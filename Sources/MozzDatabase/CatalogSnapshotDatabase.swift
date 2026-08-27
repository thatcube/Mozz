import Foundation
import GRDB
import MozzCore

public enum CatalogSnapshotDatabaseError: Error, Equatable {
    case invalidPlaylistPosition(Int)
}

/// Streams portable catalog snapshot chunks into and out of the local database.
///
/// Internal SQLite ids never leave the device. Every page is ordered by the
/// provider's stable remote id, so export is deterministic and keyset-paged.
public struct CatalogSnapshotDatabase: Sendable {
    private let database: MusicDatabase

    public init(_ database: MusicDatabase) {
        self.database = database
    }

    /// Adopt the requested identity, clearing a catalog owned by another
    /// account/library selection in the same transaction. A pre-v20 catalog has
    /// no marker and is adopted in place for migration compatibility.
    @discardableResult
    public func prepare(scope: CatalogSnapshotScope) async throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try String(
            decoding: encoder.encode(scope),
            as: UTF8.self)
        return try await database.write { db in
            let existingText = try String.fetchOne(
                db,
                sql: "SELECT scope FROM catalogScope WHERE serverId = ?",
                arguments: [scope.serverID])
            let existingScope: CatalogSnapshotScope?
            if let existingText {
                existingScope = try JSONDecoder().decode(
                    CatalogSnapshotScope.self,
                    from: Data(existingText.utf8))
            } else {
                existingScope = nil
            }
            guard existingScope != scope else { return false }
            if existingText != nil {
                try Self.clearCatalog(serverID: scope.serverID, in: db)
            }
            try db.execute(
                sql: """
                    INSERT INTO catalogScope (serverId, scope) VALUES (?, ?)
                    ON CONFLICT(serverId) DO UPDATE SET scope = excluded.scope
                    """,
                arguments: [scope.serverID, encoded])
            return existingText != nil
        }
    }

    public func localScope(
        serverID: String
    ) async throws -> CatalogSnapshotScope? {
        try await database.read { db in
            guard let text = try String.fetchOne(
                db,
                sql: "SELECT scope FROM catalogScope WHERE serverId = ?",
                arguments: [serverID]),
                  let data = text.data(using: .utf8) else {
                return nil
            }
            return try JSONDecoder().decode(
                CatalogSnapshotScope.self,
                from: data)
        }
    }

    public func artistsPage(
        serverID: String,
        after remoteID: String?,
        limit: Int
    ) async throws -> [Artist] {
        try await database.read { db in
            try ArtistRecord.fetchAll(
                db,
                sql: Self.pageSQL(table: "artist", after: remoteID),
                arguments: Self.pageArguments(serverID, after: remoteID, limit: limit)
            ).map { $0.toDomain() }
        }
    }

    public func albumsPage(
        serverID: String,
        after remoteID: String?,
        limit: Int
    ) async throws -> [Album] {
        try await database.read { db in
            try AlbumRecord.fetchAll(
                db,
                sql: Self.pageSQL(table: "album", after: remoteID),
                arguments: Self.pageArguments(serverID, after: remoteID, limit: limit)
            ).map { $0.toDomain() }
        }
    }

    public func tracksPage(
        serverID: String,
        after remoteID: String?,
        limit: Int
    ) async throws -> [Track] {
        try await database.read { db in
            try TrackRecord.fetchAll(
                db,
                sql: Self.pageSQL(table: "track", after: remoteID),
                arguments: Self.pageArguments(serverID, after: remoteID, limit: limit)
            ).map { $0.toDomain() }
        }
    }

    public func playlistsPage(
        serverID: String,
        after remoteID: String?,
        limit: Int
    ) async throws -> [Playlist] {
        try await database.read { db in
            try PlaylistRecord.fetchAll(
                db,
                sql: Self.pageSQL(table: "playlist", after: remoteID),
                arguments: Self.pageArguments(
                    serverID,
                    after: remoteID,
                    limit: limit)
            ).map { $0.toDomain() }
        }
    }

    public func playlistItemsPage(
        serverID: String,
        playlistRemoteID: String,
        offset: Int,
        limit: Int
    ) async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT playlistItem.trackRemoteId
                    FROM playlistItem
                    JOIN playlist ON playlist.id = playlistItem.playlistId
                    WHERE playlist.serverId = ?
                      AND playlist.remoteId = ?
                      AND playlistItem.position >= ?
                    ORDER BY playlistItem.position
                    LIMIT ?
                    """,
                arguments: [
                    serverID,
                    playlistRemoteID,
                    max(0, offset),
                    min(max(limit, 1), 1_000),
                ])
        }
    }

    public func importChunk(
        _ chunk: CatalogSnapshotChunk,
        serverID: String
    ) async throws {
        let writer = CatalogWriter(database)
        switch chunk.kind {
        case .artists:
            try await writer.upsertArtists(chunk.artists, serverId: serverID)
        case .albums:
            try await writer.upsertAlbums(chunk.albums, serverId: serverID)
        case .tracks:
            try await writer.upsertTracks(chunk.tracks, serverId: serverID)
        case .playlists:
            try await writer.upsertPlaylists(
                chunk.playlists,
                serverId: serverID)
        case .playlistItems:
            for page in chunk.playlistItems {
                try await writer.upsertPlaylistItemPage(
                    playlistRemoteId: page.playlistRemoteID,
                    startPosition: page.startPosition,
                    trackRemoteIds: page.trackRemoteIDs,
                    serverId: serverID)
            }
        }
    }

    /// Remove only the rebuildable catalog for one server.
    ///
    /// Used when a network or integrity failure interrupts a first hydration.
    /// Hydration runs only against an empty catalog, so this cannot erase a
    /// previously usable local library.
    public func clearCatalog(serverID: String) async throws {
        try await database.write { db in
            try Self.clearCatalog(serverID: serverID, in: db)
        }
    }

    private static func clearCatalog(
        serverID: String,
        in db: Database
    ) throws {
        try db.execute(
            sql: "DELETE FROM playlist WHERE serverId = ?",
            arguments: [serverID])
        try db.execute(
            sql: "DELETE FROM track WHERE serverId = ?",
            arguments: [serverID])
        try db.execute(
            sql: "DELETE FROM album WHERE serverId = ?",
            arguments: [serverID])
        try db.execute(
            sql: "DELETE FROM artist WHERE serverId = ?",
            arguments: [serverID])
        try db.execute(
            sql: "DELETE FROM favorite_outbox WHERE serverId = ?",
            arguments: [serverID])
    }

    private static func pageSQL(table: String, after remoteID: String?) -> String {
        """
        SELECT * FROM \(table)
        WHERE serverId = ? \(remoteID == nil ? "" : "AND remoteId > ?")
        ORDER BY remoteId
        LIMIT ?
        """
    }

    private static func pageArguments(
        _ serverID: String,
        after remoteID: String?,
        limit: Int
    ) -> StatementArguments {
        let boundedLimit = min(max(limit, 1), 1_000)
        if let remoteID {
            return [serverID, remoteID, boundedLimit]
        }
        return [serverID, boundedLimit]
    }
}
