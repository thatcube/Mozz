import XCTest
import MozzCore
import GRDB
@testable import MozzDatabase

private func server(_ id: String = "srv1") -> ServerConnection {
    ServerConnection(id: id, kind: .plex, name: "T",
                     baseURL: URL(string: "https://x.local")!, userID: nil, clientIdentifier: "c1")
}

// Distinct canonical/raw MBIDs.
private let rawA  = "aaaaaaa1-0000-4000-8000-000000000001"
private let rawB  = "bbbbbbb2-0000-4000-8000-000000000002"
private let canA  = "caaaaaa1-0000-4000-8000-0000000000a1"
private let canB  = "cbbbbbb2-0000-4000-8000-0000000000b2"
private let seed1 = "5eed0001-0000-4000-8000-0000000000e1"
private let seed2 = "5eed0002-0000-4000-8000-0000000000e2"
private let algo  = "algoX"

final class SimilarityStoreTests: XCTestCase {
    private func setup() async throws -> (MusicDatabase, CatalogWriter, EnrichmentStore) {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        try await writer.saveServer(server())
        return (db, writer, EnrichmentStore(db))
    }

    /// Two owned tracks with resolved+canonicalized MBIDs.
    private func seedOwnedTracks(_ writer: CatalogWriter, _ store: EnrichmentStore) async throws {
        try await writer.upsertTracks([
            Track(id: "tA", title: "A", artistName: "AA", mbid: rawA),
            Track(id: "tB", title: "B", artistName: "BB", mbid: rawB),
        ], serverId: "srv1")
        try await store.setCanonical(mbid: rawA, canonical: canA, at: 100)
        try await store.setCanonical(mbid: rawB, canonical: canB, at: 100)
    }

    func testCanonicalNeedingLookupRespectsState() async throws {
        let (_, writer, store) = try await setup()
        try await writer.upsertTracks([
            Track(id: "tA", title: "A", artistName: "AA", mbid: rawA),
        ], serverId: "srv1")
        var needing = try await store.canonicalNeedingLookup(serverId: "srv1", notLookedUpSince: 1_000, limit: 10)
        XCTAssertEqual(needing, [rawA])
        try await store.setCanonical(mbid: rawA, canonical: canA, at: 100)
        needing = try await store.canonicalNeedingLookup(serverId: "srv1", notLookedUpSince: 1_000, limit: 10)
        XCTAssertTrue(needing.isEmpty)
    }

    func testCanonicalFallbackNilStampsForTTLRetry() async throws {
        let (_, writer, store) = try await setup()
        try await writer.upsertTracks([Track(id: "tA", title: "A", artistName: "AA", mbid: rawA)], serverId: "srv1")
        // Transient failure: canonical nil, only timestamp stamped.
        try await store.setCanonical(mbid: rawA, canonical: nil, at: 2_000)
        // Excluded until the TTL cutoff passes; due again after.
        let before = try await store.canonicalNeedingLookup(serverId: "srv1", notLookedUpSince: 1_000, limit: 10)
        XCTAssertTrue(before.isEmpty)
        let after = try await store.canonicalNeedingLookup(serverId: "srv1", notLookedUpSince: 3_000, limit: 10)
        XCTAssertEqual(after, [rawA])
    }

    func testReplaceSimilarStampsLookupEvenWhenEmpty() async throws {
        let (_, writer, store) = try await setup()
        try await seedOwnedTracks(writer, store)
        // Empty result must still stamp similar_lookup_at (negative cache).
        try await store.replaceSimilarRecordings(sourceMbid: canA, algorithm: algo, pairs: [], at: 500)
        let needing = try await store.recordingsNeedingSimilarity(serverId: "srv1", notFetchedSince: 400, limit: 10)
        XCTAssertFalse(needing.contains(canA)) // canA fetched (empty) → not due
        XCTAssertTrue(needing.contains(canB))  // canB never fetched → due
    }

    func testSimilarOwnedTracksReverseMapRanked() async throws {
        let (_, writer, store) = try await setup()
        try await seedOwnedTracks(writer, store)
        try await store.replaceSimilarRecordings(sourceMbid: seed1, algorithm: algo, pairs: [
            (canB, 0.9), (canA, 0.5),
            ("dddddddd-0000-4000-8000-00000000dddd", 0.99), // not owned → dropped
        ], at: 500)
        let out = try await store.similarOwnedTracks(
            seedCanonicalMbids: [seed1], algorithm: algo, serverId: "srv1", limit: 10)
        XCTAssertEqual(out.map { $0.candidate.remoteId }, ["tB", "tA"]) // ranked by score
        XCTAssertEqual(out.first?.score, 0.9)
    }

    func testSimilarOwnedTracksMultiSeedMax() async throws {
        let (_, writer, store) = try await setup()
        try await seedOwnedTracks(writer, store)
        try await store.replaceSimilarRecordings(sourceMbid: seed1, algorithm: algo, pairs: [(canB, 0.4)], at: 500)
        try await store.replaceSimilarRecordings(sourceMbid: seed2, algorithm: algo, pairs: [(canB, 0.8)], at: 500)
        let out = try await store.similarOwnedTracks(
            seedCanonicalMbids: [seed1, seed2], algorithm: algo, serverId: "srv1", limit: 10)
        XCTAssertEqual(out.count, 1)              // one row for tB, not two
        XCTAssertEqual(out.first?.candidate.remoteId, "tB")
        XCTAssertEqual(out.first?.score, 0.8)     // MAX across seeds
    }

    func testSimilarOwnedTracksAlgorithmScoped() async throws {
        let (_, writer, store) = try await setup()
        try await seedOwnedTracks(writer, store)
        try await store.replaceSimilarRecordings(sourceMbid: seed1, algorithm: "other", pairs: [(canB, 0.9)], at: 500)
        let out = try await store.similarOwnedTracks(
            seedCanonicalMbids: [seed1], algorithm: algo, serverId: "srv1", limit: 10)
        XCTAssertTrue(out.isEmpty) // different algorithm → not matched
    }

    func testSimilarOwnedTracksExcludes() async throws {
        let (_, writer, store) = try await setup()
        try await seedOwnedTracks(writer, store)
        try await store.replaceSimilarRecordings(sourceMbid: seed1, algorithm: algo, pairs: [(canB, 0.9), (canA, 0.5)], at: 500)
        let out = try await store.similarOwnedTracks(
            seedCanonicalMbids: [seed1], algorithm: algo, serverId: "srv1",
            excludingRemoteIds: ["tB"], limit: 10)
        XCTAssertEqual(out.map { $0.candidate.remoteId }, ["tA"])
    }

    func testMbidChangeClearsCanonicalAndSimilarCaches() async throws {
        let (_, writer, store) = try await setup()
        try await writer.upsertTracks([Track(id: "tA", title: "A", artistName: "AA", mbid: rawA)], serverId: "srv1")
        try await store.setCanonical(mbid: rawA, canonical: canA, at: 100)
        try await store.replaceSimilarRecordings(sourceMbid: canA, algorithm: algo, pairs: [], at: 100)
        // Re-sync with a DIFFERENT embedded recording MBID.
        try await writer.upsertTracks([Track(id: "tA", title: "A", artistName: "AA", mbid: rawB)], serverId: "srv1")
        let state = try await store.mbidState(trackRef: "srv1:tA")
        XCTAssertEqual(state?.mbid, rawB)
        // canonical + similarity caches were reset, so it's due for re-derivation.
        let needCanon = try await store.canonicalNeedingLookup(serverId: "srv1", notLookedUpSince: 1_000, limit: 10)
        XCTAssertEqual(needCanon, [rawB])
    }
}
