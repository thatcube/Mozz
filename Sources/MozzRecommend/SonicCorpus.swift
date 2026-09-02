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
