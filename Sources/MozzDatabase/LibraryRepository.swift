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

    /// Remote ids of tracks whose audio format hasn't been backfilled yet (the
    /// light catalog sync omits `MediaSources` for speed). Drives the background
    /// media backfill; returns at most `limit` ids.
    public func trackRemoteIdsMissingFormat(serverId: ServerID, limit: Int) async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(db, sql: """
                SELECT remoteId FROM track
                WHERE serverId = ? AND container IS NULL
                LIMIT ?
                """, arguments: [serverId, limit])
        }
    }

    private func count<R: TableRecord>(table: R.Type, serverId: ServerID?) async throws -> Int {
        try await database.read { db in
            var request = R.all()
            if let serverId { request = request.filter(Column("serverId") == serverId) }
            return try request.fetchCount(db)
        }
    }

    // MARK: Paginated browse (alphabetical)
    //
    // Two shapes, deliberately. `…Page(offset:limit:)` is what the iOS views and
    // CarPlay use; `…Page(after:limit:)` is the seek/keyset form, and is what a
    // client scrolling a large library should use.
    //
    // OFFSET has two problems that only show up at real library sizes, and both
    // were measured on a 100,000-track catalog rather than assumed.
    //
    // It is O(offset). SQLite must walk and discard every skipped index entry, so
    // a page costs 10 ms at the top of the list and 197 ms near the bottom — a
    // nineteen-fold slowdown precisely when someone is scrolling fast.
    //
    // Worse, it is wrong whenever the table changes underneath it, and Mozz syncs
    // in the background *while you browse*, which is exactly that. Inserting 40
    // rows during a full paged walk of 100,000 made 40 tracks appear twice and 40
    // others never appear at all. Nothing warns you; the list simply lies.
    //
    // A cursor fixes both. It names the last row seen rather than counting rows
    // skipped, so a page is an index seek regardless of depth, and rows arriving
    // elsewhere in the order cannot shift it.

    /// An opaque position in a paged listing. Clients echo it back; only this
    /// file knows what is inside, which is what allows the sort keys to change
    /// without a client change.
    public struct PageCursor: Sendable, Hashable {
        let keys: [String]
        let id: Int64

        public init(keys: [String], id: Int64) {
            self.keys = keys
            self.id = id
        }

        /// Round-trips through a string so the FFI can carry it.
        ///
        /// Each part is base64-encoded *before* being joined, rather than being
        /// joined raw. That looks redundant and is not: a key may contain any
        /// character, including the separator. `albumGroupKey` is itself a
        /// composite that `AlbumGrouping` joins with U+001F — the same
        /// character this once used — so an album cursor split into two keys on
        /// the way back, the seek clause was built for one key while the
        /// arguments were bound for two, and SQLite rejected the statement.
        /// Paging albums over the FFI failed on the second page.
        ///
        /// Base64's alphabet cannot contain the separator, so the split is
        /// unambiguous no matter what the keys hold.
        public var token: String {
            let parts = (keys + [String(id)])
                .map { Data($0.utf8).base64EncodedString() }
                .joined(separator: "\u{1F}")
            return Data(parts.utf8).base64EncodedString()
        }

        public init?(token: String) {
            guard let outer = Data(base64Encoded: token),
                  let text = String(data: outer, encoding: .utf8) else { return nil }
            var parts: [String] = []
            for encoded in text.components(separatedBy: "\u{1F}") {
                guard let data = Data(base64Encoded: encoded),
                      let part = String(data: data, encoding: .utf8) else { return nil }
                parts.append(part)
            }
            guard parts.count >= 2, let id = Int64(parts.removeLast()) else { return nil }
            self.keys = parts
            self.id = id
        }
    }

    /// `(k1, k2, …, id) > (v1, v2, …, id)` written out longhand, preceded by a
    /// redundant bound on the first key.
    ///
    /// SQLite supports row-value comparison, but not with a per-column COLLATE,
    /// and these sorts are all NOCASE — so the comparison has to be expanded into
    /// alternatives.
    ///
    /// The leading `k1 >= ?` looks redundant and is not. A bare chain of ORs
    /// gives SQLite no range constraint it can seek with, so the plan degrades to
    /// `SEARCH track USING INDEX idx_track_sort (serverId=?)` — it enters the
    /// index at the start of the server's rows and filters forward, which at the
    /// bottom of a 100,000-track library means walking almost the whole index.
    /// Measured: 7.82 ms without the bound, 0.47 ms with it, for the same page.
    /// With it the plan becomes `(serverId=? AND sortTitle>?)` and the seek is
    /// what it should have been all along.
    private static func seekClause(_ columns: [String], _ cursor: PageCursor) -> String {
        var alternatives: [String] = []
        for (index, column) in columns.enumerated() {
            var equalities = (0..<index).map { "\(columns[$0]) = ? COLLATE NOCASE" }
            equalities.append("\(column) > ? COLLATE NOCASE")
            alternatives.append("(" + equalities.joined(separator: " AND ") + ")")
        }
        // Every key equal — fall through to the unique tiebreaker.
        let allEqual = columns.map { "\($0) = ? COLLATE NOCASE" }.joined(separator: " AND ")
        alternatives.append("(\(allEqual) AND id > ?)")

        let seekable = "\(columns[0]) >= ? COLLATE NOCASE"
        return "\(seekable) AND (" + alternatives.joined(separator: " OR ") + ")"
    }

    /// Server filter, then the seek keys, then the limit — the order every
    /// keyset query below binds them in.
    private static func pagedArgs(
        _ serverId: ServerID?, _ cursor: PageCursor?, _ limit: Int
    ) -> StatementArguments {
        var args = serverArgs(serverId)
        if let cursor { args += seekArgs(cursor) }
        args += [limit]
        return args
    }

    /// Arguments for ``seekClause``, in the order the clause consumes them.
    private static func seekArgs(_ cursor: PageCursor) -> StatementArguments {
        // The leading seekable bound consumes the first key before the
        // alternatives do; see `seekClause`.
        var values: [any DatabaseValueConvertible] = [cursor.keys[0]]
        for index in 0..<cursor.keys.count {
            values.append(contentsOf: cursor.keys[0...index].map { $0 as any DatabaseValueConvertible })
        }
        values.append(contentsOf: cursor.keys.map { $0 as any DatabaseValueConvertible })
        values.append(cursor.id)
        return StatementArguments(values)
    }

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

    /// Correlated existence check that keeps only albums with at least one synced
    /// track. Post-full-sync this is always true (a no-op), but during the initial
    /// quick-start / mid-sync it hides "empty album shells" whose tracks haven't
    /// arrived yet. Cheap via the (serverId, albumRemoteId) track index.
    private static let albumHasTracks = """
        EXISTS (SELECT 1 FROM track t WHERE t.serverId = album.serverId AND t.albumRemoteId = album.remoteId)
        """

    public func albumsPage(serverId: ServerID? = nil, offset: Int, limit: Int) async throws -> [AlbumRecord] {
        try await database.read { db in
            try AlbumRecord.fetchAll(db, sql: """
                SELECT *, \(Self.albumRepresentative) FROM album
                \(Self.serverClause(serverId))
                \(serverId == nil ? "WHERE" : "AND") \(Self.albumHasTracks)
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

    // MARK: Keyset paging

    /// One page of a listing, plus where to resume.
    public struct Page<Row: Sendable>: Sendable {
        public var rows: [Row]
        /// `nil` when this was the last page. A client that stops on nil cannot
        /// loop forever, which an offset-based caller has to reason about itself.
        public var next: PageCursor?

        public init(rows: [Row], next: PageCursor? = nil) {
            self.rows = rows
            self.next = next
        }

        /// An already-exhausted page, for a view's placeholder data source
        /// before the real repository is injected.
        public static var empty: Page<Row> { Page(rows: [], next: nil) }
    }

    public func artistsPage(
        serverId: ServerID? = nil, after cursor: PageCursor?, limit: Int
    ) async throws -> Page<ArtistRecord> {
        let seek = cursor.map { " AND \(Self.seekClause(["sortName", "name"], $0))" } ?? ""
        let rows = try await database.read { db in
            try ArtistRecord.fetchAll(db, sql: """
                SELECT * FROM artist
                \(Self.serverClause(serverId, forceWhere: true))\(seek)
                ORDER BY sortName COLLATE NOCASE, name COLLATE NOCASE, id
                LIMIT ?
                """, arguments: Self.pagedArgs(serverId, cursor, limit))
        }
        return Page(rows: rows, next: rows.count < limit ? nil : rows.last.map {
            PageCursor(keys: [$0.sortName ?? $0.name, $0.name], id: $0.id ?? 0)
        })
    }

    public func tracksPage(
        serverId: ServerID? = nil, after cursor: PageCursor?, limit: Int
    ) async throws -> Page<TrackRecord> {
        let seek = cursor.map { " AND \(Self.seekClause(["sortTitle", "title"], $0))" } ?? ""
        let rows = try await database.read { db in
            try TrackRecord.fetchAll(db, sql: """
                SELECT * FROM track
                \(Self.serverClause(serverId, forceWhere: true))\(seek)
                ORDER BY sortTitle COLLATE NOCASE, title COLLATE NOCASE, id
                LIMIT ?
                """, arguments: Self.pagedArgs(serverId, cursor, limit))
        }
        return Page(rows: rows, next: rows.count < limit ? nil : rows.last.map {
            PageCursor(keys: [$0.sortTitle ?? $0.title, $0.title], id: $0.id ?? 0)
        })
    }

    /// Albums group by `albumGroupKey`, so the cursor rides that single key. The
    /// grouping already collapses duplicates, and the key is unique per group,
    /// so `id` is only a formality here — but it costs nothing and keeps every
    /// listing's cursor the same shape.
    public func albumsPage(
        serverId: ServerID? = nil, after cursor: PageCursor?, limit: Int
    ) async throws -> Page<AlbumRecord> {
        let seek = cursor.map { " AND \(Self.seekClause(["albumGroupKey"], $0))" } ?? ""
        let rows = try await database.read { db in
            try AlbumRecord.fetchAll(db, sql: """
                SELECT *, \(Self.albumRepresentative) FROM album
                \(Self.serverClause(serverId, forceWhere: true))
                AND \(Self.albumHasTracks)\(seek)
                GROUP BY serverId, albumGroupKey
                ORDER BY albumGroupKey, id
                LIMIT ?
                """, arguments: Self.pagedArgs(serverId, cursor, limit))
        }
        return Page(rows: rows, next: rows.count < limit ? nil : rows.last.map {
            PageCursor(keys: [$0.albumGroupKey], id: $0.id ?? 0)
        })
    }

    /// Domain tracks for a set of remote ids on a server, returned in the SAME
    /// order as `remoteIds` (used to realize a computed order — e.g. a radio
    /// batch — into playable tracks). Ids not found are skipped. Fetch + mapping
    /// run off the main thread.
    public func tracksForPlayback(remoteIds: [String], serverId: ServerID) async throws -> [Track] {
        guard !remoteIds.isEmpty else { return [] }
        return try await database.read { db in
            let placeholders = Array(repeating: "?", count: remoteIds.count).joined(separator: ", ")
            var args: [DatabaseValueConvertible?] = [serverId]
            args.append(contentsOf: remoteIds)
            let byId = try TrackRecord.fetchAll(db, sql: """
                SELECT * FROM track WHERE serverId = ? AND remoteId IN (\(placeholders))
                """, arguments: StatementArguments(args))
                .reduce(into: [String: Track]()) { $0[$1.remoteId] = $1.toDomain() }
            return remoteIds.compactMap { byId[$0] }
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

    /// Albums credited to another album-artist that nevertheless contain tracks
    /// by this artist. Cursor-paged for the desktop/iOS "Appears On" shelf.
    public func appearsOnAlbums(
        forArtistRemoteId artistRemoteId: String,
        serverId: ServerID,
        after cursor: PageCursor?,
        limit: Int
    ) async throws -> Page<AlbumRecord> {
        let seek = cursor.map { " AND \(Self.seekClause(["albumGroupKey"], $0))" } ?? ""
        var mutableArgs: StatementArguments = [serverId, artistRemoteId, artistRemoteId]
        if let cursor { mutableArgs += Self.seekArgs(cursor) }
        mutableArgs += [limit]
        let args = mutableArgs

        let rows = try await database.read { db in
            try AlbumRecord.fetchAll(db, sql: """
                SELECT album.*, \(Self.albumRepresentative("album.")) FROM album
                WHERE album.serverId = ?
                  AND album.artistRemoteId IS NOT NULL
                  AND album.artistRemoteId <> ?
                  AND \(Self.albumHasTracks)
                  AND EXISTS (
                      SELECT 1 FROM track
                      WHERE track.serverId = album.serverId
                        AND track.albumRemoteId = album.remoteId
                        AND track.artistRemoteId = ?
                  )\(seek)
                GROUP BY album.albumGroupKey
                ORDER BY album.albumGroupKey, album.id
                LIMIT ?
                """, arguments: args)
        }
        return Page(rows: rows, next: rows.count < limit ? nil : rows.last.map {
            PageCursor(keys: [$0.albumGroupKey], id: $0.id ?? 0)
        })
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
                WHERE serverId = ? AND \(Self.albumHasTracks)
                GROUP BY albumGroupKey
                ORDER BY addedAt DESC, albumGroupKey
                LIMIT ?
                """, arguments: [serverId, limit])
        }
    }

    /// The most recently-added tracks, newest first. Used for the Home "Recently
    /// Added" shelf — songs (immediately playable) rather than album shells,
    /// which also means it populates from the first-run quick-start's track slice.
    public func recentlyAddedTracks(serverId: ServerID, limit: Int = 20) async throws -> [TrackRecord] {
        try await database.read { db in
            try TrackRecord.fetchAll(db, sql: """
                SELECT * FROM track
                WHERE serverId = ? AND addedAt IS NOT NULL
                ORDER BY addedAt DESC
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
            // CROSS JOIN, with the FTS table first, is a deliberate optimizer
            // instruction rather than a stylistic choice: SQLite documents that
            // CROSS JOIN suppresses table reordering, which pins the FTS table
            // as the outer loop.
            //
            // Written the natural way round, the planner is free to drive from
            // the base table instead — scanning all 100k tracks and probing the
            // index once per row. Apple's SQLite has STAT4 statistics and picks
            // correctly; a stock build has no statistics for a virtual table and
            // picked the catastrophic plan, turning a 16 ms search into 54
            // seconds on Windows. Pinning the order makes the query fast on any
            // SQLite, which is worth more than relying on a good planner.
            let artists = try ArtistRecord.fetchAll(db, sql: """
                SELECT artist.* FROM artist_fts
                CROSS JOIN artist ON artist.id = artist_fts.rowid
                WHERE artist_fts MATCH ?\(serverFilter ? " AND artist.serverId = ?" : "")
                \(order("artist_fts")) LIMIT ?
                """, arguments: Self.matchArgs(pattern, serverId, limitPerType))
            let albums = try AlbumRecord.fetchAll(db, sql: """
                SELECT album.* FROM album_fts
                CROSS JOIN album ON album.id = album_fts.rowid
                WHERE album_fts MATCH ?\(serverFilter ? " AND album.serverId = ?" : "")
                \(order("album_fts")) LIMIT ?
                """, arguments: Self.matchArgs(pattern, serverId, limitPerType * 5))
                .dedupedByAlbumGroup(limit: limitPerType)
            let tracks = try TrackRecord.fetchAll(db, sql: """
                SELECT track.* FROM track_fts
                CROSS JOIN track ON track.id = track_fts.rowid
                WHERE track_fts MATCH ?\(serverFilter ? " AND track.serverId = ?" : "")
                \(order("track_fts")) LIMIT ?
                """, arguments: Self.matchArgs(pattern, serverId, limitPerType))
            return SearchResults(artists: artists, albums: albums, tracks: tracks)
        }
    }

    /// The query plan SQLite chooses for the track search, as text.
    ///
    /// Exposed for the cross-platform spike: a search that is fast on one
    /// platform and pathological on another is almost always a different join
    /// order, and the plan says so immediately where a stopwatch only says
    /// "slow". A healthy plan scans `track_fts` and looks `track` up by rowid;
    /// an unhealthy one scans `track`.
    public func searchQueryPlan(_ query: String, serverId: ServerID? = nil) async throws -> [String] {
        guard let pattern = FTSQuery.pattern(for: query) else { return [] }
        let serverFilter = serverId != nil
        return try await database.read { db in
            // EXPLAIN QUERY PLAN returns (id, parent, notused, detail); the
            // human-readable part is `detail`, and fetching the first column
            // silently yields row ids instead.
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN
                SELECT track.* FROM track_fts
                CROSS JOIN track ON track.id = track_fts.rowid
                WHERE track_fts MATCH ?\(serverFilter ? " AND track.serverId = ?" : "")
                ORDER BY bm25(track_fts) LIMIT ?
                """, arguments: Self.matchArgs(pattern, serverId, 20))
                .map { row in (row["detail"] as String?) ?? "" }
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

    /// As above, but always emits a WHERE so callers can append `AND …` without
    /// knowing whether a server filter was present.
    private static func serverClause(_ serverId: ServerID?, forceWhere: Bool) -> String {
        guard forceWhere else { return serverClause(serverId) }
        return serverId != nil ? "WHERE serverId = ?" : "WHERE 1"
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
