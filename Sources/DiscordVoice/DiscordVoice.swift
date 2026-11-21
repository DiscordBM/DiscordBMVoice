@_exported import DiscordBMVoice
@_exported import DiscordCore
@_exported import DiscordGateway
@_exported import DiscordModels
import NIOCore
import NIOPosix

// MARK: - Snowflake Conversions

extension DiscordBMVoice.Snowflake {
    public init(_ snowflake: GuildSnowflake) {
        self = DiscordBMVoice.Snowflake(snowflake.rawValue) ?? 0
    }

    public init(_ snowflake: ChannelSnowflake) {
        self = DiscordBMVoice.Snowflake(snowflake.rawValue) ?? 0
    }

    public init(_ snowflake: UserSnowflake) {
        self = DiscordBMVoice.Snowflake(snowflake.rawValue) ?? 0
    }

    public var asGuildSnowflake: GuildSnowflake {
        GuildSnowflake(self.description)
    }

    public var asChannelSnowflake: ChannelSnowflake {
        ChannelSnowflake(self.description)
    }

    public var asUserSnowflake: UserSnowflake {
        UserSnowflake(self.description)
    }
}

// MARK: - DiscordBM Gateway Extensions

extension VoiceManager {

    /// Convenience initializer for DiscordBM's `GatewayManager`.
    public init(
        gateway: any GatewayManager,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        userID: UserSnowflake,
        config: VoiceConfiguration = .init()
    ) {
        self.init(
            eventLoopGroup: eventLoopGroup,
            userID: DiscordBMVoice.Snowflake(userID),
            config: config,
            sendVoiceStateUpdate: { update in
                await gateway.updateVoiceState(
                    payload: .init(
                        guildId: update.guildID.asGuildSnowflake,
                        channelId: update.channelID?.asChannelSnowflake,
                        selfMute: update.selfMute,
                        selfDeaf: update.selfDeaf
                    )
                )
            }
        )
    }

    /// Convenience method to route DiscordBM gateway events directly.
    public func handleEvent(_ event: Gateway.Event) async {
        switch event.data {
        case .voiceStateUpdate(let voiceState):
            await self.handleVoiceStateUpdate(
                guildID: DiscordBMVoice.Snowflake(voiceState.guild_id),
                channelID: voiceState.channel_id.map { DiscordBMVoice.Snowflake($0) },
                userID: DiscordBMVoice.Snowflake(voiceState.user_id),
                sessionID: voiceState.session_id
            )
        case .voiceServerUpdate(let serverUpdate):
            await self.handleVoiceServerUpdate(
                guildID: DiscordBMVoice.Snowflake(serverUpdate.guild_id),
                endpoint: serverUpdate.endpoint,
                token: serverUpdate.token
            )
        default:
            break
        }
    }

    /// Joins a voice channel using DiscordBM's snowflake types.
    public func join(
        guildID: GuildSnowflake,
        channelID: ChannelSnowflake,
        selfMute: Bool = false,
        selfDeaf: Bool = false
    ) async throws -> VoiceConnection {
        try await self.join(
            guildID: DiscordBMVoice.Snowflake(guildID),
            channelID: DiscordBMVoice.Snowflake(channelID),
            selfMute: selfMute,
            selfDeaf: selfDeaf
        )
    }

    /// Leaves a voice channel using DiscordBM's guild snowflake.
    public func leave(guildID: GuildSnowflake) async {
        await self.leave(guildID: DiscordBMVoice.Snowflake(guildID))
    }

    /// Returns the active voice connection for a DiscordBM guild snowflake.
    public func connection(for guildID: GuildSnowflake) -> VoiceConnection? {
        self.connection(for: DiscordBMVoice.Snowflake(guildID))
    }

