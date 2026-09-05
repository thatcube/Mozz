import Foundation
import MozzCore
import MozzDatabase
import MozzJellyfin
import MozzPlex
import MozzSubsonic
import MozzSync

// MARK: - Server connection, sync, and URL resolution
//
// `MozzSession.swift` reads a library that already exists. This file is how one
// comes to exist: sign in to a server, mirror its catalog into SQLite, and hand
// back playable URLs. Together they are everything a client needs to go from a
// blank window to audio.
//
// THREE DECISIONS WORTH THE WORDS
//
// 1. THE HOST OWNS SECRETS, NOT THE CORE.
//
// `connect` returns the auth token to the caller and then forgets it. It is not
// written to the database and there is no cross-platform keychain in here.
//
// That looks like passing the buck; it is the opposite. Secret storage is one of
// the few things that is genuinely, irreducibly platform-specific: Windows has
// DPAPI (`ProtectedData`, keyed to the logged-in user), macOS and iOS have the
// Keychain, Linux has libsecret, Android has the Keystore. A "portable" secret
// store would be the worst of all of them — either a file we pretend is safe, or
// four `#if` branches calling four native APIs from Swift, which is precisely the
// code that will not compile on the next platform. The host already links those
// APIs and already knows which one it is. So the boundary is: the core does
// protocol work, the host does platform work, and the token crosses between them
// exactly twice — out of `connect`, back in via `attach`.
//
// 2. SYNC IS POLLED, NOT CALLED BACK.
//
// `LibrarySyncEngine` reports progress through a closure. A closure cannot cross
// a C ABI without becoming a function pointer plus a context pointer plus a
// threading contract, re-stated correctly in every consumer language. Instead
// `sync` starts a task and returns immediately; `syncStatus` reads the latest
// progress out of a lock-guarded box. A UI that draws a progress bar is polling
// on a timer anyway.
//
// 3. BACKENDS LIVE ON THE SESSION.
//
// A backend holds a transport with its own connection pool and, for Plex, the
// resolved set of music section ids — all of which are expensive to rebuild and
// wrong to rebuild per call. `attach` puts one in the session's table; every
// later command looks it up by server id.

// MARK: - Wire models

struct WireSession: Encodable {
    var serverId: String
    var kind: String
    var baseURL: String
    var token: String
    var userID: String?
    var serverName: String
    var clientIdentifier: String
    var serverMachineIdentifier: String?
    var accountToken: String?
}

struct WirePinSession: Encodable {
    var pinId: Int
    var code: String
    /// Echoed back so the client persists the SAME identifier it polls and later
    /// attaches with — Plex ties the PIN, and every later request, to it.
    var clientIdentifier: String
    /// The hosted page to open in a browser (or render as a QR code) to link
    /// the account.
    var linkURL: String?
}

struct WirePlexAccountToken: Encodable {
    var accountToken: String?
}

struct WirePlexHomeUser: Encodable {
    var id: String
    var name: String
    var requiresPIN: Bool
    var isAdmin: Bool
    var isRestricted: Bool
    var avatarURL: String?
}

struct WirePlexSwitchedToken: Encodable {
    var accountToken: String
}

struct WireStream: Encodable {
    var url: String
    var isTranscoded: Bool
    var sessionID: String?
}

struct WireURL: Encodable {
    var url: String?
}

struct WireSyncStart: Encodable {
    var started: Bool
    var reason: String?
}

struct WireSyncStatus: Encodable {
    var running: Bool
    var finished: Bool
    var phase: String?
    var phaseLabel: String?
    var itemsSynced: Int
    var total: Int?
    var details: [WireSyncPhaseDetail]
    var error: String?
    var artists: Int?
    var albums: Int?
    var tracks: Int?
    var playlists: Int?
}

struct WireSyncPhaseDetail: Encodable {
    var phase: String
    var label: String
    var state: String
    var synced: Int
    var total: Int?
    var isComplete: Bool
}

struct WireLibrary: Encodable {
    var id: String
    var name: String
}

// MARK: - Per-session server state

