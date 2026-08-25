import XCTest
import Foundation
import MozzCore
import MozzDatabase
@testable import MozzFFI

/// Recommendation commands through the real C session dispatcher: these shapes
/// are what a desktop or Android client decodes, so the tests assert field names
/// and primitive JSON types rather than Swift implementation details.
final class MozzSessionRecommendationTests: XCTestCase {
    private let server = ServerConnection(id: "srv", kind: .jellyfin, name: "S",
                                          baseURL: URL(string: "https://s.example.com")!, clientIdentifier: "c")
    private let now = Date()

    private func makeLibrary() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mozz-recommendations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.sqlite").path
    }

    private func daysAgo(_ d: Double) -> Date {
        Date(timeIntervalSince1970: now.timeIntervalSince1970 - d * 24 * 3600)
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
            try JSONSerialization.jsonObject(
                with: Data(String(cString: responsePtr).utf8)) as? [String: Any]
        )
    }

    private func seedLibrary(at path: String) async throws {
        let db = try MusicDatabase.open(at: URL(fileURLWithPath: path))
        let writer = CatalogWriter(db)
        let plays = PlayEventStore(db)
        try await writer.saveServer(server)

        var tracks: [Track] = []
        let artists = [("ar1", "Nirvana"), ("ar2", "Pixies"), ("ar3", "Hole"), ("ar4", "Breeders")]
        for (ai, artist) in artists.enumerated() {
            for i in 0..<4 {
                tracks.append(Track(id: "\(artist.0)-\(i)", title: "Track \(ai)-\(i)",
                                    albumTitle: "Album \(ai)", albumID: "al\(ai)",
                                    artistName: artist.1, artistID: artist.0,
                                    duration: Double(180 + i),
                                    artwork: ArtworkRef(key: "art-\(artist.0)"),
                                    genres: ["Rock"], addedAt: daysAgo(Double(i + 1))))
            }
        }
        tracks.append(Track(id: "jazz1", title: "Jazz One", artistName: "Davis",
                            artistID: "ar9", duration: 200, genres: ["Jazz"], addedAt: daysAgo(2)))
        try await writer.upsertTracks(tracks, serverId: server.id)

        for id in ["ar1-0", "ar1-1", "ar1-2", "ar1-3", "ar2-0", "ar2-1", "ar2-2", "ar2-3"] {
            try await plays.append(
                PlayEvent(trackID: id, kind: .completed, createdAt: daysAgo(1)),
                serverId: server.id)
        }
    }

    func testRecommendationCommandNamesAreListedForHelpfulErrors() {
        let commands = Set(mozzSessionCommands)
        for cmd in [
            "homeMixes", "generateHomeMixes", "mix", "mixTracks", "generateMozzWeekly",
            "mozzWeeklyTracks", "mozzWeeklyItems", "radioBatch", "suppressTrack",
            "suppressArtist", "unsuppressTrack", "unsuppressArtist", "suppressions",
        ] {
            XCTAssertTrue(commands.contains(cmd), "\(cmd) missing from mozzSessionCommands")
        }
    }

    func testHomeMixCommandsRoundTripStableJSON() async throws {
        let path = try makeLibrary()
        try await seedLibrary(at: path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let generated = try call(handle, ["id": 1, "cmd": "generateHomeMixes", "serverId": server.id, "seed": 7])
        XCTAssertEqual(generated["ok"] as? Bool, true, "\(generated)")
        XCTAssertEqual(generated["id"] as? Int, 1)
        XCTAssertEqual((generated["payload"] as? [String: Any])?["ok"] as? Bool, true)

        let mixesResponse = try call(handle, ["cmd": "homeMixes"])
        XCTAssertEqual(mixesResponse["ok"] as? Bool, true, "\(mixesResponse)")
        let mixes = try XCTUnwrap(mixesResponse["payload"] as? [[String: Any]])
        let supermix = try XCTUnwrap(mixes.first { $0["id"] as? String == "supermix" })
        XCTAssertEqual(supermix["title"] as? String, "Supermix")
        XCTAssertEqual(supermix["kind"] as? String, "supermix")
        if let subtitle = supermix["subtitle"] { XCTAssertTrue(subtitle is String) }
        if let artworkKey = supermix["artworkKey"] { XCTAssertTrue(artworkKey is String) }
        XCTAssertNotNil(supermix["generatedAt"] as? Double)

        let mix = try call(handle, ["cmd": "mix", "setId": "supermix"])
        let mixPayload = try XCTUnwrap(mix["payload"] as? [String: Any])
        XCTAssertEqual(mixPayload["id"] as? String, "supermix")
        XCTAssertEqual(mixPayload["title"] as? String, "Supermix")
        XCTAssertEqual(mixPayload["kind"] as? String, "supermix")
        XCTAssertNotNil(mixPayload["generatedAt"] as? Double)

        let tracksResponse = try call(handle, ["cmd": "mixTracks", "setId": "supermix"])
        let tracks = try XCTUnwrap(tracksResponse["payload"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(tracks.count, 8)
        assertWireTrack(tracks[0])
    }

    func testMozzWeeklyCommandsRoundTripStableJSON() async throws {
        let path = try makeLibrary()
        try await seedLibrary(at: path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let generated = try call(handle, ["cmd": "generateMozzWeekly", "serverId": server.id, "limit": 6, "seed": 11])
        XCTAssertEqual(generated["ok"] as? Bool, true, "\(generated)")
        let set = try XCTUnwrap(generated["payload"] as? [String: Any])
        XCTAssertEqual(set["id"] as? String, "mozz-weekly")
        XCTAssertNotNil(set["title"] as? String)
        XCTAssertEqual(set["kind"] as? String, "forgotten")
        XCTAssertNotNil(set["generatedAt"] as? Double)

        let tracksResponse = try call(handle, ["cmd": "mozzWeeklyTracks"])
        let tracks = try XCTUnwrap(tracksResponse["payload"] as? [[String: Any]])
        XCTAssertFalse(tracks.isEmpty)
        assertWireTrack(tracks[0])

        let itemsResponse = try call(handle, ["cmd": "mozzWeeklyItems"])
        let items = try XCTUnwrap(itemsResponse["payload"] as? [[String: Any]])
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item["setId"] as? String, "mozz-weekly")
        XCTAssertNotNil(item["trackRef"] as? String)
        XCTAssertNotNil(item["rank"] as? Int)
        XCTAssertNotNil(item["score"] as? Double)
        XCTAssertNotNil(item["inLibrary"] as? Bool)
        if let reason = item["reason"] { XCTAssertTrue(reason is String) }
    }

    func testRadioBatchCommandRoundTripsSeedToTracks() async throws {
        let path = try makeLibrary()
        try await seedLibrary(at: path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, [
            "cmd": "radioBatch", "serverId": server.id, "limit": 5,
            "seedTitle": "Rock Radio", "seedGenres": ["Rock"], "seedArtistIds": ["ar1"],
            "seedTrackRef": "srv:ar1-0", "excluding": ["ar1-0"],
        ])
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let payload = try XCTUnwrap(response["payload"] as? [String: Any])
        let remoteIds = try XCTUnwrap(payload["remoteIds"] as? [String])
        let tracks = try XCTUnwrap(payload["tracks"] as? [[String: Any]])
        XCTAssertFalse(remoteIds.isEmpty)
        XCTAssertEqual(remoteIds.count, tracks.count)
        XCTAssertFalse(remoteIds.contains("ar1-0"))
        assertWireTrack(tracks[0])
        XCTAssertEqual(tracks[0]["remoteId"] as? String, remoteIds[0])
    }

    func testSuppressionCommandsRoundTripStableJSON() async throws {
        let path = try makeLibrary()
        try await seedLibrary(at: path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        for request in [
            ["cmd": "suppressTrack", "serverId": server.id, "remoteId": "ar1-0"],
            ["cmd": "suppressArtist", "serverId": server.id, "remoteId": "ar2"],
        ] {
            let response = try call(handle, request)
            XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
            XCTAssertEqual((response["payload"] as? [String: Any])?["ok"] as? Bool, true)
        }

        var suppressionsResponse = try call(handle, ["cmd": "suppressions", "serverId": server.id])
        var rows = try XCTUnwrap(suppressionsResponse["payload"] as? [[String: Any]])
        XCTAssertEqual(Set(rows.compactMap { $0["scope"] as? String }), ["track", "artist"])
        XCTAssertTrue(rows.contains { $0["ref"] as? String == "ar1-0" && ($0["createdAt"] as? Double) != nil })

        let unsuppressTrack = try call(handle, ["cmd": "unsuppressTrack", "serverId": server.id, "remoteId": "ar1-0"])
        XCTAssertEqual((unsuppressTrack["payload"] as? [String: Any])?["ok"] as? Bool, true)
        let unsuppressArtist = try call(handle, ["cmd": "unsuppressArtist", "serverId": server.id, "remoteId": "ar2"])
        XCTAssertEqual((unsuppressArtist["payload"] as? [String: Any])?["ok"] as? Bool, true)

        suppressionsResponse = try call(handle, ["cmd": "suppressions", "serverId": server.id])
        rows = try XCTUnwrap(suppressionsResponse["payload"] as? [[String: Any]])
        XCTAssertTrue(rows.isEmpty)
    }

    private func assertWireTrack(_ track: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(track["id"] as? Int, file: file, line: line)
        XCTAssertNotNil(track["remoteId"] as? String, file: file, line: line)
        XCTAssertNotNil(track["serverId"] as? String, file: file, line: line)
        XCTAssertNotNil(track["title"] as? String, file: file, line: line)
        XCTAssertNotNil(track["artistName"] as? String, file: file, line: line)
        if let albumTitle = track["albumTitle"] { XCTAssertTrue(albumTitle is String, file: file, line: line) }
        if let albumRemoteId = track["albumRemoteId"] { XCTAssertTrue(albumRemoteId is String, file: file, line: line) }
        if let trackNumber = track["trackNumber"] { XCTAssertTrue(trackNumber is Int, file: file, line: line) }
        if let discNumber = track["discNumber"] { XCTAssertTrue(discNumber is Int, file: file, line: line) }
        XCTAssertNotNil(track["durationSeconds"] as? Double, file: file, line: line)
        if let artworkKey = track["artworkKey"] { XCTAssertTrue(artworkKey is String, file: file, line: line) }
        XCTAssertNotNil(track["isFavorite"] as? Bool, file: file, line: line)
        if let gain = track["normalizationGainDB"] { XCTAssertTrue(gain is Double, file: file, line: line) }
    }
}
