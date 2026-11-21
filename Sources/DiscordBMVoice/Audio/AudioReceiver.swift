import Audio
import Foundation
import Logging

/// Actor responsible for receiving, decrypting, and dispatching incoming audio frames.
///
/// https://discord.com/developers/docs/topics/voice-connections#encrypting-and-sending-voice
actor AudioReceiver {

    private var receiver: (any OpusFrameReceiver)?
    private var isRunning = false
    private let packets: AsyncStream<[UInt8]>
    private let encryptor: any TransportEncryptor
    private let key: [UInt8]
    private let dave: any DAVESession
    private let logger: Logger

    private var ssrcMap: [UInt32: UserID] = [:]
    private var userContinuations: [UserID: [UUID: AsyncStream<[UInt8]>.Continuation]] = [:]
    private var allStreamsContinuations: [UUID: AsyncStream<(userID: UserID, frame: [UInt8])>.Continuation] = [:]

    private var opusDecoders: [UserID: OpusDecoder] = [:]
    private var customDecoder: (any CustomOpusDecoder)?
    private var pcmUserContinuations: [UserID: [UUID: AsyncStream<[Float]>.Continuation]] = [:]
    private var pcmAllContinuations: [UUID: AsyncStream<(userID: UserID, frame: [Float])>.Continuation] = [:]

    init(
        packets: AsyncStream<[UInt8]>,
        encryptor: any TransportEncryptor,
        key: [UInt8],
        dave: any DAVESession,
        logger: Logger
    ) {
        self.packets = packets
        self.encryptor = encryptor
        self.key = key
        self.dave = dave
        self.logger = logger
    }

    /// Maps an SSRC to a Discord user ID for frame decryption and routing.
    func mapSSRC(_ ssrc: UInt32, to userID: UserID) {
        self.ssrcMap[ssrc] = userID
    }

    /// Removes mappings for a disconnected user and frees associated decoders.
    func unmapUser(_ userID: UserID) {
        self.ssrcMap = ssrcMap.filter { $0.value != userID }
        self.opusDecoders.removeValue(forKey: userID)
    }

    /// Sets or clears the active Opus frame receiver.
    func setReceiver(_ receiver: (any OpusFrameReceiver)?) {
        self.receiver = receiver
    }

    /// Sets or clears a custom Opus decoder for inbound PCM stream decoding.
    func setCustomDecoder(_ decoder: (any CustomOpusDecoder)?) {
        self.customDecoder = decoder
    }

    /// Subscribes to decrypted Opus frames for a specific user.
    func audioStream(for userID: UserID) -> AsyncStream<[UInt8]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
        if userContinuations[userID] == nil {
            userContinuations[userID] = [:]
        }
        userContinuations[userID]?[id] = continuation

        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.removeUserStream(id: id, for: userID)
            }
        }
        return stream
    }

    /// Subscribes to all decrypted Opus frames from all participants.
    func allAudioStreams() -> AsyncStream<(userID: UserID, frame: [UInt8])> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<(userID: UserID, frame: [UInt8])>.makeStream()
        allStreamsContinuations[id] = continuation

        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.removeAllStreams(id: id)
            }
        }
        return stream
    }

    /// Subscribes to decoded 20ms Float PCM frames for a specific user (1,920 stereo samples at 48kHz).
    func pcmStream(for userID: UserID) -> AsyncStream<[Float]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        if pcmUserContinuations[userID] == nil {
            pcmUserContinuations[userID] = [:]
        }
        pcmUserContinuations[userID]?[id] = continuation

        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.removeUserPCMStream(id: id, for: userID)
            }
        }
        return stream
    }

    /// Subscribes to all decoded 20ms Float PCM frames across all channel participants.
    func allPCMStreams() -> AsyncStream<(userID: UserID, frame: [Float])> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<(userID: UserID, frame: [Float])>.makeStream()
        pcmAllContinuations[id] = continuation

        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.removeAllPCMStreams(id: id)
            }
        }
        return stream
    }

    private func removeUserStream(id: UUID, for userID: UserID) {
        userContinuations[userID]?.removeValue(forKey: id)
        if userContinuations[userID]?.isEmpty == true {
            userContinuations.removeValue(forKey: userID)
        }
    }

    private func removeAllStreams(id: UUID) {
        allStreamsContinuations.removeValue(forKey: id)
    }

    private func removeUserPCMStream(id: UUID, for userID: UserID) {
        pcmUserContinuations[userID]?.removeValue(forKey: id)
        if pcmUserContinuations[userID]?.isEmpty == true {
            pcmUserContinuations.removeValue(forKey: userID)
            opusDecoders.removeValue(forKey: userID)
        }
    }

    private func removeAllPCMStreams(id: UUID) {
        pcmAllContinuations.removeValue(forKey: id)
    }

    /// Starts processing inbound UDP datagrams.
    func start() async {
        self.isRunning = true

        for await rawPacket in packets {
            guard isRunning else { break }

            guard case .success(let parsed) = parseRTPPacket(rawPacket) else {
                continue
            }

            guard let userID = ssrcMap[parsed.ssrc] else {
                continue
            }

            let headerSlice = rawPacket[0..<parsed.headerLength]
            let ciphertextSlice = rawPacket[parsed.ciphertextRange]

            var plaintext: [UInt8]
            do {
                plaintext = try encryptor.open(
                    ciphertext: ciphertextSlice,
                    key: key,
                    nonce: parsed.nonce,
                    header: headerSlice
                )
            } catch {
                logger.debug(
                    "Failed transport AEAD decryption for packet from user",
                    metadata: [
                        "userID": .stringConvertible(userID),
                        "error": .string("\(error)"),
                    ]
                )
                continue
            }

            guard
                stripRTPExtensionAndPadding(
                    plaintext: &plaintext,
                    hasExtension: parsed.hasExtension,
                    extensionBodyLength: parsed.extensionBodyLength,
                    hasPadding: parsed.hasPadding
                )
            else {
                logger.trace(
                    "Failed stripping RTP extension/padding from packet",
                    metadata: ["plainLen": .stringConvertible(plaintext.count)]
                )
                continue
            }

            let frameToDeliver: [UInt8]
            let daveReady = await dave.isReady
            if daveReady && plaintext != AudioSender.silenceFrame {
                do {
                    frameToDeliver = try await dave.decrypt(frame: plaintext, userID: userID)
                } catch {
                    logger.debug(
                        "DAVE frame decryption failed, dropping frame",
                        metadata: [
                            "userID": .stringConvertible(userID),
                            "error": .string("\(error)"),
                        ]
                    )
                    continue
                }
            } else {
                frameToDeliver = plaintext
            }

            await receiver?.receive(frame: frameToDeliver, from: userID)

            if let userSubs = userContinuations[userID] {
                for cont in userSubs.values {
                    cont.yield(frameToDeliver)
                }
            }

            if !allStreamsContinuations.isEmpty {
                for cont in allStreamsContinuations.values {
                    cont.yield((userID: userID, frame: frameToDeliver))
                }
            }

            let needsPCM = (pcmUserContinuations[userID]?.isEmpty == false) || (!pcmAllContinuations.isEmpty)
            if needsPCM {
                let pcm: [Float]?
                if let custom = customDecoder {
                    pcm = try? custom.decode(packet: frameToDeliver)
                } else {
                    var decoder = opusDecoders[userID]
                    if decoder == nil {
                        decoder = try? OpusDecoder(channels: AudioConstants.channelCount)
                        opusDecoders[userID] = decoder
                    }
                    pcm = try? decoder?.decode(bytes: frameToDeliver)
                }

                if let pcm {
                    if let userSubs = pcmUserContinuations[userID] {
                        for cont in userSubs.values {
                            cont.yield(pcm)
                        }
                    }
                    if !pcmAllContinuations.isEmpty {
                        for cont in pcmAllContinuations.values {
                            cont.yield((userID: userID, frame: pcm))
                        }
                    }
                }
            }
        }
    }

    /// Stops the audio receiving loop and finishes all active streams.
    func stop() {
        guard self.isRunning else { return }
        self.isRunning = false
        self.ssrcMap.removeAll()
        logger.debug("AudioReceiver stopping; finishing all active inbound streams")

        for subs in userContinuations.values {
            for cont in subs.values {
                cont.finish()
            }
        }
        userContinuations.removeAll()

        for cont in allStreamsContinuations.values {
            cont.finish()
        }
        allStreamsContinuations.removeAll()

        for subs in pcmUserContinuations.values {
            for cont in subs.values {
                cont.finish()
            }
        }
        pcmUserContinuations.removeAll()

        for cont in pcmAllContinuations.values {
            cont.finish()
        }
        pcmAllContinuations.removeAll()
        opusDecoders.removeAll()
    }

    deinit {
        for subs in userContinuations.values {
            for cont in subs.values {
                cont.finish()
            }
        }
        for cont in allStreamsContinuations.values {
            cont.finish()
        }
        for subs in pcmUserContinuations.values {
            for cont in subs.values {
                cont.finish()
            }
        }
        for cont in pcmAllContinuations.values {
            cont.finish()
        }
    }
}
