import DiscordBM
import DiscordGateway
import DiscordModels
import DiscordVoice
import Foundation
import Logging

struct BassBooster: AudioFilter, Sendable {
    let factor: Float
    func process(_ pcm: inout [Float]) {
        for i in 0..<pcm.count {
            pcm[i] = max(-1.0, min(1.0, pcm[i] * factor))
        }
    }
}

@main
struct FilterBot {
    static func main() async throws {
        var logger = Logger(label: "FilterBot")
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
        case "play-boosted":
            await handlePlayBoosted(interaction: interaction, cmd: cmd, guildID: guildID)
        case "stop":
            await voiceManager.leave(guildID: guildID)
            await respond(interaction, text: "Disconnected.")
        default:
            break
        }
    }

    private func handlePlayBoosted(
        interaction: Interaction,
        cmd: Interaction.ApplicationCommand,
        guildID: GuildSnowflake
    ) async {
        guard let channelID = await interaction.memberVoiceChannel(using: voiceManager) else {
            await respond(interaction, text: "You must be in a voice channel.")
            return
        }

        do {
            let connection = try await channelID.joinVoice(in: guildID, using: voiceManager)
            let file = cmd.option(named: "file")?.value?.asString ?? "music.mp3"

            let handle = try await connection.playFile(file, title: "Boosted Track")

            // Attach per-track bass boost filter
            await handle.addFilter(BassBooster(factor: 1.5))

            // Attach master soft limiter to prevent audio clipping
            await connection.addFilter(SoftLimiterFilter(threshold: 0.90))

            await respond(interaction, text: "Playing '\(file)' with 1.5x bass boost and master soft limiter.")
        } catch {
            await respond(interaction, text: "Failed to play: \(error.localizedDescription)")
        }
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
