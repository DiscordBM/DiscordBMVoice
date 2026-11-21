/// Provides Opus-encoded audio frames for transmission.
///
/// Implement this protocol to supply audio to a voice connection.
/// The connection pulls one frame every 20 ms. Each frame must be a complete
/// Opus-encoded packet ready to send; partial or raw PCM frames are not accepted.
///
/// When no frame is available, return `nil`. The sender will transmit five silence
/// frames (`0xF8 0xFF 0xFE`) and then stop marking the bot as speaking.
public protocol OpusFrameProvider: AnyObject, Sendable {

    /// Returns the next Opus frame, or `nil` if no audio is available.
    func nextFrame() async -> [UInt8]?
}

/// An Opus frame provider that can be reset to the beginning for looping.
public protocol ResettableOpusFrameProvider: OpusFrameProvider {

    /// Resets the provider back to the beginning of the audio source.
    func reset() async
}

/// Provides 48kHz stereo 20ms Float PCM audio frames (1920 interleaved samples).
///
/// Implement this protocol to supply raw PCM audio to the mixer without prior Opus encoding.
public protocol PCMFrameProvider: AnyObject, Sendable {

    /// Returns the next 20ms stereo Float PCM frame (1920 samples: 960 left, 960 right interleaved),
    /// or `nil` if no audio is available.
    func nextPCMFrame() async -> [Float]?
}

/// A PCM frame provider that can be reset to the beginning for looping.
public protocol ResettablePCMFrameProvider: PCMFrameProvider {

    /// Resets the provider back to the beginning of the audio source.
    func reset() async
}

/// Receives decrypted, per-user Opus frames from an active voice connection.
///
/// Implement this protocol to consume incoming audio from other participants.
/// Each call delivers one complete Opus-encoded packet from the given user.
public protocol OpusFrameReceiver: AnyObject, Sendable {

    /// Delivers a decrypted Opus frame from the given user.
    ///
    /// - Parameters:
    ///   - frame: A complete Opus-encoded audio packet.
    ///   - userID: The Discord user who sent the frame.
    func receive(frame: [UInt8], from userID: UserID) async
}

/// Protocol for custom Opus decoders capable of decoding 20ms Opus packets to 48kHz stereo Float PCM.
public protocol CustomOpusDecoder: Sendable {
    /// Decodes a 20ms Opus audio packet into interleaved 48kHz stereo Float PCM samples (1,920 floats).
    func decode(packet: [UInt8]) throws -> [Float]
}

/// Closure-based custom Opus decoder.
public struct AnyOpusDecoder: CustomOpusDecoder, Sendable {
    private let _decode: @Sendable ([UInt8]) throws -> [Float]

    public init(_ decode: @escaping @Sendable ([UInt8]) throws -> [Float]) {
        self._decode = decode
    }

    public func decode(packet: [UInt8]) throws -> [Float] {
        try _decode(packet)
    }
}

/// An audio frame provider that supports seeking to a specific playback position.
public protocol SeekableAudioProvider: AnyObject, Sendable {

    /// Seeks playback to the specified position in seconds.
    func seek(to seconds: Double) async throws

    /// Seeks playback to the specified Duration.
    func seek(to duration: Duration) async throws
}

extension SeekableAudioProvider {
    public func seek(to duration: Duration) async throws {
        let (sec, atto) = duration.components
        let seconds = Double(sec) + (Double(atto) * 1e-18)
        try await seek(to: seconds)
    }
}

/// Errors thrown during audio seeking operations.
public enum AudioSeekError: Error, CustomStringConvertible, Sendable, Equatable {
    case notSeekable
    case targetOutOfBounds(requested: Double, duration: Double?)
    case streamClosed

    public var description: String {
        switch self {
        case .notSeekable:
            return "AudioSeekError.notSeekable: Underlying audio provider does not support seeking"
        case .targetOutOfBounds(let requested, let duration):
            let total = duration.map { "\($0)" } ?? "unknown"
            return "AudioSeekError.targetOutOfBounds: Requested \(requested)s exceeds duration \(total)s"
        case .streamClosed:
            return "AudioSeekError.streamClosed: Stream is closed"
        }
    }
}
