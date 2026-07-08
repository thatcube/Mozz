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

    /// Progress for one entity phase, so the UI can show a live per-type
    /// breakdown (Songs 3.7k/20k · Albums 1.2k/2.5k · …) — with every phase
    /// listed from the start (queued → syncing → done) rather than appearing only
    /// once it begins.
    public struct PhaseDetail: Sendable, Hashable, Identifiable {
        public enum State: Sendable { case pending, syncing, done }
        public let phase: Phase
        public let synced: Int
        public let total: Int?
        public let state: State
        public var id: Phase { phase }
        public var isComplete: Bool { state == .done }

        public init(phase: Phase, synced: Int, total: Int?, state: State) {
            self.phase = phase
            self.synced = synced
            self.total = total
            self.state = state
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

/// Scopes a sync run. The default `.full` mirrors the entire library and prunes.
/// A bounded plan (`.quickStart`) syncs only the first few (newest) pages of
/// albums + tracks and skips pruning, so the app becomes browsable/playable on a
/// recent slice within a minute or two before the full sync runs in the
/// background — important on slow self-hosted servers where a full mirror can
/// take many minutes.
public struct SyncPlan: Sendable {
    /// Max pages per phase: `nil` = all pages, `0` = skip the phase entirely.
    public var maxArtistPages: Int?
    public var maxAlbumPages: Int?
    public var maxTrackPages: Int?
    public var includePlaylists: Bool
    /// Prune rows the server no longer has. Only safe on a full enumeration — a
    /// bounded plan MUST NOT prune (it hasn't seen the whole library).
    public var prune: Bool
    /// Page size override (nil = the engine's default). A bounded quick start uses
    /// a small page so its one request returns fast for an immediate first impression.
    public var pageSize: Int?

    public init(maxArtistPages: Int?, maxAlbumPages: Int?, maxTrackPages: Int?, includePlaylists: Bool, prune: Bool, pageSize: Int? = nil) {
        self.maxArtistPages = maxArtistPages
        self.maxAlbumPages = maxAlbumPages
        self.maxTrackPages = maxTrackPages
        self.includePlaylists = includePlaylists
        self.prune = prune
        self.pageSize = pageSize
    }

    public static let full = SyncPlan(
        maxArtistPages: nil, maxAlbumPages: nil, maxTrackPages: nil,
        includePlaylists: true, prune: true
    )

    /// A tiny, immediately-usable slice: the newest `tracks` in ONE small request
    /// (newest-first), no albums/artists/playlists, no prune.
    ///
    /// Sizing (from on-device probing of a real server): the `/Items` endpoint
    /// costs a FLAT ~40ms per returned row with essentially ZERO fixed per-query
    /// overhead, and that rate can't be improved by query params or concurrency —
    /// it's a hard server-side ceiling that drifts ~15-26 rows/s with load. So
    /// quick-start time ≈ tracks × ~40ms. 150 tracks lands in ~6s (fast) to ~10s
    /// (slow) — a reliably snappy first impression that's still plenty to browse
    /// and play. Albums/artists fill in via the background full sync that follows
    /// (empty album shells are hidden until their tracks arrive), and a track
    /// carries its own album art + title so "Recently Added" songs render.
    public static func quickStart(tracks: Int = 150) -> SyncPlan {
        SyncPlan(
            maxArtistPages: 0, maxAlbumPages: 0, maxTrackPages: 1,
            includePlaylists: false, prune: false, pageSize: tracks
        )
    }
}
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
    public func sync(plan: SyncPlan = .full, progress: (@Sendable (SyncProgress) -> Void)? = nil) async throws -> SyncSummary {
        let started = Date()

        try await writer.saveServer(backend.connection)
        progress?(SyncProgress(phase: .capabilities, itemsSynced: 0))
        let capabilities = try await backend.detectCapabilities()
        try await writer.saveCapabilities(capabilities, serverId: serverId)

        // The progress breakdown lists exactly the phases this plan will run.
        var plannedPhases: [SyncProgress.Phase] = []
        if plan.maxArtistPages != 0 { plannedPhases.append(.artists) }
        if plan.maxAlbumPages != 0 { plannedPhases.append(.albums) }
        if plan.maxTrackPages != 0 { plannedPhases.append(.tracks) }
        if plan.includePlaylists { plannedPhases.append(.playlists) }
        let aggregator = progress.map { ProgressAggregator(phases: plannedPhases, emit: $0) }
        let report: @Sendable (SyncProgress.Phase, Int, Int?) async -> Void = { phase, seen, total in
            await aggregator?.report(phase: phase, seen: seen, total: total)
        }
        // Mark a phase done (drives the breakdown's queued→syncing→done state;
        // called even for 0-item phases so they don't look stuck "queued").
        let complete: @Sendable (PagedEnumeration) async -> Void = { e in
            await aggregator?.complete(phase: e.phase, finalCount: e.seen.count)
        }

        // Artists (light, dedicated endpoint) and playlists (few) run
        // concurrently, but the two HEAVY /Items phases — albums and tracks —
        // run SEQUENTIALLY. Measured: this self-hosted server serves a heavy
        // /Items page in ~60s and does NOT parallelize them; running albums and
        // tracks at once just starved the tracks request past its timeout
        // (serverUnreachable) and aborted the whole sync. One heavy stream at a
        // time keeps every request served promptly and well within the timeout.
        // A bounded plan (quick start) may skip artists/playlists entirely.
        async let artistsTask = syncPages(
            phase: .artists, maxPages: plan.maxArtistPages,
            fetch: { try await backend.fetchArtists(offset: $0, limit: $1) },
            write: { try await writer.upsertArtists($0, serverId: serverId) },
            id: \.id,
            report: report
        )
        async let playlistsTask = plan.includePlaylists
            ? syncPlaylists(report: report)
            : PagedEnumeration(seen: [], reportedTotal: nil, phase: .playlists, elapsed: 0)

        let artistIDs: PagedEnumeration
        let albumIDs: PagedEnumeration
        let trackIDs: PagedEnumeration
        let playlistIDs: PagedEnumeration
        do {
            albumIDs = try await syncPages(
                phase: .albums, maxPages: plan.maxAlbumPages,
                fetch: { try await backend.fetchAlbums(offset: $0, limit: $1) },
                write: { try await writer.upsertAlbums($0, serverId: serverId) },
                id: \.id,
                report: report
            )
            await complete(albumIDs)
            trackIDs = try await syncTracksStream(maxPages: plan.maxTrackPages, report: report)
            await complete(trackIDs)
            artistIDs = try await artistsTask
            await complete(artistIDs)
            playlistIDs = try await playlistsTask
            await complete(playlistIDs)
        } catch {
            diag?("SYNC ERROR: \(error)")
            throw error
        }

        // Some album-artists (DJs, producers, combined credits) are referenced by
        // albums but never returned by the artist listing, leaving their albums
        // unbrowsable. Derive artist rows for them from the just-synced albums —
        // no network. The artist prune keeps anything a surviving album still
        // references (see CatalogWriter.pruneArtists), so these survive future
        // syncs without needing to thread their ids through the keep-set here.
        _ = try await writer.synthesizeMissingAlbumArtists(serverId: serverId)

        // Derive album track counts locally (the album fetch no longer asks the
        // server for the expensive per-album ChildCount). Cheap local pass.
        try await writer.deriveAlbumTrackCounts(serverId: serverId)

        // Prune rows the server no longer has — but ONLY on a full plan where
        // EVERY phase enumerated completely (all-or-nothing). A bounded/quick-start
        // plan never prunes (it deliberately saw only a slice). A truncated/flaky
        // full sync must never prune either: the `download` row cascade-deletes
        // from `track`, so a single bad sync could otherwise wipe the catalog AND
        // the user's offline downloads (and orphan the files on disk).
        progress?(SyncProgress(phase: .pruning, itemsSynced: 0))
        var deleted = 0
        let allPhasesComplete = [artistIDs, albumIDs, trackIDs, playlistIDs].allSatisfy(phaseCompleted)
        if plan.prune && allPhasesComplete {
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
    /// (all-or-nothing) prune. Completeness requires the server (or the
    /// backend's enumerator) to have reported a total AND for `seen` to cover
    /// at least that many DISTINCT items. If NO total was reported the phase
    /// is treated as unverifiable — prune is skipped. This is stricter than
    /// the previous "non-empty seen ⇒ complete" fallback, which was safe in
    /// practice for Plex/Jellyfin (both always populate `totalCount`) but
    /// would authorize an unsafe prune for a Subsonic backend that couldn't
    /// derive an expected total.
    ///
    /// DISTINCT is essential: pages can legitimately overlap (e.g. an item
    /// added server-side mid-sync shifts the window), so counting raw rows
    /// could reach `total` while real ids were never seen — which would
    /// authorize a prune that deletes those missed-but-still-present tracks.
    /// Comparing unique ids makes completeness a true coverage guarantee
    /// regardless of page ordering.
    private func phaseCompleted(_ enumeration: PagedEnumeration) -> Bool {
        // A `nil` reported total means the backend couldn't derive one — the
        // phase is unverifiable, so we refuse to authorise the destructive
        // prune (encodes "if not provable, DO NOT prune"). A zero total is
        // a legitimate "library is empty for this entity type" completion.
        guard let total = enumeration.reportedTotal else { return false }
        return Set(enumeration.seen).count >= total
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
        maxPages: Int? = nil,
        fetch: @Sendable @escaping (Int, Int) async throws -> CatalogPage<Item>,
        write: @Sendable ([Item]) async throws -> Void,
        id: @Sendable (Item) -> String,
        report: @Sendable (SyncProgress.Phase, Int, Int?) async -> Void
    ) async throws -> PagedEnumeration {
        // maxPages == 0 → phase skipped entirely (bounded plan).
        if maxPages == 0 {
            return PagedEnumeration(seen: [], reportedTotal: nil, phase: phase, elapsed: 0)
        }
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
        var pageNo = 0
        diag?("\(phase.rawValue): phase start")
        // Prefetch the next page while writing the current one. Awaiting the
        // detached task via `withTaskCancellationHandler` (rather than a bare
        // `await pending.value`, which is NOT a cancellation point and doesn't
        // inherit parent cancellation) ensures that if the sync is cancelled — or
        // the app is backgrounded and a request freezes — the in-flight fetch is
        // actually torn down instead of hanging silently until the ~1200s
        // resource timeout. So a stalled page surfaces promptly as an error.
        var pending = Task { try await fetch(0, pageSize) }
        func awaitPage(_ task: Task<CatalogPage<Item>, Error>) async throws -> CatalogPage<Item> {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
        do {
            while true {
                try Task.checkCancellation()
                let waitStart = Date()
                let page = try await awaitPage(pending)
                let waited = Date().timeIntervalSince(waitStart)
                fetchWait += waited
                if let total = page.totalCount { reportedTotal = max(reportedTotal ?? 0, total) }
                diag?("\(phase.rawValue): page \(pageNo) off=\(offset) got=\(page.items.count) total=\(reportedTotal.map(String.init) ?? "?") fetch=\(String(format: "%.1f", waited))s")
                pageNo += 1
                if page.items.isEmpty { break }
                // Bounded plan (quick start): stop after `maxPages`. Don't prefetch
                // beyond the limit. The phase is intentionally incomplete, so the
                // prune guard (phaseCompleted) will correctly refuse to prune.
                let reachedLimit = maxPages.map { pageNo >= $0 } ?? false
                let nextOffset = offset + page.items.count
                if !reachedLimit {
                    pending = Task { try await fetch(nextOffset, pageSize) }
                }
                let writeStart = Date()
                try await write(page.items)
                writeTime += Date().timeIntervalSince(writeStart)
                seen.append(contentsOf: page.items.map(id))
                await report(phase, seen.count, reportedTotal)
                offset = nextOffset
                if reachedLimit { break }
            }
        } catch {
            pending.cancel()
            diag?("\(phase.rawValue): ERROR after \(seen.count) items: \(error)")
            throw error
        }
        pending.cancel()
        let elapsed = Date().timeIntervalSince(started)
        let rate = elapsed > 0 ? Double(seen.count) / elapsed : 0
        syncLog.notice("phase \(phase.rawValue, privacy: .public): \(seen.count) items in \(String(format: "%.1f", elapsed))s (\(String(format: "%.0f", rate))/s)")
        diag?("\(phase.rawValue): \(seen.count) items in \(String(format: "%.1f", elapsed))s (\(Int(rate.rounded()))/s) — fetch-wait \(String(format: "%.1f", fetchWait))s, write \(String(format: "%.1f", writeTime))s")
        return PagedEnumeration(seen: seen, reportedTotal: reportedTotal, phase: phase, elapsed: elapsed)
    }

    /// Enumerate tracks via the backend's ``MusicBackend/enumerateAllTracks(pageSize:)``
    /// stream. This is the plug point for backends whose flat offset/limit pager
    /// is unstable under mutation (Subsonic's `search3` empty-query paging) — the
    /// Subsonic override walks `getAlbumList2` → `getAlbum(id)` for a stable
    /// order and, crucially, a *derivable* running total (sum of album
    /// `songCount`s) that the prune-completeness guard can trust.
    ///
    /// Plex/Jellyfin get the default protocol implementation, which just wraps
    /// their existing `fetchTracks(offset:limit:)` pager — so their behavior is
    /// unchanged. `maxPages` from a quick-start plan still applies: we take the
    /// first N pages then stop, and the prune guard correctly refuses to prune.
    private func syncTracksStream(
        maxPages: Int?,
        report: @Sendable (SyncProgress.Phase, Int, Int?) async -> Void
    ) async throws -> PagedEnumeration {
        if maxPages == 0 {
            return PagedEnumeration(seen: [], reportedTotal: nil, phase: .tracks, elapsed: 0)
        }
        let started = Date()
        var seen: [String] = []
        // Dedupe across pages: the album-walk enumerator can legitimately re-emit
        // a track that appears on multiple albums / compilations, and the sync
        // must count each remoteId once for the prune-completeness check.
        var seenSet = Set<String>()
        var reportedTotal: Int?
        var pageNo = 0
        diag?("tracks: phase start (stream)")
        let stream = backend.enumerateAllTracks(pageSize: pageSize)
        do {
            for try await page in stream {
                try Task.checkCancellation()
                if let total = page.totalCount {
                    reportedTotal = max(reportedTotal ?? 0, total)
                }
                if !page.items.isEmpty {
                    try await writer.upsertTracks(page.items, serverId: serverId)
                    for track in page.items where seenSet.insert(track.id).inserted {
                        seen.append(track.id)
                    }
                    await report(.tracks, seen.count, reportedTotal)
                }
                pageNo += 1
                diag?("tracks: page \(pageNo) got=\(page.items.count) seen=\(seen.count) total=\(reportedTotal.map(String.init) ?? "?")")
                if let maxPages, pageNo >= maxPages { break }
            }
        } catch {
            diag?("tracks: ERROR after \(seen.count) items: \(error)")
            throw error
        }
        let elapsed = Date().timeIntervalSince(started)
        let rate = elapsed > 0 ? Double(seen.count) / elapsed : 0
        syncLog.notice("phase tracks: \(seen.count) items in \(String(format: "%.1f", elapsed))s (\(String(format: "%.0f", rate))/s)")
        return PagedEnumeration(seen: seen, reportedTotal: reportedTotal, phase: .tracks, elapsed: elapsed)
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

/// Merges progress from the entity phases into one combined `SyncProgress`
/// (phase `.syncing`): the sum of items seen, a determinate overall total once
/// the three main phases (artists/albums/tracks) report their server totals, and
/// a per-phase breakdown that lists EVERY phase from the start — queued →
/// syncing → done — so the user always sees Artists/Albums/Songs/Playlists
/// rather than a phase only appearing once it begins.
private actor ProgressAggregator {
    /// Fixed display order for the breakdown.
    private let order: [SyncProgress.Phase]
    private let mainPhases: Set<SyncProgress.Phase>
    private let emit: @Sendable (SyncProgress) -> Void
    private var seen: [SyncProgress.Phase: Int] = [:]
    private var totals: [SyncProgress.Phase: Int] = [:]
    private var completed: Set<SyncProgress.Phase> = []

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
        publish()
    }

    /// A phase finished (call even for a 0-item phase so it shows as done, not
    /// stuck "queued").
    func complete(phase: SyncProgress.Phase, finalCount: Int) {
        seen[phase] = finalCount
        completed.insert(phase)
        publish()
    }

    private func publish() {
        let details = order.map { p -> SyncProgress.PhaseDetail in
            let state: SyncProgress.PhaseDetail.State =
                completed.contains(p) ? .done
                : (seen[p] != nil || totals[p] != nil) ? .syncing
                : .pending
            return SyncProgress.PhaseDetail(phase: p, synced: seen[p] ?? 0, total: totals[p], state: state)
        }
        let combinedSeen = seen.values.reduce(0, +)
        // Determinate total once the main phases have theirs (playlists can lag);
        // include any other known totals so the number is as complete as possible.
        let mainKnown = mainPhases.isSubset(of: Set(totals.keys))
        let combinedTotal = mainKnown ? totals.values.reduce(0, +) : nil
        emit(SyncProgress(phase: .syncing, itemsSynced: combinedSeen, totalCount: combinedTotal, details: details))
    }
}
