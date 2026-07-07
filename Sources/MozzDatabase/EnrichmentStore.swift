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
                    durationMs: duration.map { $0 * 1000 })
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
}
