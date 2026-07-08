import XCTest
import Foundation
import MozzCore
import MozzNetworking
@testable import MozzSubsonic

/// Serves recorded JSON fixtures for requests whose URL contains a route's
/// match string, so DTO decode + URL building can be tested with no real
/// server. Routes are tried in order; the first containment match wins.
/// Mirrors `MozzJellyfinTests.FixtureTransport`.
final class FixtureTransport: HTTPTransport, @unchecked Sendable {
    struct Route { let contains: String; let fixture: String }

    private let routes: [Route]
    private let lock = NSLock()
    private var _last: URLRequest?
    private var _all: [URLRequest] = []

    init(_ routes: [Route]) { self.routes = routes }

    var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return _last
    }

    var allRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _all
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); _last = request; _all.append(request); lock.unlock()
        let string = request.url?.absoluteString ?? ""
        let fallbackURL = request.url ?? URL(string: "https://example.com")!
        guard
            let route = routes.first(where: { string.contains($0.contains) }),
            let url = Bundle.module.url(forResource: route.fixture, withExtension: "json", subdirectory: "Fixtures"),
            let data = try? Data(contentsOf: url)
        else {
            return (Data(), HTTPURLResponse(url: fallbackURL, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        return (data, HTTPURLResponse(url: fallbackURL, statusCode: 200, httpVersion: nil, headerFields: [
            "Content-Type": "application/json",
        ])!)
    }
}

/// A transport driven entirely by a closure — used for tests that need a
/// dynamically generated or deliberately non-JSON response (e.g. a raw XML
/// error body, or a specific HTTP status/content-type combination) rather
/// than a fixed recorded-JSON fixture file.
final class ClosureTransport: HTTPTransport, @unchecked Sendable {
    private let handler: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

    init(_ handler: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try handler(request)
    }
}

func makeSubsonicConnection(musicFolderId: String? = nil) -> ServerConnection {
    ServerConnection(
        id: "srv-subsonic",
        kind: .subsonic,
        name: "Home Navidrome",
        baseURL: URL(string: "https://music.example.com")!,
        userID: "brandon",
        clientIdentifier: "client-uuid",
        musicSectionID: musicFolderId
    )
}

/// A ready-to-decode `apiKey`-mode credential envelope, matching the shape
/// `SubsonicAuthenticator` produces — used directly (bypassing sign-in) so
/// catalog/URL tests don't depend on a live `ping`.
func apiKeyToken(_ apiKey: String = "test-api-key") -> String {
    """
    {"mode":"apiKey","username":"brandon","secret":"\(apiKey)"}
    """
}

func md5Token(secret: String = "deadbeefcafe", salt: String = "abc123") -> String {
    """
    {"mode":"md5","username":"brandon","secret":"\(secret)","salt":"\(salt)"}
    """
}

func makeSubsonicBackend(
    transport: any HTTPTransport,
    token: String = apiKeyToken(),
    musicFolderId: String? = nil
) throws -> SubsonicBackend {
    try SubsonicBackend(connection: makeSubsonicConnection(musicFolderId: musicFolderId), token: token, transport: transport)
}

private let catalogTransport = FixtureTransport([
    .init(contains: "getArtists", fixture: "sub_artists"),
    .init(contains: "getAlbumList2", fixture: "sub_album_list2"),
    .init(contains: "search3", fixture: "sub_search3"),
    .init(contains: "getPlaylist.view", fixture: "sub_playlist_detail"),
    .init(contains: "getPlaylists", fixture: "sub_playlists"),
    .init(contains: "getOpenSubsonicExtensions", fixture: "sub_extensions"),
    .init(contains: "ping", fixture: "sub_ping_ok"),
])

final class SubsonicCatalogTests: XCTestCase {
    func testDecodesArtistsWithRichFields() async throws {
        let backend = try makeSubsonicBackend(transport: catalogTransport)
        let page = try await backend.fetchArtists(offset: 0, limit: 50)
        XCTAssertEqual(page.totalCount, 2)
        let first = try XCTUnwrap(page.items.first { $0.id == "ar-a1f9" })
        XCTAssertEqual(first.name, "Aphex Twin")
        XCTAssertEqual(first.sortName, "Aphex Twin")
        XCTAssertEqual(first.albumCount, 2)
        XCTAssertTrue(first.isFavorite)
        XCTAssertEqual(first.artwork?.key, "ar-a1f9")

        let second = try XCTUnwrap(page.items.first { $0.id == "ar-b207" })
        XCTAssertFalse(second.isFavorite)
        XCTAssertNil(second.artwork)
    }

    func testDecodesAlbumsPreferringStructuredGenres() async throws {
        let backend = try makeSubsonicBackend(transport: catalogTransport)
        let page = try await backend.fetchAlbums(offset: 0, limit: 50)
        // getAlbumList2 has no total-record-count field of its own.
        XCTAssertNil(page.totalCount)
        let album = try XCTUnwrap(page.items.first { $0.id == "al-9c31" })
        XCTAssertEqual(album.title, "Selected Ambient Works 85-92")
        XCTAssertEqual(album.artistName, "Aphex Twin")
        XCTAssertEqual(album.artistID, "ar-a1f9")
        XCTAssertEqual(album.year, 1992)
        XCTAssertEqual(album.trackCount, 13)
        // genres[] (structured, OpenSubsonic) must win over the singular `genre`.
        XCTAssertEqual(album.genres, ["Ambient", "IDM"])
        XCTAssertTrue(album.isFavorite)
        XCTAssertNotNil(album.addedAt)
        XCTAssertEqual(album.artwork?.key, "al-9c31")

        let classicGenreAlbum = try XCTUnwrap(page.items.first { $0.id == "al-1120" })
        // Falls back to the singular `genre` when `genres[]` is absent.
        XCTAssertEqual(classicGenreAlbum.genres, ["Art Pop"])
        XCTAssertEqual(classicGenreAlbum.artistName, "Bjork")
    }

    func testDecodesQuickStartTracksViaSearch3() async throws {
        let backend = try makeSubsonicBackend(transport: catalogTransport)
        let page = try await backend.fetchTracks(offset: 0, limit: 50)
        // search3(query:"") is a best-effort, non-authoritative quick start —
        // it must NEVER report a total (see architecture point 2), even
        // though the fixture itself is fully decodable.
        XCTAssertNil(page.totalCount)
        let track = try XCTUnwrap(page.items.first)
        XCTAssertEqual(track.id, "sg-4471")
        XCTAssertEqual(track.title, "Xtal")
        XCTAssertEqual(track.albumID, "al-9c31")
        XCTAssertEqual(track.artistName, "Aphex Twin")
        XCTAssertEqual(track.trackNumber, 1)
        XCTAssertEqual(track.discNumber, 1)
        XCTAssertEqual(track.duration, 315, accuracy: 0.01)
        XCTAssertEqual(track.format.container, "flac")
        XCTAssertEqual(track.format.codec, "flac")
        XCTAssertEqual(track.format.bitrateKbps, 900)
        XCTAssertEqual(track.format.sampleRateHz, 44100)
        XCTAssertEqual(track.format.bitDepth, 16)
        XCTAssertEqual(track.format.channels, 2)
        XCTAssertEqual(track.fileSizeBytes, 31457280)
        XCTAssertEqual(track.mediaKey, "sg-4471")
        XCTAssertTrue(track.isFavorite)
        XCTAssertEqual(track.rating, 4)
        XCTAssertEqual(track.normalizationGainDB, -6.5)
        XCTAssertNotNil(track.addedAt)
        XCTAssertEqual(track.mbid, "d3b8e2a1-1111-4222-8333-444455556666")
        XCTAssertNil(track.artistMbid)
        XCTAssertEqual(track.artwork?.key, "al-9c31")
    }

    func testSearch3FailureDegradesToEmptyPageNotError() async throws {
        // A classic-profile server that rejects an empty-query search3 must
        // never fail the quick-start preview — it's optional and best-effort.
        let transport = FixtureTransport([]) // no routes match => 404 for everything
        let backend = try makeSubsonicBackend(transport: transport)
        let page = try await backend.fetchTracks(offset: 0, limit: 50)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.totalCount)
    }

    func testDecodesPlaylists() async throws {
        let backend = try makeSubsonicBackend(transport: catalogTransport)
        let page = try await backend.fetchPlaylists(offset: 0, limit: 50)
        XCTAssertEqual(page.totalCount, 1)
        let playlist = try XCTUnwrap(page.items.first)
        XCTAssertEqual(playlist.id, "pl-7742")
        XCTAssertEqual(playlist.title, "Late Night")
        XCTAssertEqual(playlist.trackCount, 42)
        XCTAssertEqual(playlist.durationSeconds, 9000)
        XCTAssertFalse(playlist.isSmart)
    }

    func testDecodesPlaylistItems() async throws {
        let backend = try makeSubsonicBackend(transport: catalogTransport)
        let page = try await backend.fetchPlaylistItems(playlistID: "pl-7742", offset: 0, limit: 50)
        XCTAssertEqual(page.totalCount, 2)
        XCTAssertEqual(page.items.map(\.id), ["sg-4471", "sg-9981"])
    }

    func testDetectsCapabilitiesOpenSubsonic() async throws {
        let backend = try makeSubsonicBackend(transport: catalogTransport)
        let capabilities = try await backend.detectCapabilities()
        XCTAssertEqual(capabilities.backend, .subsonic)
        XCTAssertEqual(capabilities.serverProduct, "navidrome")
        XCTAssertEqual(capabilities.serverVersion, "0.51.1 (abcdef1)")
        XCTAssertTrue(capabilities.isOpenSubsonic)
        XCTAssertTrue(capabilities.supportsFavorites)
        XCTAssertTrue(capabilities.supportsRatings)
        XCTAssertTrue(capabilities.supportsNormalizationGain)
        // Gated on the (best-effort) detected extension list.
        XCTAssertTrue(capabilities.supportsLyrics)
        XCTAssertFalse(capabilities.supportsSyncedLyrics)
    }

    func testDetectsCapabilitiesClassicServerFallback() async throws {
        // A classic-profile server: ping omits `type`/`serverVersion`/
        // `openSubsonic`, and getOpenSubsonicExtensions plain 404s. This must
        // read as "no extensions" (isOpenSubsonic = false), NOT as a failed
        // probe (architecture point 10).
        let transport = FixtureTransport([
            .init(contains: "ping", fixture: "sub_ping_classic"),
            // getOpenSubsonicExtensions intentionally has no route -> 404.
        ])
        let backend = try makeSubsonicBackend(transport: transport)
        let capabilities = try await backend.detectCapabilities()
        XCTAssertEqual(capabilities.backend, .subsonic)
        XCTAssertNil(capabilities.serverProduct)
        XCTAssertFalse(capabilities.isOpenSubsonic)
        XCTAssertFalse(capabilities.supportsLyrics)
        XCTAssertFalse(capabilities.supportsNormalizationGain)
        // ping itself still succeeded, so favorites/ratings remain supported
        // (they're a base Subsonic feature, not extension-gated).
        XCTAssertTrue(capabilities.supportsFavorites)
        XCTAssertTrue(capabilities.supportsRatings)
    }

    func testMusicFolderScopingAddsQueryParam() async throws {
        let transport = FixtureTransport([.init(contains: "getAlbumList2", fixture: "sub_album_list2")])
        let backend = try makeSubsonicBackend(transport: transport, musicFolderId: "3")
        _ = try await backend.fetchAlbums(offset: 0, limit: 10)
        let url = try XCTUnwrap(transport.lastRequest?.url?.absoluteString)
        XCTAssertTrue(url.contains("musicFolderId=3"), "expected musicFolderId in query: \(url)")
    }
}