/// Sync progress is written by a detached task and read by whichever thread
/// polls. A lock is the whole synchronisation story; the payload is small and
/// the contention is a poll timer.
final class SyncBox: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var finished = false
    private var phase: SyncProgress.Phase?
    private var itemsSynced = 0
    private var total: Int?
    private var details: [SyncProgress.PhaseDetail] = []
    private var failure: String?
    private var counts: (artists: Int, albums: Int, tracks: Int, playlists: Int)?

    /// Returns false when a sync is already in flight, so a client that
    /// double-taps cannot start two mirrors of the same server at once.
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if running { return false }
        running = true
        finished = false
        phase = nil
        itemsSynced = 0
        total = nil
        details = []
        failure = nil
        counts = nil
        return true
    }

    func report(_ progress: SyncProgress) {
        lock.lock(); defer { lock.unlock() }
        self.phase = progress.phase
        self.itemsSynced = progress.itemsSynced
        self.total = progress.totalCount
        self.details = progress.details
    }

    func succeed(artists: Int, albums: Int, tracks: Int, playlists: Int) {
        lock.lock(); defer { lock.unlock() }
        running = false
        finished = true
        counts = (artists, albums, tracks, playlists)
    }

    func fail(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        running = false
        finished = true
        failure = message
    }

    func status() -> WireSyncStatus {
        lock.lock(); defer { lock.unlock() }
        return WireSyncStatus(
            running: running, finished: finished, phase: phase?.rawValue,
            phaseLabel: phase?.label, itemsSynced: itemsSynced, total: total,
            details: details.map(wireSyncPhaseDetail), error: failure,
            artists: counts?.artists, albums: counts?.albums,
            tracks: counts?.tracks, playlists: counts?.playlists
        )
    }
}

private func wireSyncPhaseDetail(_ detail: SyncProgress.PhaseDetail) -> WireSyncPhaseDetail {
    let state: String
    switch detail.state {
    case .pending: state = "pending"
    case .syncing: state = "syncing"
    case .done: state = "done"
    }
    return WireSyncPhaseDetail(
        phase: detail.phase.rawValue,
        label: detail.phase.label,
        state: state,
        synced: detail.synced,
        total: detail.total,
        isComplete: detail.isComplete
    )
}

/// Backends and their sync boxes, keyed by server id.
final class BackendTable: @unchecked Sendable {
    private let lock = NSLock()
    private var backends: [String: any MusicBackend] = [:]
    private var syncs: [String: SyncBox] = [:]

    func set(_ backend: any MusicBackend, for id: String) {
        lock.lock(); defer { lock.unlock() }
        backends[id] = backend
        if syncs[id] == nil { syncs[id] = SyncBox() }
    }

    func backend(_ id: String) -> (any MusicBackend)? {
        lock.lock(); defer { lock.unlock() }
        return backends[id]
    }

    func sync(_ id: String) -> SyncBox? {
        lock.lock(); defer { lock.unlock() }
        return syncs[id]
    }

    func ids() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(backends.keys)
    }
}

// MARK: - Identity

/// Stable server id, matching the iOS app's derivation exactly.
///
/// This has to agree byte for byte across clients: it is the key every catalog
/// row is scoped by, so a desktop client that derived it differently would mirror
/// the same server into a second, parallel library.
func mozzServerId(
    kind: BackendKind,
    baseURL: URL,
    username: String? = nil,
    serverMachineIdentifier: String? = nil
) -> String {
    ServerIdentity.id(
        kind: kind,
        baseURL: baseURL,
        username: username,
        serverMachineIdentifier: serverMachineIdentifier
    )
}

private func clientInfo() -> ClientInfo {
    ClientInfo(
        product: "Mozz",
        version: mozzClientVersion,
        deviceName: mozzHostPlatform,
        platform: mozzHostPlatform,
        platformVersion: mozzHostPlatformVersion
    )
}

/// A stable per-installation identifier. The host supplies one (it knows where
/// to persist it); this is only the fallback for a caller that didn't.
private func fallbackClientIdentifier() -> String {
    UUID().uuidString
}

// MARK: - Dispatch