    /// Automatically routes voice events from a gateway manager in a background task.
    @discardableResult
    public nonisolated func forwardEvents(from gateway: any GatewayManager) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            for await event in await gateway.events {
                await self.handleEvent(event)
            }
        }
    }

    /// Looks up the voice channel a user is currently in within a guild.
    public func voiceChannel(for userID: UserSnowflake, in guildID: GuildSnowflake) -> ChannelSnowflake? {
        self.voiceChannel(for: DiscordBMVoice.Snowflake(userID), in: DiscordBMVoice.Snowflake(guildID))
            .map { ChannelSnowflake($0.description) }
    }

    /// Returns a snapshot of all users currently in voice channels within a guild.
    public func usersInVoice(in guildID: GuildSnowflake) -> [UserSnowflake: ChannelSnowflake] {
        let raw = self.usersInVoice(in: DiscordBMVoice.Snowflake(guildID))
        var result: [UserSnowflake: ChannelSnowflake] = [:]
        for (u, c) in raw {
            result[UserSnowflake(u.description)] = ChannelSnowflake(c.description)
        }
        return result
    }

    /// Returns an async stream of decoded 20ms Float PCM audio frames for a DiscordBM user.
    public func pcmStream(for userID: UserSnowflake, in guildID: GuildSnowflake) async -> AsyncStream<[Float]>? {
        await self.pcmStream(for: DiscordBMVoice.Snowflake(userID), in: DiscordBMVoice.Snowflake(guildID))
    }
}

// MARK: - GatewayManager Voice Extensions

extension GatewayManager {
    /// Binds this gateway manager to a `VoiceManager`, forwarding all voice events automatically.
    @discardableResult
    public func bind(to voiceManager: VoiceManager) -> Task<Void, Never> {
        voiceManager.forwardEvents(from: self)
    }
}

// MARK: - Snowflake Convenience Extensions

extension ChannelSnowflake {
    /// Joins this voice channel using the given VoiceManager.
    public func joinVoice(
        in guildID: GuildSnowflake,
        using voiceManager: VoiceManager,
        selfMute: Bool = false,
        selfDeaf: Bool = false
    ) async throws -> VoiceConnection {
        try await voiceManager.join(guildID: guildID, channelID: self, selfMute: selfMute, selfDeaf: selfDeaf)
    }
}

extension GuildSnowflake {
    /// Leaves the voice channel in this guild.
    public func leaveVoice(using voiceManager: VoiceManager) async {
        await voiceManager.leave(guildID: self)
    }

    /// Returns the active voice connection for this guild, if any.
    public func voiceConnection(using voiceManager: VoiceManager) async -> VoiceConnection? {
        await voiceManager.connection(for: self)
    }
}

// MARK: - VoiceConnection DiscordBM Overloads

extension VoiceConnection {
    public var guildIDSnowflake: GuildSnowflake {
        GuildSnowflake(self.guildID.description)
    }

    public var channelIDSnowflake: ChannelSnowflake? {
        self.channelID.map { ChannelSnowflake($0.description) }
    }

    public var userIDSnowflake: UserSnowflake {
        UserSnowflake(self.userID.description)
    }

    /// Returns an async stream of decrypted Opus audio frames for a DiscordBM user.
    public func audioStream(for userID: UserSnowflake) async -> AsyncStream<[UInt8]> {
        await self.audioStream(for: DiscordBMVoice.Snowflake(userID))
    }

    /// Returns an async stream of decoded 20ms Float PCM audio frames for a DiscordBM user.
    public func pcmStream(for userID: UserSnowflake) async -> AsyncStream<[Float]> {
        await self.pcmStream(for: DiscordBMVoice.Snowflake(userID))
    }
}

// MARK: - TrackMetadata DiscordBM Extensions

extension TrackMetadata {
    /// Convenience initializer accepting a DiscordBM `UserSnowflake` for requester ID.
    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: Duration? = nil,
        thumbnailURL: String? = nil,
        sourceURL: String? = nil,
        uploader: String? = nil,
        requester: UserSnowflake?,
        custom: [String: String] = [:]
    ) {
        self.init(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            thumbnailURL: thumbnailURL,
            sourceURL: sourceURL,
            uploader: uploader,
            requesterID: requester.flatMap { DiscordBMVoice.Snowflake($0) },
            custom: custom
        )
    }
}

// MARK: - Interaction Voice Helper

extension Interaction {
    /// Returns the voice channel of the interaction author, if currently in a voice channel.
    public func memberVoiceChannel(using voiceManager: VoiceManager) async -> ChannelSnowflake? {
        guard let guildID = self.guild_id,
            let userID = self.member?.user?.id ?? self.user?.id
        else {
            return nil
        }
        return await voiceManager.voiceChannel(for: userID, in: guildID)
    }
}
