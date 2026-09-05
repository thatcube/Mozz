import XCTest
import MozzCore
import MozzDatabase
@testable import MozzRecommend

private func stationServer() -> ServerConnection {
    ServerConnection(id: "ssrv", kind: .plex, name: "T",
                     baseURL: URL(string: "https://x.local")!, userID: nil, clientIdentifier: "c1")
}

private func owned(_ remoteId: String, artist: String, score: Double) -> ScoredOwnedTrack {
    ScoredOwnedTrack(
        candidate: TrackCandidate(
            trackRef: "ssrv:\(remoteId)", remoteId: remoteId, title: remoteId,
            artistName: artist, artistRemoteId: artist, albumRemoteId: nil,
            genres: ["Rock"], addedAt: nil),
        score: score)
}

final class RadioStationTests: XCTestCase {

    private func makeService() async throws -> (RecommendationService, ServerID) {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        try await writer.saveServer(stationServer())
        try await writer.upsertTracks((1...12).map {
            Track(id: "rock\($0)", title: "R\($0)", artistName: "Genre\($0)",
                  artistID: "g\($0)", genres: ["Rock"])
        }, serverId: "ssrv")
        return (RecommendationService(store: RecommendationStore(db)), "ssrv")
    }

    private func rockSeed() -> RadioSeed {
        RadioSeed(title: "Seed", genres: ["Rock"], artistIds: [], seedTrackRef: "ssrv:seed")
    }

    // MARK: What a station remembers

    func testASecondBatchDoesNotRepeatTheFirst() async throws {
        let (service, serverId) = try await makeService()
        let station = RadioStation(recommendations: service)

        let first = await station.start(seed: rockSeed(), serverId: serverId, limit: 4)
        XCTAssertEqual(first.count, 4)
        let second = await station.next(limit: 4)
        XCTAssertEqual(second.count, 4)
        XCTAssertTrue(Set(first).isDisjoint(with: Set(second)),
                      "a station that repeats itself after four songs is not endless")
    }

    func testTheSeedTrackIsExcludedFromItsOwnStation() async throws {
        let (service, serverId) = try await makeService()
        let station = RadioStation(recommendations: service)
        let seedTrack = RadioTrackSeed(remoteId: "rock1", title: "R1", genres: ["Rock"])

        let ids = await station.start(fromTrack: seedTrack, serverId: serverId, limit: 6)
        XCTAssertFalse(ids.contains("rock1"),
                       "the shell plays the seed itself; the batch is what comes after")
    }

    func testNextIsEmptyWithoutAStation() async throws {
        let (service, _) = try await makeService()
        let station = RadioStation(recommendations: service)
        let ids = await station.next()
        XCTAssertTrue(ids.isEmpty)
    }

    func testStoppingEndsTheStation() async throws {
        let (service, serverId) = try await makeService()
        let station = RadioStation(recommendations: service)

        _ = await station.start(seed: rockSeed(), serverId: serverId, limit: 3)
        var state = await station.state
        XCTAssertNotNil(state)

        await station.stop()
        state = await station.state
        XCTAssertNil(state)
        let ids = await station.next()
        XCTAssertTrue(ids.isEmpty, "a stopped station cannot top up a queue it no longer owns")
    }

    func testStateCountsWhatTheStationHasHandedOut() async throws {
        let (service, serverId) = try await makeService()
        let station = RadioStation(recommendations: service)

        _ = await station.start(seed: rockSeed(), serverId: serverId, limit: 4)
        _ = await station.next(limit: 3)
        let state = await station.state
        XCTAssertEqual(state?.surfaced, 7)
        XCTAssertEqual(state?.serverId, serverId)
    }

    // MARK: Where the candidates come from

    func testTheServersOwnAnalysisIsPreferredToThisDevices() async throws {
        let (service, serverId) = try await makeService()
        // The server answered, so the local vectors are never consulted — which
        // is the point: the server analysed the whole library, this device has
        // only analysed what it got through.
        let sources = RadioStation.Sources(
            serverSonicMatches: { _, _, _ in [SonicMatch(trackID: "rock9", similarity: 0.8)] },
            sonicEngine: { XCTFail("the local engine was consulted anyway"); return nil }
        )
        let station = RadioStation(recommendations: service, sources: sources)

        let ids = await station.start(seed: rockSeed(), serverId: serverId, limit: 5)
        XCTAssertEqual(ids.first, "rock9", "the acoustic tier leads the batch")
    }

    func testTheCollaborativeTierIsConsultedAndExcluded() async throws {
        let (service, serverId) = try await makeService()
        let asked = Mutex<[Set<String>]>([])
        let sources = RadioStation.Sources(
            collaborativeMatches: { _, _, excluding, _ in
                asked.withLock { $0.append(excluding) }
                return [owned("rock7", artist: "Crowd", score: 0.9)]
            }
        )
        let station = RadioStation(recommendations: service, sources: sources)

        let first = await station.start(seed: rockSeed(), serverId: serverId, limit: 4)
        XCTAssertEqual(first.first, "rock7", "with no acoustic tier, the crowd leads")

        _ = await station.next(limit: 4)
        let exclusions = asked.withLock { $0 }
        XCTAssertEqual(exclusions.count, 2)
        XCTAssertTrue(exclusions[1].contains("rock7"),
                      "the second batch asks the crowd for something it has not already played")
    }

    func testASeedWithNoTrackRefSkipsTheAcousticTier() async throws {
        let (service, serverId) = try await makeService()
        let sources = RadioStation.Sources(
            serverSonicMatches: { _, _, _ in
                XCTFail("an artist seed has no track to find neighbours for")
                return []
            }
        )
        let station = RadioStation(recommendations: service, sources: sources)
        let seed = RadioSeed(title: "Band", genres: ["Rock"], artistIds: ["g1"])

        let ids = await station.start(seed: seed, serverId: serverId, limit: 3)
        XCTAssertEqual(ids.count, 3, "the genre floor still fills it")
    }

    // MARK: Adopting what is already playing

    func testAdoptingFormsAStationBehindTheCurrentTrack() async throws {
        let (service, serverId) = try await makeService()
        let station = RadioStation(recommendations: service)

        await station.adopt(seed: rockSeed(), serverId: serverId, playing: "rock1")
        let state = await station.state
        XCTAssertNotNil(state, "adopting installs a station without producing a batch")

        let ids = await station.next(limit: 5)
        XCTAssertFalse(ids.contains("rock1"), "what is already playing is not queued again")
    }
}

/// A tiny lock so a test closure can record what it was asked, without the
/// station's actor isolation leaking into the assertions.
private final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
