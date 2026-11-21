import Audio
import Foundation
import Logging

/// Multi-track software audio mixer for concurrent playback on a single voice connection.
public actor AudioMixer: OpusFrameProvider, PCMFrameProvider {

    private var activeTracks: [AudioTrack] = []
    private var encoder: OpusEncoder?
    private let configuration: OpusConfiguration
    private let logger: Logger
    private var mixBuffer: [Float] = [Float](repeating: 0.0, count: AudioConstants.frameSampleCount)
    private var filters: [any AudioFilter] = []

    public private(set) var masterVolume: Float = 1.0

    public init(
        configuration: OpusConfiguration = .music,
        logger: Logger = Logger(label: "DiscordBMVoice.AudioMixer")
    ) {
        self.configuration = configuration
        self.logger = logger
        self.encoder = try? OpusEncoder(channels: AudioConstants.channelCount, configuration: configuration)
    }

    /// Adds an audio track to the mixer for concurrent playback.
    @discardableResult
    public func add(_ track: AudioTrack) -> TrackHandle {
        activeTracks.append(track)
        return TrackHandle(track: track)
    }

    /// Adds an Opus frame provider to the mixer by wrapping it in an `AudioTrack`.
    @discardableResult
    public func add(
        _ provider: any OpusFrameProvider,
        title: String? = nil,
        metadata: [String: String] = [:],
        volume: Float = 1.0,
        isLooping: Bool = false
    ) -> TrackHandle {
        let track = AudioTrack(
            provider: provider,
            title: title,
            metadata: metadata,
            volume: volume,
            isLooping: isLooping
        )
        return add(track)
    }

    /// Adds a PCM frame provider to the mixer by wrapping it in an `AudioTrack`.
    @discardableResult
    public func add(
        _ provider: any PCMFrameProvider,
        title: String? = nil,
        metadata: [String: String] = [:],
        volume: Float = 1.0,
        isLooping: Bool = false
    ) -> TrackHandle {
        let track = AudioTrack(
            pcmProvider: provider,
            title: title,
            metadata: metadata,
            volume: volume,
            isLooping: isLooping
        )
        return add(track)
    }

    /// Plays an audio file from disk concurrently on the mixer.
    @discardableResult
    public func playFile(
        _ path: String,
        title: String? = nil,
        metadata: [String: String] = [:],
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) throws -> TrackHandle {
        let track = try AudioTrack.file(
            path,
            title: title,
            metadata: metadata,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
        return add(track)
    }

    /// Plays in-memory audio data concurrently on the mixer.
    @discardableResult
    public func playData(
        _ data: Data,
        title: String? = nil,
        metadata: [String: String] = [:],
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) throws -> TrackHandle {
        let track = try AudioTrack.data(
            data,
            title: title,
            metadata: metadata,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
        return add(track)
    }

    /// Plays in-memory audio bytes concurrently on the mixer.
    @discardableResult
    public func playBytes(
        _ bytes: [UInt8],
        title: String? = nil,
        metadata: [String: String] = [:],
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) throws -> TrackHandle {
        let track = try AudioTrack.bytes(
            bytes,
            title: title,
            metadata: metadata,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
        return add(track)
    }

    /// Removes a track by its UUID from the mixer.
    public func remove(id: UUID) {
        activeTracks.removeAll { $0.id == id }
    }

    /// Removes an audio track from the mixer.
    public func remove(_ track: AudioTrack) {
        remove(id: track.id)
    }

    /// Removes a track associated with the given handle from the mixer.
    public func remove(_ handle: TrackHandle) {
        remove(id: handle.id)
    }

    /// Stops all currently active tracks and clears the mixer.
    public func stopAll() async {
        for track in activeTracks {
            await track.stop()
        }
        activeTracks.removeAll()
    }

    /// Currently active tracks in the mixer.
    public var tracks: [AudioTrack] {
        activeTracks
    }

    /// Number of active tracks in the mixer.
    public var trackCount: Int {
        activeTracks.count
    }

    /// True if there are active tracks playing in the mixer.
    public var isPlaying: Bool {
        get async {
            for track in activeTracks {
                if await track.state == .playing {
                    return true
                }
            }
            return false
        }
    }

    /// Sets the master volume multiplier applied to all mixed audio.
    public func setMasterVolume(_ volume: Float) {
        self.masterVolume = max(0.0, volume)
    }

    /// Adds a master audio filter applied to all mixed audio before encoding.
    public func addFilter(_ filter: any AudioFilter) {
        filters.append(filter)
    }

    /// Removes all master audio filters from the mixer.
    public func removeFilters() {
        filters.removeAll()
    }

    /// Pulls 20ms Float PCM samples from all active tracks, scales each by its volume,
    /// and mixes them into a single stereo 20ms frame (1920 samples).
    public func nextPCMFrame() async -> [Float]? {
        guard !activeTracks.isEmpty else { return nil }

        // Fast zero-fill of the preallocated scratch buffer
        mixBuffer.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }

        var activeCount = 0
        var finishedIDs: [UUID] = []

        for track in activeTracks {
            let state = await track.state
            if state == .stopped || state == .ended {
                finishedIDs.append(track.id)
                continue
            }
            guard state == .playing else { continue }

            if let pcm = await track.nextPCMFrame() {
                activeCount += 1
                let vol = await track.volume
                let count = min(pcm.count, AudioConstants.frameSampleCount)
                for i in 0..<count {
                    mixBuffer[i] += pcm[i] * vol
                }
            } else {
                finishedIDs.append(track.id)
            }
        }

        if !finishedIDs.isEmpty {
            activeTracks.removeAll { finishedIDs.contains($0.id) }
        }

        guard activeCount > 0 else {
            return nil
        }

        if masterVolume != 1.0 {
            for i in 0..<mixBuffer.count {
                mixBuffer[i] *= masterVolume
            }
        }

        if !filters.isEmpty {
            for filter in filters {
                filter.process(pcm: &mixBuffer)
            }
        }

        for i in 0..<mixBuffer.count {
            mixBuffer[i] = max(-1.0, min(1.0, mixBuffer[i]))
        }

        return mixBuffer
    }

    /// Returns the next 20ms Opus frame for transmission over UDP.
    public func nextFrame() async -> [UInt8]? {
        guard !activeTracks.isEmpty else { return nil }

        if activeTracks.count == 1 && masterVolume == 1.0 && filters.isEmpty {
            let track = activeTracks[0]
            let state = await track.state
            let volume = await track.volume
            let isOpusNative = await track.isOpusNative
            if state == .playing && volume == 1.0 && isOpusNative {
                if let frame = await track.nextFrame() {
                    return frame
                } else {
                    activeTracks.removeAll()
                    return nil
                }
            }
        }

        guard let pcm = await nextPCMFrame() else {
            return nil
        }

        if encoder == nil {
            encoder = try? OpusEncoder(channels: AudioConstants.channelCount, configuration: configuration)
        }

        guard let encoder else {
            logger.debug("AudioMixer encoder unavailable")
            return nil
        }

        do {
            let packet = try encoder.encode(frame: pcm)
            return packet.bytes
        } catch {
            logger.debug("AudioMixer failed to encode Opus frame", metadata: ["error": .string("\(error)")])
            return nil
        }
    }
}