final class SubsonicURLTests: XCTestCase {
    private let flacTrack = Track(
        id: "sg-4471", title: "Xtal", artistName: "Aphex Twin",
        format: AudioFormat(container: "flac", codec: "flac"), mediaKey: "sg-4471"
    )
    private let oggTrack = Track(
        id: "sg-9981", title: "Weird Fishes", artistName: "Radiohead",
        format: AudioFormat(container: "ogg", codec: "vorbis"), mediaKey: "sg-9981"
    )

    func testStreamURLDirectPlaysSupportedContainer() async throws {
        let backend = try makeSubsonicBackend(transport: catalogTransport)
        let source = try await backend.streamSource(for: flacTrack, options: .bestAvailable)
        let string = source.url.absoluteString
        XCTAssertTrue(string.contains("/rest/stream.view"))
        XCTAssertTrue(string.contains("format=raw"))
        XCTAssertFalse(source.isTranscoded)
    }

    func testStreamURLTranscodesUnsupportedContainer() async throws {
        let backend = try makeSubsonicBackend(transport: catalogTransport)
        let source = try await backend.streamSource(for: oggTrack, options: .bestAvailable)
        let string = source.url.absoluteString
        XCTAssertTrue(string.contains("format=aac"))
        XCTAssertTrue(source.isTranscoded)
    }

