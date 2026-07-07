import Foundation
import Combine
import MozzCore
import MozzDatabase
import MozzDownloads
import MozzPlayback
import MozzNetworking
import MozzRecommend
import MozzEnrichment
import MozzSync
import MozzPlex
import MozzJellyfin
#if canImport(WidgetKit)
import WidgetKit
#endif

/// A resolver whose delegate can be swapped at runtime. The ``PlaybackEngine``
/// is created once at launch, but the active server (and therefore the offline/
/// streaming resolver) only becomes known after sign-in — so the engine holds
/// this box and we point it at the real resolver on activation.
public final class SwappableResolver: TrackURLResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var delegate: (any TrackURLResolver)?

    public init() {}

    public func setDelegate(_ resolver: any TrackURLResolver) {
        lock.lock(); delegate = resolver; lock.unlock()
    }

    private func currentDelegate() -> (any TrackURLResolver)? {
        lock.lock(); defer { lock.unlock() }
        return delegate
    }

    public func resolve(_ track: Track) async throws -> ResolvedTrackURL {
        guard let current = currentDelegate() else { throw MozzError.unsupported("No active server") }
        return try await current.resolve(track)
    }
}

/// The active server plus everything derived from it.
public struct ActiveServer: Sendable {
    public var connection: ServerConnection
    public var backend: any MusicBackend
    public var capabilities: ServerCapabilities
}

/// A Plex server the account can reach, for the server picker.
public struct PlexServerOption: Identifiable, Sendable, Hashable {
    public let id: String   // Plex machine identifier
    public let name: String
    public let isCurrent: Bool
}

/// A music library on the active Plex server, for the library picker.
public struct PlexMusicLibraryOption: Identifiable, Sendable, Hashable {
    public let id: String   // section key
    public let title: String
    public let isSelected: Bool
}

/// The composition root. Owns the long-lived services (database, repository,
/// download manager, playback engine, credential store) and knows how to build
/// a backend from a stored or freshly-authenticated session. Created once and
/// injected into the SwiftUI environment.
@MainActor
public final class AppEnvironment: ObservableObject {
    public let database: MusicDatabase
    public let repository: LibraryRepository
    public let fileStore: DownloadFileStore
    public let downloads: DownloadManager
    public let playback: PlaybackEngine
    public let playEvents: PlayEventStore
    /// On-device recommendation engine ("Mozz Weekly"); computes + persists sets
    /// off-main so the Home shelf reads instantly and offline.
    public let recommendations: RecommendationService
    /// Open metadata enrichment (MusicBrainz IDs → later ListenBrainz similarity).
    /// On by default with a Settings off-switch; resolves MBIDs off-main and
    /// rate-limited, never blocking sync or the UI (ADR-0007).
    public let enrichment: EnrichmentService
    /// UserDefaults key for the enrichment on/off switch (default on when unset).
    public static let enrichmentEnabledKey = "mozz.enrichmentEnabled"
    /// Offline-first like/rating writes (local DB + queued server write-back).
    public let favorites: FavoritesStore
    public let credentials: any CredentialStore
    public let clientInfo: ClientInfo
    public let clientIdentifier: String

    private let resolver = SwappableResolver()

    /// The active server, or `nil` when the user needs to sign in.
    @Published public private(set) var active: ActiveServer?
    /// Whether we're still restoring a saved session at launch.
    @Published public private(set) var isRestoring = true
    @Published public private(set) var lastSyncSummary: String?

    /// A deep-link / Handoff destination waiting to be navigated to. Set by
    /// `onOpenURL` / `onContinueUserActivity`; consumed by `MainTabsView` once it
    /// is on screen (a link may arrive during launch/onboarding, before the tab
    /// UI exists, so it must be queued rather than applied immediately).
    @Published var pendingDeepLink: DeepLinkTarget?

    /// Whether a catalog sync is currently running, and its latest progress.
    /// Owned by the environment (not a view) so a sync survives navigating away
    /// from Settings / refreshing Home, and every view reflects the true state.
    @Published public private(set) var isSyncing = false
    @Published public private(set) var syncProgress: SyncProgress?
    private var syncTask: Task<Void, Never>?

    /// A short human status for the sync UI, or `nil` when idle.
    public var syncStatusText: String? {
        guard isSyncing else { return nil }
        guard let p = syncProgress else { return "Starting…" }
        return "\(p.phase.rawValue): \(p.itemsSynced)"
    }

    /// Single-flight guard for the favorite/rating outbox flush (see
    /// `flushFavoriteOutbox`). Main-actor state, so checked/set without races.
    private var isFlushingOutbox = false
    private var flushRequestedAgain = false

    /// Combine subscriptions that keep the Home/Lock Screen widget snapshots in
    /// sync with playback.
    private var widgetCancellables = Set<AnyCancellable>()

    /// Muted background colour ("#RRGGBB") derived from each track's artwork, for
    /// the widgets. Keyed by track id; bounded by the widget artwork pruning.
    private var widgetTintByTrack: [String: String] = [:]

    public init(database: MusicDatabase, credentials: any CredentialStore, fileStore: DownloadFileStore) {
        self.database = database
        self.credentials = credentials
        self.fileStore = fileStore
        self.repository = LibraryRepository(database)
        self.downloads = DownloadManager(database: database, fileStore: fileStore)
        self.playback = PlaybackEngine(resolver: resolver)
        self.playEvents = PlayEventStore(database)
        self.recommendations = RecommendationService(store: RecommendationStore(database))
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        let enrichmentConfig = EnrichmentConfig(
            userAgent: "Mozz/\(appVersion) ( https://github.com/thatcube/Mozz )")
        // One shared limiter/client so every MusicBrainz call across the app
        // (background pass + on-demand seed resolution) honors one 1 req/s budget.
        let mbLimiter = AsyncRateLimiter(minInterval: enrichmentConfig.minRequestInterval)
        self.enrichment = EnrichmentService(
            store: EnrichmentStore(database),
            musicBrainz: MusicBrainzClient.make(config: enrichmentConfig, limiter: mbLimiter),
            config: enrichmentConfig,
            isEnabled: {
                UserDefaults.standard.object(forKey: AppEnvironment.enrichmentEnabledKey) as? Bool ?? true
            })
        self.favorites = FavoritesStore(database)
        self.clientIdentifier = Self.stableClientIdentifier(credentials)
        self.clientInfo = ClientInfo(
            product: "Mozz", version: "0.1.0",
            deviceName: "iPhone", platform: "iOS", platformVersion: "17.0"
        )
        wirePlaybackReporting()
        wirePlayEventLogging()
        wireBackgroundDownloads()
        wireNowPlayingArtwork()
        wireNowPlayingWidget()
    }

