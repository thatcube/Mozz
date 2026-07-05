import Foundation
import GRDB

/// Owns the schema. All schema changes are additive migrations so an installed
/// catalog survives app updates (we never want to force a full re-sync).
enum Schema {
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerV1(&migrator)
        registerV2(&migrator)
        registerV3(&migrator)
        registerV4(&migrator)
        registerV5(&migrator)
        registerV6(&migrator)
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

    /// v3 — album consolidation key (`albumGroupKey`).
    ///
    /// Servers (notably Jellyfin) fragment one album into many album entities
    /// that share an album-artist + title but each hold a subset of tracks. We
    /// never mutate/delete those mirrored rows (that would risk the download
    /// cascade / prune path); instead each album carries a derived group key the
    /// read layer groups by. Backfilled in Swift so existing rows use the exact
    /// same derivation as the upsert path.
    private static func registerV3(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3.albumGroupKey") { db in
            try db.alter(table: "album") { t in
                t.add(column: "albumGroupKey", .text).notNull().defaults(to: "")
            }
            let rows = try Row.fetchAll(db, sql: "SELECT id, artistRemoteId, artistName, sortTitle, title FROM album")
            let update = try db.makeStatement(sql: "UPDATE album SET albumGroupKey = ? WHERE id = ?")
            for row in rows {
                let sortTitle: String = row["sortTitle"] ?? row["title"] ?? ""
                let key = AlbumGrouping.key(
                    artistRemoteId: row["artistRemoteId"],
                    artistName: row["artistName"] ?? "",
                    sortTitle: sortTitle
                )
                try update.execute(arguments: [key, row["id"] as Int64])
            }
            // Album list/detail group + order by this key, scoped per server.
            try db.execute(sql: """
                CREATE INDEX idx_album_group ON album(serverId, albumGroupKey, sortTitle COLLATE NOCASE, title COLLATE NOCASE)
                """)
        }
    }

    /// v4 — re-backfill `albumGroupKey` after switching to the title-first key
    /// layout (so `ORDER BY albumGroupKey` is alphabetical and can early-
    /// terminate). Installs that already ran v3 hold the old artist-first keys;
    /// this rewrites them. Fresh installs migrate an empty album table, so this
    /// is a no-op there (rows arrive later via the upsert, already title-first).
    private static func registerV4(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4.albumGroupKeyTitleFirst") { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, artistRemoteId, artistName, sortTitle, title FROM album")
            let update = try db.makeStatement(sql: "UPDATE album SET albumGroupKey = ? WHERE id = ?")
            for row in rows {
                let sortTitle: String = row["sortTitle"] ?? row["title"] ?? ""
                let key = AlbumGrouping.key(
                    artistRemoteId: row["artistRemoteId"],
                    artistName: row["artistName"] ?? "",
                    sortTitle: sortTitle
                )
                try update.execute(arguments: [key, row["id"] as Int64])
            }
        }
    }

    /// v5 — backfill synthesized artist rows for album-artists the server
    /// referenced on albums but omitted from its artist listing, so installed
    /// catalogs get them without a re-sync. Ongoing maintenance happens in the
    /// sync engine; this covers what's already on disk. Derived from albums only.
    private static func registerV5(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5.synthesizeAlbumArtists") { db in
            let serverIds = try String.fetchAll(db, sql: "SELECT id FROM server")
            for serverId in serverIds {
                _ = try AlbumArtistSynthesis.run(db, serverId: serverId)
            }
        }
    }

    /// v6 — recommendation seams: `track_features` (enrichment + a vector-ready
    /// sonic embedding), plus precomputed `recommendation_set`/`recommendation_item`
    /// (see DATA_MODEL §2/§3, ADR-0004/0005).
    ///
    /// These are added EARLY, before the sonic analyzer ships, so on-device
    /// embeddings slot into the reserved `embedding` BLOB with no later migration,
    /// and listening-derived features have a home from day one.
    ///
    /// CRITICAL: `track_features` and `recommendation_item` key on the durable,
    /// OPAQUE `track_ref` (= PlayEventStore.trackRef) — NOT the catalog `Int64 id`
    /// and NOT a cascading FK. A computed embedding / a generated mix must SURVIVE
    /// a catalog prune (a track briefly vanishing from a flaky sync, or being
    /// re-added). Joins back to the catalog reconstruct the ref
    /// (`serverId || ':' || remoteId`); consumers tolerate a ref with no current
    /// catalog row. `recommendation_item` DOES cascade from its set (a regenerated
    /// set replaces its items) — that's disposable derived data, unlike history.
    private static func registerV6(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6.recommendationSeams") { db in
            try db.create(table: "track_features") { t in
                t.primaryKey("track_ref", .text)
                t.column("mbid", .text)
                t.column("artist_mbid", .text)
                t.column("genres", .text)          // JSON array (folksonomy tags)
                t.column("tags", .text)            // JSON array (moods/styles)
                t.column("bpm", .double)
                t.column("replaygain_db", .double) // client-applied loudness normalization
                t.column("embedding", .blob)       // Float32 vector (L2-normalized), nil until analyzed
                t.column("embedding_dim", .integer)
                t.column("feature_source", .text)  // ondevice|audiomuse|plex
                t.column("updated_at", .double).notNull()
            }

            try db.create(table: "recommendation_set") { t in
                t.primaryKey("id", .text)          // e.g. "mozz-weekly", "discover", "radio:{seed}"
                t.column("title", .text).notNull()
                t.column("kind", .text).notNull()  // daily_mix|discover|artist_radio|forgotten
                t.column("generated_at", .double).notNull()
                t.column("params", .text)          // JSON (seed, weights, filters)
            }

            try db.create(table: "recommendation_item") { t in
                t.column("set_id", .text).notNull()
                    .references("recommendation_set", onDelete: .cascade)
                t.column("track_ref", .text).notNull()
                t.column("rank", .integer).notNull()
                t.column("score", .double).notNull()
                t.column("in_library", .boolean).notNull() // 0 = discovery ("add to your server")
                t.column("reason", .text)                  // "because you played X" / "sounds like Y"
                t.primaryKey(["set_id", "track_ref"])
            }
            // Stream a set's items in rank order without a sort step.
            try db.create(index: "idx_rec_item_rank", on: "recommendation_item",
                          columns: ["set_id", "rank"])
        }
    }
}