/// Returns `nil` when the command isn't one of ours, so the caller can keep
/// walking its own table and produce a single "unknown command" error.
func dispatchServerCommand(
    _ request: ServerRequest,
    _ session: SessionContext
) async throws -> String? {
    switch request.cmd {

    // MARK: Sign-in

    case "connect":
        return try await connect(request, session)

    case "plexPin":
        let identifier = request.clientIdentifier ?? fallbackClientIdentifier()
        let auth = PlexAuthenticator(clientInfo: clientInfo(), clientIdentifier: identifier)
        let pin = try await auth.requestPin()
        return session.success(request, WirePinSession(
            pinId: pin.id,
            code: pin.code,
            clientIdentifier: identifier,
            linkURL: pin.authAppURL(clientInfo: clientInfo())?.absoluteString
        ))

    case "plexPinCheck":
        guard let pinId = request.pinId, let code = request.code else {
            return session.failure(request, "plexPinCheck needs pinId and code")
        }
        let auth = PlexAuthenticator(
            clientInfo: clientInfo(),
            clientIdentifier: request.clientIdentifier ?? fallbackClientIdentifier())
        // nil simply means "not linked yet" — the client keeps polling.
        guard let accountToken = try await auth.checkPin(id: pinId, code: code) else {
            return session.success(request, WireURL(url: nil))
        }
        let authenticated = try await auth.completeLogin(accountToken: accountToken)
        return session.success(request, wire(authenticated))

    case "plexPinToken":
        guard let pinId = request.pinId, let code = request.code else {
            return session.failure(request, "plexPinToken needs pinId and code")
        }
        let auth = PlexAuthenticator(
            clientInfo: clientInfo(),
            clientIdentifier: request.clientIdentifier
                ?? fallbackClientIdentifier())
        let token = try await auth.checkPin(id: pinId, code: code)
        return session.success(
            request,
            WirePlexAccountToken(accountToken: token))

    case "plexHomeUsers":
        guard let accountToken = request.accountToken else {
            return session.failure(
                request, "plexHomeUsers needs accountToken")
        }
        let auth = PlexAuthenticator(
            clientInfo: clientInfo(),
            clientIdentifier: request.clientIdentifier
                ?? fallbackClientIdentifier())
        let users = try await auth.homeUsers(accountToken: accountToken)
        return session.success(request, users.map {
            WirePlexHomeUser(
                id: $0.id,
                name: $0.name,
                requiresPIN: $0.requiresPIN,
                isAdmin: $0.isAdmin,
                isRestricted: $0.isRestricted,
                avatarURL: $0.avatarURL?.absoluteString)
        })

    case "plexHomeSwitch":
        guard let accountToken = request.accountToken,
              let homeUserID = request.homeUserID else {
            return session.failure(
                request,
                "plexHomeSwitch needs accountToken and homeUserID")
        }
        let auth = PlexAuthenticator(
            clientInfo: clientInfo(),
            clientIdentifier: request.clientIdentifier
                ?? fallbackClientIdentifier())
        let user = PlexHomeUser(
            id: homeUserID,
            name: "",
            requiresPIN: request.profilePIN != nil,
            isAdmin: false)
        let switched = try await auth.token(
            for: user,
            accountToken: accountToken,
            pin: request.profilePIN)
        return session.success(
            request,
            WirePlexSwitchedToken(accountToken: switched))

    case "plexCompleteLogin":
        guard let accountToken = request.accountToken else {
            return session.failure(
                request, "plexCompleteLogin needs accountToken")
        }
        let auth = PlexAuthenticator(
            clientInfo: clientInfo(),
            clientIdentifier: request.clientIdentifier
                ?? fallbackClientIdentifier())
        let authenticated = try await auth.completeLogin(
            accountToken: accountToken,
            plexUserID: request.homeUserID)
        return session.success(request, wire(authenticated))

    /// Re-point a linked Plex account at an address that answers.
    ///
    /// The iOS client reaches ``PlexAuthenticator/resolveConnection`` directly
    /// because it is Swift all the way down; Android and the desktop only ever
    /// speak this envelope, so without a command here a dead address is
    /// permanent on those platforms. See ADR-0017.
    case "plexResolve":
        guard let accountToken = request.accountToken else {
            return session.failure(request, "plexResolve needs accountToken")
        }
        let auth = PlexAuthenticator(
            clientInfo: clientInfo(),
            clientIdentifier: request.clientIdentifier
                ?? fallbackClientIdentifier())
        let resolved = try await auth.resolveConnection(
            accountToken: accountToken,
            machineIdentifier: request.serverMachineIdentifier,
            serverName: request.serverName)
        return session.success(request, wire(resolved))

    // MARK: Attach / mirror

    case "attach":
        let backend = try makeBackend(request)
        session.backends.set(backend, for: backend.connection.id)
        try await CatalogWriter(session.database).saveServer(backend.connection)
        if let scope = CatalogSnapshotScope(
            connection: backend.connection,
            libraryIDs: request.allMusicLibraries == true
                ? ["*"]
                : request.musicSectionIDs) {
            _ = try await CatalogSnapshotDatabase(session.database)
                .prepare(scope: scope)
        }
        return session.success(request, ["serverId": backend.connection.id])

    case "libraries":
        guard let backend = try requireBackend(request, session) else {
            return session.failure(request, "libraries needs an attached serverId")
        }
        let libraries = try await backend.fetchLibraries()
        return session.success(request, libraries.map { WireLibrary(id: $0.id, name: $0.name) })

    /// What the attached server can actually do.
    ///
    /// Worth asking rather than inferring from the backend kind: the like
    /// control differs per backend — a heart on Jellyfin, a star on Plex, both
    /// on Subsonic — and a client that guessed would be wrong the first time a
    /// server grew a feature.
    case "capabilities":
        guard let backend = try requireBackend(request, session) else {
            return session.failure(request, "capabilities needs an attached serverId")
        }
        return session.success(request, try await backend.detectCapabilities())

    case "account":
        guard let backend = try requireBackend(request, session) else {
            return session.failure(request, "account needs an attached serverId")
        }
        let account = await backend.signedInAccount(size: request.size ?? 120)
        return session.success(request, WireAccount(
            displayName: account.displayName,
            username: account.username,
            avatarURL: account.avatarURL?.absoluteString
        ))

    case "sync":
        return try startSync(request, session)

    case "syncStatus":
        guard let serverId = request.serverId, let box = session.backends.sync(serverId) else {
            return session.failure(request, "syncStatus needs an attached serverId")
        }
        return session.success(request, box.status())

    // MARK: Playback URLs

    case "streamURL":
        guard let backend = try requireBackend(request, session) else {
            return session.failure(request, "streamURL needs an attached serverId")
        }
        guard let remoteId = request.remoteId, let serverId = request.serverId else {
            return session.failure(request, "streamURL needs remoteId and serverId")
        }
        guard let record = try await session.repository.track(serverId: serverId, remoteId: remoteId) else {
            return session.failure(request, "no track \(remoteId)")
        }
        let source = try await backend.streamSource(
            for: record.toDomain(), options: streamOptions(request))
        return session.success(request, WireStream(
            url: source.url.absoluteString,
            isTranscoded: source.isTranscoded,
            sessionID: source.sessionID
        ))

    case "artworkURL":
        guard let backend = try requireBackend(request, session) else {
            return session.failure(request, "artworkURL needs an attached serverId")
        }
        guard let key = request.artworkKey else {
            return session.failure(request, "artworkURL needs artworkKey")
        }
        let url = backend.artworkURL(for: ArtworkRef(key: key), size: request.size ?? 512)
        return session.success(request, WireURL(url: url?.absoluteString))

    default:
        return nil
    }
}

