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

    public func upsertAlbums(_ albums: [Album], serverId: ServerID) async throws {
        guard !albums.isEmpty else { return }
        try await database.write { db in
            let stmt = try db.makeStatement(sql: Self.albumUpsertSQL)
            for album in albums {
                try stmt.execute(arguments: [
                    serverId, album.id, album.title, album.sortTitle ?? album.title,
                    album.artistName, album.artistID, album.year,
                    album.artwork?.key, album.trackCount, album.isFavorite,
                    album.addedAt?.timeIntervalSince1970, Self.jsonText(album.genres),
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
        "artworkKey", "trackCount", "isFavorite", "addedAt", "genres",
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
