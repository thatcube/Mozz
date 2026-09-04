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
    ///
    /// ## Cross-platform divergence (resolved in favour of the cap)
    ///
    /// The C# desktop equivalent (`clients/desktop/Audio/Dsp/ReplayGain.cs`,
    /// `LinearFor`) computes the same `10^(dB/20)` but returns it **uncapped**.
    /// The core keeps the cap because it is the safer, defensible behaviour: a
    /// single malformed loudness tag (e.g. `+60 dB`) would otherwise produce a
    /// 1000× amplitude scalar and clip catastrophically. +12 dB (4.0×) is the
    /// same ceiling the EQ preamp uses and is already pinned by a test here.
    /// When the desktop shell migrates to reading normalization from the core,
    /// it should adopt this cap; the DSP file is intentionally left unchanged in
    /// this task (no UI/desktop behaviour change), so the divergence persists in
    /// the desktop code until then.
    public static func linearScalar(gainDB: Double, preampDB: Double = 0, maxScalar: Float = 4.0) -> Float {
        let scalar = Float(pow(10.0, (gainDB + preampDB) / 20.0))
        guard scalar.isFinite else { return 1.0 }
        return min(max(scalar, 0), maxScalar)
    }
}
