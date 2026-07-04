import Foundation
import MozzCore
import MozzDatabase
import MozzDownloads
import MozzPlayback
import MozzNetworking
import MozzSync
import MozzPlex
import MozzJellyfin

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
    public let credentials: any CredentialStore
    public let clientInfo: ClientInfo
    public let clientIdentifier: String

    private let resolver = SwappableResolver()

    /// The active server, or `nil` when the user needs to sign in.
    @Published public private(set) var active: ActiveServer?
    /// Whether we're still restoring a saved session at launch.
    @Published public private(set) var isRestoring = true
    @Published public private(set) var lastSyncSummary: String?

    public init(database: MusicDatabase, credentials: any CredentialStore, fileStore: DownloadFileStore) {
        self.database = database
        self.credentials = credentials
        self.fileStore = fileStore
        self.repository = LibraryRepository(database)
        self.downloads = DownloadManager(database: database, fileStore: fileStore)
        self.playback = PlaybackEngine(resolver: resolver)
        self.clientIdentifier = Self.stableClientIdentifier(credentials)
        self.clientInfo = ClientInfo(
            product: "Mozz", version: "0.1.0",
            deviceName: "iPhone", platform: "iOS", platformVersion: "17.0"
        )
        wirePlaybackReporting()
        wireBackgroundDownloads()
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
        } catch {
            SessionPersistence.clear(credentials)
        }
    }

    /// Activate a freshly-authenticated Plex/Jellyfin session.
    public func activate(session: AuthenticatedSession) async throws {
        let stored = StoredSession(
            kind: session.kind, baseURL: session.baseURL, token: session.token,
            userID: session.userID, serverName: session.serverName,
            clientIdentifier: session.clientIdentifier, musicSectionID: nil
        )
        try await activate(stored)
        SessionPersistence.save(stored, to: credentials)
    }

    /// Activate the offline demo: generate a synthetic catalog and serve a
    /// bundled clip so playback/downloads work with no server.
    public func activateDemo(size: SyntheticCatalog.Size = .init(artists: 200, albums: 2_000, tracks: 20_000)) async throws {
        let serverId = "demo"
        let clip = try Self.demoClipURL()
        let backend = DemoBackend(serverId: serverId, clipURL: clip)
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
        let capabilities = (try? await backend.detectCapabilities())
            ?? ServerCapabilities(backend: stored.kind)
        try await CatalogWriter(database).saveServer(connection)
        try await CatalogWriter(database).saveCapabilities(capabilities, serverId: connection.id)
        finishActivation(connection: connection, backend: backend, capabilities: capabilities)
    }

    private func finishActivation(connection: ServerConnection, backend: any MusicBackend, capabilities: ServerCapabilities) {
        let offline = OfflineTrackURLResolver(
            serverId: connection.id,
            repository: repository,
            fileStore: fileStore,
            fallback: StreamingTrackURLResolver(backend: backend)
        )
        resolver.setDelegate(offline)
        active = ActiveServer(connection: connection, backend: backend, capabilities: capabilities)
    }

    public func signOut() {
        playback.stop()
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

    // MARK: Sync

    @discardableResult
    public func syncNow(progress: (@Sendable (SyncProgress) -> Void)? = nil) async throws -> SyncSummary {
        guard let active else { throw MozzError.unsupported("No active server") }
        let engine = LibrarySyncEngine(backend: active.backend, database: database)
        let summary = try await engine.sync(progress: progress)
        lastSyncSummary = "\(summary.tracks) tracks, \(summary.albums) albums, \(summary.artists) artists"
        return summary
    }

    // MARK: Downloads convenience

    public func downloadTrack(_ track: Track) async {
        guard let active else { return }
        try? await downloads.download(track, serverId: active.connection.id, using: active.backend)
    }

    public func downloadAlbum(remoteId: String) async {
        guard let active else { return }
        try? await downloads.downloadAlbum(remoteId: remoteId, serverId: active.connection.id, using: active.backend)
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

    private static func stableClientIdentifier(_ store: any CredentialStore) -> String {
        if let existing = try? store.string(forKey: "client.identifier") {
            return existing
        }
        let new = UUID().uuidString
        try? store.setString(new, forKey: "client.identifier")
        return new
    }
}
