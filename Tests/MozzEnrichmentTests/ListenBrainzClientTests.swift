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

/// Serves different JSON by request path so canonicalization + similarity can be
/// exercised together.
private final class LBTransport: HTTPTransport, @unchecked Sendable {
    var similarJSON: String
    var canonicalJSON: String
    private let lock = NSLock()
    private(set) var similarCalls = 0
    private(set) var canonicalCalls = 0
    init(similarJSON: String, canonicalJSON: String) {
        self.similarJSON = similarJSON; self.canonicalJSON = canonicalJSON
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let body: String
        lock.lock()
        if path.contains("similar-recordings") { similarCalls += 1; body = similarJSON }
        else if path.contains("recording-mbid-lookup") { canonicalCalls += 1; body = canonicalJSON }
        else { body = "[]" }
        lock.unlock()
        return (Data(body.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
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
        let t = LBTransport(similarJSON: json, canonicalJSON: "{}")
        let out = try await client(t).similarRecordings(forCanonicalMbid: canonSeed)
        XCTAssertEqual(out.map(\.recordingMBID), [sim1, sim2])
        XCTAssertEqual(out.first?.score, 95)
    }

    func testEmptySimilarReturnsEmpty() async throws {
        let out = try await client(LBTransport(similarJSON: "[]", canonicalJSON: "{}"))
            .similarRecordings(forCanonicalMbid: canonSeed)
        XCTAssertTrue(out.isEmpty)
    }

    func testSkipsInvalidAndSelfMBIDs() async throws {
        let json = """
            [{"recording_mbid":"not-a-uuid","score":99},
             {"recording_mbid":"\(canonSeed)","score":88},
             {"recording_mbid":"\(sim1)","score":70}]
            """
        let out = try await client(LBTransport(similarJSON: json, canonicalJSON: "{}"))
            .similarRecordings(forCanonicalMbid: canonSeed)
        XCTAssertEqual(out.map(\.recordingMBID), [sim1]) // invalid + self dropped
    }

    func testCanonicalRecording() async throws {
        let t = LBTransport(similarJSON: "[]",
                            canonicalJSON: "{\"canonical_recording_mbid\":\"\(canonSeed)\",\"original_recording_mbid\":\"\(recSeed)\"}")
        let canon = await client(t).canonicalRecording(forMbid: recSeed)
        XCTAssertEqual(canon, canonSeed)
    }

    func testCanonicalRecordingNilOnEmptyObject() async throws {
        let canon = await client(LBTransport(similarJSON: "[]", canonicalJSON: "{}"))
            .canonicalRecording(forMbid: recSeed)
        XCTAssertNil(canon) // no mapping → nil (caller TTL-stamps for retry)
    }
}

final class EnrichmentPipelineTests: XCTestCase {
    private func makeDB() async throws -> (MusicDatabase, EnrichmentStore) {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        try await writer.saveServer(ServerConnection(
            id: "srv1", kind: .plex, name: "T",
            baseURL: URL(string: "https://x.local")!, userID: nil, clientIdentifier: "c1"))
        // A track with an embedded recording MBID (skips stage-1 name-search).
        try await writer.upsertTracks([
            Track(id: "t1", title: "Xtal", artistName: "Aphex Twin", duration: 300, mbid: recSeed),
            // An owned track whose canonical == the similar MBID we'll return.
            Track(id: "t2", title: "Other", artistName: "Other", mbid: sim1),
        ], serverId: "srv1")
        return (db, EnrichmentStore(db))
    }

    func testFullPipelinePopulatesSimilarityAndReverseMap() async throws {
        let (db, store) = try await makeDB()
        // t2's canonical must equal the similar MBID so the reverse map hits.
        try await store.setCanonical(mbid: sim1, canonical: sim1, at: 1)
        let config = EnrichmentConfig(userAgent: "t", listenBrainzAlgorithm: algoName)
        let mb = MusicBrainzClient.make(config: config, limiter: AsyncRateLimiter(minInterval: 0),
                                        baseTransport: LBTransport(similarJSON: "[]", canonicalJSON: "{}"))
        let lbTransport = LBTransport(
            similarJSON: "[{\"recording_mbid\":\"\(sim1)\",\"score\":0.9}]",
            canonicalJSON: "{\"canonical_recording_mbid\":\"\(canonSeed)\"}")
        let lb = ListenBrainzClient.make(config: config, limiter: AsyncRateLimiter(minInterval: 0),
                                         baseTransport: lbTransport)
        let service = EnrichmentService(store: store, musicBrainz: mb, listenBrainz: lb,
                                        config: config, isEnabled: { true })
        await service.enrich(serverId: "srv1")
        await service.waitForBackgroundPass()

        // t1 canonicalized to canonSeed, similarity fetched → similar_recording row.
        let out = try await store.similarOwnedTracks(
            seedCanonicalMbids: [canonSeed], algorithm: algoName, serverId: "srv1", limit: 10)
        XCTAssertEqual(out.map { $0.candidate.remoteId }, ["t2"]) // reverse map surfaced the owned track
    }

    private let algoName = "session_based_days_9000_session_300_contribution_5_threshold_15_limit_50_skip_30"
}
