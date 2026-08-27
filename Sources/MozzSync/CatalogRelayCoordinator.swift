import Foundation
import MozzCore
import MozzDatabase
import MozzRelay

public enum CatalogRelayError: Error, Equatable {
    case invalidScope
    case incompleteSnapshot(
        expected: CatalogSnapshotCounts,
        actual: CatalogSnapshotCounts)
}

public struct CatalogRelayHydration: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case notNeeded
        case unavailable
        case imported
    }

    public var status: Status
    public var counts: CatalogSnapshotCounts
    public var writtenAtMS: Int64?

    public init(
        status: Status,
        counts: CatalogSnapshotCounts = CatalogSnapshotCounts(),
        writtenAtMS: Int64? = nil
    ) {
        self.status = status
        self.counts = counts
        self.writtenAtMS = writtenAtMS
    }
}

/// Moves a rebuildable catalog through the encrypted relay in bounded chunks.
///
/// The media server remains authoritative. Hydration runs only when the local
/// server catalog is empty, then the normal full sync reconciles it in the
/// background. Publication happens only after a complete full sync.
public actor CatalogRelayCoordinator {
    private static let pageSize = 1_000

    private let database: MusicDatabase
    private let snapshots: CatalogSnapshotDatabase
    private let relay: RelayHistoryStore
    private let localDeviceID: String

    public init(
        database: MusicDatabase,
        relay: RelayHistoryStore,
        localDeviceID: String
    ) {
        self.database = database
        self.snapshots = CatalogSnapshotDatabase(database)
        self.relay = relay
        self.localDeviceID = localDeviceID
    }

    public func hydrateIfEmpty(
        scope: CatalogSnapshotScope
    ) async throws -> CatalogRelayHydration {
        try Self.validate(scope)
        _ = try await snapshots.prepare(scope: scope)
        let repository = LibraryRepository(database)
        guard try await repository.trackCount(serverId: scope.serverID) == 0 else {
            return CatalogRelayHydration(status: .notNeeded)
        }
        guard let snapshot = try await relay.latestCatalogSnapshot(scope: scope),
              snapshot.counts.tracks > 0 else {
            return CatalogRelayHydration(status: .unavailable)
        }

        // A prior interrupted direct sync can leave album shells without tracks.
        // Start from one coherent snapshot rather than mixing those fragments in.
        try await snapshots.clearCatalog(serverID: scope.serverID)
        var imported = CatalogSnapshotCounts()
        do {
            for reference in snapshot.chunks {
                let chunk = try await relay.loadCatalogChunk(
                    reference,
                    from: snapshot)
                try await snapshots.importChunk(
                    chunk,
                    serverID: scope.serverID)
                imported = imported + chunk.counts
            }
            guard imported == snapshot.counts else {
                throw CatalogRelayError.incompleteSnapshot(
                    expected: snapshot.counts,
                    actual: imported)
            }
            return CatalogRelayHydration(
                status: .imported,
                counts: imported,
                writtenAtMS: snapshot.writtenAtMS)
        } catch {
            try? await snapshots.clearCatalog(serverID: scope.serverID)
            throw error
        }
    }

    @discardableResult
    public func publish(
        scope: CatalogSnapshotScope,
        writtenAtMS: Int64 = Int64(
            Date().timeIntervalSince1970 * 1_000)
    ) async throws -> RelayCatalogSnapshotIndex? {
        try Self.validate(scope)
        let repository = LibraryRepository(database)
        if let localScope = try await snapshots.localScope(
            serverID: scope.serverID) {
            guard localScope == scope else {
                throw CatalogRelayError.invalidScope
            }
        } else {
            _ = try await snapshots.prepare(scope: scope)
        }
        guard try await repository.trackCount(serverId: scope.serverID) > 0 else {
            return nil
        }
        if let current = try await relay.latestCatalogSnapshot(scope: scope),
           current.writtenAtMS >= writtenAtMS {
            return current
        }
        let scopeID = try RelayHistoryStore.catalogScopeID(scope)
        var references: [RelayCatalogChunkReference] = []

        var after: String?
        while true {
            let page = try await snapshots.artistsPage(
                serverID: scope.serverID,
                after: after,
                limit: Self.pageSize)
            guard !page.isEmpty else { break }
            references += try await save(
                CatalogSnapshotChunk(
                    sourceDeviceID: localDeviceID,
                    scopeID: scopeID,
                    artists: page),
                scope: scope)
            after = page.last?.id
            if page.count < Self.pageSize { break }
        }

        after = nil
        while true {
            let page = try await snapshots.albumsPage(
                serverID: scope.serverID,
                after: after,
                limit: Self.pageSize)
            guard !page.isEmpty else { break }
            references += try await save(
                CatalogSnapshotChunk(
                    sourceDeviceID: localDeviceID,
                    scopeID: scopeID,
                    albums: page),
                scope: scope)
            after = page.last?.id
            if page.count < Self.pageSize { break }
        }

        after = nil
        while true {
            let page = try await snapshots.tracksPage(
                serverID: scope.serverID,
                after: after,
                limit: Self.pageSize)
            guard !page.isEmpty else { break }
            references += try await save(
                CatalogSnapshotChunk(
                    sourceDeviceID: localDeviceID,
                    scopeID: scopeID,
                    tracks: page),
                scope: scope)
            after = page.last?.id
            if page.count < Self.pageSize { break }
        }

        after = nil
        while true {
            let page = try await snapshots.playlistsPage(
                serverID: scope.serverID,
                after: after,
                limit: Self.pageSize)
            guard !page.isEmpty else { break }
            references += try await save(
                CatalogSnapshotChunk(
                    sourceDeviceID: localDeviceID,
                    scopeID: scopeID,
                    playlists: page),
                scope: scope)
            for playlist in page {
                var itemOffset = 0
                while true {
                    let itemPage = try await snapshots.playlistItemsPage(
                        serverID: scope.serverID,
                        playlistRemoteID: playlist.id,
                        offset: itemOffset,
                        limit: Self.pageSize)
                    guard !itemPage.isEmpty else { break }
                    references += try await save(
                        CatalogSnapshotChunk(
                            sourceDeviceID: localDeviceID,
                            scopeID: scopeID,
                            playlistItems: [
                                CatalogSnapshotPlaylistItems(
                                    playlistRemoteID: playlist.id,
                                    startPosition: itemOffset,
                                    trackRemoteIDs: itemPage),
                            ]),
                        scope: scope)
                    itemOffset += itemPage.count
                    if itemPage.count < Self.pageSize { break }
                }
            }
            after = page.last?.id
            if page.count < Self.pageSize { break }
        }

        let counts = references.reduce(CatalogSnapshotCounts()) {
            $0 + $1.counts
        }
        let index = RelayCatalogSnapshotIndex(
            sourceDeviceID: localDeviceID,
            scope: scope,
            writtenAtMS: writtenAtMS,
            counts: counts,
            chunks: references)
        try await relay.saveCatalogSnapshot(index)
        return index
    }

    /// Publish only a catalog proven complete by the normal authoritative sync.
    /// A relay-hydrated cache has no completed run and cannot become the source
    /// of a second-generation snapshot before it has reconciled with the server.
    @discardableResult
    public func publishLatestComplete(
        scope: CatalogSnapshotScope
    ) async throws -> RelayCatalogSnapshotIndex? {
        guard let completed = try await CatalogSyncStore(database)
            .completedRunAt(serverId: scope.serverID) else {
            return nil
        }
        return try await publish(
            scope: scope,
            writtenAtMS: Int64(completed.timeIntervalSince1970 * 1_000))
    }

    /// Split only when real encoded bytes exceed the relay bound. Fixed record
    /// counts alone are unsafe because server-provided titles and genre lists
    /// have variable size.
    private func save(
        _ chunk: CatalogSnapshotChunk,
        scope: CatalogSnapshotScope
    ) async throws -> [RelayCatalogChunkReference] {
        do {
            return [try await relay.saveCatalogChunk(chunk, scope: scope)]
        } catch let error as RelayStoreError {
            guard case .objectTooLarge = error,
                  Self.canSplit(chunk) else {
                throw error
            }
            let (first, second) = Self.split(chunk)
            let firstReferences = try await save(first, scope: scope)
            let secondReferences = try await save(second, scope: scope)
            return firstReferences + secondReferences
        }
    }

    private static func split(
        _ chunk: CatalogSnapshotChunk
    ) -> (CatalogSnapshotChunk, CatalogSnapshotChunk) {
        switch chunk.kind {
        case .artists:
            let middle = chunk.artists.count / 2
            return (
                CatalogSnapshotChunk(
                    sourceDeviceID: chunk.sourceDeviceID,
                    scopeID: chunk.scopeID,
                    artists: Array(chunk.artists[..<middle])),
                CatalogSnapshotChunk(
                    sourceDeviceID: chunk.sourceDeviceID,
                    scopeID: chunk.scopeID,
                    artists: Array(chunk.artists[middle...])))
        case .albums:
            let middle = chunk.albums.count / 2
            return (
                CatalogSnapshotChunk(
                    sourceDeviceID: chunk.sourceDeviceID,
                    scopeID: chunk.scopeID,
                    albums: Array(chunk.albums[..<middle])),
                CatalogSnapshotChunk(
                    sourceDeviceID: chunk.sourceDeviceID,
                    scopeID: chunk.scopeID,
                    albums: Array(chunk.albums[middle...])))
        case .tracks:
            let middle = chunk.tracks.count / 2
            return (
                CatalogSnapshotChunk(
                    sourceDeviceID: chunk.sourceDeviceID,
                    scopeID: chunk.scopeID,
                    tracks: Array(chunk.tracks[..<middle])),
                CatalogSnapshotChunk(
                    sourceDeviceID: chunk.sourceDeviceID,
                    scopeID: chunk.scopeID,
                    tracks: Array(chunk.tracks[middle...])))
        case .playlists:
            let middle = chunk.playlists.count / 2
            return (
                CatalogSnapshotChunk(
                    sourceDeviceID: chunk.sourceDeviceID,
                    scopeID: chunk.scopeID,
                    playlists: Array(chunk.playlists[..<middle])),
                CatalogSnapshotChunk(
                    sourceDeviceID: chunk.sourceDeviceID,
                    scopeID: chunk.scopeID,
                    playlists: Array(chunk.playlists[middle...])))
        case .playlistItems:
            if chunk.playlistItems.count > 1 {
                let middle = chunk.playlistItems.count / 2
                return (
                    CatalogSnapshotChunk(
                        sourceDeviceID: chunk.sourceDeviceID,
                        scopeID: chunk.scopeID,
                        playlistItems: Array(
                            chunk.playlistItems[..<middle])),
                    CatalogSnapshotChunk(
                        sourceDeviceID: chunk.sourceDeviceID,
                        scopeID: chunk.scopeID,
                        playlistItems: Array(
                            chunk.playlistItems[middle...])))
            }
            let page = chunk.playlistItems[0]
            let middle = page.trackRemoteIDs.count / 2
            return (
                CatalogSnapshotChunk(
                    sourceDeviceID: chunk.sourceDeviceID,
                    scopeID: chunk.scopeID,
                    playlistItems: [
                        CatalogSnapshotPlaylistItems(
                            playlistRemoteID: page.playlistRemoteID,
                            startPosition: page.startPosition,
                            trackRemoteIDs: Array(
                                page.trackRemoteIDs[..<middle])),
                    ]),
                CatalogSnapshotChunk(
                    sourceDeviceID: chunk.sourceDeviceID,
                    scopeID: chunk.scopeID,
                    playlistItems: [
                        CatalogSnapshotPlaylistItems(
                            playlistRemoteID: page.playlistRemoteID,
                            startPosition: page.startPosition + middle,
                            trackRemoteIDs: Array(
                                page.trackRemoteIDs[middle...])),
                    ]))
        }
    }

    private static func canSplit(_ chunk: CatalogSnapshotChunk) -> Bool {
        if chunk.recordCount > 1 { return true }
        guard chunk.kind == .playlistItems,
              let page = chunk.playlistItems.first else {
            return false
        }
        return page.trackRemoteIDs.count > 1
    }

    private static func validate(_ scope: CatalogSnapshotScope) throws {
        guard !scope.serverID.isEmpty, !scope.accountID.isEmpty else {
            throw CatalogRelayError.invalidScope
        }
    }
}
