import Foundation
import MozzCore
import MozzDatabase
import MozzRelay
@testable import MozzSync
import XCTest

private actor CatalogMemoryRelayStore: RelayObjectStore {
    private struct Stored {
        var data: Data
        var etag: String
    }

    private var values: [String: Stored] = [:]
    private var generation = 0
    private(set) var putCount = 0

    func read(
        path: String,
        ifNoneMatch: String?
    ) async throws -> RelayReadResult {
        guard let value = values[path] else { return .missing }
        if value.etag == ifNoneMatch { return .notModified }
        return .object(RelayStoredObject(
            data: value.data,
            etag: value.etag))
    }

    func put(
        path: String,
        data: Data,
        condition: RelayWriteCondition
    ) async throws -> String {
        generation += 1
        putCount += 1
        let etag = "etag-\(generation)"
        values[path] = Stored(data: data, etag: etag)
        return etag
    }

    func list(prefix: String) async throws -> [String] {
        values.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    func corruptFirstPath(containing fragment: String) {
        guard let path = values.keys.first(where: { $0.contains(fragment) }),
              var value = values[path],
              !value.data.isEmpty else {
            return
        }
        value.data[value.data.startIndex] ^= 0xFF
        values[path] = value
    }
}

final class CatalogRelayCoordinatorTests: XCTestCase {
    private let key = Data(repeating: 0xA7, count: 32)
    private let scope = CatalogSnapshotScope(
        backend: .jellyfin,
        serverID: "jellyfin-server",
        accountID: "user-1",
        libraryIDs: ["music"])

    private func server() -> ServerConnection {
        ServerConnection(
            id: scope.serverID,
            kind: .jellyfin,
            name: "Home",
            baseURL: URL(string: "https://music.example")!,
            userID: scope.accountID,
            clientIdentifier: UUID().uuidString)
    }

    private func relay(
        objects: CatalogMemoryRelayStore,
        deviceID: String
    ) throws -> RelayHistoryStore {
        try RelayHistoryStore(
            objects: objects,
            channelID: "channel",
            localDeviceID: deviceID,
            epoch: 1,
            channelKey: key)
    }

    private func seed(
        _ database: MusicDatabase,
        suffix: String = ""
    ) async throws {
        let writer = CatalogWriter(database)
        try await writer.saveServer(server())
        try await writer.upsertArtists([
            Artist(
                id: "artist\(suffix)",
                name: "Artist \(suffix)",
                genres: ["Rock"]),
        ], serverId: scope.serverID)
        try await writer.upsertAlbums([
            Album(
                id: "album\(suffix)",
                title: "Album \(suffix)",
                artistName: "Artist \(suffix)",
                artistID: "artist\(suffix)"),
        ], serverId: scope.serverID)
        let tracks = (1...3).map {
            Track(
                id: "track\(suffix)-\($0)",
                title: "Track \($0)",
                albumTitle: "Album \(suffix)",
                albumID: "album\(suffix)",
                artistName: "Artist \(suffix)",
                artistID: "artist\(suffix)",
                duration: Double($0 * 60),
                isFavorite: $0 == 2)
        }

        try await writer.upsertTracks(tracks, serverId: scope.serverID)
        let playlist = Playlist(
            id: "playlist\(suffix)",
            title: "Mix \(suffix)",
            trackCount: tracks.count)
        try await writer.upsertPlaylistPage(
            [playlist],
            itemIDsByPlaylist: [
                playlist.id: Array(tracks.map(\.id).reversed()),
            ],
            serverId: scope.serverID,
            syncCheckpoint: nil)
    }

    func testScopeNormalizesLibraryOrderAndSeparatesAccounts() {
        let first = CatalogSnapshotScope(
            backend: .plex,
            serverID: "plex-server",
            accountID: "owner",
            libraryIDs: ["2", "1", "2"])
        let same = CatalogSnapshotScope(
            backend: .plex,
            serverID: "plex-server",
            accountID: "owner",
            libraryIDs: ["1", "2"])
        var otherAccount = same
        otherAccount.accountID = "managed-user"

        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, otherAccount)
    }

    func testChangingTheAccountScopeClearsThePreviousCatalog() async throws {
        let database = try MusicDatabase.inMemory()
        try await seed(database)
        let snapshots = CatalogSnapshotDatabase(database)

        let adopted = try await snapshots.prepare(scope: scope)
        let countAfterAdoption = try await database.trackCount()
        var otherAccount = scope
        otherAccount.accountID = "user-2"
        let cleared = try await snapshots.prepare(scope: otherAccount)
        let countAfterSwitch = try await database.trackCount()

        XCTAssertFalse(adopted)
        XCTAssertEqual(countAfterAdoption, 3)
        XCTAssertTrue(cleared)
        XCTAssertEqual(countAfterSwitch, 0)
    }

    func testACompleteSnapshotHydratesEveryCatalogSurface() async throws {
        let objects = CatalogMemoryRelayStore()
        let source = try MusicDatabase.inMemory()
        try await seed(source)
        let publisher = CatalogRelayCoordinator(
            database: source,
            relay: try relay(objects: objects, deviceID: "phone"),
            localDeviceID: "phone")

        let published = try await publisher.publish(
            scope: scope,
            writtenAtMS: 100)
        XCTAssertEqual(published?.counts, CatalogSnapshotCounts(
            artists: 1,
            albums: 1,
            tracks: 3,
            playlists: 1,
            playlistItems: 3))

        let target = try MusicDatabase.inMemory()
        try await CatalogWriter(target).saveServer(server())
        let hydration = try await CatalogRelayCoordinator(
            database: target,
            relay: try relay(objects: objects, deviceID: "pc"),
            localDeviceID: "pc"
        ).hydrateIfEmpty(scope: scope)

        XCTAssertEqual(hydration.status, .imported)
        XCTAssertEqual(hydration.counts, published?.counts)
        let repository = LibraryRepository(target)
        let trackCount = try await repository.trackCount(
            serverId: scope.serverID)
        let genres = try await repository.artist(
            serverId: scope.serverID,
            remoteId: "artist")?.genres
        let favorite = try await repository.track(
            serverId: scope.serverID,
            remoteId: "track-2")?.isFavorite
        let playlistTracks = try await repository.tracks(
            forPlaylistRemoteId: "playlist",
            serverId: scope.serverID).map(\.remoteId)
        XCTAssertEqual(trackCount, 3)
        XCTAssertEqual(genres, ["Rock"])
        XCTAssertEqual(favorite, true)
        XCTAssertEqual(
            playlistTracks,
            ["track-3", "track-2", "track-1"])
    }

    func testNewestWholeSnapshotWinsWithoutMergingDevices() async throws {
        let objects = CatalogMemoryRelayStore()
        let oldDatabase = try MusicDatabase.inMemory()
        try await seed(oldDatabase, suffix: "-old")
        _ = try await CatalogRelayCoordinator(
            database: oldDatabase,
            relay: try relay(objects: objects, deviceID: "phone"),
            localDeviceID: "phone"
        ).publish(scope: scope, writtenAtMS: 100)

        let newDatabase = try MusicDatabase.inMemory()
        try await seed(newDatabase, suffix: "-new")
        _ = try await CatalogRelayCoordinator(
            database: newDatabase,
            relay: try relay(objects: objects, deviceID: "laptop"),
            localDeviceID: "laptop"
        ).publish(scope: scope, writtenAtMS: 200)

        let target = try MusicDatabase.inMemory()
        try await CatalogWriter(target).saveServer(server())
        _ = try await CatalogRelayCoordinator(
            database: target,
            relay: try relay(objects: objects, deviceID: "reader"),
            localDeviceID: "reader"
        ).hydrateIfEmpty(scope: scope)
        let repository = LibraryRepository(target)

        let oldTrack = try await repository.track(
            serverId: scope.serverID,
            remoteId: "track-old-1")
        let newTrack = try await repository.track(
            serverId: scope.serverID,
            remoteId: "track-new-1")
        XCTAssertNil(oldTrack)
        XCTAssertNotNil(newTrack)
    }

    func testWrongAccountScopeCannotHydrate() async throws {
        let objects = CatalogMemoryRelayStore()
        let source = try MusicDatabase.inMemory()
        try await seed(source)
        _ = try await CatalogRelayCoordinator(
            database: source,
            relay: try relay(objects: objects, deviceID: "phone"),
            localDeviceID: "phone"
        ).publish(scope: scope)

        let target = try MusicDatabase.inMemory()
        try await CatalogWriter(target).saveServer(server())
        var other = scope
        other.accountID = "other-user"
        let result = try await CatalogRelayCoordinator(
            database: target,
            relay: try relay(objects: objects, deviceID: "pc"),
            localDeviceID: "pc"
        ).hydrateIfEmpty(scope: other)

        XCTAssertEqual(result.status, .unavailable)
        let trackCount = try await target.trackCount()
        XCTAssertEqual(trackCount, 0)
    }

    func testPublishingAnUnchangedCatalogWritesNoObjects() async throws {
        let objects = CatalogMemoryRelayStore()
        let source = try MusicDatabase.inMemory()
        try await seed(source)
        let coordinator = CatalogRelayCoordinator(
            database: source,
            relay: try relay(objects: objects, deviceID: "phone"),
            localDeviceID: "phone")

        _ = try await coordinator.publish(
            scope: scope,
            writtenAtMS: 100)
        let firstPutCount = await objects.putCount
        _ = try await coordinator.publish(
            scope: scope,
            writtenAtMS: 100)
        let secondPutCount = await objects.putCount

        XCTAssertEqual(secondPutCount, firstPutCount)
    }

    func testAnOversizedPageSplitsBeforeUpload() async throws {
        let objects = CatalogMemoryRelayStore()
        let source = try MusicDatabase.inMemory()
        let writer = CatalogWriter(source)
        try await writer.saveServer(server())
        let longTitle = String(
            repeating: "x",
            // The DB materializes `sortTitle` from title, so each title appears
            // twice in the exported record.
            count: RelayHistoryStore.maximumCatalogChunkBytes / 4 + 10_000)
        try await writer.upsertTracks([
            Track(id: "large-1", title: longTitle, artistName: "Artist"),
            Track(id: "large-2", title: longTitle, artistName: "Artist"),
        ], serverId: scope.serverID)

        let snapshot = try await CatalogRelayCoordinator(
            database: source,
            relay: try relay(objects: objects, deviceID: "phone"),
            localDeviceID: "phone"
        ).publish(scope: scope, writtenAtMS: 100)
        let trackChunks = snapshot?.chunks.filter { $0.kind == .tracks }

        XCTAssertEqual(trackChunks?.count, 2)
        XCTAssertTrue(
            trackChunks?.allSatisfy {
                $0.plaintextBytes <= RelayHistoryStore.maximumCatalogChunkBytes
            } == true)
    }

    func testOneHugePlaylistSplitsItsMembershipAndRestoresInOrder() async throws {
        let objects = CatalogMemoryRelayStore()
        let source = try MusicDatabase.inMemory()
        let writer = CatalogWriter(source)
        try await writer.saveServer(server())
        try await writer.upsertTracks([
            Track(id: "playable", title: "Playable", artistName: "Artist"),
        ], serverId: scope.serverID)
        try await writer.upsertPlaylists([
            Playlist(id: "huge", title: "Huge"),
        ], serverId: scope.serverID)
        let itemIDs = (0..<1_000).map {
            String(repeating: "x", count: 2_500) + String(format: "%04d", $0)
        }
        try await writer.replacePlaylistItems(
            playlistRemoteId: "huge",
            trackRemoteIds: itemIDs,
            serverId: scope.serverID)

        let snapshot = try await CatalogRelayCoordinator(
            database: source,
            relay: try relay(objects: objects, deviceID: "phone"),
            localDeviceID: "phone"
        ).publish(scope: scope, writtenAtMS: 100)
        let itemChunks = snapshot?.chunks.filter {
            $0.kind == .playlistItems
        } ?? []

        XCTAssertGreaterThan(itemChunks.count, 1)
        XCTAssertEqual(
            itemChunks.reduce(0) { $0 + $1.counts.playlistItems },
            itemIDs.count)

        let target = try MusicDatabase.inMemory()
        try await CatalogWriter(target).saveServer(server())
        _ = try await CatalogRelayCoordinator(
            database: target,
            relay: try relay(objects: objects, deviceID: "pc"),
            localDeviceID: "pc"
        ).hydrateIfEmpty(scope: scope)
        let restored = try await CatalogSnapshotDatabase(target)
            .playlistItemsPage(
                serverID: scope.serverID,
                playlistRemoteID: "huge",
                offset: 0,
                limit: 1_000)

        XCTAssertEqual(restored, itemIDs)
    }

    func testInterruptedHydrationRemovesPartialCatalog() async throws {
        let objects = CatalogMemoryRelayStore()
        let source = try MusicDatabase.inMemory()
        try await seed(source)
        _ = try await CatalogRelayCoordinator(
            database: source,
            relay: try relay(objects: objects, deviceID: "phone"),
            localDeviceID: "phone"
        ).publish(scope: scope)
        await objects.corruptFirstPath(containing: "/tracks/")

        let target = try MusicDatabase.inMemory()
        try await CatalogWriter(target).saveServer(server())
        let reader = CatalogRelayCoordinator(
            database: target,
            relay: try relay(objects: objects, deviceID: "pc"),
            localDeviceID: "pc")
        do {
            _ = try await reader.hydrateIfEmpty(scope: scope)
            XCTFail("corrupt snapshot unexpectedly hydrated")
        } catch {
            let trackCount = try await target.trackCount()
            let artistCount = try await LibraryRepository(target).artistCount(
                serverId: scope.serverID)
            XCTAssertEqual(trackCount, 0)
            XCTAssertEqual(artistCount, 0)
        }
    }
}
