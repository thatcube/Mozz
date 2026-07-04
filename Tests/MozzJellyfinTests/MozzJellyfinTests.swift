import XCTest
import Foundation
import MozzCore
import MozzNetworking
@testable import MozzJellyfin

/// Serves recorded JSON fixtures for requests whose URL contains a route's
/// match string, so provider decode + URL building can be tested with no real
/// server. Routes are tried in order; the first containment match wins.
final class FixtureTransport: HTTPTransport, @unchecked Sendable {
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
        kind: .jellyfin,
        name: "Home",
        baseURL: URL(string: "https://jf.example.com")!,
        userID: "user1",
        clientIdentifier: "client-uuid"
    )
}

private let catalogTransport = FixtureTransport([
    .init(contains: "/Artists", fixture: "jf_artists"),
    .init(contains: "IncludeItemTypes=MusicAlbum", fixture: "jf_albums"),
    .init(contains: "IncludeItemTypes=Audio", fixture: "jf_tracks"),
    .init(contains: "IncludeItemTypes=Playlist", fixture: "jf_playlists"),
    .init(contains: "System/Info/Public", fixture: "jf_system_info"),
])

private func makeBackend(_ transport: FixtureTransport = catalogTransport) -> JellyfinBackend {
    JellyfinBackend(connection: makeConnection(), token: "jf-token", clientInfo: clientInfo, transport: transport)
}

final class JellyfinCatalogTests: XCTestCase {
    func testDecodesArtists() async throws {
        let page = try await makeBackend().fetchArtists(offset: 0, limit: 50)
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.totalCount, 2)
        let first = page.items[0]
        XCTAssertEqual(first.id, "a1")
        XCTAssertEqual(first.name, "Aphex Twin")
        XCTAssertTrue(first.isFavorite)
        XCTAssertEqual(first.artwork?.key, "a1|tagA")
        XCTAssertEqual(first.genres, ["Electronic", "IDM"])
    }

    func testDecodesAlbums() async throws {
        let page = try await makeBackend().fetchAlbums(offset: 0, limit: 50)
        let album = try XCTUnwrap(page.items.first)
        XCTAssertEqual(album.id, "al1")
        XCTAssertEqual(album.artistName, "Aphex Twin")
        XCTAssertEqual(album.artistID, "a1")
        XCTAssertEqual(album.year, 1992)
        XCTAssertEqual(album.trackCount, 13)
        XCTAssertEqual(album.artwork?.key, "al1|talb1")
        XCTAssertNotNil(album.addedAt)
    }

    func testDecodesTracks() async throws {
        let page = try await makeBackend().fetchTracks(offset: 0, limit: 50)
        let track = try XCTUnwrap(page.items.first)
        XCTAssertEqual(track.id, "t1")
        XCTAssertEqual(track.albumID, "al1")
        XCTAssertEqual(track.artistName, "Aphex Twin")
        XCTAssertEqual(track.trackNumber, 1)
        XCTAssertEqual(track.discNumber, 1)
        XCTAssertEqual(track.duration, 315, accuracy: 0.01)
        XCTAssertEqual(track.format.container, "flac")
        XCTAssertEqual(track.format.codec, "flac")
        XCTAssertEqual(track.format.bitrateKbps, 900)
        XCTAssertEqual(track.format.sampleRateHz, 44100)
        XCTAssertEqual(track.format.bitDepth, 16)
        XCTAssertEqual(track.fileSizeBytes, 31457280)
        XCTAssertEqual(track.mediaKey, "t1")
        XCTAssertEqual(track.normalizationGainDB, -6.5)
        XCTAssertEqual(track.artwork?.key, "t1|ttrk1")
        XCTAssertTrue(track.isFavorite)
    }

    func testDecodesPlaylists() async throws {
        let page = try await makeBackend().fetchPlaylists(offset: 0, limit: 50)
        let playlist = try XCTUnwrap(page.items.first)
        XCTAssertEqual(playlist.id, "pl1")
        XCTAssertEqual(playlist.title, "Late Night")
        XCTAssertEqual(playlist.trackCount, 42)
    }

    func testDetectsCapabilities() async throws {
        let capabilities = try await makeBackend().detectCapabilities()
        XCTAssertEqual(capabilities.backend, .jellyfin)
        XCTAssertEqual(capabilities.serverVersion, "10.9.11")
        XCTAssertTrue(capabilities.supportsFavorites)
        XCTAssertTrue(capabilities.supportsSyncedLyrics)
        XCTAssertTrue(capabilities.supportsNormalizationGain)
    }

    func testSendsAuthorizationHeader() async throws {
        _ = try await makeBackend().fetchArtists(offset: 0, limit: 1)
        let header = catalogTransport.lastRequest?.value(forHTTPHeaderField: "Authorization")
        XCTAssertNotNil(header)
        XCTAssertTrue(header?.contains("MediaBrowser") == true)
        XCTAssertTrue(header?.contains("Token=\"jf-token\"") == true)
        XCTAssertTrue(header?.contains("DeviceId=\"client-uuid\"") == true)
    }
}

