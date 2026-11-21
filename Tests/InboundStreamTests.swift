import Foundation
import Logging
import Testing

@testable import DiscordBMVoice

@Suite("Inbound Stream & Speaking Tests")
struct InboundStreamTests {

    @Test("SpeakingUpdate properly reflects speaking state and flags")
    func testSpeakingUpdateFlags() {
        let user: UserID = "123456789012345678"
        let ssrc: UInt32 = 42

        let speakingMicrophone = SpeakingUpdate(userID: user, ssrc: ssrc, flags: .microphone)
        #expect(speakingMicrophone.isSpeaking)
        #expect(speakingMicrophone.flags.contains(.microphone))
        #expect(!speakingMicrophone.flags.contains(.priority))

        let speakingPriority = SpeakingUpdate(
            userID: user,
            ssrc: ssrc,
            flags: [.microphone, .priority]
        )
        #expect(speakingPriority.isSpeaking)
        #expect(speakingPriority.flags.contains(.priority))

        let stoppedSpeaking = SpeakingUpdate(userID: user, ssrc: ssrc, flags: .none)
        #expect(!stoppedSpeaking.isSpeaking)
        #expect(stoppedSpeaking.flags.isEmpty)
    }

    @Test("AudioReceiver routes frames and manages subscriptions")
    func testAudioReceiverSubscriptions() async {
        let (packetsStream, packetsContinuation) = AsyncStream<[UInt8]>.makeStream()
        let logger = Logger(label: "test.receiver")

        final class MockDAVE: DAVESession, @unchecked Sendable {
            var maxSupportedProtocolVersion: Int { 1 }
            var isReady: Bool { false }
            var outgoing: AsyncStream<OutgoingDAVEMessage> {
                AsyncStream { $0.finish() }
            }
            func acknowledgeProtocolVersion(_ version: Int) async throws {}
            func prepareTransition(id: UInt16, protocolVersion: Int) async throws {}
            func executeTransition(id: UInt16) async throws {}
            func prepareEpoch(_ epoch: UInt32, protocolVersion: Int) async throws {}
            func setExternalSender(_ data: [UInt8]) async throws {}
            func processProposals(_ data: [UInt8]) async throws {}
            func announceCommitTransition(id: UInt16, commit: [UInt8]) async throws {}
            func processWelcome(id: UInt16, welcome: [UInt8]) async throws {}
            func assignSSRC(_ ssrc: UInt32) async throws {}
            func addUser(_ userID: UserID) async throws {}
            func removeUser(_ userID: UserID) async throws {}
            func encrypt(frame: [UInt8], ssrc: UInt32) async throws -> [UInt8] { frame }
            func decrypt(frame: [UInt8], userID: UserID) async throws -> [UInt8] { frame }
            func close() async {}
        }

        let receiver = AudioReceiver(
            packets: packetsStream,
            encryptor: AES256GCMEncryptor(),
            key: [UInt8](repeating: 0, count: 32),
            dave: MockDAVE(),
            logger: logger
        )

        let userA: UserID = "111111111111111111"
        let userB: UserID = "222222222222222222"

        await receiver.mapSSRC(100, to: userA)

        var streamA: AsyncStream<[UInt8]>? = await receiver.audioStream(for: userA)
        var streamB: AsyncStream<[UInt8]>? = await receiver.audioStream(for: userB)
        var broadcastStream: AsyncStream<(userID: UserID, frame: [UInt8])>? =
            await receiver.allAudioStreams()

        #expect(streamA != nil)
        #expect(streamB != nil)
        #expect(broadcastStream != nil)

        // Unmap user
        await receiver.unmapUser(userA)
        packetsContinuation.finish()
        streamA = nil
        streamB = nil
        broadcastStream = nil
    }
}
