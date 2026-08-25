import XCTest
import Foundation
import MozzCore
import MozzDatabase
@testable import MozzFFI

final class MozzSessionLyricsTests: XCTestCase {
    private func makeLibrary() throws -> String {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/mozz-session-lyrics-\(UUID().uuidString)", isDirectory: true)
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

    private func seedTrack(at path: String) async throws {
        let db = try MusicDatabase.open(at: URL(fileURLWithPath: path))
        let writer = CatalogWriter(db)
        try await writer.saveServer(ServerConnection(
            id: "srv",
            kind: .jellyfin,
            name: "Server",
            baseURL: URL(string: "https://music.example.com")!,
            clientIdentifier: "client"
        ))
        try await writer.upsertTracks([
            Track(
                id: "trk-lyrics",
                title: "No Network Lookup",
                albumTitle: "Album",
                albumID: "album",
                artistName: "Artist",
                artistID: "artist",
                duration: 180,
                artwork: nil
            ),
        ], serverId: "srv")
    }

    func testLyricsCommandIsListedForHelpfulErrors() {
        XCTAssertTrue(mozzSessionCommands.contains("lyrics"))
    }

    func testLyricsCommandRoundTripsStableSilentJSON() async throws {
        let path = try makeLibrary()
        try await seedTrack(at: path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, [
            "id": 9,
            "cmd": "lyrics",
            "serverId": "srv",
            "remoteId": "trk-lyrics",
            "useLRCLIB": false,
            "positionSeconds": 12.5,
            "leadSeconds": 0.3,
        ])

        XCTAssertEqual(response["id"] as? Int, 9)
        XCTAssertEqual(response["cmd"] as? String, "lyrics")
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let payload = try XCTUnwrap(response["payload"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["activeLineIndex", "lyrics", "status", "staySilent"])
        XCTAssertEqual(payload["status"] as? String, "silent")
        XCTAssertEqual(payload["staySilent"] as? Bool, true)
        XCTAssertTrue(payload["lyrics"] is NSNull)
        XCTAssertTrue(payload["activeLineIndex"] is NSNull)
    }

    func testLyricsCommandNamesMissingTrack() async throws {
        let path = try makeLibrary()
        try await seedTrack(at: path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, [
            "cmd": "lyrics",
            "serverId": "srv",
            "remoteId": "missing",
        ])

        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertTrue(try XCTUnwrap(response["error"] as? String).contains("missing"))
    }
}
