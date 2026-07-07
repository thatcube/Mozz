import XCTest
import Foundation
import MozzCore
import MozzNetworking
import MozzDatabase
@testable import MozzEnrichment

private let recSeed = "55258edc-bfcf-47dd-b63c-441bd8c7bf40"
private let canonSeed = "aaaa1111-bfcf-47dd-b63c-441bd8c7bf40"
private let sim1 = "11111111-1111-4111-8111-111111111111"
private let sim2 = "22222222-2222-4222-8222-222222222222"
private let algoName = "session_based_days_9000_session_300_contribution_5_threshold_15_limit_50_skip_30"

/// Routes by path; canonical responses are ARRAYS (matching the live API) keyed
/// by the requested `recording_mbid` so multiple tracks canonicalize distinctly.
private final class LBTransport: HTTPTransport, @unchecked Sendable {
    var similarJSON: String
    var canonicalByMbid: [String: String]
    var canonicalRaw: String?   // when set, returned verbatim for any lookup (malformed-body tests)
    private let lock = NSLock()
    private(set) var similarCalls = 0
    private(set) var canonicalCalls = 0
    init(similarJSON: String, canonicalByMbid: [String: String] = [:], canonicalRaw: String? = nil) {
        self.similarJSON = similarJSON; self.canonicalByMbid = canonicalByMbid; self.canonicalRaw = canonicalRaw
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let path = url.path
        let body: String
        lock.lock()
        if path.contains("similar-recordings") {
            similarCalls += 1; body = similarJSON
        } else if path.contains("recording-mbid-lookup") {
            canonicalCalls += 1
            if let raw = canonicalRaw {
                body = raw
            } else {
                let queried = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "recording_mbid" }?.value ?? ""
                if let canon = canonicalByMbid[queried] {
                    body = "[{\"canonical_recording_mbid\":\"\(canon)\",\"original_recording_mbid\":\"\(queried)\"}]"
                } else {
                    body = "[]" // no mapping
                }
            }
        } else { body = "[]" }
        lock.unlock()
        return (Data(body.utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class ListenBrainzClientTests: XCTestCase {
    private func client(_ transport: LBTransport) -> ListenBrainzClient {
        ListenBrainzClient.make(
            config: EnrichmentConfig(userAgent: "t"), limiter: AsyncRateLimiter(minInterval: 0),
            baseTransport: transport)
    }

    func testParsesSimilarRecordings() async throws {
        let json = """
            [{"recording_mbid":"\(sim1)","score":95,"recording_name":"X","artist_credit_mbids":null},
             {"recording_mbid":"\(sim2)","score":40,"release_mbid":null}]
            """
        let out = try await client(LBTransport(similarJSON: json)).similarRecordings(forCanonicalMbid: canonSeed)
        XCTAssertEqual(out.map(\.recordingMBID), [sim1, sim2])
        XCTAssertEqual(out.first?.score, 95)
    }

    func testEmptySimilarReturnsEmpty() async throws {
        let out = try await client(LBTransport(similarJSON: "[]")).similarRecordings(forCanonicalMbid: canonSeed)
        XCTAssertTrue(out.isEmpty)
    }

    func testSkipsInvalidAndSelfMBIDs() async throws {
        let json = """
            [{"recording_mbid":"not-a-uuid","score":99},
             {"recording_mbid":"\(canonSeed)","score":88},
             {"recording_mbid":"\(sim1)","score":70}]
            """
        let out = try await client(LBTransport(similarJSON: json)).similarRecordings(forCanonicalMbid: canonSeed)
        XCTAssertEqual(out.map(\.recordingMBID), [sim1]) // invalid + self dropped
    }

    func testCanonicalRecordingParsesArray() async throws {
        let t = LBTransport(similarJSON: "[]", canonicalByMbid: [recSeed: canonSeed])
        let canon = try await client(t).canonicalRecording(forMbid: recSeed)
        XCTAssertEqual(canon, canonSeed)
    }

    func testCanonicalRecordingNilOnNoMapping() async throws {
        // Empty array = decoded but no mapping -> nil (caller TTL-stamps).
        let canon = try await client(LBTransport(similarJSON: "[]")).canonicalRecording(forMbid: recSeed)
        XCTAssertNil(canon)
    }

    func testCanonicalRecordingThrowsOnMalformedBody() async {
        // A 500-style object body (not an array) must THROW, not be cached as nil.
        let t = LBTransport(similarJSON: "[]", canonicalRaw: "{}")
        do {
            _ = try await client(t).canonicalRecording(forMbid: recSeed)
            XCTFail("expected a decoding error")
        } catch { /* expected */ }
    }
}

final class EnrichmentPipelineTests: XCTestCase {
    private func makeDB() async throws -> (MusicDatabase, EnrichmentStore) {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        try await writer.saveServer(ServerConnection(
            id: "srv1", kind: .plex, name: "T",
            baseURL: URL(string: "https://x.local")!, userID: nil, clientIdentifier: "c1"))
        try await writer.upsertTracks([
            Track(id: "t1", title: "Xtal", artistName: "Aphex Twin", duration: 300, mbid: recSeed),
            Track(id: "t2", title: "Other", artistName: "Other", mbid: sim1),
        ], serverId: "srv1")
        return (db, EnrichmentStore(db))
    }

    func testFullPipelinePopulatesSimilarityAndReverseMap() async throws {
        let (_, store) = try await makeDB()
        let config = EnrichmentConfig(userAgent: "t", listenBrainzAlgorithm: algoName)
        let mb = MusicBrainzClient.make(config: config, limiter: AsyncRateLimiter(minInterval: 0),
                                        baseTransport: LBTransport(similarJSON: "[]"))
        // Both tracks canonicalize distinctly through the REAL stage-2 (no pre-seed):
        // t1 recSeed -> canonSeed, t2 sim1 -> sim1.
        let lbTransport = LBTransport(
            similarJSON: "[{\"recording_mbid\":\"\(sim1)\",\"score\":0.9}]",
            canonicalByMbid: [recSeed: canonSeed, sim1: sim1])
        let lb = ListenBrainzClient.make(config: config, limiter: AsyncRateLimiter(minInterval: 0),
                                         baseTransport: lbTransport)
        let service = EnrichmentService(store: store, musicBrainz: mb, listenBrainz: lb,
                                        config: config, isEnabled: { true })
        await service.enrich(serverId: "srv1")
        await service.waitForBackgroundPass()

        // t1 -> canonSeed; similar (canonSeed -> sim1) maps to owned t2 (canonical sim1).
        let out = try await store.similarOwnedTracks(
            seedCanonicalMbids: [canonSeed], algorithm: algoName, serverId: "srv1", limit: 10)
        XCTAssertEqual(out.map { $0.candidate.remoteId }, ["t2"])
    }

    func testCancelStopsPipelineBeforeSimilarityStage() async throws {
        let (_, store) = try await makeDB()
        let config = EnrichmentConfig(userAgent: "t", listenBrainzAlgorithm: algoName)
        let mb = MusicBrainzClient.make(config: config, limiter: AsyncRateLimiter(minInterval: 0),
                                        baseTransport: LBTransport(similarJSON: "[]"))
        // Block the first canonical (stage 2) request so we can cancel mid-flight.
        let gate = GatedLBTransport(canonical: canonSeed)
        let lb = ListenBrainzClient.make(config: config, limiter: AsyncRateLimiter(minInterval: 0),
                                         baseTransport: gate)
        let service = EnrichmentService(store: store, musicBrainz: mb, listenBrainz: lb,
                                        config: config, isEnabled: { true })
        await service.enrich(serverId: "srv1")
        try await Task.sleep(nanoseconds: 60_000_000) // let stage 2 block on the gate
        await service.cancel()
        gate.open()
        try await Task.sleep(nanoseconds: 150_000_000) // let the (cancelled) task fully unwind
        XCTAssertEqual(gate.similarCalls, 0) // stage 3 never ran after cancellation
    }

    func testPrepareSeedNoMappingNegativeCaches() async throws {
        let (_, store) = try await makeDB()
        let config = EnrichmentConfig(userAgent: "t", listenBrainzAlgorithm: algoName)
        let mb = MusicBrainzClient.make(config: config, limiter: AsyncRateLimiter(minInterval: 0),
                                        baseTransport: LBTransport(similarJSON: "[]"))
        // Empty canonicalByMbid → recording-mbid-lookup returns "[]" (genuine "no mapping").
        let lb = ListenBrainzClient.make(config: config, limiter: AsyncRateLimiter(minInterval: 0),
                                         baseTransport: LBTransport(similarJSON: "[]"))
        let service = EnrichmentService(store: store, musicBrainz: mb, listenBrainz: lb,
                                        config: config, isEnabled: { true })
        let result = await service.prepareSeedSimilarity(
            trackRef: "srv1:t1", artistName: "Aphex Twin", title: "Xtal",
            durationMs: 300_000, artistMBID: nil)
        XCTAssertNil(result) // no canonical mapping
        // A genuine no-mapping must be negative-cached, not re-queried every call.
        let needing = try await store.canonicalNeedingLookup(serverId: "srv1", notLookedUpSince: 0, limit: 10)
        XCTAssertFalse(needing.contains(recSeed))
    }
}

/// Blocks the first recording-mbid-lookup request until `open()`, so cancellation
/// can be exercised while stage 2 is in flight.
private final class GatedLBTransport: HTTPTransport, @unchecked Sendable {
    let canonical: String
    private let lock = NSLock()
    private(set) var similarCalls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    init(canonical: String) { self.canonical = canonical }
    func open() {
        lock.lock(); opened = true; let c = continuation; continuation = nil; lock.unlock()
        c?.resume()
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if url.path.contains("similar-recordings") {
            lock.lock(); similarCalls += 1; lock.unlock()
            return (Data("[]".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        // recording-mbid-lookup: block once until open().
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened { lock.unlock(); c.resume() } else { continuation = c; lock.unlock() }
        }
        let body = "[{\"canonical_recording_mbid\":\"\(canonical)\"}]"
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