    func testStreamURLTranscodesWhenBitrateCapped() async throws {
        let backend = try makeSubsonicBackend(transport: catalogTransport)
        let source = try await backend.streamSource(for: flacTrack, options: StreamOptions(maxBitrateKbps: 192))
        XCTAssertTrue(source.isTranscoded)
        XCTAssertTrue(source.url.absoluteString.contains("maxBitRate=192"))
    }

    func testOriginalFileURL() throws {
        let backend = try makeSubsonicBackend(transport: catalogTransport)
        let url = try backend.originalFileURL(for: flacTrack)
        let string = url.absoluteString
        XCTAssertTrue(string.contains("/rest/download.view"))
        XCTAssertTrue(string.contains("id=sg-4471"))
    }

    func testArtworkURLIsDeterministicAcrossInstances() throws {
        // Two INDEPENDENT backend instances built from the same persisted
        // token must resolve the SAME artwork URL (architecture point 8) — a
        // per-launch-random salt would thrash the artwork cache.
        let backendA = try makeSubsonicBackend(transport: catalogTransport, token: md5Token())
        let backendB = try makeSubsonicBackend(transport: catalogTransport, token: md5Token())
        let urlA = try XCTUnwrap(backendA.artworkURL(for: ArtworkRef(key: "al-9c31"), size: 300))
        let urlB = try XCTUnwrap(backendB.artworkURL(for: ArtworkRef(key: "al-9c31"), size: 300))
        XCTAssertEqual(urlA, urlB)
        XCTAssertTrue(urlA.absoluteString.contains("/rest/getCoverArt.view"))
        XCTAssertTrue(urlA.absoluteString.contains("size=300"))
    }

