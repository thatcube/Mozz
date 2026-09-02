import XCTest
import Foundation
import MozzCore
import MozzDatabase
@testable import MozzAnalysis

/// A backend that serves one analyzable URL per track and nothing else.
private struct StubBackend: MusicBackend {
    let connection: ServerConnection
    var kind: BackendKind { .jellyfin }
    /// Track ids this backend refuses to serve analysis audio for.
    var unservable: Set<String> = []
    var startsAtLeadIn = true

    init(serverId: String) {
        self.connection = ServerConnection(
            id: serverId, kind: .jellyfin, name: "Stub",
            baseURL: URL(string: "https://stub.example.com")!, clientIdentifier: "cid")
    }

    func detectCapabilities() async throws -> ServerCapabilities {
        ServerCapabilities(backend: .jellyfin, serverVersion: "10.9.0")
    }
    func fetchArtists(offset: Int, limit: Int) async throws -> CatalogPage<Artist> {
        CatalogPage(items: [], totalCount: 0)
    }
    func fetchAlbums(offset: Int, limit: Int) async throws -> CatalogPage<Album> {
        CatalogPage(items: [], totalCount: 0)
    }
    func fetchTracks(offset: Int, limit: Int) async throws -> CatalogPage<Track> {
        CatalogPage(items: [], totalCount: 0)
    }
    func fetchPlaylists(offset: Int, limit: Int) async throws -> CatalogPage<Playlist> {
        CatalogPage(items: [], totalCount: 0)
    }
    func fetchPlaylistItems(playlistID: String, offset: Int, limit: Int) async throws -> CatalogPage<Track> {
        CatalogPage(items: [], totalCount: 0)
    }
    func streamSource(for track: Track, options: StreamOptions) async throws -> StreamSource {
        StreamSource(url: URL(string: "https://stub.example.com/\(track.id)")!, isTranscoded: false)
    }
    func originalFileURL(for track: Track) throws -> URL {
        URL(string: "https://stub.example.com/\(track.id)/file")!
    }
    func artworkURL(for artwork: ArtworkRef, size: Int) -> URL? { nil }
    func setFavorite(_ isFavorite: Bool, itemID: String, type: CatalogItemType) async throws {}
    func setRating(_ stars: Double?, itemID: String, type: CatalogItemType) async throws {}

    func analysisAudioSource(forTrackID trackID: String) throws -> AnalysisAudioSource? {
        guard !unservable.contains(trackID) else { return nil }
        return AnalysisAudioSource(url: URL(string: "https://stub.example.com/analysis/\(trackID)")!,
                                   startsAtLeadIn: startsAtLeadIn)
    }
}

/// Records what the service asked for, and answers with fixture bytes.
private final class LoaderSpy: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requested: [URL] = []
    private(set) var budgets: [Int] = []
    private let payload: Data
    /// When set, every load throws instead of answering.
    var failure: (any Error)?

    init(payload: Data) { self.payload = payload }

    var loader: AnalysisAudioLoader {
        { [self] url, maxBytes in
            lock.lock()
            requested.append(url)
            budgets.append(maxBytes)
            let failure = self.failure
            lock.unlock()
            if let failure { throw failure }
            return payload
        }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return requested.count
    }
}

final class SonicAnalysisServiceTests: XCTestCase {
    private let serverId = "asrv"

