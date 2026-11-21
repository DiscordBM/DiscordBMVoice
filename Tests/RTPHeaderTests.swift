import Testing

@testable import DiscordBMVoice

@Suite("RTP Header Tests")
struct RTPHeaderTests {

    @Test("RTP header encoding produces correct 12-byte big-endian format")
    func testRTPHeaderEncoding() {
        let header = RTPHeader(
            sequence: 0x1234,
            timestamp: 0x5678_9ABC,
            ssrc: 0xDEF0_1234
        )

        let bytes = header.encode()
        #expect(bytes.count == 12)
        #expect(bytes[0] == 0x80)  // Version 2
        #expect(bytes[1] == 0x78)  // Payload type 120 (Opus)
        #expect(bytes[2] == 0x12)  // Sequence high
        #expect(bytes[3] == 0x34)  // Sequence low
        #expect(bytes[4] == 0x56)  // Timestamp byte 3
        #expect(bytes[5] == 0x78)  // Timestamp byte 2
        #expect(bytes[6] == 0x9A)  // Timestamp byte 1
        #expect(bytes[7] == 0xBC)  // Timestamp byte 0
        #expect(bytes[8] == 0xDE)  // SSRC byte 3
        #expect(bytes[9] == 0xF0)  // SSRC byte 2
        #expect(bytes[10] == 0x12)  // SSRC byte 1
        #expect(bytes[11] == 0x34)  // SSRC byte 0
    }

    @Test("Inbound RTP packet parsing succeeds for valid audio packet")
    func testInboundRTPParsing() throws {
        let header = RTPHeader(
            sequence: 42,
            timestamp: 960,
            ssrc: 12345
        )
        var packet = header.encode()

        // Append ciphertext dummy payload
        let dummyCiphertext: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        packet.append(contentsOf: dummyCiphertext)

        // Append 4-byte nonce counter (e.g. 7 in big-endian)
        let nonce: UInt32 = 7
        packet.append(UInt8((nonce >> 24) & 0xFF))
        packet.append(UInt8((nonce >> 16) & 0xFF))
        packet.append(UInt8((nonce >> 8) & 0xFF))
        packet.append(UInt8(nonce & 0xFF))

        let result = parseRTPPacket(packet)
        let parsed = try #require(try? result.get())
        #expect(parsed.ssrc == 12345)
        #expect(parsed.headerLength == 12)
        #expect(parsed.nonce == 7)
        #expect(parsed.ciphertext == dummyCiphertext)
        #expect(parsed.hasExtension == false)
        #expect(parsed.hasPadding == false)
    }

    @Test("Inbound RTP packet parsing rejects packet with invalid payload type")
    func testInboundRTPInvalidPayloadType() {
        var packet = [UInt8](repeating: 0, count: 20)
        packet[0] = 0x80
        packet[1] = 0x60  // Non-opus payload type

        let result = parseRTPPacket(packet)
        #expect(result == .failure(.wrongPayloadType(0x60)))
    }

    @Test("Inbound RTP packet parsing rejects packet shorter than minimum size")
    func testInboundRTPTooShort() {
        let packet: [UInt8] = [0x80, 0x78, 0x00]
        let result = parseRTPPacket(packet)
        #expect(result == .failure(.tooShort))
    }
}
