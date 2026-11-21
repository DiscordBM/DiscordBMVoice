import Testing

@testable import DiscordBMVoice

@Suite("Transport Encryption Tests")
struct EncryptionTests {

    @Test("AES-256-GCM roundtrip encryption and decryption")
    func testAES256GCMRoundtrip() throws {
        let encryptor = AES256GCMEncryptor()
        let key = [UInt8](repeating: 0x42, count: 32)
        let header = [UInt8](0..<12)
        let plaintext = Array("Hello, Discord voice via DiscordBMVoice!".utf8)
        let nonce: UInt32 = 1

        let sealed = try encryptor.seal(
            plaintext: plaintext,
            key: key,
            nonce: nonce,
            header: header
        )

        // Sealed output includes 16-byte auth tag and 4-byte nonce appended
        #expect(sealed.count == plaintext.count + 16 + 4)

        // Strip the trailing 4-byte nonce for open()
        let ciphertext = Array(sealed.dropLast(4))

        let opened = try encryptor.open(
            ciphertext: ciphertext,
            key: key,
            nonce: nonce,
            header: header
        )

        #expect(opened == plaintext)
    }

    @Test("AES-256-GCM fails authentication with corrupted ciphertext")
    func testAES256GCMCorruptedCiphertext() throws {
        let encryptor = AES256GCMEncryptor()
        let key = [UInt8](repeating: 0x42, count: 32)
        let header = [UInt8](0..<12)
        let plaintext = Array("Secret voice packet".utf8)
        let nonce: UInt32 = 1

        let sealed = try encryptor.seal(
            plaintext: plaintext,
            key: key,
            nonce: nonce,
            header: header
        )

        var ciphertext = Array(sealed.dropLast(4))
        ciphertext[0] ^= 0xFF  // Corrupt first byte

        #expect(throws: TransportEncryptionError.authenticationFailure) {
            try encryptor.open(
                ciphertext: ciphertext,
                key: key,
                nonce: nonce,
                header: header
            )
        }
    }

    @Test("XChaCha20-Poly1305 roundtrip encryption and decryption")
    func testXChaCha20Poly1305Roundtrip() throws {
        let encryptor = XChaCha20Poly1305Encryptor()
        let key = [UInt8](repeating: 0x33, count: 32)
        let header = [UInt8](0..<12)
        let plaintext = Array("XChaCha20 voice data test".utf8)
        let nonce: UInt32 = 42

        let sealed = try encryptor.seal(
            plaintext: plaintext,
            key: key,
            nonce: nonce,
            header: header
        )

        // Sealed output includes 16-byte auth tag and 4-byte nonce appended
        #expect(sealed.count == plaintext.count + 16 + 4)

        let ciphertext = Array(sealed.dropLast(4))
        let opened = try encryptor.open(
            ciphertext: ciphertext,
            key: key,
            nonce: nonce,
            header: header
        )

        #expect(opened == plaintext)
    }
}
