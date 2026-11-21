import Foundation
import Testing

@testable import DiscordBMVoice

@Suite("Audio Scheduler Tests")
struct AudioSchedulerTests {

    private actor MockSchedulable: AudioSchedulable {
        private(set) var tickCount = 0

        func tick() async {
            tickCount += 1
        }
    }

    @Test("AudioScheduler shards guilds across workers according to guildsPerWorker")
    func schedulerWorkerSharding() async {
        let scheduler = AudioScheduler(configuration: .init(guildsPerWorker: 4))

        #expect(await scheduler.guildCount == 0)
        #expect(await scheduler.workerCount == 0)

        // 4 guilds on capacity-4 scheduler -> 1 worker
        for g in 1...4 {
            let target = MockSchedulable()
            await scheduler.register(guildID: Snowflake(UInt64(g)), target: target)
        }

        #expect(await scheduler.guildCount == 4)
        #expect(await scheduler.workerCount == 1)

        // 5th guild spills into a 2nd worker
        let target5 = MockSchedulable()
        await scheduler.register(guildID: 5, target: target5)

        #expect(await scheduler.guildCount == 5)
        #expect(await scheduler.workerCount == 2)

        // Fill 2nd worker to capacity (8 total)
        for g in 6...8 {
            await scheduler.register(guildID: Snowflake(UInt64(g)), target: MockSchedulable())
        }
        #expect(await scheduler.guildCount == 8)
        #expect(await scheduler.workerCount == 2)

        // 9th guild spawns a 3rd worker
        await scheduler.register(guildID: 9, target: MockSchedulable())
        #expect(await scheduler.guildCount == 9)
        #expect(await scheduler.workerCount == 3)

        let stats = await scheduler.workerStats
        #expect(stats.count == 3)
        #expect(stats[0].activeGuilds == 4)
        #expect(stats[1].activeGuilds == 4)
        #expect(stats[2].activeGuilds == 1)

        await scheduler.stopAll()
        #expect(await scheduler.guildCount == 0)
        #expect(await scheduler.workerCount == 0)
    }

    @Test("AudioScheduler delivers 20ms paced ticks to registered targets")
    func schedulerDeliversTicks() async throws {
        let scheduler = AudioScheduler(configuration: .init(guildsPerWorker: 4))

        let targetA = MockSchedulable()
        let targetB = MockSchedulable()

        await scheduler.register(guildID: 101, target: targetA)
        await scheduler.register(guildID: 102, target: targetB)

        // Allow at least 2 ticks to fire (~40ms)
        try await Task.sleep(for: .milliseconds(75))

        let ticksA = await targetA.tickCount
        let ticksB = await targetB.tickCount
        #expect(ticksA >= 2)
        #expect(ticksB >= 2)

        await scheduler.stopAll()
    }

    @Test("AudioScheduler unregisters targets and prunes idle workers")
    func schedulerUnregisterAndPrune() async {
        let scheduler = AudioScheduler(configuration: .init(guildsPerWorker: 2))

        let target1 = MockSchedulable()
        let target2 = MockSchedulable()
        let target3 = MockSchedulable()

        await scheduler.register(guildID: 1, target: target1)
        await scheduler.register(guildID: 2, target: target2)
        await scheduler.register(guildID: 3, target: target3)

        #expect(await scheduler.guildCount == 3)
        #expect(await scheduler.workerCount == 2)
        #expect(await scheduler.contains(guildID: 1))
        #expect(await scheduler.contains(guildID: 3))

        // Removing guild 3 empties worker 2, triggering auto-prune
        await scheduler.unregister(guildID: 3)
        #expect(await scheduler.guildCount == 2)
        #expect(await scheduler.workerCount == 1)
        #expect(await !scheduler.contains(guildID: 3))

        await scheduler.unregister(guildID: 1)
        await scheduler.unregister(guildID: 2)

        #expect(await scheduler.guildCount == 0)
        #expect(await scheduler.workerCount == 0)
    }

    @Test("VoiceConfiguration presets")
    func voiceConfigurationPresets() {
        let defaultConfig = VoiceConfiguration()
        #expect(defaultConfig.audioScheduler == nil)

        let customScheduler = AudioScheduler()
        let highScaleConfig = VoiceConfiguration.highScale(guildsPerWorker: 16, scheduler: customScheduler)
        #expect(highScaleConfig.audioScheduler != nil)
    }

    @Test("VoiceConnection unregisters from AudioScheduler on close")
    func voiceConnectionSchedulerIntegration() async {
        let scheduler = AudioScheduler()
        let config = VoiceConfiguration.highScale(scheduler: scheduler)

        let connection = VoiceConnection(
            guildID: 99_999,
            userID: 88_888,
            config: config,
            sendVoiceStateUpdate: { _ in }
        )

        let target = MockSchedulable()
        await scheduler.register(guildID: 99_999, target: target)
        #expect(await scheduler.contains(guildID: 99_999))

        // Connection close triggers automatic unregistration
        await connection.close()
        #expect(await !scheduler.contains(guildID: 99_999))
        await scheduler.stopAll()
    }
}