    func testApiKeyModeOmitsUsernameParam() async throws {
        let transport = FixtureTransport([.init(contains: "getArtists", fixture: "sub_artists")])
        let backend = try makeSubsonicBackend(transport: transport, token: apiKeyToken("my-api-key"))
        _ = try await backend.fetchArtists(offset: 0, limit: 10)
        let url = try XCTUnwrap(transport.lastRequest?.url?.absoluteString)
        XCTAssertTrue(url.contains("apiKey=my-api-key"))
        XCTAssertFalse(url.contains("u=brandon"))
        XCTAssertFalse(url.contains("&t="))
        XCTAssertFalse(url.contains("&s="))
    }

    func testMd5ModeSignsUsernameTokenAndSalt() async throws {
        let transport = FixtureTransport([.init(contains: "getArtists", fixture: "sub_artists")])
        let backend = try makeSubsonicBackend(transport: transport, token: md5Token(secret: "cafebabe", salt: "salty"))
        _ = try await backend.fetchArtists(offset: 0, limit: 10)
        let url = try XCTUnwrap(transport.lastRequest?.url?.absoluteString)
        XCTAssertTrue(url.contains("u=brandon"))
        XCTAssertTrue(url.contains("t=cafebabe"))
        XCTAssertTrue(url.contains("s=salty"))
        XCTAssertFalse(url.contains("apiKey="))
    }
}

final class SubsonicErrorMappingTests: XCTestCase {
    func testFailedEnvelopeMapsToMozzError() async throws {
        let transport = FixtureTransport([.init(contains: "ping", fixture: "sub_error_wrongauth")])
        let backend = try makeSubsonicBackend(transport: transport)
        do {
            _ = try await backend.detectCapabilities()
            XCTFail("expected an error")
        } catch let error as MozzError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testErrorCodeTable() {
        func error(_ code: Int) -> MozzError {
            SubsonicClient.mapError(SubsonicErrorDTO(code: code, message: nil, helpUrl: nil))
        }
        XCTAssertEqual(error(40), .unauthorized)
        XCTAssertEqual(error(44), .unauthorized)
        XCTAssertEqual(error(50), .unauthorized)
        XCTAssertEqual(error(70), .notFound)
        if case .unsupported = error(41) {} else { XCTFail("41 should be .unsupported") }
        if case .unsupported = error(42) {} else { XCTFail("42 should be .unsupported") }
        if case .unsupported = error(43) {} else { XCTFail("43 should be .unsupported") }
        if case .unsupported = error(20) {} else { XCTFail("20 should be .unsupported") }
        if case .unsupported = error(30) {} else { XCTFail("30 should be .unsupported") }
        if case .unsupported = error(60) {} else { XCTFail("60 should be .unsupported") }
        if case .unsupported = error(10) {} else { XCTFail("10 should be .unsupported") }
        if case .transport = error(999) {} else { XCTFail("unknown code should be .transport") }
    }

    func testNilErrorMapsToInvalidResponse() {
        XCTAssertEqual(SubsonicClient.mapError(nil), .invalidResponse)
    }
}

final class SubsonicBinaryValidationTests: XCTestCase {
    private func client(transport: any HTTPTransport) throws -> SubsonicClient {
        try SubsonicClient(
            baseURL: URL(string: "https://music.example.com")!,
            credential: SubsonicCredential(mode: .apiKey, username: "brandon", secret: "key"),
            transport: transport
        )
    }

