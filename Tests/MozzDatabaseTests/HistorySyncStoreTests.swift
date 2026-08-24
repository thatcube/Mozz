import XCTest
import MozzCore
import MozzHistory
import GRDB
@testable import MozzDatabase

/// Round-trip tests for cross-device history sync.
///
/// The pure merge laws are covered in `MozzHistoryTests`; what matters here is
/// that the database honours them — that import really is idempotent under the
/// unique index, that a device never exports another's events, and that rows
/// written before `event_uid` existed are given one deterministically.
final class HistorySyncStoreTests: XCTestCase {

    private func makeDatabase() throws -> MusicDatabase {
        try MusicDatabase.inMemory()
    }

    private func appendLocalEvent(
        _ store: PlayEventStore,
        trackID: String,
        kind: PlayEventKind = .completed,
        at: Date,
        device: String? = nil
    ) async throws {
        try await store.append(
            PlayEvent(
                trackID: trackID,
                kind: kind,
                positionSeconds: 120,
                durationSeconds: 180,
                createdAt: at
            ),
            serverId: "srv1",
            device: device
        )
    }

    // MARK: Backfill

    func testBackfillAssignsDeterministicUIDs() async throws {
        let db = try makeDatabase()
        let events = PlayEventStore(db)
        let sync = HistorySyncStore(db)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try await appendLocalEvent(events, trackID: "t1", at: now)
        try await appendLocalEvent(events, trackID: "t2", at: now.addingTimeInterval(-60))

        let filled = try await sync.backfillUIDs(localDeviceID: "dev-a")
        XCTAssertEqual(filled, 2)

        let uids = try await db.read { database in
            try String.fetchAll(database, sql: "SELECT event_uid FROM play_event ORDER BY id")
        }
        XCTAssertEqual(uids.count, 2)

        // Deterministic: the uid must equal what the portable derivation gives
        // for the same fields, or another device would compute a different id
        // for an event it already has.
        let expected = HistoryEvent.makeUID(
            deviceID: "dev-a",
            trackRef: PlayEventStore.trackRef(serverId: "srv1", remoteId: "t1"),
            kind: PlayEventKind.completed.rawValue,
            createdAtMS: HistorySyncStore.milliseconds(now.timeIntervalSince1970),
            positionMS: 120_000,
            durationMS: 180_000
        )
        XCTAssertTrue(uids.contains(expected))
    }

    func testBackfillIsIdempotent() async throws {
        let db = try makeDatabase()
        let events = PlayEventStore(db)
        let sync = HistorySyncStore(db)

        try await appendLocalEvent(events, trackID: "t1", at: Date(timeIntervalSince1970: 1_800_000_000))
        let firstPass = try await sync.backfillUIDs(localDeviceID: "dev-a")
        XCTAssertEqual(firstPass, 1)
        // Second pass finds nothing left to do, which is how a caller knows to
        // stop looping.
        let secondPass = try await sync.backfillUIDs(localDeviceID: "dev-a")
        XCTAssertEqual(secondPass, 0)
    }

    // MARK: Export

    func testExportReturnsOnlyThisDevicesEvents() async throws {
        let db = try makeDatabase()
        let events = PlayEventStore(db)
        let sync = HistorySyncStore(db)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try await appendLocalEvent(events, trackID: "mine", at: now)
        try await appendLocalEvent(events, trackID: "theirs", at: now, device: "dev-b")
        try await sync.backfillUIDs(localDeviceID: "dev-a")

        let exported = try await sync.exportableEvents(
            localDeviceID: "dev-a",
            since: now.addingTimeInterval(-86_400)
        )
        // Republishing another device's events would multiply one listen across
        // every device that ever saw it.
        XCTAssertEqual(exported.map(\.trackRef), ["srv1:mine"])
    }

    func testExportRespectsTheTimeWindow() async throws {
        let db = try makeDatabase()
        let events = PlayEventStore(db)
        let sync = HistorySyncStore(db)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try await appendLocalEvent(events, trackID: "recent", at: now)
        try await appendLocalEvent(events, trackID: "ancient", at: now.addingTimeInterval(-400 * 86_400))
        try await sync.backfillUIDs(localDeviceID: "dev-a")

        let exported = try await sync.exportableEvents(
            localDeviceID: "dev-a",
            since: now.addingTimeInterval(-180 * 86_400)
        )
        XCTAssertEqual(exported.map(\.trackRef), ["srv1:recent"])
    }

    // MARK: Import

