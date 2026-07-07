import Foundation
import GRDB
import MozzCore

/// A single listening event joined to its track's genres/artist — raw fuel for
/// taste-profile computation. Emitted by ``RecommendationStore``; consumed by
/// the pure taste logic in `MozzRecommend`.
public struct PlayedTrackSignal: Sendable, Hashable {
    public var trackRef: String
    /// `PlayEventKind` raw value (started|completed|skipped|liked|unliked|seek).
    public var kind: String
    /// Epoch seconds the event fired.
    public var createdAt: Double
    public var genres: [String]
    public var artistRemoteId: String?

    public init(trackRef: String, kind: String, createdAt: Double,
                genres: [String], artistRemoteId: String?) {
        self.trackRef = trackRef
        self.kind = kind
        self.createdAt = createdAt
        self.genres = genres
        self.artistRemoteId = artistRemoteId
    }
}

/// A library track eligible to be recommended, with the attributes the content
/// scorer needs. `trackRef` is the durable recommendation key; `remoteId` is the
/// backend id for playback/navigation.
public struct TrackCandidate: Sendable, Hashable {
    public var trackRef: String
    public var remoteId: String
    public var title: String
    public var artistName: String
    public var artistRemoteId: String?
    public var albumRemoteId: String?
    public var genres: [String]
    public var addedAt: Double?

    public init(trackRef: String, remoteId: String, title: String, artistName: String,
                artistRemoteId: String?, albumRemoteId: String?, genres: [String], addedAt: Double?) {
        self.trackRef = trackRef
        self.remoteId = remoteId
        self.title = title
        self.artistName = artistName
        self.artistRemoteId = artistRemoteId
        self.albumRemoteId = albumRemoteId
        self.genres = genres
        self.addedAt = addedAt
    }
}

/// The DB side of recommendations: persists `track_features` and precomputed
/// recommendation sets, and serves the raw reads the recommender consumes
/// (played-track signals, eligible candidates, cold-start pools). All reads are
/// off the main thread via `MusicDatabase`. Pure ranking/blending lives in
/// `MozzRecommend`; this type never scores.
public struct RecommendationStore: Sendable {
    private let database: MusicDatabase

    public init(_ database: MusicDatabase) {
        self.database = database
    }

    // The SQL expression that reconstructs the opaque track_ref from catalog
    // columns. NEVER split a track_ref — always compose (a serverId may itself
    // contain ':'). Matches PlayEventStore.trackRef.
    private static let refExpr = "(track.serverId || ':' || track.remoteId)"

    // MARK: - track_features