    /// The default on-disk environment (App Support DB + downloads dir + Keychain).
    public static func makeDefault() throws -> AppEnvironment {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dbURL = support.appendingPathComponent("mozz.sqlite")
        let database = try MusicDatabase.open(at: dbURL)
        let fileStore = try DownloadFileStore(root: try DownloadFileStore.defaultRoot())
        let credentials = KeychainCredentialStore()
        return AppEnvironment(database: database, credentials: credentials, fileStore: fileStore)
    }

    /// A last-resort environment (used only if the on-disk store can't open) so
    /// the app still launches into onboarding.
    public static func makeInMemoryFallback() -> AppEnvironment {
        // Force-try is acceptable here: an in-memory SQLite DB and a temp
        // downloads dir cannot realistically fail, and this is the fallback of
        // last resort when the on-disk store is unavailable.
        let database = try! MusicDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MozzDownloads-fallback")
        let fileStore = try! DownloadFileStore(root: root)
        return AppEnvironment(database: database, credentials: InMemoryCredentialStore(), fileStore: fileStore)
    }

    // MARK: Session lifecycle

    public func restoreSession() async {
        defer { isRestoring = false }
        guard let saved = SessionPersistence.load(credentials) else { return }
        do {
            try await activate(saved)
            restoreLastPlaybackSession()
        } catch {
            SessionPersistence.clear(credentials)
        }
    }

    /// Activate a freshly-authenticated Plex/Jellyfin session.
    public func activate(session: AuthenticatedSession) async throws {
        let stored = StoredSession(
            kind: session.kind, baseURL: session.baseURL, token: session.token,
            userID: session.userID, serverName: session.serverName,
            clientIdentifier: session.clientIdentifier, musicSectionID: nil,
            accountToken: session.accountToken, selectedMusicSectionIDs: nil
        )
        // Persist BEFORE activation so buildBackend's Plex section resolution can
        // load this session, add the resolved section id and save it back (it
        // would otherwise be a no-op on first sign-in — nothing to load — and the
        // section would be re-resolved every launch). Do NOT re-save `stored`
        // afterwards: that clobbered the resolved section back to nil.
        SessionPersistence.save(stored, to: credentials)
        try await activate(stored)
    }

    /// Activate the offline demo: generate a synthetic catalog and serve a
    /// full-length tone per track so playback/scrub/downloads behave like real
    /// multi-minute audio with no server.
    public func activateDemo(size: SyntheticCatalog.Size = .init(artists: 200, albums: 2_000, tracks: 20_000)) async throws {
        let serverId = "demo"
        let backend = DemoBackend(serverId: serverId, clipProvider: Self.makeDemoClipProvider())
        let existing = try await repository.trackCount(serverId: serverId)
        if existing == 0 {
            try await SyntheticCatalog(database).generate(serverId: serverId, size: size)
        }
        let capabilities = try await backend.detectCapabilities()
        try await CatalogWriter(database).saveCapabilities(capabilities, serverId: serverId)
        finishActivation(connection: backend.connection, backend: backend, capabilities: capabilities)

        let stored = StoredSession(
            kind: .jellyfin, baseURL: backend.connection.baseURL, token: "demo",
            userID: "demo", serverName: "Demo Library",
            clientIdentifier: "demo-client", musicSectionID: nil, isDemo: true
        )
        SessionPersistence.save(stored, to: credentials)
    }

    private func activate(_ stored: StoredSession) async throws {
        if stored.isDemo {
            try await activateDemo()
            return
        }
        let (connection, backend) = try await buildBackend(from: stored)
        try await CatalogWriter(database).saveServer(connection)

        // Prefer live detection; if the server is unreachable (offline launch),
        // keep the last-known capabilities rather than clobbering them with
        // generic defaults. Only persist detected/fallback values (never re-save
        // the cached row). See CapabilityResolver.
        let detected = try? await backend.detectCapabilities()
        let cached = try? await repository.capabilities(serverId: connection.id)
        let resolved = CapabilityResolver.resolve(detected: detected, cached: cached, backend: stored.kind)
        if resolved.shouldPersist {
            try await CatalogWriter(database).saveCapabilities(resolved.capabilities, serverId: connection.id)
        }
        finishActivation(connection: connection, backend: backend, capabilities: resolved.capabilities)
    }

    private func finishActivation(connection: ServerConnection, backend: any MusicBackend, capabilities: ServerCapabilities) {
        let offline = OfflineTrackURLResolver(
            serverId: connection.id,
            repository: repository,
            fileStore: fileStore,
            fallback: StreamingTrackURLResolver(backend: backend)
        )
        resolver.setDelegate(offline)
        // End any station only on an actual server SWITCH — not on same-server
        // rebuilds (Sync Now / library-selection changes also route through here),
        // which must not kill a live station's auto-extend. `active` still holds
        // the previous server at this point.
        if connection.id != active?.connection.id {
            invalidateRadio()
            // A different server has a different catalog — abandon any in-flight
            // enrichment crawl scoped to the previous server.
            let enrichment = self.enrichment
            Task { await enrichment.cancel() }
        }
        active = ActiveServer(connection: connection, backend: backend, capabilities: capabilities)
    }

    public func signOut() {
        playback.stop()
        invalidateRadio()
        let enrichment = self.enrichment
        Task { await enrichment.cancel() }
        SessionPersistence.clear(credentials)
        active = nil
    }

