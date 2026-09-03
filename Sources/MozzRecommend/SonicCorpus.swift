import Foundation

/// A server's analyzed vectors, put on a footing where distances mean
/// something.
///
/// The analyzer emits a vector whose components are on the scales the DSP
/// produced and weighted by how much each was judged to matter. That is the
/// right thing to *store* — it is engine-defined and comparable across devices
/// — but it is the wrong thing to take a cosine of, because a handful of
/// components that nearly every recording shares (overall loudness, the low
/// MFCCs, broad spectral shape) dominate the dot product. Everything ends up
/// pointing the same way.
///
/// Measured on a real library, 135 tracks in: random pairs scored 0.887 with a
/// standard deviation of 0.054, and pairs by the SAME ARTIST scored 0.911 —
/// less than half a standard deviation apart. Kate Bush's nearest neighbour was
/// Harry Chapin. The ranking was not wrong so much as flat.
///
/// So a corpus standardizes each dimension against the library it belongs to:
/// subtract that dimension's mean across every analyzed track, divide by its
/// standard deviation, re-normalize. A dimension where every track in someone's
/// library agrees stops carrying the comparison; the ones that actually vary
/// start to. On the same 135 tracks that moved same-artist separation from
/// +0.45 to +1.14 standard deviations, and put AURORA next to AURORA and JAY-Z
/// next to Kanye and 50 Cent.
///
/// It is deliberately a *query-time* transform over stored vectors, not a
/// change to what the analyzer writes: it needs no re-analysis, and the
/// statistics belong to one library at one moment rather than to the engine.
struct SonicCorpus {
    /// Vectors already standardized and unit-normalized, ready to dot.
    let entries: [(remoteId: String, vector: [Float])]

    private let mean: [Float]
    private let inverseSD: [Float]
    /// Whether the statistics were worth computing.
    private let standardized: Bool

    /// Below this a library's own statistics are noise — the mean and spread of
    /// a dimension across a dozen tracks says more about those dozen tracks than
    /// about the music. Under it, vectors are compared as stored.
    static let minimumForStatistics = 24

    init(_ raw: [(remoteId: String, vector: [Float])]) {
        guard let width = raw.first?.vector.count, width > 0,
              raw.count >= Self.minimumForStatistics,
              raw.allSatisfy({ $0.vector.count == width })
        else {
            self.mean = []
            self.inverseSD = []
            self.standardized = false
            self.entries = raw.map { ($0.remoteId, Self.unit($0.vector)) }
            self.reference = Self.sample(entries.map(\.vector), count: Self.referenceSample)
            return
        }

        var mean = [Float](repeating: 0, count: width)
        for entry in raw {
            for i in 0..<width { mean[i] += entry.vector[i] }
        }
        let count = Float(raw.count)
        for i in 0..<width { mean[i] /= count }

        var variance = [Float](repeating: 0, count: width)
        for entry in raw {
            for i in 0..<width {
                let d = entry.vector[i] - mean[i]
                variance[i] += d * d
            }
        }
        // A dimension that never varies would divide by zero and turn rounding
        // noise into a loud signal; the floor keeps it quiet instead.
        let floor: Float = 1e-6
        let inverseSD = (0..<width).map { i -> Float in
            let sd = (variance[i] / count).squareRoot()
            return sd > floor ? 1 / sd : 0
        }

        self.mean = mean
        self.inverseSD = inverseSD
        self.standardized = true
        self.entries = raw.map { ($0.remoteId, Self.standardize($0.vector, mean: mean, inverseSD: inverseSD)) }
        self.reference = Self.sample(entries.map(\.vector), count: Self.referenceSample)
    }

    /// Every `stride`-th vector, so the sample spans the library rather than
    /// its first few hundred tracks.
    static func sample(_ vectors: [[Float]], count: Int) -> [[Float]] {
        guard vectors.count > count else { return vectors }
        let stride = Swift.max(vectors.count / count, 1)
        return Swift.stride(from: 0, to: vectors.count, by: stride).prefix(count).map { vectors[$0] }
    }

