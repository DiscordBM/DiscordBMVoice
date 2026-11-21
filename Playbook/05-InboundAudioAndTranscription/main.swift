import DiscordBM
import DiscordGateway
import DiscordModels
import DiscordVoice
import Foundation
import Logging

@main
struct TranscriptionBot {
    static func main() async throws {
        var logger = Logger(label: "TranscriptionBot")
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
        case "listen":
            await handleListen(interaction: interaction, guildID: guildID)
        case "stop":
            await voiceManager.leave(guildID: guildID)
            await respond(interaction, text: "Stopped listening and left channel.")
        default:
            break
        }
    }

    private func handleListen(interaction: Interaction, guildID: GuildSnowflake) async {
        guard let channelID = await interaction.memberVoiceChannel(using: voiceManager) else {
            await respond(interaction, text: "You must be in a voice channel.")
            return
        }

        do {
            let connection = try await channelID.joinVoice(in: guildID, using: voiceManager)

            // VAD meter with -35 dBFS threshold and 10 frames hangover
            let vad = VoiceActivityDetector(thresholdDB: -35.0, hangoverFrames: 10)

            // Subscribe to channel-wide inbound Float PCM
            let pcmStream = await connection.pcmStream()

            Task {
                for await (userID, pcmFrame) in pcmStream {
                    let isSpeaking = vad.process(pcmFrame)
                    if isSpeaking {
                        // Deliver frame to Whisper / Speech-to-Text inference engine
                        logger.info("Received \(pcmFrame.count) PCM samples from User \(userID)")
                    }
                }
            }

            // Monitor speaking updates
            Task {
                for await update in await connection.speakingUpdates {
                    logger.info("Speaking update: User \(update.userID) isSpeaking=\(update.isSpeaking)")
                }
            }

            await respond(interaction, text: "Listening in voice channel. Transcribing audio...")
        } catch {
            await respond(interaction, text: "Failed to join: \(error.localizedDescription)")
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