    /// Launch-time automation for headless verification in the simulator (the
    /// accessibility bridge is unavailable in this toolchain). Gated entirely on
    /// environment variables, so it is inert in normal use.
    ///   MOZZ_AUTODEMO=1  → activate the offline demo with a small catalog.
    ///   MOZZ_AUTOPLAY=1  → start playing the first album after activation.
    public func runLaunchAutomationIfNeeded() async {
        let env = ProcessInfo.processInfo.environment
        if env["MOZZ_BENCH"] == "1" {
            await runBenchmark()
            return
        }
        guard env["MOZZ_AUTODEMO"] == "1" else { return }
        if active == nil {
            try? await activateDemo(size: .init(artists: 50, albums: 300, tracks: 3_000))
        }
        if env["MOZZ_AUTOPLAY"] == "1", let serverId = active?.connection.id {
            let albums = (try? await repository.albumsPage(serverId: serverId, offset: 0, limit: 1)) ?? []
            if let album = albums.first {
                let tracks = (try? await repository.tracks(forAlbumRemoteId: album.remoteId, serverId: serverId)) ?? []
                if !tracks.isEmpty { playback.play(tracks: tracks.map { $0.toDomain() }) }
            }
        }
    }

    /// Full performance run on-device: generate the 100k-track catalog, measure
    /// the read path, and time first audio. Results print with a `MOZZ_BENCH`
    /// marker so they can be captured from the simulator console for
    /// ARCHITECTURE.md. Triggered by `MOZZ_BENCH=1`.
    private func runBenchmark() async {
        let serverId = "demo"
        // Honest generation timing: only counts when the catalog is generated
        // (fresh install). On a warm container this is nil and we skip it.
        let existing = (try? await repository.trackCount(serverId: serverId)) ?? 0
        let genStart = Date()
        try? await activateDemo(size: .large)
        let generationSeconds: Double? = existing == 0 ? Date().timeIntervalSince(genStart) : nil

        guard active?.connection.id != nil else {
            print("MOZZ_BENCH_RESULT\nno active server"); return
        }

        // True cold-open: open a *fresh* pool on the same on-disk file and time
        // the first count query — the real "launch and read" cost on device.
        var coldOpenMs: Double?
        if let dbURL = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("mozz.sqlite"),
           let coldDB = try? MusicDatabase.open(at: dbURL) {
            let coldRepo = LibraryRepository(coldDB)
            let coldStart = Date()
            _ = try? await coldRepo.trackCount(serverId: serverId)
            coldOpenMs = Date().timeIntervalSince(coldStart) * 1000
        }

        let harness = PerformanceHarness(database)
        let metrics = try? await harness.measureReads(
            serverId: serverId, iterations: 5,
            generationSeconds: generationSeconds, coldOpenMs: coldOpenMs
        )

        var ttfaMs: Double?
        if let album = try? await repository.albumsPage(serverId: serverId, offset: 0, limit: 1).first {
            let tracks = (try? await repository.tracks(forAlbumRemoteId: album.remoteId, serverId: serverId)) ?? []
            if !tracks.isEmpty {
                let start = Date()
                playback.play(tracks: tracks.map { $0.toDomain() })
                ttfaMs = await waitUntilPlaying(startedAt: start, timeout: 8)
            }
        }

        var out = metrics?.summary ?? "no metrics"
        if let ttfaMs {
            out += String(format: "\ntime-to-first-audio (local file): %.1f ms", ttfaMs)
        } else {
            out += "\ntime-to-first-audio: (did not reach playing)"
        }
        print("MOZZ_BENCH_RESULT\n\(out)\nMOZZ_BENCH_END")
        // Also persist to a file — simulator stdout capture is unreliable in
        // this toolchain, so ARCHITECTURE.md numbers are read back from here.
        if let caches = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("mozz_bench.txt") {
            try? out.write(to: caches, atomically: true, encoding: .utf8)
        }
    }

    private func waitUntilPlaying(startedAt: Date, timeout: TimeInterval) async -> Double? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if playback.snapshot.status == .playing {
                return Date().timeIntervalSince(startedAt) * 1000
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    // MARK: Sync

    /// Start a catalog sync owned by the environment (not a view), so it keeps
    /// running when the user leaves Settings or refreshes Home, and its progress
    /// is reflected everywhere via `isSyncing`/`syncProgress`. Single-flight: a
    /// second tap while syncing is a no-op.
    public func startSync() {
        guard !isSyncing, active != nil else { return }
        isSyncing = true
        syncProgress = nil
        syncTask = Task { [self] in
            defer { isSyncing = false; syncProgress = nil }
            do {
                _ = try await syncNow { progress in
                    Task { @MainActor in self.syncProgress = progress }
                }
            } catch is CancellationError {
                // User cancelled — leave the partial catalog; next sync resumes.
            } catch {
                lastSyncSummary = "Sync failed: \(error.localizedDescription)"
            }
        }
    }

    /// Cancel an in-flight sync (best-effort).
    public func cancelSync() {
        syncTask?.cancel()
    }

    @discardableResult
    public func syncNow(progress: (@Sendable (SyncProgress) -> Void)? = nil) async throws -> SyncSummary {
        guard active != nil else { throw MozzError.unsupported("No active server") }
        // Plex can't browse without a music-library section id. Resolve it now if
        // activation didn't (self-healing), so a plain "Sync Now" recovers without
        // a re-login — and surfaces a clear error if the server has no music.
        try await ensurePlexMusicSection()
        guard let active else { throw MozzError.unsupported("No active server") }
        // Catalog sync uses a bulk-timeout backend: a single page of a few
        // hundred items can take tens of seconds to generate on a large/slow
        // self-hosted server, which would blow the 12s interactive timeout and
        // abort the sync (leaving albums/tracks unsynced). A smaller page size
        // keeps each request well within the bulk timeout and bounds memory.
        let backend = makeBulkSyncBackend() ?? active.backend
        let engine = LibrarySyncEngine(backend: backend, database: database, pageSize: 200)
        let summary = try await engine.sync(progress: progress)
        lastSyncSummary = "\(summary.tracks) tracks, \(summary.albums) albums, \(summary.artists) artists"
        // New catalog + listening → refresh the mixes off-main. Non-fatal.
        await regenerateMozzWeekly()
        await regenerateHomeMixes()
        // Flush any likes/ratings that were made offline.
        await flushFavoriteOutbox()
        // Fill in missing MusicBrainz IDs off-main, rate-limited. Fire-and-forget
        // and single-flight inside the actor, so it never delays this sync.
        await enrichment.resolvePending(serverId: active.connection.id)
        return summary
    }

    // MARK: Recommendations

    /// Force-regenerate the "Mozz Weekly" set for the active server (e.g. after a
    /// sync). Off-main via the recommendation actor; failures are swallowed so a
    /// recommendation hiccup never breaks sync/browse.
    public func regenerateMozzWeekly() async {
        guard let serverId = active?.connection.id else { return }
        _ = try? await recommendations.generateMozzWeekly(serverId: serverId)
    }

    /// Generate "Mozz Weekly" only if it's missing or older than a week — the
    /// weekly cadence, cheap to call whenever Home appears.
    public func ensureMozzWeekly() async {
        guard let serverId = active?.connection.id else { return }
        let existing = try? await recommendations.mozzWeeklySet()
        let ageDays = existing.map { (Date().timeIntervalSince1970 - $0.generatedAt) / 86_400 }
        if existing == nil || (ageDays ?? .greatestFiniteMagnitude) >= 7 {
            _ = try? await recommendations.generateMozzWeekly(serverId: serverId)
        }
    }

    private static let homeMixesGeneratedAtKey = "mozz.homeMixesGeneratedAt"

    /// Force-regenerate the daily Home mixes (Supermix, Daily/Artist/Replay).
    public func regenerateHomeMixes() async {
        guard let serverId = active?.connection.id else { return }
        try? await recommendations.generateHomeMixes(serverId: serverId)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.homeMixesGeneratedAtKey)
    }

