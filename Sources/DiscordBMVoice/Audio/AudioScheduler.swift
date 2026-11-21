import Foundation
import Logging

/// Target that advances transmission by one 20ms frame on each scheduler tick.
public protocol AudioSchedulable: AnyObject, Sendable {
    /// Advances transmission by one 20ms frame.
    func tick() async
}

/// Multi-guild audio scheduler coordinating 20ms audio transmission across guilds.
///
/// Instead of every voice connection running an independent timer loop, the scheduler groups guilds
/// into worker tasks (defaulting to 16 guilds per worker). This reduces timer wakeups and scheduling
/// jitter on high-scale bots.
public actor AudioScheduler {

    /// Default shared scheduler instance.
    public static let shared = AudioScheduler()

    /// Configuration for the scheduler.
    public struct Configuration: Sendable {
        /// Maximum number of guilds paced by a single worker loop. Defaults to 16.
        public var guildsPerWorker: Int

        public init(guildsPerWorker: Int = 16) {
            self.guildsPerWorker = max(1, guildsPerWorker)
        }
    }

    /// Single worker managing a batch of guilds in a single 20ms timer loop.
    private actor Worker {
        nonisolated let id: Int
        private var targets: [GuildID: any AudioSchedulable] = [:]
        private var loopTask: Task<Void, Never>?
        private var isStopped = false
        private let logger: Logger

        init(id: Int, logger: Logger) {
            self.id = id
            self.logger = logger
        }

        var count: Int {
            targets.count
        }

        var isEmpty: Bool {
            targets.isEmpty
        }

        func add(guildID: GuildID, target: any AudioSchedulable) {
            targets[guildID] = target
            ensureRunning()
        }

        func remove(guildID: GuildID) {
            targets.removeValue(forKey: guildID)
            if targets.isEmpty {
                stop()
            }
        }

        func contains(guildID: GuildID) -> Bool {
            targets[guildID] != nil
        }

        private func ensureRunning() {
            guard loopTask == nil else { return }
            isStopped = false
            loopTask = Task { [weak self] in
                var deadline = ContinuousClock.now

                while !Task.isCancelled, let self, await !self.isStopped {
                    deadline = deadline + .milliseconds(20)
                    let now = ContinuousClock.now
                    // If more than 3 frames behind, reset deadline to avoid burst catch-up
                    if deadline < now - .milliseconds(60) {
                        deadline = now
                    }

                    await self.processTick()

                    try? await Task.sleep(until: deadline, clock: .continuous)
                }
            }
        }

        func processTick() async {
            guard !targets.isEmpty else { return }
            let current = Array(targets.values)
            // Fan out ticks concurrently across targets in this shard
            await withTaskGroup(of: Void.self) { group in
                for target in current {
                    group.addTask {
                        await target.tick()
                    }
                }
            }
        }

        func stop() {
            isStopped = true
            loopTask?.cancel()
            loopTask = nil
            targets.removeAll()
        }
    }

    public let configuration: Configuration
    private var workers: [Worker] = []
    private var guildWorkerMap: [GuildID: Worker] = [:]
    private var nextWorkerID = 1
    private let logger: Logger

    public init(
        configuration: Configuration = .init(),
        logger: Logger = Logger(label: "DiscordBMVoice.AudioScheduler")
    ) {
        self.configuration = configuration
        self.logger = logger
    }

    /// Assigns a guild to an existing worker with available capacity, or spawns a new one.
    public func register(guildID: GuildID, target: any AudioSchedulable) async {
        if let existingWorker = guildWorkerMap[guildID] {
            await existingWorker.add(guildID: guildID, target: target)
            return
        }

        for worker in workers {
            let count = await worker.count
            if count < configuration.guildsPerWorker {
                await worker.add(guildID: guildID, target: target)
                guildWorkerMap[guildID] = worker
                return
            }
        }

        let newWorker = Worker(id: nextWorkerID, logger: logger)
        nextWorkerID += 1
        await newWorker.add(guildID: guildID, target: target)
        workers.append(newWorker)
        guildWorkerMap[guildID] = newWorker
    }

    /// Drops a guild from the scheduler and prunes its worker if left empty.
    public func unregister(guildID: GuildID) async {
        guard let worker = guildWorkerMap.removeValue(forKey: guildID) else { return }
        await worker.remove(guildID: guildID)

        if await worker.isEmpty {
            let workerID = worker.id
            workers.removeAll(where: { $0.id == workerID })
        }
    }

    /// Whether the given guild is currently registered.
    public func contains(guildID: GuildID) -> Bool {
        guildWorkerMap[guildID] != nil
    }

    /// Total registered guilds across all workers.
    public var guildCount: Int {
        guildWorkerMap.count
    }

    /// Number of active worker tasks running.
    public var workerCount: Int {
        workers.count
    }

    /// Target capacity per worker.
    public var guildsPerWorker: Int {
        configuration.guildsPerWorker
    }

    /// Diagnostic stats for an active scheduler worker.
    public struct WorkerStats: Sendable {
        public let workerID: Int
        public let activeGuilds: Int
    }

    /// Guild load breakdown per worker.
    public var workerStats: [WorkerStats] {
        get async {
            var stats: [WorkerStats] = []
            for worker in workers {
                let id = worker.id
                let count = await worker.count
                stats.append(WorkerStats(workerID: id, activeGuilds: count))
            }
            return stats
        }
    }

    /// Cancels all worker loops and clears all registrations.
    public func stopAll() async {
        for worker in workers {
            await worker.stop()
        }
        workers.removeAll()
        guildWorkerMap.removeAll()
    }
}
