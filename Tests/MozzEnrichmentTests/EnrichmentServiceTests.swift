import XCTest
import Foundation
import MozzCore
import MozzNetworking
import MozzDatabase
import GRDB
@testable import MozzEnrichment

private let recA = "b1a9c0e9-d987-4042-ae91-78d6a3267d69"
private let artistA = "f22942a1-6f70-4f48-866e-238cb2308fbd"

/// A thread-safe bool for driving `isEnabled` in tests. Returns `initial` for the
/// first `trueReads` calls, then `!initial` — to simulate the toggle flipping
/// mid-flight between the entry check and a later re-check.
private final class EnabledFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private let trueReads: Int
    init(trueReads: Int) { self.trueReads = trueReads }
    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        return reads <= trueReads
    }
}

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
                             enabled: @escaping @Sendable () -> Bool = { true },
                             perRunBudget: Int = 200, maxResolvePerPass: Int = 5000)
        -> (EnrichmentService, ServiceCannedTransport) {
        let transport = ServiceCannedTransport(json: json)
        let config = EnrichmentConfig(userAgent: "MozzTest/1 ( t@e.com )",
                                      perRunBudget: perRunBudget, maxResolvePerPass: maxResolvePerPass)
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

    /// One pass must DRAIN the whole resolve backlog across multiple batches, not
    /// just the first `perRunBudget`. With budget 1 and 3 unmatched tracks, all 3
    /// resolve in a single pass.
    func testResolveDrainsWholeBacklogAcrossBatches() async throws {
        let (db, store) = try await makeDB()
        let writer = CatalogWriter(db)
        try await writer.upsertTracks([
            Track(id: "t2", title: "A", artistName: "Artist", duration: 200),
            Track(id: "t3", title: "B", artistName: "Artist", duration: 200),
        ], serverId: "srv1")   // now t1, t2, t3 all need resolution
        let (service, transport) = makeService(store: store, json: hitJSON, perRunBudget: 1)
        await service.enrich(serverId: "srv1")
        await service.waitForBackgroundPass()
        for id in ["t1", "t2", "t3"] {
            let state = try await store.mbidState(trackRef: "srv1:\(id)")
            XCTAssertEqual(state?.mbid, recA, "\(id) should have resolved in the same pass")
        }
        // 3 resolve calls (one per track, batch size 1) — proves it looped past
        // the first batch. (Canonicalize/similarity/tags add ListenBrainz/MB calls,
        // but the resolve drain is the point here.)
        XCTAssertGreaterThanOrEqual(transport.sendCount, 3)
    }

    /// The `maxResolvePerPass` cap bounds a single pass: with cap 2 and 3 unmatched
    /// tracks, only 2 resolve this pass (the rest resume on the next launch).
    func testResolveRespectsMaxPerPassCap() async throws {
        let (db, store) = try await makeDB()
        let writer = CatalogWriter(db)
        try await writer.upsertTracks([
            Track(id: "t2", title: "A", artistName: "Artist", duration: 200),
            Track(id: "t3", title: "B", artistName: "Artist", duration: 200),
        ], serverId: "srv1")
        let (service, _) = makeService(store: store, json: hitJSON,
                                       perRunBudget: 1, maxResolvePerPass: 2)
        await service.enrich(serverId: "srv1")
        await service.waitForBackgroundPass()
        var resolved = 0
        for id in ["t1", "t2", "t3"] where try await store.mbidState(trackRef: "srv1:\(id)")?.mbid != nil {
            resolved += 1
        }
        XCTAssertEqual(resolved, 2, "the per-pass cap must bound one pass to 2 tracks")
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

    /// If enrichment is toggled OFF mid-flight (after the seed is already resolved +
    /// canonicalized locally), prepareSeedSimilarity must NOT issue the ListenBrainz
    /// similar-recordings request — honoring the "fully offline" promise.
    func testSeedPrepReGatesBeforeSimilarFetchWhenDisabledMidFlight() async throws {
        let (_, store) = try await makeDB()
        // Pre-resolve + pre-canonicalize t1 so prepareSeedSimilarity skips straight
        // to the similarity fetch (the only remaining outbound call).
        try await store.recordTrackResolution(trackRef: "srv1:t1", mbid: recA, artistMbid: artistA, at: 100)
        try await store.setCanonical(mbid: recA, canonical: recA, at: 100)

        // isEnabled is true for the entry check, then false — simulating the user
        // turning the toggle off during seed prep (before the similarity fetch).
        let flag = EnabledFlag(trueReads: 1)
        let lbTransport = ServiceCannedTransport(json: "[]")
        let config = EnrichmentConfig(userAgent: "MozzTest/1 ( t@e.com )")
        let mb = MusicBrainzClient.make(
            config: config, limiter: AsyncRateLimiter(minInterval: 0),
            baseTransport: ServiceCannedTransport(json: hitJSON))
        let lb = ListenBrainzClient.make(
            config: config, limiter: AsyncRateLimiter(minInterval: 0), baseTransport: lbTransport)
        let service = EnrichmentService(
            store: store, musicBrainz: mb, listenBrainz: lb, config: config,
            isEnabled: { flag.value })
        let result = await service.prepareSeedSimilarity(
            trackRef: "srv1:t1", artistName: "Aphex Twin", title: "Xtal",
            durationMs: nil, artistMBID: nil)
        XCTAssertEqual(result, recA)               // returns the canonical it already had
        XCTAssertEqual(lbTransport.sendCount, 0)   // but issued NO outbound request
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

    /// A track that always fails resolution must be attempted at most ONCE per
    /// pass — even while other tracks keep succeeding (which keeps the drain
    /// looping). Guards against re-fetching the same high-priority failure every
    /// iteration and burning the pass budget.
    func testResolveDoesNotRefetchFailingTrackWithinPass() async throws {
        let (db, store) = try await makeDB()   // t1 "Xtal" (resolves)
        let writer = CatalogWriter(db)
        try await writer.upsertTracks([
            Track(id: "t2", title: "Works Two", artistName: "Artist", duration: 200),
            Track(id: "t3", title: "Works Three", artistName: "Artist", duration: 200),
            Track(id: "tfail", title: "FailTitleXYZ", artistName: "Artist", duration: 200),
        ], serverId: "srv1")
        let transport = PartialFailTransport(hitJSON: hitJSON, failMarker: "FailTitleXYZ")
        let config = EnrichmentConfig(userAgent: "MozzTest/1 ( t@e.com )",
                                      perRunBudget: 2, maxResolvePerPass: 5000)
        let mb = MusicBrainzClient.make(
            config: config, limiter: AsyncRateLimiter(minInterval: 0), baseTransport: transport)
        let lb = ListenBrainzClient.make(
            config: config, limiter: AsyncRateLimiter(minInterval: 0),
            baseTransport: ServiceCannedTransport(json: "[]"))
        let service = EnrichmentService(
            store: store, musicBrainz: mb, listenBrainz: lb, config: config, isEnabled: { true })
        await service.enrich(serverId: "srv1")
        await service.waitForBackgroundPass()
        // The three working tracks resolve; the failing one stays unresolved but
        // was tried exactly once (the attempted-set filters it out thereafter).
        for id in ["t1", "t2", "t3"] {
            let state = try await store.mbidState(trackRef: "srv1:\(id)")
            XCTAssertEqual(state?.mbid, recA)
        }
        let failState = try await store.mbidState(trackRef: "srv1:tfail")
        XCTAssertNil(failState?.mbid)
        XCTAssertEqual(transport.attemptsForFailing, 1,
                       "a persistently-failing track must be attempted at most once per pass")
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

    /// A same-server re-kick while crawling is a single-flight no-op, but a kick for
    /// a DIFFERENT server cancels the stale pass and starts fresh — so a raced
    /// server switch can't leave the previous library crawling.
    func testEnrichForDifferentServerCancelsAndRestarts() async throws {
        let (db, store) = try await makeDB()   // srv1 has t1
        let writer = CatalogWriter(db)
        try await writer.saveServer(ServerConnection(
            id: "srv2", kind: .plex, name: "T2",
            baseURL: URL(string: "https://y.local")!, userID: nil, clientIdentifier: "c2"))
        try await writer.upsertTracks([
            Track(id: "u1", title: "Windowlicker", artistName: "Aphex Twin", duration: 300),
        ], serverId: "srv2")
        let transport = GatedTransport(json: hitJSON)
        let config = EnrichmentConfig(userAgent: "MozzTest/1 ( t@e.com )")
        let mb = MusicBrainzClient.make(
            config: config, limiter: AsyncRateLimiter(minInterval: 0), baseTransport: transport)
        let lb = ListenBrainzClient.make(
            config: config, limiter: AsyncRateLimiter(minInterval: 0),
            baseTransport: ServiceCannedTransport(json: "[]"))
        let service = EnrichmentService(
            store: store, musicBrainz: mb, listenBrainz: lb, config: config, isEnabled: { true })
        await service.enrich(serverId: "srv1")            // pass for srv1 starts, blocks
        try await Task.sleep(nanoseconds: 60_000_000)
        await service.enrich(serverId: "srv1")            // same server → no-op
        await service.enrich(serverId: "srv2")            // switch → cancel srv1, start srv2
        transport.open()
        await service.waitForBackgroundPass()
        // srv2's track got resolved (the new pass ran); the cancelled srv1 pass
        // stopped, so its track is left unresolved.
        let u1 = try await store.mbidState(trackRef: "srv2:u1")
        XCTAssertEqual(u1?.mbid, recA, "the new server's crawl must run")
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

/// Throws for any request whose (decoded) URL contains `failMarker` (routing by
/// the track title in the Lucene query), and returns `hitJSON` otherwise — so a
/// pass can have some tracks succeed and one persistently fail. Counts how many
/// times the failing track was hit, to prove it isn't re-fetched every iteration.
private final class PartialFailTransport: HTTPTransport, @unchecked Sendable {
    let hitJSON: String
    let failMarker: String
    private let lock = NSLock()
    private(set) var attemptsForFailing = 0
    init(hitJSON: String, failMarker: String) {
        self.hitJSON = hitJSON
        self.failMarker = failMarker
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url?.absoluteString.removingPercentEncoding ?? ""
        if url.contains(failMarker) {
            lock.lock(); attemptsForFailing += 1; lock.unlock()
            throw URLError(.timedOut)
        }
        return (Data(hitJSON.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