    /// Regenerate the daily Home mixes at most once a day. Gated by a persisted
    /// timestamp (not a set's age) so cold-start users — who produce no mix sets
    /// yet — don't re-run the generator on every Home appearance.
    public func ensureHomeMixes() async {
        guard active?.connection.id != nil else { return }
        let last = UserDefaults.standard.double(forKey: Self.homeMixesGeneratedAtKey)
        if (Date().timeIntervalSince1970 - last) >= 24 * 3600 {
            await regenerateHomeMixes()
        }
    }

    /// The Home mix tiles (daily batch + Mozz Weekly), ordered for display.
    public func homeMixes() async -> [RecommendationService.HomeMix] {
        (try? await recommendations.homeMixes()) ?? []
    }

    // MARK: Likes & ratings

    /// Whether the active server models likes as a boolean favorite (Jellyfin);
    /// the UI shows a heart. Otherwise it uses ratings (Plex) → a rating chip.
    public var usesFavorites: Bool { active?.capabilities.supportsFavorites ?? false }
    public var usesRatings: Bool { active?.capabilities.supportsRatings ?? false }

    /// Like or unlike a track. On a favorites backend this toggles the boolean
    /// favorite; on a ratings backend it sets 5★ (like) or clears the rating
    /// (unlike). Offline-first: the local DB updates immediately and the server
    /// write is queued + flushed later.
    public func setLiked(_ liked: Bool, track: TrackRecord) async {
        guard let active else { return }
        let value: FavoriteChange.Value = active.capabilities.supportsFavorites
            ? .favorite(liked)
            : .rating(liked ? LikePolicy.likeStars : nil)
        await applyFavorite(FavoriteChange(serverId: active.connection.id, remoteId: track.remoteId, value: value),
                            wasLiked: LikePolicy.isLiked(isFavorite: track.isFavorite, rating: track.rating))
    }

    /// Set (or clear, with `nil`) a track's granular star rating — ratings
    /// backends only (Plex). No-op on a favorites backend.
    public func setRating(_ stars: Double?, track: TrackRecord) async {
        guard let active, active.capabilities.supportsRatings else { return }
        await applyFavorite(FavoriteChange(serverId: active.connection.id, remoteId: track.remoteId, value: .rating(stars)),
                            wasLiked: LikePolicy.isLiked(isFavorite: track.isFavorite, rating: track.rating))
    }

    /// Like/rate overloads for the domain ``Track`` (e.g. the now-playing engine
    /// exposes `Track`, not `TrackRecord`). `Track.id` is the backend remote id.
    public func setLiked(_ liked: Bool, track: Track) async {
        guard let active else { return }
        let value: FavoriteChange.Value = active.capabilities.supportsFavorites
            ? .favorite(liked)
            : .rating(liked ? LikePolicy.likeStars : nil)
        await applyFavorite(FavoriteChange(serverId: active.connection.id, remoteId: track.id, value: value),
                            wasLiked: LikePolicy.isLiked(isFavorite: track.isFavorite, rating: track.rating))
    }

    public func setRating(_ stars: Double?, track: Track) async {
        guard let active, active.capabilities.supportsRatings else { return }
        await applyFavorite(FavoriteChange(serverId: active.connection.id, remoteId: track.id, value: .rating(stars)),
                            wasLiked: LikePolicy.isLiked(isFavorite: track.isFavorite, rating: track.rating))
    }

    /// Whether a track is currently liked, per the active backend's policy.
    public func isLiked(_ track: Track) -> Bool {
        LikePolicy.isLiked(isFavorite: track.isFavorite, rating: track.rating)
    }

    /// Apply a like/rating change: local DB write (instant, offline) + a
    /// liked/unliked play-event on transition (recommender signal) + a queued
    /// server write-back that flushes now if online.
    private func applyFavorite(_ change: FavoriteChange, wasLiked: Bool) async {
        let nowLiked = (try? await favorites.applyLocally(change)) ?? change.isLiked
        if nowLiked != wasLiked {
            try? await playEvents.append(
                PlayEvent(trackID: change.remoteId, kind: nowLiked ? .liked : .unliked),
                serverId: change.serverId)
        }
        await flushFavoriteOutbox()
    }

    /// Replay queued like/rating writes to the server, removing each on success.
    /// Single-flight (@MainActor guard) so a sync-triggered flush and a
    /// toggle-triggered flush can't overlap and double-send; if a flush is
    /// requested while one is running, it re-runs once more at the end so the
    /// latest intent is always synced promptly.
    public func flushFavoriteOutbox() async {
        guard active != nil else { return }
        if isFlushingOutbox { flushRequestedAgain = true; return }
        isFlushingOutbox = true
        defer { isFlushingOutbox = false }
        repeat {
            flushRequestedAgain = false
            await performFavoriteFlush()
        } while flushRequestedAgain
    }

