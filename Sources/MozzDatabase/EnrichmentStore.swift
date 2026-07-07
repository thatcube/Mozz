import Foundation
import GRDB
import MozzCore

/// A library track that still needs a MusicBrainz recording MBID resolved, with
/// the fields a name-search needs. `existingArtistMbid` is any artist MBID a
/// prior lookup already stored (so a track search can prefer it).
public struct MBIDResolutionCandidate: Sendable, Hashable {
    public var trackRef: String
    public var remoteId: String
    public var title: String
    public var artistName: String
    public var artistRemoteId: String?
    public var existingArtistMbid: String?
    /// Track duration in milliseconds (for MusicBrainz duration disambiguation).
    public var durationMs: Double?

    public init(trackRef: String, remoteId: String, title: String, artistName: String,
                artistRemoteId: String?, existingArtistMbid: String?, durationMs: Double?) {
        self.trackRef = trackRef
        self.remoteId = remoteId
        self.title = title
        self.artistName = artistName
        self.artistRemoteId = artistRemoteId
        self.existingArtistMbid = existingArtistMbid
        self.durationMs = durationMs
    }
}

/// The current MBID state of a track's `track_features` row (nil if no row).
public struct MBIDState: Sendable, Hashable {
    public var mbid: String?
    public var artistMbid: String?
    public var lookupStatus: String?
    public var lookupAt: Double?

    public init(mbid: String?, artistMbid: String?, lookupStatus: String?, lookupAt: Double?) {
        self.mbid = mbid
        self.artistMbid = artistMbid
        self.lookupStatus = lookupStatus
        self.lookupAt = lookupAt
    }
}

/// The DB seam for open metadata enrichment (ADR-0007). Encapsulates all
/// `track_features` MBID SQL so `MozzEnrichment` (network + orchestration) and
/// `MozzRecommend` (ranking) never import GRDB. Tier-1 embedded MBIDs are written
/// by `CatalogWriter` during sync; this store serves the name-search tier and,
/// later, the similarity reads (B2/B3). Everything keys on the durable
/// `track_ref` (= `PlayEventStore.trackRef`), so enrichment survives a catalog
/// prune.
public struct EnrichmentStore: Sendable {
    private let database: MusicDatabase

    public init(_ database: MusicDatabase) {
        self.database = database
    }

    // The SQL expression that reconstructs the opaque track_ref from catalog
    // columns. NEVER split a track_ref — always compose (matches
    // PlayEventStore.trackRef / RecommendationStore.refExpr).
    private static let refExpr = "(track.serverId || ':' || track.remoteId)"

    // MARK: - Reads

