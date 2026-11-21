import DiscordCore
import DiscordGateway
import DiscordModels
import DiscordVoice
import Foundation
import Testing

@Suite("DiscordVoice Target Integration Tests")
struct DiscordVoiceTests {

    @Test("Snowflake bidirectional conversions between DiscordBM and DiscordBMVoice")
    func snowflakeConversions() {
        let rawID = "123456789012345678"
        let guildSnowflake = GuildSnowflake(rawID)
        let channelSnowflake = ChannelSnowflake(rawID)
        let userSnowflake = UserSnowflake(rawID)

        let bmGuild = DiscordBMVoice.Snowflake(guildSnowflake)
        let bmChannel = DiscordBMVoice.Snowflake(channelSnowflake)
        let bmUser = DiscordBMVoice.Snowflake(userSnowflake)

        #expect(bmGuild.description == rawID)
        #expect(bmChannel.description == rawID)
        #expect(bmUser.description == rawID)

        #expect(bmGuild.asGuildSnowflake == guildSnowflake)
        #expect(bmChannel.asChannelSnowflake == channelSnowflake)
        #expect(bmUser.asUserSnowflake == userSnowflake)
    }

    @Test("VoiceManager tracks user voice channels and exposes lookup")
    func voiceManagerUserTracking() async {
        let vm = VoiceManager(userID: 100) { _ in }

        let guildID: GuildSnowflake = "111222333444555"
        let channelID: ChannelSnowflake = "999888777666555"
        let userID: UserSnowflake = "123123123123123"

        // Initially unknown
        #expect(await vm.voiceChannel(for: userID, in: guildID) == nil)
        #expect(await vm.usersInVoice(in: guildID).isEmpty)

        // Route a user joining a voice channel
        await vm.handleVoiceStateUpdate(
            guildID: DiscordBMVoice.Snowflake(guildID),
            channelID: DiscordBMVoice.Snowflake(channelID),
            userID: DiscordBMVoice.Snowflake(userID),
            sessionID: "test_session"
        )

        #expect(await vm.voiceChannel(for: userID, in: guildID) == channelID)
        let usersInVoice = await vm.usersInVoice(in: guildID)
        #expect(usersInVoice.count == 1)
        #expect(usersInVoice[userID] == channelID)

        // Route user disconnecting
        await vm.handleVoiceStateUpdate(
            guildID: DiscordBMVoice.Snowflake(guildID),
            channelID: nil,
            userID: DiscordBMVoice.Snowflake(userID),
            sessionID: "test_session"
        )

        #expect(await vm.voiceChannel(for: userID, in: guildID) == nil)
        #expect(await vm.usersInVoice(in: guildID).isEmpty)
    }

    @Test("TrackMetadata DiscordBM UserSnowflake convenience initializer")
    func trackMetadataDiscordBMSnowflake() {
        let user: UserSnowflake = "987654321098765432"
        let meta = TrackMetadata(
            title: "Song",
            artist: "Artist",
            requester: user
        )

        #expect(meta.title == "Song")
        #expect(meta.requesterID?.description == user.rawValue)
    }
}
