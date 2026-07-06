import Foundation

/// ReplayGain / "Sound Check"-style loudness-normalization math.
///
/// Servers expose a per-track normalization gain in **decibels** (negative to
/// attenuate a loud master, positive to bring up a quiet one). Audio mixing
/// wants a **linear amplitude scalar** (1.0 = unchanged), so this converts and
/// bounds it. Kept pure (no AVFoundation) so it's trivially unit-tested.
public enum NormalizationGain {
    /// Convert a gain in dB (plus an optional preamp, also dB) into a linear
    /// amplitude scalar for an audio mix. Clamped to `[0, maxScalar]` so a
    /// bogus or extreme tag can never blow out the output (default cap +12 dB).
    public static func linearScalar(gainDB: Double, preampDB: Double = 0, maxScalar: Float = 4.0) -> Float {
        let scalar = Float(pow(10.0, (gainDB + preampDB) / 20.0))
        guard scalar.isFinite else { return 1.0 }
        return min(max(scalar, 0), maxScalar)
    }
}
