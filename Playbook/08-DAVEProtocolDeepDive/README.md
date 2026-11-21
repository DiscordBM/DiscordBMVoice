# Chapter 08: DAVE Protocol & Cryptographic Deep Dive

This chapter provides an exhaustive technical breakdown of Discord's **DAVE** (Discord Audio Video End-to-End Encryption) protocol, MLS state machines, AEAD transport ciphers, and RTP header formats as implemented in `DiscordBMVoice`.

---

## Protocol Architecture

Discord voice traffic uses two distinct encryption layers:

```mermaid
flowchart TD
    subgraph Layer1["1. DAVE MLS E2EE (Application Layer)"]
        Frame["Raw Opus Frame (48kHz Stereo)"]
        MLS["MLS Encryption (Per-Sender Ratchet Key)"]
        SecuredFrame["DAVE Ciphertext + MLS Tag"]
    end

    subgraph Layer2["2. Transport Encryption (Network Layer)"]
        RTP["12-Byte Big-Endian RTP Header"]
        AEAD["AEAD Cipher (AES-256-GCM or XChaCha20-Poly1305)"]
        Datagram["Encrypted RTP Datagram (Sent over UDP)"]
    end

    Frame --> MLS
    MLS --> SecuredFrame
    SecuredFrame --> AEAD
    RTP -->|Authenticated Associated Data (AAD)| AEAD
    AEAD --> Datagram
```

---

## 1. DAVE MLS (Messaging Layer Security)

DAVE is based on RFC 9420 (MLS). It ensures that only participants currently in the voice channel can decrypt audio and video frames:

### Opcodes Handled Automatically
* **Opcode 21 (`DAVE_PREPARE_TRANSITION`)**: Prepares epoch transition when members join or leave.
* **Opcode 23 (`DAVE_EXECUTE_TRANSITION`)**: Ratchets the MLS group to the next epoch.
* **Opcode 24 (`DAVE_TRANSITION_READY`)**: Signals readiness to switch encryption epochs.
* **Opcode 26 (`DAVE_KEY_PACKAGE`)**: Emits binary MLS key packages to Discord.
* **Opcode 28 (`DAVE_MLS_EXTERNAL_SENDER`)**: Installs credentials for external senders.
* **Opcode 29 (`DAVE_MLS_KEY_PACKAGE`)**: Receives group member key packages.
* **Opcode 30 (`DAVE_MLS_PROPOSALS`)**: Commits pending member add/remove proposals.

---

## 2. Transport Encryption Modes

Discord negotiates one of two modern AEAD ciphers during the `SELECT_PROTOCOL` handshake:

### Mode 1: `aead_aes256_gcm_rtpsize`
* **Cipher**: AES-256 in Galois/Counter Mode.
* **AAD**: 12-byte big-endian RTP header.
* **Nonce**: 4-byte big-endian counter appended to the ciphertext payload.
* **Authentication**: 16-byte Poly1305 / GCM authentication tag.

### Mode 2: `aead_xchacha20_poly1305_rtpsize`
* **Cipher**: XChaCha20-Poly1305 (24-byte extended nonce).
* **Key Derivation**: Subkey derived via internal `HChaCha20` implementation.
* **AAD**: 12-byte big-endian RTP header.
* **Nonce**: 4-byte counter appended to ciphertext.

---

## 3. RTP Header Serialization

RTP packets follow standard RFC 3550 layout:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|V=2|P|X|  CC   |M|     PT      |       Sequence Number         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           Timestamp                           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|           Synchronization Source (SSRC) identifier            |
+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+
|       Payload (Encrypted Opus Audio + Appended Nonce)         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

* **Version**: `2`
* **Payload Type**: `0x78` (120, standard Opus)
* **Timestamp Increment**: 960 samples per 20ms frame (48kHz)
* **Silence Frames**: When stopping or pausing, exactly 5 silence frames (`[0xF8, 0xFF, 0xFE]`) are sent to flush jitter buffers.
