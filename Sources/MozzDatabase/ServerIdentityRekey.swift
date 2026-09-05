import Foundation
import GRDB
import MozzCore

/// Move a library from one server id to another.
///
/// A server id is not data the user can see, but everything they can is keyed
/// on it: the catalog rows, the likes, the play history, the suppressions, and
/// the `track_ref` on every analysed vector. When the id a client persists and
/// the id its rows were written under stop agreeing, the library appears to
/// vanish — and re-syncing brings the catalog back while leaving the analysis
/// stranded under a prefix nothing looks up any more.
///
/// That happened once, for a reason worth writing down. For Plex the id could
/// be derived from a `*.plex.direct` hostname, whose middle component looks
/// exactly like a machine identifier and is not one: it identifies the
/// *connection*, and the same server hands out a different one at a different
/// address. A library keyed on it re-keys itself the moment Plex moves.
public enum ServerIdentityRekey {

    /// Every table that stores a server id outright.
    private static let serverIdTables = [
        "album", "artist", "catalogScope", "catalogSyncProgress",
        "catalogSyncRun", "favorite_outbox", "playlist", "serverCapabilities",
        "suppressed_ref", "track",
    ]

    /// Every table whose durable reference is `serverId:remoteId`.
    private static let trackRefTables = [
        "play_event", "recommendation_item", "track_features",
    ]

    /// Re-key `old` to `new`, or do nothing if it is not safe to.
    ///
    /// Returns the number of rows moved, or nil when the migration did not
    /// apply. Refuses when the destination already has a server row: two
    /// catalogs merging is a different and much harder problem than a rename,
    /// and getting it wrong silently is worse than leaving both alone.
    ///
    /// One transaction, and plain `UPDATE` rather than `UPDATE OR IGNORE` —
    /// with the destination proven empty a unique-constraint conflict is not
    /// something to swallow, it is a sign the precondition was wrong.
    @discardableResult
    public static func apply(
        in database: MusicDatabase, from old: String, to new: String
    ) async throws -> Int? {
        guard !old.isEmpty, !new.isEmpty, old != new else { return nil }
        return try await database.write { db in
            let existing = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM server WHERE id = ?",
                arguments: [old]) ?? 0
            guard existing > 0 else { return nil }
            let destination = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM server WHERE id = ?",
                arguments: [new]) ?? 0
            guard destination == 0 else { return nil }

            // Every child references `server.id`, and none of them cascades on
            // update - only on delete. Renaming the parent therefore orphans
            // every row for as long as it takes to rename them too, which
            // SQLite rejects outright. Deferring moves the check to COMMIT,
            // where the whole set is consistent again.
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")

            var moved = 0
            try db.execute(
                sql: "UPDATE server SET id = ? WHERE id = ?",
                arguments: [new, old])
            moved += db.changesCount

            for table in serverIdTables where try tableExists(db, table) {
                try db.execute(
                    sql: "UPDATE \(table) SET serverId = ? WHERE serverId = ?",
                    arguments: [new, old])
                moved += db.changesCount
            }

            // The prefix only, and only when the separator is where it should
            // be: a `track_ref` is `serverId:remoteId`, and a remote id may
            // itself contain a colon.
            let prefix = "\(old):"
            for table in trackRefTables where try tableExists(db, table) {
                try db.execute(sql: """
                    UPDATE \(table)
                    SET track_ref = ? || substr(track_ref, ?)
                    WHERE substr(track_ref, 1, ?) = ?
                    """, arguments: ["\(new):", prefix.count + 1, prefix.count, prefix])
                moved += db.changesCount
            }
            return moved
        }
    }

    /// What a Plex library keyed on a `*.plex.direct` hostname would have been
    /// filed under, so an attach carrying the real machine id can find it.
    ///
    /// Returns nil for anything else — a different backend, a plain address, or
    /// an id that already agrees.
    public static func supersededPlexID(
        for serverID: String, kind: BackendKind, baseURL: URL
    ) -> String? {
        guard kind == .plex else { return nil }
        let derived = ServerIdentity.id(kind: kind, baseURL: baseURL)
        return derived == serverID ? nil : derived
    }

    private static func tableExists(_ db: Database, _ name: String) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
                SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)
            """, arguments: [name]) ?? false
    }
}