// MARK: - Sign-in

private func connect(_ request: ServerRequest, _ session: SessionContext) async throws -> String {
    guard let kindRaw = request.kind, let kind = BackendKind(rawValue: kindRaw) else {
        return session.failure(request, "connect needs kind (plex|jellyfin|subsonic)")
    }
    guard let baseURLString = request.baseURL, let baseURL = URL(string: baseURLString) else {
        return session.failure(request, "connect needs a valid baseURL")
    }
    let identifier = request.clientIdentifier ?? fallbackClientIdentifier()

    switch kind {
    case .jellyfin:
        guard let username = request.username, let password = request.password else {
            return session.failure(request, "jellyfin connect needs username and password")
        }
        let auth = JellyfinAuthenticator(
            baseURL: baseURL, clientInfo: clientInfo(), clientIdentifier: identifier)
        return session.success(request, wire(try await auth.authenticate(
            username: username, password: password)))

    case .subsonic:
        guard let username = request.username else {
            return session.failure(request, "subsonic connect needs username")
        }
        let auth = SubsonicAuthenticator(
            baseURL: baseURL, clientInfo: clientInfo(), clientIdentifier: identifier)
        // An OpenSubsonic API key is preferred where the server offers one: it
        // is revocable and never signs with a hash of the password.
        if let apiKey = request.apiKey {
            return session.success(request, wire(try await auth.authenticate(
                username: username, apiKey: apiKey)))
        }
        guard let password = request.password else {
            return session.failure(request, "subsonic connect needs password or apiKey")
        }
        return session.success(request, wire(try await auth.authenticate(
            username: username, password: password)))

    case .plex:
        // Plex has no username/password API for third parties; the PIN flow is
        // the supported path. `plexPin` starts it.
        return session.failure(request, "plex uses the PIN flow — call plexPin then plexPinCheck")
    }
}

