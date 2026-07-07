import XCTest
import MozzCore
import GRDB
@testable import MozzDatabase

private func srv(_ id: String = "s1") -> ServerConnection {
    ServerConnection(id: id, kind: .plex, name: "T",
                     baseURL: URL(string: "https://x.local")!, userID: nil, clientIdentifier: "c1")
}
private let artistA = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
private let artistB = "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"

/// B4.5 — the store's enrich-aware genre reads (corpus / candidates / taste /
/// seed-artist / mb_tags lookups). Verifies canonical normalization, symmetric
/// merge, the cartesian/double-count guard, and OFF == today.
final class GenreEnrichmentStoreTests: XCTestCase {
    private func setup() async throws -> (MusicDatabase, CatalogWriter, RecommendationStore, EnrichmentStore) {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        try await writer.saveServer(srv())
        return (db, writer, RecommendationStore(db), EnrichmentStore(db))
    }

    // MARK: corpus (genreFrequencies)

    func testCorpusFoldsCaseAndPunctuationAndCountsOncePerTrack() async throws {
        let (_, writer, store, enrich) = try await setup()
        // Track t1: Plex "Rock" + mb_tag "rock" (same concept, different case).
        // Track t2: Plex "Hip-Hop" + mb_tag "hip hop" (case + separator variants).
        try await writer.upsertTracks([
            Track(id: "t1", title: "A", artistName: "AA", artistID: "a1", genres: ["Rock"], artistMbid: artistA),
            Track(id: "t2", title: "B", artistName: "BB", artistID: "b1", genres: ["Hip-Hop"], artistMbid: artistB),
        ], serverId: "s1")
        try await enrich.setArtistTags(artistMbid: artistA, tags: ["rock"], at: 100)
        try await enrich.setArtistTags(artistMbid: artistB, tags: ["hip hop"], at: 100)

        let corpus = try await store.genreFrequencies(serverId: "s1", enrich: true)
        XCTAssertEqual(corpus.total, 2)
        // A genre present in BOTH columns of a track counts ONCE (df dedup), and
        // "Rock"/"rock" and "Hip-Hop"/"hip hop" each collapse to one canonical key.
        XCTAssertEqual(corpus.counts["rock"], 1)
        XCTAssertEqual(corpus.counts["hip hop"], 1)
        XCTAssertNil(corpus.counts["Rock"])      // no case-fractured duplicate key
        XCTAssertNil(corpus.counts["hip-hop"])
    }

    func testCorpusOffIsRawCaseSensitiveLikeToday() async throws {
        let (_, writer, store, enrich) = try await setup()
        try await writer.upsertTracks([
            Track(id: "t1", title: "A", artistName: "AA", artistID: "a1", genres: ["Rock"], artistMbid: artistA),
        ], serverId: "s1")
        try await enrich.setArtistTags(artistMbid: artistA, tags: ["rock"], at: 100)
        // Off: raw case-sensitive, mb_tags ignored — byte-identical to pre-B4.5.
        let corpus = try await store.genreFrequencies(serverId: "s1", enrich: false)
        XCTAssertEqual(corpus.counts["Rock"], 1)
        XCTAssertNil(corpus.counts["rock"])      // mb_tag not merged when off
    }

    func testCorpusEnrichSurvivesMalformedJSON() async throws {
        let (db, writer, store, _) = try await setup()
        try await writer.upsertTracks([
            Track(id: "t1", title: "A", artistName: "AA", artistID: "a1", genres: ["Rock"], artistMbid: artistA),
        ], serverId: "s1")
        // A deliberately invalid, non-NULL mb_tags value must NOT abort the query.
        try await db.write { database in
            try database.execute(sql: "UPDATE track_features SET mb_tags = 'not json' WHERE artist_mbid = ?",
                                 arguments: [artistA])
        }
        let corpus = try await store.genreFrequencies(serverId: "s1", enrich: true)
        XCTAssertEqual(corpus.counts["rock"], 1)   // valid rows still counted
    }

    // MARK: candidates

    func testCandidatesReturnMergedNormalizedGenresAndMatchViaMbTags() async throws {
        let (_, writer, store, enrich) = try await setup()
        // t1's ONLY link to the query genre "electronic" is via its mb_tag, not
        // its Plex genre "Rock" — the widened match must still surface it.
        try await writer.upsertTracks([
            Track(id: "t1", title: "A", artistName: "AA", artistID: "a1", genres: ["Rock"], artistMbid: artistA),
        ], serverId: "s1")
        try await enrich.setArtistTags(artistMbid: artistA, tags: ["electronic"], at: 100)
        let pool = try await store.candidateTracks(
            serverId: "s1", genres: ["electronic"], artistIds: [],
            notPlayedSince: 9_999_999_999, limit: 100, enrich: true)
        XCTAssertEqual(pool.count, 1)
        // Returned genres are the canonical union of track.genres + mb_tags.
        XCTAssertEqual(Set(pool[0].genres), ["rock", "electronic"])
    }

    func testCandidatesOffUseRawGenresAndExactMatch() async throws {
        let (_, writer, store, enrich) = try await setup()
        try await writer.upsertTracks([
            Track(id: "t1", title: "A", artistName: "AA", artistID: "a1", genres: ["Rock"], artistMbid: artistA),
        ], serverId: "s1")
        try await enrich.setArtistTags(artistMbid: artistA, tags: ["electronic"], at: 100)
        // Off: no mb_tags match, raw genres.
        let viaMb = try await store.candidateTracks(
            serverId: "s1", genres: ["electronic"], artistIds: [],
            notPlayedSince: 9_999_999_999, limit: 100, enrich: false)
        XCTAssertTrue(viaMb.isEmpty)   // mb_tag not consulted when off
        let viaRaw = try await store.candidateTracks(
            serverId: "s1", genres: ["Rock"], artistIds: [],
            notPlayedSince: 9_999_999_999, limit: 100, enrich: false)
        XCTAssertEqual(viaRaw.first?.genres, ["Rock"])   // raw, exact
    }

