import Foundation
import MozzCore
import MozzDatabase

/// Progress emitted as a catalog sync advances, for a progress bar / status
/// line. `totalCount` is advisory (the backend may not report it).
public struct SyncProgress: Sendable, Hashable {
    public enum Phase: String, Sendable {
        case capabilities
        case artists
        case albums
        case tracks
        case playlists
        case pruning
        case done
    }

    public var phase: Phase
    public var itemsSynced: Int
    public var totalCount: Int?

    public init(phase: Phase, itemsSynced: Int, totalCount: Int? = nil) {
        self.phase = phase
        self.itemsSynced = itemsSynced
        self.totalCount = totalCount
    }
}

/// What a completed sync wrote.
public struct SyncSummary: Sendable, Hashable {
    public var artists: Int
    public var albums: Int
    public var tracks: Int
    public var playlists: Int
    public var deleted: Int
    public var duration: TimeInterval

    public init(artists: Int = 0, albums: Int = 0, tracks: Int = 0, playlists: Int = 0, deleted: Int = 0, duration: TimeInterval = 0) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
        self.playlists = playlists
        self.deleted = deleted
        self.duration = duration
    }
}

/// Mirrors a backend's entire music catalog into the source-of-truth database,
/// one page at a time.
///
/// Design:
/// - **Backend-agnostic.** It drives the ``MusicBackend`` paging API; Plex vs
///   Jellyfin differences never leak in. (For Plex, the caller resolves the
///   music section id onto the connection *before* constructing the backend.)
/// - **Off the main thread.** Everything is `async`; network decode happens in
///   the provider's task and every write lands on GRDB's writer connection.
///   Batches are streamed straight to ``CatalogWriter`` so peak memory stays at
///   one page, not the whole library.
/// - **Id-stable + prunes.** Writes are UPSERTs keyed on (server, remoteId), so
///   downloads survive a resync; a full sync then deletes rows it no longer saw.
/// - **Cancellable.** Cooperatively checks for cancellation between pages.
public struct LibrarySyncEngine: Sendable {
    private let backend: any MusicBackend
    private let writer: CatalogWriter
    private let pageSize: Int

    private var serverId: ServerID { backend.connection.id }

    public init(backend: any MusicBackend, database: MusicDatabase, pageSize: Int = 500) {
        self.backend = backend
        self.writer = CatalogWriter(database)
        self.pageSize = pageSize
    }

    /// Run a full catalog sync. Emits progress and returns a summary.
    @discardableResult
    public func sync(progress: (@Sendable (SyncProgress) -> Void)? = nil) async throws -> SyncSummary {
        let started = Date()

        try await writer.saveServer(backend.connection)
        progress?(SyncProgress(phase: .capabilities, itemsSynced: 0))
        let capabilities = try await backend.detectCapabilities()
        try await writer.saveCapabilities(capabilities, serverId: serverId)

        let artistIDs = try await syncPages(
            phase: .artists,
            fetch: { try await backend.fetchArtists(offset: $0, limit: $1) },
            write: { try await writer.upsertArtists($0, serverId: serverId) },
            id: \.id,
            progress: progress
        )
        let albumIDs = try await syncPages(
            phase: .albums,
            fetch: { try await backend.fetchAlbums(offset: $0, limit: $1) },
            write: { try await writer.upsertAlbums($0, serverId: serverId) },
            id: \.id,
            progress: progress
        )
        let trackIDs = try await syncPages(
            phase: .tracks,
            fetch: { try await backend.fetchTracks(offset: $0, limit: $1) },
            write: { try await writer.upsertTracks($0, serverId: serverId) },
            id: \.id,
            progress: progress
        )
        let playlistIDs = try await syncPlaylists(progress: progress)

        progress?(SyncProgress(phase: .pruning, itemsSynced: 0))
        var deleted = 0
        deleted += try await writer.pruneTracks(serverId: serverId, keeping: trackIDs)
        deleted += try await writer.pruneAlbums(serverId: serverId, keeping: albumIDs)
        deleted += try await writer.pruneArtists(serverId: serverId, keeping: artistIDs)
        deleted += try await writer.prunePlaylists(serverId: serverId, keeping: playlistIDs)

        let summary = SyncSummary(
            artists: artistIDs.count,
            albums: albumIDs.count,
            tracks: trackIDs.count,
            playlists: playlistIDs.count,
            deleted: deleted,
            duration: Date().timeIntervalSince(started)
        )
        progress?(SyncProgress(phase: .done, itemsSynced: summary.tracks, totalCount: summary.tracks))
        return summary
    }

    // MARK: Paging

    /// Page one entity type to exhaustion, writing each batch and collecting the
    /// remote ids seen (for pruning). Stops on the first short/empty page.
    private func syncPages<Item: Sendable>(
        phase: SyncProgress.Phase,
        fetch: @Sendable (Int, Int) async throws -> CatalogPage<Item>,
        write: @Sendable ([Item]) async throws -> Void,
        id: @Sendable (Item) -> String,
        progress: (@Sendable (SyncProgress) -> Void)?
    ) async throws -> [String] {
        var offset = 0
        var seen: [String] = []
        while true {
            try Task.checkCancellation()
            let page = try await fetch(offset, pageSize)
            if page.items.isEmpty { break }
            try await write(page.items)
            seen.append(contentsOf: page.items.map(id))
            progress?(SyncProgress(phase: phase, itemsSynced: seen.count, totalCount: page.totalCount))
            offset += page.items.count
            if page.items.count < pageSize { break }
        }
        return seen
    }

    /// Playlists need a second pass to sync their ordered items.
    private func syncPlaylists(progress: (@Sendable (SyncProgress) -> Void)?) async throws -> [String] {
        var offset = 0
        var playlists: [Playlist] = []
        while true {
            try Task.checkCancellation()
            let page = try await backend.fetchPlaylists(offset: offset, limit: pageSize)
            if page.items.isEmpty { break }
            try await writer.upsertPlaylists(page.items, serverId: serverId)
            playlists.append(contentsOf: page.items)
            progress?(SyncProgress(phase: .playlists, itemsSynced: playlists.count, totalCount: page.totalCount))
            offset += page.items.count
            if page.items.count < pageSize { break }
        }

        for playlist in playlists {
            try Task.checkCancellation()
            let itemIDs = try await fetchPlaylistItemIDs(playlistID: playlist.id)
            try await writer.replacePlaylistItems(playlistRemoteId: playlist.id, trackRemoteIds: itemIDs, serverId: serverId)
        }
        return playlists.map(\.id)
    }

    private func fetchPlaylistItemIDs(playlistID: String) async throws -> [String] {
        var offset = 0
        var ids: [String] = []
        while true {
            try Task.checkCancellation()
            let page = try await backend.fetchPlaylistItems(playlistID: playlistID, offset: offset, limit: pageSize)
            if page.items.isEmpty { break }
            // Ensure any track only reachable via a playlist is in the catalog.
            try await writer.upsertTracks(page.items, serverId: serverId)
            ids.append(contentsOf: page.items.map(\.id))
            offset += page.items.count
            if page.items.count < pageSize { break }
        }
        return ids
    }
}
