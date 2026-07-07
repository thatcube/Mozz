import Foundation
import MozzDatabase

/// A single scored recommendation candidate produced by a ``Recommender``,
/// before blending/ranking.
public struct ScoredCandidate: Sendable, Equatable {
    public var candidate: TrackCandidate
    /// Raw, un-normalized score in this recommender's own units. The blender
    /// min-max normalizes per source before fusing, so absolute scale is fine.
    public var score: Double
    /// Which signal produced it: "content" | "sonic" | "collaborative" | "coldstart".
    public var source: String
    /// Human-readable justification ("Because you're into Jazz", "More from …").
    public var reason: String?

    public var trackRef: String { candidate.trackRef }

    public init(candidate: TrackCandidate, score: Double, source: String, reason: String? = nil) {
        self.candidate = candidate
        self.score = score
        self.source = source
        self.reason = reason
    }
}

/// A source of scored candidates. The design fuses several — **content**
/// (tag/genre affinity, offline), **sonic** (on-device embedding k-NN, future),
/// and **collaborative** (ListenBrainz, opt-in, future) — behind this one port
/// so new signals are additive (ADR-0004). Pure and synchronous: given
/// candidates + taste it returns scores; all I/O happens in the service.
public protocol Recommender: Sendable {
    var source: String { get }
    func score(candidates: [TrackCandidate], taste: TasteProfile) -> [ScoredCandidate]
}

/// Scores library tracks by how well their genres/artist match the listener's
/// taste. Fully offline, no model — the always-available Phase-1 signal.
///
/// When a ``GenreSimilarity`` space is supplied, genre matching uses **TF-IDF
/// cosine similarity** (ubiquitous tags like "Rock" contribute almost nothing;
/// rare, distinctive tags dominate), which stops loose single-broad-tag matches
/// from scoring like genuine matches. Without a space it falls back to the
/// original raw-affinity-sum scoring, so behavior is unchanged where no genre
/// corpus is available (keeps existing callers/tests intact).
public struct ContentRecommender: Recommender {
    public let source = "content"
    /// Relative emphasis of genre vs artist affinity.
    private let genreWeight: Double
    private let artistWeight: Double
    private let genreSpace: GenreSimilarity?

    public init(genreWeight: Double = 0.6, artistWeight: Double = 0.4,
                genreSpace: GenreSimilarity? = nil) {
        self.genreWeight = genreWeight
        self.artistWeight = artistWeight
        self.genreSpace = genreSpace
    }

    public func score(candidates: [TrackCandidate], taste: TasteProfile) -> [ScoredCandidate] {
        guard let genreSpace else { return scoreByAffinitySum(candidates, taste: taste) }
        return scoreByCosine(candidates, taste: taste, space: genreSpace)
    }

    /// TF-IDF cosine genre similarity + artist affinity. The query genre vector
    /// is built from the taste's positive genre affinities (× IDF); each
    /// candidate is its own IDF-weighted genre vector. `cosine` is in `[0, 1]`.
    private func scoreByCosine(_ candidates: [TrackCandidate], taste: TasteProfile,
                               space: GenreSimilarity) -> [ScoredCandidate] {
        let query = space.vector(fromAffinities: taste.genreAffinity)
        return candidates.compactMap { c in
            let genreSim = space.cosine(query, space.vector(for: c.genres))
            let artistAffinity = c.artistRemoteId.map { max(0, taste.artistAffinity[$0] ?? 0) } ?? 0
            let score = genreWeight * genreSim + artistWeight * artistAffinity
            guard score > 0 else { return nil }
            let reason: String?
            if artistAffinity > 0, artistWeight * artistAffinity >= genreWeight * genreSim {
                reason = "More from \(c.artistName)"
            } else if genreSim > 0, let g = bestGenre(c, taste: taste) {
                reason = "Because you're into \(g)"
            } else {
                reason = nil
            }
            return ScoredCandidate(candidate: c, score: score, source: source, reason: reason)
        }
    }

    /// The candidate genre with the highest taste affinity (for the "because" reason).
    private func bestGenre(_ c: TrackCandidate, taste: TasteProfile) -> String? {
        c.genres
            .map { ($0, max(0, taste.genreAffinity[$0] ?? 0)) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
    }

    /// Original scoring: raw sum of matched genre affinities + artist affinity.
    /// Retained as the fallback when no genre corpus (IDF space) is available.
    private func scoreByAffinitySum(_ candidates: [TrackCandidate], taste: TasteProfile) -> [ScoredCandidate] {
        candidates.compactMap { c in
            // Best matching genre (for scoring + the "because" reason).
            var bestGenre: (name: String, affinity: Double)?
            var genreSum = 0.0
            for g in c.genres {
                let a = max(0, taste.genreAffinity[g] ?? 0)
                genreSum += a
                if a > 0, a > (bestGenre?.affinity ?? 0) { bestGenre = (g, a) }
            }
            let artistAffinity = c.artistRemoteId.map { max(0, taste.artistAffinity[$0] ?? 0) } ?? 0
            let score = genreWeight * genreSum + artistWeight * artistAffinity
            guard score > 0 else { return nil }   // nothing in common → not a content pick

            let reason: String?
            if artistAffinity * artistWeight >= (bestGenre?.affinity ?? 0) * genreWeight, artistAffinity > 0 {
                reason = "More from \(c.artistName)"
            } else if let g = bestGenre {
                reason = "Because you're into \(g.name)"
            } else {
                reason = nil
            }
            return ScoredCandidate(candidate: c, score: score, source: source, reason: reason)
        }
    }
}

/// Cold-start fallback for a thin/empty history: rank by how recently the track
/// was added to the library. Keeps the shelf useful on day one until real
/// affinity accumulates (ADR-0005). Scored so newer = higher; the blender
/// normalizes and adds exploration jitter for variety.
public struct ColdStartRecommender: Recommender {
    public let source = "coldstart"
    public init() {}

    public func score(candidates: [TrackCandidate], taste: TasteProfile) -> [ScoredCandidate] {
        candidates.map { c in
            ScoredCandidate(candidate: c, score: c.addedAt ?? 0, source: source,
                            reason: "New to your library")
        }
    }
}
