import Foundation
import GRDB
import MozzCore

/// Combined full-text search results across the three catalog entity types.
public struct SearchResults: Sendable {
    public var artists: [ArtistRecord]
    public var albums: [AlbumRecord]
    public var tracks: [TrackRecord]

    public var isEmpty: Bool { artists.isEmpty && albums.isEmpty && tracks.isEmpty }

    public init(artists: [ArtistRecord] = [], albums: [AlbumRecord] = [], tracks: [TrackRecord] = []) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
    }
}

extension Array where Element == AlbumRecord {
    /// Collapse album fragments (same `albumGroupKey`) to one representative,
    /// keeping the first occurrence — which, for a ranked FTS result, is the
    /// best-scored fragment — then cap at `limit`. Used to dedupe search results
    /// without limiting *before* grouping (which would let fragments of one album
    /// crowd out distinct albums).
    func dedupedByAlbumGroup(limit: Int) -> [AlbumRecord] {
        var seen = Set<String>()
        var out: [AlbumRecord] = []
        out.reserveCapacity(Swift.min(limit, count))
        for album in self {
            guard seen.insert(album.albumGroupKey).inserted else { continue }
            out.append(album)
            if out.count == limit { break }
        }
        return out
    }
}

/// The read side of the source-of-truth database — the *only* thing the UI
/// reads from. Every method is paginated or bounded so no query ever loads the
/// whole library, which is what keeps memory flat and scrolling smooth at
/// 100k+ tracks. All reads run on GRDB's WAL reader pool, off the main thread.
public struct LibraryRepository: Sendable {
    private let database: MusicDatabase

    public init(_ database: MusicDatabase) {
        self.database = database
    }

    // MARK: Servers & capabilities

    public func servers() async throws -> [ServerConnection] {
        try await database.read { db in
            try ServerRecord.fetchAll(db).compactMap(\.connection)
        }
    }

    public func capabilities(serverId: ServerID) async throws -> ServerCapabilities? {
        try await database.read { db in
            try CapabilitiesRecord
                .filter(Column("serverId") == serverId)
                .fetchOne(db)?
                .capabilities
        }
    }

    // MARK: Counts (for section headers / progress)

    public func artistCount(serverId: ServerID? = nil) async throws -> Int {
        try await count(table: ArtistRecord.self, serverId: serverId)
    }

    public func albumCount(serverId: ServerID? = nil) async throws -> Int {
        try await count(table: AlbumRecord.self, serverId: serverId)
    }

    public func trackCount(serverId: ServerID? = nil) async throws -> Int {
        try await count(table: TrackRecord.self, serverId: serverId)
    }

    private func count<R: TableRecord>(table: R.Type, serverId: ServerID?) async throws -> Int {
        try await database.read { db in
            var request = R.all()
            if let serverId { request = request.filter(Column("serverId") == serverId) }
            return try request.fetchCount(db)
        }
    }

    // MARK: Paginated browse (alphabetical)

    public func artistsPage(serverId: ServerID? = nil, offset: Int, limit: Int) async throws -> [ArtistRecord] {
        try await database.read { db in
            try ArtistRecord.fetchAll(db, sql: """
                SELECT * FROM artist
                \(Self.serverClause(serverId))
                ORDER BY sortName COLLATE NOCASE, name COLLATE NOCASE
                LIMIT ? OFFSET ?
                """, arguments: Self.serverArgs(serverId) + [limit, offset])
        }
    }

    public func albumsPage(serverId: ServerID? = nil, offset: Int, limit: Int) async throws -> [AlbumRecord] {
        try await database.read { db in
            try AlbumRecord.fetchAll(db, sql: """
                SELECT *, \(Self.albumRepresentative) FROM album
                \(Self.serverClause(serverId))
                GROUP BY serverId, albumGroupKey
                ORDER BY albumGroupKey
                LIMIT ? OFFSET ?
                """, arguments: Self.serverArgs(serverId) + [limit, offset])
        }
    }

    public func tracksPage(serverId: ServerID? = nil, offset: Int, limit: Int) async throws -> [TrackRecord] {
        try await database.read { db in
            try TrackRecord.fetchAll(db, sql: """
                SELECT * FROM track
                \(Self.serverClause(serverId))
                ORDER BY sortTitle COLLATE NOCASE, title COLLATE NOCASE
                LIMIT ? OFFSET ?
                """, arguments: Self.serverArgs(serverId) + [limit, offset])
        }
    }

