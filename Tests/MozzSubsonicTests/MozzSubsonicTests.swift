import XCTest
import Foundation
import MozzCore
import MozzNetworking
@testable import MozzSync
@testable import MozzSubsonic

// MARK: - Test doubles

/// Serves recorded JSON fixtures for requests whose URL contains a route's match
/// string (first containment match wins). Records the last request so signing can
/// be inspected. Unmatched routes return HTTP 404 (used to simulate a classic
/// server with no `getOpenSubsonicExtensions`).
final class FixtureTransport: HTTPTransport, @unchecked Sendable {
    struct Route { let contains: String; let fixture: String }

    private let routes: [Route]
    private let lock = NSLock()
    private var _last: URLRequest?
    private var _requests: [URLRequest] = []

    init(_ routes: [Route]) { self.routes = routes }

    var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return _last
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); _last = request; _requests.append(request); lock.unlock()
        let string = request.url?.absoluteString ?? ""
        let fallbackURL = request.url ?? URL(string: "https://example.com")!
        guard
            let route = routes.first(where: { string.contains($0.contains) }),
            let url = Bundle.module.url(forResource: route.fixture, withExtension: "json", subdirectory: "Fixtures"),
            let data = try? Data(contentsOf: url)
        else {
            return (Data(), HTTPURLResponse(url: fallbackURL, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let headers = ["Content-Type": "application/json"]
        return (data, HTTPURLResponse(url: fallbackURL, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
}

/// Returns one fixed (status, content-type, body) for every request. Used to
/// prove binary endpoints reject an error body instead of saving it as audio.
final class BinaryStubTransport: HTTPTransport, @unchecked Sendable {
    let status: Int
    let contentType: String?
    let body: Data

    init(status: Int, contentType: String?, body: Data) {
        self.status = status; self.contentType = contentType; self.body = body
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url ?? URL(string: "https://example.com")!
        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }
        return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

// MARK: - Shared fixtures

private let clientInfo = ClientInfo(
    product: "Mozz", version: "1.0", deviceName: "iPhone", platform: "iOS", platformVersion: "17.0"
)

private func makeConnection(musicFolderId: String? = nil) -> ServerConnection {
    ServerConnection(
        id: "subsonic-brandon-https://music.example.com",
        kind: .subsonic,
        name: "Navidrome",
        baseURL: URL(string: "https://music.example.com")!,
        userID: "brandon",
        clientIdentifier: "client-uuid",
        musicSectionID: musicFolderId
    )
}

/// A credential with a FIXED salt so the derived token — and every signed URL —
/// is deterministic in tests.
private let md5Credential = SubsonicCredential.md5(username: "brandon", password: "hunter2", salt: "deadbeef")
private let apiKeyCredential = SubsonicCredential.apiKey(username: "brandon", apiKey: "os-key-123")

private func queryItems(_ url: URL?) -> [String: String] {
    guard let url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
    var out: [String: String] = [:]
    for item in comps.queryItems ?? [] { out[item.name] = item.value ?? "" }
    return out
}

// MARK: - Mapper (DTO -> domain) against recorded fixtures

final class SubsonicMapperTests: XCTestCase {
    private func decodeAlbum() throws -> SubsonicAlbumID3 {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sub_album", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let env = try JSONDecoder().decode(SubsonicEnvelope<SubsonicAlbumPayload>.self, from: data)
        return try XCTUnwrap(env.response.payload.album)
    }

    func testTrackMappingPreservesOpaqueIdsAndRichFields() throws {
        let album = try decodeAlbum()
        let songs = try XCTUnwrap(album.song)
        XCTAssertEqual(songs.count, 2)

        let so_what = SubsonicMapper.track(songs[0])
        // Opaque string id preserved verbatim.
        XCTAssertEqual(so_what.id, "tr-1001")
        XCTAssertEqual(so_what.title, "So What")
        XCTAssertEqual(so_what.albumID, "al-100")
        XCTAssertEqual(so_what.artistID, "ar-50")
        XCTAssertEqual(so_what.trackNumber, 1)
        XCTAssertEqual(so_what.discNumber, 1)
        XCTAssertEqual(so_what.duration, 545)
        XCTAssertEqual(so_what.format.container, "flac")
        XCTAssertEqual(so_what.fileSizeBytes, 68_000_000)
        // Rich OpenSubsonic fields.
        XCTAssertTrue(so_what.isFavorite)                 // starred present
        XCTAssertEqual(so_what.rating, 5)                 // userRating
        XCTAssertEqual(so_what.normalizationGainDB, -6.5) // replayGain.trackGain
        XCTAssertEqual(so_what.mbid, "6fe9f7d5-3a5f-4b6a-8f2e-1c2d3e4f5a6b")
        XCTAssertEqual(so_what.genres, ["Jazz", "Modal"]) // single+list merged, deduped
        // Item cover art preferred over album's.
        XCTAssertEqual(so_what.artwork?.key, "tr-1001")
    }

    func testNumericIdDecodesToStringAndClassicSongIsNullSafe() throws {
        let album = try decodeAlbum()
        let songs = try XCTUnwrap(album.song)
        let freddie = SubsonicMapper.track(songs[1])
        // A JSON *number* id becomes the opaque string "1002".
        XCTAssertEqual(freddie.id, "1002")
        XCTAssertEqual(freddie.format.container, "opus")
        XCTAssertFalse(freddie.isFavorite)     // no starred
        XCTAssertNil(freddie.rating)           // no userRating
        XCTAssertNil(freddie.normalizationGainDB)
        XCTAssertNil(freddie.mbid)
        XCTAssertEqual(freddie.genres, [])
        // Falls back to the album's cover art (no per-song coverArt).
        XCTAssertEqual(freddie.artwork?.key, "al-100")
    }

    func testAlbumAndArtistMapping() throws {
        let album = try decodeAlbum()
        let mapped = SubsonicMapper.album(album)
        XCTAssertEqual(mapped.id, "al-100")
        XCTAssertEqual(mapped.title, "Kind of Blue")
        XCTAssertEqual(mapped.artistName, "Miles Davis")
        XCTAssertEqual(mapped.artistID, "ar-50")
        XCTAssertEqual(mapped.year, 1959)
        XCTAssertEqual(mapped.trackCount, 2)
        XCTAssertEqual(mapped.genres, ["Jazz"])
    }
}

// MARK: - Auth signing (tri-mode + apiKey omits u)

final class SubsonicAuthTests: XCTestCase {
    func testApiKeyModeOmitsUsername() {
        let items = apiKeyCredential.signingQueryItems()
        let names = Set(items.map(\.name))
        XCTAssertTrue(names.contains("apiKey"))
        XCTAssertFalse(names.contains("u"), "apiKey mode MUST omit the u param")
        XCTAssertFalse(names.contains("t"))
        XCTAssertFalse(names.contains("s"))
        XCTAssertEqual(items.first(where: { $0.name == "apiKey" })?.value, "os-key-123")
    }

    func testMD5ModeSendsUserTokenSaltAndDiscardsPassword() {
        let items = md5Credential.signingQueryItems()
        let map = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(map["u"], "brandon")
        XCTAssertEqual(map["s"], "deadbeef")
        // t = MD5(password + salt); the plaintext password is never present.
        XCTAssertEqual(map["t"], SubsonicCredential.md5Hex("hunter2" + "deadbeef"))
        XCTAssertNil(map["p"])
        XCTAssertFalse(md5Credential.secret.contains("hunter2"))
    }

    func testLegacyModeSendsCleartextPassword() {
        let cred = SubsonicCredential(mode: .legacy, username: "brandon", secret: "hunter2")
        let map = Dictionary(uniqueKeysWithValues: cred.signingQueryItems().map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(map["u"], "brandon")
        XCTAssertEqual(map["p"], "hunter2")
        XCTAssertNil(map["t"])
    }

    func testCredentialEnvelopeRoundTripsThroughTokenSlot() {
        let token = md5Credential.encoded()
        let decoded = try? XCTUnwrap(SubsonicCredential.decode(token))
        XCTAssertEqual(decoded?.mode, .md5)
        XCTAssertEqual(decoded?.username, "brandon")
        XCTAssertEqual(decoded?.salt, "deadbeef")
        XCTAssertEqual(decoded?.secret, md5Credential.secret)
    }

    func testURLNormalizerAddsSchemeAndStripsTrailingSlash() {
        XCTAssertEqual(SubsonicURLNormalizer.normalize("music.example.com")?.absoluteString, "http://music.example.com")
        XCTAssertEqual(SubsonicURLNormalizer.normalize("https://music.example.com/")?.absoluteString, "https://music.example.com")
        XCTAssertNil(SubsonicURLNormalizer.normalize("   "))
    }
}

// MARK: - Client: envelope errors + binary validation

final class SubsonicClientTests: XCTestCase {
    private func client(_ transport: HTTPTransport, credential: SubsonicCredential = md5Credential) -> SubsonicClient {
        SubsonicClient(baseURL: URL(string: "https://music.example.com")!,
                       credential: credential, clientInfo: clientInfo, transport: transport)
    }

    func testFailedEnvelopeOverHTTP200MapsToMozzError() async {
        // The error fixture is served with HTTP 200 (Subsonic reports failures in
        // the body, not the status). It must still surface as .unauthorized.
        let transport = FixtureTransport([.init(contains: "ping", fixture: "sub_error_wrongcreds")])
        do {
            _ = try await client(transport).send("ping", as: SubsonicEmpty.self)
            XCTFail("Expected a thrown error for a failed envelope")
        } catch {
            XCTAssertEqual(error as? MozzError, .unauthorized)
        }
    }

    func testErrorCodeMapping() {
        XCTAssertEqual(SubsonicClient.mapError(code: 40, message: nil), .unauthorized)
        XCTAssertEqual(SubsonicClient.mapError(code: 44, message: nil), .unauthorized)
        XCTAssertEqual(SubsonicClient.mapError(code: 50, message: nil), .unauthorized)
        XCTAssertEqual(SubsonicClient.mapError(code: 70, message: nil), .notFound)
        if case .unsupported = SubsonicClient.mapError(code: 30, message: "boom") {} else {
            XCTFail("Non-auth codes should map to .unsupported")
        }
    }

    func testValidateBinaryRejectsErrorBodies() {
        // XML/JSON/text bodies are error pages, never audio.
        XCTAssertEqual(throwsMozz { try SubsonicClient.validateBinary(status: 200, contentType: "application/xml") }, .invalidResponse)
        XCTAssertEqual(throwsMozz { try SubsonicClient.validateBinary(status: 200, contentType: "text/html; charset=utf-8") }, .invalidResponse)
        XCTAssertEqual(throwsMozz { try SubsonicClient.validateBinary(status: 200, contentType: "application/json") }, .invalidResponse)
        // Real audio / unknown types pass; 206 partial (range) is fine.
        XCTAssertNil(throwsMozz { try SubsonicClient.validateBinary(status: 200, contentType: "audio/mpeg") })
        XCTAssertNil(throwsMozz { try SubsonicClient.validateBinary(status: 206, contentType: "audio/flac") })
        XCTAssertNil(throwsMozz { try SubsonicClient.validateBinary(status: 200, contentType: nil) })
        // Non-2xx status wins over content-type.
        XCTAssertEqual(throwsMozz { try SubsonicClient.validateBinary(status: 401, contentType: "audio/mpeg") }, .unauthorized)
        XCTAssertEqual(throwsMozz { try SubsonicClient.validateBinary(status: 404, contentType: "audio/mpeg") }, .notFound)
        XCTAssertEqual(throwsMozz { try SubsonicClient.validateBinary(status: 500, contentType: nil) }, .badStatus(500))
    }

    func testFetchBinaryRejectsXMLErrorBodyServedOverHTTP200() async {
        // A classic Subsonic error arrives as an XML body over HTTP 200; saving it
        // as an audio file would corrupt a download. fetchBinary must reject it.
        let xml = Data("<subsonic-response status=\"failed\"><error code=\"70\"/></subsonic-response>".utf8)
        let transport = BinaryStubTransport(status: 200, contentType: "application/xml", body: xml)
        do {
            _ = try await client(transport).fetchBinary("stream", query: [URLQueryItem(name: "id", value: "tr-1")])
            XCTFail("Expected fetchBinary to reject an XML error body")
        } catch {
            XCTAssertEqual(error as? MozzError, .invalidResponse)
        }
    }
}

// MARK: - Backend: search3 paging, artwork determinism, transcoding, capabilities

final class SubsonicBackendTests: XCTestCase {
    private func backend(_ transport: HTTPTransport,
                         credential: SubsonicCredential = md5Credential,
                         musicFolderId: String? = nil) -> SubsonicBackend {
        SubsonicBackend(connection: makeConnection(musicFolderId: musicFolderId),
                        credential: credential, clientInfo: clientInfo, transport: transport)
    }

    func testSearch3QuickStartNeverReportsATotal() async throws {
        // search3(query="") is the quick-start fast path: it must map items but
        // NEVER report a total, so it can never authorize a prune.
        let transport = FixtureTransport([.init(contains: "search3", fixture: "sub_search3")])
        let page = try await backend(transport).fetchTracks(offset: 0, limit: 100)
        XCTAssertEqual(page.items.map(\.id), ["tr-1001", "tr-2001"])
        XCTAssertNil(page.totalCount, "search3 must never report a total")
        // It really did hit search3 with an empty query.
        let q = queryItems(transport.lastRequest?.url)
        XCTAssertEqual(q["query"], "")
        XCTAssertTrue(transport.lastRequest?.url?.absoluteString.contains("search3.view") == true)
    }

    func testArtworkURLIsSignedAndDeterministicAcrossInstances() {
        let a = backend(FixtureTransport([]))
        let b = backend(FixtureTransport([]))
        let art = ArtworkRef(key: "cover-1")
        let urlA = a.artworkURL(for: art, size: 300)
        let urlB = b.artworkURL(for: art, size: 300)
        XCTAssertNotNil(urlA)
        // Same credential (stable salt) → byte-identical URL across launches, so
        // the artwork cache (keyed on the URL) doesn't thrash.
        XCTAssertEqual(urlA, urlB)
        let q = queryItems(urlA)
        XCTAssertEqual(q["id"], "cover-1")
        XCTAssertEqual(q["size"], "300")
        XCTAssertEqual(q["u"], "brandon")
        XCTAssertEqual(q["s"], "deadbeef")
        XCTAssertEqual(q["t"], SubsonicCredential.md5Hex("hunter2deadbeef"))
        XCTAssertEqual(q["f"], "json")
    }

    func testArtworkURLApiKeyModeOmitsUsername() {
        let b = backend(FixtureTransport([]), credential: apiKeyCredential)
        let q = queryItems(b.artworkURL(for: ArtworkRef(key: "cover-1"), size: 100))
        XCTAssertEqual(q["apiKey"], "os-key-123")
        XCTAssertNil(q["u"], "apiKey mode must omit u even on media URLs")
    }

    func testSelectiveTranscodingDirectPlaysFriendlyContainers() async throws {
        let b = backend(FixtureTransport([]))
        // flac is iOS-friendly → format=raw (preserve gapless + quality).
        let flac = makeTrack(id: "t1", container: "flac")
        let raw = try await b.streamSource(for: flac, options: StreamOptions())
        XCTAssertFalse(raw.isTranscoded)
        XCTAssertEqual(queryItems(raw.url)["format"], "raw")

        // opus is not directly playable → transcode to aac.
        let opus = makeTrack(id: "t2", container: "opus")
        let transcoded = try await b.streamSource(for: opus, options: StreamOptions())
        XCTAssertTrue(transcoded.isTranscoded)
        XCTAssertEqual(queryItems(transcoded.url)["format"], "aac")

        // A bitrate cap forces transcode even for a friendly container.
        let capped = try await b.streamSource(for: flac, options: StreamOptions(maxBitrateKbps: 192))
        XCTAssertTrue(capped.isTranscoded)
        XCTAssertEqual(queryItems(capped.url)["format"], "aac")
        XCTAssertEqual(queryItems(capped.url)["maxBitRate"], "192")
    }

    func testCapabilitiesClassicServerFallsBackWithoutExtensions() async throws {
        // Classic server: ping has no openSubsonic flag, and there is no
        // getOpenSubsonicExtensions route (→ 404). Detection must still succeed.
        let transport = FixtureTransport([.init(contains: "ping", fixture: "sub_ping_classic")])
        let caps = try await backend(transport).detectCapabilities()
        XCTAssertFalse(caps.isOpenSubsonic)
        XCTAssertFalse(caps.supportsNormalizationGain)
        XCTAssertFalse(caps.supportsLyrics)
        // Classic Subsonic still supports these.
        XCTAssertTrue(caps.supportsFavorites)
        XCTAssertTrue(caps.supportsRatings)
        XCTAssertTrue(caps.supportsTranscoding)
    }

    func testCapabilitiesOpenSubsonicExtensions404IsNotAFailure() async throws {
        // OpenSubsonic ping but the extensions endpoint 404s. Per spec item 10 a
        // 404 means "classic profile", NOT a detection failure.
        let transport = FixtureTransport([.init(contains: "ping", fixture: "sub_ping_opensubsonic")])
        let caps = try await backend(transport).detectCapabilities()
        XCTAssertTrue(caps.isOpenSubsonic)
        XCTAssertEqual(caps.serverProduct, "navidrome")
        XCTAssertTrue(caps.supportsNormalizationGain)     // openSubsonic → replayGain
        XCTAssertFalse(caps.supportsLyrics)               // no songLyrics extension seen
    }

    func testCapabilitiesReadsDetectedExtensions() async throws {
        let transport = FixtureTransport([
            .init(contains: "getOpenSubsonicExtensions", fixture: "sub_extensions"),
            .init(contains: "ping", fixture: "sub_ping_opensubsonic"),
        ])
        let caps = try await backend(transport).detectCapabilities()
        XCTAssertTrue(caps.isOpenSubsonic)
        XCTAssertTrue(caps.supportsLyrics)                // songLyrics extension present
    }

    func testMusicFolderScopingIsAppliedToRequests() async throws {
        let transport = FixtureTransport([.init(contains: "search3", fixture: "sub_search3")])
        _ = try await backend(transport, musicFolderId: "7").fetchTracks(offset: 0, limit: 10)
        XCTAssertEqual(queryItems(transport.lastRequest?.url)["musicFolderId"], "7")
    }
}

// MARK: - Bulk enumeration + prune safety (spec items 2–4)

final class SubsonicEnumerationTests: XCTestCase {
    private func backend(_ transport: HTTPTransport) -> SubsonicBackend {
        SubsonicBackend(connection: makeConnection(), credential: md5Credential,
                        clientInfo: clientInfo, transport: transport)
    }

    /// Album-list route MUST precede album route: "/rest/getAlbumList2.view"
    /// contains the substring "getAlbum", so order matters (first match wins).
    private func albumWalkTransport(albumList: String) -> FixtureTransport {
        FixtureTransport([
            .init(contains: "getAlbumList2", fixture: albumList),
            .init(contains: "getAlbum", fixture: "sub_album"),
        ])
    }

    func testEnumerateAllTracksDerivesExpectedTotalFromSongCounts() async throws {
        // Every album reports a songCount → expected total = Σ songCount = 2, and
        // every page carries it (the completeness proof that gates pruning).
        let transport = albumWalkTransport(albumList: "sub_albumlist2_counted")
        let stream = try XCTUnwrap(backend(transport).enumerateAllTracks(pageSize: 50))
        var pages: [CatalogPage<Track>] = []
        for try await page in stream { pages.append(page) }

        let allTracks = pages.flatMap(\.items)
        XCTAssertEqual(Set(allTracks.map(\.id)), ["tr-1001", "1002"]) // deduped
        XCTAssertFalse(pages.isEmpty)
        for page in pages { XCTAssertEqual(page.totalCount, 2) }
    }

    func testEnumerateAllTracksWithMissingSongCountReportsNoTotal() async throws {
        // A single album without songCount makes the total UNPROVABLE → every page
        // reports totalCount == nil, which the sync engine treats as "do not
        // prune" (protecting offline downloads).
        let transport = albumWalkTransport(albumList: "sub_albumlist2_nocount")
        let stream = try XCTUnwrap(backend(transport).enumerateAllTracks(pageSize: 50))
        var pages: [CatalogPage<Track>] = []
        for try await page in stream { pages.append(page) }

        XCTAssertFalse(pages.isEmpty)
        for page in pages { XCTAssertNil(page.totalCount, "unprovable total must be nil") }
    }

    /// Regression: an empty-id album inside a FULL album-list window must not
    /// truncate the walk. Page 1 (offset 0) is a full window of 2 albums, one of
    /// which has an empty id; after filtering it yields a single id. Driving
    /// termination off that post-filter count (the original bug) would break the
    /// loop before ever requesting offset 2, dropping every later album — and,
    /// because the derived total would then match the truncated set, authorize a
    /// prune that deletes unseen tracks and their offline downloads. Termination
    /// must instead use the RAW window length, so the tail page IS fetched.
    func testEmptyIdAlbumInFullWindowDoesNotTruncateWalk() async throws {
        let transport = FixtureTransport([
            .init(contains: "offset=2", fixture: "sub_albumlist2_page2_tail"),
            .init(contains: "getAlbumList2", fixture: "sub_albumlist2_page1_full"),
            .init(contains: "id=al-1", fixture: "sub_album_a1"),
            .init(contains: "id=al-2", fixture: "sub_album_a2"),
        ])
        // albumWindow == 2 so page 1's raw length (2) fills the window and the walk
        // must continue to offset 2; the tail's raw length (1) is the real terminal.
        let stream = try XCTUnwrap(
            backend(transport).enumerateAllTracks(pageSize: 50, albumWindow: 2))
        var pages: [CatalogPage<Track>] = []
        for try await page in stream { pages.append(page) }

        let allTracks = pages.flatMap(\.items)
        // Both real albums walked — the empty-id album did not end enumeration.
        XCTAssertEqual(Set(allTracks.map(\.id)), ["tr-a1", "tr-a2"])
        // Expected total = Σ songCount over the two VALID albums (the empty-id
        // album is filtered and excluded), and it is reached → prune is safe.
        for page in pages { XCTAssertEqual(page.totalCount, 2) }
        // The tail page at offset 2 was actually requested (offset advanced by the
        // raw window length, not the filtered id count).
        let hitOffset2 = transport.requests.contains {
            ($0.url?.absoluteString ?? "").contains("offset=2")
        }
        XCTAssertTrue(hitOffset2, "walk must page past the empty-id full window")
    }

    /// The engine-side guard: an enumerator page-set with a nil reported total
    /// must NOT authorize a prune, while a reached total must.
    func testPruneGuardRefusesToPruneWithoutProvableTotal() {
        // Bulk enumerator, no provable total → never prune.
        let unproven = LibrarySyncEngine.PagedEnumeration(
            seen: ["a", "b"], reportedTotal: nil, requiresReportedTotalForPrune: true)
        XCTAssertFalse(LibrarySyncEngine.phaseCompleted(unproven))

        // Bulk enumerator that reached its expected total → safe to prune.
        let proven = LibrarySyncEngine.PagedEnumeration(
            seen: ["a", "b", "c"], reportedTotal: 3, requiresReportedTotalForPrune: true)
        XCTAssertTrue(LibrarySyncEngine.phaseCompleted(proven))

        // Bulk enumerator that fell short of its total → still refuse.
        let short = LibrarySyncEngine.PagedEnumeration(
            seen: ["a", "b"], reportedTotal: 3, requiresReportedTotalForPrune: true)
        XCTAssertFalse(LibrarySyncEngine.phaseCompleted(short))

        // Flat pager default (Plex/Jellyfin): a non-empty enumeration is complete
        // even without a reported total — the strict rule is Subsonic-only.
        let flat = LibrarySyncEngine.PagedEnumeration(
            seen: ["a"], reportedTotal: nil, requiresReportedTotalForPrune: false)
        XCTAssertTrue(LibrarySyncEngine.phaseCompleted(flat))
    }
}

// MARK: - Helpers

private func makeTrack(id: String, container: String) -> Track {
    Track(
        id: id, title: "T", sortTitle: nil, albumTitle: "A", albumID: "al-1",
        artistName: "Artist", artistID: "ar-1", albumArtistName: nil,
        trackNumber: 1, discNumber: 1, duration: 100,
        format: AudioFormat(container: container, codec: container, bitrateKbps: nil,
                            sampleRateHz: nil, channels: nil, bitDepth: nil),
        fileSizeBytes: nil, mediaKey: id, artwork: nil, genres: [],
        isFavorite: false, rating: nil, normalizationGainDB: nil, addedAt: nil,
        mbid: nil, artistMbid: nil
    )
}

/// Run a throwing binary-validation call and return the thrown MozzError (or nil
/// if it did not throw), so assertions read as `== .invalidResponse`.
private func throwsMozz(_ body: () throws -> Void) -> MozzError? {
    do { try body(); return nil } catch { return error as? MozzError }
}