    private func fixtureMP3() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "tone-440-6s", withExtension: "mp3", subdirectory: "Fixtures"),
            "missing analysis fixture")
        return try Data(contentsOf: url)
    }

    private func makeLibrary(trackCount: Int) async throws -> (MusicDatabase, RecommendationStore) {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        try await writer.saveServer(ServerConnection(
            id: serverId, kind: .jellyfin, name: "Stub",
            baseURL: URL(string: "https://stub.example.com")!, userID: nil, clientIdentifier: "cid"))
        try await writer.upsertTracks((1...trackCount).map {
            Track(id: "t\($0)", title: "T\($0)", artistName: "A", artistID: "a1", genres: ["Rock"])
        }, serverId: serverId)
        return (db, RecommendationStore(db))
    }

    func testAPassAnalyzesTheWholeQueueAndStoresVectors() async throws {
        let (_, store) = try await makeLibrary(trackCount: 3)
        let spy = LoaderSpy(payload: try fixtureMP3())
        let service = SonicAnalysisService(store: store, load: spy.loader,
                                           config: SonicAnalysisConfig(pauseBetweenTracks: 0))
        await service.analyze(serverId: serverId, backend: StubBackend(serverId: serverId))
        await service.waitForPass()

        let progress = await service.progress(serverId: serverId)
        XCTAssertEqual(progress.analyzed, 3)
        XCTAssertEqual(progress.total, 3)
        XCTAssertEqual(spy.count, 3)
        // The vector is the analyzer's, stamped with the analyzer's engine.
        let vector = try await store.sonicEmbedding(trackRef: "\(serverId):t1", engine: SonicAnalyzer.engine)
        XCTAssertEqual(vector?.count, SonicFeatureLayout.dimension)
    }

    func testASecondPassResumesRatherThanRedoingTheLibrary() async throws {
        let (_, store) = try await makeLibrary(trackCount: 3)
        let payload = try fixtureMP3()
        let first = LoaderSpy(payload: payload)
        let service = SonicAnalysisService(store: store, load: first.loader,
                                           config: SonicAnalysisConfig(maxPerPass: 2, pauseBetweenTracks: 0))
        await service.analyze(serverId: serverId, backend: StubBackend(serverId: serverId))
        await service.waitForPass()
        XCTAssertEqual(first.count, 2)

        let second = LoaderSpy(payload: payload)
        let resumed = SonicAnalysisService(store: store, load: second.loader,
                                           config: SonicAnalysisConfig(pauseBetweenTracks: 0))
        await resumed.analyze(serverId: serverId, backend: StubBackend(serverId: serverId))
        await resumed.waitForPass()
        // Only the track the first pass never reached: the rows already written
        // are the progress marker, so an interrupted library costs one track.
        XCTAssertEqual(second.count, 1)
        let progress = await resumed.progress(serverId: serverId)
        XCTAssertEqual(progress.analyzed, 3)
    }

    func testTracksTheBackendCannotServeAreSkippedWithoutStallingThePass() async throws {
        let (_, store) = try await makeLibrary(trackCount: 3)
        let spy = LoaderSpy(payload: try fixtureMP3())
        var backend = StubBackend(serverId: serverId)
        backend.unservable = ["t2"]
        let service = SonicAnalysisService(store: store, load: spy.loader,
                                           config: SonicAnalysisConfig(pauseBetweenTracks: 0))
        await service.analyze(serverId: serverId, backend: backend)
        await service.waitForPass()

        let progress = await service.progress(serverId: serverId)
        XCTAssertEqual(progress.analyzed, 2)
        // Nothing marks t2 as hopeless, so the pass must not spin on it: two
        // fetches, not an endless retry of the one it cannot have.
        XCTAssertEqual(spy.count, 2)
    }

    func testAServerThatFailsEveryFetchEndsThePassInsteadOfSpinning() async throws {
        let (_, store) = try await makeLibrary(trackCount: 4)
        let spy = LoaderSpy(payload: Data())
        spy.failure = MozzError.serverUnreachable
        let service = SonicAnalysisService(store: store, load: spy.loader,
                                           config: SonicAnalysisConfig(pauseBetweenTracks: 0))
        await service.analyze(serverId: serverId, backend: StubBackend(serverId: serverId))
        await service.waitForPass()

        // Every track is tried exactly once; the pass ends rather than looping
        // over a library it cannot reach.
        XCTAssertEqual(spy.count, 4)
        let progress = await service.progress(serverId: serverId)
        XCTAssertEqual(progress.analyzed, 0)
    }

    func testThePassStopsWhenTheConditionsLapse() async throws {
        let (_, store) = try await makeLibrary(trackCount: 4)
        let spy = LoaderSpy(payload: try fixtureMP3())
        // The charger comes out while the first track is downloading.
        let powered = Flag(true)
        let fetch = spy.loader
        let load: AnalysisAudioLoader = { url, maxBytes in
            let data = try await fetch(url, maxBytes)
            powered.set(false)
            return data
        }
        let service = SonicAnalysisService(store: store, load: load,
                                           config: SonicAnalysisConfig(pauseBetweenTracks: 0),
                                           isEnabled: { powered.value })
        await service.analyze(serverId: serverId, backend: StubBackend(serverId: serverId))
        await service.waitForPass()

        XCTAssertEqual(spy.count, 1)
        let progress = await service.progress(serverId: serverId)
        XCTAssertEqual(progress.analyzed, 1)
    }

    func testADisabledServiceStartsNothing() async throws {
        let (_, store) = try await makeLibrary(trackCount: 2)
        let spy = LoaderSpy(payload: try fixtureMP3())
        let service = SonicAnalysisService(store: store, load: spy.loader,
                                           config: SonicAnalysisConfig(pauseBetweenTracks: 0),
                                           isEnabled: { false })
        await service.analyze(serverId: serverId, backend: StubBackend(serverId: serverId))
        await service.waitForPass()
        XCTAssertEqual(spy.count, 0)
    }

    // MARK: - Input shaping

    func testTheWindowSkipsTheLeadInOnlyWhenTheServerDidNot() {
        let rate = 16_000
        let samples = [Float](repeating: 0.5, count: rate * 200)
        let trimmed = SonicAnalysisService.window(samples, sampleRate: rate, trimLeadIn: true)
        let served = SonicAnalysisService.window(samples, sampleRate: rate, trimLeadIn: false)
        // Both describe the same ninety seconds of music; only one of them had
        // to throw the intro away itself.
        XCTAssertEqual(trimmed.count, AnalysisAudio.windowSeconds * rate)
        XCTAssertEqual(served.count, AnalysisAudio.windowSeconds * rate)
    }

    func testAShortTrackIsAnalyzedFromTheStartRatherThanNotAtAll() {
        let rate = 16_000
        let samples = [Float](repeating: 0.5, count: rate * 6)   // a 6-second interlude
        let window = SonicAnalysisService.window(samples, sampleRate: rate, trimLeadIn: true)
        XCTAssertEqual(window.count, samples.count)
    }

    func testTheByteBudgetCoversTheLeadInOnlyWhenTheClientHasToTrimIt() {
        let served = SonicAnalysisService.byteBudget(startsAtLeadIn: true)
        let trimmed = SonicAnalysisService.byteBudget(startsAtLeadIn: false)
        XCTAssertGreaterThan(trimmed, served)
        // The window itself, at the bitrate we asked for, has to fit.
        let windowBytes = AnalysisAudio.windowSeconds * AnalysisAudio.bitrateKbps * 1_000 / 8
        XCTAssertGreaterThan(served, windowBytes)
    }
}

/// A charger, in the form of a boolean two threads can see.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool
    init(_ initial: Bool) { flag = initial }
    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }
    func set(_ newValue: Bool) {
        lock.lock(); flag = newValue; lock.unlock()
    }
}
