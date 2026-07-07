import XCTest
import MozzCore
import MozzDatabase
@testable import MozzRecommend

private func radioServer() -> ServerConnection {
    ServerConnection(id: "rsrv", kind: .plex, name: "T",
                     baseURL: URL(string: "https://x.local")!, userID: nil, clientIdentifier: "c1")
}
private let fixedNow = Date(timeIntervalSince1970: 2_000_000)

private func scored(_ remoteId: String, artist: String, score: Double) -> ScoredOwnedTrack {
    ScoredOwnedTrack(
        candidate: TrackCandidate(
            trackRef: "rsrv:\(remoteId)", remoteId: remoteId, title: remoteId,
            artistName: artist, artistRemoteId: artist, albumRemoteId: nil,
            genres: ["Rock"], addedAt: nil),
        score: score)
}

final class RadioBatchTests: XCTestCase {
    /// A catalog of genre-matched "Rock" tracks to serve as the genre pool.
    private func makeService() async throws -> (RecommendationService, ServerID) {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        try await writer.saveServer(radioServer())
        try await writer.upsertTracks((1...8).map {
            Track(id: "rock\($0)", title: "R\($0)", artistName: "Genre\($0)",
                  artistID: "g\($0)", genres: ["Rock"])
        }, serverId: "rsrv")
        return (RecommendationService(store: RecommendationStore(db), now: { fixedNow }), "rsrv")
    }

    func testSimilarityLeadsOverGenreEvenAtLowScore() async throws {
        let (service, serverId) = try await makeService()
        let seed = RadioSeed(title: "Seed", genres: ["Rock"], artistIds: [], seedTrackRef: "rsrv:seed")
        // A LOW-scored similar track must still lead over any genre-only track.
        let similar = [scored("sim1", artist: "SimArtist", score: 0.01)]
        let ids = try await service.radioBatch(
            seed: seed, serverId: serverId, limit: 5, excluding: [], similar: similar)
        XCTAssertEqual(ids.first, "sim1", "similarity must lead the batch")
        XCTAssertLessThanOrEqual(ids.count, 5)
        XCTAssertTrue(ids.dropFirst().allSatisfy { $0.hasPrefix("rock") }, "genre fills the rest")
    }

    func testSimilarityFillsWithGenreWhenShort() async throws {
        let (service, serverId) = try await makeService()
        let seed = RadioSeed(title: "Seed", genres: ["Rock"], artistIds: [], seedTrackRef: "rsrv:seed")
        let similar = [scored("sim1", artist: "A", score: 0.9), scored("sim2", artist: "B", score: 0.5)]
        let ids = try await service.radioBatch(
            seed: seed, serverId: serverId, limit: 6, excluding: [], similar: similar)
        XCTAssertEqual(Array(ids.prefix(2)), ["sim1", "sim2"]) // similarity leads, in score order
        XCTAssertEqual(ids.count, 6)                            // genre topped it up
        XCTAssertTrue(ids.dropFirst(2).allSatisfy { $0.hasPrefix("rock") })
    }

    func testFallsBackToGenreWhenNoSimilar() async throws {
        let (service, serverId) = try await makeService()
        let seed = RadioSeed(title: "Seed", genres: ["Rock"], artistIds: [], seedTrackRef: "rsrv:seed")
        // No similarity → identical to the genre engine (all rock, no sim ids).
        let ids = try await service.radioBatch(
            seed: seed, serverId: serverId, limit: 5, excluding: [], similar: [])
        XCTAssertFalse(ids.isEmpty)
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("rock") })
    }

    func testSimilarityRespectsExcluding() async throws {
        let (service, serverId) = try await makeService()
        let seed = RadioSeed(title: "Seed", genres: ["Rock"], artistIds: [], seedTrackRef: "rsrv:seed")
        let similar = [scored("sim1", artist: "A", score: 0.9)]
        let ids = try await service.radioBatch(
            seed: seed, serverId: serverId, limit: 5, excluding: ["sim1"], similar: similar)
        XCTAssertFalse(ids.contains("sim1"), "excluded similar track must not appear")
    }

    func testBothEmptyReturnsEmpty() async throws {
        let (service, serverId) = try await makeService()
        // A seed genre nothing matches + no similarity → empty batch.
        let seed = RadioSeed(title: "Seed", genres: ["Polka"], artistIds: [], seedTrackRef: nil)
        let ids = try await service.radioBatch(
            seed: seed, serverId: serverId, limit: 5, excluding: [], similar: [])
        XCTAssertTrue(ids.isEmpty)
    }

    func testDropsNonPositiveSimilarityScores() async throws {
        let (service, serverId) = try await makeService()
        let seed = RadioSeed(title: "Seed", genres: ["Rock"], artistIds: [], seedTrackRef: "rsrv:seed")
        let similar = [scored("sim0", artist: "A", score: 0)] // score 0 → dropped
        let ids = try await service.radioBatch(
            seed: seed, serverId: serverId, limit: 5, excluding: [], similar: similar)
        XCTAssertFalse(ids.contains("sim0"))
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("rock") })
    }
}