    /// Every track as a domain model, alphabetical (matching ``tracksPage``), for
    /// a "Play/Shuffle all songs" action. The fetch AND the record→domain mapping
    /// run inside the database read (off the main thread), so tapping Play never
    /// hitches even on a very large library.
    public func allTracksForPlayback(serverId: ServerID? = nil) async throws -> [Track] {
        try await database.read { db in
            try TrackRecord.fetchAll(db, sql: """
                SELECT * FROM track
                \(Self.serverClause(serverId))
                ORDER BY sortTitle COLLATE NOCASE, title COLLATE NOCASE
                """, arguments: Self.serverArgs(serverId))
                .map { $0.toDomain() }
        }
    }

    /// Every track as a domain model, grouped by album (album → disc → track
    /// order), for a "Play/Shuffle all albums" action on the album grid. Fetch +
    /// mapping run off the main thread.
    public func allAlbumTracksForPlayback(serverId: ServerID? = nil) async throws -> [Track] {
        try await database.read { db in
            try TrackRecord.fetchAll(db, sql: """
                SELECT track.* FROM track
                JOIN album ON album.serverId = track.serverId AND album.remoteId = track.albumRemoteId
                \(serverId != nil ? "WHERE track.serverId = ?" : "")
                ORDER BY album.albumGroupKey,
                         COALESCE(track.discNumber, 1),
                         COALESCE(track.trackNumber, 999999),
                         track.sortTitle COLLATE NOCASE
                """, arguments: Self.serverArgs(serverId))
                .map { $0.toDomain() }
        }
    }

    // MARK: Detail

    /// Albums by an artist, newest first (then alphabetical). Fragments of the
    /// same album (same album-artist + title) are consolidated to one row.
    public func albums(forArtistRemoteId artistRemoteId: String, serverId: ServerID) async throws -> [AlbumRecord] {
        try await database.read { db in
            try AlbumRecord.fetchAll(db, sql: """
                SELECT *, \(Self.albumRepresentative) FROM album
                WHERE serverId = ? AND artistRemoteId = ?
                GROUP BY albumGroupKey
                ORDER BY year DESC, albumGroupKey
                """, arguments: [serverId, artistRemoteId])
        }
    }

    /// Tracks of an album in disc/track order.
    public func tracks(forAlbumRemoteId albumRemoteId: String, serverId: ServerID) async throws -> [TrackRecord] {
        try await database.read { db in
            try TrackRecord.fetchAll(db, sql: """
                SELECT * FROM track
                WHERE serverId = ? AND albumRemoteId = ?
                \(Self.albumTrackOrder)
                """, arguments: [serverId, albumRemoteId])
        }
    }

    /// Tracks of a consolidated album, spanning every fragment that shares the
    /// album's group key (so a server-split album shows all its songs). This is
    /// what the album detail and album download use.
    public func tracks(forAlbumGroupKey groupKey: String, serverId: ServerID) async throws -> [TrackRecord] {
        try await database.read { db in
            try TrackRecord.fetchAll(db, sql: """
                SELECT * FROM track
                WHERE serverId = ? AND albumRemoteId IN (
                    SELECT remoteId FROM album WHERE serverId = ? AND albumGroupKey = ?
                )
                \(Self.albumTrackOrder)
                """, arguments: [serverId, serverId, groupKey])
        }
    }

    /// Tracks of the consolidated album *containing* a given album remoteId —
    /// resolves the group key first. Used where only a remoteId is known.
    public func tracks(forAlbumGroupContaining albumRemoteId: String, serverId: ServerID) async throws -> [TrackRecord] {
        try await database.read { db in
            try TrackRecord.fetchAll(db, sql: """
                SELECT * FROM track
                WHERE serverId = ? AND albumRemoteId IN (
                    SELECT remoteId FROM album WHERE serverId = ? AND albumGroupKey = (
                        SELECT albumGroupKey FROM album WHERE serverId = ? AND remoteId = ?
                    )
                )
                \(Self.albumTrackOrder)
                """, arguments: [serverId, serverId, serverId, albumRemoteId])
        }
    }

    public func track(id: Int64) async throws -> TrackRecord? {
        try await database.read { db in try TrackRecord.fetchOne(db, key: id) }
    }

    public func track(serverId: ServerID, remoteId: String) async throws -> TrackRecord? {
        try await database.read { db in
            try TrackRecord
                .filter(Column("serverId") == serverId && Column("remoteId") == remoteId)
                .fetchOne(db)
        }
    }

