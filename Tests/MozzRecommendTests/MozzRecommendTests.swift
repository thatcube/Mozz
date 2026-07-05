import XCTest
import Foundation
import MozzCore
import MozzDatabase
@testable import MozzRecommend

// Fixed clock so recency-decay + exclusion windows are deterministic.
private let now = Date(timeIntervalSince1970: 1_700_000_000)
private func daysAgo(_ d: Double) -> Double { now.timeIntervalSince1970 - d * 24 * 3600 }

private func signal(_ ref: String, _ kind: String, genres: [String],
                    artist: String?, ageDays: Double) -> PlayedTrackSignal {
    PlayedTrackSignal(trackRef: ref, kind: kind, createdAt: daysAgo(ageDays),
                      genres: genres, artistRemoteId: artist)
}

private func candidate(_ ref: String, artist: String = "A", artistId: String? = nil,
                       album: String? = nil, genres: [String] = [], addedAt: Double? = nil) -> TrackCandidate {
    TrackCandidate(trackRef: ref, remoteId: ref, title: ref, artistName: artist,
                   artistRemoteId: artistId, albumRemoteId: album, genres: genres, addedAt: addedAt)
}

final class TasteProfileTests: XCTestCase {
    func testCompletedIsPositiveSkippedIsNegative() {
        let taste = TasteProfile.build(from: [
            signal("a", "completed", genres: ["Rock"], artist: "ar1", ageDays: 1),
            signal("b", "skipped", genres: ["Jazz"], artist: "ar2", ageDays: 1),
        ], now: now)
        XCTAssertGreaterThan(taste.genreAffinity["Rock"] ?? 0, 0)
        XCTAssertLessThan(taste.genreAffinity["Jazz"] ?? 0, 0)
        XCTAssertEqual(taste.topGenres(5), ["Rock"])   // only positives surface
    }

    func testLikedOutweighsCompleted() {
        let taste = TasteProfile.build(from: [
            signal("a", "liked", genres: ["Rock"], artist: nil, ageDays: 1),
            signal("b", "completed", genres: ["Jazz"], artist: nil, ageDays: 1),
        ], now: now)
        XCTAssertGreaterThan(taste.genreAffinity["Rock"]!, taste.genreAffinity["Jazz"]!)
    }

    func testRecencyDecayHalvesEveryHalfLife() {
        let recent = TasteProfile.build(
            from: [signal("a", "completed", genres: ["Rock"], artist: nil, ageDays: 0)],
            now: now, halfLife: 30 * 24 * 3600)
        let old = TasteProfile.build(
            from: [signal("a", "completed", genres: ["Rock"], artist: nil, ageDays: 60)],
            now: now, halfLife: 30 * 24 * 3600)
        XCTAssertGreaterThan(recent.genreAffinity["Rock"]!, old.genreAffinity["Rock"]!)
        // 60 days = two 30-day half-lives → ~0.25×.
        XCTAssertEqual(old.genreAffinity["Rock"]!, recent.genreAffinity["Rock"]! * 0.25, accuracy: 0.001)
    }

    func testThinHistoryDetection() {
        XCTAssertTrue(TasteProfile.empty.isThin)
        XCTAssertTrue(TasteProfile.build(from: [], now: now).isThin)
        let strong = TasteProfile.build(
            from: (0..<5).map { signal("t\($0)", "completed", genres: ["Rock"], artist: nil, ageDays: 1) },
            now: now)
        XCTAssertFalse(strong.isThin)
    }
}

final class ContentRecommenderTests: XCTestCase {
    func testScoresByAffinityAndDropsUnrelated() {
        let taste = TasteProfile.build(
            from: [signal("x", "completed", genres: ["Rock"], artist: "ar1", ageDays: 1)], now: now)
        let scored = ContentRecommender().score(candidates: [
            candidate("c1", artistId: "ar1", album: "al1", genres: ["Rock"]),   // genre + artist
            candidate("c2", artistId: "ar2", album: "al2", genres: ["Rock"]),   // genre only
            candidate("c3", artistId: "ar3", album: "al3", genres: ["Polka"]),  // nothing in common
        ], taste: taste)
        let refs = scored.map(\.trackRef)
        XCTAssertTrue(refs.contains("c1"))
        XCTAssertTrue(refs.contains("c2"))
        XCTAssertFalse(refs.contains("c3"), "a candidate with no taste overlap isn't a content pick")
        let s1 = scored.first { $0.trackRef == "c1" }!.score
        let s2 = scored.first { $0.trackRef == "c2" }!.score
        XCTAssertGreaterThan(s1, s2, "genre + artist match beats genre alone")
    }

