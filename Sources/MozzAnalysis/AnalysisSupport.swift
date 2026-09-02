import Foundation

/// Mean and variance in one pass, without keeping the samples.
///
/// Welford's method rather than sum-of-squares: a 90-second window is ~5,600
/// frames, and the naive form loses precision exactly where the values are
/// large and close together, which is every MFCC coefficient.
struct RunningStat {
    private(set) var count = 0
    private(set) var mean = 0.0
    private var m2 = 0.0

    mutating func add(_ value: Double) {
        count += 1
        let delta = value - mean
        mean += delta / Double(count)
        m2 += delta * (value - mean)
    }

    var variance: Double { count > 1 ? m2 / Double(count - 1) : 0 }
    var standardDeviation: Double { variance.squareRoot() }
}

func clamp01(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return Swift.min(Swift.max(value, 0), 1)
}

/// Map a signed, unbounded feature into 0...1 with 0 at the midpoint.
///
/// `tanh` rather than a hard clamp so an outlier compresses instead of
/// saturating — two tracks that both blow past the scale should still be
/// ordered relative to each other.
func squashSigned(_ value: Double, scale: Double) -> Double {
    guard value.isFinite, scale > 0 else { return 0.5 }
    return 0.5 + 0.5 * tanh(value / scale)
}

/// One triangular mel filter, stored sparsely.
struct MelBand {
    let startBin: Int
    let weights: [Double]
}

extension SonicAnalyzer {
    /// Triangular mel-spaced filters, one row per band, over FFT magnitude bins.
    ///
    /// Mel spacing is the point: it gives low frequencies, where most musical
    /// information sits, far more resolution than the linear FFT grid does.
    /// Each band is returned as its first bin plus only the weights that are
    /// non-zero. A full-width row per band means walking all 513 bins forty
    /// times per frame to multiply by zero; a triangular filter touches maybe
    /// thirty of them.
    static func melFilterbank(configuration: Configuration) -> [MelBand] {
        let bins = configuration.frameSize / 2 + 1
        let bands = configuration.melBands
        let minMel = hzToMel(configuration.melMinHz)
        let maxMel = hzToMel(Swift.min(configuration.melMaxHz, configuration.nyquist))
        // `bands + 2` points: each filter spans one point either side of its peak.
        let points = (0..<(bands + 2)).map { index -> Double in
            let mel = minMel + (maxMel - minMel) * Double(index) / Double(bands + 1)
            return melToHz(mel)
        }
        let binHz = configuration.nyquist / Double(bins - 1)
        return (0..<bands).map { band in
            let lower = points[band], centre = points[band + 1], upper = points[band + 2]
            let first = Swift.max(0, Int((lower / binHz).rounded(.down)))
            let last = Swift.min(bins - 1, Int((upper / binHz).rounded(.up)))
            guard last >= first else { return MelBand(startBin: 0, weights: []) }
            var weights = [Double](repeating: 0, count: last - first + 1)
            for bin in first...last {
                let hz = Double(bin) * binHz
                if hz > lower && hz < centre {
                    weights[bin - first] = (hz - lower) / Swift.max(centre - lower, 1e-9)
                } else if hz >= centre && hz < upper {
                    weights[bin - first] = (upper - hz) / Swift.max(upper - centre, 1e-9)
                }
            }
            return MelBand(startBin: first, weights: weights)
        }
    }

    static func hzToMel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
    static func melToHz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }

    /// DCT-II, the standard cepstral transform: it decorrelates the log-mel
    /// bands so a handful of coefficients carry the spectral envelope.
    static func dct(_ input: [Double], count: Int) -> [Double] {
        let n = input.count
        guard n > 0 else { return [Double](repeating: 0, count: count) }
        return (0..<count).map { k in
            var acc = 0.0
            for i in 0..<n {
                acc += input[i] * cos(Double.pi * Double(k) * (Double(i) + 0.5) / Double(n))
            }
            return acc
        }
    }

    /// Which pitch class each FFT bin belongs to, or -1 for bins outside the
    /// range where pitch is meaningful.
    ///
    /// Precomputed once per size: the alternative is a `log2` per bin per frame,
    /// which is the same answer several thousand times over.
    static func chromaClasses(bins: Int, sampleRate: Int) -> [Int] {
        let binHz = Double(sampleRate) / 2 / Double(bins - 1)
        return (0..<bins).map { bin in
            let hz = Double(bin) * binHz
            // Below ~55 Hz the bins are too coarse to name a note; above ~5 kHz
            // the energy is overtones, not pitch.
            guard hz >= 55, hz <= 5_000 else { return -1 }
            let midi = 69 + 12 * log2(hz / 440)
            let pitchClass = Int(midi.rounded()) % 12
            return pitchClass < 0 ? pitchClass + 12 : pitchClass
        }
    }

    /// Tempo from the onset envelope, by autocorrelation.
    ///
    /// Deliberately simple: find the lag at which the envelope most resembles a
    /// shifted copy of itself, inside the range of plausible musical tempos, and
    /// call that the beat period. It does not try to resolve the octave
    /// ambiguity — 85 and 170 BPM are genuinely the same pulse — because for a
    /// similarity vector "how fast does this feel" is the useful part and a
    /// halved or doubled reading is a small error, not a wrong answer.
    ///
    /// Returns nil when nothing periodic stands out, which centres the feature
    /// rather than inventing a number.
    static func estimateTempo(onsets: [Double], frameRate: Double,
                              minBPM: Double = 40, maxBPM: Double = 220) -> Double? {
        guard onsets.count > 32, frameRate > 0 else { return nil }
        let mean = onsets.reduce(0, +) / Double(onsets.count)
        let centred = onsets.map { $0 - mean }
        let energy = centred.reduce(0) { $0 + $1 * $1 }
        guard energy > 1e-12 else { return nil }

        let minLag = Swift.max(2, Int((60 * frameRate / maxBPM).rounded(.down)))
        let maxLag = Swift.min(centred.count / 2, Int((60 * frameRate / minBPM).rounded(.up)))
        guard maxLag > minLag else { return nil }

        var bestLag = -1
        var bestScore = 0.0
        for lag in minLag...maxLag {
            var acc = 0.0
            for i in 0..<(centred.count - lag) { acc += centred[i] * centred[i + lag] }
            let score = acc / energy
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        // A weak peak is noise correlating with itself. Below this the envelope
        // has no pulse worth reporting.
        guard bestLag > 0, bestScore > 0.05 else { return nil }
        return 60 * frameRate / Double(bestLag)
    }
}
