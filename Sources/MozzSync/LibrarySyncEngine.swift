import Foundation
import MozzCore
import MozzDatabase
import os

private let syncLog = Logger(subsystem: "com.thatcube.Mozz", category: "sync")

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

        /// Short, user-facing label.
        public var label: String {
            switch self {
            case .capabilities: return "Connecting"
            case .syncing:      return "Syncing"
            case .artists:      return "Artists"
            case .albums:       return "Albums"
            case .tracks:       return "Songs"
            case .playlists:    return "Playlists"
            case .pruning:      return "Finishing up"
            case .done:         return "Done"
            }
        }
    }

    /// Progress for one concurrently-running entity phase, so the UI can show a
    /// live per-type breakdown (Songs 3.7k/20k · Albums 1.2k/2.5k · …) instead of
    /// one opaque total that appears to jump and stall.
    public struct PhaseDetail: Sendable, Hashable, Identifiable {
        public let phase: Phase
        public let synced: Int
        public let total: Int?
        public var id: Phase { phase }
        public var isComplete: Bool { total.map { synced >= $0 } ?? false }

        public init(phase: Phase, synced: Int, total: Int?) {
            self.phase = phase
            self.synced = synced
            self.total = total
        }
    }

    public var phase: Phase
    public var itemsSynced: Int
    public var totalCount: Int?
    /// Per-phase breakdown during the concurrent `.syncing` phase (empty otherwise).
    public var details: [PhaseDetail]

    public init(phase: Phase, itemsSynced: Int, totalCount: Int? = nil, details: [PhaseDetail] = []) {
        self.phase = phase
        self.itemsSynced = itemsSynced
        self.totalCount = totalCount
        self.details = details
    }
}

/// What a completed sync wrote.
public struct SyncSummary: Sendable, Hashable {
    /// Timing for one phase, for the Diagnostics "last sync" report.
    public struct PhaseTiming: Sendable, Hashable {
        public let phase: SyncProgress.Phase
        public let items: Int
        public let seconds: TimeInterval
        public var rate: Double { seconds > 0 ? Double(items) / seconds : 0 }
        public init(phase: SyncProgress.Phase, items: Int, seconds: TimeInterval) {
            self.phase = phase
            self.items = items
            self.seconds = seconds
        }
    }

    public var artists: Int
    public var albums: Int
    public var tracks: Int
    public var playlists: Int
    public var deleted: Int
    public var duration: TimeInterval
    public var phaseTimings: [PhaseTiming]

    public init(artists: Int = 0, albums: Int = 0, tracks: Int = 0, playlists: Int = 0, deleted: Int = 0, duration: TimeInterval = 0, phaseTimings: [PhaseTiming] = []) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
        self.playlists = playlists
        self.deleted = deleted
        self.duration = duration
        self.phaseTimings = phaseTimings
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
    /// Optional diagnostic sink for detailed per-page timing (fetch vs write),
    /// written to a file the debugger pulls off-device. `nil` in tests/normal use.
    private let diag: (@Sendable (String) -> Void)?

    private var serverId: ServerID { backend.connection.id }

    public init(
        backend: any MusicBackend,
        database: MusicDatabase,
        pageSize: Int = 500,
        diag: (@Sendable (String) -> Void)? = nil
    ) {
        self.backend = backend
        self.writer = CatalogWriter(database)
        self.pageSize = pageSize
        self.diag = diag
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
        let timings = [artistIDs, albumIDs, trackIDs, playlistIDs].map {
            SyncSummary.PhaseTiming(phase: $0.phase, items: $0.seen.count, seconds: $0.elapsed)
        }
        let summary = SyncSummary(
            artists: artistTotal,
            albums: albumIDs.seen.count,
            tracks: trackIDs.seen.count,
            playlists: playlistIDs.seen.count,
            deleted: deleted,
            duration: Date().timeIntervalSince(started),
            phaseTimings: timings
        )
        progress?(SyncProgress(phase: .done, itemsSynced: summary.tracks, totalCount: summary.tracks))
        syncLog.notice("sync complete: \(summary.tracks) tracks, \(summary.albums) albums, \(summary.artists) artists, \(summary.playlists) playlists, \(summary.deleted) pruned in \(String(format: "%.1f", summary.duration))s")
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
        var phase: SyncProgress.Phase = .syncing
        var elapsed: TimeInterval = 0
    }

