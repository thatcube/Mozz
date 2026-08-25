import XCTest
import Foundation
import MozzCore
import MozzDatabase
@testable import MozzFFI

final class MozzSessionDetailTests: XCTestCase {
    private let server = ServerConnection(
        id: "srv",
        kind: .jellyfin,
        name: "Server",
        baseURL: URL(string: "https://music.example.com")!,
        clientIdentifier: "client"
    )

    private func makeLibrary() throws -> String {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/mozz-session-detail-\(UUID().uuidString)", isDirectory: true)
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

    private func seedDetailFixture(at path: String) async throws {
        let db = try MusicDatabase.open(at: URL(fileURLWithPath: path))
        let writer = CatalogWriter(db)
        let plays = PlayEventStore(db)
        try await writer.saveServer(server)
        try await writer.upsertArtists([
            Artist(
                id: "ar1",
                name: "Featured Artist",
                sortName: "Featured, Artist",
                artwork: ArtworkRef(key: "artist-art"),
                albumCount: 1,
                genres: ["Pop"],
                isFavorite: true
            ),
            Artist(id: "ar2", name: "Host Artist", sortName: "Host, Artist"),
            Artist(id: "ar3", name: "No Art Artist", sortName: "No Art"),
        ], serverId: server.id)
        try await writer.upsertAlbums([
            Album(
                id: "own",
                title: "Own Album",
                sortTitle: "Own Album",
                artistName: "Featured Artist",
                artistID: "ar1",
                year: 2024,
                artwork: ArtworkRef(key: "own-art"),
                trackCount: 2,
                genres: ["Pop"],
                isFavorite: true,
                addedAt: Date(timeIntervalSince1970: 123)
            ),
            Album(
                id: "appears",
                title: "Host Album",
                sortTitle: "Host Album",
                artistName: "Host Artist",
                artistID: "ar2",
                year: 2023,
                artwork: ArtworkRef(key: "host-art"),
                trackCount: 2,
                genres: ["Rock"],
                isFavorite: false,
                addedAt: Date(timeIntervalSince1970: 456)
            ),
            Album(
                id: "fallback",
                title: "Fallback Cover",
                artistName: "No Art Artist",
                artistID: "ar3",
                artwork: ArtworkRef(key: "fallback-art"),
                trackCount: 4
            ),
        ], serverId: server.id)
        try await writer.upsertTracks([
            Track(id: "own1", title: "Own One", albumTitle: "Own Album", albumID: "own",
                  artistName: "Featured Artist", artistID: "ar1", trackNumber: 1, duration: 180),
            Track(id: "own2", title: "Own Two", albumTitle: "Own Album", albumID: "own",
                  artistName: "Featured Artist", artistID: "ar1", trackNumber: 2, duration: 181),
            Track(id: "feat", title: "Feature", albumTitle: "Host Album", albumID: "appears",
                  artistName: "Featured Artist", artistID: "ar1", albumArtistName: "Host Artist",
                  trackNumber: 1, duration: 182),
            Track(id: "host", title: "Host Song", albumTitle: "Host Album", albumID: "appears",
                  artistName: "Host Artist", artistID: "ar2", trackNumber: 2, duration: 183),
            Track(id: "fallback-track", title: "Fallback Song", albumTitle: "Fallback Cover", albumID: "fallback",
                  artistName: "No Art Artist", artistID: "ar3", trackNumber: 1, duration: 184),
        ], serverId: server.id)

        try await plays.append(PlayEvent(trackID: "own2", kind: .completed), serverId: server.id)
        try await plays.append(PlayEvent(trackID: "own2", kind: .started), serverId: server.id)
        try await plays.append(PlayEvent(trackID: "own1", kind: .completed), serverId: server.id)
    }

    func testDetailCommandNamesAreListedForHelpfulErrors() {
        let commands = Set(mozzSessionCommands)
        for cmd in ["artist", "album", "artistTopTracks", "artistAppearsOn", "albumReleaseKind"] {
            XCTAssertTrue(commands.contains(cmd), "\(cmd) missing from mozzSessionCommands")
        }
    }

    func testArtistAndAlbumHeadersRoundTripTheSpecifiedJSONFields() async throws {
        let path = try makeLibrary()
        try await seedDetailFixture(at: path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let artistResponse = try call(handle, ["cmd": "artist", "serverId": server.id, "remoteId": "ar1"])
        XCTAssertEqual(artistResponse["ok"] as? Bool, true, "\(artistResponse)")
        let artist = try XCTUnwrap(artistResponse["payload"] as? [String: Any])
        XCTAssertEqual(Set(artist.keys), ["remoteId", "serverId", "name", "sortName", "artworkKey", "heroArtworkKey", "albumCount", "genres", "isFavorite"])
        XCTAssertEqual(artist["remoteId"] as? String, "ar1")
        XCTAssertEqual(artist["serverId"] as? String, server.id)
        XCTAssertEqual(artist["name"] as? String, "Featured Artist")
        XCTAssertEqual(artist["sortName"] as? String, "Featured, Artist")
        XCTAssertEqual(artist["artworkKey"] as? String, "artist-art")
        XCTAssertEqual(artist["heroArtworkKey"] as? String, "artist-art")
        XCTAssertEqual(artist["albumCount"] as? Int, 1)
        XCTAssertEqual(artist["genres"] as? [String], ["Pop"])
        XCTAssertEqual(artist["isFavorite"] as? Bool, true)

        let fallbackResponse = try call(handle, ["cmd": "artist", "serverId": server.id, "remoteId": "ar3"])
        let fallbackArtist = try XCTUnwrap(fallbackResponse["payload"] as? [String: Any])
        XCTAssertTrue(fallbackArtist["artworkKey"] is NSNull)
        XCTAssertEqual(fallbackArtist["heroArtworkKey"] as? String, "fallback-art")

        let albumResponse = try call(handle, ["cmd": "album", "serverId": server.id, "remoteId": "own"])
        XCTAssertEqual(albumResponse["ok"] as? Bool, true, "\(albumResponse)")
        let album = try XCTUnwrap(albumResponse["payload"] as? [String: Any])
        XCTAssertEqual(Set(album.keys), ["remoteId", "serverId", "title", "sortTitle", "artistName", "artistRemoteId", "year", "artworkKey", "trackCount", "genres", "isFavorite", "addedAt"])
        XCTAssertEqual(album["remoteId"] as? String, "own")
        XCTAssertEqual(album["serverId"] as? String, server.id)
        XCTAssertEqual(album["title"] as? String, "Own Album")
        XCTAssertEqual(album["sortTitle"] as? String, "Own Album")
        XCTAssertEqual(album["artistName"] as? String, "Featured Artist")
        XCTAssertEqual(album["artistRemoteId"] as? String, "ar1")
        XCTAssertEqual(album["year"] as? Int, 2024)
        XCTAssertEqual(album["artworkKey"] as? String, "own-art")
        XCTAssertEqual(album["trackCount"] as? Int, 2)
        XCTAssertEqual(album["genres"] as? [String], ["Pop"])
        XCTAssertEqual(album["isFavorite"] as? Bool, true)
        XCTAssertEqual(album["addedAt"] as? Double, 123)
    }

    func testArtistTopTracksAndAppearsOnRoundTripTheSpecifiedJSONFields() async throws {
        let path = try makeLibrary()
        try await seedDetailFixture(at: path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let topResponse = try call(handle, [
            "cmd": "artistTopTracks", "serverId": server.id, "artistRemoteId": "ar1", "limit": 2,
        ])
        XCTAssertEqual(topResponse["ok"] as? Bool, true, "\(topResponse)")
        let tracks = try XCTUnwrap(topResponse["payload"] as? [[String: Any]])
        XCTAssertEqual(tracks.map { $0["remoteId"] as? String }, ["own2", "own1"])
        XCTAssertTrue(Set(["id", "remoteId", "serverId", "title", "artistName", "albumTitle", "albumRemoteId", "trackNumber", "discNumber", "durationSeconds", "artworkKey", "isFavorite", "normalizationGainDB"]).isSuperset(of: tracks[0].keys))

        let appearsResponse = try call(handle, [
            "cmd": "artistAppearsOn", "serverId": server.id, "artistRemoteId": "ar1", "limit": 20, "after": NSNull(),
        ])
        XCTAssertEqual(appearsResponse["ok"] as? Bool, true, "\(appearsResponse)")
        let page = try XCTUnwrap(appearsResponse["payload"] as? [String: Any])
        XCTAssertEqual(Set(page.keys), ["items", "nextCursor"])
        XCTAssertTrue(page["nextCursor"] is NSNull)
        let albums = try XCTUnwrap(page["items"] as? [[String: Any]])
        XCTAssertEqual(albums.map { $0["remoteId"] as? String }, ["appears"])
        XCTAssertEqual(Set(albums[0].keys), ["remoteId", "serverId", "title", "sortTitle", "artistName", "artistRemoteId", "year", "artworkKey", "trackCount", "genres", "isFavorite", "addedAt"])
    }

    func testAlbumReleaseKindUsesTheSharedClassifierThroughFFI() throws {
        let path = try makeLibrary()
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, [
            "cmd": "albumReleaseKind", "trackCount": 3,
        ])
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let payload = try XCTUnwrap(response["payload"] as? [String: Any])
        XCTAssertEqual(payload["kind"] as? String, "singleOrEP")
        XCTAssertEqual(payload["isSingleOrEP"] as? Bool, true)

        let unknown = try call(handle, ["cmd": "albumReleaseKind"])
        let unknownPayload = try XCTUnwrap(unknown["payload"] as? [String: Any])
        XCTAssertEqual(unknownPayload["kind"] as? String, "album")
        XCTAssertEqual(unknownPayload["isSingleOrEP"] as? Bool, false)
    }
}
