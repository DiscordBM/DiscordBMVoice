import Audio
import Foundation
import Testing

@testable import DiscordBMVoice

@Suite("Audio Filter & Pipeline Tests")
struct AudioFilterTests {

    @Test("VolumeFilter scales PCM samples linearly")
    func volumeFilterScaling() {
        var samples: [Float] = [0.2, -0.4, 0.8, -1.0]
        let filter = VolumeFilter(volume: 0.5)
        filter.process(pcm: &samples)

        #expect(abs(samples[0] - 0.1) < 1e-5)
        #expect(abs(samples[1] - (-0.2)) < 1e-5)
        #expect(abs(samples[2] - 0.4) < 1e-5)
        #expect(abs(samples[3] - (-0.5)) < 1e-5)
    }

    @Test("SoftLimiterFilter suppresses amplitudes above threshold")
    func softLimiterCompression() {
        var samples: [Float] = [0.5, 0.96, 1.5, -1.8]
        let limiter = SoftLimiterFilter(threshold: 0.90)
        limiter.process(pcm: &samples)

        // Below threshold remains uncompressed
        #expect(abs(samples[0] - 0.5) < 1e-5)
        // Above threshold is soft-compressed and strictly clamped
        #expect(samples[1] < 0.96)
        #expect(samples[2] <= 1.0)
        #expect(samples[3] >= -1.0)
    }

    @Test("AutoDucker smoothly transitions volume across frames")
    func autoDuckerTransitions() {
        let ducker = AutoDucker(duckVolume: 0.2, attackFrames: 2, releaseFrames: 2)

        #expect(ducker.volume == 1.0)
        #expect(!ducker.isDucked)

        ducker.duck()
        #expect(ducker.isDucked)

        // Process frame 1 of attack
        var pcm1 = [Float](repeating: 1.0, count: 100)
        ducker.process(pcm: &pcm1)
        let volAfterF1 = ducker.volume
        #expect(volAfterF1 < 1.0)
        #expect(volAfterF1 >= 0.2)

        // Process frame 2 of attack -> reaches duck volume
        var pcm2 = [Float](repeating: 1.0, count: 100)
        ducker.process(pcm: &pcm2)
        let volAfterF2 = ducker.volume
        #expect(abs(volAfterF2 - 0.2) < 1e-4)

        // Unduck
        ducker.unduck()
        #expect(!ducker.isDucked)

        // Process release frames
        var pcm3 = [Float](repeating: 1.0, count: 100)
        ducker.process(pcm: &pcm3)
        let volAfterF3 = ducker.volume
        #expect(volAfterF3 > 0.2)

        var pcm4 = [Float](repeating: 1.0, count: 100)
        ducker.process(pcm: &pcm4)
        let volAfterF4 = ducker.volume
        #expect(abs(volAfterF4 - 1.0) < 1e-4)
    }

    @Test("VoiceActivityDetector detects speech energy and applies hangover")
    func vadEnergyAndHangover() {
        let vad = VoiceActivityDetector(thresholdDB: -40.0, hangoverFrames: 2)

        // Silence frame (all zeroes)
        let silence = [Float](repeating: 0.0, count: 1920)
        #expect(!vad.process(pcm: silence))
        #expect(!vad.isSpeaking)

        // Speech frame (full volume sine wave, high energy ~ -3dB)
        var speech = [Float](repeating: 0.0, count: 1920)
        for i in 0..<speech.count {
            speech[i] = sin(Float(i) * 0.1) * 0.8
        }
        #expect(vad.process(pcm: speech))
        #expect(vad.isSpeaking)

        // Frame 1 of silence -> hangover keeps speaking state true
        #expect(vad.process(pcm: silence))
        #expect(vad.isSpeaking)

        // Frame 2 of silence -> hangover threshold reached, returns false
        #expect(!vad.process(pcm: silence))
        #expect(!vad.isSpeaking)
    }

    @Test("AudioTrack applies custom AudioFilter in nextPCMFrame")
    func trackFilterPipeline() async {
        let pcmData = [Float](repeating: 0.5, count: AudioConstants.frameSampleCount)
        let provider = MemoryPCMFrameProvider(frames: [pcmData])
        let track = AudioTrack(pcmProvider: provider)

        // Attach custom filter doubling amplitude
        await track.addFilter(
            AnyAudioFilter { pcm in
                for i in 0..<pcm.count {
                    pcm[i] *= 2.0
                }
            }
        )

        let output = await track.nextPCMFrame()
        #expect(output != nil)
        #expect(abs(output![0] - 1.0) < 1e-5)
    }

    @Test("AudioMixer applies master AudioFilter across summed tracks")
    func mixerMasterFilterPipeline() async {
        let mixer = AudioMixer()

        let trackA = AudioTrack(pcmProvider: MemoryPCMFrameProvider(frames: [[Float](repeating: 0.2, count: 1920)]))
        let trackB = AudioTrack(pcmProvider: MemoryPCMFrameProvider(frames: [[Float](repeating: 0.3, count: 1920)]))

        await mixer.add(trackA)
        await mixer.add(trackB)

        // Master filter: invert signal
        await mixer.addFilter(
            AnyAudioFilter { pcm in
                for i in 0..<pcm.count {
                    pcm[i] = -pcm[i]
                }
            }
        )

        let mixed = await mixer.nextPCMFrame()
        #expect(mixed != nil)
        // 0.2 + 0.3 = 0.5 -> inverted = -0.5
        #expect(abs(mixed![0] - (-0.5)) < 1e-5)
    }

    @Test("CustomOpusDecoder and AnyOpusDecoder decode packets into Float PCM")
    func customOpusDecoderTest() throws {
        let expectedCount = AudioConstants.frameSampleCount
        let decoder = AnyOpusDecoder { packet in
            // Custom decoder returns a distinct float signal
            [Float](repeating: 0.42, count: expectedCount)
        }

        let packet: [UInt8] = [0xF8, 0xFF, 0xFE]
        let decoded = try decoder.decode(packet: packet)
        #expect(decoded.count == expectedCount)
        #expect(decoded[0] == 0.42)
    }
}
