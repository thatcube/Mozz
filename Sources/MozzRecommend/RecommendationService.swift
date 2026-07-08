import Foundation
import MozzCore
import MozzDatabase

/// A seed for an Instant-Mix "station": the genres and artist(s) to build a
/// station around (e.g. from a track or an artist the user tapped "Start Radio"
/// on) plus a display title.
public struct RadioSeed: Sendable, Equatable {
    public var title: String
    public var genres: [String]
    public var artistIds: [String]
    /// Durable `track_ref` of the seed track, when seeded from a track (nil for an
    /// artist-seeded station). Lets the caller resolve the seed's ListenBrainz
    /// similarity for the precedence tier.
    public var seedTrackRef: String?

    public init(title: String, genres: [String], artistIds: [String], seedTrackRef: String? = nil) {
        self.title = title
        self.genres = genres
        self.artistIds = artistIds
        self.seedTrackRef = seedTrackRef
    }
}

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
    /// Whether open-metadata enrichment is on (B4.5). When true the genre engine
    /// reads the CANONICAL, normalized union of `track.genres` + `mb_tags` on every
    /// side (corpus/candidates/seed/taste); when false it reads today's raw,
    /// case-sensitive `track.genres` — byte-identical to pre-B4.5 behavior. Honors
    /// the same Settings switch the enrichment pipeline uses (off = fully offline).
    private let isEnrichmentEnabled: @Sendable () -> Bool

    /// Cached per-server TF-IDF genre space (a full-catalog aggregate), refreshed
    /// on a TTL so repeated radio/shuffle scoring doesn't re-scan every call. Keyed
    /// also by the enrichment flag so toggling it never serves a stale corpus.
    private var genreSpaceCache: [ServerID: (space: GenreSimilarity, computedAt: Date, enrich: Bool)] = [:]
    private static let genreSpaceTTL: TimeInterval = 3600

    /// Stable id of the weekly rediscovery set.
    public static let mozzWeeklyId = "mozz-weekly"

    /// Minimum IDF-weighted Jaccard genre similarity for a (non-same-artist)
    /// track to join a radio station. Below this, a candidate shares only
    /// broad/ubiquitous tags with the seed and is a genre outlier. Robust for
    /// single-genre candidates (unlike a raw cosine magnitude). Same-artist tracks
    /// bypass this floor. Tunable; conservative enough to keep the station full.
    private static let minRadioSimilarity = 0.15

    public init(store: RecommendationStore,
                content: ContentRecommender = ContentRecommender(),
                coldStart: ColdStartRecommender = ColdStartRecommender(),
                blender: Blender = Blender(),
                now: @escaping @Sendable () -> Date = { Date() },
                isEnrichmentEnabled: @escaping @Sendable () -> Bool = { true }) {
        self.store = store
        self.content = content
        self.coldStart = coldStart
        self.blender = blender
        self.now = now
        self.isEnrichmentEnabled = isEnrichmentEnabled
    }

    /// The TF-IDF genre space for a server (cached with a TTL), or `nil` when no
    /// genre corpus is available. Feeds cosine similarity for radio / Smart
    /// Shuffle / Weekly.
    private func genreSpace(for serverId: ServerID) async -> GenreSimilarity? {
        let enrich = isEnrichmentEnabled()
        if let cached = genreSpaceCache[serverId], cached.enrich == enrich,
           now().timeIntervalSince(cached.computedAt) < Self.genreSpaceTTL {
            return cached.space
        }
        guard let freq = try? await store.genreFrequencies(serverId: serverId, enrich: enrich),
              freq.total > 0 else {
            return nil
        }
        let space = GenreSimilarity(totalTracks: freq.total, counts: freq.counts)
        genreSpaceCache[serverId] = (space, now(), enrich)
        return space
    }

    /// A cosine-similarity `ContentRecommender` for a server (preserving the
    /// service's configured weights), or the default affinity-sum scorer when no
    /// genre corpus is available.
    private func contentScorer(for serverId: ServerID) async -> ContentRecommender {
        guard let space = await genreSpace(for: serverId) else { return content }
        return content.withGenreSpace(space)
    }

    /// The canonical genres of an artist (across its tracks), for seeding an
    /// artist radio station. When enrichment is on these are the normalized union
    /// of `track.genres` and the artist's `mb_tags` — the SAME normalization the
    /// candidate pool uses, so an artist-seeded station is symmetric with its
    /// candidates (an un-enriched seed vs enriched candidates would recreate the
    /// asymmetric floor drop). Empty when the artist has no local tracks.
    public func artistSeedGenres(artistId: String, serverId: ServerID) async -> [String] {
        let enrich = isEnrichmentEnabled()
        guard let seed = try? await store.seedArtist(remoteId: artistId, serverId: serverId, enrich: enrich)
        else { return [] }
        return seed.genres
    }

    /// A "Smart Shuffle" affinity map for a specific set of tracks: track id →
    /// normalized score in `(0, 1]` (1 == best match to the listener's taste).
    /// Tracks with no affinity are absent. Returns `[:]` when history is too thin
    /// to personalize (cold start), so the caller falls back to a plain shuffle.
    /// Uses TF-IDF cosine genre similarity + artist affinity (see ``ContentRecommender``).
    public func tasteScores(serverId: ServerID, tracks: [Track]) async throws -> [String: Double] {
        let nowDate = now()
        let enrich = isEnrichmentEnabled()
        let lookback = nowDate.addingTimeInterval(-90 * 24 * 3600).timeIntervalSince1970
        let signals = try await store.playedTrackSignals(serverId: serverId, since: lookback, enrich: enrich)
        let taste = TasteProfile.build(from: signals, now: nowDate)
        guard !taste.isThin else { return [:] }

        // Score the caller's own tracks against the taste profile via the shared
        // content scorer (cosine genre similarity + artist affinity), mapping
        // domain Tracks into the TrackCandidate shape the scorer consumes. When
        // enriched, merge each track's mb_tags (keyed by the COMPOSED track_ref,
        // not the bare id) so Smart Shuffle candidates are symmetric with the
        // (identically normalized) taste side.
        let scorer = await contentScorer(for: serverId)
        var mbByRef: [String: [String]] = [:]
        if enrich {
            let refs = tracks.map { PlayEventStore.trackRef(serverId: serverId, remoteId: $0.id) }
            mbByRef = (try? await store.mbTags(forTrackRefs: refs)) ?? [:]
        }
        let candidates = tracks.map { track -> TrackCandidate in
            let ref = PlayEventStore.trackRef(serverId: serverId, remoteId: track.id)
            let genres = enrich ? GenreNormalizer.merge(track.genres, mbByRef[ref] ?? []) : track.genres
            return TrackCandidate(trackRef: ref, remoteId: track.id, title: track.title,
                                  artistName: track.artistName, artistRemoteId: track.artistID,
                                  albumRemoteId: track.albumID, genres: genres, addedAt: nil)
        }
        let scored = scorer.score(candidates: candidates, taste: taste)
        let maxScore = scored.map(\.score).max() ?? 0
        guard maxScore > 0 else { return [:] }
        var out: [String: Double] = [:]
        out.reserveCapacity(scored.count)
        for s in scored { out[s.candidate.remoteId] = s.score / maxScore }
        return out
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

    /// Generate the next batch of station tracks. When ListenBrainz similarity for
    /// the seed is available (`similar`, resolved by the caller from
    /// `EnrichmentStore.similarOwnedTracks`), those tracks LEAD the batch — the
    /// crowd-similarity signal that separates tracks a coarse genre tag lumps
    /// together — with the genre engine filling any remaining slots. With no
    /// similarity the result is exactly the genre engine's (never worse than
    /// today). `excluding` drops the seed and anything already queued.
    public func radioBatch(seed: RadioSeed, serverId: ServerID,
                           limit: Int = 20, excluding: Set<String> = [],
                           similar: [ScoredOwnedTrack] = []) async throws -> [String] {
        // Tier 1 — ListenBrainz similarity (explicit precedence). Trusted OVER the
        // genre floor on purpose (that's the point: separate within a genre bucket);
        // guarded only by dropping non-positive scores + ranking by score.
        let suppressedArtists = (try? await store.suppressedArtistIds(serverId: serverId)) ?? []
        let suppressedTrackIds = (try? await store.suppressedTrackRemoteIds(serverId: serverId)) ?? []
        var picked: [String] = []
        var pickedSet = excluding.union(suppressedTrackIds)
        let usableSimilar = similar.filter {
            $0.score > 0 && !pickedSet.contains($0.candidate.remoteId)
                && !($0.candidate.artistRemoteId.map(suppressedArtists.contains) ?? false)
        }
        if !usableSimilar.isEmpty {
            let scored = usableSimilar.map {
                ScoredCandidate(candidate: $0.candidate, score: $0.score, source: "collaborative")
            }
            // Rank tier 1 by the ListenBrainz score (near-zero jitter so the crowd
            // signal — not exploration noise — orders the lead; batch-to-batch
            // variety comes from the growing `excluding` set). Tighter per-artist
            // cap: ListenBrainz "similar" skews same-artist, and the seed's own
            // artist isn't discovery.
            let config = Blender.Config(limit: limit, explorationJitter: 0.02,
                                        maxPerArtist: 4, maxPerAlbum: max(2, limit / 4))
            var rng = SeededGenerator(seed: UInt64(truncatingIfNeeded: now().timeIntervalSince1970.bitPattern))
            let ranked = blender.blend(sources: [scored], config: config,
                                       excludingArtists: suppressedArtists, using: &rng)
            picked = ranked.map { $0.candidate.remoteId }
            pickedSet.formUnion(picked)
            if picked.count >= limit { return picked }
        }
        // Tier 3 — genre engine fills the remaining slots (unchanged behavior).
        let genre = try await genreRadioBatch(
            seed: seed, serverId: serverId, limit: limit - picked.count,
            excluding: pickedSet, excludingArtists: suppressedArtists)
        return picked + genre
    }

    /// The genre-similarity station batch (the pre-B3 `radioBatch` body, verbatim):
    /// pulls a same-genre / same-artist pool, applies the IDF-weighted-Jaccard floor,
    /// scores by similarity to the seed, and blends with variety caps + jitter.
    private func genreRadioBatch(seed: RadioSeed, serverId: ServerID,
                                 limit: Int, excluding: Set<String>,
                                 excludingArtists: Set<String> = []) async throws -> [String] {
        guard limit > 0, !seed.genres.isEmpty || !seed.artistIds.isEmpty else { return [] }
        let enrich = isEnrichmentEnabled()
        // Effective seed genres: when enriched, normalize the caller's genres and
        // union the SEED TRACK's mb_tags (so the seed is enriched symmetrically with
        // the candidates — an un-enriched seed vs enriched candidates would recreate
        // the asymmetric floor drop). Falls back to the (normalized) caller genres if
        // the seed row/tags are absent, so a missing row never empties the station.
        var seedGenres = seed.genres
        if enrich {
            var merged = seed.genres
            if let ref = seed.seedTrackRef {
                merged += (try? await store.mbTags(forTrackRef: ref)) ?? []
            }
            seedGenres = GenreNormalizer.keys(merged)
        }
        // Include the whole matching catalog (notPlayedSince = now excludes ~none);
        // radio may revisit tracks. Pull a generous pool to blend from, excluding
        // already-surfaced tracks in SQL so the random sample is drawn from unseen
        // tracks (avoids stalling near the tail of a large catalog).
        //
        // The SQL exclusion is bounded (SQLite param limit), so in a marathon
        // session the random sample can still come back all-seen; resample a few
        // times (each draws a fresh RANDOM() slice) before concluding the pool is
        // genuinely exhausted, so the station doesn't stop early.
        var fresh: [TrackCandidate] = []
        for _ in 0..<3 {
            let pool = try await store.candidateTracks(
                serverId: serverId, genres: seedGenres, artistIds: seed.artistIds,
                notPlayedSince: now().timeIntervalSince1970, excludingRemoteIds: excluding,
                excludingArtistIds: excludingArtists, limit: 500, enrich: enrich)
            fresh = pool.filter { !excluding.contains($0.remoteId) }
            if !fresh.isEmpty { break }
        }
        guard !fresh.isEmpty else { return [] }

        // Drop genre outliers up front: keep the seed's own artist(s) always, but
        // require a genre-tagged candidate to clear a minimum IDF-weighted Jaccard
        // similarity to the seed. Weighted Jaccard (shared IDF mass / union IDF
        // mass) is robust even for single-genre candidates — a track carrying only
        // a broad "Rock" tag it shares with a dream-pop seed scores low because the
        // seed's rare genres inflate the union it can't match. A genre-less
        // (artist-only) seed keeps its same-artist pool as-is.
        let space = await genreSpace(for: serverId)
        let seedArtists = Set(seed.artistIds)
        let relevant: [TrackCandidate]
        if space != nil, !seedGenres.isEmpty {
            relevant = fresh.filter { candidate in
                if let artist = candidate.artistRemoteId, seedArtists.contains(artist) { return true }
                return space!.weightedJaccard(seedGenres, candidate.genres) >= Self.minRadioSimilarity
            }
        } else {
            relevant = fresh
        }
        // If nothing is genre-appropriate, wind the station down gracefully (the
        // caller treats an empty batch as "nothing to add") rather than flooding
        // it with the cross-genre outliers the floor just excluded.
        guard !relevant.isEmpty else { return [] }
        let candidates = relevant

        // Score by similarity to the SEED (treat the seed's genres/artists as a
        // synthetic taste), so the station stays close to what it was seeded on.
        let seedTaste = TasteProfile(
            genreAffinity: Dictionary(seedGenres.map { ($0, 1.0) }, uniquingKeysWith: { a, _ in a }),
            artistAffinity: Dictionary(seed.artistIds.map { ($0, 1.0) }, uniquingKeysWith: { a, _ in a }),
            positiveSignal: TasteProfile.coldStartThreshold + 1)
        let scorer = content.withGenreSpace(space)
        let scored = scorer.score(candidates: candidates, taste: seedTaste)
        // Fall back to the pool when nothing scored (e.g. artist-only seed whose
        // tracks carry no genres): still a valid same-artist station.
        let sources = scored.isEmpty
            ? [candidates.map { ScoredCandidate(candidate: $0, score: 1, source: "content") }]
            : [scored]

        // Relax the variety caps for radio: an artist-only seed (no genre signal,
        // even after enrichment) would otherwise be throttled to `maxPerArtist`
        // per batch and stall. Use the EFFECTIVE seed genres so a track seed whose
        // local genres are empty but whose artist has mb_tags still gets the
        // multi-artist genre cap (not the single-artist relaxation).
        let config = Blender.Config(
            limit: limit,
            maxPerArtist: seedGenres.isEmpty ? limit : 6,
            maxPerAlbum: max(2, limit / 4))
        var rng = SeededGenerator(seed: UInt64(truncatingIfNeeded: now().timeIntervalSince1970.bitPattern))
        let ranked = blender.blend(sources: sources, config: config,
                                   excludingArtists: excludingArtists, using: &rng)
        return ranked.map { $0.candidate.remoteId }
    }

    /// (Re)generate "Mozz Weekly" for a server and persist it. Pass a `seed` for
    /// a deterministic ranking (tests); omit it for fresh weekly variety.
    @discardableResult
    public func generateMozzWeekly(serverId: ServerID, limit: Int = 30,
                                   seed: UInt64? = nil) async throws -> RecommendationSetRecord {
        let nowDate = now()
        let enrich = isEnrichmentEnabled()
        let lookback = nowDate.addingTimeInterval(-90 * 24 * 3600).timeIntervalSince1970
        let notPlayedSince = nowDate.addingTimeInterval(-30 * 24 * 3600).timeIntervalSince1970

        let signals = try await store.playedTrackSignals(serverId: serverId, since: lookback, enrich: enrich)
        let taste = TasteProfile.build(from: signals, now: nowDate)
        let suppressedArtists = (try? await store.suppressedArtistIds(serverId: serverId)) ?? []
        let suppressedRefs = (try? await store.suppressedTrackRefs(serverId: serverId)) ?? []

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
                notPlayedSince: notPlayedSince, excludingArtistIds: suppressedArtists,
                limit: 2000, enrich: enrich)
            scored = [await contentScorer(for: serverId).score(candidates: pool, taste: taste)]
            title = "Mozz Weekly"
        }

        // Deterministic when seeded; otherwise varies by generation time.
        var rng = SeededGenerator(seed: seed ?? UInt64(bitPattern: Int64(nowDate.timeIntervalSince1970)))
        let blended = blender.blend(sources: scored, config: Blender.Config(limit: limit),
                                    excluding: suppressedRefs, excludingArtists: suppressedArtists,
                                    using: &rng)

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
        let enrich = isEnrichmentEnabled()
        let nowSec = nowDate.timeIntervalSince1970
        let lookback = nowSec - 90 * 24 * 3600
        // notPlayedSince in the future ⇒ exclude nothing ⇒ include familiar
        // (recently-played) tracks, which is what a Daily Mix / Supermix wants.
        let includeFamiliar = nowSec + 24 * 3600

        let signals = try await store.playedTrackSignals(serverId: serverId, since: lookback, enrich: enrich)
        let taste = TasteProfile.build(from: signals, now: nowDate)
        var rng = SeededGenerator(seed: seed ?? UInt64(bitPattern: Int64(nowSec)))

        try await store.deleteSets(kinds: Self.homeBatchKinds)
        guard !taste.isThin else { return }
        let scorer = await contentScorer(for: serverId)
        let suppressedArtists = (try? await store.suppressedArtistIds(serverId: serverId)) ?? []
        let suppressedRefs = (try? await store.suppressedTrackRefs(serverId: serverId)) ?? []

        // Supermix — broad, familiar-leaning blend across all of the listener's taste.
        let superPool = try await store.candidateTracks(
            serverId: serverId, genres: taste.topGenres(20), artistIds: taste.topArtists(30),
            notPlayedSince: includeFamiliar, excludingArtistIds: suppressedArtists, limit: 3000, enrich: enrich)
        if let ranked = ranked(superPool, taste: taste, scorer: scorer,
                               config: .init(limit: 60, explorationJitter: 0.12, maxPerArtist: 5, maxPerAlbum: 3),
                               excludingRefs: suppressedRefs, excludingArtists: suppressedArtists,
                               rng: &rng) {
            try await save(id: "supermix", title: "Supermix", kind: Self.kindSupermix, items: ranked)
        }

        // Daily Mixes — one coherent mix per top genre.
        for (i, genre) in taste.topGenres(3).enumerated() {
            let pool = try await store.candidateTracks(
                serverId: serverId, genres: [genre], artistIds: [],
                notPlayedSince: includeFamiliar, excludingArtistIds: suppressedArtists, limit: 1000, enrich: enrich)
            if let ranked = ranked(pool, taste: taste, scorer: scorer,
                                   config: .init(limit: 40, explorationJitter: 0.12, maxPerArtist: 4, maxPerAlbum: 2),
                                   excludingRefs: suppressedRefs, excludingArtists: suppressedArtists,
                                   rng: &rng) {
                try await save(id: "daily-mix-\(i + 1)", title: "Daily Mix \(i + 1)", kind: Self.kindDaily, items: ranked)
            }
        }

        // Artist Mixes — a top artist plus same-genre neighbours.
        for (i, artistId) in taste.topArtists(2).enumerated() {
            guard !suppressedArtists.contains(artistId),
                  let seedArtist = try await store.seedArtist(remoteId: artistId, serverId: serverId, enrich: enrich)
            else { continue }
            let pool = try await store.candidateTracks(
                serverId: serverId, genres: Array(seedArtist.genres.prefix(4)), artistIds: [artistId],
                notPlayedSince: includeFamiliar, excludingArtistIds: suppressedArtists, limit: 1000, enrich: enrich)
            if let ranked = ranked(pool, taste: taste, scorer: scorer,
                                   config: .init(limit: 40, explorationJitter: 0.1, maxPerArtist: 6, maxPerAlbum: 3),
                                   excludingRefs: suppressedRefs, excludingArtists: suppressedArtists,
                                   rng: &rng) {
                let title = seedArtist.name.isEmpty ? "Artist Mix" : "\(seedArtist.name) Mix"
                try await save(id: "artist-mix-\(i + 1)", title: title, kind: Self.kindArtist, items: ranked)
            }
        }

        // Replay — most-played recently, in play-count order (no re-ranking). Still
        // honors suppression: a "don't recommend" item shouldn't resurface here.
        let replayPool = try await store.mostPlayedCandidates(serverId: serverId, since: nowSec - 60 * 24 * 3600, limit: 50)
            .filter { !suppressedRefs.contains($0.trackRef)
                && !($0.artistRemoteId.map(suppressedArtists.contains) ?? false) }
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

    // MARK: - Suppression ("Don't recommend")

    /// Suppress a track from all recommendations (hard exclusion). Reversible.
    public func suppressTrack(remoteId: String, serverId: ServerID) async throws {
        try await store.suppress(serverId: serverId, scope: "track", ref: remoteId, at: now().timeIntervalSince1970)
    }

    /// Suppress an artist (and thus all their tracks) from recommendations.
    public func suppressArtist(remoteId: String, serverId: ServerID) async throws {
        try await store.suppress(serverId: serverId, scope: "artist", ref: remoteId, at: now().timeIntervalSince1970)
    }

    public func unsuppressTrack(remoteId: String, serverId: ServerID) async throws {
        try await store.unsuppress(serverId: serverId, scope: "track", ref: remoteId)
    }

    public func unsuppressArtist(remoteId: String, serverId: ServerID) async throws {
        try await store.unsuppress(serverId: serverId, scope: "artist", ref: remoteId)
    }

    /// All active suppressions for a server, newest first (Settings list).
    public func suppressions(serverId: ServerID) async throws -> [(scope: String, ref: String, createdAt: Double)] {
        try await store.suppressions(serverId: serverId)
    }

    /// Suppressions resolved to display names for the Settings "Not Recommended"
    /// list, newest first.
    public func suppressedItems(serverId: ServerID) async throws -> [RecommendationStore.SuppressedItem] {
        try await store.suppressedItemsDetailed(serverId: serverId)
    }

    // MARK: - Home mix helpers

    /// Content-score a pool and blend it; nil if the result is too thin to ship.
    private func ranked(_ pool: [TrackCandidate], taste: TasteProfile, scorer: ContentRecommender,
                        config: Blender.Config, excludingRefs: Set<String> = [],
                        excludingArtists: Set<String> = [], rng: inout SeededGenerator) -> [ScoredCandidate]? {
        guard pool.count >= Self.minTracks else { return nil }
        let scored = scorer.score(candidates: pool, taste: taste)
        let blended = blender.blend(sources: [scored], config: config,
                                    excluding: excludingRefs, excludingArtists: excludingArtists, using: &rng)
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
