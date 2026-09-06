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
            "mozzWeeklyTracks", "mozzWeeklyItems", "radioBatch",
            "radioStart", "radioNext", "radioStop", "radioState", "suppressTrack",
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

    // MARK: Stations
    //
    // The stateful half of radio. A shell driving these keeps no seed, no
    // seen-set and no tier logic of its own, which is the whole reason they
    // exist - three shells owning that state is three shells that can drift
    // into playing different music from the same seed.

    func testAStationStartsFromATrackAndKeepsGoing() async throws {
        let path = try makeLibrary()
        try await seedLibrary(at: path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let started = try call(handle, [
            "cmd": "radioStart", "serverId": server.id, "remoteId": "ar1-0", "limit": 5,
        ])
        XCTAssertEqual(started["ok"] as? Bool, true, "\(started)")
        let first = try XCTUnwrap(started["payload"] as? [String: Any])
        let firstIds = try XCTUnwrap(first["remoteIds"] as? [String])
        let firstTracks = try XCTUnwrap(first["tracks"] as? [[String: Any]])
        XCTAssertFalse(firstIds.isEmpty)
        XCTAssertEqual(firstIds.count, firstTracks.count)
        XCTAssertFalse(firstIds.contains("ar1-0"),
                       "the shell plays the seed itself; the batch is what follows")
        assertWireTrack(firstTracks[0])

        // The client says nothing about what it already played: the station
        // remembers. That is the entire difference from `radioBatch`.
        let continued = try call(handle, ["cmd": "radioNext", "limit": 5])
        XCTAssertEqual(continued["ok"] as? Bool, true, "\(continued)")
        let second = try XCTUnwrap(continued["payload"] as? [String: Any])
        let secondIds = try XCTUnwrap(second["remoteIds"] as? [String])
        XCTAssertTrue(Set(firstIds).isDisjoint(with: Set(secondIds)),
                      "a station that repeats itself is not endless")
    }

    func testAStationReportsAndForgetsItself() async throws {
        let path = try makeLibrary()
        try await seedLibrary(at: path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let before = try XCTUnwrap(
            try call(handle, ["cmd": "radioState"])["payload"] as? [String: Any])
        XCTAssertEqual(before["active"] as? Bool, false)

        // No `artist` row exists in this fixture on purpose: a catalog synced
        // tracks-first has tracks and no artists, and a station must still start.
        let startResponse = try call(handle, [
            "cmd": "radioStart", "serverId": server.id, "artistRemoteId": "ar1", "limit": 4,
        ])
        XCTAssertEqual(startResponse["ok"] as? Bool, true, "\(startResponse)")
        let during = try XCTUnwrap(
            try call(handle, ["cmd": "radioState"])["payload"] as? [String: Any])
        XCTAssertEqual(during["active"] as? Bool, true)
        XCTAssertEqual(during["title"] as? String, "Nirvana")
        XCTAssertEqual(during["serverId"] as? String, server.id)
        XCTAssertEqual(during["surfaced"] as? Int, 4)

        let stopped = try call(handle, ["cmd": "radioStop"])
        XCTAssertEqual((stopped["payload"] as? [String: Any])?["ok"] as? Bool, true)

        let after = try XCTUnwrap(
            try call(handle, ["cmd": "radioState"])["payload"] as? [String: Any])
        XCTAssertEqual(after["active"] as? Bool, false)
    }

    func testToppingUpWithNoStationIsAnEmptyAnswerNotAnError() async throws {
        let path = try makeLibrary()
        try await seedLibrary(at: path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        // A shell tops up its queue on a timer; asking when nothing is playing
        // from a station is routine, not a mistake worth an error.
        let response = try call(handle, ["cmd": "radioNext", "limit": 5])
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let payload = try XCTUnwrap(response["payload"] as? [String: Any])
        XCTAssertEqual((payload["remoteIds"] as? [String])?.isEmpty, true)
    }

    func testStartingAStationFromATrackTheLibraryLacksFails() async throws {
        let path = try makeLibrary()
        try await seedLibrary(at: path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, [
            "cmd": "radioStart", "serverId": server.id, "remoteId": "no-such-track",
        ])
        XCTAssertEqual(response["ok"] as? Bool, false, "\(response)")
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
        // Asserted present rather than merely well-typed. This field was absent
        // from the wire entirely, so every shell but the Apple one saw null and
        // silently hid "go to artist" and "don't recommend this artist" — a
        // capability missing from three platforms because of one omitted line.
        XCTAssertNotNil(track["artistRemoteId"] as? String, file: file, line: line)
        if let trackNumber = track["trackNumber"] { XCTAssertTrue(trackNumber is Int, file: file, line: line) }
        if let discNumber = track["discNumber"] { XCTAssertTrue(discNumber is Int, file: file, line: line) }
        XCTAssertNotNil(track["durationSeconds"] as? Double, file: file, line: line)
        if let artworkKey = track["artworkKey"] { XCTAssertTrue(artworkKey is String, file: file, line: line) }
        XCTAssertNotNil(track["isFavorite"] as? Bool, file: file, line: line)
        if let gain = track["normalizationGainDB"] { XCTAssertTrue(gain is Double, file: file, line: line) }
    }
}
