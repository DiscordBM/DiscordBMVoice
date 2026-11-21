import Audio
import Foundation

/// Lifecycle state of an audio track.
public enum TrackState: Sendable, Equatable {
    case playing
    case paused
    case stopped
    case ended
}

/// Events emitted during the lifecycle of an audio track.
public enum TrackEvent: Sendable, Equatable {
    case paused(TrackMetadata)
    case resumed(TrackMetadata)
    case stopped(TrackMetadata)
    case ended(TrackMetadata)
    case error(TrackMetadata, message: String)

    /// Associated metadata of the track emitting this event.
    public var metadata: TrackMetadata {
        switch self {
        case .paused(let meta), .resumed(let meta), .stopped(let meta), .ended(let meta):
            return meta
        case .error(let meta, _):
            return meta
        }
    }
}

/// Control handle for an active track.
public actor TrackHandle: Identifiable {

    nonisolated public let id: UUID
    private let track: AudioTrack

    init(track: AudioTrack) {
        self.id = track.id
        self.track = track
    }

    /// Direct reference to the underlying AudioTrack actor.
    public var audioTrack: AudioTrack {
        track
    }

    /// Track title, if set in metadata.
    nonisolated public var title: String? {
        track.title
    }

    /// Rich track metadata.
    nonisolated public var metadata: TrackMetadata {
        track.metadata
    }

    /// Contextual user data attached to this track.
    public var userData: TrackUserData {
        get async {
            await track.userData
        }
    }

    /// Replaces the contextual user data for this track.
    public func setUserData(_ data: TrackUserData) async {
        await track.setUserData(data)
    }

    /// Mutates the contextual user data in-place.
    public func updateUserData(_ mutate: @Sendable (inout TrackUserData) -> Void) async {
        await track.updateUserData(mutate)
    }

    /// Current state of the track.
    public var state: TrackState {
        get async {
            await track.state
        }
    }

    /// Stream of events emitted by this track.
    public var events: AsyncStream<TrackEvent> {
        get async {
            await track.events
        }
    }

    /// Pauses playback of this track.
    public func pause() async {
        await track.pause()
    }

    /// Resumes playback of this track.
    public func resume() async {
        await track.resume()
    }

    /// Stops playback permanently.
    public func stop() async {
        await track.stop()
    }

    /// Playback volume factor (1.0 = 100%).
    public var volume: Float {
        get async {
            await track.volume
        }
    }

    /// Sets the playback volume factor.
    public func setVolume(_ volume: Float) async {
        await track.setVolume(volume)
    }

    /// Whether playback will repeat when finished.
    public var isLooping: Bool {
        get async {
            await track.isLooping
        }
    }

    /// Sets whether the track should loop indefinitely.
    public func setLooping(_ looping: Bool) async {
        await track.setLooping(looping)
    }

    /// Current playback position as a Duration.
    public var position: Duration {
        get async {
            await track.position
        }
    }

    /// Current playback position in seconds.
    public var positionSeconds: Double {
        get async {
            await track.positionSeconds
        }
    }

    /// Seeks playback to the specified position in seconds.
    public func seek(to seconds: Double) async throws {
        try await track.seek(to: seconds)
    }

    /// Seeks playback to the specified Duration.
    public func seek(to duration: Duration) async throws {
        try await track.seek(to: duration)
    }

    /// Adds a digital audio filter to this track.
    public func addFilter(_ filter: any AudioFilter) async {
        await track.addFilter(filter)
    }

    /// Removes all audio filters from this track.
    public func removeFilters() async {
        await track.removeFilters()
    }
}

