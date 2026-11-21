import Audio
import Foundation

/// In-memory audio clip stored as pre-encoded Opus or raw PCM frames.
public final class CachedSource: Sendable {

    /// Storage format of the cached audio.
    public enum Kind: Sendable, Equatable {
        /// Compressed 20ms Opus packets ready for direct passthrough.
        case opus
        /// Uncompressed 48kHz stereo Float PCM frames ready for mixer summation.
        case pcm
    }

    public let kind: Kind
    public let metadata: TrackMetadata
    public let opusFrames: [[UInt8]]?
    public let pcmFrames: [[Float]]?

    public var frameCount: Int {
        opusFrames?.count ?? pcmFrames?.count ?? 0
    }

    public var duration: Duration {
        metadata.duration ?? .milliseconds(Int64(frameCount * 20))
    }

    public var durationSeconds: Double {
        metadata.durationSeconds ?? (Double(frameCount) * 0.02)
    }

    /// Total memory used by the cached frames in bytes.
    public var byteCount: Int {
        if let opusFrames {
            return opusFrames.reduce(0) { $0 + $1.count }
        } else if let pcmFrames {
            return pcmFrames.reduce(0) { $0 + ($1.count * MemoryLayout<Float>.size) }
        }
        return 0
    }

    public init(
        opusFrames: [[UInt8]],
        metadata: TrackMetadata = TrackMetadata()
    ) {
        self.kind = .opus
        self.opusFrames = opusFrames
        self.pcmFrames = nil
        var meta = metadata
        if meta.duration == nil {
            meta.duration = .milliseconds(Int64(opusFrames.count * 20))
        }
        self.metadata = meta
    }

    public init(
        pcmFrames: [[Float]],
        metadata: TrackMetadata = TrackMetadata()
    ) {
        self.kind = .pcm
        self.opusFrames = nil
        self.pcmFrames = pcmFrames
        var meta = metadata
        if meta.duration == nil {
            meta.duration = .milliseconds(Int64(pcmFrames.count * 20))
        }
        self.metadata = meta
    }

    /// Decodes an audio file from disk into pre-encoded 20ms Opus frames.
    public static func opus(
        fromFile path: String,
        metadata: TrackMetadata? = nil,
        configuration: OpusConfiguration = .music
    ) throws -> CachedSource {
        let decoder = try AudioDecoder(path: path)
        let frames = try readOpusFrames(from: decoder, configuration: configuration)
        var meta = metadata ?? TrackMetadata()
        if meta.title == nil {
            meta.title = URL(fileURLWithPath: path).lastPathComponent
        }
        if meta.sourceURL == nil {
            meta.sourceURL = path
        }
        if meta.duration == nil, let dur = decoder.info.durationSeconds {
            meta.durationSeconds = dur
        }
        return CachedSource(opusFrames: frames, metadata: meta)
    }

    /// Decodes an audio file from disk into 20ms Float PCM frames.
    public static func pcm(
        fromFile path: String,
        metadata: TrackMetadata? = nil
    ) throws -> CachedSource {
        let decoder = try AudioDecoder(path: path)
        let frames = try readPCMFrames(from: decoder)
        var meta = metadata ?? TrackMetadata()
        if meta.title == nil {
            meta.title = URL(fileURLWithPath: path).lastPathComponent
        }
        if meta.sourceURL == nil {
            meta.sourceURL = path
        }
        if meta.duration == nil, let dur = decoder.info.durationSeconds {
            meta.durationSeconds = dur
        }
        return CachedSource(pcmFrames: frames, metadata: meta)
    }

    /// Encodes in-memory audio bytes into 20ms Opus frames.
    public static func opus(
        fromData data: Data,
        metadata: TrackMetadata? = nil,
        configuration: OpusConfiguration = .music
    ) throws -> CachedSource {
        let decoder = try AudioDecoder(bytes: [UInt8](data))
        let frames = try readOpusFrames(from: decoder, configuration: configuration)
        var meta = metadata ?? TrackMetadata()
        if meta.duration == nil, let dur = decoder.info.durationSeconds {
            meta.durationSeconds = dur
        }
        return CachedSource(opusFrames: frames, metadata: meta)
    }

    /// Decodes in-memory audio bytes into 20ms Float PCM frames.
    public static func pcm(
        fromData data: Data,
        metadata: TrackMetadata? = nil
    ) throws -> CachedSource {
        let decoder = try AudioDecoder(bytes: [UInt8](data))
        let frames = try readPCMFrames(from: decoder)
        var meta = metadata ?? TrackMetadata()
        if meta.duration == nil, let dur = decoder.info.durationSeconds {
            meta.durationSeconds = dur
        }
        return CachedSource(pcmFrames: frames, metadata: meta)
    }

    private static func readOpusFrames(
        from decoder: AudioDecoder,
        configuration: OpusConfiguration
    ) throws -> [[UInt8]] {
        defer { decoder.close() }
        let stream = try OpusPacketStream(decoder, configuration: configuration)
        defer { stream.close() }

        var frames: [[UInt8]] = []
        while let packet = try stream.next() {
            frames.append(packet.bytes)
        }
        return frames
    }

    private static func readPCMFrames(from decoder: AudioDecoder) throws -> [[Float]] {
        defer { decoder.close() }
        var chunker = FrameChunker()
        var frames: [[Float]] = []

        while true {
            let samples = try decoder.read(frames: chunker.samplesPerChannel)
            if samples.isEmpty {
                if let last = chunker.finish(padWithSilence: true) {
                    frames.append(last)
                }
                break
            }
            chunker.append(samples)
            while let frame = chunker.nextFrame() {
                frames.append(frame)
            }
        }
        return frames
    }

