import Foundation
import GRDB

/// Owns the schema. All schema changes are additive migrations so an installed
/// catalog survives app updates (we never want to force a full re-sync).
enum Schema {
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerV1(&migrator)
        registerV2(&migrator)
        return migrator
    }

    private static func registerV1(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1.catalog") { db in
            try db.create(table: "server") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("baseURL", .text).notNull()
                t.column("userID", .text)
                t.column("clientIdentifier", .text).notNull()
                t.column("musicSectionID", .text)
            }

            try db.create(table: "serverCapabilities") { t in
                t.primaryKey("serverId", .text)
                    .references("server", onDelete: .cascade)
                t.column("backend", .text).notNull()
                t.column("serverVersion", .text)
                t.column("supportsTranscoding", .boolean).notNull()
                t.column("supportsOriginalFileDownload", .boolean).notNull()
                t.column("supportsFavorites", .boolean).notNull()
                t.column("supportsLyrics", .boolean).notNull()
                t.column("supportsSyncedLyrics", .boolean).notNull()
                t.column("supportsNormalizationGain", .boolean).notNull()
                t.column("supportsProgressReporting", .boolean).notNull()
                t.column("hasPlexPass", .boolean)
                t.column("detectedAt", .double).notNull()
            }

            try db.create(table: "artist") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("serverId", .text).notNull()
                    .references("server", onDelete: .cascade)
                t.column("remoteId", .text).notNull()
                t.column("name", .text).notNull()
                t.column("sortName", .text)
                t.column("artworkKey", .text)
                t.column("albumCount", .integer)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("genres", .text).notNull().defaults(to: "[]")
            }
            try db.create(index: "idx_artist_identity", on: "artist",
                          columns: ["serverId", "remoteId"], unique: true)
            try db.execute(sql: """
                CREATE INDEX idx_artist_sort ON artist(serverId, sortName COLLATE NOCASE, name COLLATE NOCASE)
                """)

            try db.create(table: "album") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("serverId", .text).notNull()
                    .references("server", onDelete: .cascade)
                t.column("remoteId", .text).notNull()
                t.column("title", .text).notNull()
                t.column("sortTitle", .text)
                t.column("artistName", .text).notNull()
                t.column("artistRemoteId", .text)
                t.column("year", .integer)
                t.column("artworkKey", .text)
                t.column("trackCount", .integer)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("addedAt", .double)
                t.column("genres", .text).notNull().defaults(to: "[]")
            }
            try db.create(index: "idx_album_identity", on: "album",
                          columns: ["serverId", "remoteId"], unique: true)
            try db.execute(sql: """
                CREATE INDEX idx_album_sort ON album(serverId, sortTitle COLLATE NOCASE, title COLLATE NOCASE)
                """)
            try db.create(index: "idx_album_artist", on: "album",
                          columns: ["serverId", "artistRemoteId"])

            try db.create(table: "track") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("serverId", .text).notNull()
                    .references("server", onDelete: .cascade)
                t.column("remoteId", .text).notNull()
                t.column("title", .text).notNull()
                t.column("sortTitle", .text)
                t.column("albumTitle", .text)
                t.column("albumRemoteId", .text)
                t.column("artistName", .text).notNull()
                t.column("artistRemoteId", .text)
                t.column("albumArtistName", .text)
                t.column("trackNumber", .integer)
                t.column("discNumber", .integer)
                t.column("duration", .double).notNull().defaults(to: 0)
                t.column("container", .text)
                t.column("codec", .text)
                t.column("bitrateKbps", .integer)
                t.column("sampleRateHz", .integer)
                t.column("channels", .integer)
                t.column("bitDepth", .integer)
                t.column("fileSizeBytes", .integer)
                t.column("mediaKey", .text)
                t.column("artworkKey", .text)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("normalizationGainDB", .double)
                t.column("addedAt", .double)
                t.column("genres", .text).notNull().defaults(to: "[]")
            }
            try db.create(index: "idx_track_identity", on: "track",
                          columns: ["serverId", "remoteId"], unique: true)
            // Album detail: tracks of an album in disc/track order.
            try db.create(index: "idx_track_album", on: "track",
                          columns: ["serverId", "albumRemoteId", "discNumber", "trackNumber"])
            try db.create(index: "idx_track_artist", on: "track",
                          columns: ["serverId", "artistRemoteId"])
            try db.execute(sql: """
                CREATE INDEX idx_track_sort ON track(serverId, sortTitle COLLATE NOCASE, title COLLATE NOCASE)
                """)

            try db.create(table: "playlist") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("serverId", .text).notNull()
                    .references("server", onDelete: .cascade)
                t.column("remoteId", .text).notNull()
                t.column("title", .text).notNull()
                t.column("trackCount", .integer)
                t.column("durationSeconds", .double)
                t.column("artworkKey", .text)
                t.column("isSmart", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "idx_playlist_identity", on: "playlist",
                          columns: ["serverId", "remoteId"], unique: true)

            try db.create(table: "playlistItem") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("playlistId", .integer).notNull()
                    .references("playlist", onDelete: .cascade)
                t.column("trackRemoteId", .text).notNull()
                t.column("position", .integer).notNull()
            }
            try db.create(index: "idx_playlistitem_playlist", on: "playlistItem",
                          columns: ["playlistId", "position"])

            try db.create(table: "download") { t in
                t.primaryKey("trackId", .integer)
                    .references("track", onDelete: .cascade)
                t.column("state", .text).notNull()
                t.column("localPath", .text)
                t.column("sizeBytes", .integer).notNull().defaults(to: 0)
                t.column("totalBytes", .integer)
                t.column("requestedAt", .double).notNull()
                t.column("completedAt", .double)
                t.column("errorMessage", .text)
            }
            try db.create(index: "idx_download_state", on: "download", columns: ["state"])

            // Full-text search: external-content FTS5 tables kept in sync with
            // their base tables via GRDB-generated triggers. Diacritic-
            // insensitive unicode61 tokenizer. Reads never duplicate text.
            try db.create(virtualTable: "track_fts", using: FTS5()) { t in
                t.synchronize(withTable: "track")
                t.tokenizer = .unicode61()
                t.column("title")
                t.column("albumTitle")
                t.column("artistName")
            }
            try db.create(virtualTable: "album_fts", using: FTS5()) { t in
                t.synchronize(withTable: "album")
                t.tokenizer = .unicode61()
                t.column("title")
                t.column("artistName")
            }
            try db.create(virtualTable: "artist_fts", using: FTS5()) { t in
                t.synchronize(withTable: "artist")
                t.tokenizer = .unicode61()
                t.column("name")
            }
        }
    }

    /// v2 — the append-only listening-history log (`play_event`).
    ///
    /// Deliberately NOT foreign-keyed to `track`: history must *survive* a
    /// catalog prune (a track vanishing from a flaky sync, or being re-added),
    /// so events key on the stable `track_ref` = "{serverId}:{remoteId}" and
    /// tolerate having no matching catalog row. (This also means the sync
    /// pruner can never cascade-delete listening history.)
    private static func registerV2(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2.playEvents") { db in
            try db.create(table: "play_event") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("track_ref", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("position_sec", .double)
                t.column("duration_sec", .double)
                t.column("context", .text)
                t.column("context_id", .text)
                t.column("device", .text)
                t.column("created_at", .double).notNull()
            }
            try db.create(index: "idx_play_event_track", on: "play_event", columns: ["track_ref"])
            try db.create(index: "idx_play_event_time", on: "play_event", columns: ["created_at"])
        }
    }
}