    private func performFavoriteFlush() async {
        guard let active else { return }
        let pending = (try? await favorites.pending(serverId: active.connection.id)) ?? []
        for op in pending {
            let type = CatalogItemType(rawValue: op.itemType) ?? .track
            do {
                if op.kind == "favorite" {
                    try await active.backend.setFavorite((op.value ?? 0) >= 0.5, itemID: op.remoteId, type: type)
                } else {
                    try await active.backend.setRating(op.value, itemID: op.remoteId, type: type)
                }
                // Compare-and-delete: if the user re-toggled this track while the
                // (slow) server write was in flight, its createdAt changed and this
                // no-ops, leaving the newer intent queued.
                if let id = op.id {
                    try await favorites.removePending(id: id, ifUnchangedSince: op.createdAt)
                }
            } catch {
                break
            }
        }
    }

    // MARK: Deep links / Handoff routing

    /// Handle an incoming `mozz://` URL (deep link, widget tap). Parses it and
    /// queues the destination; `MainTabsView` applies it when it's on screen.
    func handle(url: URL) {
        guard let target = DeepLinkTarget.parse(url) else { return }
        pendingDeepLink = target
    }

    /// Handle a continued Handoff activity, routing through the same queue.
    func handleHandoff(activityType: String, userInfo: [AnyHashable: Any]?) {
        guard let target = DeepLinkTarget.from(activityType: activityType, userInfo: userInfo) else { return }
        pendingDeepLink = target
    }

    /// Resolve a queued target into a concrete tab + navigation path, looking up
    /// record payloads from the local database. Returns `nil` if the record isn't
    /// in the catalog (e.g. a stale link, or not yet synced).
    func resolveDeepLink(_ target: DeepLinkTarget) async -> (AppTab, [AppRoute])? {
        switch target {
        case .tab(let tab):
            return (tab, [])
        case .category(let route):
            return (.library, [route])
        case .genre(let name):
            return (.library, [.genre(name)])
        case .album(let id):
            guard let serverId = active?.connection.id,
                  let album = try? await repository.album(serverId: serverId, remoteId: id) else { return nil }
            return (.library, [.album(album)])
        case .artist(let id):
            guard let serverId = active?.connection.id,
                  let artist = try? await repository.artist(serverId: serverId, remoteId: id) else { return nil }
            return (.library, [.artist(artist)])
        case .playlist(let id):
            guard let serverId = active?.connection.id,
                  let playlist = (try? await repository.allPlaylists(serverId: serverId))?.first(where: { $0.remoteId == id })
            else { return nil }
            return (.library, [.playlist(playlist)])
        }
    }

    /// Ensure the active Plex backend is set up to sync ALL the server's music
    /// libraries. Plex browse endpoints require a section id, and a server can
    /// host several music libraries — the user's default is to sync them all — so
    /// we resolve the full set of `artist` sections here (fresh each sync, so
    /// newly-added libraries are picked up) and rebuild the active backend to span
    /// them. On success it persists the primary section to the connection/DB/
    /// keychain (a "music resolved" marker + back-compat). If the server exposes
    /// no music library it throws a clear error naming the sections it DOES have,
    /// instead of the later cryptic "section not resolved". No-op for non-Plex.
    private func ensurePlexMusicSection() async throws {
        guard let current = active, current.connection.kind == .plex,
              let plex = current.backend as? PlexBackend else { return }

        guard let sections = try? await plex.musicSections(), !sections.isEmpty else {
            let summary: String
            do {
                let all = try await plex.allLibrarySections()
                summary = all.isEmpty
                    ? "the server returned no library sections"
                    : "found only " + all.map { "\($0.title ?? "?") (\($0.type ?? "?"))" }.joined(separator: ", ")
            } catch {
                summary = "couldn't list sections: \(error.localizedDescription)"
            }
            throw MozzError.unsupported("No music library on ‘\(current.connection.name)’ — \(summary)")
        }

        let allIDs = sections.map(\.id)
        // Honor the user's library selection (nil = all); ignore stale ids the
        // server no longer has, and fall back to all if the selection resolves to
        // nothing (e.g. every chosen library was removed).
        let stored = SessionPersistence.load(credentials)
        let selected = stored?.selectedMusicSectionIDs
        var ids = allIDs
        if let selected {
            let filtered = allIDs.filter { selected.contains($0) }
            if !filtered.isEmpty { ids = filtered }
        }
        // Already spanning exactly this set — nothing to rebuild.
        if Set(ids) == Set(plex.musicSectionIDs), current.connection.musicSectionID != nil { return }
        guard let token = stored?.token else { return }

        var connection = current.connection
        connection.musicSectionID = ids.first
        let backend = PlexBackend(connection: connection, token: token, clientInfo: clientInfo, musicSectionIDs: ids)
        try await CatalogWriter(database).saveServer(connection)
        if var stored = SessionPersistence.load(credentials) {
            stored.musicSectionID = ids.first
            SessionPersistence.save(stored, to: credentials)
        }
        finishActivation(connection: connection, backend: backend, capabilities: current.capabilities)
    }

    // MARK: Plex server & library picker

    /// Discover the account's Plex servers for the picker (grouped by server, one
    /// entry each). Empty for non-Plex or when the account token isn't stored.
    public func plexServers() async -> [PlexServerOption] {
        guard active?.connection.kind == .plex,
              let accountToken = SessionPersistence.load(credentials)?.accountToken else { return [] }
        let auth = PlexAuthenticator(clientInfo: clientInfo, clientIdentifier: clientIdentifier)
        guard let connections = try? await auth.discoverConnections(accountToken: accountToken) else { return [] }
        let currentName = active?.connection.name
        var seen = Set<String>()
        var options: [PlexServerOption] = []
        for connection in connections where !connection.clientIdentifier.isEmpty {
            if seen.insert(connection.clientIdentifier).inserted {
                options.append(PlexServerOption(id: connection.clientIdentifier,
                                                name: connection.serverName,
                                                isCurrent: connection.serverName == currentName))
            }
        }
        return options
    }

