import Foundation

/// Content-based genre similarity using **TF-IDF weighted vectors + cosine
/// similarity** — the standard offline technique for "sounds like" matching when
/// no audio embeddings are available (they aren't yet in Mozz).
///
/// The key property: a genre's weight is its **inverse document frequency**
/// across the library, so ubiquitous tags ("Rock", "Pop") count for almost
/// nothing while distinctive ones ("dream pop", "math rock") dominate. Two tracks
/// that share only a broad tag score near zero; two that share rare tags score
/// high. This is what stops a hard-rock track leaking into a dream-pop station
/// just because both happen to carry a generic "Rock" tag.
///
/// Vectors are L2-normalized, so cosine similarity is a plain dot product over
/// shared genres and lands in `[0, 1]` (all weights are non-negative).
public struct GenreSimilarity: Sendable, Equatable {
    /// genre → IDF weight.
    private let idf: [String: Double]
    /// Weight for a genre absent from the corpus (treated as maximally rare).
    private let defaultIDF: Double

    /// Build the space from a corpus: `totalTracks` and per-genre document counts
    /// (how many tracks carry each genre). Uses smoothed IDF
    /// `log((1 + N) / (1 + df)) + 1`, which is always positive and rank-stable.
    public init(totalTracks: Int, counts: [String: Int]) {
        let total = Double(max(0, totalTracks))
        var idf: [String: Double] = [:]
        idf.reserveCapacity(counts.count)
        for (genre, df) in counts {
            idf[genre] = log((1 + total) / (1 + Double(max(0, df)))) + 1
        }
        self.idf = idf
        self.defaultIDF = log(1 + total) + 1
    }

    /// The IDF weight for a genre (rare → high). An unknown genre is treated as
    /// maximally rare.
    public func weight(for genre: String) -> Double { idf[genre] ?? defaultIDF }

    /// An L2-normalized TF-IDF vector for a set of genres (presence-based term
    /// frequency — a genre is either on the track or not). Empty in → empty out.
    public func vector(for genres: [String]) -> [String: Double] {
        guard !genres.isEmpty else { return [:] }
        var v: [String: Double] = [:]
        for genre in Set(genres) { v[genre] = weight(for: genre) }
        return Self.l2Normalized(v)
    }

    /// An L2-normalized query vector from a genre→affinity map (e.g. a taste
    /// profile): each genre weighted by `affinity × idf`, positives only.
    public func vector(fromAffinities affinities: [String: Double]) -> [String: Double] {
        var v: [String: Double] = [:]
        for (genre, affinity) in affinities where affinity > 0 {
            v[genre] = affinity * weight(for: genre)
        }
        return Self.l2Normalized(v)
    }

    /// Cosine similarity of two vectors from this space (both L2-normalized, so
    /// this is their dot product over shared genres). Returns `0` if either is
    /// empty. Result is in `[0, 1]`.
    public func cosine(_ a: [String: Double], _ b: [String: Double]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let (small, large) = a.count <= b.count ? (a, b) : (b, a)
        var dot = 0.0
        for (key, value) in small where large[key] != nil {
            dot += value * large[key]!
        }
        return dot
    }

    private static func l2Normalized(_ v: [String: Double]) -> [String: Double] {
        let norm = (v.values.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard norm > 0 else { return [:] }
        return v.mapValues { $0 / norm }
    }
}