    /// Spawns an independent `AudioTrack` reading from this cached source.
    public func track(
        metadata: TrackMetadata? = nil,
        volume: Float = 1.0,
        isLooping: Bool = false,
        userData: TrackUserData = TrackUserData()
    ) -> AudioTrack {
        let meta = metadata ?? self.metadata
        switch kind {
        case .opus:
            let provider = MemoryOpusFrameProvider(frames: opusFrames ?? [], isLooping: isLooping)
            return AudioTrack(
                provider: provider,
                metadata: meta,
                userData: userData,
                volume: volume,
                isLooping: isLooping
            )
        case .pcm:
            let provider = MemoryPCMFrameProvider(frames: pcmFrames ?? [], isLooping: isLooping)
            return AudioTrack(
                pcmProvider: provider,
                metadata: meta,
                userData: userData,
                volume: volume,
                isLooping: isLooping
            )
        }
    }

    /// Returns an independent Opus provider pointing to this cached data.
    public func opusProvider(isLooping: Bool = false) -> MemoryOpusFrameProvider {
        MemoryOpusFrameProvider(frames: opusFrames ?? [], isLooping: isLooping)
    }

    /// Returns an independent PCM provider pointing to this cached data.
    public func pcmProvider(isLooping: Bool = false) -> MemoryPCMFrameProvider {
        MemoryPCMFrameProvider(frames: pcmFrames ?? [], isLooping: isLooping)
    }
}

/// In-memory cache for soundboard audio clips.
public actor SoundboardCache {

    /// Global shared soundboard cache.
    public static let shared = SoundboardCache()

    private var storage: [String: CachedSource] = [:]

    public init() {}

    /// Preloads an audio file from disk into memory.
    @discardableResult
    public func preload(
        key: String,
        file path: String,
        kind: CachedSource.Kind = .opus,
        metadata: TrackMetadata? = nil,
        configuration: OpusConfiguration = .music
    ) throws -> CachedSource {
        let source: CachedSource
        switch kind {
        case .opus:
            source = try CachedSource.opus(fromFile: path, metadata: metadata, configuration: configuration)
        case .pcm:
            source = try CachedSource.pcm(fromFile: path, metadata: metadata)
        }
        storage[key] = source
        return source
    }

    /// Preloads raw audio data into memory.
    @discardableResult
    public func preload(
        key: String,
        data: Data,
        kind: CachedSource.Kind = .opus,
        metadata: TrackMetadata? = nil,
        configuration: OpusConfiguration = .music
    ) throws -> CachedSource {
        let source: CachedSource
        switch kind {
        case .opus:
            source = try CachedSource.opus(fromData: data, metadata: metadata, configuration: configuration)
        case .pcm:
            source = try CachedSource.pcm(fromData: data, metadata: metadata)
        }
        storage[key] = source
        return source
    }

    /// Stores raw PCM frames in the cache.
    @discardableResult
    public func register(
        key: String,
        pcmFrames: [[Float]],
        metadata: TrackMetadata = TrackMetadata()
    ) -> CachedSource {
        let source = CachedSource(pcmFrames: pcmFrames, metadata: metadata)
        storage[key] = source
        return source
    }

    /// Stores raw Opus frames in the cache.
    @discardableResult
    public func register(
        key: String,
        opusFrames: [[UInt8]],
        metadata: TrackMetadata = TrackMetadata()
    ) -> CachedSource {
        let source = CachedSource(opusFrames: opusFrames, metadata: metadata)
        storage[key] = source
        return source
    }

    /// Stores an existing cached source under the specified key.
    @discardableResult
    public func insert(_ source: CachedSource, forKey key: String) -> CachedSource {
        storage[key] = source
        return source
    }

    /// Returns true if the key exists in cache.
    public func contains(key: String) -> Bool {
        storage[key] != nil
    }

    /// Returns the cached source for key, or nil if not found.
    public func get(key: String) -> CachedSource? {
        storage[key]
    }

    /// Returns the cached source, loading and caching from disk on first access.
    public func autoCache(
        file path: String,
        key: String? = nil,
        kind: CachedSource.Kind = .opus,
        metadata: TrackMetadata? = nil,
        configuration: OpusConfiguration = .music
    ) throws -> CachedSource {
        let cacheKey = key ?? path
        if let existing = storage[cacheKey] {
            return existing
        }
        return try preload(
            key: cacheKey,
            file: path,
            kind: kind,
            metadata: metadata,
            configuration: configuration
        )
    }

    /// Creates an independent `AudioTrack` from a cached clip.
    public func track(
        key: String,
        metadata: TrackMetadata? = nil,
        volume: Float = 1.0,
        isLooping: Bool = false,
        userData: TrackUserData = TrackUserData()
    ) -> AudioTrack? {
        guard let source = storage[key] else { return nil }
        return source.track(metadata: metadata, volume: volume, isLooping: isLooping, userData: userData)
    }

    /// Plays a cached sound effect on the given connection's mixer.
    @discardableResult
    public func play(
        key: String,
        on connection: VoiceConnection,
        metadata: TrackMetadata? = nil,
        volume: Float = 1.0,
        isLooping: Bool = false,
        userData: TrackUserData = TrackUserData()
    ) async -> TrackHandle? {
        guard let track = track(key: key, metadata: metadata, volume: volume, isLooping: isLooping, userData: userData)
        else {
            return nil
        }
        return await connection.play(track)
    }

    public func remove(key: String) {
        storage.removeValue(forKey: key)
    }

    public func clear() {
        storage.removeAll()
    }

    public var keys: [String] {
        Array(storage.keys)
    }

    public var count: Int {
        storage.count
    }

    /// Total memory used across all cached clips in bytes.
    public var totalBytes: Int {
        storage.values.reduce(0) { $0 + $1.byteCount }
    }
}
