import Foundation
import MozzCore
import MozzDatabase

/// Progress emitted as a catalog sync advances, for a progress bar / status
/// line. `totalCount` is advisory (the backend may not report it).
public struct SyncProgress: Sendable, Hashable {
    public enum Phase: String, Sendable {
        case capabilities
        case syncing        // concurrent bulk pull of artists/albums/tracks/playlists
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
    ///
    /// The independent entity phases (artists, albums, tracks, playlists) run
    /// **concurrently**: the catalog schema is denormalized (a track/album stores
    /// its artist/album *ids as plain columns* — there are no foreign keys
    /// between entity types), so any write order is safe, and GRDB serializes the
    /// writer connection. Running them together overlaps four network streams and
    /// — crucially — lets albums and tracks start landing in the first second or
    /// two instead of waiting for the entire artist listing to enumerate, so a
    /// huge library becomes browsable almost immediately.
    @discardableResult
    public func sync(progress: (@Sendable (SyncProgress) -> Void)? = nil) async throws -> SyncSummary {
        let started = Date()

        try await writer.saveServer(backend.connection)
        progress?(SyncProgress(phase: .capabilities, itemsSynced: 0))
        let capabilities = try await backend.detectCapabilities()
        try await writer.saveCapabilities(capabilities, serverId: serverId)

        // A single combined progress stream across the concurrent phases, so the
        // UI shows one honest "Syncing — N of M items" instead of four racing bars.
        let aggregator = progress.map {
            ProgressAggregator(phases: [.artists, .albums, .tracks, .playlists], emit: $0)
        }
        let report: @Sendable (SyncProgress.Phase, Int, Int?) async -> Void = { phase, seen, total in
            await aggregator?.report(phase: phase, seen: seen, total: total)
        }

        async let artistsTask = syncPages(
            phase: .artists,
            fetch: { try await backend.fetchArtists(offset: $0, limit: $1) },
            write: { try await writer.upsertArtists($0, serverId: serverId) },
            id: \.id,
            report: report
        )
        async let albumsTask = syncPages(
            phase: .albums,
            fetch: { try await backend.fetchAlbums(offset: $0, limit: $1) },
            write: { try await writer.upsertAlbums($0, serverId: serverId) },
            id: \.id,
            report: report
        )
        async let tracksTask = syncPages(
            phase: .tracks,
            fetch: { try await backend.fetchTracks(offset: $0, limit: $1) },
            write: { try await writer.upsertTracks($0, serverId: serverId) },
            id: \.id,
            report: report
        )
        async let playlistsTask = syncPlaylists(report: report)

        let artistIDs = try await artistsTask
        let albumIDs = try await albumsTask
        let trackIDs = try await tracksTask
        let playlistIDs = try await playlistsTask

        // Some album-artists (DJs, producers, combined credits) are referenced by
        // albums but never returned by the artist listing, leaving their albums
        // unbrowsable. Derive artist rows for them from the just-synced albums —
        // no network. The artist prune keeps anything a surviving album still
        // references (see CatalogWriter.pruneArtists), so these survive future
        // syncs without needing to thread their ids through the keep-set here.
        _ = try await writer.synthesizeMissingAlbumArtists(serverId: serverId)

        // Prune rows the server no longer has — but ONLY when EVERY phase
        // enumerated completely (all-or-nothing). A truncated/flaky sync (fewer
        // items seen than the server's reported total, or an empty result) must
        // never prune: the `download` row cascade-deletes from `track`, so a
        // single bad sync could otherwise wipe the catalog AND the user's
        // offline downloads (and orphan the files on disk). A half-enumerated
        // sibling type must not authorize deletes for any type either — hence
        // the whole run is gated on `allPhasesComplete`.
        progress?(SyncProgress(phase: .pruning, itemsSynced: 0))
        var deleted = 0
        let allPhasesComplete = [artistIDs, albumIDs, trackIDs, playlistIDs].allSatisfy(phaseCompleted)
        if allPhasesComplete {
            deleted += try await writer.pruneTracks(serverId: serverId, keeping: trackIDs.seen)
            deleted += try await writer.pruneAlbums(serverId: serverId, keeping: albumIDs.seen)
            deleted += try await writer.pruneArtists(serverId: serverId, keeping: artistIDs.seen)
            deleted += try await writer.prunePlaylists(serverId: serverId, keeping: playlistIDs.seen)
        }

        // Report the live artist total (server-listed + synthesized) so the
        // count stays consistent across syncs — synthesized artists persist in
        // the DB but aren't in this run's server-"seen" set.
        let artistTotal = try await writer.artistCount(serverId: serverId)
        let summary = SyncSummary(
            artists: artistTotal,
            albums: albumIDs.seen.count,
            tracks: trackIDs.seen.count,
            playlists: playlistIDs.seen.count,
            deleted: deleted,
            duration: Date().timeIntervalSince(started)
        )
        progress?(SyncProgress(phase: .done, itemsSynced: summary.tracks, totalCount: summary.tracks))
        return summary
    }