    /// Page one entity type to exhaustion, writing each batch and collecting the
    /// remote ids seen (for pruning). Terminates ONLY on a genuinely empty page.
    /// A short page (fewer than `pageSize`) is *not* treated as terminal: some
    /// servers legitimately return short pages mid-enumeration, and assuming
    /// "short == done" would truncate the sync and then prune everything the
    /// truncated run never saw.
    ///
    /// The next page is prefetched WHILE the current one is being written, so a
    /// slow page fetch overlaps the DB write instead of alternating with it. This
    /// matters most for the long-pole tracks phase, which runs alone (a serial
    /// fetch→write loop) once the smaller phases finish — on a slow server the
    /// fetch dominates, so overlapping it with the write ~doubles the tail's
    /// throughput. Only one page is buffered ahead, so peak memory is bounded.
    private func syncPages<Item: Sendable>(
        phase: SyncProgress.Phase,
        fetch: @Sendable @escaping (Int, Int) async throws -> CatalogPage<Item>,
        write: @Sendable ([Item]) async throws -> Void,
        id: @Sendable (Item) -> String,
        report: @Sendable (SyncProgress.Phase, Int, Int?) async -> Void
    ) async throws -> PagedEnumeration {
        let started = Date()
        let pageSize = self.pageSize
        var offset = 0
        var seen: [String] = []
        var reportedTotal: Int?
        // Because the next page is prefetched while the current one is written,
        // the time spent *awaiting* the prefetch vs. the time spent writing is a
        // clean bottleneck signal: near-zero fetch-wait ⇒ write-bound; large
        // fetch-wait ⇒ network/server-bound.
        var fetchWait: TimeInterval = 0
        var writeTime: TimeInterval = 0
        var pending = Task { try await fetch(0, pageSize) }
        do {
            while true {
                try Task.checkCancellation()
                let waitStart = Date()
                let page = try await pending.value
                fetchWait += Date().timeIntervalSince(waitStart)
                if let total = page.totalCount { reportedTotal = max(reportedTotal ?? 0, total) }
                if page.items.isEmpty { break }
                let nextOffset = offset + page.items.count
                pending = Task { try await fetch(nextOffset, pageSize) }
                let writeStart = Date()
                try await write(page.items)
                writeTime += Date().timeIntervalSince(writeStart)
                seen.append(contentsOf: page.items.map(id))
                await report(phase, seen.count, reportedTotal)
                offset = nextOffset
            }
        } catch {
            pending.cancel()
            throw error
        }
        pending.cancel()
        let elapsed = Date().timeIntervalSince(started)
        let rate = elapsed > 0 ? Double(seen.count) / elapsed : 0
        syncLog.notice("phase \(phase.rawValue, privacy: .public): \(seen.count) items in \(String(format: "%.1f", elapsed))s (\(String(format: "%.0f", rate))/s)")
        diag?("\(phase.rawValue): \(seen.count) items in \(String(format: "%.1f", elapsed))s (\(Int(rate.rounded()))/s) — fetch-wait \(String(format: "%.1f", fetchWait))s, write \(String(format: "%.1f", writeTime))s")
        return PagedEnumeration(seen: seen, reportedTotal: reportedTotal, phase: phase, elapsed: elapsed)
    }

    /// Playlists need a second pass to sync their ordered items.
    private func syncPlaylists(report: @Sendable (SyncProgress.Phase, Int, Int?) async -> Void) async throws -> PagedEnumeration {
        let started = Date()
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
        let elapsed = Date().timeIntervalSince(started)
        syncLog.notice("phase playlists: \(playlists.count) items in \(String(format: "%.1f", elapsed))s")
        return PagedEnumeration(seen: playlists.map(\.id), reportedTotal: reportedTotal, phase: .playlists, elapsed: elapsed)
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
/// `SyncProgress` (phase `.syncing`): the sum of items seen across phases, a live
/// per-phase breakdown, and a determinate total as soon as the three main phases
/// (artists/albums/tracks) have reported their server totals — so the bar shows a
/// spinner + live counts first, then a smooth determinate bar, and never a total
/// that lurches as each phase's count arrives.
private actor ProgressAggregator {
    /// Fixed display order for the breakdown.
    private let order: [SyncProgress.Phase]
    private let mainPhases: Set<SyncProgress.Phase>
    private let emit: @Sendable (SyncProgress) -> Void
    private var seen: [SyncProgress.Phase: Int] = [:]
    private var totals: [SyncProgress.Phase: Int] = [:]

    init(phases: [SyncProgress.Phase], emit: @escaping @Sendable (SyncProgress) -> Void) {
        self.order = phases
        // The big phases whose totals gate a trustworthy overall percentage.
        let main: Set<SyncProgress.Phase> = [.artists, .albums, .tracks]
        self.mainPhases = main.intersection(Set(phases))
        self.emit = emit
    }

    func report(phase: SyncProgress.Phase, seen count: Int, total: Int?) {
        seen[phase] = count
        if let total { totals[phase] = max(totals[phase] ?? 0, total) }

        let details = order.compactMap { p -> SyncProgress.PhaseDetail? in
            // Only surface a phase once it has started (reported a count or total).
            guard seen[p] != nil || totals[p] != nil else { return nil }
            return SyncProgress.PhaseDetail(phase: p, synced: seen[p] ?? 0, total: totals[p])
        }
        let combinedSeen = seen.values.reduce(0, +)
        // Show a determinate total once the main phases have theirs (playlists can
        // lag); include any other known totals so the number is as complete as
        // possible without waiting on a slow tail.
        let mainKnown = mainPhases.isSubset(of: Set(totals.keys))
        let combinedTotal = mainKnown ? totals.values.reduce(0, +) : nil
        emit(SyncProgress(phase: .syncing, itemsSynced: combinedSeen, totalCount: combinedTotal, details: details))
    }
}
