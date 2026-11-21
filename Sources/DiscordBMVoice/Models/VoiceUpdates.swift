/// https://discord.com/developers/docs/topics/gateway-events#update-voice-state
public struct VoiceStateUpdate: Sendable, Codable, Equatable {
    public var guildID: GuildID
    public var channelID: ChannelID?
    public var selfMute: Bool
    public var selfDeaf: Bool

    public init(
        guildID: GuildID,
        channelID: ChannelID?,
        selfMute: Bool = false,
        selfDeaf: Bool = false
    ) {
        self.guildID = guildID
        self.channelID = channelID
        self.selfMute = selfMute
        self.selfDeaf = selfDeaf
    }
}

/// https://discord.com/developers/docs/topics/gateway-events#voice-server-update
public struct VoiceServerUpdate: Sendable, Codable, Equatable {
    public var guildID: GuildID
    public var token: String
    public var endpoint: String?

    public init(guildID: GuildID, token: String, endpoint: String?) {
        self.guildID = guildID
        self.token = token
        self.endpoint = endpoint
    }
}

/// https://discord.com/developers/docs/resources/voice#voice-state-object
public struct VoiceState: Sendable, Codable, Equatable {
    public var guildID: GuildID
    public var channelID: ChannelID?
    public var userID: UserID
    public var sessionID: String

    public init(
        guildID: GuildID,
        channelID: ChannelID?,
        userID: UserID,
        sessionID: String
    ) {
        self.guildID = guildID
        self.channelID = channelID
        self.userID = userID
        self.sessionID = sessionID
    }
}