/// Audio track wrapping an Opus or PCM frame provider with volume, looping, and state controls.
public actor AudioTrack: OpusFrameProvider, PCMFrameProvider, SeekableAudioProvider, Identifiable {

    nonisolated public let id: UUID
    nonisolated public let metadata: TrackMetadata
    private var _userData: TrackUserData

    /// Track title, if set in metadata.
    nonisolated public var title: String? {
        metadata.title
    }

    /// Contextual user data attached to this track.
    public var userData: TrackUserData {
        get { _userData }
        set { _userData = newValue }
    }

    /// Replaces the contextual user data for this track.
    public func setUserData(_ data: TrackUserData) {
        _userData = data
    }

    /// Mutates the contextual user data in-place.
    public func updateUserData(_ mutate: (inout TrackUserData) -> Void) {
        mutate(&_userData)
    }

    private let opusProvider: (any OpusFrameProvider)?
    private let pcmProvider: (any PCMFrameProvider)?
    private var opusDecoder: OpusDecoder?
    private var opusEncoder: OpusEncoder?
    private(set) public var state: TrackState = .playing
    private(set) public var volume: Float = 1.0
    public var isLooping: Bool = false
    private(set) public var positionSeconds: Double = 0.0

    /// Current playback position as a Duration.
    public var position: Duration {
        let sec = Int64(positionSeconds)
        let atto = Int64((positionSeconds - Double(sec)) * 1e18)
        return Duration(secondsComponent: sec, attosecondsComponent: atto)
    }

    /// True if the track was initialized from an OpusFrameProvider, does not have native PCM, and has no custom filters.
    public var isOpusNative: Bool {
        pcmProvider == nil && opusProvider != nil && filters.isEmpty
    }

    private var filters: [any AudioFilter] = []

    /// Adds a digital audio filter to this track.
    public func addFilter(_ filter: any AudioFilter) {
        filters.append(filter)
    }

    /// Removes all audio filters from this track.
    public func removeFilters() {
        filters.removeAll()
    }

    private let eventStream: AsyncStream<TrackEvent>
    private let eventContinuation: AsyncStream<TrackEvent>.Continuation

    /// Stream of playback lifecycle events.
    public var events: AsyncStream<TrackEvent> {
        eventStream
    }

    public init(
        provider: any OpusFrameProvider,
        id: UUID = UUID(),
        metadata: TrackMetadata = TrackMetadata(),
        userData: TrackUserData = TrackUserData(),
        volume: Float = 1.0,
        isLooping: Bool = false
    ) {
        self.id = id
        self.metadata = metadata
        self._userData = userData
        self.opusProvider = provider
        self.pcmProvider = provider as? any PCMFrameProvider
        self.volume = max(0.0, volume)
        self.isLooping = isLooping
        let (stream, continuation) = AsyncStream<TrackEvent>.makeStream()
        self.eventStream = stream
        self.eventContinuation = continuation
    }

    public init(
        provider: any OpusFrameProvider,
        id: UUID = UUID(),
        title: String?,
        metadata: TrackMetadata? = nil,
        userData: TrackUserData = TrackUserData(),
        volume: Float = 1.0,
        isLooping: Bool = false
    ) {
        var meta = metadata ?? TrackMetadata()
        if let title, meta.title == nil {
            meta.title = title
        }
        self.init(
            provider: provider,
            id: id,
            metadata: meta,
            userData: userData,
            volume: volume,
            isLooping: isLooping
        )
    }

    public init(
        provider: any OpusFrameProvider,
        id: UUID = UUID(),
        title: String? = nil,
        metadata: [String: String],
        volume: Float = 1.0,
        isLooping: Bool = false
    ) {
        let meta = TrackMetadata(title: title, custom: metadata)
        self.init(
            provider: provider,
            id: id,
            metadata: meta,
            volume: volume,
            isLooping: isLooping
        )
    }

    public init(
        pcmProvider: any PCMFrameProvider,
        id: UUID = UUID(),
        metadata: TrackMetadata = TrackMetadata(),
        userData: TrackUserData = TrackUserData(),
        volume: Float = 1.0,
        isLooping: Bool = false
    ) {
        self.id = id
        self.metadata = metadata
        self._userData = userData
        self.pcmProvider = pcmProvider
        self.opusProvider = pcmProvider as? any OpusFrameProvider
        self.volume = max(0.0, volume)
        self.isLooping = isLooping
        let (stream, continuation) = AsyncStream<TrackEvent>.makeStream()
        self.eventStream = stream
        self.eventContinuation = continuation
    }

    public init(
        pcmProvider: any PCMFrameProvider,
        id: UUID = UUID(),
        title: String?,
        metadata: TrackMetadata? = nil,
        userData: TrackUserData = TrackUserData(),
        volume: Float = 1.0,
        isLooping: Bool = false
    ) {
        var meta = metadata ?? TrackMetadata()
        if let title, meta.title == nil {
            meta.title = title
        }
        self.init(
            pcmProvider: pcmProvider,
            id: id,
            metadata: meta,
            userData: userData,
            volume: volume,
            isLooping: isLooping
        )
    }

    public init(
        pcmProvider: any PCMFrameProvider,
        id: UUID = UUID(),
        title: String? = nil,
        metadata: [String: String],
        volume: Float = 1.0,
        isLooping: Bool = false
    ) {
        let meta = TrackMetadata(title: title, custom: metadata)
        self.init(
            pcmProvider: pcmProvider,
            id: id,
            metadata: meta,
            volume: volume,
            isLooping: isLooping
        )
    }

    /// Initializes an audio track from a file on disk (MP3, WAV, FLAC).
    public init(
        file path: String,
        id: UUID = UUID(),
        metadata: TrackMetadata? = nil,
        userData: TrackUserData = TrackUserData(),
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) throws {
        let source = try AudioSource(path: path, configuration: configuration)
        var meta = metadata ?? TrackMetadata()
        if meta.title == nil {
            meta.title = URL(fileURLWithPath: path).lastPathComponent
        }
        if meta.duration == nil, let durSec = source.info.durationSeconds {
            meta.durationSeconds = durSec
        }
        if meta.sourceURL == nil {
            meta.sourceURL = path
        }
        self.init(
            provider: source,
            id: id,
            metadata: meta,
            userData: userData,
            volume: volume,
            isLooping: isLooping
        )
    }

    /// Initializes an audio track from a file on disk with title and custom metadata.
    public init(
        file path: String,
        id: UUID = UUID(),
        title: String?,
        metadata: [String: String] = [:],
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) throws {
        let meta = TrackMetadata(title: title, custom: metadata)
        try self.init(
            file: path,
            id: id,
            metadata: meta,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
    }

    /// Initializes an audio track from in-memory audio data (MP3, WAV, FLAC).
    public init(
        data: Data,
        id: UUID = UUID(),
        metadata: TrackMetadata = TrackMetadata(),
        userData: TrackUserData = TrackUserData(),
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) throws {
        let source = try AudioSource(data: data, configuration: configuration)
        var meta = metadata
        if meta.duration == nil, let durSec = source.info.durationSeconds {
            meta.durationSeconds = durSec
        }
        self.init(
            provider: source,
            id: id,
            metadata: meta,
            userData: userData,
            volume: volume,
            isLooping: isLooping
        )
    }

    public init(
        data: Data,
        id: UUID = UUID(),
        title: String?,
        metadata: [String: String] = [:],
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) throws {
        let meta = TrackMetadata(title: title, custom: metadata)
        try self.init(
            data: data,
            id: id,
            metadata: meta,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
    }

    /// Initializes an audio track from in-memory byte array (MP3, WAV, FLAC).
    public init(
        bytes: [UInt8],
        id: UUID = UUID(),
        metadata: TrackMetadata = TrackMetadata(),
        userData: TrackUserData = TrackUserData(),
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) throws {
        let source = try AudioSource(bytes: bytes, configuration: configuration)
        var meta = metadata
        if meta.duration == nil, let durSec = source.info.durationSeconds {
            meta.durationSeconds = durSec
        }
        self.init(
            provider: source,
            id: id,
            metadata: meta,
            userData: userData,
            volume: volume,
            isLooping: isLooping
        )
    }

    public init(
        bytes: [UInt8],
        id: UUID = UUID(),
        title: String?,
        metadata: [String: String] = [:],
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) throws {
        let meta = TrackMetadata(title: title, custom: metadata)
        try self.init(
            bytes: bytes,
            id: id,
            metadata: meta,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
    }

    /// Factory method creating an `AudioTrack` from a file on disk.
    public static func file(
        _ path: String,
        metadata: TrackMetadata = TrackMetadata(),
        userData: TrackUserData = TrackUserData(),
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) throws -> AudioTrack {
        try AudioTrack(
            file: path,
            metadata: metadata,
            userData: userData,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
    }

    public static func file(
        _ path: String,
        title: String? = nil,
        metadata: [String: String] = [:],
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) throws -> AudioTrack {
        let meta = TrackMetadata(title: title, custom: metadata)
        return try AudioTrack(
            file: path,
            metadata: meta,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
    }

    /// Creates an AudioTrack from in-memory Data.
    public static func data(
        _ data: Data,
        metadata: TrackMetadata = TrackMetadata(),
        userData: TrackUserData = TrackUserData(),
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) throws -> AudioTrack {
        try AudioTrack(
            data: data,
            metadata: metadata,
            userData: userData,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
    }

    public static func data(
        _ data: Data,
        title: String? = nil,
        metadata: [String: String] = [:],
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) throws -> AudioTrack {
        let meta = TrackMetadata(title: title, custom: metadata)
        return try AudioTrack(
            data: data,
            metadata: meta,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
    }

    /// Creates an AudioTrack from in-memory bytes.
    public static func bytes(
        _ bytes: [UInt8],
        metadata: TrackMetadata = TrackMetadata(),
        userData: TrackUserData = TrackUserData(),
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) throws -> AudioTrack {
        try AudioTrack(
            bytes: bytes,
            metadata: metadata,
            userData: userData,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
    }

    public static func bytes(
        _ bytes: [UInt8],
        title: String? = nil,
        metadata: [String: String] = [:],
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) throws -> AudioTrack {
        let meta = TrackMetadata(title: title, custom: metadata)
        return try AudioTrack(
            bytes: bytes,
            metadata: meta,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
    }

    deinit {
        eventContinuation.finish()
    }

    /// Sets whether the track loops.
    public func setLooping(_ looping: Bool) {
        self.isLooping = looping
    }

    /// Sets the track volume.
    public func setVolume(_ volume: Float) {
        self.volume = max(0.0, volume)
    }

    /// Pauses playback.
    public func pause() {
        guard state == .playing else { return }
        state = .paused
        eventContinuation.yield(.paused(metadata))
    }

    /// Resumes playback.
    public func resume() {
        guard state == .paused else { return }
        state = .playing
        eventContinuation.yield(.resumed(metadata))
    }

    /// Stops playback permanently.
    public func stop() {
        guard state != .stopped && state != .ended else { return }
        state = .stopped
        opusDecoder?.close()
        opusEncoder?.close()
        eventContinuation.yield(.stopped(metadata))
        eventContinuation.finish()
    }

    /// Seeks playback to the specified position in seconds.
    public func seek(to seconds: Double) async throws {
        guard state != .stopped && state != .ended else {
            throw AudioSeekError.streamClosed
        }

        if let seekable = (pcmProvider as? any SeekableAudioProvider) ?? (opusProvider as? any SeekableAudioProvider) {
            try await seekable.seek(to: seconds)
            self.positionSeconds = max(0.0, seconds)
            self.opusDecoder = nil
        } else {
            throw AudioSeekError.notSeekable
        }
    }

    /// Seeks playback to the specified Duration.
    public func seek(to duration: Duration) async throws {
        let (sec, atto) = duration.components
        let seconds = Double(sec) + (Double(atto) * 1e-18)
        try await seek(to: seconds)
    }

    /// Pulls the next 20ms Float PCM frame (1920 samples) from the track, running through attached filters.
    public func nextPCMFrame() async -> [Float]? {
        guard state == .playing else {
            return nil
        }

        var rawPCM: [Float]?
        if let pcmProvider {
            if let pcm = await pcmProvider.nextPCMFrame() {
                positionSeconds += 0.02
                rawPCM = pcm
            } else if isLooping {
                positionSeconds = 0.0
                if let resettable = pcmProvider as? any ResettablePCMFrameProvider {
                    await resettable.reset()
                    let pcm = await resettable.nextPCMFrame()
                    if pcm != nil { positionSeconds += 0.02 }
                    rawPCM = pcm
                } else {
                    return nil
                }
            } else {
                markEnded()
                return nil
            }
        } else if let opusProvider {
            if let frame = await opusProvider.nextFrame() {
                positionSeconds += 0.02
                rawPCM = decodeOpusToPCM(frame)
            } else if isLooping {
                positionSeconds = 0.0
                if let resettable = opusProvider as? any ResettableOpusFrameProvider {
                    await resettable.reset()
                    if let frame = await resettable.nextFrame() {
                        positionSeconds += 0.02
                        rawPCM = decodeOpusToPCM(frame)
                    } else {
                        return nil
                    }
                } else {
                    return nil
                }
            } else {
                markEnded()
                return nil
            }
        }

        guard var pcm = rawPCM else { return nil }
        if !filters.isEmpty {
            for filter in filters {
                filter.process(pcm: &pcm)
            }
        }
        return pcm
    }

    /// Pulls the next Opus frame from the underlying provider according to current playback state.
    public func nextFrame() async -> [UInt8]? {
        guard state == .playing else {
            return nil
        }

        if let opusProvider {
            if let frame = await opusProvider.nextFrame() {
                positionSeconds += 0.02
                if volume == 1.0 {
                    return frame
                }
                if let pcm = decodeOpusToPCM(frame) {
                    let scaled = pcm.map { $0 * volume }
                    if opusEncoder == nil {
                        opusEncoder = try? OpusEncoder(channels: AudioConstants.channelCount, configuration: .music)
                    }
                    if let enc = opusEncoder, let packet = try? enc.encode(frame: scaled) {
                        return packet.bytes
                    }
                }
                return frame
            } else if isLooping {
                positionSeconds = 0.0
                if let resettable = opusProvider as? any ResettableOpusFrameProvider {
                    await resettable.reset()
                    if let frame = await resettable.nextFrame() {
                        positionSeconds += 0.02
                        return frame
                    }
                }
                return nil
            } else {
                markEnded()
                return nil
            }
        } else if let pcmProvider {
            if let pcm = await pcmProvider.nextPCMFrame() {
                positionSeconds += 0.02
                let scaled = volume == 1.0 ? pcm : pcm.map { $0 * volume }
                if opusEncoder == nil {
                    opusEncoder = try? OpusEncoder(channels: AudioConstants.channelCount, configuration: .music)
                }
                if let enc = opusEncoder, let packet = try? enc.encode(frame: scaled) {
                    return packet.bytes
                }
                return nil
            } else if isLooping {
                positionSeconds = 0.0
                if let resettable = pcmProvider as? any ResettablePCMFrameProvider {
                    await resettable.reset()
                    if let pcm = await resettable.nextPCMFrame() {
                        positionSeconds += 0.02
                        let scaled = volume == 1.0 ? pcm : pcm.map { $0 * volume }
                        if opusEncoder == nil {
                            opusEncoder = try? OpusEncoder(channels: AudioConstants.channelCount, configuration: .music)
                        }
                        if let enc = opusEncoder, let packet = try? enc.encode(frame: scaled) {
                            return packet.bytes
                        }
                    }
                }
                return nil
            } else {
                markEnded()
                return nil
            }
        }

        return nil
    }

    private func decodeOpusToPCM(_ frame: [UInt8]) -> [Float]? {
        if frame == AudioConstants.silencePacket {
            return [Float](repeating: 0.0, count: AudioConstants.frameSampleCount)
        }
        if opusDecoder == nil {
            opusDecoder = try? OpusDecoder(channels: AudioConstants.channelCount)
        }
        guard let decoder = opusDecoder else { return nil }
        do {
            let samples = try decoder.decode(bytes: frame)
            if samples.count < AudioConstants.frameSampleCount {
                var padded = samples
                let missing = AudioConstants.frameSampleCount - samples.count
                padded.append(contentsOf: [Float](repeating: 0.0, count: missing))
                return padded
            }
            return samples
        } catch {
            return [Float](repeating: 0.0, count: AudioConstants.frameSampleCount)
        }
    }

    private func markEnded() {
        guard state == .playing else { return }
        state = .ended
        eventContinuation.yield(.ended(metadata))
        eventContinuation.finish()
    }

    /// Terminates playback with an error and emits an `.error` event.
    public func fail(with error: String) {
        guard state != .stopped && state != .ended else { return }
        state = .ended
        opusDecoder?.close()
        opusEncoder?.close()
        eventContinuation.yield(.error(metadata, message: error))
        eventContinuation.finish()
    }
}

/// In-memory Float PCM frame provider for tests or direct PCM audio playback.
public actor MemoryPCMFrameProvider: ResettablePCMFrameProvider, SeekableAudioProvider {

    private let frames: [[Float]]
    private var currentIndex = 0
    public var isLooping: Bool

    public init(frames: [[Float]], isLooping: Bool = false) {
        self.frames = frames
        self.isLooping = isLooping
    }

    public func nextPCMFrame() async -> [Float]? {
        guard currentIndex < frames.count else {
            if isLooping && !frames.isEmpty {
                currentIndex = 1
                return frames[0]
            }
            return nil
        }
        let frame = frames[currentIndex]
        currentIndex += 1
        return frame
    }

    /// Resets playback index back to the first frame.
    public func reset() {
        currentIndex = 0
    }

    /// Seeks playback to the specified position in seconds.
    public func seek(to seconds: Double) {
        let targetIndex = max(0, Int(seconds / 0.02))
        self.currentIndex = min(targetIndex, frames.count)
    }

    /// Seeks playback to the specified Duration.
    public func seek(to duration: Duration) {
        let (sec, atto) = duration.components
        let seconds = Double(sec) + (Double(atto) * 1e-18)
        seek(to: seconds)
    }
}

/// In-memory frame provider for tests or small buffers.
public actor MemoryOpusFrameProvider: ResettableOpusFrameProvider, SeekableAudioProvider {

    private let frames: [[UInt8]]
    private var currentIndex = 0
    public var isLooping: Bool

    public init(frames: [[UInt8]], isLooping: Bool = false) {
        self.frames = frames
        self.isLooping = isLooping
    }

    public func nextFrame() async -> [UInt8]? {
        guard currentIndex < frames.count else {
            if isLooping && !frames.isEmpty {
                currentIndex = 1
                return frames[0]
            }
            return nil
        }
        let frame = frames[currentIndex]
        currentIndex += 1
        return frame
    }

    /// Resets playback index back to the first frame.
    public func reset() {
        currentIndex = 0
    }

    /// Seeks playback to the specified position in seconds.
    public func seek(to seconds: Double) {
        let targetIndex = max(0, Int(seconds / 0.02))
        self.currentIndex = min(targetIndex, frames.count)
    }

    /// Seeks playback to the specified Duration.
    public func seek(to duration: Duration) {
        let (sec, atto) = duration.components
        let seconds = Double(sec) + (Double(atto) * 1e-18)
        seek(to: seconds)
    }
}
