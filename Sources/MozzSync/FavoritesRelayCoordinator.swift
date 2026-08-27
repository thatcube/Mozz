import Foundation
import MozzCore
import MozzDatabase
import MozzRelay

public actor FavoritesRelayCoordinator {
    private let favorites: FavoritesStore
    private let relay: RelayHistoryStore
    private let localDeviceID: String

    public init(
        database: MusicDatabase,
        relay: RelayHistoryStore,
        localDeviceID: String
    ) {
        self.favorites = FavoritesStore(database)
        self.relay = relay
        self.localDeviceID = localDeviceID
    }

    public func sync(scope: CatalogSnapshotScope) async throws -> Int {
        let local = try await localRecords(serverID: scope.serverID)
        try await relay.save(RelayFavoriteSnapshot(
            deviceID: localDeviceID,
            scope: scope,
            records: local))
        let merged = RelayHistoryStore.mergedFavoriteRecords(
            try await relay.loadFavoriteSnapshots(scope: scope))
        let imported = try await favorites.importRemote(
            merged,
            serverId: scope.serverID)
        if imported > 0 {
            try await relay.save(RelayFavoriteSnapshot(
                deviceID: localDeviceID,
                scope: scope,
                records: try await localRecords(serverID: scope.serverID)))
        }
        return imported
    }

    private func localRecords(
        serverID: String
    ) async throws -> [FavoriteMutationState] {
        try await favorites.durableState(serverId: serverID).map {
            FavoriteMutationState(
                remoteID: $0.remoteId,
                itemType: $0.itemType,
                kind: $0.kind,
                value: $0.value,
                updatedAtMS: Int64($0.createdAt * 1_000),
                sourceDeviceID: $0.sourceDeviceID.isEmpty
                    ? localDeviceID
                    : $0.sourceDeviceID)
        }
    }
}