    func testXMLErrorBodyIsRejectedNotSavedAsMedia() async throws {
        // Subsonic reports binary-endpoint failures as HTTP 200 + text/xml,
        // "regardless" of the requested `f=json` — this must NEVER be
        // returned to a caller that will write the bytes to disk as if they
        // were audio.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <subsonic-response status="failed" version="1.16.1"><error code="70" message="Song not found"/></subsonic-response>
        """.data(using: .utf8)!
        let transport = ClosureTransport { request in
            (xml, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/xml"])!)
        }
        let sut = try client(transport: transport)
        do {
            _ = try await sut.fetchBinary(action: "stream", query: [URLQueryItem(name: "id", value: "sg-missing")])
            XCTFail("expected an error, not the XML bytes")
        } catch let error as MozzError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testJSONErrorBodyOnBinaryEndpointMapsPreciseError() async throws {
        let json = """
        {"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":70,"message":"Song not found"}}}
        """.data(using: .utf8)!
        let transport = ClosureTransport { request in
            (json, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        let sut = try client(transport: transport)
        do {
            _ = try await sut.fetchBinary(action: "stream", query: [URLQueryItem(name: "id", value: "sg-missing")])
            XCTFail("expected an error")
        } catch let error as MozzError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testGenuineBinaryResponsePassesThrough() async throws {
        let bytes = Data([0xFF, 0xFB, 0x90, 0x00]) // fake mp3 frame header
        let transport = ClosureTransport { request in
            (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/mpeg"])!)
        }
        let sut = try client(transport: transport)
        let data = try await sut.fetchBinary(action: "stream", query: [URLQueryItem(name: "id", value: "sg-4471")])
        XCTAssertEqual(data, bytes)
    }
}

final class SubsonicAuthSigningTests: XCTestCase {
    func testApiKeyQueryItemsOmitUPTS() throws {
        let credential = SubsonicCredential(mode: .apiKey, username: "brandon", secret: "my-key")
        let items = try SubsonicAuth.authQueryItems(for: credential)
        XCTAssertEqual(items, [URLQueryItem(name: "apiKey", value: "my-key")])
    }

    func testMd5QueryItemsIncludeUTS() throws {
        let credential = SubsonicCredential(mode: .md5, username: "brandon", secret: "tokval", salt: "saltval")
        let items = try SubsonicAuth.authQueryItems(for: credential)
        XCTAssertEqual(Set(items.map(\.name)), ["u", "t", "s"])
        XCTAssertEqual(items.first { $0.name == "u" }?.value, "brandon")
        XCTAssertEqual(items.first { $0.name == "t" }?.value, "tokval")
        XCTAssertEqual(items.first { $0.name == "s" }?.value, "saltval")
    }

    func testMd5MissingSaltThrows() {
        let credential = SubsonicCredential(mode: .md5, username: "brandon", secret: "tokval", salt: nil)
        XCTAssertThrowsError(try SubsonicAuth.authQueryItems(for: credential))
    }

    func testLegacyModeThrowsUnsupported() {
        let credential = SubsonicCredential(mode: .legacy, username: "brandon", secret: "plaintext")
        XCTAssertThrowsError(try SubsonicAuth.authQueryItems(for: credential)) { error in
            guard case MozzError.unsupported = error else {
                return XCTFail("expected .unsupported, got \(error)")
            }
        }
    }

    func testMd5TokenIsDeterministic() {
        let token1 = SubsonicAuth.md5Token(password: "hunter2", salt: "abc")
        let token2 = SubsonicAuth.md5Token(password: "hunter2", salt: "abc")
        XCTAssertEqual(token1, token2)
        XCTAssertNotEqual(token1, SubsonicAuth.md5Token(password: "hunter2", salt: "xyz"))
    }

    func testCredentialEnvelopeRoundTrips() throws {
        let original = SubsonicCredential(mode: .md5, username: "brandon", secret: "tok", salt: "salt")
        let encoded = try original.encoded()
        let decoded = try SubsonicCredential.decoded(from: encoded)
        XCTAssertEqual(original, decoded)
    }
}
