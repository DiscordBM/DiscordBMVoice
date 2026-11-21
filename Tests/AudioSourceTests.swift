import Audio
import Foundation
import Testing

@testable import DiscordBMVoice

@Suite("Audio Source Tests")
struct AudioSourceTests {

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
        withUnsafeBytes(of: UInt16(1).littleEndian) { wav.append(contentsOf: $0) }  // PCM format
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
                wav.append(contentsOf: $0)  // Left
                wav.append(contentsOf: $0)  // Right
            }
        }

        return wav
    }

    @Test("AudioSource decodes in-memory WAV and yields Opus frames")
    func audioSourceDecoding() async throws {
        let wav = generateTestWav(durationSeconds: 0.1)  // 100ms = 5 frames of 20ms
        let source = try AudioSource(bytes: wav)

        let initialFrame = await source.nextFrame()
        #expect(initialFrame != nil)
        #expect(initialFrame?.isEmpty == false)

        var count = 1
        while let _ = await source.nextFrame() {
            count += 1
        }

        #expect(count >= 4)  // Should yield approximately 5 20ms frames
        #expect(await source.sourceChannels == 2)
        #expect(await source.sourceSampleRate == 48000)
    }

    @Test("AudioSource reset restarts playback from the beginning")
    func audioSourceReset() async throws {
        let wav = generateTestWav(durationSeconds: 0.06)  // ~3 frames
        let source = try AudioSource(bytes: wav)

        let frame1 = await source.nextFrame()
        #expect(frame1 != nil)

        // Drain remainder
        while let _ = await source.nextFrame() {}

        // At end, nextFrame should return nil
        #expect(await source.nextFrame() == nil)

        // Reset
        await source.reset()

        // Should produce frames again
        let frameAfterReset = await source.nextFrame()
        #expect(frameAfterReset != nil)
        #expect(frameAfterReset?.count == frame1?.count)
    }

    @Test("AudioSource seeking re-positions the stream")
    func audioSourceSeeking() async throws {
        let wav = generateTestWav(durationSeconds: 0.2)
        let source = try AudioSource(bytes: wav)

        let initialFrame = await source.nextFrame()
        #expect(initialFrame != nil)

        // Seek back to start
        try await source.seek(to: 0.0)

        let seekedFrame = await source.nextFrame()
        #expect(seekedFrame != nil)
    }

    @Test("AudioSource seeking with Duration")
    func audioSourceDurationSeeking() async throws {
        let wav = generateTestWav(durationSeconds: 0.3)
        let source = try AudioSource(bytes: wav)

        let initialFrame = await source.nextFrame()
        #expect(initialFrame != nil)

        try await source.seek(to: .milliseconds(100))
        let seekedFrame = await source.nextFrame()
        #expect(seekedFrame != nil)
    }

    @Test("AudioTrack integration with AudioSource")
    func audioTrackWithAudioSource() async throws {
        let wav = generateTestWav(durationSeconds: 0.08)
        let track = try AudioTrack.bytes(wav, title: "Test Audio")

        #expect(track.title == "Test Audio")

        let frame = await track.nextFrame()
        #expect(frame != nil)
        #expect(frame?.isEmpty == false)
    }
}
