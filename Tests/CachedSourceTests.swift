import Audio
import Foundation
import Testing

@testable import DiscordBMVoice

@Suite("Cached Source & Soundboard Tests")
struct CachedSourceTests {

    /// Generates a valid in-memory PCM 16-bit stereo WAV buffer.
    private func generateTestWav(durationSeconds: Double = 0.2, sampleRate: Int = 48000) -> [UInt8] {
        let channels: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        let totalFrames = Int(Double(sampleRate) * durationSeconds)
        let dataSize = totalFrames * Int(channels) * Int(bitsPerSample / 8)

        var wav = [UInt8]()
        wav.reserveCapacity(44 + dataSize)

        // RIFF header
        wav.append(contentsOf: "RIFF".utf8)
        withUnsafeBytes(of: UInt32(36 + dataSize).littleEndian) { wav.append(contentsOf: $0) }
        wav.append(contentsOf: "WAVE".utf8)

        // fmt subchunk
        wav.append(contentsOf: "fmt ".utf8)
        withUnsafeBytes(of: UInt32(16).littleEndian) { wav.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { wav.append(contentsOf: $0) }
        withUnsafeBytes(of: channels.littleEndian) { wav.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { wav.append(contentsOf: $0) }
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        withUnsafeBytes(of: byteRate.littleEndian) { wav.append(contentsOf: $0) }
        let blockAlign = channels * (bitsPerSample / 8)
        withUnsafeBytes(of: blockAlign.littleEndian) { wav.append(contentsOf: $0) }
        withUnsafeBytes(of: bitsPerSample.littleEndian) { wav.append(contentsOf: $0) }

        // data subchunk
        wav.append(contentsOf: "data".utf8)
        withUnsafeBytes(of: UInt32(dataSize).littleEndian) { wav.append(contentsOf: $0) }

        // Sine wave audio samples (440Hz)
        for frame in 0..<totalFrames {
            let t = Double(frame) / Double(sampleRate)
            let sample = sin(2.0 * Double.pi * 440.0 * t) * 0.5
            let intVal = Int16(sample * 32767.0)
            withUnsafeBytes(of: intVal.littleEndian) {
                wav.append(contentsOf: $0)
                wav.append(contentsOf: $0)
            }
        }

        return wav
    }

    @Test("CachedSource initialized with pre-encoded Opus frames")
    func cachedSourceOpusInit() async throws {
        let dummyFrames: [[UInt8]] = [
            [0xF8, 0xFF, 0xFE],
            [0xF8, 0xFF, 0xFD],
            [0xF8, 0xFF, 0xFC],
        ]
        let metadata = TrackMetadata(title: "Chime SFX", requesterID: 123_456)
        let source = CachedSource(opusFrames: dummyFrames, metadata: metadata)

        #expect(source.kind == .opus)
        #expect(source.frameCount == 3)
        #expect(abs(source.durationSeconds - 0.06) < 0.001)
        #expect(source.duration == .milliseconds(60))
        #expect(source.byteCount == 9)
        #expect(source.metadata.title == "Chime SFX")
        #expect(source.metadata.requesterID == 123_456)

        let provider1 = source.opusProvider()
        let provider2 = source.opusProvider()

        let frame1 = await provider1.nextFrame()
        let frame2 = await provider2.nextFrame()
        #expect(frame1 == [0xF8, 0xFF, 0xFE])
        #expect(frame2 == [0xF8, 0xFF, 0xFE])

        _ = await provider1.nextFrame()
        _ = await provider1.nextFrame()
        let endFrame1 = await provider1.nextFrame()
        #expect(endFrame1 == nil)

        let frame2Next = await provider2.nextFrame()
        #expect(frame2Next == [0xF8, 0xFF, 0xFD])
    }

    @Test("CachedSource initialized with pre-decoded PCM frames")
    func cachedSourcePCMInit() async throws {
        let pcmFrame = [Float](repeating: 0.25, count: AudioConstants.frameSampleCount)
        let frames = [pcmFrame, pcmFrame]
        let source = CachedSource(pcmFrames: frames, metadata: TrackMetadata(title: "Beep SFX"))

        #expect(source.kind == .pcm)
        #expect(source.frameCount == 2)
        #expect(abs(source.durationSeconds - 0.04) < 0.001)
        #expect(source.duration == .milliseconds(40))
        #expect(source.byteCount == 2 * AudioConstants.frameSampleCount * MemoryLayout<Float>.size)
        #expect(source.metadata.title == "Beep SFX")

        let provider = source.pcmProvider()
        let first = await provider.nextPCMFrame()
        #expect(first?.count == AudioConstants.frameSampleCount)
        #expect(first?[0] == 0.25)

        let second = await provider.nextPCMFrame()
        #expect(second != nil)
        let finished = await provider.nextPCMFrame()
        #expect(finished == nil)
    }

    @Test("CachedSource preloads from Data")
    func cachedSourceFromData() async throws {
        let wav = generateTestWav(durationSeconds: 0.1)  // 100ms = 5 frames
        let data = Data(wav)

        let pcmSource = try CachedSource.pcm(fromData: data, metadata: TrackMetadata(title: "WAV PCM Clip"))
        #expect(pcmSource.kind == .pcm)
        #expect(pcmSource.frameCount == 5)
        #expect(pcmSource.metadata.title == "WAV PCM Clip")

        let opusSource = try CachedSource.opus(fromData: data, metadata: TrackMetadata(title: "WAV Opus Clip"))
        #expect(opusSource.kind == .opus)
        #expect(opusSource.frameCount == 5)
        #expect(opusSource.metadata.title == "WAV Opus Clip")
    }

    @Test("CachedSource creates independent AudioTracks concurrently")
    func cachedSourceIndependentTracks() async throws {
        let dummyFrames: [[UInt8]] = [
            [0x01, 0x02],
            [0x03, 0x04],
        ]
        let source = CachedSource(opusFrames: dummyFrames, metadata: TrackMetadata(title: "Mem Clip"))

        let track1 = source.track(volume: 1.0)
        let track2 = source.track(volume: 1.0)

        #expect(track1.id != track2.id)
        #expect(await track1.volume == 1.0)
        #expect(await track2.volume == 1.0)

        let t1f1 = await track1.nextFrame()
        #expect(t1f1 == [0x01, 0x02])

        let t2f1 = await track2.nextFrame()
        #expect(t2f1 == [0x01, 0x02])

        let mixer = AudioMixer()
        let pcmFrame = [Float](repeating: 0.5, count: AudioConstants.frameSampleCount)
        let pcmSource = CachedSource(pcmFrames: [pcmFrame])

        let pcmTrack = pcmSource.track(volume: 0.5)
        await mixer.add(pcmTrack)
        let mixed = await mixer.nextPCMFrame()
        #expect(mixed?[0] == 0.25)
    }

    @Test("SoundboardCache registration, lookup, and memory tracking")
    func soundboardCacheManagement() async throws {
        let cache = SoundboardCache()

        #expect(await cache.count == 0)
        #expect(await cache.totalBytes == 0)
        #expect(await !cache.contains(key: "horn"))

        let pcmFrame = [Float](repeating: 0.1, count: AudioConstants.frameSampleCount)
        await cache.register(key: "chime", pcmFrames: [pcmFrame, pcmFrame], metadata: TrackMetadata(title: "Chime"))
        await cache.register(
            key: "horn",
            opusFrames: [[0x01, 0x02], [0x03, 0x04]],
            metadata: TrackMetadata(title: "Airhorn")
        )

        #expect(await cache.count == 2)
        #expect(await cache.contains(key: "chime"))
        #expect(await cache.contains(key: "horn"))
        #expect(await cache.totalBytes > 0)

        let chimeSource = await cache.get(key: "chime")
        #expect(chimeSource?.kind == .pcm)
        #expect(chimeSource?.metadata.title == "Chime")

        let track = await cache.track(key: "horn", volume: 0.7)
        #expect(track != nil)
        #expect(await track?.volume == 0.7)

        await cache.remove(key: "chime")
        #expect(await cache.count == 1)
        #expect(await !cache.contains(key: "chime"))

        await cache.clear()
        #expect(await cache.count == 0)
        #expect(await cache.totalBytes == 0)
    }

    @Test("SoundboardCache preloads from in-memory Data")
    func soundboardCachePreloadData() async throws {
        let cache = SoundboardCache()
        let wav = generateTestWav(durationSeconds: 0.06)  // 60ms = 3 frames
        let data = Data(wav)

        try await cache.preload(key: "sfx_pcm", data: data, kind: .pcm)
        try await cache.preload(key: "sfx_opus", data: data, kind: .opus)

        #expect(await cache.contains(key: "sfx_pcm"))
        #expect(await cache.contains(key: "sfx_opus"))
        #expect(await cache.get(key: "sfx_pcm")?.kind == .pcm)
        #expect(await cache.get(key: "sfx_opus")?.kind == .opus)
    }

    @Test("VoiceConnection and TrackQueue cached soundboard playback")
    func connectionAndQueueSoundboardPlayback() async throws {
        let fakeConnection = VoiceConnection(
            guildID: 11_111,
            userID: 22_222,
            sendVoiceStateUpdate: { _ in }
        )

        let cache = SoundboardCache()
        let pcmFrame = [Float](repeating: 0.2, count: AudioConstants.frameSampleCount)
        await cache.register(key: "beep", pcmFrames: [pcmFrame, pcmFrame], metadata: TrackMetadata(title: "Beep SFX"))

        let handle = await fakeConnection.playSoundboard(key: "beep", from: cache, volume: 0.8)
        #expect(handle != nil)
        #expect(await handle?.volume == 0.8)
        #expect(handle?.title == "Beep SFX")
        #expect(await fakeConnection.mixer.trackCount == 1)

        let queue = await fakeConnection.queue
        let qHandle = await queue.addSoundboard(key: "beep", from: cache, volume: 0.5)
        #expect(qHandle != nil)
        #expect(await queue.count == 1)
        #expect(await queue.currentTrack?.title == "Beep SFX")
    }
}