    public func album(serverId: ServerID, remoteId: String) async throws -> AlbumRecord? {
        try await database.read { db in
            try AlbumRecord
                .filter(Column("serverId") == serverId && Column("remoteId") == remoteId)
                .fetchOne(db)
        }
    }

    public func artist(serverId: ServerID, remoteId: String) async throws -> ArtistRecord? {
        try await database.read { db in
            try ArtistRecord
                .filter(Column("serverId") == serverId && Column("remoteId") == remoteId)
                .fetchOne(db)
        }
    }

    /// Ordered tracks of a playlist, resolving membership to local track rows.
    public func tracks(forPlaylistRemoteId playlistRemoteId: String, serverId: ServerID) async throws -> [TrackRecord] {
        try await database.read { db in
            try TrackRecord.fetchAll(db, sql: """
                SELECT track.* FROM playlistItem
                JOIN playlist ON playlist.id = playlistItem.playlistId
                JOIN track ON track.serverId = playlist.serverId AND track.remoteId = playlistItem.trackRemoteId
                WHERE playlist.serverId = ? AND playlist.remoteId = ?
                ORDER BY playlistItem.position
                """, arguments: [serverId, playlistRemoteId])
        }
    }

    // MARK: Library home (recently added, playlists, genres)

    /// Most recently added albums (newest first) for the "Recently Added" shelf.
    /// Albums with no known add date sort last. Bounded by `limit`.
    public func recentlyAddedAlbums(serverId: ServerID, limit: Int = 20) async throws -> [AlbumRecord] {
        try await database.read { db in
            try AlbumRecord.fetchAll(db, sql: """
                SELECT *, \(Self.albumRepresentative) FROM album
                WHERE serverId = ?
                GROUP BY albumGroupKey
                ORDER BY addedAt DESC, albumGroupKey
                LIMIT ?
                """, arguments: [serverId, limit])
        }
    }

    /// All playlists for a server, alphabetical. Playlists are few, so this is
    /// not paginated.
    public func allPlaylists(serverId: ServerID) async throws -> [PlaylistRecord] {
        try await database.read { db in
            try PlaylistRecord.fetchAll(db, sql: """
                SELECT * FROM playlist
                WHERE serverId = ?
                ORDER BY title COLLATE NOCASE
                """, arguments: [serverId])
        }
    }

