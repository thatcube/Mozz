import Foundation

/// One track's acoustic fingerprint: a fixed-width vector compared by cosine
/// similarity, plus the handful of human-readable numbers that went into it.
///
/// The readable fields exist because "why is this in my station" is a question
/// worth being able to answer. They are not part of the vector's contract; only
/// ``values`` is.
public struct SonicFeatures: Sendable, Equatable {
    /// The vector, in the fixed order ``SonicFeatureLayout`` documents, already
    /// L2-normalized. Cosine similarity is the metric; because the vector is
    /// unit length, that is just a dot product.
    public let values: [Float]

    /// Which analyzer produced this, as `name@version`.
    ///
    /// Stored alongside every vector because vectors from different engines are
    /// **not comparable** — a nearest-neighbour search must filter to one engine
    /// or it is comparing coordinates in two unrelated spaces. Bumping the
    /// version is what re-analysis keys on.
    public let engine: String

    /// Estimated tempo in BPM, or nil when the signal gave no usable periodicity
    /// (silence, or something genuinely arrhythmic).
    public let tempoBPM: Double?
    /// Integrated loudness proxy: RMS in dBFS across the analyzed window.
    public let loudnessDBFS: Double
    /// Seconds of audio actually analyzed.
    public let analyzedSeconds: Double

    public var dimension: Int { values.count }

    public init(values: [Float], engine: String, tempoBPM: Double?,
                loudnessDBFS: Double, analyzedSeconds: Double) {
        self.values = values
        self.engine = engine
        self.tempoBPM = tempoBPM
        self.loudnessDBFS = loudnessDBFS
        self.analyzedSeconds = analyzedSeconds
    }

    /// Cosine similarity against another vector from the SAME engine, 0...1.
    ///
    /// Returns nil for a mismatched engine or dimension rather than a number,
    /// because a plausible-looking score across two feature spaces is worse than
    /// no score: it would quietly rank a station on noise.
    public func similarity(to other: SonicFeatures) -> Double? {
        guard engine == other.engine, values.count == other.values.count else { return nil }
        var dot = 0.0
        for i in 0..<values.count { dot += Double(values[i]) * Double(other.values[i]) }
        // Both are unit vectors and every component is non-negative by
        // construction, so the dot product is already the cosine and already in
        // 0...1; the clamp is only against accumulated rounding.
        return min(max(dot, 0), 1)
    }
}

/// The vector's layout, fixed and documented because it is persisted.
///
/// Order matters and must never be rearranged without bumping the engine
/// version: a stored vector is just numbers, and its meaning is entirely this
/// table.
public enum SonicFeatureLayout {
    /// Timbre. The single most useful family for "sounds like": broadly, what
    /// the instrumentation and production sound like, independent of key.
    public static let mfccCount = 13
    /// Pitch-class energy — harmonic content, roughly "what key and how tonal".
    public static let chromaCount = 12

    /// mean+variance of each MFCC, then chroma means, then the scalar families.
    public static let dimension =
        mfccCount * 2      // MFCC mean + variance
        + chromaCount      // chroma mean
        + 2                // spectral centroid mean, variance
        + 2                // spectral rolloff mean, variance
        + 2                // spectral flatness mean, variance
        + 2                // spectral flux mean, variance
        + 2                // zero-crossing rate mean, variance
        + 2                // RMS mean, variance
        + 1                // crest factor
        + 2                // tempo, onset strength
}
