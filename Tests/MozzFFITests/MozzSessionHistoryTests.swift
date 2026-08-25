import XCTest
import Foundation
import MozzCore
import MozzDatabase
@testable import MozzFFI

final class MozzSessionHistoryTests: XCTestCase {
    private func makeLibrary(_ name: String = "history") throws -> String {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/mozz-session-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.sqlite").path
    }

    private func seed(_ path: String, tracks: Int = 8) async throws {
        let db = try MusicDatabase.open(at: URL(fileURLWithPath: path))
        try await SyntheticCatalog(db).generate(
            serverId: SyntheticCatalog.defaultServerID,
            size: .init(artists: 2, albums: 2, tracks: tracks)
        )
    }

    private func open(_ path: String) throws -> Int64 {
        let handle = path.withCString { mozz_session_open($0) }
        XCTAssertGreaterThan(handle, 0)
        return handle
    }

    private func call(_ handle: Int64, _ request: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: request)
        let json = String(data: data, encoding: .utf8)!
        let ptr = json.withCString { mozz_session_call(handle, $0) }
        let responsePtr = try XCTUnwrap(ptr)
        defer { mozz_ffi_free_string(responsePtr) }
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(String(cString: responsePtr).utf8)) as? [String: Any]
        )
    }

    func testHistoryCommandsAreListedForHelpfulErrors() {
        let commands = Set(mozzSessionCommands)
        for cmd in ["recordPlayEvent", "playHistory", "historyExportBatch", "historyImportBatches", "historyYearRollup"] {
            XCTAssertTrue(commands.contains(cmd), "\(cmd) missing from mozzSessionCommands")
        }
    }

    func testRecordPlayEventRoundTripsTheHistoryJSONContract() async throws {
        let path = try makeLibrary()
        try await seed(path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, [
            "id": 7,
            "cmd": "recordPlayEvent",
            "serverId": SyntheticCatalog.defaultServerID,
            "remoteId": "trk-1",
            "kind": "completed",
            "positionSeconds": 119.5,
            "durationSeconds": 120.0,
            "context": "album",
            "contextId": "alb-0",
            "createdAtMS": 1_800_000_000_123,
            "deviceID": "desktop-a",
        ])

        XCTAssertEqual(response["id"] as? Int, 7)
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let event = try XCTUnwrap(response["payload"] as? [String: Any])
        XCTAssertEqual(Set(event.keys), [
            "uid", "deviceID", "trackRef", "kind", "createdAtMS",
            "positionMS", "durationMS", "context", "contextID",
        ])
        XCTAssertEqual(event["deviceID"] as? String, "desktop-a")
        XCTAssertEqual(event["trackRef"] as? String, "\(SyntheticCatalog.defaultServerID):trk-1")
        XCTAssertEqual(event["kind"] as? String, "completed")
        XCTAssertEqual(event["createdAtMS"] as? Int, 1_800_000_000_123)
        XCTAssertEqual(event["positionMS"] as? Int, 119_500)
        XCTAssertEqual(event["durationMS"] as? Int, 120_000)
        XCTAssertEqual(event["context"] as? String, "album")
        XCTAssertEqual(event["contextID"] as? String, "alb-0")
        XCTAssertEqual((event["uid"] as? String)?.count, 32)

        let recentTracks = try call(handle, [
            "cmd": "recentlyPlayedTracks",
            "serverId": SyntheticCatalog.defaultServerID,
            "limit": 5,
        ])
        let tracks = try XCTUnwrap(recentTracks["payload"] as? [[String: Any]])
        XCTAssertEqual(tracks.first?["remoteId"] as? String, "trk-1")
    }

    func testPlayHistoryPagesWithCursorAndStableFieldNames() async throws {
        let path = try makeLibrary()
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        for index in 0..<3 {
            _ = try call(handle, [
                "cmd": "recordPlayEvent",
                "serverId": "srv",
                "remoteId": "trk-\(index)",
                "kind": index == 0 ? "started" : "skipped",
                "positionMS": index * 10_000,
                "durationMS": 180_000,
                "createdAtMS": 1_800_000_000_000 + index * 1_000,
                "deviceID": "desktop-a",
            ])
        }

        let first = try call(handle, ["cmd": "playHistory", "serverId": "srv", "limit": 2])
        XCTAssertEqual(first["ok"] as? Bool, true, "\(first)")
        let firstRows = try XCTUnwrap(first["payload"] as? [[String: Any]])
        XCTAssertEqual(firstRows.map { $0["trackRef"] as? String }, ["srv:trk-2", "srv:trk-1"])
        XCTAssertEqual(Set(firstRows[0].keys), [
            "id", "eventUid", "trackRef", "kind", "positionSeconds",
            "durationSeconds", "context", "contextID", "deviceID", "createdAtMS",
        ])
        let cursor = try XCTUnwrap(first["nextCursor"] as? String)

        let second = try call(handle, ["cmd": "playHistory", "serverId": "srv", "limit": 2, "cursor": cursor])
        let secondRows = try XCTUnwrap(second["payload"] as? [[String: Any]])
        XCTAssertEqual(secondRows.map { $0["trackRef"] as? String }, ["srv:trk-0"])
        XCTAssertNil(second["nextCursor"] as? String)
    }

    func testHistoryBatchExchangeConvergesRegardlessOfOrder() async throws {
        let pathA = try makeLibrary("history-a")
        let pathB = try makeLibrary("history-b")
        let a = try open(pathA)
        let b = try open(pathB)
        defer {
            _ = mozz_session_close(a)
            _ = mozz_session_close(b)
        }

        _ = try call(a, [
            "cmd": "recordPlayEvent", "serverId": "srv", "remoteId": "a",
            "kind": "completed", "durationMS": 180_000,
            "createdAtMS": 1_800_000_000_000, "deviceID": "dev-a",
        ])
        _ = try call(b, [
            "cmd": "recordPlayEvent", "serverId": "srv", "remoteId": "b",
            "kind": "skipped", "positionMS": 12_000, "durationMS": 200_000,
            "createdAtMS": 1_800_000_001_000, "deviceID": "dev-b",
        ])

        let exportA = try call(a, ["cmd": "historyExportBatch", "deviceID": "dev-a", "deviceName": "A"])
        let exportB = try call(b, ["cmd": "historyExportBatch", "deviceID": "dev-b", "deviceName": "B"])
        let batchA = try XCTUnwrap(exportA["payload"] as? [String: Any])
        let batchB = try XCTUnwrap(exportB["payload"] as? [String: Any])
        XCTAssertEqual(Set(batchA.keys), ["version", "deviceID", "deviceName", "writtenAtMS", "windowStartMS", "events"])
        let batchAEvents = try XCTUnwrap(batchA["events"] as? [[String: Any]])
        XCTAssertEqual(Set(batchAEvents[0].keys), [
            "uid", "deviceID", "trackRef", "kind", "createdAtMS",
            "positionMS", "durationMS", "context", "contextID",
        ])

        let importIntoA = try call(a, ["cmd": "historyImportBatches", "deviceID": "dev-a", "batches": [batchB]])
        let importIntoB = try call(b, ["cmd": "historyImportBatches", "deviceID": "dev-b", "batches": [batchA]])
        XCTAssertEqual((importIntoA["payload"] as? [String: Any])?["imported"] as? Int, 1)
        XCTAssertEqual((importIntoB["payload"] as? [String: Any])?["imported"] as? Int, 1)

        let rowsA = try XCTUnwrap(try call(a, ["cmd": "playHistory", "limit": 10])["payload"] as? [[String: Any]])
        let rowsB = try XCTUnwrap(try call(b, ["cmd": "playHistory", "limit": 10])["payload"] as? [[String: Any]])
        XCTAssertEqual(Set(rowsA.compactMap { $0["eventUid"] as? String }),
                       Set(rowsB.compactMap { $0["eventUid"] as? String }))

        let replay = try call(a, ["cmd": "historyImportBatches", "deviceID": "dev-a", "batches": [batchB, batchA]])
        XCTAssertEqual((replay["payload"] as? [String: Any])?["imported"] as? Int, 0)
    }

    func testHistoryYearRollupUsesRecordedEvents() async throws {
        let path = try makeLibrary()
        try await seed(path, tracks: 2)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        _ = try call(handle, [
            "cmd": "recordPlayEvent", "serverId": SyntheticCatalog.defaultServerID,
            "remoteId": "trk-0", "kind": "completed",
            "durationMS": 120_000, "createdAtMS": 1_800_000_000_000,
            "deviceID": "desktop-a",
        ])

        let response = try call(handle, ["cmd": "historyYearRollup", "deviceID": "desktop-a", "year": 2027])
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let rollup = try XCTUnwrap(response["payload"] as? [String: Any])
        XCTAssertEqual(rollup["deviceID"] as? String, "desktop-a")
        XCTAssertEqual(rollup["year"] as? Int, 2027)
        XCTAssertEqual(rollup["monthlyMS"] as? [Int], [120_000] + Array(repeating: 0, count: 11))
        XCTAssertEqual(rollup["monthlyPlays"] as? [Int], [1] + Array(repeating: 0, count: 11))
        XCTAssertNotNil(rollup["topTracks"])
    }
}
