import Audio
import Foundation

/// Processes 20ms Float PCM audio frames (1,920 interleaved 48kHz stereo samples) in-place.
public protocol AudioFilter: Sendable {
    /// Mutates the given 20ms Float PCM audio frame in-place.
    ///
    /// - Parameter pcm: An array of 1,920 interleaved 32-bit float samples (-1.0 to 1.0).
    func process(pcm: inout [Float])
}

/// Closure-based audio filter for custom digital signal processing.
public struct AnyAudioFilter: AudioFilter, Sendable {
    private let _process: @Sendable (inout [Float]) -> Void

    public init(_ process: @escaping @Sendable (inout [Float]) -> Void) {
        self._process = process
    }

    public func process(pcm: inout [Float]) {
        _process(&pcm)
    }
}

/// Linear volume attenuation or gain filter.
public struct VolumeFilter: AudioFilter, Sendable {
    public var volume: Float

    public init(volume: Float = 1.0) {
        self.volume = max(0.0, volume)
    }

    public func process(pcm: inout [Float]) {
        guard volume != 1.0 else { return }
        for i in 0..<pcm.count {
            pcm[i] *= volume
        }
    }
}

/// Soft-knee peak limiter preventing digital clipping distortion above a specified threshold.
public struct SoftLimiterFilter: AudioFilter, Sendable {
    public var threshold: Float

    public init(threshold: Float = 0.95) {
        self.threshold = min(0.999, max(0.1, threshold))
    }

    public func process(pcm: inout [Float]) {
        let thresh = self.threshold
        let headroom = 1.0 - thresh
        guard headroom > 0 else { return }

        for i in 0..<pcm.count {
            let sample = pcm[i]
            let absSample = abs(sample)
            if absSample > thresh {
                let over = absSample - thresh
                let compressed = thresh + (headroom * (over / (headroom + over)))
                pcm[i] = sample < 0 ? -compressed : compressed
            }
        }
    }
}

/// Auto-ducking filter providing smooth volume attenuation and recovery.
///
/// Attenuates background music when ducking is triggered, smoothing changes across
/// frames to prevent audible clicks or pops.
public final class AutoDucker: AudioFilter, @unchecked Sendable {

    private let lock = NSLock()
    private var _duckVolume: Float
    private var _attackFrames: Int
    private var _releaseFrames: Int

    private var targetVolume: Float = 1.0
    private var currentVolume: Float = 1.0
    private var isDuckedState = false

    /// - Parameters:
    ///   - duckVolume: Volume multiplier when ducked (default 0.25 = ~-12dB).
    ///   - attackFrames: Frames to fade down (default 5 frames = 100ms).
    ///   - releaseFrames: Frames to fade up (default 15 frames = 300ms).
    public init(
        duckVolume: Float = 0.25,
        attackFrames: Int = 5,
        releaseFrames: Int = 15
    ) {
        self._duckVolume = max(0.0, min(1.0, duckVolume))
        self._attackFrames = max(1, attackFrames)
        self._releaseFrames = max(1, releaseFrames)
    }

    public var duckVolume: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _duckVolume
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _duckVolume = max(0.0, min(1.0, newValue))
        }
    }

    public var attackFrames: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _attackFrames
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _attackFrames = max(1, newValue)
        }
    }

    public var releaseFrames: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _releaseFrames
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _releaseFrames = max(1, newValue)
        }
    }

    /// Triggers ducking to lower volume.
    public func duck() {
        lock.lock()
        defer { lock.unlock() }
        self.isDuckedState = true
        self.targetVolume = _duckVolume
    }

    /// Releases ducking to restore normal volume.
    public func unduck() {
        lock.lock()
        defer { lock.unlock() }
        self.isDuckedState = false
        self.targetVolume = 1.0
    }

    /// Sets ducked state directly.
    public func setDucked(_ ducked: Bool) {
        if ducked {
            duck()
        } else {
            unduck()
        }
    }

    /// Whether ducking is currently active.
    public var isDucked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isDuckedState
    }

    /// Current volume multiplier applied by the ducker.
    public var volume: Float {
        lock.lock()
        defer { lock.unlock() }
        return currentVolume
    }

    public func process(pcm: inout [Float]) {
        lock.lock()
        let target = self.targetVolume
        let startVol = self.currentVolume
        let attack = self._attackFrames
        let release = self._releaseFrames
        let duckVol = self._duckVolume

        // Fast path if fully steady-state at target
        if startVol == target {
            if target == 1.0 {
                lock.unlock()
                return
            }
            lock.unlock()
            for i in 0..<pcm.count {
                pcm[i] *= target
            }
            return
        }

        let delta = target - startVol
        let span = max(0.01, 1.0 - duckVol)
        let maxStep = span / Float(target < startVol ? attack : release)

        let endVol: Float
        if abs(delta) <= maxStep {
            endVol = target
        } else {
            endVol = startVol + (delta > 0 ? maxStep : -maxStep)
        }

        self.currentVolume = endVol
        lock.unlock()

        let sampleCount = pcm.count
        guard sampleCount > 0 else { return }

        // Interpolate smoothly per sample across the 20ms frame
        let sampleStep = (endVol - startVol) / Float(sampleCount)
        var vol = startVol
        for i in 0..<sampleCount {
            pcm[i] *= vol
            vol += sampleStep
        }
    }
}

/// Voice Activity Detector (VAD) measuring root-mean-square (RMS) energy on 20ms audio frames.
public final class VoiceActivityDetector: @unchecked Sendable {

    private let lock = NSLock()
    private var _thresholdDB: Float
    private var _hangoverFrames: Int
    private var silenceFrames = 0
    private var _isSpeaking = false

    /// - Parameters:
    ///   - thresholdDB: Decibel threshold below which frames are considered silence (default -45.0 dB).
    ///   - hangoverFrames: Frames of silence to wait before ending speech (default 10 frames = 200ms).
    public init(thresholdDB: Float = -45.0, hangoverFrames: Int = 10) {
        self._thresholdDB = thresholdDB
        self._hangoverFrames = max(1, hangoverFrames)
    }

    public var thresholdDB: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _thresholdDB
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _thresholdDB = newValue
        }
    }

    public var isSpeaking: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isSpeaking
    }

    /// Computes RMS energy of a 20ms Float PCM frame in decibels relative to full scale (dBFS).
    public static func energyDB(pcm: [Float]) -> Float {
        guard !pcm.isEmpty else { return -100.0 }
        var sumSquares: Float = 0.0
        for sample in pcm {
            sumSquares += sample * sample
        }
        let meanSquare = sumSquares / Float(pcm.count)
        guard meanSquare > 1e-12 else { return -120.0 }
        return 10.0 * log10(meanSquare)
    }

    /// Evaluates a 20ms Float PCM frame and updates speech activity state.
    ///
    /// - Returns: True if speech is actively detected.
    @discardableResult
    public func process(pcm: [Float]) -> Bool {
        let db = Self.energyDB(pcm: pcm)
        lock.lock()
        defer { lock.unlock() }

        if db >= _thresholdDB {
            silenceFrames = 0
            _isSpeaking = true
            return true
        } else {
            silenceFrames += 1
            if silenceFrames >= _hangoverFrames {
                _isSpeaking = false
                return false
            } else {
                return _isSpeaking
            }
        }
    }

    /// Resets the detector state to silence.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        silenceFrames = 0
        _isSpeaking = false
    }
}