    func testReasonStrings() {
        let taste = TasteProfile(genreAffinity: ["Rock": 1.0], artistAffinity: ["ar1": 5.0], positiveSignal: 1.0)
        let scored = ContentRecommender().score(candidates: [
            candidate("c1", artist: "Nirvana", artistId: "ar1", album: "al1", genres: ["Rock"]),
            candidate("c2", artist: "Other", artistId: "ar2", album: "al2", genres: ["Rock"]),
        ], taste: taste)
        XCTAssertEqual(scored.first { $0.trackRef == "c1" }?.reason, "More from Nirvana")
        XCTAssertEqual(scored.first { $0.trackRef == "c2" }?.reason, "Because you're into Rock")
    }
}

final class BlenderTests: XCTestCase {
    private func items(_ refs: [String], artist: String = "A", artistId: String? = nil,
                       album: String? = nil, score: (Int) -> Double = { Double($0) }) -> [ScoredCandidate] {
        refs.enumerated().map { i, r in
            ScoredCandidate(candidate: candidate(r, artist: artist, artistId: artistId ?? "ar-\(r)",
                                                  album: album ?? "al-\(r)"),
                            score: score(i), source: "content", reason: nil)
        }
    }

    func testDeterministicWithSeed() {
        let pool = items((0..<10).map { "t\($0)" })
        var r1 = SeededGenerator(seed: 42), r2 = SeededGenerator(seed: 42)
        let a = Blender().blend(sources: [pool], config: .init(limit: 5), using: &r1)
        let b = Blender().blend(sources: [pool], config: .init(limit: 5), using: &r2)
        XCTAssertEqual(a.map(\.trackRef), b.map(\.trackRef))
        XCTAssertEqual(a.count, 5)
    }

    func testVarietyCapPerArtist() {
        // Five tracks, same artist, cap 2 → only two survive.
        let pool = items((0..<5).map { "t\($0)" }, artistId: "same", score: { Double(5 - $0) })
        var rng = SeededGenerator(seed: 1)
        let out = Blender().blend(sources: [pool],
                                  config: .init(limit: 30, explorationJitter: 0, maxPerArtist: 2, maxPerAlbum: 99),
                                  using: &rng)
        XCTAssertEqual(out.count, 2)
    }

    func testExcludeAlreadyHeard() {
        let pool = items(["keep", "heard"])
        var rng = SeededGenerator(seed: 1)
        let out = Blender().blend(sources: [pool], config: .init(limit: 30, explorationJitter: 0),
                                  excluding: ["heard"], using: &rng)
        XCTAssertEqual(out.map(\.trackRef), ["keep"])
    }

    func testWeightedFuseAcrossSources() {
        let c = candidate("t1", artistId: "a1", album: "al1")
        let content = [ScoredCandidate(candidate: c, score: 1, source: "content", reason: "content")]
        let cold = [ScoredCandidate(candidate: c, score: 1, source: "coldstart", reason: "cold")]
        var rng = SeededGenerator(seed: 1)
        let out = Blender().blend(
            sources: [content, cold],
            config: .init(weights: .init(content: 0.5, sonic: 0.3, collaborative: 0.2, coldstart: 1.0),
                          limit: 30, explorationJitter: 0, maxPerArtist: 9, maxPerAlbum: 9),
            using: &rng)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].score, 1.5, accuracy: 0.0001)   // 0.5×1 (content) + 1.0×1 (coldstart)
    }
}

final class RecommendationServiceTests: XCTestCase {
    private func makeServer() -> ServerConnection {
        ServerConnection(id: "srv", kind: .jellyfin, name: "S",
                         baseURL: URL(string: "https://s.example.com")!, clientIdentifier: "c")
    }

