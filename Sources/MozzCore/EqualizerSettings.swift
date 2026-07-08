import Foundation

/// A pure, serializable model of the app's graphic equalizer: one gain per band
/// plus a global preamp, in **decibels**. No AVFoundation here so it's trivially
/// unit-testable off-device (mirrors ``NormalizationGain``). The DSP that applies
/// these values lives in `MozzPlayback` (an `MTAudioProcessingTap` hosting
/// `kAudioUnitSubType_NBandEQ`).
///
/// A 10-band ISO graphic EQ (31 Hz–16 kHz, octave-spaced) is the mainstream
/// choice for a consumer music app — enough control for power users without the
/// intimidation of parametric bands. Gains are bounded to ±12 dB, the standard
/// range that stays musically useful while making runaway boosts (and clipping)
/// hard to reach by accident.
public struct EqualizerSettings: Codable, Equatable, Sendable {
    /// Number of graphic-EQ bands.
    public static let bandCount = 10

    /// ISO octave-spaced center frequencies (Hz), one per band, low → high.
    public static let centerFrequencies: [Double] =
        [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]

    /// The bound each band gain and the preamp are clamped to (± dB).
    public static let gainRange: ClosedRange<Double> = -12.0...12.0

    /// Per-band gains in dB (low → high), always ``bandCount`` long.
    public private(set) var gains: [Double]

    /// A global gain in dB applied on top of every band — handy to pull the whole
    /// signal down a few dB when boosting bands, avoiding clipping.
    public private(set) var preampDB: Double

    public init(gains: [Double] = Array(repeating: 0, count: EqualizerSettings.bandCount),
                preampDB: Double = 0) {
        // Normalize length (pad with 0 / truncate) then clamp every value so a
        // corrupt persisted blob or an out-of-range caller can never produce an
        // invalid EQ or an extreme boost.
        var normalized = Array(gains.prefix(Self.bandCount))
        if normalized.count < Self.bandCount {
            normalized.append(contentsOf: Array(repeating: 0, count: Self.bandCount - normalized.count))
        }
        self.gains = normalized.map { Self.clampGain($0) }
        self.preampDB = Self.clampGain(preampDB)
    }

    /// The neutral (no-op) curve: every band and the preamp at 0 dB.
    public static var flat: EqualizerSettings { EqualizerSettings() }

    /// True when nothing is changed — used to skip installing DSP entirely.
    public var isFlat: Bool { preampDB == 0 && gains.allSatisfy { $0 == 0 } }

    /// Set one band's gain (clamped), returning the band index unchanged for a
    /// no-op if `index` is out of range.
    public mutating func setGain(_ value: Double, forBand index: Int) {
        guard gains.indices.contains(index) else { return }
        gains[index] = Self.clampGain(value)
    }

    public mutating func setPreamp(_ value: Double) {
        preampDB = Self.clampGain(value)
    }

    public static func clampGain(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, gainRange.lowerBound), gainRange.upperBound)
    }

    /// A short human label for a band's center frequency, e.g. "31", "500",
    /// "1k", "16k".
    public static func frequencyLabel(forBand index: Int) -> String {
        guard centerFrequencies.indices.contains(index) else { return "" }
        return frequencyLabel(centerFrequencies[index])
    }

    public static func frequencyLabel(_ hz: Double) -> String {
        if hz >= 1_000 {
            let k = hz / 1_000
            // "1k", "16k" — drop a trailing .0 but keep e.g. "1.5k" if it ever occurs.
            return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        return "\(Int(hz))"
    }
}

/// A small curated set of named starting points for the graphic EQ. Selecting one
/// loads its ``settings``; editing any band afterward drops back to a "custom"
/// (no-preset) state in the UI.
public enum EqualizerPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case flat
    case bassBoost
    case trebleBoost
    case vocal
    case acoustic
    case electronic
    case rock

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .flat: return "Flat"
        case .bassBoost: return "Bass Boost"
        case .trebleBoost: return "Treble Boost"
        case .vocal: return "Vocal"
        case .acoustic: return "Acoustic"
        case .electronic: return "Electronic"
        case .rock: return "Rock"
        }
    }

    /// Per-band gains (dB) for the 10 ISO bands 31 Hz … 16 kHz.
    public var gains: [Double] {
        switch self {
        case .flat:        return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bassBoost:   return [6.0, 5.0, 4.0, 2.0, 0.5, 0, 0, 0, 0, 0]
        case .trebleBoost: return [0, 0, 0, 0, 0, 0.5, 2.0, 4.0, 5.0, 6.0]
        case .vocal:       return [-2.0, -1.5, -1.0, 1.0, 3.0, 4.0, 3.5, 2.0, 0.5, -0.5]
        case .acoustic:    return [3.0, 2.5, 1.5, 0.5, 1.5, 1.5, 2.0, 2.5, 2.0, 1.5]
        case .electronic:  return [4.0, 3.5, 1.5, 0, -1.5, 1.5, 0.5, 1.5, 3.5, 4.5]
        case .rock:        return [4.0, 3.0, 1.5, 0, -0.5, 0.5, 1.5, 3.0, 3.5, 3.5]
        }
    }

    public var settings: EqualizerSettings { EqualizerSettings(gains: gains) }

    /// The preset whose band gains exactly match `settings` (ignoring preamp), or
    /// `nil` when the user has a custom curve.
    public static func matching(_ settings: EqualizerSettings) -> EqualizerPreset? {
        allCases.first { $0.settings.gains == settings.gains }
    }
}