final class JellyfinURLTests: XCTestCase {
    private let track = Track(id: "t1", title: "Xtal", artistName: "Aphex Twin", mediaKey: "t1")

    func testStreamURLDirect() async throws {
        let source = try await makeBackend().streamSource(for: track, options: .bestAvailable)
        let string = source.url.absoluteString
        XCTAssertTrue(string.contains("/Audio/t1/universal"))
        XCTAssertTrue(string.contains("api_key=jf-token"))
        XCTAssertTrue(string.contains("PlaySessionId="))
        XCTAssertFalse(source.isTranscoded)
        XCTAssertNotNil(source.sessionID)
    }

    func testStreamURLTranscodeWhenBitrateCapped() async throws {
        let source = try await makeBackend().streamSource(for: track, options: StreamOptions(maxBitrateKbps: 192))
        XCTAssertTrue(source.isTranscoded)
        XCTAssertTrue(source.url.absoluteString.contains("MaxStreamingBitrate=192000"))
    }

    func testOriginalFileURL() throws {
        let url = try makeBackend().originalFileURL(for: track)
        let string = url.absoluteString
        XCTAssertTrue(string.contains("/Items/t1/Download"))
        XCTAssertTrue(string.contains("api_key=jf-token"))
    }

    func testArtworkURL() throws {
        let url = try XCTUnwrap(makeBackend().artworkURL(for: ArtworkRef(key: "t1|ttrk1"), size: 300))
        let string = url.absoluteString
        XCTAssertTrue(string.contains("/Items/t1/Images/Primary"))
        XCTAssertTrue(string.contains("tag=ttrk1"))
        XCTAssertTrue(string.contains("fillWidth=300"))
        XCTAssertTrue(string.contains("api_key=jf-token"))
    }
}

final class JellyfinAuthTests: XCTestCase {
    private let authTransport = FixtureTransport([
        .init(contains: "QuickConnect/Initiate", fixture: "jf_quickconnect_initiate"),
        .init(contains: "QuickConnect/Connect", fixture: "jf_quickconnect_state_true"),
        .init(contains: "AuthenticateWithQuickConnect", fixture: "jf_auth_result"),
        .init(contains: "System/Info/Public", fixture: "jf_system_info"),
    ])

    private func makeAuthenticator() -> JellyfinAuthenticator {
        JellyfinAuthenticator(
            baseURL: URL(string: "https://jf.example.com")!,
            clientInfo: clientInfo,
            clientIdentifier: "client-uuid",
            transport: authTransport
        )
    }

    func testInitiateQuickConnect() async throws {
        let session = try await makeAuthenticator().initiateQuickConnect()
        XCTAssertEqual(session.secret, "SECRET123")
        XCTAssertEqual(session.code, "123456")
    }

    func testQuickConnectApproved() async throws {
        let approved = try await makeAuthenticator().isQuickConnectApproved(secret: "SECRET123")
        XCTAssertTrue(approved)
    }

    func testCompleteQuickConnectProducesSession() async throws {
        let session = try await makeAuthenticator().completeQuickConnect(secret: "SECRET123")
        XCTAssertEqual(session.kind, .jellyfin)
        XCTAssertEqual(session.token, "jf-token-xyz")
        XCTAssertEqual(session.userID, "user1")
        XCTAssertEqual(session.serverName, "Home Jellyfin")
    }
}