    func testImportInsertsRemoteEvents() async throws {
        let db = try makeDatabase()
        let sync = HistorySyncStore(db)

        let remote = HistoryEvent(
            deviceID: "dev-b",
            trackRef: "srv1:remote-track",
            kind: "skipped",
            createdAtMS: 1_800_000_000_000,
            positionMS: 12_000,
            durationMS: 200_000
        )
        let insertedCount = try await sync.importEvents([remote])
        XCTAssertEqual(insertedCount, 1)

        let row = try await db.read { database in
            try Row.fetchOne(database, sql: """
                SELECT track_ref, kind, device, position_sec, duration_sec, event_uid
                FROM play_event
                """)
        }
        let unwrapped = try XCTUnwrap(row)
        XCTAssertEqual(unwrapped["track_ref"], "srv1:remote-track")
        XCTAssertEqual(unwrapped["kind"], "skipped")
        // Attribution is preserved, so this device will never re-export it.
        XCTAssertEqual(unwrapped["device"], "dev-b")
        XCTAssertEqual(unwrapped["position_sec"], 12.0)
        XCTAssertEqual(unwrapped["event_uid"], remote.uid)
    }

    func testImportingTheSameEventTwiceInsertsItOnce() async throws {
        let db = try makeDatabase()
        let sync = HistorySyncStore(db)

        let remote = HistoryEvent(
            deviceID: "dev-b",
            trackRef: "srv1:x",
            kind: "completed",
            createdAtMS: 1_800_000_000_000
        )
        let firstInsert = try await sync.importEvents([remote])
        XCTAssertEqual(firstInsert, 1)
        // The unique index on event_uid is what makes a repeated sync safe;
        // without it every sync would inflate the play count.
        let secondInsert = try await sync.importEvents([remote])
        XCTAssertEqual(secondInsert, 0)

        let count = try await db.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM play_event") ?? 0
        }
        XCTAssertEqual(count, 1)
    }

    // MARK: End to end

    func testTwoDevicesConvergeOnTheSameHistory() async throws {
        // The property the whole design exists for: after exchanging batches,
        // both devices hold the same set of events.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let since = now.addingTimeInterval(-180 * 86_400)

        let dbA = try makeDatabase()
        let syncA = HistorySyncStore(dbA)
        try await appendLocalEvent(PlayEventStore(dbA), trackID: "a1", at: now)
        try await appendLocalEvent(PlayEventStore(dbA), trackID: "a2", at: now.addingTimeInterval(-30))
        try await syncA.backfillUIDs(localDeviceID: "dev-a")

        let dbB = try makeDatabase()
        let syncB = HistorySyncStore(dbB)
        try await appendLocalEvent(PlayEventStore(dbB), trackID: "b1", at: now.addingTimeInterval(-10))
        try await syncB.backfillUIDs(localDeviceID: "dev-b")

        func batch(_ store: HistorySyncStore, device: String) async throws -> HistoryBatch {
            HistoryBatch(
                deviceID: device,
                writtenAtMS: Int64(now.timeIntervalSince1970 * 1000),
                windowStartMS: Int64(since.timeIntervalSince1970 * 1000),
                events: try await store.exportableEvents(localDeviceID: device, since: since)
            )
        }

        let batchA = try await batch(syncA, device: "dev-a")
        let batchB = try await batch(syncB, device: "dev-b")

        // Each device merges the other's batch.
        let intoA = HistoryMerge.newEvents(
            from: [batchB], known: try await syncA.knownUIDs(since: since), ownDeviceID: "dev-a"
        )
        try await syncA.importEvents(intoA)

        let intoB = HistoryMerge.newEvents(
            from: [batchA], known: try await syncB.knownUIDs(since: since), ownDeviceID: "dev-b"
        )
        try await syncB.importEvents(intoB)

        func uids(_ db: MusicDatabase) async throws -> Set<String> {
            try await db.read { database in
                Set(try String.fetchAll(database, sql: "SELECT event_uid FROM play_event WHERE event_uid IS NOT NULL"))
            }
        }

        let a = try await uids(dbA)
        let b = try await uids(dbB)
        XCTAssertEqual(a, b, "devices did not converge")
        XCTAssertEqual(a.count, 3)

        // And a second exchange changes nothing — convergence is stable, not a
        // one-shot coincidence.
        let againA = HistoryMerge.newEvents(
            from: [batchB], known: try await syncA.knownUIDs(since: since), ownDeviceID: "dev-a"
        )
        let reimported = try await syncA.importEvents(againA)
        XCTAssertEqual(reimported, 0)
    }
}
