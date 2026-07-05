import Foundation
import MozzCore
import MozzDatabase

/// Computes and persists ranked recommendation sets in the background so the UI
/// is instant and offline (it only ever *reads* precomputed rows — never scores
/// on the main thread / on view load).
///
/// Phase 1 ships "Mozz Weekly" — in-library rediscovery, fully offline: build a
/// taste profile from the play log, pull not-recently-played library tracks that
/// match that taste, score them by content affinity, blend (normalize → jitter →
/// variety caps → rank) and persist. Sonic (on-device embedding) and
/// collaborative (ListenBrainz) are additional `Recommender`s that slot into the
/// same blend later (ADR-0004) — no change to this flow.
public actor RecommendationService {
    private let store: RecommendationStore
    private let content: ContentRecommender
    private let coldStart: ColdStartRecommender
    private let blender: Blender
    private let now: @Sendable () -> Date

    /// Stable id of the weekly rediscovery set.
    public static let mozzWeeklyId = "mozz-weekly"

    public init(store: RecommendationStore,
                content: ContentRecommender = ContentRecommender(),
                coldStart: ColdStartRecommender = ColdStartRecommender(),
                blender: Blender = Blender(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.content = content
        self.coldStart = coldStart
        self.blender = blender
        self.now = now
    }

    /// (Re)generate "Mozz Weekly" for a server and persist it. Pass a `seed` for
    /// a deterministic ranking (tests); omit it for fresh weekly variety.
    @discardableResult
    public func generateMozzWeekly(serverId: ServerID, limit: Int = 30,
                                   seed: UInt64? = nil) async throws -> RecommendationSetRecord {
        let nowDate = now()
        let lookback = nowDate.addingTimeInterval(-90 * 24 * 3600).timeIntervalSince1970
        let notPlayedSince = nowDate.addingTimeInterval(-30 * 24 * 3600).timeIntervalSince1970

        let signals = try await store.playedTrackSignals(serverId: serverId, since: lookback)
        let taste = TasteProfile.build(from: signals, now: nowDate)

        let scored: [[ScoredCandidate]]
        let title: String
        if taste.isThin {
            // Cold start: nothing to personalize against yet — surface what's new
            // in the library so the shelf still earns its place on day one.
            let pool = try await store.recentlyAddedCandidates(
                serverId: serverId, notPlayedSince: notPlayedSince, limit: 200)
            scored = [coldStart.score(candidates: pool, taste: taste)]
            title = "New to Your Library"
        } else {
            let pool = try await store.candidateTracks(
                serverId: serverId, genres: taste.topGenres(12), artistIds: taste.topArtists(20),
                notPlayedSince: notPlayedSince, limit: 2000)
            scored = [content.score(candidates: pool, taste: taste)]
            title = "Mozz Weekly"
        }

        // Deterministic when seeded; otherwise varies by generation time.
        var rng = SeededGenerator(seed: seed ?? UInt64(bitPattern: Int64(nowDate.timeIntervalSince1970)))
        let blended = blender.blend(sources: scored, config: Blender.Config(limit: limit), using: &rng)

        let set = RecommendationSetRecord(id: Self.mozzWeeklyId, title: title, kind: "forgotten",
                                          generatedAt: nowDate.timeIntervalSince1970)
        let items = blended.enumerated().map { index, sc in
            RecommendationItemRecord(setId: set.id, trackRef: sc.trackRef, rank: index + 1,
                                     score: sc.score, inLibrary: true, reason: sc.reason)
        }
        try await store.saveRecommendationSet(set, items: items)
        return set
    }

    // MARK: - Read-back for the UI (precomputed → instant + offline)

    public func mozzWeeklySet() async throws -> RecommendationSetRecord? {
        try await store.set(id: Self.mozzWeeklyId)
    }

    public func mozzWeeklyTracks() async throws -> [TrackRecord] {
        try await store.tracks(forSet: Self.mozzWeeklyId)
    }

    public func mozzWeeklyItems() async throws -> [RecommendationItemRecord] {
        try await store.items(forSet: Self.mozzWeeklyId)
    }
}
