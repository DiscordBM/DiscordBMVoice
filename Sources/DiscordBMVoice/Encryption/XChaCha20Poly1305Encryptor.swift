import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// XChaCha20-Poly1305 transport encryptor for the Discord voice UDP pipeline.
///
/// Implements subkey derivation via HChaCha20 followed by standard ChaCha20-Poly1305.
/// Reference: RFC 8439 / draft-irtf-cfrg-xchacha-03.
/// Nonce format: 4-byte big-endian packet counter followed by 20 zero bytes (24 bytes total).
/// Subkey is derived with HChaCha20(key, nonce[0..<16]).
/// ChaCha20-Poly1305 nonce is 4 zero bytes followed by nonce[16..<24] (12 bytes total).
///
/// https://discord.com/developers/docs/topics/voice-connections#transport-encryption-modes
struct XChaCha20Poly1305Encryptor: TransportEncryptor {

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

        var nonce24 = [UInt8](repeating: 0, count: 24)
        nonce24[0] = UInt8((nonce >> 24) & 0xFF)
        nonce24[1] = UInt8((nonce >> 16) & 0xFF)
        nonce24[2] = UInt8((nonce >> 8) & 0xFF)
        nonce24[3] = UInt8(nonce & 0xFF)

        let subkey = hchacha20(key: key, nonce16: Array(nonce24[0..<16]))

        var derivedNonce12 = [UInt8](repeating: 0, count: 12)
        derivedNonce12[4..<12] = nonce24[16..<24]

        let symmetricKey = SymmetricKey(data: subkey)
        let chachaNonce = try ChaChaPoly.Nonce(data: derivedNonce12)

        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: symmetricKey,
            nonce: chachaNonce,
            authenticating: header
        )

        // Ciphertext + 16-byte tag + 4-byte nonce counter
        packet.append(contentsOf: sealed.ciphertext)
        packet.append(contentsOf: sealed.tag)
        packet.append(nonce24[0])
        packet.append(nonce24[1])
        packet.append(nonce24[2])
        packet.append(nonce24[3])
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

        var nonce24 = [UInt8](repeating: 0, count: 24)
        nonce24[0] = UInt8((nonce >> 24) & 0xFF)
        nonce24[1] = UInt8((nonce >> 16) & 0xFF)
        nonce24[2] = UInt8((nonce >> 8) & 0xFF)
        nonce24[3] = UInt8(nonce & 0xFF)

        let subkey = hchacha20(key: key, nonce16: Array(nonce24[0..<16]))

        var derivedNonce12 = [UInt8](repeating: 0, count: 12)
        derivedNonce12[4..<12] = nonce24[16..<24]

        let symmetricKey = SymmetricKey(data: subkey)
        let chachaNonce = try ChaChaPoly.Nonce(data: derivedNonce12)

        // 16-byte authentication tag is at the end
        let tagIndex = ciphertext.endIndex - 16
        let rawCiphertext = ciphertext[..<tagIndex]
        let tag = ciphertext[tagIndex...]

        do {
            let sealedBox = try ChaChaPoly.SealedBox(
                nonce: chachaNonce,
                ciphertext: rawCiphertext,
                tag: tag
            )
            let plaintext = try ChaChaPoly.open(sealedBox, using: symmetricKey, authenticating: header)
            return Array(plaintext)
        } catch {
            throw TransportEncryptionError.authenticationFailure
        }
    }
}

/// HChaCha20 intermediate key derivation function.
/// Takes a 32-byte key and 16-byte nonce, returns a 32-byte derived subkey.
/// Unlike standard ChaCha20, HChaCha20 does NOT add the initial state words back into the final state.
@inline(__always)
func hchacha20(key: [UInt8], nonce16: [UInt8]) -> [UInt8] {
    precondition(key.count == 32 && nonce16.count == 16)

    @inline(__always)
    func loadLE32(_ bytes: [UInt8], offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    var x0: UInt32 = 0x6170_7865  // "expa"
    var x1: UInt32 = 0x3320_646e  // "nd 3"
    var x2: UInt32 = 0x7962_2d32  // "2-by"
    var x3: UInt32 = 0x6b20_6574  // "te k"

    var x4 = loadLE32(key, offset: 0)
    var x5 = loadLE32(key, offset: 4)
    var x6 = loadLE32(key, offset: 8)
    var x7 = loadLE32(key, offset: 12)
    var x8 = loadLE32(key, offset: 16)
    var x9 = loadLE32(key, offset: 20)
    var x10 = loadLE32(key, offset: 24)
    var x11 = loadLE32(key, offset: 28)

    var x12 = loadLE32(nonce16, offset: 0)
    var x13 = loadLE32(nonce16, offset: 4)
    var x14 = loadLE32(nonce16, offset: 8)
    var x15 = loadLE32(nonce16, offset: 12)

    @inline(__always)
    func quarterRound(_ a: inout UInt32, _ b: inout UInt32, _ c: inout UInt32, _ d: inout UInt32) {
        a &+= b
        d ^= a
        d = (d << 16) | (d >> 16)
        c &+= d
        b ^= c
        b = (b << 12) | (b >> 20)
        a &+= b
        d ^= a
        d = (d << 8) | (d >> 24)
        c &+= d
        b ^= c
        b = (b << 7) | (b >> 25)
    }

    // 10 double-rounds = 20 rounds
    for _ in 0..<10 {
        // Column rounds
        quarterRound(&x0, &x4, &x8, &x12)
        quarterRound(&x1, &x5, &x9, &x13)
        quarterRound(&x2, &x6, &x10, &x14)
        quarterRound(&x3, &x7, &x11, &x15)

        // Diagonal rounds
        quarterRound(&x0, &x5, &x10, &x15)
        quarterRound(&x1, &x6, &x11, &x12)
        quarterRound(&x2, &x7, &x8, &x13)
        quarterRound(&x3, &x4, &x9, &x14)
    }

    // Write words 0..3 and 12..15 as 32 little-endian bytes
    var out = [UInt8](repeating: 0, count: 32)
    @inline(__always)
    func storeLE32(_ val: UInt32, into: inout [UInt8], offset: Int) {
        into[offset] = UInt8(val & 0xFF)
        into[offset + 1] = UInt8((val >> 8) & 0xFF)
        into[offset + 2] = UInt8((val >> 16) & 0xFF)
        into[offset + 3] = UInt8((val >> 24) & 0xFF)
    }

    storeLE32(x0, into: &out, offset: 0)
    storeLE32(x1, into: &out, offset: 4)
    storeLE32(x2, into: &out, offset: 8)
    storeLE32(x3, into: &out, offset: 12)
    storeLE32(x12, into: &out, offset: 16)
    storeLE32(x13, into: &out, offset: 20)
    storeLE32(x14, into: &out, offset: 24)
    storeLE32(x15, into: &out, offset: 28)

    return out
}
