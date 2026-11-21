# Chapter 04: Audio Filters & Auto-Ducking

This chapter covers real-time digital signal processing (DSP), custom audio filters, soft limiting, and voice activity detection using `AudioFilter` and `VoiceActivityDetector`.

---

## 1. The AudioFilter Protocol

`DiscordBMVoice` processes audio as 20ms frames of 32-bit floating point PCM (`[Float]`) sampled at 48kHz stereo (960 samples per channel, 1,920 interleaved samples per frame).

Any type conforming to `AudioFilter` can transform PCM frames in-place:

```swift
public protocol AudioFilter: Sendable {
    func process(_ pcm: inout [Float])
}
```

### Implementing a Custom DSP Filter

```swift
public struct BassBoostFilter: AudioFilter, Sendable {
    public let gain: Float

    public init(gain: Float = 1.6) {
        self.gain = gain
    }

    public func process(_ pcm: inout [Float]) {
        for i in 0..<pcm.count {
            pcm[i] = pcm[i] * gain
        }
    }
}
```

### Inline Closure Filters (`AnyAudioFilter`)

For quick inline DSP without defining a new struct, use `AnyAudioFilter`:

```swift
let invertChannels = AnyAudioFilter { pcm in
    // Interleaved stereo: [L0, R0, L1, R1, ...]
    for i in stride(from: 0, to: pcm.count, by: 2) {
        let left = pcm[i]
        pcm[i] = pcm[i + 1]
        pcm[i + 1] = left
    }
}
```

---

## 2. Attaching Filters

Filters can be attached at two distinct levels:

### A. Per-Track Filter
Applies DSP only to a specific track before mixing:

```swift
let track = try AudioTrack.file("music.mp3")
let handle = await connection.play(track)

await handle.addFilter(BassBoostFilter(gain: 1.4))
```

### B. Master Output Filter
Applies DSP across the summed output of all playing tracks:

```swift
// Soft limiter prevents digital clipping when multiple tracks sum > 1.0:
await connection.addFilter(SoftLimiterFilter(threshold: 0.95))
```

---

## 3. Voice Activity Detection (`VoiceActivityDetector`)

Detect speech energy levels without running heavy machine-learning models. The detector computes root-mean-square (RMS) decibels relative to full scale (dBFS):

```swift
let vad = VoiceActivityDetector(
    thresholdDB: -35.0,  // Audio above -35 dBFS is classified as speech
    hangoverFrames: 10   // Stays active for 200ms after speech ends to prevent flickering
)

for await pcmFrame in await connection.pcmStream() {
    let isSpeaking = vad.process(pcmFrame.1)
    if isSpeaking {
        print("User \(pcmFrame.0) is speaking")
    }
}
```

---

## 4. Complete Runnable Implementation

See [main.swift](main.swift) for the complete implementation.
