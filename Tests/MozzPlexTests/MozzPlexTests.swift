import XCTest
import Foundation
import MozzCore
import MozzNetworking
@testable import MozzPlex

/// Fixture-serving transport (same idea as the Jellyfin tests): first route
/// whose match string is contained in the request URL wins.
final class PlexFixtureTransport: HTTPTransport, @unchecked Sendable {
    struct Route { let contains: String; let fixture: String }

    private let routes: [Route]
    private let lock = NSLock()
    private var _last: URLRequest?

    init(_ routes: [Route]) { self.routes = routes }

    var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return _last
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); _last = request; lock.unlock()
        let string = request.url?.absoluteString ?? ""
        let fallbackURL = request.url ?? URL(string: "https://example.com")!
        guard
            let route = routes.first(where: { string.contains($0.contains) }),
            let url = Bundle.module.url(forResource: route.fixture, withExtension: "json", subdirectory: "Fixtures"),
            let data = try? Data(contentsOf: url)
        else {
            return (Data(), HTTPURLResponse(url: fallbackURL, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        return (data, HTTPURLResponse(url: fallbackURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// A transport that fakes an `artist` library per section id, honoring
/// `X-Plex-Container-Start`/`Size` and capping items per response — so
/// multi-section pagination (including short pages and boundary spans) can be
/// exercised end to end.
final class PlexPagingTransport: HTTPTransport, @unchecked Sendable {
    private let sectionSizes: [String: Int]
    private let maxPageSize: Int
    init(sectionSizes: [String: Int], maxPageSize: Int) {
        self.sectionSizes = sectionSizes
        self.maxPageSize = maxPageSize
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        // Path: /library/sections/{id}/all
        let segments = url.path.split(separator: "/").map(String.init)
        let section = segments.count >= 3 ? segments[2] : ""
        let query = comps.queryItems ?? []
        func intQuery(_ name: String) -> Int { Int(query.first { $0.name == name }?.value ?? "") ?? 0 }
        let start = intQuery("X-Plex-Container-Start")
        let size = intQuery("X-Plex-Container-Size")
        let total = sectionSizes[section] ?? 0
        let count = max(0, min(min(size, maxPageSize), total - start))
        let metadata = (0..<count).map { i in
            "{\"ratingKey\":\"\(section)-\(start + i)\",\"type\":\"artist\",\"title\":\"\(section) \(start + i)\",\"titleSort\":\"\(section) \(start + i)\"}"
        }.joined(separator: ",")
        let json = "{\"MediaContainer\":{\"size\":\(count),\"totalSize\":\(total),\"offset\":\(start),\"Metadata\":[\(metadata)]}}"
        return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private let clientInfo = ClientInfo(
    product: "Mozz", version: "1.0", deviceName: "iPhone", platform: "iOS", platformVersion: "17.0"
)

private func makeConnection() -> ServerConnection {
    ServerConnection(
        id: "srv",
        kind: .plex,
        name: "Home",
        baseURL: URL(string: "https://plex.example.com")!,
        userID: nil,
        clientIdentifier: "client-uuid",
        musicSectionID: "3"
    )
}

private let catalogTransport = PlexFixtureTransport([
    .init(contains: "all?type=10", fixture: "plex_tracks"),
    .init(contains: "all?type=9", fixture: "plex_albums"),
    .init(contains: "all?type=8", fixture: "plex_artists"),
    .init(contains: "library/sections", fixture: "plex_sections"),
])

private func makeBackend(_ transport: any HTTPTransport = catalogTransport) -> PlexBackend {
    PlexBackend(connection: makeConnection(), token: "plex-token", clientInfo: clientInfo, transport: transport)
}

final class PlexCatalogTests: XCTestCase {
    func testDecodesArtists() async throws {
        let page = try await makeBackend().fetchArtists(offset: 0, limit: 50)
        XCTAssertEqual(page.totalCount, 1)
        let artist = try XCTUnwrap(page.items.first)
        XCTAssertEqual(artist.id, "1001")
        XCTAssertEqual(artist.name, "Boards of Canada")
        XCTAssertEqual(artist.albumCount, 3)
        XCTAssertEqual(artist.artwork?.key, "/library/metadata/1001/thumb/1600000000")
        XCTAssertEqual(artist.genres, ["IDM", "Electronic"])
    }

    func testFetchArtistsSpansMultipleMusicSections() async throws {
        // A server with two music libraries: a sync must span BOTH into one
        // catalog and report the combined total (so pruning sees the true count).
        let transport = PlexFixtureTransport([
            .init(contains: "sections/secA/", fixture: "plex_artists"),
            .init(contains: "sections/secB/", fixture: "plex_artists_b"),
        ])
        let connection = ServerConnection(
            id: "srv", kind: .plex, name: "Home",
            baseURL: URL(string: "https://plex.example.com")!,
            userID: nil, clientIdentifier: "client-uuid", musicSectionID: "secA")
        let backend = PlexBackend(connection: connection, token: "t", clientInfo: clientInfo,
                                  transport: transport, musicSectionIDs: ["secA", "secB"])
        let page = try await backend.fetchArtists(offset: 0, limit: 200)
        XCTAssertEqual(page.items.map(\.name), ["Boards of Canada", "Aphex Twin"])
        XCTAssertEqual(page.totalCount, 2)
    }

    func testMultiSectionPaginationCoversEveryItemAcrossShortPages() async throws {
        // Two music libraries (A: 3 artists, B: 2), a small page size AND a server
        // that returns short pages. Driving the paging exactly as LibrarySyncEngine
        // does must visit every item once, span the A→B boundary, and terminate.
        let transport = PlexPagingTransport(sectionSizes: ["secA": 3, "secB": 2], maxPageSize: 2)
        let connection = ServerConnection(
            id: "srv", kind: .plex, name: "Home",
            baseURL: URL(string: "https://plex.example.com")!,
            userID: nil, clientIdentifier: "client-uuid", musicSectionID: "secA")
        let backend = PlexBackend(connection: connection, token: "t", clientInfo: clientInfo,
                                  transport: transport, musicSectionIDs: ["secA", "secB"])

        var seen: [String] = []
        var offset = 0
        while true {
            let page = try await backend.fetchArtists(offset: offset, limit: 2)
            XCTAssertEqual(page.totalCount, 5, "combined total spans both sections")
            if page.items.isEmpty { break }
            seen.append(contentsOf: page.items.map(\.id))
            offset += page.items.count
            XCTAssertLessThan(offset, 20, "paging must terminate")
        }
        XCTAssertEqual(seen.sorted(), ["secA-0", "secA-1", "secA-2", "secB-0", "secB-1"])
        XCTAssertEqual(Set(seen).count, seen.count, "no duplicates across the section boundary")
    }

    func testDecodesAlbums() async throws {
        let page = try await makeBackend().fetchAlbums(offset: 0, limit: 50)
        let album = try XCTUnwrap(page.items.first)
        XCTAssertEqual(album.id, "2001")
        XCTAssertEqual(album.title, "Music Has the Right to Children")
        XCTAssertEqual(album.artistName, "Boards of Canada")
        XCTAssertEqual(album.artistID, "1001")
        XCTAssertEqual(album.year, 1998)
        XCTAssertEqual(album.trackCount, 17)
        XCTAssertNotNil(album.addedAt)
    }

    func testDecodesTracks() async throws {
        let page = try await makeBackend().fetchTracks(offset: 0, limit: 50)
        let track = try XCTUnwrap(page.items.first)
        XCTAssertEqual(track.id, "3001")
        XCTAssertEqual(track.albumTitle, "Music Has the Right to Children")
        XCTAssertEqual(track.albumID, "2001")
        XCTAssertEqual(track.artistName, "Boards of Canada")
        XCTAssertEqual(track.artistID, "1001")
        XCTAssertEqual(track.trackNumber, 8)
        XCTAssertEqual(track.discNumber, 1)
        XCTAssertEqual(track.duration, 161, accuracy: 0.01)
        XCTAssertEqual(track.format.codec, "flac")
        XCTAssertEqual(track.format.bitrateKbps, 900)
        XCTAssertEqual(track.format.channels, 2)
        XCTAssertEqual(track.mediaKey, "/library/parts/5001/1600000000/file.flac")
        XCTAssertEqual(track.fileSizeBytes, 18874368)
    }

    func testResolvesMusicSections() async throws {
        let sections = try await makeBackend().musicSections()
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.id, "3")
        XCTAssertEqual(sections.first?.title, "Music")
    }

    func testAllLibrarySectionsForDiagnostics() async throws {
        // Diagnostics path (used when no music section is found) must surface
        // EVERY section with its type, not just the artist ones.
        let all = try await makeBackend().allLibrarySections()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.map(\.type), ["artist", "movie"])
        XCTAssertEqual(all.map(\.title), ["Music", "Movies"])
    }

    func testDetectsCapabilities() async throws {
        let transport = PlexFixtureTransport([.init(contains: "plex.example.com", fixture: "plex_identity")])
        let capabilities = try await makeBackend(transport).detectCapabilities()
        XCTAssertEqual(capabilities.backend, .plex)
        XCTAssertEqual(capabilities.serverVersion, "1.40.1.8227-abc")
        XCTAssertFalse(capabilities.supportsFavorites)
        XCTAssertTrue(capabilities.supportsProgressReporting)
    }
}

final class PlexURLTests: XCTestCase {
    private let track = Track(
        id: "3001", title: "Roygbiv", artistName: "Boards of Canada",
        duration: 161, mediaKey: "/library/parts/5001/1600000000/file.flac"
    )

    func testStreamURLDirectPlay() async throws {
        let source = try await makeBackend().streamSource(for: track, options: .bestAvailable)
        let string = source.url.absoluteString
        XCTAssertTrue(string.contains("/library/parts/5001/1600000000/file.flac"))
        XCTAssertTrue(string.contains("X-Plex-Token=plex-token"))
        XCTAssertFalse(source.isTranscoded)
    }

    func testStreamURLTranscode() async throws {
        let source = try await makeBackend().streamSource(for: track, options: StreamOptions(maxBitrateKbps: 256))
        let string = source.url.absoluteString
        XCTAssertTrue(string.contains("transcode/universal"))
        XCTAssertTrue(string.contains("maxAudioBitrate=256"))
        XCTAssertTrue(source.isTranscoded)
        XCTAssertNotNil(source.sessionID)
    }

    func testOriginalFileURL() throws {
        let url = try makeBackend().originalFileURL(for: track)
        let string = url.absoluteString
        XCTAssertTrue(string.contains("/library/parts/5001/1600000000/file.flac"))
        XCTAssertTrue(string.contains("download=1"))
        XCTAssertTrue(string.contains("X-Plex-Token=plex-token"))
    }

    func testArtworkURL() throws {
        let url = try XCTUnwrap(makeBackend().artworkURL(for: ArtworkRef(key: "/library/metadata/2001/thumb/1"), size: 200))
        let string = url.absoluteString
        XCTAssertTrue(string.contains("photo/:/transcode"))
        XCTAssertTrue(string.contains("width=200"))
        XCTAssertTrue(string.contains("X-Plex-Token=plex-token"))
    }

    func testSetRatingIssuesRateRequest() async throws {
        // Plex has no boolean favorite; a rating is written via `/:/rate` with
        // the value on Plex's 0–10 scale (4★ → 8). The mock 404s on this path,
        // but the outgoing request (what we're testing) is still captured.
        let transport = PlexFixtureTransport([])
        _ = try? await makeBackend(transport).setRating(4, itemID: "3001", type: .track)
        let url = try XCTUnwrap(transport.lastRequest?.url?.absoluteString)
        XCTAssertTrue(url.contains(":/rate"), "expected the rate endpoint, got \(url)")
        XCTAssertTrue(url.contains("key=3001"))
        XCTAssertTrue(url.contains("rating=8"), "4★ should map to Plex rating 8, got \(url)")
        XCTAssertTrue(url.contains("identifier=com.plexapp.plugins.library"))
    }

    func testSetFavoriteMapsToFiveStarRating() async throws {
        // On Plex a "like" is expressed as 5★ (rating 10); "unlike" clears it (0).
        let transport = PlexFixtureTransport([])
        _ = try? await makeBackend(transport).setFavorite(true, itemID: "3001", type: .track)
        XCTAssertTrue(try XCTUnwrap(transport.lastRequest?.url?.absoluteString).contains("rating=10"))

        let clearTransport = PlexFixtureTransport([])
        _ = try? await makeBackend(clearTransport).setFavorite(false, itemID: "3001", type: .track)
        XCTAssertTrue(try XCTUnwrap(clearTransport.lastRequest?.url?.absoluteString).contains("rating=0"))
    }
}

final class PlexAuthTests: XCTestCase {
    private let authTransport = PlexFixtureTransport([
        .init(contains: "api/v2/pins/", fixture: "plex_pin_claimed"),
        .init(contains: "api/v2/pins", fixture: "plex_pin_claimed"),
        .init(contains: "api/v2/resources", fixture: "plex_resources"),
        .init(contains: "library/sections", fixture: "plex_sections"),
        .init(contains: "identity", fixture: "plex_identity"),
    ])

    private func makeAuthenticator() -> PlexAuthenticator {
        PlexAuthenticator(clientInfo: clientInfo, clientIdentifier: "client-uuid", transport: authTransport)
    }

    func testRequestPin() async throws {
        let session = try await makeAuthenticator().requestPin()
        XCTAssertEqual(session.id, 424242)
        XCTAssertEqual(session.code, "abcd")
        XCTAssertEqual(session.clientIdentifier, "client-uuid")
        // The hosted app.plex.tv/auth flow can only claim STRONG pins; a
        // strong=false short code fails with "unable to complete this request".
        XCTAssertTrue(authTransport.lastRequest?.url?.absoluteString.contains("strong=true") ?? false,
                      "PIN must be requested with strong=true for the hosted OAuth flow")
    }

    func testCheckPinReturnsToken() async throws {
        let token = try await makeAuthenticator().checkPin(id: 424242, code: "abcd")
        XCTAssertEqual(token, "plex-account-token")
    }

    func testDiscoverConnectionsSortsLocalFirst() async throws {
        let connections = try await makeAuthenticator().discoverConnections(accountToken: "acct")
        XCTAssertEqual(connections.count, 2, "player-only resource is filtered out")
        XCTAssertTrue(connections[0].isLocal)
        XCTAssertFalse(connections[0].isRelay)
        XCTAssertTrue(connections[1].isRelay)
        XCTAssertEqual(connections[0].accessToken, "server-token-1")
    }

    func testCompleteLoginPicksReachableConnection() async throws {
        let session = try await makeAuthenticator().completeLogin(accountToken: "acct")
        XCTAssertEqual(session.kind, .plex)
        XCTAssertEqual(session.token, "server-token-1")
        XCTAssertEqual(session.serverName, "Home Plex")
        XCTAssertTrue(session.baseURL.absoluteString.contains("plex.direct"))
    }

    func testPrefersServerThatHasMusic() async throws {
        // Account with a movies-only box AND a music box, both reachable. Selection
        // must NOT stop at the first reachable server — it must pick the one that
        // actually has an artist library.
        let transport = PlexFixtureTransport([
            .init(contains: "movies-box", fixture: "plex_sections_movies_only"),
            .init(contains: "music-box", fixture: "plex_sections"),
        ])
        let auth = PlexAuthenticator(clientInfo: clientInfo, clientIdentifier: "cid", transport: transport)
        let movies = PlexResourceConnection(
            serverName: "The Movies", clientIdentifier: "m1",
            uri: URL(string: "https://movies-box.plex.direct:32400")!,
            isLocal: true, isRelay: false, accessToken: "t-movies")
        let music = PlexResourceConnection(
            serverName: "The Music", clientIdentifier: "m2",
            uri: URL(string: "https://music-box.plex.direct:32400")!,
            isLocal: true, isRelay: false, accessToken: "t-music")

        let chosen = await auth.firstMusicConnection([movies, music])
        XCTAssertEqual(chosen?.serverName, "The Music")
        XCTAssertEqual(chosen?.accessToken, "t-music")
    }

    func testFallsBackToFirstReachableWhenNoServerHasMusic() async throws {
        // Only a movies box answers; nothing has music. Login must still resolve a
        // connection (the reachable one) so it doesn't dead-end — the "no music"
        // condition is reported later, at sync, with a clear message.
        let transport = PlexFixtureTransport([
            .init(contains: "movies-box", fixture: "plex_sections_movies_only"),
        ])
        let auth = PlexAuthenticator(clientInfo: clientInfo, clientIdentifier: "cid", transport: transport)
        let movies = PlexResourceConnection(
            serverName: "The Movies", clientIdentifier: "m1",
            uri: URL(string: "https://movies-box.plex.direct:32400")!,
            isLocal: true, isRelay: false, accessToken: "t-movies")
        let unreachable = PlexResourceConnection(
            serverName: "Offline", clientIdentifier: "m3",
            uri: URL(string: "https://offline-box.plex.direct:32400")!,
            isLocal: false, isRelay: true, accessToken: "t-offline")

        let chosen = await auth.firstMusicConnection([movies, unreachable])
        XCTAssertEqual(chosen?.serverName, "The Movies")
    }
}
