import XCTest
import MozzCore
import GRDB
@testable import MozzDatabase

private func server(_ id: String = "srv1") -> ServerConnection {
    ServerConnection(id: id, kind: .plex, name: "T",
                     baseURL: URL(string: "https://x.local")!, userID: nil, clientIdentifier: "c1")
}
private let mbidA = "b1a9c0e9-d987-4042-ae91-78d6a3267d69"
private let mbidB = "c2b8d1f0-1234-4567-8999-aabbccddeeff"
private let artistMbid = "f22942a1-6f70-4f48-866e-238cb2308fbd"

final class EnrichmentStoreTests: XCTestCase {
    private func setup() async throws -> (MusicDatabase, CatalogWriter, EnrichmentStore) {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        try await writer.saveServer(server())
        return (db, writer, EnrichmentStore(db))
    }

    func testEmbeddedCaptureDuringTrackUpsert() async throws {
        let (_, writer, store) = try await setup()
        try await writer.upsertTracks([
            Track(id: "t1", title: "Song", artistName: "Artist", mbid: mbidA, artistMbid: artistMbid),
        ], serverId: "srv1")
        let state = try await store.mbidState(trackRef: "srv1:t1")
        XCTAssertEqual(state?.mbid, mbidA)
        XCTAssertEqual(state?.artistMbid, artistMbid)
        XCTAssertEqual(state?.lookupStatus, "embedded")
    }

    func testEmbeddedCaptureIgnoresTracksWithoutMBID() async throws {
        let (_, writer, store) = try await setup()
        try await writer.upsertTracks([
            Track(id: "t9", title: "No MBID", artistName: "Artist"),
        ], serverId: "srv1")
        let state = try await store.mbidState(trackRef: "srv1:t9")
        XCTAssertNil(state) // no track_features row created for a no-MBID track
    }

    func testPartialUpsertPreservesTagsAndEmbedding() async throws {
        let (db, writer, store) = try await setup()
        // Pre-existing enrichment (tags + a sonic embedding) that must survive.
        try await db.write { database in
            try database.execute(sql: """
                INSERT INTO track_features (track_ref, tags, embedding, feature_source, updated_at)
                VALUES (?, ?, ?, 'ondevice', ?)
                """, arguments: ["srv1:t1", "[\"dreampop\"]", Data([1, 2, 3, 4]), 100.0])
        }
        try await writer.upsertTracks([
            Track(id: "t1", title: "Song", artistName: "Artist", mbid: mbidA),
        ], serverId: "srv1")
        let row = try await db.read { try Row.fetchOne($0, sql: """
            SELECT mbid, tags, embedding, feature_source FROM track_features WHERE track_ref = ?
            """, arguments: ["srv1:t1"]) }
        XCTAssertEqual(row?["mbid"], mbidA)
        XCTAssertEqual(row?["tags"], "[\"dreampop\"]")
        XCTAssertEqual((row?["embedding"] as Data?), Data([1, 2, 3, 4]))
        XCTAssertEqual(row?["feature_source"], "ondevice") // untouched by MBID path
    }

    func testArtistMbidCoalescedNotClobbered() async throws {
        let (_, writer, store) = try await setup()
        // A name-search earlier resolved the artist MBID.
        try await store.recordTrackResolution(trackRef: "srv1:t1", mbid: mbidA,
                                              artistMbid: artistMbid, at: 100)
        // A later embedded upsert (Plex: no artist MBID on the track) must not wipe it.
        try await writer.upsertTracks([
            Track(id: "t1", title: "Song", artistName: "Artist", mbid: mbidB, artistMbid: nil),
        ], serverId: "srv1")
        let state = try await store.mbidState(trackRef: "srv1:t1")
        XCTAssertEqual(state?.mbid, mbidB)            // embedded overrides
        XCTAssertEqual(state?.artistMbid, artistMbid) // preserved via COALESCE
        XCTAssertEqual(state?.lookupStatus, "embedded")
    }

    func testRecordMissThenEmbeddedClearsNotFound() async throws {
        let (_, writer, store) = try await setup()
        try await store.recordTrackResolution(trackRef: "srv1:t1", mbid: nil, artistMbid: nil, at: 100)
        var state = try await store.mbidState(trackRef: "srv1:t1")
        XCTAssertNil(state?.mbid)
        XCTAssertEqual(state?.lookupStatus, "notfound")
        try await writer.upsertTracks([
            Track(id: "t1", title: "Song", artistName: "Artist", mbid: mbidA),
        ], serverId: "srv1")
        state = try await store.mbidState(trackRef: "srv1:t1")
        XCTAssertEqual(state?.mbid, mbidA)
        XCTAssertEqual(state?.lookupStatus, "embedded")
    }

    func testTracksNeedingResolutionRespectsMBIDAndTTL() async throws {
        let (_, writer, store) = try await setup()
        // t1 has an embedded MBID (should be excluded); t2 has none (included).
        try await writer.upsertTracks([
            Track(id: "t1", title: "A", artistName: "Artist", mbid: mbidA),
            Track(id: "t2", title: "B", artistName: "Artist"),
        ], serverId: "srv1")
        var needing = try await store.tracksNeedingResolution(
            serverId: "srv1", notLookedUpSince: 1_000, limit: 100).map(\.remoteId)
        XCTAssertEqual(needing, ["t2"])

        // A recent miss on t2 excludes it until the TTL cutoff passes.
        try await store.recordTrackResolution(trackRef: "srv1:t2", mbid: nil, artistMbid: nil, at: 2_000)
        needing = try await store.tracksNeedingResolution(
            serverId: "srv1", notLookedUpSince: 1_000, limit: 100).map(\.remoteId)
        XCTAssertTrue(needing.isEmpty) // looked up at 2000, cutoff 1000 → not due
        needing = try await store.tracksNeedingResolution(
            serverId: "srv1", notLookedUpSince: 3_000, limit: 100).map(\.remoteId)
        XCTAssertEqual(needing, ["t2"]) // cutoff 3000 > 2000 → due again
    }

    func testRecordFoundWritesRecordingMBID() async throws {
        let (_, _, store) = try await setup()
        try await store.recordTrackResolution(trackRef: "srv1:t1", mbid: mbidA,
                                              artistMbid: artistMbid, at: 100)
        let state = try await store.mbidState(trackRef: "srv1:t1")
        XCTAssertEqual(state?.mbid, mbidA)
        XCTAssertEqual(state?.lookupStatus, "found")
    }
}