    func testGenerateMozzWeeklyPersonalized() async throws {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let plays = PlayEventStore(db)
        let store = RecommendationStore(db)
        let server = makeServer()
        try await writer.saveServer(server)
        try await writer.upsertTracks([
            Track(id: "p1", title: "P1", artistName: "Nirvana", artistID: "ar1", genres: ["Rock"]),
            Track(id: "p2", title: "P2", artistName: "Nirvana", artistID: "ar1", genres: ["Rock"]),
            Track(id: "p3", title: "P3", artistName: "Nirvana", artistID: "ar1", genres: ["Rock"]),
            Track(id: "p4", title: "P4", artistName: "Nirvana", artistID: "ar1", genres: ["Rock"]),
            Track(id: "rock1", title: "R1", artistName: "Pixies", artistID: "ar2", genres: ["Rock"]),
            Track(id: "rock2", title: "R2", artistName: "Hole", artistID: "ar3", genres: ["Rock"]),
            Track(id: "jazz1", title: "J1", artistName: "Davis", artistID: "ar4", genres: ["Jazz"]),
        ], serverId: server.id)
        // Complete four Rock tracks yesterday → strong, recent Rock affinity.
        for id in ["p1", "p2", "p3", "p4"] {
            try await plays.append(
                PlayEvent(trackID: id, kind: .completed, createdAt: Date(timeIntervalSince1970: daysAgo(1))),
                serverId: server.id)
        }
        let service = RecommendationService(store: store, now: { now })
        let set = try await service.generateMozzWeekly(serverId: server.id, limit: 30, seed: 7)
        XCTAssertEqual(set.title, "Mozz Weekly")

        let refs = Set(try await service.mozzWeeklyTracks().map(\.remoteId))
        XCTAssertTrue(refs.contains("rock1"))
        XCTAssertTrue(refs.contains("rock2"))
        XCTAssertFalse(refs.contains("jazz1"), "no Jazz affinity → not recommended")
        XCTAssertFalse(refs.contains("p1"), "recently played is excluded from rediscovery")
        XCTAssertFalse(refs.contains("p4"))

        let items = try await service.mozzWeeklyItems()
        XCTAssertEqual(items.map(\.rank), Array(1...items.count))
        XCTAssertTrue(items.allSatisfy { $0.inLibrary })
        XCTAssertNotNil(items.first?.reason)
    }

    func testGenerateMozzWeeklyColdStart() async throws {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let store = RecommendationStore(db)
        let server = makeServer()
        try await writer.saveServer(server)
        // No listening history at all.
        try await writer.upsertTracks([
            Track(id: "a", title: "A", artistName: "X", genres: ["Rock"],
                  addedAt: Date(timeIntervalSince1970: daysAgo(1))),
            Track(id: "b", title: "B", artistName: "Y", genres: ["Jazz"],
                  addedAt: Date(timeIntervalSince1970: daysAgo(2))),
        ], serverId: server.id)
        let service = RecommendationService(store: store, now: { now })
        let set = try await service.generateMozzWeekly(serverId: server.id, seed: 7)
        XCTAssertEqual(set.title, "New to Your Library", "thin history falls back to cold start")

        let refs = Set(try await service.mozzWeeklyTracks().map(\.remoteId))
        XCTAssertEqual(refs, ["a", "b"], "cold start surfaces recently-added regardless of genre")
        let items = try await service.mozzWeeklyItems()
        XCTAssertEqual(items.first?.reason, "New to your library")
    }

    func testRegenerationReplacesItems() async throws {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let store = RecommendationStore(db)
        let server = makeServer()
        try await writer.saveServer(server)
        try await writer.upsertTracks([
            Track(id: "a", title: "A", artistName: "X", genres: ["Rock"],
                  addedAt: Date(timeIntervalSince1970: daysAgo(1))),
        ], serverId: server.id)
        let service = RecommendationService(store: store, now: { now })
        _ = try await service.generateMozzWeekly(serverId: server.id, seed: 1)
        let first = try await service.mozzWeeklyItems().count
        XCTAssertGreaterThan(first, 0)
        // Regenerate → the old items are replaced, not duplicated.
        _ = try await service.generateMozzWeekly(serverId: server.id, seed: 1)
        let second = try await service.mozzWeeklyItems().count
        XCTAssertEqual(second, first)
    }
}
