import DiscordBMVoice
import Foundation
import Vapor

@main
struct VaporVoiceApp {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)

        defer {
            Task {
                try? await app.asyncShutdown()
            }
        }

        let botUserID = Snowflake("123456789012345678") ?? 0

        // Initialize VoiceManager sharing Vapor's eventLoopGroup
        let voiceManager = VoiceManager(
            eventLoopGroup: app.eventLoopGroup,
            userID: botUserID
        ) { update in
            // Send gateway voice state update through your bot's gateway
            app.logger.info("Gateway voice state update: guild=\(update.guildID) channel=\(String(describing: update.channelID))")
        }

        // POST /api/voice/play
        app.post("api", "voice", "play") { req async throws -> HTTPStatus in
            struct RequestBody: Content {
                let guildID: String
                let channelID: String
                let file: String
            }

            let body = try req.content.decode(RequestBody.self)
            guard let guildID = Snowflake(body.guildID),
                let channelID = Snowflake(body.channelID)
            else {
                throw Abort(.badRequest, reason: "Invalid guildID or channelID")
            }

            let connection = try await voiceManager.join(guildID: guildID, channelID: channelID)
            _ = try await connection.playFile(body.file, title: body.file)

            return .ok
        }

        // POST /api/voice/stop
        app.post("api", "voice", "stop") { req async throws -> HTTPStatus in
            struct StopBody: Content {
                let guildID: String
            }
            let body = try req.content.decode(StopBody.self)
            guard let guildID = Snowflake(body.guildID) else {
                throw Abort(.badRequest, reason: "Invalid guildID")
            }

            await voiceManager.leave(guildID: guildID)
            return .ok
        }

        try await app.execute()
    }
}
