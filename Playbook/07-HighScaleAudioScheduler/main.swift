import DiscordBM
import DiscordGateway
import DiscordModels
import DiscordVoice
import Foundation
import Logging

@main
struct HighScaleVoiceBot {
    static func main() async throws {
        var logger = Logger(label: "HighScaleVoiceBot")
        logger.logLevel = .info

        guard let token = ProcessInfo.processInfo.environment["BOT_TOKEN"], !token.isEmpty else {
            logger.error("Missing BOT_TOKEN environment variable.")
            return
        }

        // Configure high-scale scheduler with 32 guilds per worker loop
        let config = VoiceConfiguration.highScale(guildsPerWorker: 32)

        let bot = await BotGatewayManager(
            token: token,
            intents: [.guilds, .guildVoiceStates, .guildMessages]
        )

        let botUserID = try await bot.client.getOwnUser().decode().id

        let voiceManager = VoiceManager(
            gateway: bot,
            userID: botUserID,
            config: config
        )

        bot.bind(to: voiceManager)
        logger.info("Initialized high-scale VoiceManager with 32 guilds per worker.")

        await bot.connect()
    }
}
