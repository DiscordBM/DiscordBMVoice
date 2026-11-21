import Audio
import Foundation

/// Lifecycle events emitted by TrackQueue.
public enum QueueEvent: Sendable {
    case trackStarted(AudioTrack, TrackHandle)
    case trackEnded(AudioTrack, TrackHandle)
    case trackSkipped(AudioTrack, TrackHandle)
    case trackError(AudioTrack, TrackHandle, message: String)
    case queueEmptied
}

/// Manages sequential track playback and queue events for a voice connection.
public actor TrackQueue {

    /// A queued track entry.
    public struct QueuedItem: Sendable, Identifiable {
        public let id: UUID
        public let track: AudioTrack
        public let handle: TrackHandle

        public init(track: AudioTrack, handle: TrackHandle) {
            self.id = track.id
            self.track = track
            self.handle = handle
        }
    }

    private weak var connection: VoiceConnection?
    private var currentPlaying: QueuedItem?
    private var pendingItems: [QueuedItem] = []
    private var trackObserverTask: Task<Void, Never>?

    private let eventStream: AsyncStream<QueueEvent>
    private let eventContinuation: AsyncStream<QueueEvent>.Continuation

    /// Queue lifecycle events.
    public var events: AsyncStream<QueueEvent> {
        eventStream
    }

    /// Creates a new TrackQueue bound to the given connection.
    public init(connection: VoiceConnection) {
        self.connection = connection
        let (stream, continuation) = AsyncStream<QueueEvent>.makeStream()
        self.eventStream = stream
        self.eventContinuation = continuation
    }

    deinit {
        trackObserverTask?.cancel()
        eventContinuation.finish()
    }

    /// Currently playing track handle, if any.
    public var current: TrackHandle? {
        currentPlaying?.handle
    }

    /// Currently playing track, if any.
    public var currentTrack: AudioTrack? {
        currentPlaying?.track
    }

    /// Upcoming tracks waiting in the queue.
    public var upcomingTracks: [AudioTrack] {
        pendingItems.map(\.track)
    }

    /// Upcoming track handles waiting in the queue.
    public var upcomingHandles: [TrackHandle] {
        pendingItems.map(\.handle)
    }

    /// Total tracks in queue including current.
    public var count: Int {
        (currentPlaying != nil ? 1 : 0) + pendingItems.count
    }

    /// True if no track is playing and none are queued.
    public var isEmpty: Bool {
        currentPlaying == nil && pendingItems.isEmpty
    }

    /// Adds a track to the queue. Plays immediately if idle.
    @discardableResult
    public func add(_ track: AudioTrack) async -> TrackHandle {
        let handle = TrackHandle(track: track)
        let item = QueuedItem(track: track, handle: handle)

        if currentPlaying == nil {
            await startPlayback(of: item)
        } else {
            pendingItems.append(item)
        }

        return handle
    }

    /// Adds an Opus frame provider with rich metadata to the queue.
    @discardableResult
    public func add(
        _ provider: any OpusFrameProvider,
        metadata: TrackMetadata = TrackMetadata(),
        userData: TrackUserData = TrackUserData(),
        volume: Float = 1.0,
        isLooping: Bool = false
    ) async -> TrackHandle {
        let track = AudioTrack(
            provider: provider,
            metadata: metadata,
            userData: userData,
            volume: volume,
            isLooping: isLooping
        )
        return await add(track)
    }

    /// Adds an Opus frame provider to the queue by wrapping it into an `AudioTrack`.
    ///
    /// - Parameters:
    ///   - provider: The audio frame provider.
    ///   - title: An optional human-readable title.
    ///   - metadata: Optional key-value metadata.
    /// - Returns: A handle to the queued track.
    @discardableResult
    public func add(
        _ provider: any OpusFrameProvider,
        title: String? = nil,
        metadata: [String: String] = [:]
    ) async -> TrackHandle {
        let meta = TrackMetadata(title: title, custom: metadata)
        let track = AudioTrack(provider: provider, metadata: meta)
        return await add(track)
    }

    /// Adds an audio file from disk with rich metadata and user context.
    @discardableResult
    public func addFile(
        _ path: String,
        metadata: TrackMetadata = TrackMetadata(),
        userData: TrackUserData = TrackUserData(),
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) async throws -> TrackHandle {
        let track = try AudioTrack.file(
            path,
            metadata: metadata,
            userData: userData,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
        return await add(track)
    }

    /// Adds an audio file from disk (MP3, WAV, FLAC) to the queue.
    @discardableResult
    public func addFile(
        _ path: String,
        title: String? = nil,
        metadata: [String: String] = [:],
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) async throws -> TrackHandle {
        let track = try AudioTrack.file(
            path,
            title: title,
            metadata: metadata,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
        return await add(track)
    }

    /// Adds in-memory audio data with rich metadata and user context.
    @discardableResult
    public func addData(
        _ data: Data,
        metadata: TrackMetadata = TrackMetadata(),
        userData: TrackUserData = TrackUserData(),
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) async throws -> TrackHandle {
        let track = try AudioTrack.data(
            data,
            metadata: metadata,
            userData: userData,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
        return await add(track)
    }

    /// Adds in-memory audio data (MP3, WAV, FLAC) to the queue.
    @discardableResult
    public func addData(
        _ data: Data,
        title: String? = nil,
        metadata: [String: String] = [:],
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) async throws -> TrackHandle {
        let track = try AudioTrack.data(
            data,
            title: title,
            metadata: metadata,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
        return await add(track)
    }

    /// Adds in-memory audio bytes with rich metadata and user context.
    @discardableResult
    public func addBytes(
        _ bytes: [UInt8],
        metadata: TrackMetadata = TrackMetadata(),
        userData: TrackUserData = TrackUserData(),
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) async throws -> TrackHandle {
        let track = try AudioTrack.bytes(
            bytes,
            metadata: metadata,
            userData: userData,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
        return await add(track)
    }

    /// Adds in-memory audio bytes (MP3, WAV, FLAC) to the queue.
    @discardableResult
    public func addBytes(
        _ bytes: [UInt8],
        title: String? = nil,
        metadata: [String: String] = [:],
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) async throws -> TrackHandle {
        let track = try AudioTrack.bytes(
            bytes,
            title: title,
            metadata: metadata,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
        return await add(track)
    }

    /// Enqueues a cached audio source.
    @discardableResult
    public func addCached(
        _ source: CachedSource,
        metadata: TrackMetadata? = nil,
        volume: Float = 1.0,
        isLooping: Bool = false,
        userData: TrackUserData = TrackUserData()
    ) async -> TrackHandle {
        let track = source.track(metadata: metadata, volume: volume, isLooping: isLooping, userData: userData)
        return await add(track)
    }

    /// Enqueues a cached soundboard clip by key.
    @discardableResult
    public func addSoundboard(
        key: String,
        from cache: SoundboardCache = .shared,
        metadata: TrackMetadata? = nil,
        volume: Float = 1.0,
        isLooping: Bool = false,
        userData: TrackUserData = TrackUserData()
    ) async -> TrackHandle? {
        guard
            let track = await cache.track(
                key: key,
                metadata: metadata,
                volume: volume,
                isLooping: isLooping,
                userData: userData
            )
        else {
            return nil
        }
        return await add(track)
    }

    /// Skips the currently playing track and advances immediately to the next track in the queue.
    ///
    /// - Returns: The skipped `AudioTrack`, or `nil` if nothing was playing.
    @discardableResult
    public func skip() async -> AudioTrack? {
        guard let current = currentPlaying else {
            return nil
        }

        trackObserverTask?.cancel()
        trackObserverTask = nil

        await current.handle.stop()
        await connection?.mixer.remove(id: current.id)
        eventContinuation.yield(.trackSkipped(current.track, current.handle))

        await advanceToNext()
        return current.track
    }

    /// Pauses playback of the current track.
    public func pause() async {
        await currentPlaying?.handle.pause()
    }

    /// Resumes playback of the current track.
    public func resume() async {
        await currentPlaying?.handle.resume()
    }

    /// Stops playback permanently and clears all upcoming tracks from the queue.
    public func stop() async {
        trackObserverTask?.cancel()
        trackObserverTask = nil

        let current = currentPlaying
        currentPlaying = nil
        pendingItems.removeAll()

        if let current {
            await current.handle.stop()
            await connection?.mixer.remove(id: current.id)
            eventContinuation.yield(.trackEnded(current.track, current.handle))
        }
        eventContinuation.yield(.queueEmptied)
    }

    /// Clears all upcoming tracks from the queue without interrupting the current track.
    public func clear() {
        pendingItems.removeAll()
    }

    /// Removes an upcoming track at the specified index.
    ///
    /// - Parameter index: Zero-based index within `upcomingTracks`.
    /// - Returns: The removed track, or `nil` if index is out of bounds.
    @discardableResult
    public func dequeue(at index: Int) -> AudioTrack? {
        guard index >= 0 && index < pendingItems.count else {
            return nil
        }
        return pendingItems.remove(at: index).track
    }

    /// Shuffles the upcoming tracks in the queue randomly.
    public func shuffle() {
        pendingItems.shuffle()
    }

    /// Current playback position of the active track, or nil if idle.
    public var position: Duration? {
        get async {
            await currentPlaying?.handle.position
        }
    }

    /// Current playback position in seconds of the active track, or nil if idle.
    public var positionSeconds: Double? {
        get async {
            await currentPlaying?.handle.positionSeconds
        }
    }

    /// Seeks playback of the current track to the specified timestamp in seconds.
    public func seek(to seconds: Double) async throws {
        guard let current = currentPlaying else {
            throw AudioSeekError.streamClosed
        }
        try await current.handle.seek(to: seconds)
    }

    /// Seeks playback of the current track to the specified Duration.
    public func seek(to duration: Duration) async throws {
        guard let current = currentPlaying else {
            throw AudioSeekError.streamClosed
        }
        try await current.handle.seek(to: duration)
    }

    private func startPlayback(of item: QueuedItem) async {
        self.currentPlaying = item
        trackObserverTask?.cancel()

        guard let connection = self.connection else {
            return
        }

        await connection.play(item.track)
        eventContinuation.yield(.trackStarted(item.track, item.handle))

        let itemHandle = item.handle
        let itemTrack = item.track
        let itemID = item.id

        self.trackObserverTask = Task { [weak self] in
            for await event in await itemHandle.events {
                switch event {
                case .ended, .stopped:
                    await self?.onTrackEnded(id: itemID, track: itemTrack, handle: itemHandle)
                    return
                case .error(_, let message):
                    await self?.onTrackError(id: itemID, track: itemTrack, handle: itemHandle, message: message)
                    return
                default:
                    break
                }
            }
        }
    }

    private func onTrackEnded(id: UUID, track: AudioTrack, handle: TrackHandle) async {
        guard let current = currentPlaying, current.id == id else {
            return
        }
        await connection?.mixer.remove(id: id)
        eventContinuation.yield(.trackEnded(track, handle))
        await advanceToNext()
    }

    private func onTrackError(id: UUID, track: AudioTrack, handle: TrackHandle, message: String) async {
        guard let current = currentPlaying, current.id == id else {
            return
        }
        await connection?.mixer.remove(id: id)
        eventContinuation.yield(.trackError(track, handle, message: message))
        await advanceToNext()
    }

    private func advanceToNext() async {
        currentPlaying = nil
        if !pendingItems.isEmpty {
            let next = pendingItems.removeFirst()
            await startPlayback(of: next)
        } else {
            eventContinuation.yield(.queueEmptied)
        }
    }
}
