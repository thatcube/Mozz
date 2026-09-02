import XCTest
import MozzCore
import MozzDatabase
@testable import MozzRecommend

private let engineV1 = "mozz-dsp@1"
private let engineV2 = "mozz-dsp@2"
private let sonicNow = Date(timeIntervalSince1970: 3_000_000)

final class SonicEmbeddingCodecTests: XCTestCase {
    func testRoundTripsExactly() throws {
        let vector: [Float] = [0, 1, -1, 0.5, -0.25, 3.4028235e38, 1.1754944e-38]
        let unpacked = try XCTUnwrap(SonicEmbeddingCodec.unpack(SonicEmbeddingCodec.pack(vector)))
        XCTAssertEqual(unpacked, vector)
    }

    func testRejectsBlobsThatAreNotWholeFloats() {
        // A truncated write, or a column written by something that disagreed
        // about the format. Better no vector than a misaligned one.
        XCTAssertNil(SonicEmbeddingCodec.unpack(Data([1, 2, 3])))
        XCTAssertNil(SonicEmbeddingCodec.unpack(Data()))
    }

    func testPackingIsLittleEndianRegardlessOfHost() {
        // 1.0f is 0x3F800000; little-endian on the wire is 00 00 80 3F.
        XCTAssertEqual(Array(SonicEmbeddingCodec.pack([1.0])), [0x00, 0x00, 0x80, 0x3F])
    }
}

final class SonicEmbeddingStoreTests: XCTestCase {
    private func makeStore() async throws -> (RecommendationStore, RecommendationService, ServerID, MusicDatabase) {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        try await writer.saveServer(ServerConnection(
            id: "ssrv", kind: .plex, name: "S",
            baseURL: URL(string: "https://s.local")!, userID: nil, clientIdentifier: "c"))
        try await writer.upsertTracks((1...5).map {
            Track(id: "t\($0)", title: "T\($0)", artistName: "A\($0)",
                  artistID: "a\($0)", genres: ["Rock"])
        }, serverId: "ssrv")
        let store = RecommendationStore(db)
        return (store, RecommendationService(store: store, now: { sonicNow }), "ssrv", db)
    }

    func testEmbeddingRoundTripsThroughTheDatabase() async throws {
        let (store, _, serverId, _) = try await makeStore()
        let vector: [Float] = [0.1, -0.2, 0.3]
        try await store.saveSonicEmbedding(vector, engine: engineV1, bpm: 128,
                                           trackRef: "\(serverId):t1", at: 1)
        let read = try await store.sonicEmbedding(trackRef: "\(serverId):t1", engine: engineV1)
        XCTAssertEqual(read, vector)
        // A different engine is a different space, so this row is not an answer.
        let wrongEngine = try await store.sonicEmbedding(trackRef: "\(serverId):t1", engine: engineV2)
        XCTAssertNil(wrongEngine)
    }

    func testTheAnalysisQueueLeadsWithWhatIsWorthAnalyzingFirst() async throws {
        // Analyzing a library takes hours, and the vectors only pay off around
        // tracks someone actually plays — so the order matters more than the
        // throughput. Played first, then whatever a mix has already picked out,
        // then the tail.
        let (store, _, serverId, db) = try await makeStore()
        let events = PlayEventStore(db)
        try await events.append(PlayEvent(trackID: "t4", kind: .completed,
                                          createdAt: Date(timeIntervalSince1970: 1_000)),
                                serverId: serverId)
        try await events.append(PlayEvent(trackID: "t2", kind: .started,
                                          createdAt: Date(timeIntervalSince1970: 2_000)),
                                serverId: serverId)
        // t5 sits in a generated mix but has never been played.
        let mixRef = "\(serverId):t5"
        try await db.write { database in
            try database.execute(sql: "INSERT INTO recommendation_set (id, title, kind, generated_at) VALUES ('mix', 'Mix', 'daily_mix', 0)")
            try database.execute(
                sql: "INSERT INTO recommendation_item (set_id, track_ref, rank, score, in_library) VALUES ('mix', ?, 0, 1.0, 1)",
                arguments: [mixRef])
        }

        let queue = try await store.tracksNeedingSonicAnalysis(
            serverId: serverId, engine: engineV1, limit: 5)
        XCTAssertEqual(queue.prefix(3).map(\.remoteId), ["t2", "t4", "t5"])
    }