    /// The active Plex server's music libraries, with the user's current
    /// selection (nil selection = all selected).
    public func plexMusicLibraries() async -> [PlexMusicLibraryOption] {
        guard let plex = active?.backend as? PlexBackend,
              let sections = try? await plex.musicSections() else { return [] }
        let selected = SessionPersistence.load(credentials)?.selectedMusicSectionIDs
        return sections.map { section in
            PlexMusicLibraryOption(id: section.id, title: section.title,
                                   isSelected: selected?.contains(section.id) ?? true)
        }
    }

    /// Switch to a different Plex server (by machine identifier): pick its best
    /// music connection, reset the library selection to "all", persist, activate
    /// and re-sync.
    public func selectPlexServer(id serverMachineID: String) async {
        guard let existing = SessionPersistence.load(credentials),
              let accountToken = existing.accountToken else { return }
        let auth = PlexAuthenticator(clientInfo: clientInfo, clientIdentifier: clientIdentifier)
        guard let connections = try? await auth.discoverConnections(accountToken: accountToken) else { return }
        let serverConnections = connections.filter { $0.clientIdentifier == serverMachineID }
        guard let chosen = await auth.firstMusicConnection(serverConnections) else { return }
        let stored = StoredSession(
            kind: .plex, baseURL: chosen.uri, token: chosen.accessToken,
            userID: nil, serverName: chosen.serverName, clientIdentifier: clientIdentifier,
            musicSectionID: nil, accountToken: accountToken, selectedMusicSectionIDs: nil)
        SessionPersistence.save(stored, to: credentials)
        do {
            try await activate(stored)
            startSync()
        } catch {
            lastSyncSummary = "Couldn't switch server: \(error.localizedDescription)"
        }
    }

    /// Persist which music libraries to sync (empty = all) and re-sync. The next
    /// sync's `ensurePlexMusicSection` applies the selection, and its prune drops
    /// tracks from deselected libraries.
    public func setSelectedMusicLibraries(_ ids: [String]) {
        guard var stored = SessionPersistence.load(credentials) else { return }
        stored.selectedMusicSectionIDs = ids.isEmpty ? nil : ids
        SessionPersistence.save(stored, to: credentials)
        startSync()
    }

    /// Rebuild the active backend with a bulk-timeout transport for catalog
    /// sync. Returns `nil` for the demo (or if the session can't be loaded), so
    /// the caller falls back to the interactive backend.
    private func makeBulkSyncBackend() -> (any MusicBackend)? {
        guard let active,
              let stored = SessionPersistence.load(credentials),
              !stored.isDemo else { return nil }
        let bulk = URLSessionTransport(role: .bulk)
        switch active.connection.kind {
        case .jellyfin:
            return JellyfinBackend(connection: active.connection, token: stored.token,
                                   clientInfo: clientInfo, transport: bulk)
        case .plex:
            // Span whatever set of music libraries the active backend resolved
            // (see ensurePlexMusicSection, which runs first in syncNow).
            let sectionIDs = (active.backend as? PlexBackend)?.musicSectionIDs
            return PlexBackend(connection: active.connection, token: stored.token,
                               clientInfo: clientInfo, transport: bulk,
                               musicSectionIDs: sectionIDs)
        }
    }

    // MARK: Downloads convenience

    public func downloadTrack(_ track: Track) async {
        guard let active else { return }
        try? await downloads.download(track, serverId: active.connection.id, using: active.backend)
    }

    public func downloadAlbum(groupKey: String) async {
        guard let active else { return }
        try? await downloads.downloadAlbum(albumGroupKey: groupKey, serverId: active.connection.id, using: active.backend)
    }

    // MARK: Backend construction

    private func buildBackend(from stored: StoredSession) async throws -> (ServerConnection, any MusicBackend) {
        switch stored.kind {
        case .jellyfin:
            let connection = ServerConnection(
                id: Self.serverId(kind: .jellyfin, baseURL: stored.baseURL),
                kind: .jellyfin, name: stored.serverName, baseURL: stored.baseURL,
                userID: stored.userID, clientIdentifier: stored.clientIdentifier
            )
            let backend = JellyfinBackend(connection: connection, token: stored.token, clientInfo: clientInfo)
            return (connection, backend)
        case .plex:
            var connection = ServerConnection(
                id: Self.serverId(kind: .plex, baseURL: stored.baseURL),
                kind: .plex, name: stored.serverName, baseURL: stored.baseURL,
                userID: stored.userID, clientIdentifier: stored.clientIdentifier,
                musicSectionID: stored.musicSectionID
            )
            var backend = PlexBackend(connection: connection, token: stored.token, clientInfo: clientInfo)
            if connection.musicSectionID == nil {
                if let section = try await backend.musicSections().first {
                    connection.musicSectionID = section.id
                    backend = PlexBackend(connection: connection, token: stored.token, clientInfo: clientInfo)
                    var updated = SessionPersistence.load(credentials)
                    updated?.musicSectionID = section.id
                    if let updated { SessionPersistence.save(updated, to: credentials) }
                }
            }
            return (connection, backend)
        }
    }

    private func wirePlaybackReporting() {
        playback.onReport = { [weak self] report in
            guard let self else { return }
            Task { @MainActor in
                guard let backend = self.active?.backend else { return }
                try? await backend.reportPlayback(report)
            }
        }
    }

    /// Feed the lock screen / Control Center album art. The engine fires
    /// `onNeedsArtwork` whenever the current track changes; we resolve the active
    /// backend's artwork URL, fetch the bytes, and hand them back via
    /// `provideArtwork`. The engine drops stale results (it checks the track id),
    /// so a rapid skip can never leave the previous track's art on screen.
    private func wireNowPlayingArtwork() {
        playback.onNeedsArtwork = { [weak self] track in
            guard let self else { return }
            Task { @MainActor in await self.provideNowPlayingArtwork(for: track) }
        }
    }

