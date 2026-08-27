import Foundation
import MozzCore
import MozzDatabase
import MozzRelay
@testable import MozzSync
import XCTest

final class FavoritesRelayCoordinatorTests: XCTestCase {
    private let key = Data(repeating: 0xD3, count: 32)
    private let scope = CatalogSnapshotScope(
        backend: .jellyfin,
        serverID: "server",
        accountID: "user")

    private func relay(
        _ objects: SettingsMemoryRelayStore,
        deviceID: String
    ) throws -> RelayHistoryStore {
        try RelayHistoryStore(
            objects: objects,
            channelID: "channel",
            localDeviceID: deviceID,
            epoch: 1,
            channelKey: key)
    }

    private func database() async throws -> MusicDatabase {
        let database = try MusicDatabase.inMemory()
        let writer = CatalogWriter(database)
        try await writer.saveServer(ServerConnection(
            id: "server",
            kind: .jellyfin,
            name: "Server",
            baseURL: URL(string: "https://example.test")!,
            userID: "user",
            clientIdentifier: UUID().uuidString))
        try await writer.upsertTracks([
            Track(id: "track", title: "Track", artistName: "Artist"),
        ], serverId: "server")
        return database
    }

    func testRemoteFavoriteUpdatesCatalogAndQueuesServerWrite() async throws {
        let objects = SettingsMemoryRelayStore()
        let phone = try await database()
        let pc = try await database()
        _ = try await FavoritesStore(phone).applyLocally(FavoriteChange(
            serverId: "server",
            remoteId: "track",
            value: .favorite(true)))
        _ = try await FavoritesRelayCoordinator(
            database: phone,
            relay: try relay(objects, deviceID: "phone"),
            localDeviceID: "phone"
        ).sync(scope: scope)

        let imported = try await FavoritesRelayCoordinator(
            database: pc,
            relay: try relay(objects, deviceID: "pc"),
            localDeviceID: "pc"
        ).sync(scope: scope)
        let track = try await LibraryRepository(pc).track(
            serverId: "server",
            remoteId: "track")
        let pending = try await FavoritesStore(pc).pending(serverId: "server")

        XCTAssertEqual(imported, 1)
        XCTAssertEqual(track?.isFavorite, true)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].sourceDeviceID, "phone")
    }

    func testSuccessfulServerFlushKeepsDurableRelayState() async throws {
        let database = try await database()
        let store = FavoritesStore(database)
        _ = try await store.applyLocally(FavoriteChange(
            serverId: "server",
            remoteId: "track",
            value: .favorite(true)))
        let pending = try await store.pending(serverId: "server")
        _ = try await store.removePending(
            id: try XCTUnwrap(pending[0].id),
            ifUnchangedSince: pending[0].createdAt)

        let remaining = try await store.pending(serverId: "server")
        let durable = try await store.durableState(serverId: "server")
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(durable.count, 1)
    }
}
