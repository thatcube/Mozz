import Foundation

/// Turns audio into the log-mel patches ``VGGishTrunk`` expects.
///
/// Every constant here is VGGish's rather than ours, and they are not
/// interchangeable with the DSP engine's: a network trained on one
/// spectrogram convention reads a different one as a different instrument. The
/// values below come from Google's `mel_features.py` — 25 ms frames advanced by
/// 10 ms, a 512-point transform, 64 HTK-mel bands between 125 Hz and 7.5 kHz,
/// and `log(mel + 0.01)`. `Tests/MozzAnalysisTests` checks the output against a
/// patch the reference implementation produced.
///
/// The one deliberate difference from the reference is where the patches come
/// from: it takes every consecutive 0.96 seconds, and we sample a fixed number
/// spread across the window instead (see ``patches(_:limit:)``), because a
/// ninety-second window is ninety-four patches and the convolutions cost real
/// time on a phone.
public struct VGGishFrontEnd: Sendable {
    public static let sampleRate = 16_000
    /// 25 ms at 16 kHz.
    static let windowSamples = 400
    /// 10 ms.
    static let hopSamples = 160
    /// The next power of two at or above the window — the reference zero-pads
    /// 400 samples into a 512-point transform.
    static let fftSize = 512
    static let melBands = 64
    static let lowerHz = 125.0
    static let upperHz = 7_500.0
    /// Keeps the logarithm finite through silence.
    static let logOffset = 0.01
    /// 0.96 seconds, the window the network was trained on.
    public static let patchFrames = 96

    private let fft: FFT
    private let window: [Double]
    /// `[mel band][spectrogram bin]`, triangular in the mel domain.
    private let melMatrix: [[Double]]
    private let bins: Int

    public init() {
        self.bins = Self.fftSize / 2 + 1
        self.fft = FFT(size: Self.fftSize)
        // Periodic, not symmetric: one whole cycle of a period-N cosine, which
        // is what a Fourier basis of length N actually represents.
        self.window = (0..<Self.windowSamples).map {
            0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(Self.windowSamples))
        }
        self.melMatrix = Self.melWeights(bins: bins, sampleRate: Self.sampleRate)
    }

    /// The HTK mel scale VGGish uses. Note this is NOT the Slaney scale the
    /// DSP engine's own filterbank uses — same idea, different curve.
    static func hertzToMel(_ hertz: Double) -> Double {
        1127.0 * log(1.0 + hertz / 700.0)
    }

    static func melWeights(bins: Int, sampleRate: Int) -> [[Double]] {
        let nyquist = Double(sampleRate) / 2
        let binHertz = (0..<bins).map { Double($0) * nyquist / Double(bins - 1) }
        let binMel = binHertz.map(hertzToMel)
        let lowerMel = hertzToMel(lowerHz), upperMel = hertzToMel(upperHz)
        // One edge per band plus the two that bracket the first and last.
        let edges = (0..<(melBands + 2)).map {
            lowerMel + (upperMel - lowerMel) * Double($0) / Double(melBands + 1)
        }

        var matrix = [[Double]](repeating: [Double](repeating: 0, count: bins), count: melBands)
        for band in 0..<melBands {
            let lower = edges[band], center = edges[band + 1], upper = edges[band + 2]
            for bin in 0..<bins {
                let rising = (binMel[bin] - lower) / (center - lower)
                let falling = (upper - binMel[bin]) / (upper - center)
                matrix[band][bin] = Swift.max(0, Swift.min(rising, falling))
            }
            // HTK excludes the DC bin; leaving it in would let a track's offset
            // leak into its lowest band.
            matrix[band][0] = 0
        }
        return matrix
    }

    /// Every consecutive 96-frame patch, as the reference produces them.
    public func allPatches(_ samples: [Float]) -> [[Float]] {
        let spectrogram = logMelSpectrogram(samples)
        guard spectrogram.count >= Self.patchFrames else { return [] }
        var patches: [[Float]] = []
        var start = 0
        while start + Self.patchFrames <= spectrogram.count {
            patches.append(spectrogram[start..<(start + Self.patchFrames)].flatMap { $0 })
            start += Self.patchFrames
        }
        return patches
    }

    /// At most `limit` patches, spread evenly across the audio.
    ///
    /// Ninety seconds is ninety-four patches and about nineteen seconds of
    /// convolution on a laptop, which is a library nobody finishes. Sampling
    /// across the whole window rather than taking the first N also fixes a
    /// weakness of the DSP engine that no amount of tuning addressed: one
    /// contiguous window describes one part of a song, and songs change.
    public func patches(_ samples: [Float], limit: Int) -> [[Float]] {
        let spectrogram = logMelSpectrogram(samples)
        guard spectrogram.count >= Self.patchFrames, limit > 0 else { return [] }
        let last = spectrogram.count - Self.patchFrames
        let count = Swift.min(limit, last / Self.patchFrames + 1)
        guard count > 1 else {
            return [spectrogram[0..<Self.patchFrames].flatMap { $0 }]
        }
        return (0..<count).map { index in
            let start = Int((Double(last) * Double(index) / Double(count - 1)).rounded())
            return spectrogram[start..<(start + Self.patchFrames)].flatMap { $0 }
        }
    }

    /// `log(mel + 0.01)`, one row per 10 ms frame.
    func logMelSpectrogram(_ samples: [Float]) -> [[Float]] {
        guard samples.count >= Self.windowSamples else { return [] }
        let frames = 1 + (samples.count - Self.windowSamples) / Self.hopSamples
        var rows: [[Float]] = []
        rows.reserveCapacity(frames)

        var padded = [Double](repeating: 0, count: Self.fftSize)
        for frame in 0..<frames {
            let start = frame * Self.hopSamples
            for i in 0..<Self.windowSamples {
                padded[i] = Double(samples[start + i]) * window[i]
            }
            // Beyond the 400 real samples the transform sees zeros; they only
            // need clearing once, but clarity is cheap next to an FFT.
            for i in Self.windowSamples..<Self.fftSize { padded[i] = 0 }

            let magnitudes = fft.magnitudes(of: padded)
            var row = [Float](repeating: 0, count: Self.melBands)
            for band in 0..<Self.melBands {
                let weights = melMatrix[band]
                var sum = 0.0
                for bin in 0..<bins { sum += weights[bin] * magnitudes[bin] }
                row[band] = Float(log(sum + Self.logOffset))
            }
            rows.append(row)
        }
        return rows
    }
}