    private func provideNowPlayingArtwork(for track: Track) async {
        guard let artwork = track.artwork,
              let backend = active?.backend,
              let url = backend.artworkURL(for: artwork, size: 600) else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        playback.provideArtwork(data, for: track.id)
        // Also stash it for the widgets and refresh their snapshots with the art.
        guard track.id == playback.currentTrack?.id else { return }
        WidgetSnapshotStore.writeArtwork(data, name: Self.widgetArtworkName(track.id))
        // Derive the muted tint off the main thread (CoreImage decode + render).
        let hex = await Task.detached(priority: .utility) { WidgetTint.mutedHex(from: data) }.value
        guard track.id == playback.currentTrack?.id else { return }
        if let hex { widgetTintByTrack[track.id] = hex }
        updateNowPlayingWidget()
        patchRecentArtwork(trackID: track.id)
    }

    // MARK: Widgets (Home / Lock Screen snapshots)

    private static func widgetArtworkName(_ trackID: String) -> String {
        // Keep it filesystem-safe regardless of the backend's id format.
        let safe = trackID.replacingOccurrences(of: "/", with: "_")
        return "np-\(safe).jpg"
    }

    /// Keep the now-playing snapshot fresh on track change and play/pause. The
    /// snapshot publisher ticks every 0.5s during playback, so we collapse it to
    /// just the status to avoid rewriting the file (and reloading the widget) on
    /// every progress tick.
    private func wireNowPlayingWidget() {
        // Let widget / Control-Center AudioPlaybackIntents drive the engine (they
        // run in this app process). Safe to call the engine directly on the main
        // actor; a no-op if there's nothing loaded.
        PlaybackRemoteControl.togglePlayPause = { [weak self] in self?.playback.togglePlayPause() }
        PlaybackRemoteControl.next = { [weak self] in self?.playback.next() }
        PlaybackRemoteControl.previous = { [weak self] in self?.playback.previous() }

        playback.$currentTrack
            .removeDuplicates { $0?.id == $1?.id }
            .receive(on: RunLoop.main)
            .sink { [weak self] track in
                self?.updateNowPlayingWidget()
                self?.persistPlaybackState()
                if let track { self?.recordRecentlyPlayed(track) }
            }
            .store(in: &widgetCancellables)

        playback.$snapshot
            .map(\.status)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateNowPlayingWidget()
                self?.persistPlaybackState()
            }
            .store(in: &widgetCancellables)

