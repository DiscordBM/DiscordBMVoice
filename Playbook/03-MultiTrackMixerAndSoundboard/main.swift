import DiscordBM
import DiscordGateway
import DiscordModels
import DiscordVoice
import Foundation
import Logging

@main
struct SoundboardBot {
    static func main() async throws {
        var logger = Logger(label: "SoundboardBot")
        logger.logLevel = .info

        guard let token = ProcessInfo.processInfo.environment["BOT_TOKEN"], !token.isEmpty else {
            logger.error("Missing BOT_TOKEN environment variable.")
            return
        }

        // 1. Preload soundboard clips into memory at startup
        do {
            try await SoundboardCache.shared.preload(
                key: "airhorn",
                file: "sounds/airhorn.mp3",
                kind: .opus
            )
            try await SoundboardCache.shared.preload(
                key: "applause",
                file: "sounds/applause.wav",
                kind: .opus
            )
            logger.info("Preloaded soundboard clips into memory.")
        } catch {
            logger.warning("Could not preload some soundboard clips: \(error)")
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
        case "bgm":
            await handleBGM(interaction: interaction, cmd: cmd, guildID: guildID)
        case "sfx":
            await handleSFX(interaction: interaction, cmd: cmd, guildID: guildID)
        case "stop":
            await handleStop(interaction: interaction, guildID: guildID)
        default:
            break
        }
    }

    private func handleBGM(
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
            let file = cmd.option(named: "file")?.value?.asString ?? "bgm.mp3"

            // Play background music at 30% volume
            let bgm = try await connection.playFile(file, title: "Background Music")
            await bgm.setVolume(0.30)
            await bgm.setLooping(true)

            // Enable auto-ducking so music fades when people speak
            await connection.enableAutoDucking(duckVolume: 0.15, onSpeaking: true)

            await respond(interaction, text: "Playing looping BGM at 30% volume with auto-ducking enabled.")
        } catch {
            await respond(interaction, text: "Failed to play BGM: \(error.localizedDescription)")
        }
    }

    private func handleSFX(
        interaction: Interaction,
        cmd: Interaction.ApplicationCommand,
        guildID: GuildSnowflake
    ) async {
        guard let connection = await voiceManager.connection(for: guildID) else {
            await respond(interaction, text: "Bot is not currently in a voice channel.")
            return
        }

        let clipKey = cmd.option(named: "clip")?.value?.asString ?? "airhorn"
        await connection.playSoundboard(key: clipKey, volume: 1.0)
        await respond(interaction, text: "Triggered soundboard clip: \(clipKey)")
    }

    private func handleStop(interaction: Interaction, guildID: GuildSnowflake) async {
        await voiceManager.leave(guildID: guildID)
        await respond(interaction, text: "Disconnected.")
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
