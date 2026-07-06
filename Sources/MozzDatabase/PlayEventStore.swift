import Foundation
import GRDB
import MozzCore

/// The write + read side of the append-only listening-history log
/// (`play_event`). Written by the playback engine (via the app), never mutated.
///
/// Events are keyed on the durable `trackRef` = `"{serverId}:{remoteId}"` so
/// they survive catalog prunes and re-adds. Joins back to the catalog are done
/// by *constructing* the ref (`serverId || ':' || remoteId`), never by splitting
/// it — a `serverId` may itself contain ':'.
public struct PlayEventStore: Sendable {
    private let database: MusicDatabase

    public init(_ database: MusicDatabase) {
        self.database = database
    }

    /// The durable history key for a (server, track) pair.
    public static func trackRef(serverId: ServerID, remoteId: String) -> String {
        "\(serverId):\(remoteId)"
    }

    /// Append one event. Appends only — history is immutable.
    public func append(_ event: PlayEvent, serverId: ServerID, device: String? = nil) async throws {
        let ref = Self.trackRef(serverId: serverId, remoteId: event.trackID)
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO play_event
                    (track_ref, kind, position_sec, duration_sec, context, context_id, device, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    ref, event.kind.rawValue, event.positionSeconds, event.durationSeconds,
                    event.context, event.contextID, device, event.createdAt.timeIntervalSince1970,
                ])
        }
    }

    /// All events for a track ref, newest first.
    public func events(forTrackRef ref: String) async throws -> [PlayEventRecord] {
        try await database.read { db in
            try PlayEventRecord.fetchAll(db, sql: """
                SELECT * FROM play_event WHERE track_ref = ? ORDER BY created_at DESC
                """, arguments: [ref])
        }
    }

    /// Number of events of a given kind (e.g. total completions).
    public func count(kind: PlayEventKind) async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM play_event WHERE kind = ?",
                             arguments: [kind.rawValue]) ?? 0
        }
    }

    /// Distinct track refs ordered by most-recent play — the basis for a
    /// "Recently Played" shelf. A track counts as played when it `started` or
    /// `completed` (a pure skip doesn't).
    public func recentlyPlayedTrackRefs(limit: Int = 50) async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(db, sql: """
                SELECT track_ref FROM play_event
                WHERE kind IN ('started', 'completed')
                GROUP BY track_ref
                ORDER BY MAX(created_at) DESC
                LIMIT ?
                """, arguments: [limit])
        }
    }
}
