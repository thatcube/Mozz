import Foundation
import MozzCore
import MozzDatabase
import MozzRelay
@testable import MozzSync
import XCTest

/// Moving analyzed vectors between a listener's own devices.
///
/// The point of the feature: analysis costs a phone an evening, and the answer
/// is identical wherever it runs — both engines are deliberately free of every
/// platform framework so that a vector computed on a Pixel belongs in the same
/// index as the same track computed on an iPhone. Without this the second
/// device repeats sixteen hours of work to arrive at bytes the first one has.
final class SonicFeatureRelayTests: XCTestCase {
    private let key = Data(repeating: 0x5C, count: 32)
    private let scope = CatalogSnapshotScope(
        backend: .jellyfin,
        serverID: "jellyfin-server",
        accountID: "user-1",
        libraryIDs: ["music"])

    private func server() -> ServerConnection {
        ServerConnection(
            id: scope.serverID, kind: .jellyfin, name: "Home",
            baseURL: URL(string: "https://music.example")!,
            userID: scope.accountID, clientIdentifier: UUID().uuidString)
    }

    private func relay(
        objects: FeatureMemoryRelayStore, deviceID: String
    ) throws -> RelayHistoryStore {
        try RelayHistoryStore(
            objects: objects, channelID: "channel",
            localDeviceID: deviceID, epoch: 1, channelKey: key)
    }

    /// A catalog plus `count` analyzed tracks, so a page has something to find.
    @discardableResult
    private func seed(
        _ database: MusicDatabase, analyzed count: Int,
        engine: String = "mozz-vggish@1"
    ) async throws -> [String] {
        let writer = CatalogWriter(database)
        try await writer.saveServer(server())
        let tracks = (1...count).map {
            Track(id: "track-\($0)", title: "Track \($0)",
                  artistName: "Artist", artistID: "artist", duration: 180)
        }
        try await writer.upsertTracks(tracks, serverId: scope.serverID)

        let store = RecommendationStore(database)
        var refs: [String] = []
        for (index, track) in tracks.enumerated() {
            let ref = "\(scope.serverID):\(track.id)"
            // Distinct vectors, so a mixed-up row is visible rather than lucky.
            let vector = (0..<8).map { Float(index + $0) / 10 }
            try await store.saveSonicEmbedding(
                vector, engine: engine, bpm: Double(100 + index),
                trackRef: ref, at: 1_000)
            refs.append(ref)
        }
        return refs
    }

    private func embedding(
        _ database: MusicDatabase, ref: String, engine: String
    ) async throws -> [Float]? {
        try await RecommendationStore(database)
            .sonicEmbedding(trackRef: ref, engine: engine)
    }

    // MARK: The point of the whole thing

    func testASecondDeviceInheritsWhatTheFirstAnalysed() async throws {
        let objects = FeatureMemoryRelayStore()
        let first = try MusicDatabase.inMemory()
        try await seed(first, analyzed: 5)

        let publisher = CatalogRelayCoordinator(
            database: first, relay: try relay(objects: objects, deviceID: "pixel"),
            localDeviceID: "pixel")
        let index = try await publisher.publishFeatures(scope: scope)
        XCTAssertEqual(index?.counts.features, 5)

        // A second device with the same catalog and nothing analysed.
        let second = try MusicDatabase.inMemory()
        let writer = CatalogWriter(second)
        try await writer.saveServer(server())
        try await writer.upsertTracks((1...5).map {
            Track(id: "track-\($0)", title: "Track \($0)",
                  artistName: "Artist", artistID: "artist", duration: 180)
        }, serverId: scope.serverID)

        let subscriber = CatalogRelayCoordinator(
            database: second, relay: try relay(objects: objects, deviceID: "iphone"),
            localDeviceID: "iphone")
        let imported = try await subscriber.hydrateFeatures(scope: scope)
        XCTAssertEqual(imported, 5, "sixteen hours of analysis, arriving as bytes")

        let there = try await embedding(
            second, ref: "\(scope.serverID):track-3", engine: "mozz-vggish@1")
        let here = try await embedding(
            first, ref: "\(scope.serverID):track-3", engine: "mozz-vggish@1")
        XCTAssertEqual(there, here, "the vector has to survive the round trip exactly")
    }

    func testNothingAnalysedPublishesNothing() async throws {
        let objects = FeatureMemoryRelayStore()
        let database = try MusicDatabase.inMemory()
        let writer = CatalogWriter(database)
        try await writer.saveServer(server())

        let coordinator = CatalogRelayCoordinator(
            database: database, relay: try relay(objects: objects, deviceID: "pixel"),
            localDeviceID: "pixel")
        // The ordinary state of a library on its first evening.
        let index = try await coordinator.publishFeatures(scope: scope)
        XCTAssertNil(index)
    }

    func testADeviceDoesNotImportItsOwnPublication() async throws {
        let objects = FeatureMemoryRelayStore()
        let database = try MusicDatabase.inMemory()
        try await seed(database, analyzed: 3)

        let coordinator = CatalogRelayCoordinator(
            database: database, relay: try relay(objects: objects, deviceID: "pixel"),
            localDeviceID: "pixel")
        try await coordinator.publishFeatures(scope: scope)
        let imported = try await coordinator.hydrateFeatures(scope: scope)
        XCTAssertEqual(imported, 0, "reading back our own upload costs a download to learn nothing")
    }