    /// A fixed subset of the corpus, used to characterise how far any one track
    /// sits from the library in general.
    ///
    /// Sampled rather than exhaustive: the statistics only need to describe a
    /// distribution, and 256 draws pin a mean and a standard deviation far more
    /// cheaply than ten thousand do. Taken at a fixed stride rather than at
    /// random so the same library always produces the same numbers.
    private(set) var reference: [[Float]] = []
    static let referenceSample = 256

    /// How far this vector sits from the library at large.
    ///
    /// Returns nil when the corpus is too small for the spread to mean
    /// anything.
    func distanceProfile(_ vector: [Float]) -> (mean: Double, deviation: Double)? {
        guard reference.count >= 16, vector.count == reference[0].count else { return nil }
        var sum = 0.0, sumSquares = 0.0
        for other in reference {
            var dot = 0.0
            for i in 0..<vector.count { dot += Double(vector[i]) * Double(other[i]) }
            let distance = 1 - dot
            sum += distance
            sumSquares += distance * distance
        }
        let count = Double(reference.count)
        let mean = sum / count
        let variance = Swift.max(sumSquares / count - mean * mean, 0)
        return (mean, variance.squareRoot())
    }

    /// Mutual Proximity (Schnitzer, Flexer, Schedl & Widmer, 2011): the
    /// probability that these two tracks are each other's neighbour, judged
    /// from BOTH sides.
    ///
    /// This exists because a one-sided similarity cannot express the failure
    /// this feature actually has. A library holding one opera track answers it
    /// with a soprano-led pop song, and that match scores higher than 71% of
    /// every other best-match in the library — because the score is relative to
    /// the library's own distribution, and a library with one opera track has
    /// no yardstick for opera. From the pop song's side the same distance is an
    /// extreme outlier, and multiplying the two tail probabilities is what lets
    /// the pairing say so.
    ///
    /// The literature calls the general problem hubness, and tracks that are
    /// nobody's neighbour anti-hubs; a real recommender catalogue measured
    /// 33-35% of them (Gasser, Flexer & Schnitzer, 2010).
    func mutualProximity(distance: Double,
                         seed: (mean: Double, deviation: Double),
                         candidate: (mean: Double, deviation: Double)) -> Double {
        Self.tailProbability(distance, seed) * Self.tailProbability(distance, candidate)
    }

    /// How far below a track's usual distance this one sits, in standard
    /// deviations. Negative is closer than average; -3 is very close indeed.
    static func separation(_ distance: Double,
                           _ profile: (mean: Double, deviation: Double)) -> Double {
        guard profile.deviation > 1e-9 else { return distance < profile.mean ? -.infinity : 0 }
        return (distance - profile.mean) / profile.deviation
    }

    /// P(X > distance) for a normal fitted to one track's distances.
    static func tailProbability(_ distance: Double,
                                _ profile: (mean: Double, deviation: Double)) -> Double {
        guard profile.deviation > 1e-9 else { return distance < profile.mean ? 1 : 0 }
        let z = (distance - profile.mean) / profile.deviation
        // 1 - Φ(z), written with erfc so the far tail keeps its precision.
        return 0.5 * erfc(z / 2.0.squareRoot())
    }

    /// Put a vector from outside the corpus — the seed — into the same space.
    func normalize(_ vector: [Float]) -> [Float] {
        guard standardized, vector.count == mean.count else { return Self.unit(vector) }
        return Self.standardize(vector, mean: mean, inverseSD: inverseSD)
    }

    private static func standardize(_ vector: [Float], mean: [Float], inverseSD: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: vector.count)
        for i in 0..<vector.count { out[i] = (vector[i] - mean[i]) * inverseSD[i] }
        return unit(out)
    }

    /// Unit length, so every dot product is a cosine.
    private static func unit(_ vector: [Float]) -> [Float] {
        var sum: Float = 0
        for value in vector { sum += value * value }
        let magnitude = sum.squareRoot()
        guard magnitude > 1e-9 else { return vector }
        return vector.map { $0 / magnitude }
    }
}