    /// Library tracks that still lack an MBID and are due for a (re)lookup:
    /// `track_features.mbid` is null AND we've never looked up, or the last
    /// lookup was before `notLookedUpSince` (now − TTL). Prioritized so a bounded
    /// per-run budget lands on tracks the user actually hears: most-recently
    /// played first, then favorites, then most-recently added. Capped by `limit`.
    public func tracksNeedingResolution(serverId: ServerID,
                                        notLookedUpSince: Double,
                                        limit: Int) async throws -> [MBIDResolutionCandidate] {
        try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Self.refExpr) AS track_ref, track.remoteId AS remoteId,
                       track.title AS title, track.artistName AS artistName,
                       track.artistRemoteId AS artistRemoteId, tf.artist_mbid AS artist_mbid,
                       track.duration AS duration
                FROM track
                LEFT JOIN track_features tf ON tf.track_ref = \(Self.refExpr)
                LEFT JOIN (SELECT track_ref, MAX(created_at) AS lastPlayed
                           FROM play_event GROUP BY track_ref) lp
                       ON lp.track_ref = \(Self.refExpr)
                WHERE track.serverId = ?
                  AND (tf.mbid IS NULL OR tf.mbid = '')
                  AND (tf.mbid_lookup_at IS NULL OR tf.mbid_lookup_at < ?)
                ORDER BY lp.lastPlayed DESC, track.isFavorite DESC, track.addedAt DESC
                LIMIT ?
                """, arguments: [serverId, notLookedUpSince, limit]).map {
                let duration: Double? = $0["duration"]
                return MBIDResolutionCandidate(
                    trackRef: $0["track_ref"], remoteId: $0["remoteId"], title: $0["title"],
                    artistName: $0["artistName"], artistRemoteId: $0["artistRemoteId"],
                    existingArtistMbid: $0["artist_mbid"],
                    // The `duration` column is NOT NULL DEFAULT 0 and mappers coerce
                    // an unknown runtime to 0, so treat a non-positive value as
                    // "unknown" — otherwise the MusicBrainz duration gate would
                    // compare against 0ms and reject (and negative-cache) every
                    // track whose backend didn't report a length.
                    durationMs: duration.flatMap { $0 > 0 ? $0 * 1000 : nil })
            }
        }
    }

    /// The MBID state of a single track (nil when no `track_features` row exists).
    public func mbidState(trackRef: String) async throws -> MBIDState? {
        try await database.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT mbid, artist_mbid, mbid_lookup_status, mbid_lookup_at
                FROM track_features WHERE track_ref = ?
                """, arguments: [trackRef]) else { return nil }
            return MBIDState(mbid: row["mbid"], artistMbid: row["artist_mbid"],
                             lookupStatus: row["mbid_lookup_status"], lookupAt: row["mbid_lookup_at"])
        }
    }

    // MARK: - Writes (name-search tier)

    /// Record the outcome of a MusicBrainz name-search for a track.
    ///
    /// Found (`mbid != nil`): writes the recording MBID + `found` status;
    /// `artist_mbid` is COALESCEd so a null can't wipe an existing value.
    /// Miss (`mbid == nil`): records only `notfound` + the lookup time (the
    /// negative cache), leaving `mbid`/`artist_mbid` untouched. Neither path
    /// touches `tags`/`embedding`/`bpm`/`feature_source`. Keyed on `track_ref`.
    public func recordTrackResolution(trackRef: String, mbid: String?,
                                      artistMbid: String?, at: Double) async throws {
        let normalizedMbid = MusicBrainzID.normalized(mbid)
        let normalizedArtist = MusicBrainzID.normalized(artistMbid)
        try await database.write { db in
            if let recording = normalizedMbid {
                try db.execute(sql: """
                    INSERT INTO track_features
                        (track_ref, mbid, artist_mbid, mbid_lookup_status, mbid_lookup_at, updated_at)
                    VALUES (?, ?, ?, 'found', ?, ?)
                    ON CONFLICT(track_ref) DO UPDATE SET
                        mbid = excluded.mbid,
                        artist_mbid = COALESCE(excluded.artist_mbid, track_features.artist_mbid),
                        mbid_lookup_status = 'found',
                        mbid_lookup_at = excluded.mbid_lookup_at,
                        updated_at = excluded.updated_at
                    """, arguments: [trackRef, recording, normalizedArtist, at, at])
            } else {
                try db.execute(sql: """
                    INSERT INTO track_features
                        (track_ref, mbid_lookup_status, mbid_lookup_at, updated_at)
                    VALUES (?, 'notfound', ?, ?)
                    ON CONFLICT(track_ref) DO UPDATE SET
                        mbid_lookup_status = 'notfound',
                        mbid_lookup_at = excluded.mbid_lookup_at,
                        updated_at = excluded.updated_at
                    """, arguments: [trackRef, at, at])
            }
        }
    }

    // MARK: - B2: canonicalization + similarity

    /// Distinct raw MBIDs of owned tracks that have an `mbid` but no
    /// `canonical_mbid` yet (or whose canonical lookup is stale). Prioritized like
    /// resolution (recently played / favorites first).
    public func canonicalNeedingLookup(serverId: ServerID, notLookedUpSince: Double,
                                       limit: Int) async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(db, sql: """
                SELECT tf.mbid
                FROM track
                JOIN track_features tf ON tf.track_ref = \(Self.refExpr)
                LEFT JOIN (SELECT track_ref, MAX(created_at) AS lastPlayed
                           FROM play_event GROUP BY track_ref) lp
                       ON lp.track_ref = \(Self.refExpr)
                WHERE track.serverId = ?
                  AND tf.mbid IS NOT NULL AND tf.mbid <> ''
                  AND tf.canonical_mbid IS NULL
                  AND (tf.canonical_lookup_at IS NULL OR tf.canonical_lookup_at < ?)
                GROUP BY tf.mbid
                ORDER BY MAX(lp.lastPlayed) DESC, MAX(track.isFavorite) DESC
                LIMIT ?
                """, arguments: [serverId, notLookedUpSince, limit])
        }
    }

    /// Store a canonical MBID for every track carrying `mbid`, stamping the
    /// canonical-lookup time. Pass `canonical == nil` for a transient
    /// failure/no-mapping: only the timestamp is stamped (TTL negative cache), so
    /// it's retried later rather than every pass. `canonical` may equal `mbid`
    /// (the lookup returned the same id) — still valid.
    public func setCanonical(mbid: String, canonical: String?, at: Double) async throws {
        try await database.write { db in
            if let canonical {
                try db.execute(sql: """
                    UPDATE track_features
                    SET canonical_mbid = ?, canonical_lookup_at = ?, updated_at = ?
                    WHERE mbid = ?
                    """, arguments: [canonical, at, at, mbid])
            } else {
                try db.execute(sql: """
                    UPDATE track_features SET canonical_lookup_at = ?, updated_at = ?
                    WHERE mbid = ?
                    """, arguments: [at, at, mbid])
            }
        }
    }

    /// Distinct canonical MBIDs of owned tracks whose similarity hasn't been
    /// fetched (or is stale). Prioritized recently played / favorites first.
    public func recordingsNeedingSimilarity(serverId: ServerID, notFetchedSince: Double,
                                            limit: Int) async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(db, sql: """
                SELECT tf.canonical_mbid
                FROM track
                JOIN track_features tf ON tf.track_ref = \(Self.refExpr)
                LEFT JOIN (SELECT track_ref, MAX(created_at) AS lastPlayed
                           FROM play_event GROUP BY track_ref) lp
                       ON lp.track_ref = \(Self.refExpr)
                WHERE track.serverId = ?
                  AND tf.canonical_mbid IS NOT NULL AND tf.canonical_mbid <> ''
                  AND (tf.similar_lookup_at IS NULL OR tf.similar_lookup_at < ?)
                GROUP BY tf.canonical_mbid
                ORDER BY MAX(lp.lastPlayed) DESC, MAX(track.isFavorite) DESC
                LIMIT ?
                """, arguments: [serverId, notFetchedSince, limit])
        }
    }

    /// Replace the similarity rows for a source canonical MBID + algorithm, and
    /// stamp `similar_lookup_at` for every track sharing that canonical MBID —
    /// including when `pairs` is empty (a valid "no similar data" negative cache).
    public func replaceSimilarRecordings(sourceMbid: String, algorithm: String,
                                         pairs: [(similarMbid: String, score: Double)],
                                         at: Double) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM similar_recording WHERE source_mbid = ? AND algorithm = ?",
                           arguments: [sourceMbid, algorithm])
            let stmt = try db.makeStatement(sql: """
                INSERT OR REPLACE INTO similar_recording (source_mbid, similar_mbid, score, algorithm)
                VALUES (?, ?, ?, ?)
                """)
            for pair in pairs {
                guard let similar = MusicBrainzID.normalized(pair.similarMbid), similar != sourceMbid
                else { continue }
                try stmt.execute(arguments: [sourceMbid, similar, pair.score, algorithm])
            }
            try db.execute(sql: """
                UPDATE track_features SET similar_lookup_at = ?, updated_at = ?
                WHERE canonical_mbid = ?
                """, arguments: [at, at, sourceMbid])
        }
    }

    /// The reverse map: owned tracks similar to any of `seedCanonicalMbids`, ranked
    /// by similarity. Joins similarity → `track_features.canonical_mbid` → owned
    /// `track` on this server, de-duped per track with `MAX(score)` (closest seed).
    /// Excludes already-queued remote ids. Drives `FROM track WHERE serverId=?` so
    /// the ref-join is index-backed. Seed/exclusion lists are bounded to stay under
    /// SQLite's host-parameter limit.
    public func similarOwnedTracks(seedCanonicalMbids: [String], algorithm: String,
                                   serverId: ServerID, excludingRemoteIds: Set<String> = [],
                                   limit: Int) async throws -> [ScoredOwnedTrack] {
        let seeds = Array(Set(seedCanonicalMbids)).prefix(Self.maxSeeds)
        guard !seeds.isEmpty else { return [] }
        let excludeList = Array(excludingRemoteIds.prefix(Self.maxExclusions))
        return try await database.read { db in
            var excludeClause = ""
            if !excludeList.isEmpty {
                excludeClause = "AND track.remoteId NOT IN (\(placeholders(excludeList.count)))"
            }
            let sql = """
                SELECT \(Self.refExpr) AS track_ref, track.remoteId AS remoteId, track.title AS title,
                       track.artistName AS artistName, track.artistRemoteId AS artistRemoteId,
                       track.albumRemoteId AS albumRemoteId, track.genres AS genres,
                       track.addedAt AS addedAt, MAX(sr.score) AS score
                FROM track
                JOIN track_features tf ON tf.track_ref = \(Self.refExpr)
                JOIN similar_recording sr ON sr.similar_mbid = tf.canonical_mbid AND sr.algorithm = ?
                WHERE track.serverId = ?
                  AND sr.source_mbid IN (\(placeholders(seeds.count)))
                  \(excludeClause)
                GROUP BY track.remoteId
                ORDER BY score DESC, track.remoteId ASC
                LIMIT ?
                """
            // Arg order matches placeholder order: algorithm, serverId, seeds…,
            // [excludes…], limit.
            var ordered: [DatabaseValueConvertible] = [algorithm, serverId]
            ordered.append(contentsOf: seeds.map { $0 as DatabaseValueConvertible })
            ordered.append(contentsOf: excludeList.map { $0 as DatabaseValueConvertible })
            ordered.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(ordered)).map {
                ScoredOwnedTrack(
                    candidate: TrackCandidate(
                        trackRef: $0["track_ref"], remoteId: $0["remoteId"], title: $0["title"],
                        artistName: $0["artistName"], artistRemoteId: $0["artistRemoteId"],
                        albumRemoteId: $0["albumRemoteId"], genres: decodeGenreArray($0["genres"]),
                        addedAt: $0["addedAt"]),
                    score: $0["score"] ?? 0)
            }
        }
    }

    /// The canonical (falling back to raw) recording MBID of a seed track, for
    /// on-demand similarity (B3). Nil if the track has no resolved MBID.
    public func seedMbid(forTrackRef ref: String) async throws -> (mbid: String?, canonical: String?)? {
        try await database.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT mbid, canonical_mbid FROM track_features WHERE track_ref = ?
                """, arguments: [ref]) else { return nil }
            return (row["mbid"], row["canonical_mbid"])
        }
    }

    private static let maxSeeds = 400
    private static let maxExclusions = 400
}

/// An owned library track surfaced by similarity, with its aggregate score.
public struct ScoredOwnedTrack: Sendable, Hashable {
    public let candidate: TrackCandidate
    public let score: Double
    public init(candidate: TrackCandidate, score: Double) {
        self.candidate = candidate
        self.score = score
    }
}

private func placeholders(_ count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}

private func decodeGenreArray(_ json: String?) -> [String] {
    guard let json, let data = json.data(using: .utf8),
          let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
    return arr
}
