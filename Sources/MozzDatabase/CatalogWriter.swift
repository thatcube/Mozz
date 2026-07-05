import Foundation
import GRDB
import MozzCore

/// The write side of the source-of-truth database: maps provider domain models
/// into catalog rows. Providers never touch the database directly — the sync
/// engine hands batches to this writer.
///
/// Writes are UPSERTs keyed on the stable (`serverId`, `remoteId`) identity, so
/// re-syncing a library updates rows *in place*, preserving each row's internal
/// `id`. That id-stability is what keeps a completed download attached to its
/// track across a catalog refresh.
public struct CatalogWriter: Sendable {
    private let database: MusicDatabase

    public init(_ database: MusicDatabase) {
        self.database = database
    }

    // MARK: Server + capabilities

    public func saveServer(_ connection: ServerConnection) async throws {
        try await database.write { db in
            try ServerRecord(connection).save(db)
        }
    }

    public func saveCapabilities(_ capabilities: ServerCapabilities, serverId: ServerID) async throws {
        try await database.write { db in
            try CapabilitiesRecord(serverId: serverId, capabilities: capabilities).save(db)
        }
    }

    // MARK: Catalog batches

    public func upsertArtists(_ artists: [Artist], serverId: ServerID) async throws {
        guard !artists.isEmpty else { return }
        try await database.write { db in
            let stmt = try db.makeStatement(sql: Self.artistUpsertSQL)
            for artist in artists {
                try stmt.execute(arguments: [
                    serverId, artist.id, artist.name, artist.sortName ?? artist.name,
                    artist.artwork?.key, artist.albumCount, artist.isFavorite,
                    Self.jsonText(artist.genres),
                ])
            }
        }
    }

    /// Create artist rows for album-artists an album references but the server's
    /// artist listing omitted (see `AlbumArtistSynthesis`). Derived from
    /// already-synced albums, so no network. Returns the synthesized remote ids
    /// (for the sync engine to keep them out of the artist prune).
    @discardableResult
    public func synthesizeMissingAlbumArtists(serverId: ServerID) async throws -> [String] {
        try await database.write { db in try AlbumArtistSynthesis.run(db, serverId: serverId) }
    }

    public func upsertAlbums(_ albums: [Album], serverId: ServerID) async throws {
        guard !albums.isEmpty else { return }
        try await database.write { db in
            let stmt = try db.makeStatement(sql: Self.albumUpsertSQL)
            for album in albums {
                let groupKey = AlbumGrouping.key(
                    artistRemoteId: album.artistID, artistName: album.artistName,
                    sortTitle: album.sortTitle ?? album.title)
                try stmt.execute(arguments: [
                    serverId, album.id, album.title, album.sortTitle ?? album.title,
                    album.artistName, album.artistID, album.year,
                    album.artwork?.key, album.trackCount, album.isFavorite,
                    album.addedAt?.timeIntervalSince1970, Self.jsonText(album.genres), groupKey,
                ])
            }
        }
    }

    public func upsertTracks(_ tracks: [Track], serverId: ServerID) async throws {
        guard !tracks.isEmpty else { return }
        try await database.write { db in
            let stmt = try db.makeStatement(sql: Self.trackUpsertSQL)
            for track in tracks {
                try stmt.execute(arguments: [
                    serverId, track.id, track.title, track.sortTitle ?? track.title,
                    track.albumTitle, track.albumID, track.artistName, track.artistID,
                    track.albumArtistName, track.trackNumber, track.discNumber, track.duration,
                    track.format.container, track.format.codec, track.format.bitrateKbps,
                    track.format.sampleRateHz, track.format.channels, track.format.bitDepth,
                    track.fileSizeBytes, track.mediaKey, track.artwork?.key,
                    track.isFavorite, track.normalizationGainDB,
                    track.addedAt?.timeIntervalSince1970, Self.jsonText(track.genres),
                ])
            }
        }
    }

    public func upsertPlaylists(_ playlists: [Playlist], serverId: ServerID) async throws {
        guard !playlists.isEmpty else { return }
        try await database.write { db in
            let stmt = try db.makeStatement(sql: Self.playlistUpsertSQL)
            for playlist in playlists {
                try stmt.execute(arguments: [
                    serverId, playlist.id, playlist.title, playlist.trackCount,
                    playlist.durationSeconds, playlist.artwork?.key, playlist.isSmart,
                ])
            }
        }
    }

    /// Replace a playlist's ordered items. Removes old membership then inserts
    /// the given tracks in order, all in one transaction.
    public func replacePlaylistItems(playlistRemoteId: String, trackRemoteIds: [String], serverId: ServerID) async throws {
        try await database.write { db in
            guard let playlistPK = try Int64.fetchOne(db, sql: """
                SELECT id FROM playlist WHERE serverId = ? AND remoteId = ?
                """, arguments: [serverId, playlistRemoteId]) else {
                return
            }
            try db.execute(sql: "DELETE FROM playlistItem WHERE playlistId = ?", arguments: [playlistPK])
            let stmt = try db.makeStatement(sql: """
                INSERT INTO playlistItem (playlistId, trackRemoteId, position) VALUES (?, ?, ?)
                """)
            for (index, trackRemoteId) in trackRemoteIds.enumerated() {
                try stmt.execute(arguments: [playlistPK, trackRemoteId, index])
            }
        }
    }