    /// Distinct genre names across the album catalog, alphabetical. Genres are
    /// stored as a JSON array per album; `json_each` fans them out so the DB
    /// does the de-duplication.
    public func genres(serverId: ServerID) async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT je.value AS genre
                FROM album JOIN json_each(album.genres) je
                WHERE album.serverId = ? AND je.value <> ''
                ORDER BY genre COLLATE NOCASE
                """, arguments: [serverId])
        }
    }

    /// Albums tagged with a genre, alphabetical. Album fragments consolidated.
    public func albums(forGenre genre: String, serverId: ServerID) async throws -> [AlbumRecord] {
        try await database.read { db in
            try AlbumRecord.fetchAll(db, sql: """
                SELECT album.*, \(Self.albumRepresentative("album.")) FROM album JOIN json_each(album.genres) je
                WHERE album.serverId = ? AND je.value = ?
                GROUP BY album.albumGroupKey
                ORDER BY album.albumGroupKey
                """, arguments: [serverId, genre])
        }
    }

    /// The most recently played tracks for the "Recently Played" shelf, newest
    /// first. Joins the append-only `play_event` log back to the catalog by
    /// *constructing* the durable track ref (serverId || ':' || remoteId) — the
    /// ref is opaque and never split. A track counts as played when it
    /// `started` or `completed` (a pure skip doesn't). Tracks no longer in the
    /// catalog are naturally omitted (inner join).
    public func recentlyPlayedTracks(serverId: ServerID, limit: Int = 20) async throws -> [TrackRecord] {
        try await database.read { db in
            try TrackRecord.fetchAll(db, sql: """
                SELECT track.* FROM track
                JOIN (
                    SELECT track_ref, MAX(created_at) AS lastPlayed
                    FROM play_event
                    WHERE kind IN ('started', 'completed')
                    GROUP BY track_ref
                ) pe ON (track.serverId || ':' || track.remoteId) = pe.track_ref
                WHERE track.serverId = ?
                ORDER BY pe.lastPlayed DESC
                LIMIT ?
                """, arguments: [serverId, limit])
        }
    }

    /// An artist's tracks ranked by local play count (most-played first), then a
    /// stable disc/track/title order. Membership is via the artist's albums, so
    /// it also works for album-artists that no track directly references. Used
    /// for the "Top Songs" section (limit 5) and its "See All" list (large limit).
    public func topTracks(forArtistRemoteId artistRemoteId: String, serverId: ServerID, limit: Int) async throws -> [TrackRecord] {
        try await database.read { db in
            try TrackRecord.fetchAll(db, sql: """
                SELECT track.* FROM track
                LEFT JOIN (
                    SELECT track_ref, COUNT(*) AS plays
                    FROM play_event
                    WHERE kind IN ('started', 'completed')
                    GROUP BY track_ref
                ) pe ON (track.serverId || ':' || track.remoteId) = pe.track_ref
                WHERE track.serverId = ? AND track.albumRemoteId IN (
                    SELECT remoteId FROM album WHERE serverId = ? AND artistRemoteId = ?
                )
                ORDER BY COALESCE(pe.plays, 0) DESC,
                         track.discNumber, track.trackNumber,
                         track.sortTitle COLLATE NOCASE, track.title COLLATE NOCASE
                LIMIT ?
                """, arguments: [serverId, serverId, artistRemoteId, limit])
        }
    }

    /// The "Liked Songs" list: Jellyfin favorites plus Plex tracks rated at or
    /// above ``LikePolicy/ratingThreshold`` — unified so one query serves both
    /// backends (a track carries only one of the two signals). Highest-rated
    /// first, then favorites, then a stable alphabetical tiebreak.
    public func likedTracks(serverId: ServerID? = nil, limit: Int = 1000) async throws -> [TrackRecord] {
        try await database.read { db in
            var sql = """
                SELECT * FROM track
                WHERE (isFavorite = 1 OR COALESCE(rating, 0) >= \(LikePolicy.ratingThreshold))
                """
            var args: [DatabaseValueConvertible?] = []
            if let serverId {
                sql += " AND serverId = ?"
                args.append(serverId)
            }
            sql += """
                 ORDER BY COALESCE(rating, 0) DESC, isFavorite DESC,
                          artistName COLLATE NOCASE, sortTitle COLLATE NOCASE, title COLLATE NOCASE
                 LIMIT ?
                """
            args.append(limit)
            return try TrackRecord.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    /// Count of liked tracks (Jellyfin favorites or Plex ≥ threshold rating) —
    /// for the Home "Liked Songs" tile, without materializing the rows.
    public func likedTracksCount(serverId: ServerID? = nil) async throws -> Int {
        try await database.read { db in
            var sql = "SELECT COUNT(*) FROM track WHERE (isFavorite = 1 OR COALESCE(rating, 0) >= \(LikePolicy.ratingThreshold))"
            var args: [DatabaseValueConvertible?] = []
            if let serverId {
                sql += " AND serverId = ?"
                args.append(serverId)
            }
            return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
        }
    }

    // MARK: Full-text search

    /// Search all three entity types. Returns quickly (each MATCH is bounded by
    /// `limitPerType`) — the basis for the sub-100ms search target.
    ///
    /// **As-you-type cost control.** A short prefix (1–2 chars) matches a huge
    /// fraction of a large FTS index, and `ORDER BY bm25(...)` must score the
    /// *entire* match set before `LIMIT` — measured ~40× slower at 100k tracks.
    /// So we only rank once the query is ≥3 chars (by which point the match set
    /// is small and bm25 is cheap); shorter queries use FTS's natural order and
    /// early-terminate at `LIMIT`, which stays a couple of milliseconds even on
    /// a huge library. Ranking is meaningless for 1–2 char queries anyway.
    public func search(_ query: String, serverId: ServerID? = nil, limitPerType: Int = 20) async throws -> SearchResults {
        guard let pattern = FTSQuery.pattern(for: query) else { return SearchResults() }
        let ranked = query.trimmingCharacters(in: .whitespaces).count >= 3
        return try await database.read { db in
            let serverFilter = serverId != nil
            func order(_ table: String) -> String { ranked ? "ORDER BY bm25(\(table))" : "" }
            let artists = try ArtistRecord.fetchAll(db, sql: """
                SELECT artist.* FROM artist
                JOIN artist_fts ON artist_fts.rowid = artist.id
                WHERE artist_fts MATCH ?\(serverFilter ? " AND artist.serverId = ?" : "")
                \(order("artist_fts")) LIMIT ?
                """, arguments: Self.matchArgs(pattern, serverId, limitPerType))
            let albums = try AlbumRecord.fetchAll(db, sql: """
                SELECT album.* FROM album
                JOIN album_fts ON album_fts.rowid = album.id
                WHERE album_fts MATCH ?\(serverFilter ? " AND album.serverId = ?" : "")
                \(order("album_fts")) LIMIT ?
                """, arguments: Self.matchArgs(pattern, serverId, limitPerType * 5))
                .dedupedByAlbumGroup(limit: limitPerType)
            let tracks = try TrackRecord.fetchAll(db, sql: """
                SELECT track.* FROM track
                JOIN track_fts ON track_fts.rowid = track.id
                WHERE track_fts MATCH ?\(serverFilter ? " AND track.serverId = ?" : "")
                \(order("track_fts")) LIMIT ?
                """, arguments: Self.matchArgs(pattern, serverId, limitPerType))
            return SearchResults(artists: artists, albums: albums, tracks: tracks)
        }
    }

    // MARK: Downloads (read)

    public func download(trackId: Int64) async throws -> DownloadRecord? {
        try await database.read { db in try DownloadRecord.fetchOne(db, key: trackId) }
    }

    /// All download records in the given states (default: everything).
    public func downloads(in states: [DownloadState] = DownloadState.allCases) async throws -> [DownloadRecord] {
        let raw = states.map(\.rawValue)
        return try await database.read { db in
            try DownloadRecord
                .filter(raw.contains(Column("state")))
                .fetchAll(db)
        }
    }

    /// Downloaded tracks joined with their catalog rows, for the Downloads UI.
    public func downloadedTracks() async throws -> [TrackRecord] {
        try await database.read { db in
            try TrackRecord.fetchAll(db, sql: """
                SELECT track.* FROM track
                JOIN download ON download.trackId = track.id
                WHERE download.state = ?
                ORDER BY track.artistName COLLATE NOCASE, track.albumTitle COLLATE NOCASE,
                         track.discNumber, track.trackNumber
                """, arguments: [DownloadState.downloaded.rawValue])
        }
    }

    public func storageUsage() async throws -> StorageUsage {
        try await database.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS c, COALESCE(SUM(sizeBytes), 0) AS b
                FROM download WHERE state = ?
                """, arguments: [DownloadState.downloaded.rawValue])
            return StorageUsage(
                downloadedTrackCount: row?["c"] ?? 0,
                totalBytes: row?["b"] ?? 0
            )
        }
    }

    // MARK: - Helpers

    /// The single-`MAX()` expression whose winning row supplies the consolidated
    /// album's representative columns (artwork, id, year…). Priority: a fragment
    /// *with* artwork first, then the one with the most tracks — so the album's
    /// cover and identity stay stable across syncs. `column` prefixes the two
    /// referenced columns for queries that join (e.g. `"album."`).
    ///
    /// NOTE: this pulls *every* selected column from that one representative row
    /// (SQLite's bare-column + single-min/max rule), so on a consolidated album
    /// `trackCount` is the representative fragment's, NOT the sum across the
    /// group. No UI reads `album.trackCount` today (detail derives count from the
    /// fetched tracks), but a future "N songs" badge must use `SUM(trackCount)`
    /// via a subquery — you cannot add a second aggregate here without making the
    /// representative row arbitrary.
    private static func albumRepresentative(_ column: String = "") -> String {
        "MAX((CASE WHEN \(column)artworkKey IS NOT NULL AND \(column)artworkKey <> '' THEN 1 ELSE 0 END) * 1000000 + COALESCE(\(column)trackCount, 0))"
    }
    private static let albumRepresentative = albumRepresentative()

    /// Track ordering within a (possibly multi-fragment) album: disc then track,
    /// tolerating missing numbers (null disc floats to disc 1, null track sorts
    /// last), then the source fragment id so a fragment's tracks stay together
    /// when numbering collides, then title. Best-effort for messy metadata.
    private static let albumTrackOrder =
        "ORDER BY COALESCE(discNumber, 1), COALESCE(trackNumber, 999999), albumRemoteId, sortTitle COLLATE NOCASE"

    private static func serverClause(_ serverId: ServerID?) -> String {
        serverId != nil ? "WHERE serverId = ?" : ""
    }

    private static func serverArgs(_ serverId: ServerID?) -> StatementArguments {
        serverId != nil ? [serverId] : []
    }

    private static func matchArgs(_ pattern: String, _ serverId: ServerID?, _ limit: Int) -> StatementArguments {
        if let serverId {
            return [pattern, serverId, limit]
        }
        return [pattern, limit]
    }
}
