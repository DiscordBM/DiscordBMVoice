import Foundation
import Logging

/// Paces and transmits 20ms Opus audio frames over UDP.
///
/// https://discord.com/developers/docs/topics/voice-connections#encrypting-and-sending-voice
actor AudioSender: AudioSchedulable {

    /// Standard Opus silence frame (3 bytes: 0xF8, 0xFF, 0xFE).
    static let silenceFrame: [UInt8] = [0xF8, 0xFF, 0xFE]

    private struct TransmissionContext: Sendable {
        let ssrc: UInt32
        let encryptor: any TransportEncryptor
        let key: [UInt8]
        let send: @Sendable ([UInt8]) async throws -> Void
        let speaking: @Sendable (SpeakingFlags) async throws -> Void
    }

    private var provider: (any OpusFrameProvider)?
    private var stopped = false
    private var sequence: UInt16 = 0
    private var timestamp: UInt32 = 0
    private var nonce: UInt32 = 0

    private var context: TransmissionContext?
    private var isSpeaking = false
    private var silenceCount = 0
    private var daveActiveLogged = false
    private var transmittedFrameCount = 0
    private var packetBuffer: [UInt8] = []

    private let dave: any DAVESession
    private let logger: Logger

    init(dave: any DAVESession, logger: Logger) {
        self.dave = dave
        self.logger = logger
    }

    /// Swaps or clears the active frame provider.
    func setProvider(_ provider: (any OpusFrameProvider)?) {
        self.provider = provider
    }

    /// Caches transmission credentials and callbacks without starting an unmanaged loop.
    func prepare(
        ssrc: UInt32,
        encryptor: any TransportEncryptor,
        key: [UInt8],
        send: @escaping @Sendable ([UInt8]) async throws -> Void,
        speaking: @escaping @Sendable (SpeakingFlags) async throws -> Void
    ) {
        self.stopped = false
        self.sequence = 0
        self.timestamp = 0
        self.nonce = 0
        self.isSpeaking = false
        self.silenceCount = 0
        self.daveActiveLogged = false
        self.transmittedFrameCount = 0
        self.packetBuffer.removeAll(keepingCapacity: true)
        if self.packetBuffer.capacity < 1500 {
            self.packetBuffer.reserveCapacity(1500)
        }
        self.context = TransmissionContext(
            ssrc: ssrc,
            encryptor: encryptor,
            key: key,
            send: send,
            speaking: speaking
        )
    }

    /// Sends one 20ms frame. Conforms to `AudioSchedulable`.
    func tick() async {
        guard !stopped, let ctx = context else { return }

        let daveReady = await dave.isReady
        if daveReady && !daveActiveLogged {
            logger.debug("DAVE E2EE session ratchet is active")
            daveActiveLogged = true
        }

        // Hold audio until DAVE session is ready
        guard daveReady else { return }

        let frame = await provider?.nextFrame()

        if let frame {
            silenceCount = 0
            if !isSpeaking {
                logger.debug("Setting speaking state", metadata: ["flags": "microphone"])
                try? await ctx.speaking(.microphone)
                isSpeaking = true
            }

            if frame.count > 1400 {
                logger.warning(
                    "Dropping audio frame exceeding 1400 bytes cap",
                    metadata: ["size": .stringConvertible(frame.count)]
                )
            } else {
                do {
                    // Encrypt with DAVE if active; silence frames pass through unencrypted
                    let davePayload: [UInt8]
                    if daveReady && frame != Self.silenceFrame {
                        do {
                            davePayload = try await dave.encrypt(frame: frame, ssrc: ctx.ssrc)
                        } catch {
                            logger.warning(
                                "DAVE encryption failed, sending unencrypted frame",
                                metadata: ["error": .string("\(error)")]
                            )
                            davePayload = frame
                        }
                    } else {
                        davePayload = frame
                    }

                    packetBuffer.removeAll(keepingCapacity: true)

                    let rtpHeader = RTPHeader(sequence: sequence, timestamp: timestamp, ssrc: ctx.ssrc)
                    rtpHeader.encode(into: &packetBuffer)

                    try ctx.encryptor.seal(
                        plaintext: davePayload,
                        key: ctx.key,
                        nonce: nonce,
                        header: Array(packetBuffer[0..<12]),
                        into: &packetBuffer
                    )

                    try await ctx.send(packetBuffer)

                    sequence &+= 1
                    timestamp &+= 960
                    nonce &+= 1

                    transmittedFrameCount += 1
                    if transmittedFrameCount == 1 {
                        logger.debug(
                            "Started transmitting audio frames",
                            metadata: [
                                "ssrc": .stringConvertible(ctx.ssrc),
                                "dave_encrypted": .stringConvertible(daveReady),
                                "payload_bytes": .stringConvertible(davePayload.count),
                            ]
                        )
                    } else if transmittedFrameCount % 500 == 0 {
                        logger.debug(
                            "Audio transmit progress",
                            metadata: [
                                "frames": .stringConvertible(transmittedFrameCount),
                                "dave_encrypted": .stringConvertible(daveReady),
                            ]
                        )
                    }
                } catch {
                    logger.error(
                        "Failed to encrypt or send audio frame",
                        metadata: ["error": .string("\(error)")]
                    )
                }
            }
        } else {
            // Send up to 5 silence frames on underrun to prevent clipping
            if silenceCount < 5 {
                do {
                    packetBuffer.removeAll(keepingCapacity: true)

                    let rtpHeader = RTPHeader(sequence: sequence, timestamp: timestamp, ssrc: ctx.ssrc)
                    rtpHeader.encode(into: &packetBuffer)

                    try ctx.encryptor.seal(
                        plaintext: Self.silenceFrame,
                        key: ctx.key,
                        nonce: nonce,
                        header: Array(packetBuffer[0..<12]),
                        into: &packetBuffer
                    )

                    try await ctx.send(packetBuffer)

                    sequence &+= 1
                    timestamp &+= 960
                    nonce &+= 1
                    silenceCount += 1
                } catch {
                    logger.debug(
                        "Failed to encrypt or send silence frame",
                        metadata: ["error": .string("\(error)")]
                    )
                }
            } else if silenceCount == 5 && isSpeaking {
                logger.debug("Audio provider exhausted; clearing speaking state")
                try? await ctx.speaking(.none)
                isSpeaking = false
                silenceCount += 1
            }
        }
    }

    /// Standalone 20ms timer loop for non-scheduled operation.
    func startLoop() async {
        logger.debug("Starting audio transmission loop", metadata: ["ssrc": .stringConvertible(context?.ssrc ?? 0)])

        var deadline = ContinuousClock.now

        while !stopped {
            deadline = deadline + .milliseconds(20)
            let now = ContinuousClock.now
            if deadline < now - .milliseconds(60) {
                // If more than 3 frames behind, resync to current clock
                deadline = now
            }

            await tick()

            try? await Task.sleep(until: deadline, clock: .continuous)
        }

        if isSpeaking {
            try? await context?.speaking(.none)
            isSpeaking = false
            logger.debug("AudioSender loop ended; cleared speaking state")
        }
    }

    /// Sets credentials and runs a standalone 20ms transmission loop.
    func start(
        ssrc: UInt32,
        encryptor: any TransportEncryptor,
        key: [UInt8],
        send: @escaping @Sendable ([UInt8]) async throws -> Void,
        speaking: @escaping @Sendable (SpeakingFlags) async throws -> Void
    ) async {
        prepare(ssrc: ssrc, encryptor: encryptor, key: key, send: send, speaking: speaking)
        await startLoop()
    }

    /// Halts transmission and resets speaking state.
    func stop() async {
        self.stopped = true
        if isSpeaking {
            try? await context?.speaking(.none)
            isSpeaking = false
        }
        logger.debug("AudioSender stop requested")
    }
}
