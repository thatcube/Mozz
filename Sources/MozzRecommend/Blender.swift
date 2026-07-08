import Foundation
import MozzDatabase

/// A small, seedable PRNG (SplitMix64) so the blender's exploration jitter is
/// deterministic in tests. `SystemRandomNumberGenerator` can't be seeded.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { self.state = seed }
    public mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Fuses scored candidates from one or more recommenders into a single ranked
/// set. The pipeline (validated in `RecommenderSpike`, per RECOMMENDATIONS.md):
/// per-source **min-max normalize** → **weighted fuse** → **dedupe** → **drop
/// already-heard** → **exploration jitter** → **variety caps** → **rank**.
///
/// Pure and deterministic given the RNG, so weights/jitter/caps are all unit
/// testable without a DB.
public struct Blender: Sendable {
    public struct Weights: Sendable {
        public var content: Double
        public var sonic: Double
        public var collaborative: Double
        public var coldstart: Double

        public init(content: Double = 0.5, sonic: Double = 0.3,
                    collaborative: Double = 0.2, coldstart: Double = 1.0) {
            self.content = content
            self.sonic = sonic
            self.collaborative = collaborative
            self.coldstart = coldstart
        }

        public func weight(for source: String) -> Double {
            switch source {
            case "content": return content
            case "sonic": return sonic
            case "collaborative": return collaborative
            case "coldstart": return coldstart
            default: return 0
            }
        }
    }

    public struct Config: Sendable {
        public var weights: Weights
        /// Max items in the final set (e.g. 30 for a weekly mix).
        public var limit: Int
        /// Uniform noise in [0, jitter) added to each normalized fused score for
        /// variety. 0 = fully deterministic ranking.
        public var explorationJitter: Double
        /// Diversity caps so one artist/album can't dominate the set.
        public var maxPerArtist: Int
        public var maxPerAlbum: Int

        public init(weights: Weights = Weights(), limit: Int = 30,
                    explorationJitter: Double = 0.15, maxPerArtist: Int = 3, maxPerAlbum: Int = 2) {
            self.weights = weights
            self.limit = limit
            self.explorationJitter = explorationJitter
            self.maxPerArtist = maxPerArtist
            self.maxPerAlbum = maxPerAlbum
        }
    }

    public init() {}

    public func blend(sources: [[ScoredCandidate]], config: Config,
                      excluding excludeRefs: Set<String> = [],
                      excludingArtists: Set<String> = [],
                      using rng: inout some RandomNumberGenerator) -> [ScoredCandidate] {
        // 1+2. Per-source min-max normalize, then weighted-fuse by track_ref.
        var fused: [String: FusedCandidate] = [:]
        for list in sources {
            let scores = list.map(\.score)
            let lo = scores.min() ?? 0
            let hi = scores.max() ?? 0
            for sc in list where !excludeRefs.contains(sc.trackRef)
                && !(sc.candidate.artistRemoteId.map(excludingArtists.contains) ?? false) {
                let norm = hi > lo ? (sc.score - lo) / (hi - lo) : 1.0
                let contribution = config.weights.weight(for: sc.source) * norm
                if var existing = fused[sc.trackRef] {
                    existing.score += contribution
                    if contribution > existing.best { existing.best = contribution; existing.reason = sc.reason }
                    fused[sc.trackRef] = existing
                } else {
                    fused[sc.trackRef] = FusedCandidate(candidate: sc.candidate, score: contribution,
                                                        reason: sc.reason, best: contribution)
                }
            }
        }

        // 3. Exploration jitter (seeded), then rank. Draw jitter in a STABLE
        // order (by track_ref) — not dictionary iteration order, which isn't
        // guaranteed stable — so a given seed always yields the same result.
        // Deterministic tie-break on track_ref keeps equal scores stable too.
        let ranked = fused.values
            .sorted { $0.candidate.trackRef < $1.candidate.trackRef }
            .map { f -> (FusedCandidate, Double) in
                let jitter = config.explorationJitter > 0
                    ? Double.random(in: 0..<config.explorationJitter, using: &rng) : 0
                return (f, f.score + jitter)
            }.sorted { a, b in
                a.1 != b.1 ? a.1 > b.1 : a.0.candidate.trackRef < b.0.candidate.trackRef
            }

        // 4. Variety caps + limit: greedily take the top items, skipping any that
        // would exceed the per-artist/per-album cap.
        var perArtist: [String: Int] = [:]
        var perAlbum: [String: Int] = [:]
        var out: [ScoredCandidate] = []
        for (f, finalScore) in ranked {
            if out.count >= config.limit { break }
            let artistKey = f.candidate.artistRemoteId ?? f.candidate.artistName
            let albumKey = f.candidate.albumRemoteId
            if perArtist[artistKey, default: 0] >= config.maxPerArtist { continue }
            if let albumKey, perAlbum[albumKey, default: 0] >= config.maxPerAlbum { continue }
            perArtist[artistKey, default: 0] += 1
            if let albumKey { perAlbum[albumKey, default: 0] += 1 }
            out.append(ScoredCandidate(candidate: f.candidate, score: finalScore,
                                       source: "blended", reason: f.reason))
        }
        return out
    }
}

/// Internal accumulator for one track's fused score across sources. Lifted to
/// file scope because `Blender.blend` is generic over the RNG (types can't nest
/// in a generic function). `best` tracks the largest single-source contribution
/// so the surfaced `reason` comes from the source that mattered most.
private struct FusedCandidate {
    var candidate: TrackCandidate
    var score: Double
    var reason: String?
    var best: Double
}
