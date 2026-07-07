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

    /// Derive each album's track count locally from the synced tracks, so the
    /// album fetch doesn't have to ask the server for the (expensive) per-album
    /// `ChildCount`. Runs once at the end of a sync; uses the
    /// (serverId, albumRemoteId) track index, so it's a cheap local pass.
    public func deriveAlbumTrackCounts(serverId: ServerID) async throws {
        try await database.write { db in
            try db.execute(sql: """
                UPDATE album SET trackCount = (
                    SELECT COUNT(*) FROM track
                    WHERE track.serverId = album.serverId
                      AND track.albumRemoteId = album.remoteId
                )
                WHERE album.serverId = ?
                """, arguments: [serverId])
        }
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
                    track.isFavorite, track.rating, track.normalizationGainDB,
                    track.addedAt?.timeIntervalSince1970, Self.jsonText(track.genres),
                ])
            }
            // Tier-1 enrichment (ADR-0007/B1): capture MBIDs the backend already
            // embedded (Plex Guid / Jellyfin ProviderIds), in the SAME transaction
            // so every upsertTracks call site is covered with no extra network.
            // `tags`/`embedding`/`bpm`/`feature_source` are never touched.
            var recordings: [(ref: String, mbid: String, artist: String?)] = []
            var artistOnly: [(ref: String, artist: String)] = []
            for track in tracks {
                let ref = PlayEventStore.trackRef(serverId: serverId, remoteId: track.id)
                if let mbid = MusicBrainzID.normalized(track.mbid) {
                    recordings.append((ref, mbid, MusicBrainzID.normalized(track.artistMbid)))
                } else if let artist = MusicBrainzID.normalized(track.artistMbid) {
                    // Tagged only at the artist level (common on Jellyfin): keep the
                    // artist MBID as an `arid:` hint, but DON'T record a lookup — the
                    // track still needs recording resolution, so `mbid`/lookup stay
                    // untouched and it remains eligible.
                    artistOnly.append((ref, artist))
                }
            }
            if !recordings.isEmpty {
                let now = Date().timeIntervalSince1970
                let stmt = try db.makeStatement(sql: Self.embeddedMBIDUpsertSQL)
                for row in recordings {
                    try stmt.execute(arguments: [row.ref, row.mbid, row.artist, now, now])
                }
            }
            if !artistOnly.isEmpty {
                let now = Date().timeIntervalSince1970
                let stmt = try db.makeStatement(sql: Self.embeddedArtistMBIDUpsertSQL)
                for row in artistOnly {
                    try stmt.execute(arguments: [row.ref, row.artist, now])
                }
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
        "fileSizeBytes", "mediaKey", "artworkKey", "isFavorite", "rating", "normalizationGainDB",
        "addedAt", "genres",
    ])
    private static let playlistUpsertSQL = upsertSQL(table: "playlist", columns: [
        "title", "trackCount", "durationSeconds", "artworkKey", "isSmart",
    ])

    /// Partial UPSERT of a backend-embedded RECORDING MBID into `track_features`,
    /// keyed on the durable `track_ref`. Writes ONLY the MBID columns + lookup
    /// provenance; never touches `tags`/`embedding`/`bpm`/`feature_source`.
    /// `artist_mbid` is COALESCEd so a null (Plex) can't overwrite a resolved
    /// value. The `WHERE` guard skips a no-op rewrite when nothing would change,
    /// but still fires when a real artist MBID becomes available for an
    /// already-known recording (avoids rewriting a row + its indexes for every
    /// track on every sync while not blocking a genuine back-fill).
    /// Derived enrichment is invalidated when its key changes: the B2 canonical/
    /// similar caches when `mbid` changes, and the B4 `mb_tags` (keyed on
    /// `artist_mbid`) when the artist MBID changes to a new value — otherwise a
    /// re-tagged/merged artist would keep the previous artist's genres until the
    /// unrelated 30-day TTL lapsed.
    /// Arguments: (track_ref, mbid, artist_mbid, lookup_at, updated_at).
    private static let embeddedMBIDUpsertSQL = """
    INSERT INTO track_features (track_ref, mbid, artist_mbid, mbid_lookup_status, mbid_lookup_at, updated_at)
    VALUES (?, ?, ?, 'embedded', ?, ?)
    ON CONFLICT(track_ref) DO UPDATE SET
        mbid = excluded.mbid,
        artist_mbid = COALESCE(excluded.artist_mbid, track_features.artist_mbid),
        mbid_lookup_status = 'embedded',
        mbid_lookup_at = excluded.mbid_lookup_at,
        updated_at = excluded.updated_at,
        canonical_mbid = CASE WHEN track_features.mbid IS NOT excluded.mbid THEN NULL ELSE track_features.canonical_mbid END,
        canonical_lookup_at = CASE WHEN track_features.mbid IS NOT excluded.mbid THEN NULL ELSE track_features.canonical_lookup_at END,
        similar_lookup_at = CASE WHEN track_features.mbid IS NOT excluded.mbid THEN NULL ELSE track_features.similar_lookup_at END,
        mb_tags = CASE WHEN excluded.artist_mbid IS NOT NULL AND excluded.artist_mbid IS NOT track_features.artist_mbid THEN NULL ELSE track_features.mb_tags END,
        mb_tags_lookup_at = CASE WHEN excluded.artist_mbid IS NOT NULL AND excluded.artist_mbid IS NOT track_features.artist_mbid THEN NULL ELSE track_features.mb_tags_lookup_at END
    WHERE track_features.mbid IS NOT excluded.mbid
       OR (excluded.artist_mbid IS NOT NULL AND excluded.artist_mbid IS NOT track_features.artist_mbid)
    """

    /// Partial UPSERT of an embedded ARTIST MBID for a track that has NO recording
    /// MBID (e.g. a Jellyfin track tagged only at the artist level). Records just
    /// the artist MBID as a name-search hint; deliberately leaves `mbid`,
    /// `mbid_lookup_status`, and `mbid_lookup_at` untouched so the track stays
    /// eligible for recording resolution. The `WHERE` guard fires only when the
    /// artist MBID actually changes; when it does, the B4 `mb_tags` (keyed on the
    /// old artist) are cleared so the tag pass refetches for the new artist.
    /// Arguments: (track_ref, artist_mbid, updated_at).
    private static let embeddedArtistMBIDUpsertSQL = """
    INSERT INTO track_features (track_ref, artist_mbid, updated_at)
    VALUES (?, ?, ?)
    ON CONFLICT(track_ref) DO UPDATE SET
        artist_mbid = excluded.artist_mbid,
        updated_at = excluded.updated_at,
        mb_tags = NULL,
        mb_tags_lookup_at = NULL
    WHERE track_features.artist_mbid IS NOT excluded.artist_mbid
    """

    private static let genresEncoder = JSONEncoder()

    private static func jsonText(_ values: [String]) -> String {
        guard !values.isEmpty, let data = try? genresEncoder.encode(values) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
