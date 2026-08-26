import Foundation
import GRDB
import MozzCore
import MozzHistory

/// Moves listening history between the local `play_event` table and the
/// portable `MozzHistory` wire types.
///
/// Lives here, rather than in `MozzHistory`, so that module stays free of GRDB
/// and remains buildable anywhere — it is one of the layers a Windows or Android
/// client would reuse verbatim.
///
/// The merge itself is a G-Set union (see `HistoryMerge`), so no play event is
/// ever deleted and none is ever changed into a different listen: the import
/// path is idempotent because `event_uid` is unique.
///
/// It is not, however, strictly insert-only, and it used to say that it was.
/// `backfillEventUIDs` runs `UPDATE OR IGNORE play_event` to fill `event_uid`
/// and `device` on rows written before those columns existed. That mutates
/// metadata, never the identity of a listen — the track, the time and the kind
/// are untouched — but code that reads "insert-only" and concludes a row is
/// frozen once written would be wrong, and would be wrong in the silent way.
public struct HistorySyncStore: Sendable {
    private let database: MusicDatabase

    public init(_ database: MusicDatabase) {
        self.database = database
    }

    // MARK: Backfill

    /// Give any pre-v17 rows a `event_uid`, in batches.
    ///
    /// Old rows have no `device`, so they are attributed to `localDeviceID` —
    /// which is correct: they were all recorded on this device, before the
    /// column existed. Returns how many rows were filled, so a caller can loop
    /// until it reaches zero.
    ///
    /// `legacyLocalKind` migrates the *older* scheme, where Apple clients wrote
    /// a platform kind — "iphone" or "mac" — instead of a device identity. Those
    /// have to become a real device id, because a kind is not unique and two
    /// phones would merge as though they were one device.
    ///
    /// Only rows matching this device's own kind are rewritten. That restriction
    /// is the whole point: on a phone, a row marked "mac" arrived from a Mac
    /// through history sync, and claiming it as local would attribute someone
    /// else's listening to this device and then export it back as ours. Pass
    /// nil on a client that never wrote the old kinds.
    ///
    /// A conflict is possible in principle (two identical events on the same
    /// device in the same millisecond), so the write ignores it: the row simply
    /// keeps a NULL uid and never syncs, which is a far better outcome than
    /// failing the migration for everyone.
    @discardableResult
    public func backfillUIDs(localDeviceID: String,
                             legacyLocalKind: String? = nil,
                             limit: Int = 5_000) async throws -> Int {
        // A named type rather than a tuple: a six-element tuple of mixed
        // optionals is expensive enough to type-check that the release compiler
        // gives up on it ("unable to type-check this expression in reasonable
        // time"), while debug builds squeak through. It is also what lets these
        // rows leave the database's concurrency domain, since GRDB's `Row` is
        // not Sendable.
        struct PendingRow: Sendable {
            var id: Int64
            var trackRef: String
            var kind: String
            var createdAt: Double
            var positionSec: Double?
            var durationSec: Double?
        }

        let rows: [PendingRow] = try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, track_ref, kind, created_at, position_sec, duration_sec
                FROM play_event
                WHERE event_uid IS NULL
                ORDER BY id
                LIMIT ?
                """, arguments: [limit])
                .map { row in
                    PendingRow(
                        id: row["id"],
                        trackRef: row["track_ref"],
                        kind: row["kind"],
                        createdAt: row["created_at"],
                        positionSec: row["position_sec"],
                        durationSec: row["duration_sec"]
                    )
                }
        }
        guard !rows.isEmpty else { return 0 }

        let assignments: [(id: Int64, uid: String)] = rows.map { row in
            let uid = HistoryEvent.makeUID(
                deviceID: localDeviceID,
                trackRef: row.trackRef,
                kind: row.kind,
                createdAtMS: Self.milliseconds(row.createdAt),
                positionMS: row.positionSec.map(Self.milliseconds),
                durationMS: row.durationSec.map(Self.milliseconds)
            )
            return (row.id, uid)
        }

        return try await database.write { db in
            var filled = 0
            for (id, uid) in assignments {
                try db.execute(
                    sql: """
                        UPDATE OR IGNORE play_event
                        SET event_uid = ?,
                            device = CASE
                                WHEN device IS NULL THEN ?
                                WHEN ? IS NOT NULL AND device = ? THEN ?
                                ELSE device
                            END
                        WHERE id = ?
                        """,
                    arguments: [uid, localDeviceID, legacyLocalKind, legacyLocalKind, localDeviceID, id]
                )
                filled += db.changesCount
            }
            return filled
        }
    }

    // MARK: Export

    /// This device's events, newest-window-first, ready to be windowed and
    /// written to a server.
    ///
    /// Only rows this device authored are exported. A device republishing
    /// another's events would multiply the same listen across every device that
    /// ever saw it, and each copy would look authentic.
    public func exportableEvents(
        localDeviceID: String,
        since: Date,
        limit: Int = 20_000
    ) async throws -> [HistoryEvent] {
        let sinceEpoch = since.timeIntervalSince1970
        return try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT event_uid, track_ref, kind, created_at,
                       position_sec, duration_sec, context, context_id
                FROM play_event
                WHERE event_uid IS NOT NULL
                  AND created_at >= ?
                  AND (device IS NULL OR device = ?)
                ORDER BY created_at DESC
                LIMIT ?
                """, arguments: [sinceEpoch, localDeviceID, limit])
                .map { row in
                    HistoryEvent(
                        uid: row["event_uid"],
                        deviceID: localDeviceID,
                        trackRef: row["track_ref"],
                        kind: row["kind"],
                        createdAtMS: Self.milliseconds(row["created_at"]),
                        positionMS: (row["position_sec"] as Double?).map(Self.milliseconds),
                        durationMS: (row["duration_sec"] as Double?).map(Self.milliseconds),
                        context: row["context"],
                        contextID: row["context_id"]
                    )
                }
        }
    }

    /// The uids this device already holds, for the merge's dedupe set.
    ///
    /// Bounded by the same window as the export: an event outside the window
    /// cannot arrive in a batch either, so loading older uids would only make
    /// the set bigger without making it more correct.
    public func knownUIDs(since: Date) async throws -> Set<String> {
        let sinceEpoch = since.timeIntervalSince1970
        return try await database.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT event_uid FROM play_event
                WHERE event_uid IS NOT NULL AND created_at >= ?
                """, arguments: [sinceEpoch]))
        }
    }

    // MARK: Import

    /// Insert merged-in events from other devices.
    ///
    /// `INSERT OR IGNORE` against the unique `event_uid` index makes this safe
    /// to run repeatedly and safe against two concurrent imports of overlapping
    /// batches — the second insert is silently dropped rather than raising.
    ///
    /// Returns the number of rows actually added.
    @discardableResult
    public func importEvents(_ events: [HistoryEvent]) async throws -> Int {
        guard !events.isEmpty else { return 0 }
        return try await database.write { db in
            var inserted = 0
            for event in events {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO play_event
                        (track_ref, kind, position_sec, duration_sec,
                         context, context_id, device, created_at, event_uid)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        event.trackRef,
                        event.kind,
                        event.positionMS.map { Double($0) / 1000 },
                        event.durationMS.map { Double($0) / 1000 },
                        event.context,
                        event.contextID,
                        event.deviceID,
                        Double(event.createdAtMS) / 1000,
                        event.uid,
                    ])
                inserted += db.changesCount
            }
            return inserted
        }
    }

    // MARK: Helpers

    /// Seconds to integer milliseconds, rounded consistently.
    ///
    /// Every conversion in and out of the wire format goes through this. The
    /// wire format is integer milliseconds precisely because floating point is
    /// not canonical across platforms, so an ad-hoc `Int(x * 1000)` somewhere
    /// else — truncating where this rounds — would derive a different uid for
    /// the same event and silently defeat deduplication.
    static func milliseconds(_ seconds: Double) -> Int64 {
        Int64((seconds * 1000).rounded())
    }
}