    func testSavingAnEmbeddingDoesNotBlankEnrichment() async throws {
        // `track_features` is shared with the MusicBrainz path. A whole-record
        // write here would destroy resolved MBIDs, which are expensive and
        // rate-limited to obtain.
        let (store, _, serverId, database) = try await makeStore()
        let ref = "\(serverId):t1"
        let recordingMbid = "8f3471b5-7e6a-4b4e-9c19-1a8f4a2b6c31"
        let artistMbid = "b10bbff4-1d2f-4f3e-9a7c-5e2d3c4b5a69"

        // Seeded through the path that actually owns these columns. They are
        // expensive: MusicBrainz resolution is rate-limited and a whole library
        // of it takes days.
        try await EnrichmentStore(database).recordTrackResolution(
            trackRef: ref, mbid: recordingMbid, artistMbid: artistMbid, at: 1)
        try await store.upsertTrackFeatures(TrackFeaturesRecord(
            trackRef: ref, mbid: nil, artistMbid: nil, genres: #"["Rock"]"#,
            tags: nil, bpm: nil, replaygainDb: -3, embedding: nil, embeddingDim: nil,
            featureSource: nil, updatedAt: 1))

        try await store.saveSonicEmbedding([0.5, 0.5], engine: engineV1, bpm: 100,
                                           trackRef: ref, at: 2)

        let stored = try await store.trackFeatures(forTrackRef: ref)
        let record = try XCTUnwrap(stored)
        XCTAssertEqual(record.mbid, recordingMbid)
        XCTAssertEqual(record.artistMbid, artistMbid)
        XCTAssertEqual(record.genres, #"["Rock"]"#)
        XCTAssertEqual(record.replaygainDb, -3)
        XCTAssertEqual(record.featureSource, engineV1)
        XCTAssertEqual(record.bpm, 100)
    }

    func testCorpusAndBacklogAreFilteredByEngine() async throws {
        let (store, _, serverId, _) = try await makeStore()
        try await store.saveSonicEmbedding([1, 0], engine: engineV1, bpm: nil,
                                           trackRef: "\(serverId):t1", at: 1)
        try await store.saveSonicEmbedding([0, 1], engine: engineV1, bpm: nil,
                                           trackRef: "\(serverId):t2", at: 1)
        // An OLDER engine's vector is not a vector: it is not comparable with
        // the current one, so the track still needs analyzing.
        try await store.saveSonicEmbedding([1, 1], engine: engineV2, bpm: nil,
                                           trackRef: "\(serverId):t3", at: 1)

        let corpus = try await store.sonicEmbeddings(serverId: serverId, engine: engineV1)
        XCTAssertEqual(Set(corpus.map(\.remoteId)), ["t1", "t2"])

        let backlog = try await store.tracksNeedingSonicAnalysis(
            serverId: serverId, engine: engineV1, limit: 10)
        XCTAssertEqual(Set(backlog.map(\.remoteId)), ["t3", "t4", "t5"])

        let progress = try await store.sonicAnalysisProgress(serverId: serverId, engine: engineV1)
        XCTAssertEqual(progress.analyzed, 2)
        XCTAssertEqual(progress.total, 5)
    }
}

final class LocalSonicMatchTests: XCTestCase {
    private func makeService() async throws -> (RecommendationStore, RecommendationService, ServerID) {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        try await writer.saveServer(ServerConnection(
            id: "ksrv", kind: .plex, name: "K",
            baseURL: URL(string: "https://k.local")!, userID: nil, clientIdentifier: "c"))
        try await writer.upsertTracks(["seed", "near", "middle", "far"].map {
            Track(id: $0, title: $0, artistName: "A-\($0)", artistID: "a-\($0)", genres: ["Rock"])
        }, serverId: "ksrv")
        let store = RecommendationStore(db)
        return (store, RecommendationService(store: store, now: { sonicNow }), "ksrv")
    }

    /// Unit vectors at known angles from the seed, so the expected ranking is
    /// arithmetic rather than a guess.
    private func unit(_ x: Double, _ y: Double) -> [Float] {
        let norm = (x * x + y * y).squareRoot()
        return [Float(x / norm), Float(y / norm)]
    }

    func testMatchesAreRankedByCosineAndExcludeTheSeed() async throws {
        let (store, service, serverId) = try await makeService()
        try await store.saveSonicEmbedding(unit(1, 0), engine: engineV1, bpm: nil,
                                           trackRef: "\(serverId):seed", at: 1)
        try await store.saveSonicEmbedding(unit(0.95, 0.31), engine: engineV1, bpm: nil,
                                           trackRef: "\(serverId):near", at: 1)
        try await store.saveSonicEmbedding(unit(0, 1), engine: engineV1, bpm: nil,
                                           trackRef: "\(serverId):middle", at: 1)
        try await store.saveSonicEmbedding(unit(-1, 0), engine: engineV1, bpm: nil,
                                           trackRef: "\(serverId):far", at: 1)

        let matches = try await service.localSonicMatches(
            seedRemoteId: "seed", serverId: serverId, engine: engineV1, limit: 10)

        XCTAssertEqual(matches.map(\.trackID), ["near", "middle", "far"],
                       "closest first, and never the seed itself")
        // Cosine mapped to 0...1: identical is 1, opposite is 0, orthogonal 0.5.
        XCTAssertEqual(matches[1].similarity, 0.5, accuracy: 1e-5)
        XCTAssertEqual(matches[2].similarity, 0.0, accuracy: 1e-5)
        XCTAssertGreaterThan(matches[0].similarity, 0.9)
    }

    func testNoSeedVectorMeansNoMatchesRatherThanRandomOnes() async throws {
        let (store, service, serverId) = try await makeService()
        try await store.saveSonicEmbedding(unit(1, 0), engine: engineV1, bpm: nil,
                                           trackRef: "\(serverId):near", at: 1)
        // The seed itself was never analyzed.
        let matches = try await service.localSonicMatches(
            seedRemoteId: "seed", serverId: serverId, engine: engineV1, limit: 10)
        XCTAssertTrue(matches.isEmpty)
    }

    func testSearchNeverSpansEngines() async throws {
        let (store, service, serverId) = try await makeService()
        try await store.saveSonicEmbedding(unit(1, 0), engine: engineV1, bpm: nil,
                                           trackRef: "\(serverId):seed", at: 1)
        try await store.saveSonicEmbedding(unit(0.9, 0.4), engine: engineV2, bpm: nil,
                                           trackRef: "\(serverId):near", at: 1)
        let matches = try await service.localSonicMatches(
            seedRemoteId: "seed", serverId: serverId, engine: engineV1, limit: 10)
        XCTAssertTrue(matches.isEmpty, "two engines are two coordinate spaces; a match across them is noise")
    }
}
