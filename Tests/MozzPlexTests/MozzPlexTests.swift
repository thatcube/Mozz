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
    }

    func testCheckPinReturnsToken() async throws {
        let token = try await makeAuthenticator().checkPin(id: 424242)
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
}
