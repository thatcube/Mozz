import XCTest
import Foundation
import MozzCore
import MozzNetworking
import MozzDatabase
import GRDB
@testable import MozzEnrichment

private let recA = "b1a9c0e9-d987-4042-ae91-78d6a3267d69"
private let artistA = "f22942a1-6f70-4f48-866e-238cb2308fbd"

private final class ServiceCannedTransport: HTTPTransport, @unchecked Sendable {
    let json: String
    private let lock = NSLock()
    private(set) var sendCount = 0
    init(json: String) { self.json = json }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); sendCount += 1; lock.unlock()
        return (Data(json.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class EnrichmentServiceTests: XCTestCase {
    private func makeDB() async throws -> (MusicDatabase, EnrichmentStore) {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        try await writer.saveServer(ServerConnection(
            id: "srv1", kind: .plex, name: "T",
            baseURL: URL(string: "https://x.local")!, userID: nil, clientIdentifier: "c1"))
        try await writer.upsertTracks([
            Track(id: "t1", title: "Xtal", artistName: "Aphex Twin", duration: 300),
        ], serverId: "srv1")
        return (db, EnrichmentStore(db))
    }

    private func makeService(store: EnrichmentStore, json: String,
                             enabled: @escaping @Sendable () -> Bool = { true })
        -> (EnrichmentService, ServiceCannedTransport) {
        let transport = ServiceCannedTransport(json: json)
        let config = EnrichmentConfig(userAgent: "MozzTest/1 ( t@e.com )")
        let mb = MusicBrainzClient.make(
            config: config, limiter: AsyncRateLimiter(minInterval: 0), baseTransport: transport)
        // ListenBrainz stages get a benign transport (empty array): canonical
        // lookup decode-fails -> nil (stamped), similarity is empty. B1-focused
        // tests only assert stage-1 resolution.
        let lb = ListenBrainzClient.make(
            config: config, limiter: AsyncRateLimiter(minInterval: 0),
            baseTransport: ServiceCannedTransport(json: "[]"))
        let service = EnrichmentService(
            store: store, musicBrainz: mb, listenBrainz: lb,
            config: config, isEnabled: enabled)
        return (service, transport)
    }

    private let hitJSON = """
        {"recordings":[{"id":"\(recA)","score":100,
          "artist-credit":[{"artist":{"id":"\(artistA)","name":"Aphex Twin"}}]}]}
        """

    func testResolvePendingWritesFoundMBID() async throws {
        let (_, store) = try await makeDB()
        let (service, _) = makeService(store: store, json: hitJSON)
        await service.enrich(serverId: "srv1")
        await service.waitForBackgroundPass()
        let state = try await store.mbidState(trackRef: "srv1:t1")
        XCTAssertEqual(state?.mbid, recA)
        XCTAssertEqual(state?.artistMbid, artistA)
        XCTAssertEqual(state?.lookupStatus, "found")
    }

    func testResolvePendingRecordsMiss() async throws {
        let (_, store) = try await makeDB()
        let (service, _) = makeService(store: store, json: "{\"recordings\":[]}")
        await service.enrich(serverId: "srv1")
        await service.waitForBackgroundPass()
        let state = try await store.mbidState(trackRef: "srv1:t1")
        XCTAssertNil(state?.mbid)
        XCTAssertEqual(state?.lookupStatus, "notfound")
    }

    func testDisabledIsNoOp() async throws {
        let (_, store) = try await makeDB()
        let (service, transport) = makeService(store: store, json: hitJSON, enabled: { false })
        await service.enrich(serverId: "srv1")
        await service.waitForBackgroundPass()
        let state = try await store.mbidState(trackRef: "srv1:t1")
        XCTAssertNil(state) // nothing written
        XCTAssertEqual(transport.sendCount, 0) // no outbound request
    }

    func testResolveSeedResolvesThenCaches() async throws {
        let (_, store) = try await makeDB()
        let (service, transport) = makeService(store: store, json: hitJSON)
        let first = await service.resolveSeed(
            trackRef: "srv1:t1", artistName: "Aphex Twin", title: "Xtal",
            durationMs: nil, artistMBID: nil)
        XCTAssertEqual(first, recA)
        XCTAssertEqual(transport.sendCount, 1)
        // A second call returns the cached MBID without another request.
        let second = await service.resolveSeed(
            trackRef: "srv1:t1", artistName: "Aphex Twin", title: "Xtal",
            durationMs: nil, artistMBID: nil)
        XCTAssertEqual(second, recA)
        XCTAssertEqual(transport.sendCount, 1)
    }

    func testResolveSeedDisabledReturnsNil() async throws {
        let (_, store) = try await makeDB()
        let (service, _) = makeService(store: store, json: hitJSON, enabled: { false })
        let result = await service.resolveSeed(
            trackRef: "srv1:t1", artistName: "Aphex Twin", title: "Xtal",
            durationMs: nil, artistMBID: nil)
        XCTAssertNil(result)
    }

    func testTagStageCapturesArtistGenres() async throws {
        let (db, store) = try await makeDB()
        // Routes recording-search vs artist-genres by path so stage 1 (resolve) and
        // stage 4 (tags) get distinct bodies from one MusicBrainz client.
        let transport = PathRoutingTransport(
            recordingJSON: hitJSON,
            artistJSON: """
                {"genres":[{"name":"Ambient","count":30},
                           {"name":"IDM","count":22},
                           {"name":"x","count":1}]}
                """)
        let config = EnrichmentConfig(userAgent: "MozzTest/1 ( t@e.com )")
        let mb = MusicBrainzClient.make(
            config: config, limiter: AsyncRateLimiter(minInterval: 0), baseTransport: transport)
        let lb = ListenBrainzClient.make(
            config: config, limiter: AsyncRateLimiter(minInterval: 0),
            baseTransport: ServiceCannedTransport(json: "[]"))
        let service = EnrichmentService(
            store: store, musicBrainz: mb, listenBrainz: lb, config: config, isEnabled: { true })
        await service.enrich(serverId: "srv1")
        await service.waitForBackgroundPass()

        // Stage 1 resolved the artist MBID; stage 4 then captured its genres into
        // the DISTINCT mb_tags column (1-vote tag dropped, lowercased, ordered).
        let row = try await db.read { try Row.fetchOne($0, sql: """
            SELECT mb_tags, mb_tags_lookup_at, tags FROM track_features WHERE track_ref = ?
            """, arguments: ["srv1:t1"]) }
        let mbTags: String? = row?["mb_tags"]
        let at: Double? = row?["mb_tags_lookup_at"]
        let reservedTags: String? = row?["tags"]
        XCTAssertEqual(mbTags, "[\"ambient\",\"idm\"]")
        XCTAssertNotNil(at)
        XCTAssertNil(reservedTags)                    // reserved column untouched
        XCTAssertEqual(transport.artistRequestCount, 1) // one call per distinct artist
    }

    func testSingleFlightPreventsOverlappingPasses() async throws {
        let (_, store) = try await makeDB()
        let transport = GatedTransport(json: hitJSON)
        let config = EnrichmentConfig(userAgent: "MozzTest/1 ( t@e.com )")
        let mb = MusicBrainzClient.make(
            config: config, limiter: AsyncRateLimiter(minInterval: 0), baseTransport: transport)
        let lb = ListenBrainzClient.make(
            config: config, limiter: AsyncRateLimiter(minInterval: 0),
            baseTransport: ServiceCannedTransport(json: "[]"))
        let service = EnrichmentService(
            store: store, musicBrainz: mb, listenBrainz: lb, config: config, isEnabled: { true })
        await service.enrich(serverId: "srv1") // pass 1 starts, blocks in transport
        try await Task.sleep(nanoseconds: 60_000_000)   // let pass 1 reach the request
        await service.enrich(serverId: "srv1") // must be a no-op (single-flight)
        transport.open()
        await service.waitForBackgroundPass()
        // A single pass makes exactly two MusicBrainz calls (stage-1 resolve +
        // stage-4 artist tags); a second overlapping pass would add more. So this
        // proves single-flight held.
        XCTAssertEqual(transport.sendCount, 2)
    }
}

/// Blocks the first request until `open()` so a pass can be held in-flight while
/// single-flight is exercised.
private final class GatedTransport: HTTPTransport, @unchecked Sendable {
    let json: String
    private let lock = NSLock()
    private(set) var sendCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    init(json: String) { self.json = json }
    func open() {
        lock.lock(); opened = true; let c = continuation; continuation = nil; lock.unlock()
        c?.resume()
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); sendCount += 1; lock.unlock()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened { lock.unlock(); c.resume() } else { continuation = c; lock.unlock() }
        }
        return (Data(json.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// Returns one body for `/ws/2/artist/…` (artist-genres) requests and another for
/// everything else (recording search), so a single MusicBrainz client can drive
/// both the resolve stage and the tag stage in one pipeline pass.
private final class PathRoutingTransport: HTTPTransport, @unchecked Sendable {
    let recordingJSON: String
    let artistJSON: String
    private let lock = NSLock()
    private(set) var artistRequestCount = 0
    init(recordingJSON: String, artistJSON: String) {
        self.recordingJSON = recordingJSON
        self.artistJSON = artistJSON
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let json: String
        if path.contains("/ws/2/artist/") {
            lock.lock(); artistRequestCount += 1; lock.unlock()
            json = artistJSON
        } else {
            json = recordingJSON
        }
        return (Data(json.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
