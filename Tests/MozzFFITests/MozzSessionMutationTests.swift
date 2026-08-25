import XCTest
import Foundation
import MozzCore
import MozzDatabase
@testable import MozzFFI

final class MozzSessionMutationTests: XCTestCase {
    private func makeLibrary(_ name: String = "mutations") throws -> String {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/mozz-session-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.sqlite").path
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

    private func seedTrack(at path: String, serverId: String = "srv") async throws {
        let db = try MusicDatabase.open(at: URL(fileURLWithPath: path))
        let writer = CatalogWriter(db)
        try await writer.saveServer(ServerConnection(
            id: serverId,
            kind: .jellyfin,
            name: "Server",
            baseURL: URL(string: "https://music.example.com")!,
            clientIdentifier: "client"
        ))
        try await writer.upsertTracks([
            Track(id: "trk-1", title: "Track", artistName: "Artist", duration: 180, addedAt: Date(timeIntervalSince1970: 200)),
            Track(id: "trk-2", title: "Other", artistName: "Artist", duration: 90, addedAt: Date(timeIntervalSince1970: 100)),
        ], serverId: serverId)
    }

    func testMutationCommandNamesAreAdvertised() {
        let commands = Set(mozzSessionCommands)
        for command in [
            "setFavorite", "setRating", "flushFavoriteOutbox",
            "reportPlayback", "continuityQueueHash", "continuityLoad", "continuitySave",
            "likedTracksCount", "recentlyAddedTracks",
        ] {
            XCTAssertTrue(commands.contains(command), "\(command) missing from mozzSessionCommands")
        }
    }

    func testSetFavoriteUpdatesLocalDatabaseAndQueuesOutbox() async throws {
        let path = try makeLibrary()
        try await seedTrack(at: path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, [
            "id": 11,
            "cmd": "setFavorite",
            "serverId": "srv",
            "remoteId": "trk-1",
            "liked": true,
            "flush": false,
        ])

        XCTAssertEqual(response["id"] as? Int, 11)
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let payload = try XCTUnwrap(response["payload"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["itemType", "kind", "liked", "queued", "remoteId", "serverId", "synced", "value"])
        XCTAssertEqual(payload["serverId"] as? String, "srv")
        XCTAssertEqual(payload["remoteId"] as? String, "trk-1")
        XCTAssertEqual(payload["itemType"] as? String, "track")
        XCTAssertEqual(payload["kind"] as? String, "favorite")
        XCTAssertEqual(payload["value"] as? Double, 1)
        XCTAssertEqual(payload["liked"] as? Bool, true)
        XCTAssertEqual(payload["queued"] as? Bool, true)
        XCTAssertEqual(payload["synced"] as? Bool, false)

        let tracks = try XCTUnwrap(try call(handle, [
            "cmd": "likedTracks", "serverId": "srv", "limit": 1,
        ])["payload"] as? [[String: Any]])
        XCTAssertEqual(tracks.first?["isFavorite"] as? Bool, true)

        let count = try call(handle, ["cmd": "likedTracksCount", "serverId": "srv"])
        XCTAssertEqual(count["ok"] as? Bool, true, "\(count)")
        let countPayload = try XCTUnwrap(count["payload"] as? [String: Any])
        XCTAssertEqual(Set(countPayload.keys), ["count"])
        XCTAssertEqual(countPayload["count"] as? Int, 1)
    }

    func testRecentlyAddedTracksKeepsStableJSON() async throws {
        let path = try makeLibrary("recently-added")
        try await seedTrack(at: path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, [
            "cmd": "recentlyAddedTracks",
            "serverId": "srv",
            "limit": 1,
        ])

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let payload = try XCTUnwrap(response["payload"] as? [[String: Any]])
        XCTAssertEqual(payload.count, 1)
        let track = try XCTUnwrap(payload.first)
        XCTAssertEqual(track["remoteId"] as? String, "trk-1")
        XCTAssertTrue(track.keys.contains("addedAt"))
        XCTAssertTrue(track.keys.contains("isFavorite"))
    }

    func testSetRatingCanClearRatingAndKeepsStableJSON() async throws {
        let path = try makeLibrary("rating")
        try await seedTrack(at: path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, [
            "cmd": "setRating",
            "serverId": "srv",
            "remoteId": "trk-1",
            "flush": false,
        ])

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let payload = try XCTUnwrap(response["payload"] as? [String: Any])
        XCTAssertEqual(payload["kind"] as? String, "rating")
        XCTAssertTrue(payload["value"] is NSNull)
        XCTAssertEqual(payload["liked"] as? Bool, false)
        XCTAssertEqual(payload["queued"] as? Bool, true)
    }

    func testReportPlaybackRequiresAnAttachedBackend() async throws {
        let path = try makeLibrary("report")
        try await seedTrack(at: path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, [
            "cmd": "reportPlayback",
            "serverId": "srv",
            "remoteId": "trk-1",
            "state": "playing",
            "positionSeconds": 0,
        ])

        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertTrue(try XCTUnwrap(response["error"] as? String).contains("attached"))
    }

    func testContinuityQueueHashMatchesGoldenFixtures() throws {
        let path = try makeLibrary("continuity")
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let fixtureURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("spec/continuity/queue-hash-fixtures.json")
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        for fixture in cases {
            var input = try XCTUnwrap(fixture["input"] as? [String: Any])
            input["cmd"] = "continuityQueueHash"
            let response = try call(handle, input)
            XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
            let payload = try XCTUnwrap(response["payload"] as? [String: Any])
            XCTAssertEqual(Set(payload.keys), ["canonicalByteCount", "canonicalBytesHex", "queueHash"])
            XCTAssertEqual(payload["queueHash"] as? String, fixture["queueHash"] as? String)
            XCTAssertEqual(payload["canonicalByteCount"] as? Int, fixture["canonicalByteCount"] as? Int)
            XCTAssertEqual(payload["canonicalBytesHex"] as? String, fixture["canonicalBytesHex"] as? String)
        }
    }

    func testContinuityStoreCommandsNameAttachRequirement() throws {
        let path = try makeLibrary("continuity-missing")
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let load = try call(handle, ["cmd": "continuityLoad", "serverId": "srv"])
        XCTAssertEqual(load["ok"] as? Bool, false)
        XCTAssertTrue(try XCTUnwrap(load["error"] as? String).contains("attached"))

        let save = try call(handle, ["cmd": "continuitySave", "serverId": "srv"])
        XCTAssertEqual(save["ok"] as? Bool, false)
        XCTAssertTrue(try XCTUnwrap(save["error"] as? String).contains("attached"))
    }
}
