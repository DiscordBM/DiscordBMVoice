import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// AES-256-GCM transport encryptor for the Discord voice UDP pipeline.
///
/// Nonce format: 4-byte big-endian packet counter followed by 8 zero bytes (12 bytes total).
/// Appends the 4-byte big-endian nonce counter to the ciphertext.
///
/// https://discord.com/developers/docs/topics/voice-connections#transport-encryption-modes
struct AES256GCMEncryptor: TransportEncryptor {

    func seal(
        plaintext: [UInt8],
        key: [UInt8],
        nonce: UInt32,
        header: [UInt8],
        into packet: inout [UInt8]
    ) throws {
        guard key.count == 32 else {
            throw TransportEncryptionError.invalidKeyLength(key.count)
        }

        var nonceBytes = [UInt8](repeating: 0, count: 12)
        nonceBytes[0] = UInt8((nonce >> 24) & 0xFF)
        nonceBytes[1] = UInt8((nonce >> 16) & 0xFF)
        nonceBytes[2] = UInt8((nonce >> 8) & 0xFF)
        nonceBytes[3] = UInt8(nonce & 0xFF)

        let symmetricKey = SymmetricKey(data: key)
        let gcmNonce = try AES.GCM.Nonce(data: nonceBytes)

        let sealed = try AES.GCM.seal(
            plaintext,
            using: symmetricKey,
            nonce: gcmNonce,
            authenticating: header
        )

        // Ciphertext + 16-byte tag + 4-byte nonce counter
        packet.append(contentsOf: sealed.ciphertext)
        packet.append(contentsOf: sealed.tag)
        packet.append(nonceBytes[0])
        packet.append(nonceBytes[1])
        packet.append(nonceBytes[2])
        packet.append(nonceBytes[3])
    }

    func open(
        ciphertext: ArraySlice<UInt8>,
        key: [UInt8],
        nonce: UInt32,
        header: ArraySlice<UInt8>
    ) throws -> [UInt8] {
        guard key.count == 32 else {
            throw TransportEncryptionError.invalidKeyLength(key.count)
        }
        guard ciphertext.count >= 16 else {
            throw TransportEncryptionError.authenticationFailure
        }

        var nonceBytes = [UInt8](repeating: 0, count: 12)
        nonceBytes[0] = UInt8((nonce >> 24) & 0xFF)
        nonceBytes[1] = UInt8((nonce >> 16) & 0xFF)
        nonceBytes[2] = UInt8((nonce >> 8) & 0xFF)
        nonceBytes[3] = UInt8(nonce & 0xFF)

        let symmetricKey = SymmetricKey(data: key)
        let gcmNonce = try AES.GCM.Nonce(data: nonceBytes)

        // 16-byte authentication tag is at the end
        let tagIndex = ciphertext.endIndex - 16
        let rawCiphertext = ciphertext[..<tagIndex]
        let tag = ciphertext[tagIndex...]

        do {
            let sealedBox = try AES.GCM.SealedBox(nonce: gcmNonce, ciphertext: rawCiphertext, tag: tag)
            let plaintext = try AES.GCM.open(sealedBox, using: symmetricKey, authenticating: header)
            return Array(plaintext)
        } catch {
            throw TransportEncryptionError.authenticationFailure
        }
    }
}
