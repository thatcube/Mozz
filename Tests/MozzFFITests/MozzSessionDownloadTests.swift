import XCTest
import Foundation
import MozzCore
import MozzDatabase
@testable import MozzFFI

/// Downloads across the JSON envelope.
///
/// The core keeps the record and the shell moves the bytes: it resolves a
/// stream URL, writes the file wherever that platform keeps them, and reports
/// back. None of that was reachable over this envelope, which is why Android
/// has no downloads — not a missing screen, a missing surface.
final class MozzSessionDownloadTests: XCTestCase {
    private let server = ServerConnection(
        id: "srv", kind: .jellyfin, name: "S",
        baseURL: URL(string: "https://s.example.com")!, clientIdentifier: "c")

    private func makeLibrary() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mozz-downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.sqlite").path
    }

    private func seed(_ path: String) async throws {
        let db = try MusicDatabase.open(at: URL(fileURLWithPath: path))
        let writer = CatalogWriter(db)
        try await writer.saveServer(server)
        try await writer.upsertTracks([
            Track(id: "t1", title: "One", artistName: "A", artistID: "ar1", duration: 100),
            Track(id: "t2", title: "Two", artistName: "A", artistID: "ar1", duration: 100),
        ], serverId: server.id)
    }

    private func open(_ path: String) throws -> Int64 {
        let handle = path.withCString { mozz_session_open($0) }
        XCTAssertGreaterThan(handle, 0)
        return handle
    }

    private func call(_ handle: Int64, _ request: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: request)
        let ptr = String(data: data, encoding: .utf8)!.withCString { mozz_session_call(handle, $0) }
        let responsePtr = try XCTUnwrap(ptr)
        defer { mozz_ffi_free_string(responsePtr) }
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(String(cString: responsePtr).utf8)) as? [String: Any])
    }

    private func payload(_ response: [String: Any]) throws -> [String: Any] {
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        return try XCTUnwrap(response["payload"] as? [String: Any])
    }

    func testTheCommandsAreListed() {
        let commands = Set(mozzSessionCommands)
        for name in ["enqueueDownload", "downloads", "downloadStatus",
                     "reportDownloadProgress", "completeDownload", "failDownload",
                     "deleteDownload", "storageUsage"] {
            XCTAssertTrue(commands.contains(name), "\(name) missing from mozzSessionCommands")
        }
    }

    /// The whole life of a download, as a shell drives it.
    func testATransferIsQueuedThenReportedThenFinished() async throws {
        let path = try makeLibrary()
        try await seed(path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let queued = try payload(try call(handle, [
            "cmd": "enqueueDownload", "serverId": server.id, "remoteId": "t1",
        ]))
        XCTAssertEqual(queued["state"] as? String, "queued")
        XCTAssertEqual(queued["remoteId"] as? String, "t1")
        XCTAssertEqual(queued["title"] as? String, "One",
                       "enough of the track to draw a row without a second call")

        // The first byte report is what turns a queued download into an active
        // one, which is the moment a progress bar has something to show.
        let active = try payload(try call(handle, [
            "cmd": "reportDownloadProgress", "serverId": server.id, "remoteId": "t1",
            "receivedBytes": 512, "totalBytes": 2048,
        ]))
        XCTAssertEqual(active["state"] as? String, "downloading")
        XCTAssertEqual(active["sizeBytes"] as? Int, 512)
        XCTAssertEqual(active["totalBytes"] as? Int, 2048)

        let done = try payload(try call(handle, [
            "cmd": "completeDownload", "serverId": server.id, "remoteId": "t1",
            "localPath": "audio/t1.m4a", "sizeBytes": 2048,
        ]))
        XCTAssertEqual(done["state"] as? String, "downloaded")
        XCTAssertEqual(done["localPath"] as? String, "audio/t1.m4a")
        XCTAssertNotNil(done["completedAt"] as? Double)

        let usage = try payload(try call(handle, ["cmd": "storageUsage"]))
        XCTAssertEqual(usage["downloadedTrackCount"] as? Int, 1)
        XCTAssertEqual(usage["totalBytes"] as? Int, 2048)
    }

    func testALateProgressReportDoesNotUncompleteADownload() async throws {
        let path = try makeLibrary()
        try await seed(path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        _ = try call(handle, ["cmd": "enqueueDownload", "serverId": server.id, "remoteId": "t1"])
        _ = try call(handle, [
            "cmd": "completeDownload", "serverId": server.id, "remoteId": "t1",
            "localPath": "audio/t1.m4a", "sizeBytes": 2048,
        ])
        let stray = try payload(try call(handle, [
            "cmd": "reportDownloadProgress", "serverId": server.id, "remoteId": "t1",
            "receivedBytes": 900, "totalBytes": 2048,
        ]))
        XCTAssertEqual(stray["state"] as? String, "downloaded",
                       "a straggling report must not un-finish a finished download")
    }

    func testAskingAboutATrackNobodyDownloadedIsNotAnError() async throws {
        let path = try makeLibrary()
        try await seed(path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        // A shell asking per row would drown in failures otherwise.
        let status = try payload(try call(handle, [
            "cmd": "downloadStatus", "serverId": server.id, "remoteId": "t2",
        ]))
        XCTAssertEqual(status["state"] as? String, "absent")
    }

    func testListingFiltersByState() async throws {
        let path = try makeLibrary()
        try await seed(path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        _ = try call(handle, ["cmd": "enqueueDownload", "serverId": server.id, "remoteId": "t1"])
        _ = try call(handle, ["cmd": "enqueueDownload", "serverId": server.id, "remoteId": "t2"])
        _ = try call(handle, [
            "cmd": "completeDownload", "serverId": server.id, "remoteId": "t1",
            "localPath": "audio/t1.m4a", "sizeBytes": 10,
        ])

        let all = try XCTUnwrap(
            try call(handle, ["cmd": "downloads"])["payload"] as? [[String: Any]])
        XCTAssertEqual(all.count, 2)

        let finished = try XCTUnwrap(
            try call(handle, ["cmd": "downloads", "states": ["downloaded"]])["payload"] as? [[String: Any]])
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished.first?["remoteId"] as? String, "t1")
    }

    func testDeletingForgetsTheRecordAndTheStorageItCounted() async throws {
        let path = try makeLibrary()
        try await seed(path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        _ = try call(handle, ["cmd": "enqueueDownload", "serverId": server.id, "remoteId": "t1"])
        _ = try call(handle, [
            "cmd": "completeDownload", "serverId": server.id, "remoteId": "t1",
            "localPath": "audio/t1.m4a", "sizeBytes": 2048,
        ])
        let deleted = try payload(try call(handle, [
            "cmd": "deleteDownload", "serverId": server.id, "remoteId": "t1",
        ]))
        XCTAssertEqual(deleted["ok"] as? Bool, true)

        let usage = try payload(try call(handle, ["cmd": "storageUsage"]))
        XCTAssertEqual(usage["downloadedTrackCount"] as? Int, 0)
        XCTAssertEqual(usage["totalBytes"] as? Int, 0)
    }

    func testAFailureIsRecordedWithItsReason() async throws {
        let path = try makeLibrary()
        try await seed(path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        _ = try call(handle, ["cmd": "enqueueDownload", "serverId": server.id, "remoteId": "t1"])
        let failed = try payload(try call(handle, [
            "cmd": "failDownload", "serverId": server.id, "remoteId": "t1",
            "reason": "the server hung up",
        ]))
        XCTAssertEqual(failed["state"] as? String, "failed")
        XCTAssertEqual(failed["errorMessage"] as? String, "the server hung up")
    }

    func testAnUnknownTrackFailsRatherThanInventingARecord() async throws {
        let path = try makeLibrary()
        try await seed(path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, [
            "cmd": "enqueueDownload", "serverId": server.id, "remoteId": "nope",
        ])
        XCTAssertEqual(response["ok"] as? Bool, false, "\(response)")
    }
}
