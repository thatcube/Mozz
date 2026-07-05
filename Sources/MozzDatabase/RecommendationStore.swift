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

    /// Insert or update the feature row for a track (UPSERT on `track_ref`).
    public func upsertTrackFeatures(_ features: TrackFeaturesRecord) async throws {
        try await database.write { db in try features.upsert(db) }
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
                                   limit: Int = 2000) async throws -> [PlayedTrackSignal] {
        try await database.read { db in
            var sql = """
                SELECT pe.track_ref AS track_ref, pe.kind AS kind, pe.created_at AS created_at,
                       track.genres AS genres, track.artistRemoteId AS artistRemoteId
                FROM play_event pe
                JOIN track ON \(Self.refExpr) = pe.track_ref
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
                PlayedTrackSignal(
                    trackRef: $0["track_ref"], kind: $0["kind"], createdAt: $0["created_at"],
                    genres: Self.decodeGenres($0["genres"]), artistRemoteId: $0["artistRemoteId"]
                )
            }
        }
    }

    /// Library tracks eligible for in-library rediscovery: on this server, NOT
    /// played since `notPlayedSince`, and matching at least one taste genre or
    /// artist. Capped to a pool `limit`; the pool is sampled randomly so a huge
    /// library doesn't always surface the same slice. Returns [] when no taste
    /// filters are given (caller should use the cold-start pool instead).
    public func candidateTracks(serverId: ServerID, genres: [String], artistIds: [String],
                                notPlayedSince: Double, limit: Int = 2000) async throws -> [TrackCandidate] {
        guard !genres.isEmpty || !artistIds.isEmpty else { return [] }
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
                matchClauses.append("EXISTS (SELECT 1 FROM json_each(track.genres) je WHERE je.value IN (\(ph)))")
                args.append(contentsOf: genres)
            }
            args.append(limit)
            let sql = """
                SELECT \(Self.refExpr) AS track_ref, track.remoteId AS remoteId, track.title AS title,
                       track.artistName AS artistName, track.artistRemoteId AS artistRemoteId,
                       track.albumRemoteId AS albumRemoteId, track.genres AS genres, track.addedAt AS addedAt
                FROM track
                WHERE track.serverId = ?
                  AND NOT EXISTS (SELECT 1 FROM play_event pe
                                  WHERE pe.track_ref = \(Self.refExpr)
                                    AND pe.created_at >= ? AND pe.kind IN ('started','completed'))
                  AND (\(matchClauses.joined(separator: " OR ")))
                ORDER BY RANDOM() LIMIT ?
                """
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map(Self.candidate)
        }
    }

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
                """, arguments: [serverId, notPlayedSince, limit]).map(Self.candidate)
        }
    }

    // MARK: - mapping helpers

    private static func candidate(_ row: Row) -> TrackCandidate {
        TrackCandidate(
            trackRef: row["track_ref"], remoteId: row["remoteId"], title: row["title"],
            artistName: row["artistName"], artistRemoteId: row["artistRemoteId"],
            albumRemoteId: row["albumRemoteId"], genres: decodeGenres(row["genres"]),
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