    func testAnExistingVectorIsNeverOverwritten() async throws {
        let objects = FeatureMemoryRelayStore()
        let first = try MusicDatabase.inMemory()
        try await seed(first, analyzed: 2, engine: "mozz-vggish@1")
        try await CatalogRelayCoordinator(
            database: first, relay: try relay(objects: objects, deviceID: "pixel"),
            localDeviceID: "pixel"
        ).publishFeatures(scope: scope)

        // The second device analysed the same track with the older engine.
        let second = try MusicDatabase.inMemory()
        try await seed(second, analyzed: 2, engine: "mozz-dsp@1")
        let mine = try await embedding(
            second, ref: "\(scope.serverID):track-1", engine: "mozz-dsp@1")

        let imported = try await CatalogRelayCoordinator(
            database: second, relay: try relay(objects: objects, deviceID: "iphone"),
            localDeviceID: "iphone"
        ).hydrateFeatures(scope: scope)

        XCTAssertEqual(imported, 0)
        // Picking a winner per row is how a library ends up with half its index
        // in each engine's space, which is worse than either engine alone.
        let after = try await embedding(
            second, ref: "\(scope.serverID):track-1", engine: "mozz-dsp@1")
        XCTAssertEqual(after, mine, "whichever engine got there first keeps the row")
    }

    func testTwoDevicesEachContributeTheHalfTheyAnalysed() async throws {
        let objects = FeatureMemoryRelayStore()
        let catalog: (MusicDatabase) async throws -> Void = { database in
            let writer = CatalogWriter(database)
            try await writer.saveServer(self.server())
            try await writer.upsertTracks((1...4).map {
                Track(id: "track-\($0)", title: "Track \($0)",
                      artistName: "Artist", artistID: "artist", duration: 180)
            }, serverId: self.scope.serverID)
        }

        // The phone got through the first two, the tablet the last two.
        let phone = try MusicDatabase.inMemory()
        try await catalog(phone)
        let tablet = try MusicDatabase.inMemory()
        try await catalog(tablet)
        for (database, ids) in [(phone, [1, 2]), (tablet, [3, 4])] {
            let store = RecommendationStore(database)
            for id in ids {
                try await store.saveSonicEmbedding(
                    [Float(id), 0.5, 0.25], engine: "mozz-vggish@1", bpm: nil,
                    trackRef: "\(scope.serverID):track-\(id)", at: 1_000)
            }
        }
        try await CatalogRelayCoordinator(
            database: phone, relay: try relay(objects: objects, deviceID: "phone"),
            localDeviceID: "phone").publishFeatures(scope: scope, writtenAtMS: 10)
        try await CatalogRelayCoordinator(
            database: tablet, relay: try relay(objects: objects, deviceID: "tablet"),
            localDeviceID: "tablet").publishFeatures(scope: scope, writtenAtMS: 20)

        // A third device takes both, not merely the newer one: unlike a
        // catalog, two devices' vectors are both true at once.
        let laptop = try MusicDatabase.inMemory()
        try await catalog(laptop)
        let imported = try await CatalogRelayCoordinator(
            database: laptop, relay: try relay(objects: objects, deviceID: "laptop"),
            localDeviceID: "laptop").hydrateFeatures(scope: scope)
        XCTAssertEqual(imported, 4, "each device held half the answer")
    }

    func testAPublicationLargerThanOnePageStillArrivesWhole() async throws {
        let objects = FeatureMemoryRelayStore()
        let first = try MusicDatabase.inMemory()
        // Past the 250-row page size, so the paging loop has to resume.
        try await seed(first, analyzed: 300)

        let index = try await CatalogRelayCoordinator(
            database: first, relay: try relay(objects: objects, deviceID: "pixel"),
            localDeviceID: "pixel").publishFeatures(scope: scope)
        XCTAssertEqual(index?.counts.features, 300)
        XCTAssertGreaterThan(index?.chunks.count ?? 0, 1, "one page could not hold it")

        let second = try MusicDatabase.inMemory()
        let writer = CatalogWriter(second)
        try await writer.saveServer(server())
        try await writer.upsertTracks((1...300).map {
            Track(id: "track-\($0)", title: "Track \($0)",
                  artistName: "Artist", artistID: "artist", duration: 180)
        }, serverId: scope.serverID)
        let imported = try await CatalogRelayCoordinator(
            database: second, relay: try relay(objects: objects, deviceID: "iphone"),
            localDeviceID: "iphone").hydrateFeatures(scope: scope)
        XCTAssertEqual(imported, 300)
    }

    // MARK: Not disturbing the catalog it travels beside

    func testAFeatureSnapshotIsNotACatalogSnapshot() async throws {
        let objects = FeatureMemoryRelayStore()
        let database = try MusicDatabase.inMemory()
        try await seed(database, analyzed: 3)

        let store = try relay(objects: objects, deviceID: "pixel")
        try await CatalogRelayCoordinator(
            database: database, relay: store, localDeviceID: "pixel"
        ).publishFeatures(scope: scope)

        // A device that predates this reads the catalog key and finds nothing,
        // rather than finding a chunk kind it cannot decode.
        let asCatalog = try await store.latestCatalogSnapshot(scope: scope)
        XCTAssertNil(asCatalog)
        let asFeatures = try await store.featureSnapshots(scope: scope)
        XCTAssertEqual(asFeatures.count, 1)
    }
}

private actor FeatureMemoryRelayStore: RelayObjectStore {
    private struct Stored { var data: Data; var etag: String }
    private var values: [String: Stored] = [:]
    private var generation = 0

    func read(path: String, ifNoneMatch: String?) async throws -> RelayReadResult {
        guard let value = values[path] else { return .missing }
        if value.etag == ifNoneMatch { return .notModified }
        return .object(RelayStoredObject(data: value.data, etag: value.etag))
    }

    func put(path: String, data: Data, condition: RelayWriteCondition) async throws -> String {
        generation += 1
        let etag = "etag-\(generation)"
        values[path] = Stored(data: data, etag: etag)
        return etag
    }

    func list(prefix: String) async throws -> [String] {
        values.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }
}
