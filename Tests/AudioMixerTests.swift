import Audio
import Foundation
import Testing

@testable import DiscordBMVoice

@Suite("Audio Mixer Tests")
struct AudioMixerTests {

    @Test("Empty mixer returns nil frames and reports zero tracks")
    func testMixerEmptyState() async {
        let mixer = AudioMixer()

        #expect(await mixer.trackCount == 0)
        #expect(await mixer.tracks.isEmpty)
        #expect(await mixer.isPlaying == false)
        #expect(await mixer.nextPCMFrame() == nil)
        #expect(await mixer.nextFrame() == nil)
    }

    @Test("Single Opus-native track passes through directly at unity gain")
    func testMixerSingleTrackPassthrough() async {
        let mixer = AudioMixer()
        let dummyOpus: [[UInt8]] = [
            [0xAA, 0xBB, 0xCC],
            [0xDD, 0xEE, 0xFF],
        ]
        let provider = MemoryOpusFrameProvider(frames: dummyOpus)
        let track = AudioTrack(provider: provider)

        await mixer.add(track)

        #expect(await mixer.trackCount == 1)
        #expect(await mixer.isPlaying == true)

        let f1 = await mixer.nextFrame()
        #expect(f1 == [0xAA, 0xBB, 0xCC])

        let f2 = await mixer.nextFrame()
        #expect(f2 == [0xDD, 0xEE, 0xFF])

        let f3 = await mixer.nextFrame()
        #expect(f3 == nil)
        #expect(await mixer.trackCount == 0)
    }

    @Test("Concurrent multi-track PCM mixing combines multiple streams accurately")
    func testMixerConcurrentMultiTrackPlayback() async {
        let mixer = AudioMixer()

        // Track 1: Constant 0.5 amplitude, volume 0.4 -> contribution = 0.20
        let pcm1 = [Float](repeating: 0.5, count: AudioConstants.frameSampleCount)
        let provider1 = MemoryPCMFrameProvider(frames: [pcm1])
        let track1 = AudioTrack(pcmProvider: provider1, title: "Background Music", volume: 0.4)

        // Track 2: Constant 0.3 amplitude, volume 1.0 -> contribution = 0.30
        let pcm2 = [Float](repeating: 0.3, count: AudioConstants.frameSampleCount)
        let provider2 = MemoryPCMFrameProvider(frames: [pcm2])
        let track2 = AudioTrack(pcmProvider: provider2, title: "TTS Voice", volume: 1.0)

        await mixer.add(track1)
        await mixer.add(track2)

        #expect(await mixer.trackCount == 2)
        #expect(await mixer.isPlaying == true)

        // Mixed frame should equal 0.20 + 0.30 = 0.50
        guard let mixed = await mixer.nextPCMFrame() else {
            Issue.record("Expected mixed PCM frame")
            return
        }

        #expect(mixed.count == AudioConstants.frameSampleCount)
        for sample in mixed {
            #expect(abs(sample - 0.50) < 0.001)
        }
    }

    @Test("Master volume scales the mixed output")
    func testMixerMasterVolume() async {
        let mixer = AudioMixer()
        await mixer.setMasterVolume(0.5)

        let pcm = [Float](repeating: 0.8, count: AudioConstants.frameSampleCount)
        let provider = MemoryPCMFrameProvider(frames: [pcm])
        let track = AudioTrack(pcmProvider: provider, volume: 1.0)
        await mixer.add(track)

        guard let mixed = await mixer.nextPCMFrame() else {
            Issue.record("Expected mixed PCM frame")
            return
        }

        // 0.8 * 1.0 (track) * 0.5 (master) = 0.4
        for sample in mixed {
            #expect(abs(sample - 0.40) < 0.001)
        }
    }

    @Test("Limiter clamps summed amplitudes to [-1.0, 1.0]")
    func testMixerClampingLimiter() async {
        let mixer = AudioMixer()

        // Two signals with 0.8 amplitude sum to 1.6 -> must clamp to 1.0
        let pcmA = [Float](repeating: 0.8, count: AudioConstants.frameSampleCount)
        let pcmB = [Float](repeating: 0.8, count: AudioConstants.frameSampleCount)

        let trackA = AudioTrack(pcmProvider: MemoryPCMFrameProvider(frames: [pcmA]), volume: 1.0)
        let trackB = AudioTrack(pcmProvider: MemoryPCMFrameProvider(frames: [pcmB]), volume: 1.0)

        await mixer.add(trackA)
        await mixer.add(trackB)

        guard let mixed = await mixer.nextPCMFrame() else {
            Issue.record("Expected mixed frame")
            return
        }

        for sample in mixed {
            #expect(sample <= 1.0)
            #expect(sample >= -1.0)
            #expect(abs(sample - 1.0) < 0.001)
        }
    }