        // Keep the persisted elapsed position reasonably fresh while playing,
        // without hammering the disk on every 0.5s tick.
        playback.$snapshot
            .throttle(for: .seconds(10), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.persistPlaybackState() }
            .store(in: &widgetCancellables)
    }

    /// Save (or clear) the on-disk playback session so it can be resumed after a
    /// cold launch.
    private func persistPlaybackState() {
        if let state = playback.persistentState {
            PlaybackStatePersistence.save(state)
        } else {
            PlaybackStatePersistence.clear()
        }
    }

    /// Reload the last session into the engine (paused, seeked to where it left
    /// off) so the user or the widget's play button can resume it. Skipped when
    /// something is already playing or launch automation will start playback.
    private func restoreLastPlaybackSession() {
        guard playback.currentTrack == nil,
              ProcessInfo.processInfo.environment["MOZZ_AUTOPLAY"] != "1",
              let state = PlaybackStatePersistence.load() else { return }
        playback.restore(state)
    }

    private func updateNowPlayingWidget() {
        guard let track = playback.currentTrack else {
            WidgetSnapshotStore.writeNowPlaying(nil)
            reloadWidget(MozzWidget.nowPlayingKind)
            return
        }
        let name = Self.widgetArtworkName(track.id)
        let artworkFile = WidgetSnapshotStore.artworkURL(name) != nil ? name : nil
        let snapshot = NowPlayingWidgetSnapshot(
            title: track.title,
            artist: track.artistName,
            isPlaying: playback.snapshot.status == .playing,
            artworkFile: artworkFile,
            tintHex: widgetTintByTrack[track.id],
            deepLink: "mozz://tab/library")
        WidgetSnapshotStore.writeNowPlaying(snapshot)
        reloadWidget(MozzWidget.nowPlayingKind)
    }

    private func recordRecentlyPlayed(_ track: Track) {
        var items = WidgetSnapshotStore.readRecentlyPlayed()?.items ?? []
        items.removeAll { $0.id == track.id }
        let name = Self.widgetArtworkName(track.id)
        let artworkFile = WidgetSnapshotStore.artworkURL(name) != nil ? name : nil
        items.insert(RecentlyPlayedItem(
            id: track.id, title: track.title, subtitle: track.artistName,
            artworkFile: artworkFile, tintHex: widgetTintByTrack[track.id],
            deepLink: "mozz://tab/library"), at: 0)
        let capped = Array(items.prefix(12))
        WidgetSnapshotStore.writeRecentlyPlayed(RecentlyPlayedWidgetSnapshot(items: capped))
        pruneWidgetArtwork(referencedBy: capped)
        reloadWidget(MozzWidget.recentlyPlayedKind)
    }

    /// Delete artwork files no longer referenced by Now Playing or the (capped)
    /// recently-played list, so the App Group container doesn't accumulate one
    /// JPEG per unique track ever played.
    private func pruneWidgetArtwork(referencedBy recents: [RecentlyPlayedItem]) {
        var keep = Set(recents.compactMap(\.artworkFile))
        if let track = playback.currentTrack {
            keep.insert(Self.widgetArtworkName(track.id))
        }
        WidgetSnapshotStore.pruneArtwork(keeping: keep)
        // Keep the in-memory tint cache bounded to the tracks still referenced.
        let keepIDs = Set(recents.map(\.id) + [playback.currentTrack?.id].compactMap { $0 })
        widgetTintByTrack = widgetTintByTrack.filter { keepIDs.contains($0.key) }
    }

    /// Once artwork lands, fill it into the most-recent entry that referenced this
    /// track without art yet.
    private func patchRecentArtwork(trackID: String) {
        guard var items = WidgetSnapshotStore.readRecentlyPlayed()?.items,
              let idx = items.firstIndex(where: { $0.id == trackID && $0.artworkFile == nil }) else { return }
        items[idx].artworkFile = Self.widgetArtworkName(trackID)
        items[idx].tintHex = widgetTintByTrack[trackID]
        WidgetSnapshotStore.writeRecentlyPlayed(RecentlyPlayedWidgetSnapshot(items: items))
        reloadWidget(MozzWidget.recentlyPlayedKind)
    }

    private func reloadWidget(_ kind: String) {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
        #endif
    }

    /// Persist the engine's listening-history events into the on-device
    /// `play_event` log, tagged with the active server (to form the durable
    /// track ref) and this device. Fire-and-forget; never blocks playback.
    private func wirePlayEventLogging() {
        playback.onPlayEvent = { [weak self] event in
            Task { @MainActor in
                guard let self, let serverId = self.active?.connection.id else { return }
                try? await self.playEvents.append(event, serverId: serverId, device: Self.deviceKind)
            }
        }
    }

    // MARK: Radio / Instant Mix

    /// The seed of the currently-playing station, if any. Drives the endless
    /// queue-extension hook.
    private var activeRadioSeed: RadioSeed?
    /// Track ids already surfaced by the current station, so successive batches
    /// don't immediately repeat.
    private var radioSeenIDs: Set<String> = []
    /// Bumped on every `startRadio` *intent*, so a newer start supersedes an
    /// older still-fetching one (last tap wins).
    private var radioIntent = 0
    /// Bumped only when a station is actually installed. The engine's extend
    /// closure captures this, so a superseded/failed `startRadio` (which never
    /// installs) can't strand a running station, and an in-flight extend can't
    /// pollute a newer station's state.
    private var activeStationID = 0

    /// Start an endless station seeded from a track (its genres + artist).
    public func startRadio(fromTrack track: Track) {
        startRadio(seed: RadioSeed(title: track.title, genres: track.genres,
                                   artistIds: [track.artistID].compactMap { $0 }),
                   initialExcluding: [track.id])
    }

    /// Start an endless station seeded from an artist.
    public func startRadio(artistRemoteId: String, name: String, genres: [String]) {
        startRadio(seed: RadioSeed(title: name, genres: genres, artistIds: [artistRemoteId]))
    }

    /// Load an initial station batch and keep the queue topped up as it plays.
    /// Bails if superseded by a newer start, if the user changed playback (via a
    /// direct play/shuffle/stop) while the batch was fetching, or if the server
    /// changed — so a slow fetch can never hijack newer playback.
    public func startRadio(seed: RadioSeed, initialExcluding: Set<String> = []) {
        guard let serverId = active?.connection.id else { return }
        radioIntent += 1
        let intent = radioIntent
        let epoch = playback.transportEpoch
        Task { [weak self] in
            guard let self else { return }
            let ids = (try? await self.recommendations.radioBatch(
                seed: seed, serverId: serverId, limit: 30, excluding: initialExcluding)) ?? []
            let tracks = (try? await self.repository.tracksForPlayback(remoteIds: ids, serverId: serverId)) ?? []
            // Superseded, playback changed under us, server switched, or empty.
            guard intent == self.radioIntent,
                  epoch == self.playback.transportEpoch,
                  serverId == self.active?.connection.id,
                  !tracks.isEmpty else { return }
            self.activeStationID += 1
            let station = self.activeStationID
            self.activeRadioSeed = seed
            self.radioSeenIDs = initialExcluding.union(tracks.map(\.id))
            self.playback.startStation(tracks) { [weak self] in
                await self?.nextRadioBatch(station: station) ?? []
            }
        }
    }

    /// Fetch the next station batch, excluding tracks already surfaced this
    /// session. Bails (without mutating state) if this station is no longer the
    /// active one.
    private func nextRadioBatch(station: Int) async -> [Track] {
        guard station == activeStationID, let seed = activeRadioSeed,
              let serverId = active?.connection.id else { return [] }
        let ids = (try? await recommendations.radioBatch(
            seed: seed, serverId: serverId, limit: 20, excluding: radioSeenIDs)) ?? []
        let tracks = (try? await repository.tracksForPlayback(remoteIds: ids, serverId: serverId)) ?? []
        guard station == activeStationID else { return [] }
        radioSeenIDs.formUnion(tracks.map(\.id))
        return tracks
    }

    /// Forget any active radio session (e.g. on sign-out). The engine's own
    /// `stop()`/`play()` already bumps its transport epoch; this clears the app
    /// seed/seen so a late fetch can't resurrect a signed-out account's station.
    private func invalidateRadio() {
        activeStationID += 1
        activeRadioSeed = nil
        radioSeenIDs = []
    }

    private static let deviceKind: String = {
        #if os(iOS)
        return "iphone"
        #else
        return "mac"
        #endif
    }()

    /// Bridge the URLSession background-download completion handler (delivered to
    /// the app delegate after an out-of-process relaunch) into the download
    /// manager, so iOS knows when it's safe to snapshot the UI.
    private func wireBackgroundDownloads() {
        #if canImport(UIKit)
        downloads.backgroundCompletionHandler = {
            Task { @MainActor in
                MozzAppDelegate.backgroundSessionCompletionHandler?()
                MozzAppDelegate.backgroundSessionCompletionHandler = nil
            }
        }
        #endif
    }

    // MARK: Helpers

    public static func serverId(kind: BackendKind, baseURL: URL) -> String {
        "\(kind.rawValue)-\(baseURL.absoluteString)"
    }

    static func demoClipURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "demo_tone", withExtension: "wav") else {
            throw MozzError.unsupported("Demo clip missing from bundle")
        }
        return url
    }

    /// Build the demo's per-track clip resolver: a full-length generated tone
    /// matching each track's duration (cached in a caches subdirectory), falling
    /// back to the bundled short clip if the caches dir or generation is
    /// unavailable. Generated audio is ephemeral and never committed.
    static func makeDemoClipProvider() -> @Sendable (Track) -> URL {
        let fallback = (try? demoClipURL())
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("demo_tone.wav")
        let caches = (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = caches.appendingPathComponent("MozzDemoAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let provider = DemoAudioProvider(cacheDirectory: dir, fallbackURL: fallback)
        return { track in
            track.duration > 0 ? provider.clipURL(forDuration: track.duration) : fallback
        }
    }

    private static func stableClientIdentifier(_ store: any CredentialStore) -> String {
        if let existing = try? store.string(forKey: "client.identifier") {
            return existing
        }
        let new = UUID().uuidString
        try? store.setString(new, forKey: "client.identifier")
        return new
    }
}
