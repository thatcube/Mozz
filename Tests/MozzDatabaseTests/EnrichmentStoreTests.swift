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

    func testEmbeddingUpsertPreservesResolvedMBID() async throws {
        let (db, _, store) = try await setup()
        // Enrichment resolved an MBID first.
        try await store.recordTrackResolution(trackRef: "srv1:t1", mbid: mbidA,
                                              artistMbid: artistMbid, at: 100)
        // A later sonic-embedding write (the natural whole-record pattern) must NOT
        // blank the MBID columns.
        let rec = RecommendationStore(db)
        try await rec.upsertTrackFeatures(TrackFeaturesRecord(
            trackRef: "srv1:t1", genres: "[\"rock\"]", embedding: Data([9, 9]),
            embeddingDim: 1, featureSource: "ondevice"))
        let state = try await store.mbidState(trackRef: "srv1:t1")
        XCTAssertEqual(state?.mbid, mbidA)             // preserved
        XCTAssertEqual(state?.artistMbid, artistMbid)  // preserved
        XCTAssertEqual(state?.lookupStatus, "found")   // preserved
        let feat = try await rec.trackFeatures(forTrackRef: "srv1:t1")
        XCTAssertEqual(feat?.embedding, Data([9, 9]))  // embedding written
    }

    func testArtistOnlyEmbeddedKeepsTrackEligible() async throws {
        let (_, writer, store) = try await setup()
        // A Jellyfin track tagged only at the artist level (no recording MBID).
        try await writer.upsertTracks([
            Track(id: "t5", title: "Artist-only", artistName: "A", mbid: nil, artistMbid: artistMbid),
        ], serverId: "srv1")
        let state = try await store.mbidState(trackRef: "srv1:t5")
        XCTAssertEqual(state?.artistMbid, artistMbid) // artist hint captured
        XCTAssertNil(state?.mbid)                      // no recording MBID
        XCTAssertNil(state?.lookupStatus)              // not marked looked-up
        // Still eligible for recording resolution, with the artist MBID as a hint.
        let needing = try await store.tracksNeedingResolution(
            serverId: "srv1", notLookedUpSince: 1_000, limit: 10)
        let candidate = needing.first { $0.remoteId == "t5" }
        XCTAssertEqual(candidate?.existingArtistMbid, artistMbid)
    }

    func testEmbeddedArtistMbidBackfilledWhenRecordingUnchanged() async throws {
        let (_, writer, store) = try await setup()
        // First sync: recording MBID present, artist MBID not yet known.
        try await writer.upsertTracks([
            Track(id: "t1", title: "S", artistName: "A", mbid: mbidA, artistMbid: nil),
        ], serverId: "srv1")
        var state = try await store.mbidState(trackRef: "srv1:t1")
        XCTAssertEqual(state?.mbid, mbidA)
        XCTAssertNil(state?.artistMbid)
        // Re-sync: SAME recording MBID, now carrying an artist MBID. The no-op
        // WHERE guard must still allow this legitimate back-fill (a WHERE that only
        // checked mbid would silently drop it).
        try await writer.upsertTracks([
            Track(id: "t1", title: "S", artistName: "A", mbid: mbidA, artistMbid: artistMbid),
        ], serverId: "srv1")
        state = try await store.mbidState(trackRef: "srv1:t1")
        XCTAssertEqual(state?.mbid, mbidA)
        XCTAssertEqual(state?.artistMbid, artistMbid)
    }

    // MARK: - B4 artist-genre tags (data capture)

    func testArtistsNeedingTagsDedupesAndSetArtistTagsFansOut() async throws {
        let (db, writer, store) = try await setup()
        // Two tracks share one artist_mbid; a third track has none.
        try await writer.upsertTracks([
            Track(id: "t1", title: "A", artistName: "Artist", mbid: mbidA, artistMbid: artistMbid),
            Track(id: "t2", title: "B", artistName: "Artist", mbid: mbidB, artistMbid: artistMbid),
            Track(id: "t3", title: "C", artistName: "Other", mbid: nil, artistMbid: nil),
        ], serverId: "srv1")

        // Distinct artist_mbid returned exactly once.
        var needing = try await store.artistsNeedingTags(
            serverId: "srv1", notLookedUpSince: 1_000, limit: 100)
        XCTAssertEqual(needing, [artistMbid])

        // Setting tags fans out to every track by that artist, lowercased JSON.
        try await store.setArtistTags(
            artistMbid: artistMbid, tags: ["Alternative Rock", "Electronic"], at: 500)
        let rows = try await db.read { try Row.fetchAll($0, sql: """
            SELECT mb_tags, mb_tags_lookup_at FROM track_features
            WHERE artist_mbid = ? ORDER BY track_ref
            """, arguments: [artistMbid]) }
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            let tags: String? = row["mb_tags"]
            let at: Double? = row["mb_tags_lookup_at"]
            XCTAssertEqual(tags, "[\"alternative rock\",\"electronic\"]")
            XCTAssertEqual(at, 500)
        }

        // No longer due within TTL; due again once the cutoff passes the stamp.
        needing = try await store.artistsNeedingTags(
            serverId: "srv1", notLookedUpSince: 400, limit: 100)
        XCTAssertTrue(needing.isEmpty)
        needing = try await store.artistsNeedingTags(
            serverId: "srv1", notLookedUpSince: 600, limit: 100)
        XCTAssertEqual(needing, [artistMbid])
    }

    func testSetArtistTagsEmptyNegativeCachesWithoutWritingEmptyArray() async throws {
        let (db, writer, store) = try await setup()
        try await writer.upsertTracks([
            Track(id: "t1", title: "A", artistName: "Artist", mbid: mbidA, artistMbid: artistMbid),
        ], serverId: "srv1")
        try await store.setArtistTags(artistMbid: artistMbid, tags: [], at: 500)
        let row = try await db.read { try Row.fetchOne($0, sql: """
            SELECT mb_tags, mb_tags_lookup_at FROM track_features WHERE artist_mbid = ?
            """, arguments: [artistMbid]) }
        let tags: String? = row?["mb_tags"]
        let at: Double? = row?["mb_tags_lookup_at"]
        XCTAssertNil(tags)          // empty → NULL, never the string "[]"
        XCTAssertEqual(at, 500)     // still stamped (TTL negative cache)
        let needing = try await store.artistsNeedingTags(
            serverId: "srv1", notLookedUpSince: 400, limit: 100)
        XCTAssertTrue(needing.isEmpty) // not re-fetched within TTL
    }

    func testNewTrackByAlreadyTaggedArtistReTriggersLookup() async throws {
        let (_, writer, store) = try await setup()
        try await writer.upsertTracks([
            Track(id: "t1", title: "A", artistName: "Artist", mbid: mbidA, artistMbid: artistMbid),
        ], serverId: "srv1")
        try await store.setArtistTags(artistMbid: artistMbid, tags: ["rock"], at: 500)
        // A later sync brings a NEW track by the same artist (mb_tags still NULL).
        try await writer.upsertTracks([
            Track(id: "t2", title: "B", artistName: "Artist", mbid: mbidB, artistMbid: artistMbid),
        ], serverId: "srv1")
        // The artist is due again so a single re-fetch heals the new track — even
        // though the old track was stamped inside the TTL.
        let needing = try await store.artistsNeedingTags(
            serverId: "srv1", notLookedUpSince: 400, limit: 100)
        XCTAssertEqual(needing, [artistMbid])
    }

    func testEncodeTagArrayLowercasesAndNilsEmpty() {
        XCTAssertNil(EnrichmentStore.encodeTagArray([]))
        XCTAssertEqual(EnrichmentStore.encodeTagArray(["Rock", "Trip Hop"]),
                       "[\"rock\",\"trip hop\"]")
    }

    // A changed artist_mbid must invalidate the old artist's mb_tags so the tag
    // pass refetches — otherwise the wrong genres persist until the 30-day TTL.

    private func mbTagsRow(_ db: MusicDatabase, _ ref: String) async throws
        -> (tags: String?, at: Double?) {
        let row = try await db.read { try Row.fetchOne($0, sql: """
            SELECT mb_tags, mb_tags_lookup_at FROM track_features WHERE track_ref = ?
            """, arguments: [ref]) }
        return (row?["mb_tags"], row?["mb_tags_lookup_at"])
    }

    func testEmbeddedArtistMbidChangeClearsMbTags() async throws {
        let (db, writer, store) = try await setup()
        // Artist-only tagged track (no recording MBID), then tagged.
        try await writer.upsertTracks([
            Track(id: "t1", title: "A", artistName: "Artist", mbid: nil, artistMbid: artistMbid),
        ], serverId: "srv1")
        try await store.setArtistTags(artistMbid: artistMbid, tags: ["rock"], at: 100)
        var row = try await mbTagsRow(db, "srv1:t1")
        XCTAssertEqual(row.tags, "[\"rock\"]")

        // A later sync re-tags the track with a DIFFERENT embedded artist MBID.
        let otherArtist = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        try await writer.upsertTracks([
            Track(id: "t1", title: "A", artistName: "Artist", mbid: nil, artistMbid: otherArtist),
        ], serverId: "srv1")
        row = try await mbTagsRow(db, "srv1:t1")
        XCTAssertNil(row.tags)   // stale genres cleared
        XCTAssertNil(row.at)     // and re-queued for the new artist
        let needing = try await store.artistsNeedingTags(
            serverId: "srv1", notLookedUpSince: 50, limit: 10)
        XCTAssertEqual(needing, [otherArtist])
    }

    func testEmbeddedRecordingArtistMbidChangeClearsMbTags() async throws {
        let (db, writer, store) = try await setup()
        // Track with an embedded recording + artist MBID, then tagged.
        try await writer.upsertTracks([
            Track(id: "t1", title: "A", artistName: "Artist", mbid: mbidA, artistMbid: artistMbid),
        ], serverId: "srv1")
        try await store.setArtistTags(artistMbid: artistMbid, tags: ["rock"], at: 100)

        // Re-sync: same recording, but the embedded artist MBID now differs.
        let otherArtist = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        try await writer.upsertTracks([
            Track(id: "t1", title: "A", artistName: "Artist", mbid: mbidA, artistMbid: otherArtist),
        ], serverId: "srv1")
        let row = try await mbTagsRow(db, "srv1:t1")
        XCTAssertNil(row.tags)
        XCTAssertNil(row.at)
    }

    func testEmbeddedArtistMbidUnchangedKeepsMbTags() async throws {
        let (db, writer, store) = try await setup()
        try await writer.upsertTracks([
            Track(id: "t1", title: "A", artistName: "Artist", mbid: mbidA, artistMbid: artistMbid),
        ], serverId: "srv1")
        try await store.setArtistTags(artistMbid: artistMbid, tags: ["rock"], at: 100)
        // Re-sync with the SAME artist MBID must NOT clear the tags (no needless
        // refetch churn).
        try await writer.upsertTracks([
            Track(id: "t1", title: "A", artistName: "Artist", mbid: mbidA, artistMbid: artistMbid),
        ], serverId: "srv1")
        let row = try await mbTagsRow(db, "srv1:t1")
        XCTAssertEqual(row.tags, "[\"rock\"]")
        XCTAssertEqual(row.at, 100)
    }

    func testResolutionArtistMbidChangeClearsMbTags() async throws {
        let (db, writer, store) = try await setup()
        // Artist-only embedded track gets tagged, then a name-search resolves it
        // to a recording carrying a DIFFERENT artist MBID.
        try await writer.upsertTracks([
            Track(id: "t1", title: "A", artistName: "Artist", mbid: nil, artistMbid: artistMbid),
        ], serverId: "srv1")
        try await store.setArtistTags(artistMbid: artistMbid, tags: ["rock"], at: 100)
        let otherArtist = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        try await store.recordTrackResolution(
            trackRef: "srv1:t1", mbid: mbidA, artistMbid: otherArtist, at: 200)
        let row = try await mbTagsRow(db, "srv1:t1")
        XCTAssertNil(row.tags)
        XCTAssertNil(row.at)
    }
}