    /// Whether a phase enumerated completely, which is the precondition for the
    /// (all-or-nothing) prune. If the server reported a total record count, we
    /// must have seen at least that many items; if it reported no total, we
    /// treat a non-empty result as complete and an empty one as suspect (so an
    /// unknown-total backend can never wipe a populated type on an empty read).
    /// This is the guard that stops a flaky/truncated page from deleting rows
    /// (and cascading into the user's downloads).
    private func phaseCompleted(_ enumeration: PagedEnumeration) -> Bool {
        if let total = enumeration.reportedTotal {
            return enumeration.seen.count >= total
        }
        return !enumeration.seen.isEmpty
    }

    // MARK: Paging

    /// The outcome of enumerating one entity type: the remote ids seen (for
    /// pruning) and the server's reported total (the completeness signal).
    private struct PagedEnumeration {
        var seen: [String]
        var reportedTotal: Int?
    }

    /// Page one entity type to exhaustion, writing each batch and collecting the
    /// remote ids seen (for pruning). Terminates ONLY on a genuinely empty page.
    /// A short page (fewer than `pageSize`) is *not* treated as terminal: some
    /// servers legitimately return short pages mid-enumeration, and assuming
    /// "short == done" would truncate the sync and then prune everything the
    /// truncated run never saw.
    private func syncPages<Item: Sendable>(
        phase: SyncProgress.Phase,
        fetch: @Sendable (Int, Int) async throws -> CatalogPage<Item>,
        write: @Sendable ([Item]) async throws -> Void,
        id: @Sendable (Item) -> String,
        report: @Sendable (SyncProgress.Phase, Int, Int?) async -> Void
    ) async throws -> PagedEnumeration {
        var offset = 0
        var seen: [String] = []
        var reportedTotal: Int?
        while true {
            try Task.checkCancellation()
            let page = try await fetch(offset, pageSize)
            if let total = page.totalCount { reportedTotal = max(reportedTotal ?? 0, total) }
            if page.items.isEmpty { break }
            try await write(page.items)
            seen.append(contentsOf: page.items.map(id))
            await report(phase, seen.count, reportedTotal)
            offset += page.items.count
        }
        return PagedEnumeration(seen: seen, reportedTotal: reportedTotal)
    }

    /// Playlists need a second pass to sync their ordered items.
    private func syncPlaylists(report: @Sendable (SyncProgress.Phase, Int, Int?) async -> Void) async throws -> PagedEnumeration {
        var offset = 0
        var playlists: [Playlist] = []
        var reportedTotal: Int?
        while true {
            try Task.checkCancellation()
            let page = try await backend.fetchPlaylists(offset: offset, limit: pageSize)
            if let total = page.totalCount { reportedTotal = max(reportedTotal ?? 0, total) }
            if page.items.isEmpty { break }
            try await writer.upsertPlaylists(page.items, serverId: serverId)
            playlists.append(contentsOf: page.items)
            await report(.playlists, playlists.count, reportedTotal)
            offset += page.items.count
        }

        for playlist in playlists {
            try Task.checkCancellation()
            let itemIDs = try await fetchPlaylistItemIDs(playlistID: playlist.id)
            try await writer.replacePlaylistItems(playlistRemoteId: playlist.id, trackRemoteIds: itemIDs, serverId: serverId)
        }
        return PagedEnumeration(seen: playlists.map(\.id), reportedTotal: reportedTotal)
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
        }
        return ids
    }
}

/// Merges progress from the concurrently-running entity phases into one combined
/// `SyncProgress` (phase `.syncing`): the sum of items seen across phases, and a
/// determinate total only once every phase has reported its server total (so the
/// bar shows a spinner + live count first, then a smooth determinate bar — never
/// a total that lurches as each phase's count arrives).
private actor ProgressAggregator {
    private let phases: Set<SyncProgress.Phase>
    private let emit: @Sendable (SyncProgress) -> Void
    private var seen: [SyncProgress.Phase: Int] = [:]
    private var totals: [SyncProgress.Phase: Int] = [:]

    init(phases: Set<SyncProgress.Phase>, emit: @escaping @Sendable (SyncProgress) -> Void) {
        self.phases = phases
        self.emit = emit
    }

    func report(phase: SyncProgress.Phase, seen count: Int, total: Int?) {
        seen[phase] = count
        if let total { totals[phase] = max(totals[phase] ?? 0, total) }
        let combinedSeen = seen.values.reduce(0, +)
        let combinedTotal = totals.count == phases.count ? totals.values.reduce(0, +) : nil
        emit(SyncProgress(phase: .syncing, itemsSynced: combinedSeen, totalCount: combinedTotal))
    }
}
