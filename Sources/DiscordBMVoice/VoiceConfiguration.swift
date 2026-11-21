import Foundation
import Logging

/// Configuration for a voice connection and voice gateway.
public struct VoiceConfiguration: Sendable {

    /// Timeout for joining a voice channel and completing the full handshake.
    public var joinTimeout: Duration

    /// Maximum number of reconnect attempts before the connection is closed permanently.
    public var maxReconnectAttempts: Int

    /// Multi-guild audio scheduler coordinating 20ms audio transmission across guilds.
    /// When `nil`, each connection runs an independent timer loop.
    public var audioScheduler: AudioScheduler?

    /// Optional custom Opus decoder for decoding inbound audio frames in `pcmStream`.
    public var customOpusDecoder: (any CustomOpusDecoder)?

    /// Factory closure for creating loggers.
    public var makeLogger: @Sendable (String) -> Logger

    /// - Parameters:
    ///   - joinTimeout: Timeout for joining a voice channel and completing the full handshake.
    ///   - maxReconnectAttempts: Maximum reconnect attempts before giving up.
    ///   - audioScheduler: Optional shared audio scheduler for batch guild pacing.
    ///   - customOpusDecoder: Optional custom decoder for inbound PCM stream decoding.
    ///   - makeLogger: Custom logger factory closure.
    public init(
        joinTimeout: Duration = .seconds(30),
        maxReconnectAttempts: Int = 5,
        audioScheduler: AudioScheduler? = nil,
        customOpusDecoder: (any CustomOpusDecoder)? = nil,
        makeLogger: @escaping @Sendable (String) -> Logger = { label in
            Logger(label: "DiscordBMVoice.\(label)")
        }
    ) {
        self.joinTimeout = joinTimeout
        self.maxReconnectAttempts = maxReconnectAttempts
        self.audioScheduler = audioScheduler
        self.customOpusDecoder = customOpusDecoder
        self.makeLogger = makeLogger
    }

    /// Configuration preset optimized for high-scale bots with hundreds or thousands of guilds.
    /// Paces multiple guilds per worker loop to minimize timer wakeups and scheduling jitter.
    public static func highScale(
        guildsPerWorker: Int = 16,
        scheduler: AudioScheduler = .shared
    ) -> VoiceConfiguration {
        var config = VoiceConfiguration()
        config.audioScheduler = scheduler
        return config
    }
}
