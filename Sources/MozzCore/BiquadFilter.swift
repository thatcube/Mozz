import Foundation

/// Second-order IIR (biquad) filter coefficients, already normalized by `a0`.
/// Stored as `Float` for the real-time audio path. Pure math, so it's
/// unit-testable off-device (mirrors ``NormalizationGain`` / ``EqualizerSettings``).
public struct BiquadCoefficients: Equatable, Sendable {
    public var b0: Float
    public var b1: Float
    public var b2: Float
    public var a1: Float
    public var a2: Float

    public init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    /// A pass-through filter (output == input).
    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// A peaking (bell) EQ filter — the building block of a graphic equalizer —
    /// from the Audio EQ Cookbook (RBJ). `gainDB` boosts (+) or cuts (−) a band
    /// centered at `frequency` with sharpness `q`. A 0 dB gain returns identity.
    public static func peakingEQ(frequency: Double,
                                 gainDB: Double,
                                 q: Double,
                                 sampleRate: Double) -> BiquadCoefficients {
        guard gainDB.isFinite, abs(gainDB) > 0.001,
              sampleRate > 0, frequency > 0, q > 0 else { return .identity }
        // Keep the center below Nyquist so cos/sin stay well-defined.
        let f0 = min(frequency, sampleRate * 0.45)
        let a = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Double.pi * f0 / sampleRate
        let cosw0 = cos(w0)
        let alpha = sin(w0) / (2.0 * q)

        let a0 = 1.0 + alpha / a
        let b0 = (1.0 + alpha * a) / a0
        let b1 = (-2.0 * cosw0) / a0
        let b2 = (1.0 - alpha * a) / a0
        let a1 = (-2.0 * cosw0) / a0
        let a2 = (1.0 - alpha / a) / a0

        return BiquadCoefficients(b0: Float(b0), b1: Float(b1), b2: Float(b2),
                                  a1: Float(a1), a2: Float(a2))
    }
}

/// A single biquad filter: coefficients plus two state variables (Transposed
/// Direct Form II). `process` is allocation-free and real-time safe; the audio
/// thread cascades ten of these per channel to realize the graphic EQ.
public struct Biquad {
    public var coefficients: BiquadCoefficients
    private var z1: Float = 0
    private var z2: Float = 0

    public init(coefficients: BiquadCoefficients = .identity) {
        self.coefficients = coefficients
    }

    /// Clear the filter memory — call on a seek so a discontinuity doesn't click.
    public mutating func reset() {
        z1 = 0
        z2 = 0
    }

    /// Process one sample. Transposed Direct Form II:
    /// `y = b0·x + z1; z1 = b1·x − a1·y + z2; z2 = b2·x − a2·y`.
    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        let c = coefficients
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }
}

public extension EqualizerSettings {
    /// Filter sharpness for the octave-spaced bands (≈1-octave bandwidth).
    static let bandQ = 1.414

    /// The preamp as a linear amplitude scalar.
    var preampScalar: Double { pow(10.0, preampDB / 20.0) }

    /// One peaking-filter coefficient set per band, for the given sample rate.
    func biquadCoefficients(sampleRate: Double) -> [BiquadCoefficients] {
        (0..<Self.bandCount).map { i in
            BiquadCoefficients.peakingEQ(frequency: Self.centerFrequencies[i],
                                         gainDB: gains[i],
                                         q: Self.bandQ,
                                         sampleRate: sampleRate)
        }
    }
}
