import Foundation
import MozzDatabase

/// A listener's derived taste, computed from the append-only play log — the
/// input the content recommender scores against. Purely a function of
/// `PlayedTrackSignal`s (no DB, no network), so it's trivially unit-testable and
/// runs off the main thread.
///
/// Affinity for a genre/artist = Σ over that listener's events of
/// `weight(kind) × recencyDecay(age)`:
/// - `weight` encodes the positive/negative signal — a *completed* play is a
///   strong positive, a *skip* a negative (the distinction `PlaybackState` can't
///   capture, per ADR-0005); a *like* is the strongest positive.
/// - `recencyDecay` is an exponential half-life so this week's taste dominates
///   last year's (spike used ~30-day decay).
public struct TasteProfile: Sendable, Equatable {
    /// genre → accumulated affinity (can be negative if mostly skipped).
    public let genreAffinity: [String: Double]
    /// artist remote id → accumulated affinity.
    public let artistAffinity: [String: Double]
    /// Sum of positive genre affinity — the basis for the cold-start decision.
    public let positiveSignal: Double

    /// Below this much positive signal we treat history as too thin to
    /// personalize and fall back to a cold-start pool (recently-added).
    public static let coldStartThreshold = 2.0

    public var isThin: Bool { positiveSignal < Self.coldStartThreshold }

    public static let empty = TasteProfile(genreAffinity: [:], artistAffinity: [:], positiveSignal: 0)

    public init(genreAffinity: [String: Double], artistAffinity: [String: Double], positiveSignal: Double) {
        self.genreAffinity = genreAffinity
        self.artistAffinity = artistAffinity
        self.positiveSignal = positiveSignal
    }

    /// The positive-affinity signal weight for an event kind.
    public static func weight(for kind: String) -> Double {
        switch kind {
        case "liked": return 1.5
        case "completed": return 1.0
        case "started": return 0.2   // a partial listen is a mild positive
        case "skipped": return -0.6  // moved on before the end — a negative
        case "unliked": return -1.0
        default: return 0            // seek and anything else: neutral
        }
    }

    /// Build a profile from listening signals. `halfLife` is the recency
    /// half-life (default 30 days); `now` is injectable for deterministic tests.
    public static func build(from signals: [PlayedTrackSignal],
                             now: Date = Date(),
                             halfLife: TimeInterval = 30 * 24 * 3600) -> TasteProfile {
        var genre: [String: Double] = [:]
        var artist: [String: Double] = [:]
        let nowSec = now.timeIntervalSince1970
        for s in signals {
            let w = weight(for: s.kind)
            if w == 0 { continue }
            let ageSec = max(0, nowSec - s.createdAt)
            let decay = pow(0.5, ageSec / halfLife)
            let contribution = w * decay
            for g in s.genres { genre[g, default: 0] += contribution }
            if let a = s.artistRemoteId, !a.isEmpty { artist[a, default: 0] += contribution }
        }
        let positive = genre.values.reduce(0) { $0 + max(0, $1) }
        return TasteProfile(genreAffinity: genre, artistAffinity: artist, positiveSignal: positive)
    }

    /// The `n` genres with the highest positive affinity.
    public func topGenres(_ n: Int) -> [String] {
        genreAffinity.filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(n).map(\.key)
    }

    /// The `n` artists (remote ids) with the highest positive affinity.
    public func topArtists(_ n: Int) -> [String] {
        artistAffinity.filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(n).map(\.key)
    }
}