    func testCandidatesMatchSeparatorVariantGenreWithoutMbTags() async throws {
        let (_, writer, store, _) = try await setup()
        // A hyphenated Plex genre with NO mb_tags must still be matched by the
        // normalized key "hip hop" (else enrich-on would MISS it vs today).
        try await writer.upsertTracks([
            Track(id: "t1", title: "A", artistName: "AA", artistID: "a1", genres: ["Hip-Hop"]),
        ], serverId: "s1")
        let pool = try await store.candidateTracks(
            serverId: "s1", genres: ["hip hop"], artistIds: [],
            notPlayedSince: 9_999_999_999, limit: 100, enrich: true)
        XCTAssertEqual(pool.count, 1)
        XCTAssertEqual(pool[0].genres, ["hip hop"])   // normalized in the returned candidate
    }

    func testCandidatesMatchHyphenatedMbTagGenre() async throws {
        let (_, writer, store, enrich) = try await setup()
        // A candidate whose ONLY link to "post punk" is a hyphenated MB genre
        // ("post-punk") on its artist — must still be matched (the mb_tag is stored
        // separator-folded, so the exact-match arm works for it).
        try await writer.upsertTracks([
            Track(id: "t1", title: "A", artistName: "AA", artistID: "a1", genres: ["Rock"], artistMbid: artistA),
        ], serverId: "s1")
        try await enrich.setArtistTags(artistMbid: artistA, tags: ["Post-Punk"], at: 100)
        let pool = try await store.candidateTracks(
            serverId: "s1", genres: ["post punk"], artistIds: [],
            notPlayedSince: 9_999_999_999, limit: 100, enrich: true)
        XCTAssertEqual(pool.count, 1)
        XCTAssertEqual(Set(pool[0].genres), ["rock", "post punk"])
    }

    // MARK: taste signals

    func testPlayedSignalsMergeMbTagsWhenEnriched() async throws {
        let (db, writer, store, enrich) = try await setup()
        try await writer.upsertTracks([
            Track(id: "t1", title: "A", artistName: "AA", artistID: "a1", genres: ["Hip-Hop"], artistMbid: artistA),
        ], serverId: "s1")
        try await enrich.setArtistTags(artistMbid: artistA, tags: ["rap"], at: 100)
        try await db.write { d in
            try d.execute(sql: """
                INSERT INTO play_event (track_ref, kind, created_at) VALUES ('s1:t1','completed',500)
                """)
        }
        let signals = try await store.playedTrackSignals(serverId: "s1", enrich: true)
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(Set(signals[0].genres), ["hip hop", "rap"])   // canonical union
    }

    // MARK: seed artist

    func testSeedArtistUnionsMbTagsNormalizedWhenEnriched() async throws {
        let (_, writer, store, enrich) = try await setup()
        try await writer.upsertTracks([
            Track(id: "t1", title: "A", artistName: "The Band", artistID: "art1", genres: ["Rock"], artistMbid: artistA),
            Track(id: "t2", title: "B", artistName: "The Band", artistID: "art1", genres: ["Hard-Rock"], artistMbid: artistA),
        ], serverId: "s1")
        try await enrich.setArtistTags(artistMbid: artistA, tags: ["alternative rock"], at: 100)
        let seed = try await store.seedArtist(remoteId: "art1", serverId: "s1", enrich: true)
        XCTAssertEqual(seed?.name, "The Band")
        XCTAssertEqual(Set(seed?.genres ?? []), ["rock", "hard rock", "alternative rock"])
    }

    // MARK: mb_tags lookups

    func testMbTagsForTrackRefAndBatch() async throws {
        let (_, writer, store, enrich) = try await setup()
        try await writer.upsertTracks([
            Track(id: "t1", title: "A", artistName: "AA", artistID: "a1", genres: ["Rock"], artistMbid: artistA),
            Track(id: "t2", title: "B", artistName: "AA", artistID: "a1", genres: ["Rock"], artistMbid: artistA),
        ], serverId: "s1")
        try await enrich.setArtistTags(artistMbid: artistA, tags: ["electronic", "ambient"], at: 100)
        let one = try await store.mbTags(forTrackRef: "s1:t1")
        XCTAssertEqual(Set(one), ["electronic", "ambient"])
        let many = try await store.mbTags(forTrackRefs: ["s1:t1", "s1:t2", "s1:missing"])
        XCTAssertEqual(Set(many["s1:t1"] ?? []), ["electronic", "ambient"])
        XCTAssertEqual(Set(many["s1:t2"] ?? []), ["electronic", "ambient"])
        XCTAssertNil(many["s1:missing"])
    }

    func testMbTagsForTrackRefsBatchesBeyondParamLimit() async throws {
        let (_, writer, store, enrich) = try await setup()
        // >800 tracks (the batch size) so a distinguishing tag past the first batch
        // must still be returned (batch-loop, not prefix-truncation).
        let n = 900
        try await writer.upsertTracks((0..<n).map {
            Track(id: "t\($0)", title: "x", artistName: "AA", artistID: "a1", genres: ["Rock"], artistMbid: artistA)
        }, serverId: "s1")
        try await enrich.setArtistTags(artistMbid: artistA, tags: ["electronic"], at: 100)
        let refs = (0..<n).map { "s1:t\($0)" }
        let many = try await store.mbTags(forTrackRefs: refs)
        XCTAssertEqual(many.count, n)                       // every ref reachable
        XCTAssertEqual(many["s1:t899"], ["electronic"])     // one past the first batch
    }
}
