/// https://discord.com/developers/docs/topics/voice-connections#speaking
public struct SpeakingUpdate: Sendable, Equatable {
    public var userID: UserID
    public var ssrc: UInt32
    public var flags: SpeakingFlags

    public var isSpeaking: Bool {
        !flags.isEmpty
    }

    public init(userID: UserID, ssrc: UInt32, flags: SpeakingFlags) {
        self.userID = userID
        self.ssrc = ssrc
        self.flags = flags
    }
}