    @Test("Paused track contributes silence without being removed")
    func testMixerPauseAndResumeTrack() async {
        let mixer = AudioMixer()

        let pcm1 = [Float](repeating: 0.4, count: AudioConstants.frameSampleCount)
        let pcm2 = [Float](repeating: 0.3, count: AudioConstants.frameSampleCount)

        let track1 = AudioTrack(pcmProvider: MemoryPCMFrameProvider(frames: [pcm1, pcm1, pcm1]), volume: 1.0)
        let track2 = AudioTrack(pcmProvider: MemoryPCMFrameProvider(frames: [pcm2, pcm2, pcm2]), volume: 1.0)

        let h1 = await mixer.add(track1)
        let _ = await mixer.add(track2)

        // Both playing: 0.4 + 0.3 = 0.7
        let f1 = await mixer.nextPCMFrame()
        #expect(abs((f1?.first ?? 0) - 0.7) < 0.001)

        // Pause track 1: only track 2 heard (0.3)
        await h1.pause()
        #expect(await h1.state == .paused)
        #expect(await mixer.trackCount == 2)

        let f2 = await mixer.nextPCMFrame()
        #expect(abs((f2?.first ?? 0) - 0.3) < 0.001)

        // Resume track 1: both heard again (0.4 + 0.3 = 0.7)
        await h1.resume()
        #expect(await h1.state == .playing)

        let f3 = await mixer.nextPCMFrame()
        #expect(abs((f3?.first ?? 0) - 0.7) < 0.001)
    }

    @Test("Finished track is pruned while longer track continues")
    func testMixerFinishedTrackPruning() async {
        let mixer = AudioMixer()

        // Short track has 1 frame
        let shortPCM = [Float](repeating: 0.5, count: AudioConstants.frameSampleCount)
        let shortTrack = AudioTrack(pcmProvider: MemoryPCMFrameProvider(frames: [shortPCM]), volume: 1.0)

        // Long track has 2 frames
        let longPCM = [Float](repeating: 0.2, count: AudioConstants.frameSampleCount)
        let longTrack = AudioTrack(pcmProvider: MemoryPCMFrameProvider(frames: [longPCM, longPCM]), volume: 1.0)

        await mixer.add(shortTrack)
        await mixer.add(longTrack)
        #expect(await mixer.trackCount == 2)

        // Frame 1: both mixed (0.5 + 0.2 = 0.7)
        let f1 = await mixer.nextPCMFrame()
        #expect(abs((f1?.first ?? 0) - 0.7) < 0.001)

        // Frame 2: shortTrack has ended, pruned; only longTrack remains (0.2)
        let f2 = await mixer.nextPCMFrame()
        #expect(abs((f2?.first ?? 0) - 0.2) < 0.001)
        #expect(await mixer.trackCount == 1)

        // Frame 3: longTrack has ended, mixer is empty
        let f3 = await mixer.nextPCMFrame()
        #expect(f3 == nil)
        #expect(await mixer.trackCount == 0)
    }

    @Test("StopAll stops and clears all tracks")
    func testMixerStopAll() async {
        let mixer = AudioMixer()

        let t1 = AudioTrack(pcmProvider: MemoryPCMFrameProvider(frames: [[0.1]]))
        let t2 = AudioTrack(pcmProvider: MemoryPCMFrameProvider(frames: [[0.2]]))

        let h1 = await mixer.add(t1)
        let h2 = await mixer.add(t2)

        #expect(await mixer.trackCount == 2)

        await mixer.stopAll()

        #expect(await mixer.trackCount == 0)
        #expect(await h1.state == .stopped)
        #expect(await h2.state == .stopped)
        #expect(await mixer.nextPCMFrame() == nil)
    }

