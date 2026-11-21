import Foundation
import Logging
import NIOCore
import NIOPosix

/// Manages voice connections across guilds for a Discord bot.
///
/// Route events from your Discord Gateway by calling `handleVoiceStateUpdate`
/// and `handleVoiceServerUpdate`.
///
/// https://discord.com/developers/docs/topics/voice-connections
public actor VoiceManager {

    private var connections: [GuildID: VoiceConnection] = [:]
    private var userVoiceChannels: [GuildID: [UserID: ChannelID]] = [:]
    private let eventLoopGroup: any EventLoopGroup
    private let userID: UserID
    nonisolated let config: VoiceConfiguration
    private let sendVoiceStateUpdate: @Sendable (VoiceStateUpdate) async -> Void
    private let logger: Logger

    /// - Parameters:
    ///   - eventLoopGroup: An `EventLoopGroup` for UDP networking. Defaults to `MultiThreadedEventLoopGroup.singleton`.
    ///   - userID: The bot's own user snowflake.
    ///   - config: General configuration for voice connections.
    ///   - sendVoiceStateUpdate: Closure to send a voice state update over the gateway.
    public init(
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        userID: UserID,
        config: VoiceConfiguration = .init(),
        sendVoiceStateUpdate: @escaping @Sendable (VoiceStateUpdate) async -> Void
    ) {
        self.eventLoopGroup = eventLoopGroup
        self.userID = userID
        self.config = config
        self.sendVoiceStateUpdate = sendVoiceStateUpdate
        self.logger = config.makeLogger("VoiceManager")
    }

    /// Convenience initializer with explicit parameter closure.
    public init(
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        userID: UserID,
        config: VoiceConfiguration = .init(),
        sendVoiceStateUpdate:
            @escaping @Sendable (
                _ guildID: GuildID,
                _ channelID: ChannelID?,
                _ selfMute: Bool,
                _ selfDeaf: Bool
            ) async -> Void
    ) {
        self.init(
            eventLoopGroup: eventLoopGroup,
            userID: userID,
            config: config,
            sendVoiceStateUpdate: { update in
                await sendVoiceStateUpdate(
                    update.guildID,
                    update.channelID,
                    update.selfMute,
                    update.selfDeaf
                )
            }
        )
    }

    /// Joins a voice channel in the specified guild.
    ///
    /// - Parameters:
    ///   - guildID: Target guild snowflake.
    ///   - channelID: Target channel snowflake.
    ///   - selfMute: Whether the bot should be self-muted.
    ///   - selfDeaf: Whether the bot should be self-deafened.
    /// - Returns: The established `VoiceConnection`.
    public func join(
        guildID: GuildID,
        channelID: ChannelID,
        selfMute: Bool = false,
        selfDeaf: Bool = false
    ) async throws -> VoiceConnection {
        if let existing = connections[guildID] {
            if await existing.channelID == channelID, await existing.state != .disconnected(nil) {
                logger.debug(
                    "Reusing existing active voice connection",
                    metadata: [
                        "guild_id": .string(guildID.description),
                        "channel_id": .string(channelID.description),
                    ]
                )
                return existing
            }
            logger.debug(
                "Closing existing connection before joining new channel",
                metadata: ["guild_id": .string(guildID.description)]
            )
            await existing.close()
            connections.removeValue(forKey: guildID)
        }

        let connection = VoiceConnection(
            guildID: guildID,
            userID: userID,
            config: config,
            eventLoopGroup: eventLoopGroup,
            sendVoiceStateUpdate: sendVoiceStateUpdate
        )
        connections[guildID] = connection

        do {
            try await connection.open(
                channelID: channelID,
                selfMute: selfMute,
                selfDeaf: selfDeaf
            )
            return connection
        } catch {
            connections.removeValue(forKey: guildID)
            await connection.close()
            throw error
        }
    }

    /// Leaves the voice channel in the specified guild and closes the connection.
    public func leave(guildID: GuildID) async {
        guard let connection = connections.removeValue(forKey: guildID) else { return }
        logger.debug("Leaving voice channel", metadata: ["guild_id": .string(guildID.description)])
        await connection.close()
    }

    /// Disconnects from all voice channels and cleans up all active connections.
    public func leaveAll() async {
        let allConnections = Array(connections.values)
        connections.removeAll()
        logger.debug(
            "Leaving all voice channels",
            metadata: ["count": .stringConvertible(allConnections.count)]
        )
        for connection in allConnections {
            await connection.close()
        }
    }

    /// Returns the active voice connection for the given guild, if any.
    public func connection(for guildID: GuildID) -> VoiceConnection? {
        connections[guildID]
    }

    /// Returns the connection state for a guild if active.
    public func state(for guildID: GuildID) async -> VoiceConnectionState? {
        await connections[guildID]?.state
    }

    /// Returns the latest gateway ping latency for a guild if active.
    public func ping(for guildID: GuildID) async -> Duration? {
        await connections[guildID]?.ping
    }

    /// Returns a stream of speaking updates for a guild if active.
    public func speakingUpdates(for guildID: GuildID) async -> AsyncStream<SpeakingUpdate>? {
        await connections[guildID]?.speakingUpdates
    }

    /// Returns an async stream of decrypted audio frames for a specific user in a guild.
    public func audioStream(for userID: UserID, in guildID: GuildID) async -> AsyncStream<[UInt8]>? {
        await connections[guildID]?.audioStream(for: userID)
    }

    /// Feeds a `VoiceState` struct received from the Discord Gateway.
    public func handleVoiceStateUpdate(_ update: VoiceState) async {
        await handleVoiceStateUpdate(
            guildID: update.guildID,
            channelID: update.channelID,
            userID: update.userID,
            sessionID: update.sessionID
        )
    }

    /// Feeds raw Voice State Update fields from the Discord Gateway.
    public func handleVoiceStateUpdate(
        guildID: GuildID,
        channelID: ChannelID?,
        userID: UserID,
        sessionID: String
    ) async {
        logger.debug(
            "VoiceManager routing voiceStateUpdate",
            metadata: [
                "guild_id": .string(guildID.description),
                "user_id": .string(userID.description),
                "channel_id": .string(channelID?.description ?? "nil"),
                "hasConnection": .stringConvertible(connections[guildID] != nil),
            ]
        )
        // Track voice channels of all guild participants
        if let channelID {
            if userVoiceChannels[guildID] == nil {
                userVoiceChannels[guildID] = [:]
            }
            userVoiceChannels[guildID]?[userID] = channelID
        } else {
            userVoiceChannels[guildID]?.removeValue(forKey: userID)
        }

        guard userID == self.userID else { return }
        if channelID == nil {
            logger.debug(
                "Bot disconnected from voice channel by server",
                metadata: ["guild_id": .string(guildID.description)]
            )
            if let conn = connections.removeValue(forKey: guildID) {
                await conn.close()
            }
            return
        }
        await connections[guildID]?.handleVoiceStateUpdate(sessionID: sessionID, channelID: channelID)
    }

    /// Looks up the voice channel a user is currently in within a guild.
    public func voiceChannel(for userID: UserID, in guildID: GuildID) -> ChannelID? {
        userVoiceChannels[guildID]?[userID]
    }

    /// Returns a snapshot mapping of all users currently in voice channels within a guild.
    public func usersInVoice(in guildID: GuildID) -> [UserID: ChannelID] {
        userVoiceChannels[guildID] ?? [:]
    }

    /// Returns an async stream of decoded 20ms Float PCM audio frames for a specific user.
    public func pcmStream(for userID: UserID, in guildID: GuildID) async -> AsyncStream<[Float]>? {
        await connections[guildID]?.pcmStream(for: userID)
    }

    /// Feeds a `VoiceServerUpdate` struct received from the Discord Gateway.
    public func handleVoiceServerUpdate(_ update: VoiceServerUpdate) async {
        await handleVoiceServerUpdate(
            guildID: update.guildID,
            endpoint: update.endpoint,
            token: update.token
        )
    }

    /// Feeds raw Voice Server Update fields from the Discord Gateway.
    public func handleVoiceServerUpdate(
        guildID: GuildID,
        endpoint: String?,
        token: String
    ) async {
        logger.debug(
            "VoiceManager routing voiceServerUpdate",
            metadata: [
                "guild_id": .string(guildID.description),
                "endpoint": .string(endpoint ?? "nil"),
                "hasConnection": .stringConvertible(connections[guildID] != nil),
            ]
        )
        await connections[guildID]?.handleVoiceServerUpdate(endpoint: endpoint, token: token)
    }

    /// The active audio scheduler, if configured.
    public nonisolated var audioScheduler: AudioScheduler? {
        config.audioScheduler
    }
}
