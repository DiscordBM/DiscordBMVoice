import Foundation
import NIOCore

/// An RTP header as used by the Discord voice UDP pipeline.
///
/// https://discord.com/developers/docs/topics/voice-connections#encrypting-and-sending-voice
struct RTPHeader: Sendable, Equatable {

    /// Fixed first byte: version 2, no padding, no extension, no CSRC.
    static let firstByte: UInt8 = 0x80

    /// Payload type for Opus audio as expected by Discord.
    static let payloadType: UInt8 = 0x78

    /// The minimum size of an RTP header in bytes.
    static let minimumSize: Int = 12

    var sequence: UInt16
    var timestamp: UInt32
    var ssrc: UInt32

    /// Encodes this header into an existing byte buffer.
    @inline(__always)
    func encode(into out: inout [UInt8]) {
        out.append(Self.firstByte)
        out.append(Self.payloadType)
        out.append(UInt8((sequence >> 8) & 0xFF))
        out.append(UInt8(sequence & 0xFF))
        out.append(UInt8((timestamp >> 24) & 0xFF))
        out.append(UInt8((timestamp >> 16) & 0xFF))
        out.append(UInt8((timestamp >> 8) & 0xFF))
        out.append(UInt8(timestamp & 0xFF))
        out.append(UInt8((ssrc >> 24) & 0xFF))
        out.append(UInt8((ssrc >> 16) & 0xFF))
        out.append(UInt8((ssrc >> 8) & 0xFF))
        out.append(UInt8(ssrc & 0xFF))
    }

    /// Encodes this header directly into a NIO ByteBuffer.
    @inline(__always)
    func encode(into buffer: inout ByteBuffer) {
        buffer.writeInteger(Self.firstByte)
        buffer.writeInteger(Self.payloadType)
        buffer.writeInteger(sequence)
        buffer.writeInteger(timestamp)
        buffer.writeInteger(ssrc)
    }

    /// Encodes this header as 12 bytes in big-endian byte order.
    func encode() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(12)
        encode(into: &out)
        return out
    }
}

/// The result of parsing an inbound RTP packet.
struct InboundRTPPacket: Sendable, Equatable {
    /// The SSRC of the sender.
    var ssrc: UInt32
    /// The byte range of the authenticated header (used as AAD for AEAD decryption).
    var headerLength: Int
    /// The nonce counter (last 4 bytes of the packet, big-endian).
    var nonce: UInt32
    /// The byte slice range of the ciphertext.
    var ciphertextRange: Range<Int>
    /// The underlying raw packet buffer.
    var rawPacket: [UInt8]
    /// Whether the extension bit is set, indicating an extension body in the plaintext.
    var hasExtension: Bool
    /// The length in bytes of the RTP extension body inside the decrypted payload.
    var extensionBodyLength: Int
    /// Whether the padding bit is set, indicating padding bytes at the end of the plaintext.
    var hasPadding: Bool

    var ciphertext: [UInt8] {
        Array(rawPacket[ciphertextRange])
    }
}

/// Errors thrown when parsing an RTP packet.
enum RTPParseError: Error, Equatable {
    case tooShort
    case wrongPayloadType(UInt8)
    case invalidPaddingCount
}

/// Parses an inbound UDP datagram as an RTP packet.
///
/// Returns `nil` and silently drops the packet if the payload type is not `0x78`
/// or if the packet is shorter than the minimum header size, matching Discord's
/// behaviour for non-audio packets.
///
/// https://discord.com/developers/docs/topics/voice-connections#encrypting-and-sending-voice
func parseRTPPacket(_ packet: [UInt8]) -> Result<InboundRTPPacket, RTPParseError> {
    guard packet.count >= RTPHeader.minimumSize + 4 else {
        return .failure(.tooShort)
    }
    let payloadType = packet[1] & 0x7F
    guard payloadType == RTPHeader.payloadType else {
        return .failure(.wrongPayloadType(payloadType))
    }
    let csrcCount = Int(packet[0] & 0x0F)
    let hasExtension = (packet[0] & 0x10) != 0
    let hasPadding = (packet[0] & 0x20) != 0

    let ssrc =
        (UInt32(packet[8]) << 24)
        | (UInt32(packet[9]) << 16)
        | (UInt32(packet[10]) << 8)
        | UInt32(packet[11])

    let extensionHeaderOffset = RTPHeader.minimumSize + csrcCount * 4
    var headerLength = extensionHeaderOffset
    var extensionBodyLength = 0

    if hasExtension {
        guard packet.count >= extensionHeaderOffset + 4 else {
            return .failure(.tooShort)
        }
        let extWords =
            (Int(packet[extensionHeaderOffset + 2]) << 8) | Int(packet[extensionHeaderOffset + 3])
        extensionBodyLength = extWords * 4
        headerLength += 4
    }

    guard packet.count > headerLength + 4 else {
        return .failure(.tooShort)
    }

    /// The trailing 4 bytes are the nonce counter.
    let nonceOffset = packet.count - 4
    let nonce =
        (UInt32(packet[nonceOffset]) << 24)
        | (UInt32(packet[nonceOffset + 1]) << 16)
        | (UInt32(packet[nonceOffset + 2]) << 8)
        | UInt32(packet[nonceOffset + 3])

    return .success(
        InboundRTPPacket(
            ssrc: ssrc,
            headerLength: headerLength,
            nonce: nonce,
            ciphertextRange: headerLength..<nonceOffset,
            rawPacket: packet,
            hasExtension: hasExtension,
            extensionBodyLength: extensionBodyLength,
            hasPadding: hasPadding
        )
    )
}

/// Strips the RTP extension body and optional padding from a decrypted payload in-place.
@inline(__always)
func stripRTPExtensionAndPadding(
    plaintext: inout [UInt8],
    hasExtension: Bool,
    extensionBodyLength: Int,
    hasPadding: Bool
) -> Bool {
    if hasPadding {
        guard let last = plaintext.last, last > 0, Int(last) < plaintext.count else {
            return false
        }
        plaintext.removeLast(Int(last))
    }

    if hasExtension {
        guard extensionBodyLength <= plaintext.count else {
            return false
        }
        plaintext.removeFirst(extensionBodyLength)
    }

    return !plaintext.isEmpty
}

/// Strips the RTP extension body and optional padding from a decrypted payload.
func stripRTPExtensionAndPadding(
    plaintext: [UInt8],
    hasExtension: Bool,
    extensionBodyLength: Int,
    hasPadding: Bool
) -> [UInt8]? {
    var copy = plaintext
    if stripRTPExtensionAndPadding(
        plaintext: &copy,
        hasExtension: hasExtension,
        extensionBodyLength: extensionBodyLength,
        hasPadding: hasPadding
    ) {
        return copy
    }
    return nil
}