    // MARK: Pruning (delete rows a full sync no longer saw)

    /// Delete rows for `serverId` whose `remoteId` is not in `keeping`. UPSERT
    /// updates and inserts but never removes, so a full sync calls this to drop
    /// items deleted on the server. The kept ids are staged into a temp table so
    /// this stays one bounded DELETE rather than a giant `NOT IN (?, ?, …)`.
    /// Returns the number of rows deleted.
    public func pruneArtists(serverId: ServerID, keeping ids: [String]) async throws -> Int {
        // INVARIANT: every artist a *surviving* album still references must be
        // kept. Synthesized album-artists (see AlbumArtistSynthesis) are never
        // returned by the server's /Artists listing, so they're absent from the
        // caller's keep-set; without this guard they'd be pruned on the next
        // complete sync, re-orphaning their albums every other sync. Artists are
        // pruned AFTER albums, so `album` here already reflects the surviving
        // set — an artist whose last album was itself pruned is (correctly) not
        // protected and gets cleaned up.
        try await prune(
            table: "artist", serverId: serverId, keeping: ids,
            alsoKeeping: """
            SELECT DISTINCT artistRemoteId FROM album
            WHERE serverId = ? AND artistRemoteId IS NOT NULL AND artistRemoteId <> ''
            """
        )
    }

    /// Total artist rows for a server (server-listed + synthesized), for the
    /// post-sync summary. Read as a live count so it stays consistent across
    /// syncs even though synthesized artists aren't in the sync's "seen" set.
    public func artistCount(serverId: ServerID) async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artist WHERE serverId = ?",
                             arguments: [serverId]) ?? 0
        }
    }

    public func pruneAlbums(serverId: ServerID, keeping ids: [String]) async throws -> Int {
        try await prune(table: "album", serverId: serverId, keeping: ids)
    }

    public func pruneTracks(serverId: ServerID, keeping ids: [String]) async throws -> Int {
        try await prune(table: "track", serverId: serverId, keeping: ids)
    }

    public func prunePlaylists(serverId: ServerID, keeping ids: [String]) async throws -> Int {
        try await prune(table: "playlist", serverId: serverId, keeping: ids)
    }

    private func prune(table: String, serverId: ServerID, keeping ids: [String],
                       alsoKeeping subquery: String? = nil) async throws -> Int {
        try await database.write { db in
            try db.execute(sql: "CREATE TEMP TABLE IF NOT EXISTS _sync_keep (remoteId TEXT PRIMARY KEY)")
            try db.execute(sql: "DELETE FROM _sync_keep")
            let insert = try db.makeStatement(sql: "INSERT OR IGNORE INTO _sync_keep (remoteId) VALUES (?)")
            for id in ids {
                try insert.execute(arguments: [id])
            }
            // Fold in any extra ids to protect (e.g. artists a surviving album
            // still references). Bound with serverId; runs after sibling prunes.
            if let subquery {
                try db.execute(sql: "INSERT OR IGNORE INTO _sync_keep (remoteId) \(subquery)",
                               arguments: [serverId])
            }
            try db.execute(
                sql: "DELETE FROM \(table) WHERE serverId = ? AND remoteId NOT IN (SELECT remoteId FROM _sync_keep)",
                arguments: [serverId]
            )
            let deleted = db.changesCount
            try db.execute(sql: "DELETE FROM _sync_keep")
            return deleted
        }
    }

    // MARK: - SQL builders

    /// Build an `INSERT … ON CONFLICT(serverId, remoteId) DO UPDATE` statement.
    /// The conflict columns are never overwritten (they *are* the identity),
    /// and `id` is omitted entirely so autoincrement + id-stability both hold.
    private static func upsertSQL(table: String, columns: [String]) -> String {
        let insertCols = (["serverId", "remoteId"] + columns).joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: columns.count + 2).joined(separator: ", ")
        let updates = columns.map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
        return """
        INSERT INTO \(table) (\(insertCols)) VALUES (\(placeholders))
        ON CONFLICT(serverId, remoteId) DO UPDATE SET \(updates)
        """
    }

    private static let artistUpsertSQL = upsertSQL(table: "artist", columns: [
        "name", "sortName", "artworkKey", "albumCount", "isFavorite", "genres",
    ])
    private static let albumUpsertSQL = upsertSQL(table: "album", columns: [
        "title", "sortTitle", "artistName", "artistRemoteId", "year",
        "artworkKey", "trackCount", "isFavorite", "addedAt", "genres", "albumGroupKey",
    ])
    private static let trackUpsertSQL = upsertSQL(table: "track", columns: [
        "title", "sortTitle", "albumTitle", "albumRemoteId", "artistName",
        "artistRemoteId", "albumArtistName", "trackNumber", "discNumber", "duration",
        "container", "codec", "bitrateKbps", "sampleRateHz", "channels", "bitDepth",
        "fileSizeBytes", "mediaKey", "artworkKey", "isFavorite", "normalizationGainDB",
        "addedAt", "genres",
    ])
    private static let playlistUpsertSQL = upsertSQL(table: "playlist", columns: [
        "title", "trackCount", "durationSeconds", "artworkKey", "isSmart",
    ])

    private static let genresEncoder = JSONEncoder()

    private static func jsonText(_ values: [String]) -> String {
        guard !values.isEmpty, let data = try? genresEncoder.encode(values) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
