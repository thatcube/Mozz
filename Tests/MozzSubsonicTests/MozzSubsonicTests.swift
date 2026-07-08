import XCTest
import Foundation
import MozzCore
import MozzNetworking
@testable import MozzSubsonic

// MARK: - Fixture transport

/// Serves recorded OpenSubsonic JSON fixtures. Routes match on substring of the
/// full request URL (which for Subsonic includes both the endpoint path AND the
/// signed query items appended by ``HTTPClient``). First match wins.
final class FixtureTransport: HTTPTransport, @unchecked Sendable {
    struct Route { let contains: String; let fixture: String }

    private let routes: [Route]
    /// Optional per-URL override — used to return specific content types /
    /// status codes for binary-response validation tests.
    var binaryResponse: ((URLRequest) -> (Data, HTTPURLResponse)?)?

    private let lock = NSLock()
    private var _requests: [URLRequest] = []

    init(_ routes: [Route]) { self.routes = routes }

    var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return _requests.last
    }
    var allRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); _requests.append(request); lock.unlock()
        if let binary = binaryResponse?(request) { return binary }
        let string = request.url?.absoluteString ?? ""
        let fallbackURL = request.url ?? URL(string: "https://example.com")!
        guard
            let route = routes.first(where: { string.contains($0.contains) }),
            let url = Bundle.module.url(forResource: route.fixture, withExtension: "json", subdirectory: "Fixtures"),
            let data = try? Data(contentsOf: url)
        else {
            return (Data(), HTTPURLResponse(url: fallbackURL, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        return (data, HTTPURLResponse(
            url: fallbackURL, statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!)
    }
}

// MARK: - Test scaffolding

let clientInfo = ClientInfo(
    product: "Mozz", version: "1.0",
    deviceName: "iPhone", platform: "iOS", platformVersion: "17.0"
)

func makeConnection(username: String = "alice") -> ServerConnection {
    ServerConnection(
        id: "subsonic-\(username)-https://ss.example.com",
        kind: .subsonic,
        name: "Home",
        baseURL: URL(string: "https://ss.example.com")!,
        userID: username,
        clientIdentifier: "client-uuid"
    )
}

func stableMD5Creds(username: String = "alice", password: String = "secret") -> SubsonicCredentials {
    // Passing an explicit salt makes URLs byte-deterministic across the test run.
    SubsonicAuthCoder.makeMD5Credentials(username: username, password: password, salt: "abcdef1234567890")
}

func apiKeyCreds(username: String = "alice", apiKey: String = "kkkey-42") -> SubsonicCredentials {
    SubsonicCredentials(mode: .apiKey, username: username, secret: apiKey, salt: nil)
}

let catalogRoutes: [FixtureTransport.Route] = [
    .init(contains: "ping.view", fixture: "sub_ping"),
    .init(contains: "getOpenSubsonicExtensions.view", fixture: "sub_extensions"),
    .init(contains: "getArtists.view", fixture: "sub_artists"),
    .init(contains: "search3.view", fixture: "sub_search3"),
    // Order matters: getAlbum.view must beat getAlbumList2.view — but URLs
    // include both endpoint AND query, so match on the endpoint path segment.
    .init(contains: "getAlbum.view", fixture: "sub_album_detail_1"),
    .init(contains: "getAlbumList2.view", fixture: "sub_album_list"),
]

func makeBackend(
    transport: FixtureTransport,
    credentials: SubsonicCredentials = stableMD5Creds()
) -> SubsonicBackend {
    SubsonicBackend(
        connection: makeConnection(username: credentials.username),
        credentials: credentials,
        clientInfo: clientInfo,
        transport: transport
    )
}

// MARK: - Signing

final class SubsonicSigningTests: XCTestCase {
    func testMD5SigningIncludesUsernameTokenAndSalt() throws {
        let items = SubsonicAuthCoder.queryItems(
            for: stableMD5Creds(), clientInfo: clientInfo
        )
        let dict = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(dict["u"], "alice")
        XCTAssertEqual(dict["s"], "abcdef1234567890")
        // MD5("secret" + "abcdef1234567890") lowercased hex.
        // Verified locally: 6a1e7bdf... — but we recompute here rather than hard-code.
        let expected = SubsonicAuthCoder.makeMD5Credentials(
            username: "alice", password: "secret", salt: "abcdef1234567890"
        ).secret
        XCTAssertEqual(dict["t"], expected)
        XCTAssertNil(dict["apiKey"])
        XCTAssertNil(dict["p"])
        XCTAssertEqual(dict["f"], "json")
        XCTAssertEqual(dict["c"], "Mozz")
        XCTAssertEqual(dict["v"], SubsonicAuthCoder.apiVersion)
    }

    func testAPIKeyModeOmitsUsernameParam() throws {
        let items = SubsonicAuthCoder.queryItems(
            for: apiKeyCreds(), clientInfo: clientInfo
        )
        let dict = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        // The OpenSubsonic spec REQUIRES omission of `u` when apiKey is present.
        XCTAssertNil(dict["u"], "apiKey mode must not include u=")
        XCTAssertNil(dict["t"])
        XCTAssertNil(dict["s"])
        XCTAssertNil(dict["p"])
        XCTAssertEqual(dict["apiKey"], "kkkey-42")
    }

    func testLegacyModeSendsPlaintextPassword() throws {
        let items = SubsonicAuthCoder.queryItems(
            for: SubsonicCredentials(mode: .legacy, username: "alice", secret: "hunter2"),
            clientInfo: clientInfo
        )
        let dict = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(dict["u"], "alice")
        XCTAssertEqual(dict["p"], "hunter2")
        XCTAssertNil(dict["apiKey"])
        XCTAssertNil(dict["t"])
    }

    func testMD5CredentialDerivationIsStableGivenSameSalt() {
        let a = SubsonicAuthCoder.makeMD5Credentials(username: "u", password: "p", salt: "salt")
        let b = SubsonicAuthCoder.makeMD5Credentials(username: "u", password: "p", salt: "salt")
        XCTAssertEqual(a.secret, b.secret)
        XCTAssertEqual(a.salt, b.salt)
    }

    func testCredentialsEnvelopeRoundtrips() throws {
        let creds = stableMD5Creds()
        let token = try SubsonicAuthCoder.encode(creds)
        let decoded = try SubsonicAuthCoder.decode(token)
        XCTAssertEqual(decoded, creds)
    }
}

// MARK: - Mapper vs. fixtures

final class SubsonicMapperTests: XCTestCase {
    func testAlbumWithSongsDecodesRichFields() throws {
        let data = try loadFixture("sub_album_detail_1")
        let decoder = JSONDecoder()
        decoder.userInfo[.subsonicPayloadKey] = "album"
        let env = try decoder.decode(SSEnvelope<SSAlbumWithSongs>.self, from: data)
        let album = try XCTUnwrap(env.response.payload)
        XCTAssertEqual(album.id.value, "al-1")
        XCTAssertEqual(album.songCount, 2)
        XCTAssertEqual(album.song?.count, 2)

        let tracks = (album.song ?? []).map(SubsonicMapper.track)
        XCTAssertEqual(tracks.count, 2)

        let xtal = tracks[0]
        XCTAssertEqual(xtal.id, "sg-100")
        XCTAssertEqual(xtal.title, "Xtal")
        XCTAssertEqual(xtal.albumID, "al-1")
        XCTAssertEqual(xtal.artistID, "ar-1")
        XCTAssertTrue(xtal.isFavorite)
        XCTAssertEqual(xtal.rating, 5.0)
        XCTAssertEqual(xtal.normalizationGainDB, -6.5)
        XCTAssertEqual(xtal.format.codec, "flac")
        XCTAssertEqual(xtal.format.container, "flac")
        XCTAssertEqual(xtal.format.bitrateKbps, 992)
        XCTAssertEqual(xtal.format.sampleRateHz, 44100)
        XCTAssertEqual(xtal.artwork?.key, "al-1")
        XCTAssertNotNil(xtal.mbid, "musicBrainzId must map to Track.mbid")

        // Second track has a NUMERIC id (200) — SSAnyID must coerce to "200".
        let tha = tracks[1]
        XCTAssertEqual(tha.id, "200")
        XCTAssertEqual(tha.format.codec, "opus", "content-type audio/opus -> opus")
        XCTAssertFalse(tha.isFavorite)
        XCTAssertNil(tha.rating)
    }

    func testArtistsMapWithFavoriteAndMBID() throws {
        let data = try loadFixture("sub_artists")
        let decoder = JSONDecoder()
        decoder.userInfo[.subsonicPayloadKey] = "artists"
        let env = try decoder.decode(SSEnvelope<SSArtistsIndex>.self, from: data)
        let all = (env.response.payload?.index ?? []).flatMap { $0.artist ?? [] }
        let mapped = all.map(SubsonicMapper.artist)
        XCTAssertEqual(mapped.count, 2)
        XCTAssertEqual(mapped[0].id, "ar-1")
        XCTAssertEqual(mapped[0].name, "Aphex Twin")
        XCTAssertTrue(mapped[0].isFavorite, "starred timestamp must populate isFavorite")
        XCTAssertEqual(mapped[0].albumCount, 12)
        XCTAssertFalse(mapped[1].isFavorite)
    }

    func testCodecFromContentTypeCoversCommonServers() throws {
        XCTAssertEqual(SubsonicMapper.codec(fromContentType: "audio/mpeg"), "mp3")
        XCTAssertEqual(SubsonicMapper.codec(fromContentType: "audio/flac"), "flac")
        XCTAssertEqual(SubsonicMapper.codec(fromContentType: "audio/opus"), "opus")
        XCTAssertEqual(SubsonicMapper.codec(fromContentType: "audio/ogg"), "vorbis")
        XCTAssertEqual(SubsonicMapper.codec(fromContentType: "audio/x-m4a"), "aac")
    }
}

// MARK: - Envelope error handling

final class SubsonicEnvelopeTests: XCTestCase {
    func testFailedEnvelopeMapsAuthErrorToUnauthorized() async throws {
        let transport = FixtureTransport([
            .init(contains: "ping.view", fixture: "sub_ping_failed"),
        ])
        let backend = makeBackend(transport: transport)
        do {
            _ = try await backend.detectCapabilities()
            XCTFail("Expected MozzError.unauthorized")
        } catch MozzError.unauthorized {
            // Expected.
        } catch {
            XCTFail("Expected .unauthorized, got \(error)")
        }
    }

    func testClassicServerWithoutExtensionsFallsBackToNonOpenSubsonic() async throws {
        // Ping succeeds; extensions endpoint returns a `failed` envelope with
        // code 70 (not found). Detection must NOT throw — it should silently
        // fall back to classic-Subsonic capabilities.
        let transport = FixtureTransport([
            .init(contains: "ping.view", fixture: "sub_ping"),
            .init(contains: "getOpenSubsonicExtensions.view", fixture: "sub_extensions_notfound"),
        ])
        let backend = makeBackend(transport: transport)
        let caps = try await backend.detectCapabilities()
        XCTAssertFalse(caps.isOpenSubsonic, "Missing extensions endpoint must NOT set isOpenSubsonic")
        XCTAssertEqual(caps.serverProductType, "navidrome")
        XCTAssertFalse(caps.supportsLyrics)
        XCTAssertFalse(caps.supportsNormalizationGain)
        XCTAssertTrue(caps.supportsFavorites, "Star is a mandatory Subsonic op")
    }

    func testOpenSubsonicCapabilitiesReflectAdvertisedExtensions() async throws {
        let transport = FixtureTransport([
            .init(contains: "ping.view", fixture: "sub_ping"),
            .init(contains: "getOpenSubsonicExtensions.view", fixture: "sub_extensions"),
        ])
        let backend = makeBackend(transport: transport)
        let caps = try await backend.detectCapabilities()
        XCTAssertTrue(caps.isOpenSubsonic)
        XCTAssertTrue(caps.supportsLyrics)
        XCTAssertTrue(caps.supportsNormalizationGain)
    }
}

// MARK: - Binary response validation

final class SubsonicBinaryValidationTests: XCTestCase {
    func testXMLErrorBodyIsRejectedByBinaryValidator() {
        // A Subsonic server can serve errors over HTTP 200 with an XML body —
        // if we saved that as .mp3 it would permanently corrupt the offline
        // library.
        let xml = Data("<?xml version=\"1.0\"?><subsonic-response status=\"failed\"/>".utf8)
        XCTAssertThrowsError(try SubsonicClient.validateBinaryResponse(
            statusCode: 200, contentType: "text/xml", data: xml
        ))
    }

    func testJSONFailedEnvelopeMapsToMozzError() throws {
        let data = try loadFixture("sub_ping_failed")
        do {
            try SubsonicClient.validateBinaryResponse(
                statusCode: 200, contentType: "application/json", data: data
            )
            XCTFail("Expected an error to be thrown for a JSON failed envelope")
        } catch MozzError.unauthorized {
            // Expected: code 40 -> unauthorized.
        } catch {
            XCTFail("Expected .unauthorized, got \(error)")
        }
    }

    func testAudioContentTypeIsAccepted() {
        XCTAssertNoThrow(try SubsonicClient.validateBinaryResponse(
            statusCode: 200, contentType: "audio/mpeg", data: Data([0xFF, 0xFB])
        ))
    }

    func testHTTPErrorStatusIsRejected() {
        XCTAssertThrowsError(try SubsonicClient.validateBinaryResponse(
            statusCode: 500, contentType: "audio/mpeg", data: Data()
        ))
    }
}

// MARK: - Album walk & prune safety

final class SubsonicAlbumWalkTests: XCTestCase {
    /// FixtureTransport variant that returns the correct album detail based on
    /// the `id=` query parameter — so a walk over multiple albums decodes the
    /// right songs for each.
    private final class AlbumRouter: HTTPTransport, @unchecked Sendable {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = request.url!
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            let fixture: String
            if url.path.contains("getAlbumList2.view") {
                // Return the two-album list once; empty on subsequent pages.
                let offset = comps.queryItems?.first { $0.name == "offset" }?.value ?? "0"
                fixture = (offset == "0") ? "sub_album_list" : "sub_album_list_empty"
            } else if url.path.contains("getAlbum.view") {
                let id = comps.queryItems?.first { $0.name == "id" }?.value ?? ""
                fixture = id == "al-1" ? "sub_album_detail_1" : "sub_album_detail_2"
            } else if url.path.contains("ping.view") {
                fixture = "sub_ping"
            } else {
                return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
            let data = try Data(contentsOf: Bundle.module.url(
                forResource: fixture, withExtension: "json", subdirectory: "Fixtures"
            )!)
            return (data, HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!)
        }
    }

    func testAlbumWalkYieldsAllTracksWithDerivableExpectedTotal() async throws {
        let backend = SubsonicBackend(
            connection: makeConnection(),
            credentials: stableMD5Creds(),
            clientInfo: clientInfo,
            transport: AlbumRouter()
        )
        var collected: [Track] = []
        var lastReportedTotal: Int?
        for try await page in backend.enumerateAllTracks(pageSize: 10) {
            collected.append(contentsOf: page.items)
            lastReportedTotal = page.totalCount
        }
        // 2 songs on al-1 + 3 songs on al-2 = 5 tracks and expected total 5.
        XCTAssertEqual(collected.count, 5)
        XCTAssertEqual(lastReportedTotal, 5,
            "Expected total must equal Σ album.songCount so prune can compare seen>=total")
        // Ids preserved across the walk (opaque, dedup is by-id in the sync
        // engine — SubsonicBackend does NOT dedupe internally).
        XCTAssertEqual(Set(collected.map(\.id)), ["sg-100", "200", "sg-201", "sg-202", "sg-203"])
    }

    func testSearch3IsAvailableAsUnstableFlatPagerButDoesNotAdvertiseTotal() async throws {
        let transport = FixtureTransport([
            .init(contains: "search3.view", fixture: "sub_search3"),
        ])
        let backend = makeBackend(transport: transport)
        let page = try await backend.fetchTracks(offset: 0, limit: 500)
        XCTAssertEqual(page.items.count, 2)
        XCTAssertNil(page.totalCount,
            "search3 must not advertise a total — it is unstable and could authorise unsafe prune")
    }
}

// MARK: - Deterministic artwork URLs

final class SubsonicArtworkURLTests: XCTestCase {
    func testArtworkURLsAreDeterministicAcrossBackendInstances() throws {
        // Two backends with the SAME (username, salt, secret) MUST produce
        // byte-identical getCoverArt URLs so the artwork cache doesn't thrash.
        let creds = stableMD5Creds()
        let a = SubsonicClient(baseURL: URL(string: "https://ss.example.com")!,
                               credentials: creds, clientInfo: clientInfo)
        let b = SubsonicClient(baseURL: URL(string: "https://ss.example.com")!,
                               credentials: creds, clientInfo: clientInfo)
        let ua = try a.url(path: "getCoverArt.view", query: [URLQueryItem(name: "id", value: "al-1")])
        let ub = try b.url(path: "getCoverArt.view", query: [URLQueryItem(name: "id", value: "al-1")])
        XCTAssertEqual(ua.absoluteString, ub.absoluteString)
        // The URL must carry the signing params.
        XCTAssertTrue(ua.absoluteString.contains("s=abcdef1234567890"))
        XCTAssertTrue(ua.absoluteString.contains("u=alice"))
    }

    func testAPIKeyArtworkURLsAreDeterministicAndOmitU() throws {
        let a = SubsonicClient(baseURL: URL(string: "https://ss.example.com")!,
                               credentials: apiKeyCreds(), clientInfo: clientInfo)
        let url = try a.url(path: "getCoverArt.view", query: [URLQueryItem(name: "id", value: "al-1")])
        XCTAssertTrue(url.absoluteString.contains("apiKey=kkkey-42"))
        XCTAssertFalse(url.absoluteString.contains("u="),
            "apiKey mode must not add u= to the URL")
    }
}

// MARK: - Prune safety guard (unit-level, without engine)

final class SubsonicPruneSafetyTests: XCTestCase {
    /// Encodes the PRUNE-SAFETY invariant: on a partial walk, the stream
    /// throws BEFORE the walk completes, and MUST NOT yield a final page whose
    /// `totalCount` matches `seen`. `LibrarySyncEngine` only authorises a
    /// prune after the stream finishes successfully AND seen>=total, so a
    /// thrown stream is inherently prune-safe.
    func testPartialWalkThrowsAndNeverReportsCompleteTotal() async throws {
        final class FailingTransport: HTTPTransport, @unchecked Sendable {
            var callCount = 0
            let lock = NSLock()
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                lock.lock(); callCount += 1; let n = callCount; lock.unlock()
                let url = request.url!
                let fixture: String?
                if url.path.contains("getAlbumList2.view") {
                    fixture = "sub_album_list"
                } else if url.path.contains("getAlbum.view") && n == 2 {
                    fixture = "sub_album_detail_1"
                } else {
                    fixture = nil
                }
                guard let name = fixture,
                      let fixtureURL = Bundle.module.url(
                          forResource: name, withExtension: "json", subdirectory: "Fixtures")
                else {
                    throw URLError(.notConnectedToInternet)
                }
                let data = try Data(contentsOf: fixtureURL)
                return (data, HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!)
            }
        }
        let backend = SubsonicBackend(
            connection: makeConnection(),
            credentials: stableMD5Creds(),
            clientInfo: clientInfo,
            // pageSize=1 forces the enumerator to yield each song immediately,
            // so we CAN observe the "seen" count crossed before the throw.
            transport: FailingTransport()
        )
        var collected: [Track] = []
        var yieldedTotals: [Int?] = []
        var didThrow = false
        do {
            for try await page in backend.enumerateAllTracks(pageSize: 1) {
                collected.append(contentsOf: page.items)
                yieldedTotals.append(page.totalCount)
            }
        } catch {
            didThrow = true
        }
        XCTAssertTrue(didThrow, "Stream must throw when detail fetches fail — engine relies on that to skip prune")
        // Whatever partial pages were yielded, the last one must have reported
        // a total STRICTLY LARGER than `seen` — that's the derivable-total
        // invariant that makes seen>=total safe as the prune gate.
        for (i, total) in yieldedTotals.enumerated() {
            let seenAtThatPoint = i + 1  // pageSize=1
            if let total {
                XCTAssertGreaterThan(total, seenAtThatPoint,
                    "Reported total (\(total)) must exceed seen (\(seenAtThatPoint)) mid-walk so a partial walk never satisfies seen>=total")
            }
        }
    }
}

// MARK: - Helpers

func loadFixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
        "missing fixture \(name)"
    )
    return try Data(contentsOf: url)
}
