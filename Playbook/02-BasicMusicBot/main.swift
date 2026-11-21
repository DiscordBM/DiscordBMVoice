import DiscordBM
import DiscordGateway
import DiscordModels
import DiscordVoice
import Foundation
import Logging

@main
struct BasicMusicBot {
    static func main() async throws {
        var logger = Logger(label: "BasicMusicBot")
        logger.logLevel = .info

        guard let token = ProcessInfo.processInfo.environment["BOT_TOKEN"], !token.isEmpty else {
            logger.error("Missing BOT_TOKEN environment variable.")
            return
        }

        let bot = await BotGatewayManager(
            token: token,
            intents: [.guilds, .guildVoiceStates, .guildMessages]
        )

        let botUserID = try await bot.client.getOwnUser().decode().id

        let voiceManager = VoiceManager(
            gateway: bot,
            userID: botUserID
        )

        bot.bind(to: voiceManager)

        await withTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask {
                await bot.connect()
            }

            taskGroup.addTask {
                for await event in await bot.events {
                    await EventHandler(
                        event: event,
                        client: bot.client,
                        voiceManager: voiceManager,
                        logger: logger
                    ).handleAsync()
                }
            }
        }
    }
}

struct EventHandler: GatewayEventHandler {
    let event: Gateway.Event
    let client: any DiscordClient
    let voiceManager: VoiceManager
    let logger: Logger

    func onInteractionCreate(_ interaction: Interaction) async throws {
        guard case .applicationCommand(let cmd) = interaction.data,
            let guildID = interaction.guild_id
        else { return }

        switch cmd.name {
        case "play":
            await handlePlay(interaction: interaction, cmd: cmd, guildID: guildID)
        case "pause":
            await handlePause(interaction: interaction, guildID: guildID)
        case "resume":
            await handleResume(interaction: interaction, guildID: guildID)
        case "skip":
            await handleSkip(interaction: interaction, guildID: guildID)
        case "seek":
            await handleSeek(interaction: interaction, cmd: cmd, guildID: guildID)
        case "queue":
            await handleQueue(interaction: interaction, guildID: guildID)
        case "stop":
            await handleStop(interaction: interaction, guildID: guildID)
        default:
            break
        }
    }

    private func handlePlay(
        interaction: Interaction,
        cmd: Interaction.ApplicationCommand,
        guildID: GuildSnowflake
    ) async {
        guard let channelID = await interaction.memberVoiceChannel(using: voiceManager) else {
            await respond(interaction, text: "You must be in a voice channel to use /play.")
            return
        }

        let filePath = cmd.option(named: "file")?.value?.asString ?? "music.mp3"

        do {
            let connection = try await channelID.joinVoice(in: guildID, using: voiceManager)
            let queue = await connection.queue

            let metadata = TrackMetadata(
                title: filePath,
                requester: interaction.user?.id
            )

            let track = try AudioTrack.file(filePath, metadata: metadata)
            await queue.add(track)

            await respond(interaction, text: "Queued track: \(filePath)")
        } catch {
            logger.error("Failed to queue track: \(error)")
            await respond(interaction, text: "Playback error: \(error.localizedDescription)")
        }
    }

    private func handlePause(interaction: Interaction, guildID: GuildSnowflake) async {
        if let connection = await voiceManager.connection(for: guildID) {
            let queue = await connection.queue
            await queue.pause()
            await respond(interaction, text: "Playback paused.")
        } else {
            await respond(interaction, text: "Bot is not in a voice channel.")
        }
    }

    private func handleResume(interaction: Interaction, guildID: GuildSnowflake) async {
        if let connection = await voiceManager.connection(for: guildID) {
            let queue = await connection.queue
            await queue.resume()
            await respond(interaction, text: "Playback resumed.")
        } else {
            await respond(interaction, text: "Bot is not in a voice channel.")
        }
    }

    private func handleSkip(interaction: Interaction, guildID: GuildSnowflake) async {
        if let connection = await voiceManager.connection(for: guildID) {
            let queue = await connection.queue
            if let skipped = await queue.skip() {
                await respond(interaction, text: "Skipped: \(skipped.title ?? "track")")
            } else {
                await respond(interaction, text: "Nothing is currently playing.")
            }
        } else {
            await respond(interaction, text: "Bot is not in a voice channel.")
        }
    }

    private func handleSeek(
        interaction: Interaction,
        cmd: Interaction.ApplicationCommand,
        guildID: GuildSnowflake
    ) async {
        guard let seconds = cmd.option(named: "seconds")?.value?.asDouble else {
            await respond(interaction, text: "Specify the number of seconds to seek.")
            return
        }

        if let connection = await voiceManager.connection(for: guildID) {
            let queue = await connection.queue
            do {
                try await queue.seek(to: .seconds(Int64(seconds)))
                await respond(interaction, text: "Jumped to \(Int(seconds))s.")
            } catch {
                await respond(interaction, text: "Seek error: \(error.localizedDescription)")
            }
        } else {
            await respond(interaction, text: "Bot is not in a voice channel.")
        }
    }

    private func handleQueue(interaction: Interaction, guildID: GuildSnowflake) async {
        guard let connection = await voiceManager.connection(for: guildID) else {
            await respond(interaction, text: "Bot is not in a voice channel.")
            return
        }

        let queue = await connection.queue
        let current = await queue.currentTrack
        let upcoming = await queue.upcomingTracks

        var message = ""
        if let current {
            let pos = await current.positionSeconds
            message += "Now Playing: \(current.metadata.title ?? "Unknown") [\(Int(pos))s]\n"
        } else {
            message += "Nothing currently playing.\n"
        }

        if !upcoming.isEmpty {
            message += "\nUpcoming:\n"
            for (idx, track) in upcoming.enumerated() {
                message += "\(idx + 1). \(track.title ?? "Unknown")\n"
            }
        }

        await respond(interaction, text: message)
    }

    private func handleStop(interaction: Interaction, guildID: GuildSnowflake) async {
        await voiceManager.leave(guildID: guildID)
        await respond(interaction, text: "Disconnected and cleared queue.")
    }

    private func respond(_ interaction: Interaction, text: String) async {
        do {
            try await client.createInteractionResponse(
                id: interaction.id,
                token: interaction.token,
                payload: .channelMessageWithSource(.init(content: text))
            ).guardSuccess()
        } catch {
            logger.error("Failed to respond to interaction: \(error)")
        }
    }
}
