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

    /// A freshness map for recency-biased shuffle: track `remoteId` → score in
    /// `[0, 1]`, where 1 means "just played" and it decays toward 0 with age
    /// (0.5 at `halfLife`). Tracks never played are simply absent (treated as
    /// fully fresh by the caller). Reads the play log off the main thread.
    public func recencyScores(serverId: ServerID,
                              halfLife: TimeInterval = 7 * 24 * 3600) async throws -> [String: Double] {
        let lastPlayed = try await store.lastPlayedByRemoteID(serverId: serverId)
        guard halfLife > 0 else { return [:] }
        let nowSec = now().timeIntervalSince1970
        let lambda = log(2) / halfLife
        return lastPlayed.mapValues { playedAt in
            let age = max(0, nowSec - playedAt)
            return exp(-lambda * age)
        }
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

    // MARK: - Home mixes (multiple precomputed sets)

    public static let kindSupermix = "supermix"
    public static let kindDaily = "daily_mix"
    public static let kindArtist = "artist_mix"
    public static let kindReplay = "replay"
    /// Weekly rediscovery ("Mozz Weekly") uses this existing kind.
    public static let kindForgotten = "forgotten"

    /// The daily-cadence batch cleared and rebuilt by ``generateHomeMixes``.
    /// (Mozz Weekly is generated separately on its weekly cadence.)
    static let homeBatchKinds = [kindSupermix, kindDaily, kindArtist, kindReplay]
    /// Don't persist a mix with fewer than this many tracks — avoids junk tiles.
    static let minTracks = 8

    /// A Home mix tile summary: the set plus a representative cover and subtitle.
    public struct HomeMix: Sendable, Identifiable {
        public let id: String
        public let title: String
        public let subtitle: String?
        public let kind: String
        public let artworkKey: String?
        public let generatedAt: Double
    }

    /// (Re)generate the daily-cadence Home mixes for a server: Supermix, up to
    /// three Daily Mixes (one per top genre), up to two Artist Mixes (a top
    /// artist + same-genre neighbours), and a Replay mix (most-played). The prior
    /// batch is cleared first so removed slots don't linger. Cold-start (thin
    /// history) generates none — "Mozz Weekly" already covers day one.
    public func generateHomeMixes(serverId: ServerID, seed: UInt64? = nil) async throws {
        let nowDate = now()
        let nowSec = nowDate.timeIntervalSince1970
        let lookback = nowSec - 90 * 24 * 3600
        // notPlayedSince in the future ⇒ exclude nothing ⇒ include familiar
        // (recently-played) tracks, which is what a Daily Mix / Supermix wants.
        let includeFamiliar = nowSec + 24 * 3600

        let signals = try await store.playedTrackSignals(serverId: serverId, since: lookback)
        let taste = TasteProfile.build(from: signals, now: nowDate)
        var rng = SeededGenerator(seed: seed ?? UInt64(bitPattern: Int64(nowSec)))

        try await store.deleteSets(kinds: Self.homeBatchKinds)
        guard !taste.isThin else { return }

        // Supermix — broad, familiar-leaning blend across all of the listener's taste.
        let superPool = try await store.candidateTracks(
            serverId: serverId, genres: taste.topGenres(20), artistIds: taste.topArtists(30),
            notPlayedSince: includeFamiliar, limit: 3000)
        if let ranked = ranked(superPool, taste: taste,
                               config: .init(limit: 60, explorationJitter: 0.12, maxPerArtist: 5, maxPerAlbum: 3),
                               rng: &rng) {
            try await save(id: "supermix", title: "Supermix", kind: Self.kindSupermix, items: ranked)
        }

        // Daily Mixes — one coherent mix per top genre.
        for (i, genre) in taste.topGenres(3).enumerated() {
            let pool = try await store.candidateTracks(
                serverId: serverId, genres: [genre], artistIds: [],
                notPlayedSince: includeFamiliar, limit: 1000)
            if let ranked = ranked(pool, taste: taste,
                                   config: .init(limit: 40, explorationJitter: 0.12, maxPerArtist: 4, maxPerAlbum: 2),
                                   rng: &rng) {
                try await save(id: "daily-mix-\(i + 1)", title: "Daily Mix \(i + 1)", kind: Self.kindDaily, items: ranked)
            }
        }

        // Artist Mixes — a top artist plus same-genre neighbours.
        for (i, artistId) in taste.topArtists(2).enumerated() {
            guard let seedArtist = try await store.seedArtist(remoteId: artistId, serverId: serverId) else { continue }
            let pool = try await store.candidateTracks(
                serverId: serverId, genres: Array(seedArtist.genres.prefix(4)), artistIds: [artistId],
                notPlayedSince: includeFamiliar, limit: 1000)
            if let ranked = ranked(pool, taste: taste,
                                   config: .init(limit: 40, explorationJitter: 0.1, maxPerArtist: 6, maxPerAlbum: 3),
                                   rng: &rng) {
                let title = seedArtist.name.isEmpty ? "Artist Mix" : "\(seedArtist.name) Mix"
                try await save(id: "artist-mix-\(i + 1)", title: title, kind: Self.kindArtist, items: ranked)
            }
        }

        // Replay — most-played recently, in play-count order (no re-ranking).
        let replayPool = try await store.mostPlayedCandidates(serverId: serverId, since: nowSec - 60 * 24 * 3600, limit: 50)
        if replayPool.count >= Self.minTracks {
            let items = replayPool.enumerated().map { idx, c in
                ScoredCandidate(candidate: c, score: Double(replayPool.count - idx), source: "content", reason: "On repeat")
            }
            try await save(id: "replay-mix", title: "Replay", kind: Self.kindReplay, items: items)
        }
    }

    /// Every Home mix (the daily batch + Mozz Weekly), each with a representative
    /// cover and subtitle, ordered for display. Instant + offline (reads only).
    public func homeMixes() async throws -> [HomeMix] {
        let sets = try await store.allSets()
        let art = try await store.representativeArtworkKeys()
        return sets.map { s in
            HomeMix(id: s.id, title: s.title, subtitle: Self.decodeMeta(s.params)?.subtitle,
                    kind: s.kind, artworkKey: art[s.id], generatedAt: s.generatedAt)
        }
        .sorted { a, b in
            let pa = Self.order(a.kind), pb = Self.order(b.kind)
            return pa != pb ? pa < pb : a.id < b.id
        }
    }

    /// Tracks of any set (for the generic mix detail page), in rank order.
    public func tracks(forSetId id: String) async throws -> [TrackRecord] {
        try await store.tracks(forSet: id)
    }

    public func set(id: String) async throws -> RecommendationSetRecord? {
        try await store.set(id: id)
    }

    // MARK: - Home mix helpers

    /// Content-score a pool and blend it; nil if the result is too thin to ship.
    private func ranked(_ pool: [TrackCandidate], taste: TasteProfile,
                        config: Blender.Config, rng: inout SeededGenerator) -> [ScoredCandidate]? {
        guard pool.count >= Self.minTracks else { return nil }
        let scored = content.score(candidates: pool, taste: taste)
        let blended = blender.blend(sources: [scored], config: config, using: &rng)
        return blended.count >= Self.minTracks ? blended : nil
    }

    /// Persist a mix set + its ranked items, stashing a subtitle (top artists) in
    /// `params` for the tile.
    private func save(id: String, title: String, kind: String, items: [ScoredCandidate]) async throws {
        let set = RecommendationSetRecord(id: id, title: title, kind: kind,
                                          generatedAt: now().timeIntervalSince1970,
                                          params: Self.encodeMeta(subtitle: Self.subtitle(from: items.map(\.candidate))))
        let records = items.enumerated().map { idx, sc in
            RecommendationItemRecord(setId: id, trackRef: sc.trackRef, rank: idx + 1,
                                     score: sc.score, inLibrary: true, reason: sc.reason)
        }
        try await store.saveRecommendationSet(set, items: records)
    }

    private static func order(_ kind: String) -> Int {
        switch kind {
        case kindSupermix: return 0
        case kindDaily: return 1
        case kindArtist: return 2
        case kindReplay: return 3
        case kindForgotten: return 4
        default: return 9
        }
    }

    /// "AURORA, ODESZA and more" from a set's tracks (distinct artists, in order).
    private static func subtitle(from candidates: [TrackCandidate]) -> String? {
        var seen = Set<String>()
        var names: [String] = []
        for c in candidates where !c.artistName.isEmpty {
            if seen.insert(c.artistName).inserted { names.append(c.artistName) }
            if names.count == 3 { break }
        }
        guard !names.isEmpty else { return nil }
        return names.count >= 3 ? "\(names[0]), \(names[1]) and more" : names.joined(separator: ", ")
    }

    private struct MixMeta: Codable { var subtitle: String? }

    private static func encodeMeta(subtitle: String?) -> String? {
        guard subtitle != nil, let data = try? JSONEncoder().encode(MixMeta(subtitle: subtitle)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeMeta(_ params: String?) -> MixMeta? {
        guard let params, let data = params.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MixMeta.self, from: data)
    }
}