    /// Insert or update the sonic/tag feature columns for a track (UPSERT on
    /// `track_ref`). Deliberately writes ONLY the embedding/tag/bpm columns and
    /// PRESERVES the MBID columns (`mbid`, `artist_mbid`, `mbid_lookup_status`,
    /// `mbid_lookup_at`), which are owned by the enrichment path (`EnrichmentStore`
    /// / `CatalogWriter`). A whole-record `upsert()` would blank the MBID columns
    /// this record doesn't carry, destroying resolved enrichment — so this uses an
    /// explicit column list.
    public func upsertTrackFeatures(_ features: TrackFeaturesRecord) async throws {
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO track_features
                    (track_ref, genres, tags, bpm, replaygain_db, embedding, embedding_dim, feature_source, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(track_ref) DO UPDATE SET
                    genres = excluded.genres,
                    tags = excluded.tags,
                    bpm = excluded.bpm,
                    replaygain_db = excluded.replaygain_db,
                    embedding = excluded.embedding,
                    embedding_dim = excluded.embedding_dim,
                    feature_source = excluded.feature_source,
                    updated_at = excluded.updated_at
                """, arguments: [features.trackRef, features.genres, features.tags, features.bpm,
                                 features.replaygainDb, features.embedding, features.embeddingDim,
                                 features.featureSource, features.updatedAt])
        }
    }

    public func trackFeatures(forTrackRef ref: String) async throws -> TrackFeaturesRecord? {
        try await database.read { db in
            try TrackFeaturesRecord.fetchOne(db, key: ref)
        }
    }

    // MARK: - recommendation sets

    /// Persist a set and its ranked items atomically, replacing any prior items
    /// for the set (regeneration). The set row is upserted; old items are cleared
    /// then the new ranking is inserted.
    public func saveRecommendationSet(_ set: RecommendationSetRecord,
                                      items: [RecommendationItemRecord]) async throws {
        try await database.write { db in
            try set.upsert(db)
            try db.execute(sql: "DELETE FROM recommendation_item WHERE set_id = ?", arguments: [set.id])
            for item in items { try item.insert(db) }
        }
    }

    public func set(id: String) async throws -> RecommendationSetRecord? {
        try await database.read { db in try RecommendationSetRecord.fetchOne(db, key: id) }
    }

    /// Every persisted recommendation set (Home lists and orders these).
    public func allSets() async throws -> [RecommendationSetRecord] {
        try await database.read { db in
            try RecommendationSetRecord.fetchAll(db, sql: "SELECT * FROM recommendation_set")
        }
    }

    /// Delete every set (and its items) of the given kinds. Used to clear a stale
    /// batch of mixes before regenerating, so removed slots don't linger.
    public func deleteSets(kinds: [String]) async throws {
        guard !kinds.isEmpty else { return }
        try await database.write { db in
            let ph = databasePlaceholders(kinds.count)
            let args = StatementArguments(kinds)
            try db.execute(sql: """
                DELETE FROM recommendation_item WHERE set_id IN
                    (SELECT id FROM recommendation_set WHERE kind IN (\(ph)))
                """, arguments: args)
            try db.execute(sql: "DELETE FROM recommendation_set WHERE kind IN (\(ph))", arguments: args)
        }
    }

    /// The artwork key of the highest-ranked in-library track (that has artwork)
    /// in each set — the representative cover for a mix tile, resolved in one
    /// query for every set at once.
    public func representativeArtworkKeys() async throws -> [String: String] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT set_id, artworkKey FROM (
                    SELECT ri.set_id AS set_id, track.artworkKey AS artworkKey,
                           ROW_NUMBER() OVER (PARTITION BY ri.set_id ORDER BY ri.rank) AS rn
                    FROM recommendation_item ri
                    JOIN track ON \(Self.refExpr) = ri.track_ref
                    WHERE track.artworkKey IS NOT NULL AND track.artworkKey <> ''
                ) WHERE rn = 1
                """)
            var out: [String: String] = [:]
            for row in rows { out[row["set_id"]] = row["artworkKey"] }
            return out
        }
    }

    /// The most recently generated set of a given kind, if any.
    public func latestSet(kind: String) async throws -> RecommendationSetRecord? {
        try await database.read { db in
            try RecommendationSetRecord.fetchOne(db, sql: """
                SELECT * FROM recommendation_set WHERE kind = ? ORDER BY generated_at DESC LIMIT 1
                """, arguments: [kind])
        }
    }

    public func items(forSet setId: String) async throws -> [RecommendationItemRecord] {
        try await database.read { db in
            try RecommendationItemRecord.fetchAll(db, sql: """
                SELECT * FROM recommendation_item WHERE set_id = ? ORDER BY rank
                """, arguments: [setId])
        }
    }

    /// The in-library tracks of a set, in rank order, resolved to catalog rows
    /// for the UI. Out-of-library (discovery) items and refs with no current
    /// catalog row are omitted — callers that need those read `items(forSet:)`.
    public func tracks(forSet setId: String) async throws -> [TrackRecord] {
        try await database.read { db in
            try TrackRecord.fetchAll(db, sql: """
                SELECT track.* FROM recommendation_item ri
                JOIN track ON \(Self.refExpr) = ri.track_ref
                WHERE ri.set_id = ? AND ri.in_library = 1
                ORDER BY ri.rank
                """, arguments: [setId])
        }
    }

    // MARK: - recommender inputs (raw reads; scoring happens in MozzRecommend)

    /// Listening events joined to each track's genres/artist, newest first —
    /// the raw signal a taste profile is built from. Events whose track isn't in
    /// the catalog are skipped (we need genres). `since` filters by recency.
    public func playedTrackSignals(serverId: ServerID, since: Double? = nil,
                                   limit: Int = 2000, enrich: Bool = false) async throws -> [PlayedTrackSignal] {
        try await database.read { db in
            let mbTagsSelect = enrich ? ", tf.mb_tags AS mb_tags" : ""
            let mbTagsJoin = enrich ? "LEFT JOIN track_features tf ON tf.track_ref = pe.track_ref" : ""
            var sql = """
                SELECT pe.track_ref AS track_ref, pe.kind AS kind, pe.created_at AS created_at,
                       track.genres AS genres, track.artistRemoteId AS artistRemoteId\(mbTagsSelect)
                FROM play_event pe
                JOIN track ON \(Self.refExpr) = pe.track_ref
                \(mbTagsJoin)
                WHERE track.serverId = ?
                """
            var args: [DatabaseValueConvertible?] = [serverId]
            if let since {
                sql += " AND pe.created_at >= ?"
                args.append(since)
            }
            sql += " ORDER BY pe.created_at DESC LIMIT ?"
            args.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map {
                // Enriched: taste genres are the CANONICAL union of track.genres and
                // mb_tags — symmetric with the (identically normalized) candidates,
                // so a perfect match can't drop below the floor. Off → raw (today).
                let base = Self.decodeGenres($0["genres"])
                let genres = enrich ? GenreNormalizer.merge(base, Self.decodeGenres($0["mb_tags"])) : base
                return PlayedTrackSignal(
                    trackRef: $0["track_ref"], kind: $0["kind"], createdAt: $0["created_at"],
                    genres: genres, artistRemoteId: $0["artistRemoteId"]
                )
            }
        }
    }

    /// Most-recent play epoch (seconds) per track `remoteId` on a server — the
    /// basis for recency-biased shuffle. A track counts as played on `started`
    /// or `completed` (a pure skip doesn't). Off the main thread.
    public func lastPlayedByRemoteID(serverId: ServerID) async throws -> [String: Double] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT track.remoteId AS remoteId, MAX(pe.created_at) AS last_played
                FROM play_event pe
                JOIN track ON \(Self.refExpr) = pe.track_ref
                WHERE track.serverId = ? AND pe.kind IN ('started', 'completed')
                GROUP BY track.remoteId
                """, arguments: [serverId])
            var map: [String: Double] = [:]
            map.reserveCapacity(rows.count)
            for row in rows {
                if let id: String = row["remoteId"], let ts: Double = row["last_played"] {
                    map[id] = ts
                }
            }
            return map
        }
    }

    /// Library-wide genre document frequencies on a server: how many tracks carry
    /// each genre, plus the total track count. Feeds TF-IDF genre similarity (rare
    /// genres are discriminative, ubiquitous ones like "Rock" are not). Computed
    /// off the main thread with a single grouped scan over `json_each`.
    ///
    /// When `enrich` is true (B4.5), the corpus is the CANONICAL union of
    /// `track.genres` and `mb_tags`, normalized by `GenreNormalizer` — so IDF keys
    /// line up with the (identically normalized) candidate/seed/taste sides.
    /// Normalization is Swift-side (SQLite `LOWER()` can't fold separators, and
    /// `mb_tags` are already Swift-lowercased at rest), so we pull `(remoteId,
    /// rawGenre)` pairs and fold in memory; `df` is distinct remoteIds per key, so a
    /// genre in BOTH columns of one track counts once. When `enrich` is false the
    /// original raw, case-sensitive, SQL-grouped path runs unchanged (off == today).
    public func genreFrequencies(serverId: ServerID, enrich: Bool = false)
        async throws -> (total: Int, counts: [String: Int]) {
        try await database.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE serverId = ?",
                                         arguments: [serverId]) ?? 0
            guard enrich else {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT je.value AS genre, COUNT(DISTINCT track.remoteId) AS df
                    FROM track, json_each(track.genres) je
                    WHERE track.serverId = ?
                    GROUP BY je.value
                    """, arguments: [serverId])
                var counts: [String: Int] = [:]
                counts.reserveCapacity(rows.count)
                for row in rows {
                    if let genre: String = row["genre"], !genre.isEmpty {
                        counts[genre] = row["df"]
                    }
                }
                return (total, counts)
            }
            // Enriched: fold both columns in Swift, dedupe per (remoteId, key).
            let rows = try Row.fetchAll(db, sql: """
                SELECT track.remoteId AS remoteId, je.value AS genre
                FROM track, json_each(track.genres) je
                WHERE track.serverId = ? AND json_valid(track.genres)
                UNION ALL
                SELECT track.remoteId AS remoteId, je.value AS genre
                FROM track JOIN track_features tf ON tf.track_ref = \(Self.refExpr),
                     json_each(tf.mb_tags) je
                WHERE track.serverId = ? AND tf.mb_tags IS NOT NULL AND json_valid(tf.mb_tags)
                """, arguments: [serverId, serverId])
            var byGenre: [String: Set<String>] = [:]
            for row in rows {
                guard let remoteId: String = row["remoteId"], let raw: String = row["genre"] else { continue }
                let key = GenreNormalizer.key(raw)
                guard !key.isEmpty else { continue }
                byGenre[key, default: []].insert(remoteId)
            }
            var counts: [String: Int] = [:]
            counts.reserveCapacity(byGenre.count)
            for (genre, ids) in byGenre { counts[genre] = ids.count }
            return (total, counts)
        }
    }

    /// Library tracks eligible for in-library rediscovery: on this server, NOT
    /// played since `notPlayedSince`, and matching at least one taste genre or
    /// artist. Capped to a pool `limit`; the pool is sampled randomly so a huge
    /// library doesn't always surface the same slice. Returns [] when no taste
    /// filters are given (caller should use the cold-start pool instead).
    ///
    /// `excludingRemoteIds` (e.g. tracks a radio station has already surfaced) is
    /// applied in SQL *before* the random sample + limit, so the sample is drawn
    /// from unseen tracks — otherwise a random slice near the tail of a large
    /// catalog can miss the remaining unseen tracks and the station stalls early.
    /// Bounded to keep well under SQLite's bound-parameter limit; anything beyond
    /// the bound is left to the caller's in-memory filter.
    public func candidateTracks(serverId: ServerID, genres: [String], artistIds: [String],
                                notPlayedSince: Double, excludingRemoteIds: Set<String> = [],
                                limit: Int = 2000, enrich: Bool = false) async throws -> [TrackCandidate] {
        guard !genres.isEmpty || !artistIds.isEmpty else { return [] }
        let excludeList = Array(excludingRemoteIds.prefix(Self.maxSQLExclusions))
        return try await database.read { db in
            var args: [DatabaseValueConvertible?] = [serverId, notPlayedSince]
            var matchClauses: [String] = []
            if !artistIds.isEmpty {
                let ph = databasePlaceholders(artistIds.count)
                matchClauses.append("track.artistRemoteId IN (\(ph))")
                args.append(contentsOf: artistIds)
            }
            if !genres.isEmpty {
                let ph = databasePlaceholders(genres.count)
                if enrich {
                    // `genres` are normalized keys (case + separators folded). Match
                    // track.genres by applying the SAME fold in SQL (lowercase +
                    // fold -/_/ to space) so "Hip-Hop" matches the key "hip hop" —
                    // otherwise an un-enriched hyphenated genre would be missed
                    // (a recall regression vs today). OR exact on the already-
                    // normalized mb_tags. json_valid guards so one malformed row
                    // can't abort the whole scan. (A rare double-space genre still
                    // won't fold whitespace runs here; scoring stays authoritative.)
                    matchClauses.append("""
                        (EXISTS (SELECT 1 FROM json_each(track.genres) je
                                 WHERE json_valid(track.genres)
                                   AND LOWER(REPLACE(REPLACE(REPLACE(je.value, '-', ' '), '_', ' '), '/', ' ')) IN (\(ph)))
                         OR EXISTS (SELECT 1 FROM json_each(tf.mb_tags) je
                                 WHERE tf.mb_tags IS NOT NULL AND json_valid(tf.mb_tags) AND je.value IN (\(ph))))
                        """)
                    args.append(contentsOf: genres)   // track.genres folded arm
                    args.append(contentsOf: genres)   // mb_tags exact arm
                } else {
                    matchClauses.append("EXISTS (SELECT 1 FROM json_each(track.genres) je WHERE je.value IN (\(ph)))")
                    args.append(contentsOf: genres)
                }
            }
            var excludeClause = ""
            if !excludeList.isEmpty {
                excludeClause = "AND track.remoteId NOT IN (\(databasePlaceholders(excludeList.count)))"
                args.append(contentsOf: excludeList)
            }
            args.append(limit)
            let mbTagsSelect = enrich ? ", tf.mb_tags AS mb_tags" : ""
            let mbTagsJoin = enrich ? "LEFT JOIN track_features tf ON tf.track_ref = \(Self.refExpr)" : ""
            let sql = """
                SELECT \(Self.refExpr) AS track_ref, track.remoteId AS remoteId, track.title AS title,
                       track.artistName AS artistName, track.artistRemoteId AS artistRemoteId,
                       track.albumRemoteId AS albumRemoteId, track.genres AS genres, track.addedAt AS addedAt\(mbTagsSelect)
                FROM track
                \(mbTagsJoin)
                WHERE track.serverId = ?
                  AND NOT EXISTS (SELECT 1 FROM play_event pe
                                  WHERE pe.track_ref = \(Self.refExpr)
                                    AND pe.created_at >= ? AND pe.kind IN ('started','completed'))
                  AND (\(matchClauses.joined(separator: " OR ")))
                  \(excludeClause)
                ORDER BY RANDOM() LIMIT ?
                """
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                .map { Self.candidate($0, enrich: enrich) }
        }
    }

    /// Upper bound on ids passed to a SQL `NOT IN` (SQLite's default host-param
    /// limit is 999; stay comfortably under it alongside the other bindings).
    private static let maxSQLExclusions = 800

    /// Cold-start pool for a thin/empty history: most-recently-added tracks not
    /// played since `notPlayedSince`. (Popularity would also feed cold start, but
    /// with little history "recently added" is the reliable signal.)
    public func recentlyAddedCandidates(serverId: ServerID, notPlayedSince: Double,
                                        limit: Int = 200) async throws -> [TrackCandidate] {
        try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Self.refExpr) AS track_ref, track.remoteId AS remoteId, track.title AS title,
                       track.artistName AS artistName, track.artistRemoteId AS artistRemoteId,
                       track.albumRemoteId AS albumRemoteId, track.genres AS genres, track.addedAt AS addedAt
                FROM track
                WHERE track.serverId = ?
                  AND NOT EXISTS (SELECT 1 FROM play_event pe
                                  WHERE pe.track_ref = \(Self.refExpr)
                                    AND pe.created_at >= ? AND pe.kind IN ('started','completed'))
                ORDER BY track.addedAt DESC NULLS LAST, track.remoteId
                LIMIT ?
                """, arguments: [serverId, notPlayedSince, limit]).map { Self.candidate($0) }
        }
    }

    /// The listener's most-played tracks since `since`, ordered by play count then
    /// recency — the pool for a "Replay" mix. Play count = started/completed
    /// events (skips/seeks don't count as replays).
    public func mostPlayedCandidates(serverId: ServerID, since: Double,
                                     limit: Int = 100) async throws -> [TrackCandidate] {
        try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Self.refExpr) AS track_ref, track.remoteId AS remoteId, track.title AS title,
                       track.artistName AS artistName, track.artistRemoteId AS artistRemoteId,
                       track.albumRemoteId AS albumRemoteId, track.genres AS genres, track.addedAt AS addedAt,
                       COUNT(*) AS play_count, MAX(pe.created_at) AS last_played
                FROM play_event pe
                JOIN track ON \(Self.refExpr) = pe.track_ref
                WHERE track.serverId = ? AND pe.kind IN ('started','completed') AND pe.created_at >= ?
                GROUP BY track_ref
                ORDER BY play_count DESC, last_played DESC
                LIMIT ?
                """, arguments: [serverId, since, limit]).map { Self.candidate($0) }
        }
    }

    /// A seed artist's display name and its genres (unioned across the artist's
    /// tracks, most common first) — used to build an "{Artist} Mix" pool of that
    /// artist plus same-genre neighbours.
    ///
    /// When `enrich` (B4.5), each track's effective genres are the CANONICAL union
    /// of `track.genres` and its `mb_tags`, normalized — so an artist-seeded pool is
    /// enriched symmetrically with the candidates it's matched against (otherwise an
    /// un-enriched seed vs enriched candidates recreates the asymmetric floor drop).
    public func seedArtist(remoteId: String, serverId: ServerID,
                           enrich: Bool = false) async throws -> (name: String, genres: [String])? {
        try await database.read { db in
            let mbTagsSelect = enrich ? ", tf.mb_tags AS mb_tags" : ""
            let mbTagsJoin = enrich ? "LEFT JOIN track_features tf ON tf.track_ref = \(Self.refExpr)" : ""
            let rows = try Row.fetchAll(db, sql: """
                SELECT track.artistName AS artistName, track.genres AS genres\(mbTagsSelect)
                FROM track
                \(mbTagsJoin)
                WHERE track.serverId = ? AND track.artistRemoteId = ?
                LIMIT 100
                """, arguments: [serverId, remoteId])
            guard !rows.isEmpty else { return nil }
            let name = rows.compactMap { ($0["artistName"] as String?).flatMap { $0.isEmpty ? nil : $0 } }.first ?? ""
            var counts: [String: Int] = [:]
            for row in rows {
                let base = Self.decodeGenres(row["genres"])
                let effective = enrich ? GenreNormalizer.merge(base, Self.decodeGenres(row["mb_tags"])) : base
                for g in effective { counts[g, default: 0] += 1 }
            }
            let genres = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
            return (name, genres)
        }
    }

    /// The `mb_tags` (raw canonical MB genres) for one track by its durable
    /// `track_ref` — a fast PK lookup on `track_features`. Empty when the track has
    /// no row or no tags. Callers merge these into a seed's genres (B4.5). Returns
    /// `[]` (never nil) so a missing row degrades to "no enrichment", not a failure.
    public func mbTags(forTrackRef ref: String) async throws -> [String] {
        try await database.read { db in
            guard let json = try String.fetchOne(
                db, sql: "SELECT mb_tags FROM track_features WHERE track_ref = ? AND mb_tags IS NOT NULL",
                arguments: [ref]) else { return [] }
            return Self.decodeGenres(json)
        }
    }

    /// `mb_tags` for many tracks keyed by `track_ref` — for enriching a large,
    /// in-memory candidate set (Smart Shuffle) without a per-track round trip.
    /// Batches under the SQLite host-parameter limit and UNIONs every batch (NOT a
    /// truncating `prefix` — every track must be reachable, since the full library
    /// is passed for shuffle-everything). Only tracks with tags appear in the map.
    public func mbTags(forTrackRefs refs: [String]) async throws -> [String: [String]] {
        guard !refs.isEmpty else { return [:] }
        let unique = Array(Set(refs))
        var out: [String: [String]] = [:]
        try await database.read { db in
            for chunk in stride(from: 0, to: unique.count, by: Self.maxSQLExclusions).map({
                Array(unique[$0..<min($0 + Self.maxSQLExclusions, unique.count)])
            }) {
                let ph = databasePlaceholders(chunk.count)
                let rows = try Row.fetchAll(db, sql: """
                    SELECT track_ref, mb_tags FROM track_features
                    WHERE mb_tags IS NOT NULL AND track_ref IN (\(ph))
                    """, arguments: StatementArguments(chunk))
                for row in rows {
                    if let ref: String = row["track_ref"] {
                        out[ref] = Self.decodeGenres(row["mb_tags"])
                    }
                }
            }
        }
        return out
    }

    // MARK: - mapping helpers

    private static func candidate(_ row: Row, enrich: Bool = false) -> TrackCandidate {
        let base = decodeGenres(row["genres"])
        // When enriched, return the CANONICAL union of track.genres and mb_tags
        // (mb_tags column absent on non-enriched queries → []), so candidate keys
        // match the identically-normalized corpus/seed/taste. Off → raw (today).
        let genres = enrich ? GenreNormalizer.merge(base, decodeGenres(row["mb_tags"])) : base
        return TrackCandidate(
            trackRef: row["track_ref"], remoteId: row["remoteId"], title: row["title"],
            artistName: row["artistName"], artistRemoteId: row["artistRemoteId"],
            albumRemoteId: row["albumRemoteId"], genres: genres,
            addedAt: row["addedAt"]
        )
    }

    private static func decodeGenres(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }
}

/// `?, ?, ?` for an IN clause of `count` values.
private func databasePlaceholders(_ count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}