    @Test("Looping track repeats in mixer")
    func testMixerLoopingTrack() async {
        let mixer = AudioMixer()

        let pcm = [Float](repeating: 0.42, count: AudioConstants.frameSampleCount)
        let provider = MemoryPCMFrameProvider(frames: [pcm])
        let track = AudioTrack(pcmProvider: provider, volume: 1.0, isLooping: true)

        await mixer.add(track)

        for _ in 0..<5 {
            guard let frame = await mixer.nextPCMFrame() else {
                Issue.record("Expected looping frame")
                return
            }
            #expect(abs(frame[0] - 0.42) < 0.001)
        }

        #expect(await mixer.trackCount == 1)
    }

    @Test("VoiceConnection routes play calls into its integrated mixer")
    func testVoiceConnectionIntegratedMixer() async {
        let connection = VoiceConnection(
            guildID: 100,
            userID: 200,
            sendVoiceStateUpdate: { _ in }
        )

        let t1 = AudioTrack(pcmProvider: MemoryPCMFrameProvider(frames: [[0.5]]), title: "BGM")
        let t2 = AudioTrack(pcmProvider: MemoryPCMFrameProvider(frames: [[0.5]]), title: "SFX")

        let h1 = await connection.play(t1)
        let h2 = await connection.play(t2)

        #expect(await connection.mixer.trackCount == 2)
        #expect(h1.title == "BGM")
        #expect(h2.title == "SFX")

        await connection.stopAll()
        #expect(await connection.mixer.trackCount == 0)
    }

    private func generateTestWav(
        freq: Double = 440.0,
        durationSeconds: Double = 0.1,
        sampleRate: Int = 48000
    ) -> [UInt8] {
        let channels: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        let totalFrames = Int(Double(sampleRate) * durationSeconds)
        let dataSize = totalFrames * Int(channels) * Int(bitsPerSample / 8)

        var wav = [UInt8]()
        wav.reserveCapacity(44 + dataSize)

        wav.append(contentsOf: "RIFF".utf8)
        withUnsafeBytes(of: UInt32(36 + dataSize).littleEndian) { wav.append(contentsOf: $0) }
        wav.append(contentsOf: "WAVE".utf8)

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

        wav.append(contentsOf: "data".utf8)
        withUnsafeBytes(of: UInt32(dataSize).littleEndian) { wav.append(contentsOf: $0) }

        for frame in 0..<totalFrames {
            let t = Double(frame) / Double(sampleRate)
            let sample = sin(2.0 * Double.pi * freq * t) * 0.5
            let intVal = Int16(sample * 32767.0)
            withUnsafeBytes(of: intVal.littleEndian) {
                wav.append(contentsOf: $0)
                wav.append(contentsOf: $0)
            }
        }

        return wav
    }

    @Test("AudioSource conforms to PCMFrameProvider and yields valid PCM frames")
    func testAudioSourceDirectPCMReading() async throws {
        let wav = generateTestWav(freq: 440.0, durationSeconds: 0.06)
        let source = try AudioSource(bytes: wav)

        let pcm = await source.nextPCMFrame()
        #expect(pcm != nil)
        #expect(pcm?.count == AudioConstants.frameSampleCount)
    }

    @Test("Concurrent AudioSource tracks are mixed and encoded to valid Opus packets")
    func testMixerOpusEncodingConcurrentTracks() async throws {
        let mixer = AudioMixer()

        let wav1 = generateTestWav(freq: 440.0, durationSeconds: 0.1)
        let wav2 = generateTestWav(freq: 880.0, durationSeconds: 0.1)

        let t1 = try await mixer.playBytes(wav1, title: "Tone 440", volume: 0.4)
        let t2 = try await mixer.playBytes(wav2, title: "Tone 880", volume: 1.0)

        #expect(await mixer.trackCount == 2)
        #expect(t1.title == "Tone 440")
        #expect(t2.title == "Tone 880")

        // Pull Opus-encoded mixed frame
        guard let opusFrame = await mixer.nextFrame() else {
            Issue.record("Expected Opus-encoded mixed frame")
            return
        }

        #expect(opusFrame.isEmpty == false)

        // Decode the Opus packet to verify it is valid Opus audio
        let decoder = try OpusDecoder(channels: 2)
        let decodedPCM = try decoder.decode(bytes: opusFrame)
        #expect(decodedPCM.count == AudioConstants.frameSampleCount)
    }
}
