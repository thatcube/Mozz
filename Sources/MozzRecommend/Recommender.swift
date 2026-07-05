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
public struct ContentRecommender: Recommender {
    public let source = "content"
    /// Relative emphasis of genre vs artist affinity.
    private let genreWeight: Double
    private let artistWeight: Double

    public init(genreWeight: Double = 0.6, artistWeight: Double = 0.4) {
        self.genreWeight = genreWeight
        self.artistWeight = artistWeight
    }

    public func score(candidates: [TrackCandidate], taste: TasteProfile) -> [ScoredCandidate] {
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
