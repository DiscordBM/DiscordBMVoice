import Audio
import Foundation

/// Audio source that decodes local or in-memory audio (MP3, WAV, FLAC) into 20ms Opus frames.
public actor AudioSource: ResettableOpusFrameProvider, ResettablePCMFrameProvider, SeekableAudioProvider {

    private let input: AudioInput
    private let configuration: OpusConfiguration
    private var decoder: AudioDecoder
    private var stream: OpusPacketStream
    private var pcmChunker = FrameChunker()
    private var isClosed = false

    /// Audio metadata (sample rate, channels, duration).
    public let info: AudioFileInfo

    /// Duration in seconds, if available from the file headers.
    public var durationSeconds: Double? {
        info.durationSeconds
    }

    /// Duration as a `Duration` struct, if available from the file headers.
    public var duration: Duration? {
        guard let s = info.durationSeconds else { return nil }
        let sec = Int64(s)
        let atto = Int64((s - Double(sec)) * 1e18)
        return Duration(secondsComponent: sec, attosecondsComponent: atto)
    }

    /// Sample rate of the source audio (resampled to 48kHz).
    public var sourceSampleRate: Int {
        info.sourceSampleRate
    }

    /// Number of channels in the source audio (upmixed to stereo).
    public var sourceChannels: Int {
        info.sourceChannels
    }

    /// Initializes an audio source from a file on disk.
    ///
    /// - Parameters:
    ///   - path: Path to an MP3, WAV, or FLAC audio file.
    ///   - configuration: Opus encoder configuration (.music by default).
    public init(path: String, configuration: OpusConfiguration = .music) throws {
        self.input = .file(path)
        self.configuration = configuration
        let dec = try AudioDecoder(path: path)
        self.decoder = dec
        self.info = dec.info
        self.stream = try OpusPacketStream(dec, configuration: configuration)
    }

    /// Initializes an audio source from a local file URL.
    public init(url: URL, configuration: OpusConfiguration = .music) throws {
        try self.init(path: url.path, configuration: configuration)
    }

    /// Initializes an audio source from in-memory audio bytes.
    public init(bytes: [UInt8], configuration: OpusConfiguration = .music) throws {
        self.input = .memory(bytes)
        self.configuration = configuration
        let dec = try AudioDecoder(bytes: bytes)
        self.decoder = dec
        self.info = dec.info
        self.stream = try OpusPacketStream(dec, configuration: configuration)
    }

    /// Initializes an audio source from in-memory Data.
    public init(data: Data, configuration: OpusConfiguration = .music) throws {
        try self.init(bytes: [UInt8](data), configuration: configuration)
    }

    /// Initializes an audio source with custom AudioInput.
    public init(input: AudioInput, configuration: OpusConfiguration = .music) throws {
        self.input = input
        self.configuration = configuration
        let dec = try AudioDecoder(input: input)
        self.decoder = dec
        self.info = dec.info
        self.stream = try OpusPacketStream(dec, configuration: configuration)
    }

    /// Reads the next 20ms Opus frame. Returns nil when playback finishes.
    public func nextFrame() async -> [UInt8]? {
        guard !isClosed else { return nil }
        do {
            if let packet = try stream.next() {
                return packet.bytes
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Reads the next 20ms Float PCM frame (1920 samples). Returns nil when playback finishes.
    public func nextPCMFrame() async -> [Float]? {
        guard !isClosed else { return nil }
        while pcmChunker.bufferedSampleCount < pcmChunker.frameSampleCount {
            do {
                let samples = try decoder.read(frames: pcmChunker.samplesPerChannel)
                if samples.isEmpty {
                    return pcmChunker.finish(padWithSilence: true)
                }
                pcmChunker.append(samples)
            } catch {
                return nil
            }
        }
        return pcmChunker.nextFrame()
    }

    /// Resets playback back to the beginning.
    public func reset() async {
        guard !isClosed else { return }
        stream.close()
        decoder.close()
        pcmChunker.reset()
        do {
            let dec = try AudioDecoder(input: input)
            self.decoder = dec
            self.stream = try OpusPacketStream(dec, configuration: configuration)
        } catch {
            // Re-opening failed, stream remains closed
        }
    }

    /// Seeks to a specific timestamp in seconds.
    public func seek(to seconds: Double) throws {
        guard !isClosed else { throw AudioSeekError.streamClosed }
        let targetSeconds = max(0.0, seconds)
        if let duration = info.durationSeconds, targetSeconds > duration {
            throw AudioSeekError.targetOutOfBounds(requested: seconds, duration: duration)
        }
        stream.close()
        decoder.close()
        pcmChunker.reset()
        let dec = try AudioDecoder(input: input)
        let targetFrame = Int(targetSeconds * Double(dec.outputSampleRate))
        try dec.seek(toFrame: targetFrame)
        self.decoder = dec
        self.stream = try OpusPacketStream(dec, configuration: configuration)
    }

    /// Seeks to a specific Duration.
    public func seek(to duration: Duration) throws {
        let (sec, atto) = duration.components
        let seconds = Double(sec) + (Double(atto) * 1e-18)
        try seek(to: seconds)
    }

    /// Seeks to a specific PCM frame index.
    public func seek(toFrame frame: Int) throws {
        guard !isClosed else { throw AudioSeekError.streamClosed }
        stream.close()
        decoder.close()
        pcmChunker.reset()
        let dec = try AudioDecoder(input: input)
        try dec.seek(toFrame: max(0, frame))
        self.decoder = dec
        self.stream = try OpusPacketStream(dec, configuration: configuration)
    }

    /// Closes the decoder and stream, releasing native resources.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        pcmChunker.reset()
        stream.close()
        decoder.close()
    }

    public static func file(_ path: String, configuration: OpusConfiguration = .music) throws -> AudioSource {
        try AudioSource(path: path, configuration: configuration)
    }

    public static func data(_ data: Data, configuration: OpusConfiguration = .music) throws -> AudioSource {
        try AudioSource(data: data, configuration: configuration)
    }

    public static func bytes(_ bytes: [UInt8], configuration: OpusConfiguration = .music) throws -> AudioSource {
        try AudioSource(bytes: bytes, configuration: configuration)
    }
}

public typealias AudioFileSource = AudioSource
public typealias AudioMemorySource = AudioSource
public typealias FileSource = AudioSource
public typealias MemorySource = AudioSource