/// Internal rather than private so a test can assert the contract that matters:
/// that this agrees with `attach` about a server's identity.
func wire(_ authenticated: AuthenticatedSession) -> WireSession {
    WireSession(
        // Subsonic scopes a server id by username, because one server can hold
        // several accounts with genuinely different libraries. `attach` derives
        // it that way, so `connect` must too: a client persists the id it gets
        // back here and passes it to every later call, and if the two halves
        // disagree then the backend is registered under one id and looked up
        // under another — sync, streaming and artwork all fail with "needs an
        // attached serverId" while plain browsing still works, because that
        // queries across every backend.
        serverId: mozzServerId(
            kind: authenticated.kind,
            baseURL: authenticated.baseURL,
            username: authenticated.kind == .subsonic ? authenticated.userID : nil,
            serverMachineIdentifier: authenticated.serverMachineIdentifier
        ),
        kind: authenticated.kind.rawValue,
        baseURL: authenticated.baseURL.absoluteString,
        token: authenticated.token,
        userID: authenticated.userID,
        serverName: authenticated.serverName,
        clientIdentifier: authenticated.clientIdentifier,
        serverMachineIdentifier: authenticated.serverMachineIdentifier,
        accountToken: authenticated.accountToken
    )
}

// MARK: - Backend construction

private func makeBackend(_ request: ServerRequest) throws -> any MusicBackend {
    guard let kindRaw = request.kind, let kind = BackendKind(rawValue: kindRaw) else {
        throw MozzError.unsupported("attach needs kind (plex|jellyfin|subsonic)")
    }
    guard let baseURLString = request.baseURL, let baseURL = URL(string: baseURLString) else {
        throw MozzError.unsupported("attach needs a valid baseURL")
    }
    guard let token = request.token else {
        throw MozzError.unsupported("attach needs token")
    }
    let identifier = request.clientIdentifier ?? fallbackClientIdentifier()
    let requestedSectionIDs = Array(Set(
        (request.musicSectionIDs ?? request.musicSectionID.map { [$0] } ?? [])
            .filter { !$0.isEmpty }
    )).sorted()
    var connection = ServerConnection(
        id: ServerIdentity.id(
            kind: kind,
            baseURL: baseURL,
            username: request.username,
            serverMachineIdentifier: request.serverMachineIdentifier
        ),
        kind: kind,
        name: request.serverName ?? kind.rawValue.capitalized,
        baseURL: baseURL,
        userID: request.userID ?? (kind == .subsonic ? request.username : nil),
        clientIdentifier: identifier
    )
    connection.musicSectionID = requestedSectionIDs.first

    switch kind {
    case .jellyfin:
        return JellyfinBackend(
            connection: connection, token: token, clientInfo: clientInfo(),
            musicLibraryId: requestedSectionIDs.first)
    case .plex:
        return PlexBackend(
            connection: connection, token: token, clientInfo: clientInfo(),
            musicSectionIDs: requestedSectionIDs.isEmpty
                ? nil
                : requestedSectionIDs,
            accountToken: request.accountToken)
    case .subsonic:
        guard let credential = SubsonicCredential.decode(token) else {
            throw MozzError.unsupported("subsonic attach needs an encoded credential as token")
        }
        return SubsonicBackend(
            connection: connection, credential: credential, clientInfo: clientInfo())
    }
}

private func requireBackend(
    _ request: ServerRequest,
    _ session: SessionContext
) throws -> (any MusicBackend)? {
    guard let serverId = request.serverId else { return nil }
    return session.backends.backend(serverId)
}

private func streamOptions(_ request: ServerRequest) -> StreamOptions {
    // Desktop and Windows clients decode locally and are not on a metered link
    // by default, so direct play is the right default: transcoding costs the
    // server CPU and costs the listener fidelity, for nothing.
    StreamOptions(
        maxBitrateKbps: request.maxBitrateKbps,
        forceTranscode: request.forceTranscode ?? false
    )
}

// MARK: - Sync

private func startSync(_ request: ServerRequest, _ session: SessionContext) throws -> String {
    guard let serverId = request.serverId,
          let backend = session.backends.backend(serverId),
          let box = session.backends.sync(serverId) else {
        return session.failure(request, "sync needs an attached serverId")
    }
    guard box.begin() else {
        return session.success(request, WireSyncStart(started: false, reason: "already running"))
    }

    let database = session.database
    Task.detached {
        let engine = LibrarySyncEngine(backend: backend, database: database)
        do {
            let summary = try await engine.sync(plan: .full, startMode: .resumeIfPossible) { progress in
                box.report(progress)
            }
            box.succeed(
                artists: summary.artists, albums: summary.albums,
                tracks: summary.tracks, playlists: summary.playlists
            )
        } catch {
            box.fail(String(describing: error))
        }
    }
    return session.success(request, WireSyncStart(started: true, reason: nil))
}
