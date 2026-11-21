import Audio
import Foundation
import Logging
import NIOCore
import NIOPosix

/// Current state of a Discord voice connection.
public enum VoiceConnectionState: Sendable, Equatable {
    case connecting
    case ready
    case reconnecting(attempt: Int)
    case disconnected(VoiceGatewayCloseCode?)
}

/// Errors thrown by `VoiceConnection`.
public enum VoiceConnectionError: Error, CustomStringConvertible {
    case joinTimeout
    case connectionClosed
    case noCompatibleEncryptionMode
    case failedToInitializeDAVE(String)

    public var description: String {
        switch self {
        case .joinTimeout:
            return "VoiceConnectionError.joinTimeout"
        case .connectionClosed:
            return "VoiceConnectionError.connectionClosed"
        case .noCompatibleEncryptionMode:
            return "VoiceConnectionError.noCompatibleEncryptionMode"
        case .failedToInitializeDAVE(let reason):
            return "VoiceConnectionError.failedToInitializeDAVE(\(reason))"
        }
    }
}

/// A complete voice connection to a Discord voice channel in a specific guild.
///
/// https://discord.com/developers/docs/topics/voice-connections
public actor VoiceConnection {

    public let guildID: GuildID
    public let userID: UserID
    private(set) public var channelID: ChannelID?

    /// Current connection state.
    private(set) public var state: VoiceConnectionState = .disconnected(nil)
    private let stateStream: AsyncStream<VoiceConnectionState>
    private let stateContinuation: AsyncStream<VoiceConnectionState>.Continuation

    /// Stream of state changes for this voice connection.
    public var states: AsyncStream<VoiceConnectionState> {
        stateStream
    }

    private let speakingStream: AsyncStream<SpeakingUpdate>
    private let speakingContinuation: AsyncStream<SpeakingUpdate>.Continuation

    /// Stream of speaking updates for participants in the voice channel.
    public var speakingUpdates: AsyncStream<SpeakingUpdate> {
        speakingStream
    }

    /// The latest voice gateway round-trip ping time, if available.
    public var ping: Duration? {
        get async {
            await gateway?.ping
        }
    }

    private let config: VoiceConfiguration
    private let logger: Logger
    private let eventLoopGroup: any EventLoopGroup
    private let sendVoiceStateUpdate: @Sendable (VoiceStateUpdate) async -> Void

    private var gateway: VoiceGateway?
    private var udp: VoiceUDP?
    private var dave: (any DAVESession)?
    private var audioSender: AudioSender?
    private var audioReceiver: AudioReceiver?

    /// Multi-track software audio mixer for concurrent playback.
    public let mixer: AudioMixer
    /// Built-in auto-ducking filter.
    public let autoDucker = AutoDucker()
    private var autoDuckingTask: Task<Void, Never>?
    private var provider: (any OpusFrameProvider)?
    private var receiver: (any OpusFrameReceiver)?
    private var customDecoder: (any CustomOpusDecoder)?

    private var ssrcUserMap: [UInt32: UserID] = [:]
    private var selfSSRC: UInt32?
    private var encryptor: (any TransportEncryptor)?
    private var secretKey: [UInt8] = []

    // Handshake state
    private var pendingSessionID: String?
    private var pendingToken: String?
    private var pendingEndpoint: String?
    private var voiceStateReceived = false
    private var voiceServerReceived = false

    private var joinContinuation: CheckedContinuation<Void, any Error>?
    private var eventProcessingTask: Task<Void, Never>?
    private var daveOutgoingTask: Task<Void, Never>?
    private var isClosed = false

    public init(
        guildID: GuildID,
        userID: UserID,
        config: VoiceConfiguration = .init(),
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        sendVoiceStateUpdate: @escaping @Sendable (VoiceStateUpdate) async -> Void
    ) {
        self.guildID = guildID
        self.userID = userID
        self.config = config
        self.eventLoopGroup = eventLoopGroup
        self.sendVoiceStateUpdate = sendVoiceStateUpdate

        var logger = config.makeLogger("VoiceConnection")
        logger[metadataKey: "guild_id"] = .string("\(guildID.rawValue)")
        self.logger = logger

        let mixer = AudioMixer(logger: config.makeLogger("AudioMixer"))
        self.mixer = mixer
        self.provider = mixer
        self.customDecoder = config.customOpusDecoder

        let (stream, continuation) = AsyncStream<VoiceConnectionState>.makeStream()
        self.stateStream = stream
        self.stateContinuation = continuation

        let (spkStream, spkContinuation) = AsyncStream<SpeakingUpdate>.makeStream()
        self.speakingStream = spkStream
        self.speakingContinuation = spkContinuation
    }

    deinit {
        stateContinuation.finish()
        speakingContinuation.finish()
        joinContinuation?.resume(throwing: VoiceConnectionError.connectionClosed)
        eventProcessingTask?.cancel()
        daveOutgoingTask?.cancel()
    }

    private func updateState(_ newState: VoiceConnectionState) {
        guard self.state != newState else { return }
        self.state = newState
        logger.debug("VoiceConnection state changed", metadata: ["state": .string("\(newState)")])
        self.stateContinuation.yield(newState)
    }

    /// Opens the voice connection to the given channel.
    ///
    /// Waits until the entire voice handshake completes (Session Description received).
    /// Throws if the handshake times out or fails.
    public func open(
        channelID: ChannelID,
        selfMute: Bool = false,
        selfDeaf: Bool = false
    ) async throws {
        logger.debug(
            "VoiceConnection open requested",
            metadata: ["channel_id": .string(channelID.description)]
        )
        self.channelID = channelID
        self.isClosed = false
        self.voiceStateReceived = false
        self.voiceServerReceived = false
        self.pendingSessionID = nil
        self.pendingToken = nil
        self.pendingEndpoint = nil

        updateState(.connecting)

        let update = VoiceStateUpdate(
            guildID: guildID,
            channelID: channelID,
            selfMute: selfMute,
            selfDeaf: selfDeaf
        )

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { continuation in
                            Task {
                                await self.prepareJoin(continuation: continuation, update: update)
                            }
                        }
                    } onCancel: {
                        Task {
                            await self.cancelJoinContinuation()
                        }
                    }
                }

                group.addTask {
                    try await Task.sleep(for: self.config.joinTimeout)
                    throw VoiceConnectionError.joinTimeout
                }

                try await group.next()
                group.cancelAll()
            }
        } catch {
            logger.warning(
                "VoiceConnection open failed or timed out",
                metadata: ["error": .string("\(error)")]
            )
            await self.close()
            throw error
        }
    }

    private func prepareJoin(
        continuation: CheckedContinuation<Void, any Error>,
        update: VoiceStateUpdate
    ) async {
        if self.isClosed {
            continuation.resume(throwing: VoiceConnectionError.connectionClosed)
        } else {
            self.joinContinuation = continuation
            logger.debug(
                "Sending voice state update to join channel",
                metadata: [
                    "guild_id": .string(update.guildID.description),
                    "channel_id": .string(update.channelID?.description ?? "nil"),
                ]
            )
            await self.sendVoiceStateUpdate(update)
        }
    }

    private func cancelJoinContinuation() {
        self.joinContinuation?.resume(throwing: CancellationError())
        self.joinContinuation = nil
    }

    /// Sets or clears the active Opus frame provider.
    public func setFrameProvider(_ provider: (any OpusFrameProvider)?) async {
        self.provider = provider
        await audioSender?.setProvider(provider)
    }

    /// Plays an audio track concurrently on this voice connection's software mixer, returning a handle to control playback.
    @discardableResult
    public func play(_ track: AudioTrack) async -> TrackHandle {
        if self.provider !== self.mixer {
            await setFrameProvider(self.mixer)
        }
        return await mixer.add(track)
    }

    /// Plays audio from an Opus frame provider concurrently on the software mixer.
    @discardableResult
    public func play(_ provider: any OpusFrameProvider) async -> TrackHandle {
        let track = AudioTrack(provider: provider)
        return await play(track)
    }

    /// Plays audio from a PCM frame provider concurrently on the software mixer.
    @discardableResult
    public func play(_ provider: any PCMFrameProvider) async -> TrackHandle {
        let track = AudioTrack(pcmProvider: provider)
        return await play(track)
    }

    /// Stops all currently active tracks playing on the software mixer.
    public func stopAll() async {
        await mixer.stopAll()
    }

    /// Plays an audio file from disk with rich metadata and user context.
    @discardableResult
    public func playFile(
        _ path: String,
        metadata: TrackMetadata = TrackMetadata(),
        userData: TrackUserData = TrackUserData(),
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) async throws -> TrackHandle {
        let track = try AudioTrack.file(
            path,
            metadata: metadata,
            userData: userData,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
        return await play(track)
    }

    /// Plays an audio file from disk (MP3, WAV, FLAC), returning a handle to control playback.
    @discardableResult
    public func playFile(
        _ path: String,
        title: String? = nil,
        metadata: [String: String] = [:],
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) async throws -> TrackHandle {
        let meta = TrackMetadata(title: title, custom: metadata)
        return try await playFile(
            path,
            metadata: meta,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
    }

    /// Plays in-memory audio data with rich metadata and user context.
    @discardableResult
    public func playData(
        _ data: Data,
        metadata: TrackMetadata = TrackMetadata(),
        userData: TrackUserData = TrackUserData(),
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) async throws -> TrackHandle {
        let track = try AudioTrack.data(
            data,
            metadata: metadata,
            userData: userData,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
        return await play(track)
    }

    /// Plays in-memory audio data (MP3, WAV, FLAC), returning a handle to control playback.
    @discardableResult
    public func playData(
        _ data: Data,
        title: String? = nil,
        metadata: [String: String] = [:],
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) async throws -> TrackHandle {
        let meta = TrackMetadata(title: title, custom: metadata)
        return try await playData(
            data,
            metadata: meta,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
    }

    /// Plays in-memory audio bytes with rich metadata and user context.
    @discardableResult
    public func playBytes(
        _ bytes: [UInt8],
        metadata: TrackMetadata = TrackMetadata(),
        userData: TrackUserData = TrackUserData(),
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) async throws -> TrackHandle {
        let track = try AudioTrack.bytes(
            bytes,
            metadata: metadata,
            userData: userData,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
        return await play(track)
    }

    /// Plays in-memory audio bytes (MP3, WAV, FLAC), returning a handle to control playback.
    @discardableResult
    public func playBytes(
        _ bytes: [UInt8],
        title: String? = nil,
        metadata: [String: String] = [:],
        volume: Float = 1.0,
        isLooping: Bool = false,
        configuration: OpusConfiguration = .music
    ) async throws -> TrackHandle {
        let meta = TrackMetadata(title: title, custom: metadata)
        return try await playBytes(
            bytes,
            metadata: meta,
            volume: volume,
            isLooping: isLooping,
            configuration: configuration
        )
    }

    /// Plays a cached audio source on the mixer.
    @discardableResult
    public func playCached(
        _ source: CachedSource,
        metadata: TrackMetadata? = nil,
        volume: Float = 1.0,
        isLooping: Bool = false,
        userData: TrackUserData = TrackUserData()
    ) async -> TrackHandle {
        let track = source.track(metadata: metadata, volume: volume, isLooping: isLooping, userData: userData)
        return await play(track)
    }

    /// Plays a cached soundboard clip by key.
    @discardableResult
    public func playSoundboard(
        key: String,
        from cache: SoundboardCache = .shared,
        metadata: TrackMetadata? = nil,
        volume: Float = 1.0,
        isLooping: Bool = false,
        userData: TrackUserData = TrackUserData()
    ) async -> TrackHandle? {
        await cache.play(
            key: key,
            on: self,
            metadata: metadata,
            volume: volume,
            isLooping: isLooping,
            userData: userData
        )
    }

    private var _queue: TrackQueue?

    /// The playback queue for this voice connection.
    public var queue: TrackQueue {
        if let existing = _queue {
            return existing
        }
        let q = TrackQueue(connection: self)
        self._queue = q
        return q
    }

    /// Sets or clears the active Opus frame receiver.
    public func setFrameReceiver(_ receiver: (any OpusFrameReceiver)?) async {
        self.receiver = receiver
        await audioReceiver?.setReceiver(receiver)
    }

    /// Sets or clears the custom Opus decoder used for inbound `pcmStream` decoding.
    public func setCustomDecoder(_ decoder: (any CustomOpusDecoder)?) async {
        self.customDecoder = decoder
        await audioReceiver?.setCustomDecoder(decoder)
    }

    /// Returns an async stream of decrypted Opus audio frames for a specific user.
    public func audioStream(for userID: UserID) async -> AsyncStream<[UInt8]> {
        guard let receiver = self.audioReceiver else {
            return AsyncStream { $0.finish() }
        }
        return await receiver.audioStream(for: userID)
    }

    /// Returns an async stream of all decrypted Opus audio frames from all channel participants.
    public func audioStream() async -> AsyncStream<(userID: UserID, frame: [UInt8])> {
        guard let receiver = self.audioReceiver else {
            return AsyncStream { $0.finish() }
        }
        return await receiver.allAudioStreams()
    }

    /// Returns an async stream of decoded 20ms Float PCM audio frames for a specific user.
    public func pcmStream(for userID: UserID) async -> AsyncStream<[Float]> {
        guard let receiver = self.audioReceiver else {
            return AsyncStream { $0.finish() }
        }
        return await receiver.pcmStream(for: userID)
    }

    /// Returns an async stream of all decoded 20ms Float PCM audio frames across all channel participants.
    public func pcmStream() async -> AsyncStream<(userID: UserID, frame: [Float])> {
        guard let receiver = self.audioReceiver else {
            return AsyncStream { $0.finish() }
        }
        return await receiver.allPCMStreams()
    }

    /// Adds an audio filter to the connection's master mixer.
    public func addFilter(_ filter: any AudioFilter) async {
        await mixer.addFilter(filter)
    }

    /// Clears all master audio filters from the mixer.
    public func removeFilters() async {
        await mixer.removeFilters()
    }

    /// Automatically ducks background audio when voice channel participants speak.
    public func enableAutoDucking(duckVolume: Float = 0.25, onSpeaking: Bool = true) async {
        await mixer.addFilter(autoDucker)
        autoDucker.duckVolume = duckVolume
        autoDucker.setDucked(false)
        guard onSpeaking, autoDuckingTask == nil else { return }

        autoDuckingTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.speakingUpdates
            for await update in stream {
                let isSpeaking = update.flags.contains(.microphone)
                self.autoDucker.setDucked(isSpeaking)
            }
        }
    }

    /// Disables auto-ducking.
    public func disableAutoDucking() async {
        autoDuckingTask?.cancel()
        autoDuckingTask = nil
        autoDucker.unduck()
    }

    /// Explicitly updates the speaking state.
    public func setSpeaking(_ flags: SpeakingFlags) async throws {
        guard let ssrc = self.selfSSRC, let gateway = self.gateway else { return }
        let payload = VoiceGateway.SpeakingPayload(speaking: flags.rawValue, ssrc: ssrc)
        try await gateway.send(opcode: .speaking, data: payload)
    }

    /// Looks up a Discord user ID for a given audio SSRC.
    public func userID(for ssrc: UInt32) -> UserID? {
        ssrcUserMap[ssrc]
    }

    /// Feeds a voice state update from the Discord gateway.
    public func handleVoiceStateUpdate(_ update: VoiceState) async {
        guard update.guildID == self.guildID, update.userID == self.userID else { return }
        await self.handleVoiceStateUpdate(sessionID: update.sessionID, channelID: update.channelID)
    }

    /// Direct voice state update with primitive values.
    public func handleVoiceStateUpdate(sessionID: String, channelID: ChannelID?) async {
        logger.debug(
            "VoiceConnection handleVoiceStateUpdate",
            metadata: [
                "channel_id": .string(channelID?.description ?? "nil"),
                "session_id": .string(sessionID),
            ]
        )

        if channelID == nil {
            logger.debug("Voice state channel is nil; connection disconnected by server")
            await self.close()
            return
        }

        self.pendingSessionID = sessionID
        self.voiceStateReceived = true
        await self.tryStartHandshake()
    }

    /// Feeds a voice server update from the Discord gateway.
    public func handleVoiceServerUpdate(_ update: VoiceServerUpdate) async {
        guard update.guildID == self.guildID else { return }
        await self.handleVoiceServerUpdate(endpoint: update.endpoint, token: update.token)
    }

    /// Direct voice server update with primitive values.
    public func handleVoiceServerUpdate(endpoint: String?, token: String) async {
        guard let endpoint else {
            logger.debug(
                "VoiceConnection handleVoiceServerUpdate ignored (nil endpoint)",
                metadata: ["guild_id": .string(guildID.description)]
            )
            return
        }

        logger.debug(
            "VoiceConnection handleVoiceServerUpdate",
            metadata: ["endpoint": .string(endpoint)]
        )

        self.pendingToken = token
        self.pendingEndpoint = endpoint
        self.voiceServerReceived = true
        await self.tryStartHandshake()
    }

    private func tryStartHandshake() async {
        logger.debug(
            "VoiceConnection tryStartHandshake check",
            metadata: [
                "voiceStateReceived": .stringConvertible(voiceStateReceived),
                "voiceServerReceived": .stringConvertible(voiceServerReceived),
                "hasEndpoint": .stringConvertible(pendingEndpoint != nil),
                "hasToken": .stringConvertible(pendingToken != nil),
                "hasSessionID": .stringConvertible(pendingSessionID != nil),
            ]
        )

        guard voiceStateReceived, voiceServerReceived,
            let endpoint = pendingEndpoint,
            let token = pendingToken,
            let sessionId = pendingSessionID,
            let channelID = self.channelID
        else {
            return
        }

        logger.debug("Voice connection initiating handshake", metadata: ["endpoint": .string(endpoint)])

        // Clear flags so old handshake state is never reused
        self.voiceStateReceived = false
        self.voiceServerReceived = false
        self.pendingEndpoint = nil
        self.pendingToken = nil
        self.pendingSessionID = nil

        // Clean up any existing connection resources before initiating a new handshake
        if let scheduler = self.config.audioScheduler {
            await scheduler.unregister(guildID: self.guildID)
        }
        await self.audioSender?.stop()
        self.audioSender = nil
        await self.audioReceiver?.stop()
        self.audioReceiver = nil
        await self.udp?.close()
        self.udp = nil
        await self.gateway?.close()
        self.gateway = nil
        await self.dave?.close()
        self.dave = nil
        self.daveOutgoingTask?.cancel()
        self.daveOutgoingTask = nil
        self.eventProcessingTask?.cancel()
        self.eventProcessingTask = nil

        let daveSession: any DAVESession
        do {
            daveSession = try LiveDAVESession(userID: self.userID, channelID: channelID)
            self.dave = daveSession
        } catch {
            logger.error("Failed to initialize DAVE session", metadata: ["error": .string("\(error)")])
            updateState(.disconnected(nil))
            joinContinuation?.resume(throwing: VoiceConnectionError.failedToInitializeDAVE("\(error)"))
            joinContinuation = nil
            return
        }

        let gateway = VoiceGateway(
            eventLoopGroup: self.eventLoopGroup,
            maxReconnectAttempts: self.config.maxReconnectAttempts,
            logger: self.config.makeLogger("VoiceGateway")
        )
        self.gateway = gateway

        // Start listening to DAVE outgoing messages immediately so none are dropped
        daveOutgoingTask?.cancel()
        daveOutgoingTask = Task { [weak self] in
            for await message in await daveSession.outgoing {
                guard let self, !Task.isCancelled else { break }
                switch message {
                case .keyPackage(let bytes):
                    self.logger.debug(
                        "Sending DAVE MLS key package",
                        metadata: ["bytes": .stringConvertible(bytes.count)]
                    )
                    let frame = makeOutboundBinaryFrame(opcode: 26, payload: bytes)
                    try? await self.gateway?.sendBinary(frame)
                case .commitAndWelcome(let bytes):
                    self.logger.debug(
                        "Sending DAVE MLS commit and welcome",
                        metadata: ["bytes": .stringConvertible(bytes.count)]
                    )
                    let frame = makeOutboundBinaryFrame(opcode: 28, payload: bytes)
                    try? await self.gateway?.sendBinary(frame)
                case .readyForTransition(let transitionID):
                    self.logger.debug(
                        "Sending DAVE transition ready ack",
                        metadata: ["transitionID": .stringConvertible(transitionID)]
                    )
                    let ack = VoiceGateway.DAVETransitionReadyAck(transition_id: transitionID)
                    try? await self.gateway?.send(opcode: .daveTransitionReady, data: ack)
                case .invalidCommitWelcome(let transitionID):
                    self.logger.warning(
                        "Sending DAVE invalid commit and welcome notice",
                        metadata: ["transitionID": .stringConvertible(transitionID)]
                    )
                    let payload = VoiceGateway.DAVEInvalidCommitWelcome(transition_id: transitionID)
                    try? await self.gateway?.send(opcode: .daveMLSInvalidCommitWelcome, data: payload)
                }
            }
        }

        eventProcessingTask?.cancel()
        eventProcessingTask = Task { [weak self] in
            for await event in await gateway.events {
                guard let self else { break }
                await self.handleGatewayEvent(event)
            }
        }

        await gateway.connect(
            endpoint: endpoint,
            sessionId: sessionId,
            token: token,
            serverId: self.guildID,
            userId: self.userID,
            daveMaxProtocolVersion: daveSession.maxSupportedProtocolVersion
        )
    }

    private func handleGatewayEvent(_ event: VoiceGateway.InboundEvent) async {
        guard !isClosed else { return }

        switch event {
        case .hello:
            break

        case .ready(let ready):
            self.selfSSRC = ready.ssrc
            await self.handleReady(ready)

        case .sessionDescription(let desc):
            await self.handleSessionDescription(desc)

        case .speaking(let speaking):
            logger.trace(
                "Received voice speaking event",
                metadata: [
                    "ssrc": .stringConvertible(speaking.ssrc),
                    "userID": .stringConvertible(speaking.user_id?.description ?? "nil"),
                    "speaking": .stringConvertible(speaking.speaking),
                ]
            )
            let flags = SpeakingFlags(rawValue: speaking.speaking)
            if let uid = speaking.user_id, speaking.ssrc != 0 {
                self.ssrcUserMap[speaking.ssrc] = uid
                await self.audioReceiver?.mapSSRC(speaking.ssrc, to: uid)
                speakingContinuation.yield(SpeakingUpdate(userID: uid, ssrc: speaking.ssrc, flags: flags))
            } else if let uid = self.ssrcUserMap[speaking.ssrc] {
                speakingContinuation.yield(SpeakingUpdate(userID: uid, ssrc: speaking.ssrc, flags: flags))
            }

        case .clientsConnect(let cc):
            for uid in cc.user_ids {
                try? await dave?.addUser(uid)
            }

        case .clientDisconnect(let cd):
            try? await dave?.removeUser(cd.user_id)
            if let ssrc = ssrcUserMap.first(where: { $0.value == cd.user_id })?.key {
                ssrcUserMap.removeValue(forKey: ssrc)
            }
            await self.audioReceiver?.unmapUser(cd.user_id)

        case .davePrepareTransition(let trans):
            logger.debug(
                "Received DAVE prepare transition",
                metadata: [
                    "transition_id": .stringConvertible(trans.transition_id),
                    "protocol_version": .stringConvertible(trans.protocol_version),
                ]
            )
            try? await dave?.prepareTransition(
                id: trans.transition_id,
                protocolVersion: trans.protocol_version
            )
            if trans.transition_id != 0 {
                let ack = VoiceGateway.DAVETransitionReadyAck(transition_id: trans.transition_id)
                try? await self.gateway?.send(opcode: .daveTransitionReady, data: ack)
            }

        case .daveExecuteTransition(let exec):
            logger.debug(
                "Received DAVE execute transition",
                metadata: ["transition_id": .stringConvertible(exec.transition_id)]
            )
            try? await dave?.executeTransition(id: exec.transition_id)

        case .davePrepareEpoch(let epoch):
            logger.debug(
                "Received DAVE prepare epoch",
                metadata: [
                    "epoch": .stringConvertible(epoch.epoch),
                    "protocol_version": .stringConvertible(epoch.protocol_version),
                ]
            )
            try? await dave?.prepareEpoch(epoch.epoch, protocolVersion: epoch.protocol_version)

        case .daveMLSExternalSender(let payload):
            logger.debug(
                "Received DAVE MLS external sender",
                metadata: ["bytes": .stringConvertible(payload.count)]
            )
            try? await dave?.setExternalSender(payload)

        case .daveMLSProposals(let payload):
            logger.debug(
                "Received DAVE MLS proposals",
                metadata: ["bytes": .stringConvertible(payload.count)]
            )
            try? await dave?.processProposals(payload)

        case .daveAnnounceCommitTransition(let id, let commit):
            logger.debug(
                "Received DAVE announce commit transition",
                metadata: [
                    "id": .stringConvertible(id),
                    "commit_len": .stringConvertible(commit.count),
                ]
            )
            try? await dave?.announceCommitTransition(id: id, commit: commit)
            if id != 0 {
                logger.debug(
                    "Sending DAVE transition ready ack",
                    metadata: ["transition_id": .stringConvertible(id)]
                )
                let ack = VoiceGateway.DAVETransitionReadyAck(transition_id: id)
                try? await self.gateway?.send(opcode: .daveTransitionReady, data: ack)
            }

        case .daveMLSWelcome(let id, let welcome):
            logger.debug(
                "Received DAVE MLS welcome",
                metadata: [
                    "id": .stringConvertible(id),
                    "welcome_len": .stringConvertible(welcome.count),
                ]
            )
            try? await dave?.processWelcome(id: id, welcome: welcome)
            if id != 0 {
                logger.debug(
                    "Sending DAVE transition ready ack for welcome",
                    metadata: ["transition_id": .stringConvertible(id)]
                )
                let ack = VoiceGateway.DAVETransitionReadyAck(transition_id: id)
                try? await self.gateway?.send(opcode: .daveTransitionReady, data: ack)
            }

        case .reconnecting(let attempt):
            logger.debug("Voice gateway reconnecting", metadata: ["attempt": .stringConvertible(attempt)])
            updateState(.reconnecting(attempt: attempt))

        case .disconnected(let code, let needsNewSession):
            logger.debug(
                "Voice gateway disconnected",
                metadata: [
                    "code": .string("\(String(describing: code))"),
                    "needsNewSession": .stringConvertible(needsNewSession),
                ]
            )
            updateState(.disconnected(code))
            if needsNewSession {
                await self.handleNeedNewSession()
            } else {
                await self.close()
            }

        default:
            break
        }
    }

    private func handleReady(_ ready: VoiceGateway.Ready) async {
        guard let (encryptor, mode) = preferredEncryptor(from: ready.modes) else {
            logger.error(
                "No compatible encryption mode found in server modes",
                metadata: ["modes": .string("\(ready.modes)")]
            )
            updateState(.disconnected(nil))
            joinContinuation?.resume(throwing: VoiceConnectionError.noCompatibleEncryptionMode)
            joinContinuation = nil
            return
        }
        self.encryptor = encryptor

        let udp = VoiceUDP(
            eventLoopGroup: self.eventLoopGroup,
            logger: self.config.makeLogger("VoiceUDP")
        )
        self.udp = udp

        do {
            let (externalIP, externalPort) = try await udp.discover(
                ip: ready.ip,
                port: ready.port,
                ssrc: ready.ssrc
            )
            logger.debug(
                "Discovered external IP and port",
                metadata: [
                    "ip": .string(externalIP), "port": .stringConvertible(externalPort),
                    "mode": .string(mode.rawValue),
                ]
            )

            try? await dave?.assignSSRC(ready.ssrc)

            let selectProtocol = VoiceGateway.SelectProtocol(
                protocol_name: "udp",
                data: .init(address: externalIP, port: Int(externalPort), mode: mode.rawValue)
            )
            try await gateway?.send(opcode: .selectProtocol, data: selectProtocol)
        } catch {
            logger.error("IP discovery failed", metadata: ["error": .string("\(error)")])
            updateState(.disconnected(nil))
            joinContinuation?.resume(throwing: error)
            joinContinuation = nil
        }
    }

    private func handleSessionDescription(_ desc: VoiceGateway.SessionDescription) async {
        logger.debug(
            "Received session description",
            metadata: [
                "mode": .string(desc.mode),
                "dave_protocol_version": .string(String(describing: desc.dave_protocol_version)),
                "secret_key_len": .stringConvertible(desc.secret_key.count),
            ]
        )
        self.secretKey = desc.secret_key

        if let version = desc.dave_protocol_version {
            logger.debug(
                "Acknowledging DAVE protocol version",
                metadata: ["version": .stringConvertible(version)]
            )
            try? await dave?.acknowledgeProtocolVersion(version)
        } else {
            logger.debug("Acknowledging DAVE protocol version 0 (passthrough)")
            try? await dave?.acknowledgeProtocolVersion(0)
        }

        // Start AudioSender and AudioReceiver
        if let dave = self.dave, let encryptor = self.encryptor, let udp = self.udp {
            let sender = AudioSender(dave: dave, logger: self.logger)
            await sender.setProvider(self.provider)
            self.audioSender = sender

            let ssrc = self.selfSSRC ?? 0
            let key = self.secretKey

            await sender.prepare(
                ssrc: ssrc,
                encryptor: encryptor,
                key: key,
                send: { [weak self] packet in
                    guard let self else { return }
                    try await self.udp?.send(packet)
                },
                speaking: { [weak self] flags in
                    guard let self else { return }
                    try await self.setSpeaking(flags)
                }
            )

            if let scheduler = self.config.audioScheduler {
                await scheduler.register(guildID: self.guildID, target: sender)
            } else {
                Task {
                    await sender.startLoop()
                }
            }

            let receiver = AudioReceiver(
                packets: await udp.packets,
                encryptor: encryptor,
                key: key,
                dave: dave,
                logger: self.logger
            )
            if let custom = self.customDecoder {
                await receiver.setCustomDecoder(custom)
            }
            // Pre-populate any existing SSRC mappings
            for (s, u) in self.ssrcUserMap {
                await receiver.mapSSRC(s, to: u)
            }
            await receiver.setReceiver(self.receiver)
            self.audioReceiver = receiver

            Task {
                await receiver.start()
            }
        }

        updateState(.ready)
        joinContinuation?.resume()
        joinContinuation = nil
    }

    private func handleNeedNewSession() async {
        await self.audioSender?.stop()
        self.audioSender = nil
        await self.audioReceiver?.stop()
        self.audioReceiver = nil
        await self.udp?.close()
        self.udp = nil
        await self.dave?.close()
        self.dave = nil

        if let channelID = self.channelID {
            let update = VoiceStateUpdate(
                guildID: guildID,
                channelID: channelID,
                selfMute: false,
                selfDeaf: false
            )
            await sendVoiceStateUpdate(update)
        }
    }

    /// Closes the voice connection and disconnects from the channel.
    public func close() async {
        guard !isClosed else { return }
        self.isClosed = true
        logger.debug("VoiceConnection closing", metadata: ["guild_id": .string(guildID.description)])

        updateState(.disconnected(nil))
        stateContinuation.finish()
        speakingContinuation.finish()

        joinContinuation?.resume(throwing: VoiceConnectionError.connectionClosed)
        joinContinuation = nil

        eventProcessingTask?.cancel()
        eventProcessingTask = nil
        daveOutgoingTask?.cancel()
        daveOutgoingTask = nil
        autoDuckingTask?.cancel()
        autoDuckingTask = nil

        if let scheduler = self.config.audioScheduler {
            await scheduler.unregister(guildID: self.guildID)
        }
        await audioSender?.stop()
        audioSender = nil
        await audioReceiver?.stop()
        audioReceiver = nil
        await _queue?.stop()
        _queue = nil
        await udp?.close()
        udp = nil
        await gateway?.close()
        gateway = nil
        await dave?.close()
        dave = nil

        let update = VoiceStateUpdate(
            guildID: guildID,
            channelID: nil,
            selfMute: false,
            selfDeaf: false
        )
        await sendVoiceStateUpdate(update)
    }
}
