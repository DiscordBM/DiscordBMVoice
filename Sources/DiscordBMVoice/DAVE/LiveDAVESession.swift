import Dave
import Foundation

/// Concrete implementation of `DAVESession` wrapping DiscordAudioKit's `DaveSession`.
final class LiveDAVESession: DAVESession, @unchecked Sendable {

    private let session: DaveSession
    private let outgoingStream: AsyncStream<OutgoingDAVEMessage>
    private let continuation: AsyncStream<OutgoingDAVEMessage>.Continuation
    private var forwardTask: Task<Void, Never>?

    init(userID: UserID, channelID: ChannelID) throws {
        let session = try DaveSession(userID: userID.rawValue, channelID: channelID.rawValue)
        self.session = session

        let (stream, continuation) = AsyncStream<OutgoingDAVEMessage>.makeStream()
        self.outgoingStream = stream
        self.continuation = continuation

        self.forwardTask = Task {
            for await msg in await session.outgoing {
                guard !Task.isCancelled else { break }
                switch msg {
                case .keyPackage(let data):
                    continuation.yield(.keyPackage(data))
                case .commitAndWelcome(let data):
                    continuation.yield(.commitAndWelcome(data))
                case .readyForTransition(let transitionID):
                    continuation.yield(
                        .readyForTransition(transitionID: UInt16(truncatingIfNeeded: transitionID))
                    )
                case .invalidCommitWelcome(let transitionID):
                    continuation.yield(
                        .invalidCommitWelcome(transitionID: UInt16(truncatingIfNeeded: transitionID))
                    )
                }
            }
            continuation.finish()
        }
    }

    var maxSupportedProtocolVersion: Int {
        Int(DaveSession.maxSupportedProtocolVersion.rawValue)
    }

    var isReady: Bool {
        get async {
            await session.isReady
        }
    }

    var outgoing: AsyncStream<OutgoingDAVEMessage> {
        outgoingStream
    }

    func acknowledgeProtocolVersion(_ version: Int) async throws {
        try await session.acknowledgeProtocolVersion(DaveProtocolVersion(rawValue: UInt16(version)))
    }

    func prepareTransition(id: UInt16, protocolVersion: Int) async throws {
        try await session.prepareTransition(
            transitionID: UInt64(id),
            protocolVersion: DaveProtocolVersion(rawValue: UInt16(protocolVersion))
        )
    }

    func executeTransition(id: UInt16) async throws {
        try await session.executeTransition(transitionID: UInt64(id))
    }

    func prepareEpoch(_ epoch: UInt32, protocolVersion: Int) async throws {
        try await session.prepareEpoch(
            UInt64(epoch),
            protocolVersion: DaveProtocolVersion(rawValue: UInt16(protocolVersion))
        )
    }

    func setExternalSender(_ data: [UInt8]) async throws {
        try await session.setExternalSender(data)
    }

    func processProposals(_ data: [UInt8]) async throws {
        try await session.processProposals(data)
    }

    func announceCommitTransition(id: UInt16, commit: [UInt8]) async throws {
        // Ensure transition is registered in transitions tracker prior to processing commit.
        try? await session.prepareTransition(transitionID: UInt64(id), protocolVersion: .v1)
        try await session.announceCommitTransition(transitionID: UInt64(id), commit: commit)
    }

    func processWelcome(id: UInt16, welcome: [UInt8]) async throws {
        // Ensure transition is registered in transitions tracker prior to processing welcome.
        try? await session.prepareTransition(transitionID: UInt64(id), protocolVersion: .v1)
        try await session.processWelcome(transitionID: UInt64(id), welcome: welcome)
    }

    func assignSSRC(_ ssrc: UInt32) async throws {
        try await session.assignSSRC(ssrc, codec: .opus)
    }

    func addUser(_ userID: UserID) async throws {
        try await session.addUser(userID: userID.rawValue)
    }

    func removeUser(_ userID: UserID) async throws {
        try await session.removeUser(userID: userID.rawValue)
    }

    func encrypt(frame: [UInt8], ssrc: UInt32) async throws -> [UInt8] {
        try await session.encrypt(frame: frame, ssrc: ssrc)
    }

    func decrypt(frame: [UInt8], userID: UserID) async throws -> [UInt8] {
        try await session.decrypt(frame: frame, userID: userID.rawValue)
    }

    func close() async {
        forwardTask?.cancel()
        continuation.finish()
        await session.close()
    }

    deinit {
        forwardTask?.cancel()
        continuation.finish()
    }
}
