import Foundation
import MozzCore
import MozzDatabase
import MozzEnrichment
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
    var accountToken: String?
    /// The server's own machine identifier — the thing that stays constant when
    /// its address changes. Persist it: it is what `plexResolve` matches on.
    var machineIdentifier: String?
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

struct WireStream: Encodable {
    var url: String
    var isTranscoded: Bool
    var sessionID: String?
}

struct WireLyricLine: Encodable {
    var text: String
    /// Seconds from the start of the track; absent for unsynced lyrics.
    var start: TimeInterval?
}

struct WireLyrics: Encodable {
    var lines: [WireLyricLine]
    var isSynced: Bool
    var source: String?
    var staySilent: Bool
}

struct WireURL: Encodable {
    var url: String?
}

struct WireLike: Encodable {
    var liked: Bool
}

/// What a server can do, so a client can ask instead of branching on its name.
///
/// The like control is the reason this crosses the boundary: Jellyfin has a
/// heart, Plex has five stars, Subsonic has both. A client that guessed from the
/// backend's name would be wrong the first time a server grew a feature.
struct WireCapabilities: Encodable {
    var backend: String
    var serverVersion: String?
    var supportsFavorites: Bool
    var supportsRatings: Bool
    var supportsLyrics: Bool
    var supportsTranscoding: Bool
    var supportsOriginalFileDownload: Bool
}

private func wire(_ c: ServerCapabilities) -> WireCapabilities {
    WireCapabilities(
        backend: c.backend.rawValue,
        serverVersion: c.serverVersion,
        supportsFavorites: c.supportsFavorites,
        supportsRatings: c.supportsRatings,
        supportsLyrics: c.supportsLyrics,
        supportsTranscoding: c.supportsTranscoding,
        supportsOriginalFileDownload: c.supportsOriginalFileDownload
    )
}

struct WireSyncStart: Encodable {
    var started: Bool
    var reason: String?
}

struct WireSyncStatus: Encodable {
    var running: Bool
    var finished: Bool
    var phase: String?
    var itemsSynced: Int
    var total: Int?
    var error: String?
    var artists: Int?
    var albums: Int?
    var tracks: Int?
    var playlists: Int?
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
    private var phase: String?
    private var itemsSynced = 0
    private var total: Int?
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
        failure = nil
        counts = nil
        return true
    }

    func report(phase: String, itemsSynced: Int, total: Int?) {
        lock.lock(); defer { lock.unlock() }
        self.phase = phase
        self.itemsSynced = itemsSynced
        self.total = total
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
            running: running, finished: finished, phase: phase,
            itemsSynced: itemsSynced, total: total, error: failure,
            artists: counts?.artists, albums: counts?.albums,
            tracks: counts?.tracks, playlists: counts?.playlists
        )
    }
}

/// Backends and their sync boxes, keyed by server id.
final class BackendTable: @unchecked Sendable {
    private let lock = NSLock()
    private var backends: [String: any MusicBackend] = [:]
    private var syncs: [String: SyncBox] = [:]
    /// Capabilities, remembered per server.
    ///
    /// `detectCapabilities()` is a network call on every backend, so it cannot
    /// run on the path of something as small as a like. Fetched once on first
    /// need and kept for the life of the session.
    private var caps: [String: ServerCapabilities] = [:]

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

    func capabilities(_ id: String) -> ServerCapabilities? {
        lock.lock(); defer { lock.unlock() }
        return caps[id]
    }

    func setCapabilities(_ value: ServerCapabilities, for id: String) {
        lock.lock(); defer { lock.unlock() }
        caps[id] = value
    }
}

/// A backend's capabilities, fetched once per session and remembered.
private func resolveCapabilities(
    _ backend: any MusicBackend,
    _ session: SessionContext
) async throws -> ServerCapabilities {
    let id = backend.connection.id
    if let cached = session.backends.capabilities(id) { return cached }
    let detected = try await backend.detectCapabilities()
    session.backends.setCapabilities(detected, for: id)
    return detected
}

/// Apply a like or rating: local row first, then the server.
///
/// Offline-first, matching what the iOS app does rather than inventing a second
/// policy. The local database is the source of truth a client reads back, so it
/// is written immediately and the change is queued in the outbox; the server
/// write is attempted right away and simply stays queued if it fails. That is
/// what makes a like survive a tunnel.
private func applyLike(
    _ request: ServerRequest,
    _ session: SessionContext,
    _ backend: any MusicBackend,
    remoteId: String,
    value: FavoriteChange.Value
) async throws -> String {
    let serverId = backend.connection.id
    let itemType = request.itemType.flatMap(CatalogItemType.init(rawValue:)) ?? .track
    let favorites = FavoritesStore(session.database)

    let wasLiked = (try? await favorites.isLiked(serverId: serverId, remoteId: remoteId)) ?? false
    let change = FavoriteChange(
        serverId: serverId, remoteId: remoteId, itemType: itemType, value: value)
    let nowLiked = try await favorites.applyLocally(change)

    // A like is a recommender signal, not just a flag, so the transition is
    // recorded the same way iOS records it. Only when the client has identified
    // itself: a like must never fail because a device had no name to give.
    if nowLiked != wasLiked, let deviceID = request.deviceID ?? request.deviceId, !deviceID.isEmpty {
        _ = try? await HistoryExchangeStore(session.database).recordLocalPlayEvent(
            PlayEvent(trackID: remoteId, kind: nowLiked ? .liked : .unliked),
            serverId: serverId,
            deviceID: deviceID
        )
    }

    await flushFavorites(session, backend)
    return session.success(request, WireLike(liked: nowLiked))
}

/// Replay queued like/rating writes, dropping each one that lands.
///
/// A failure breaks the loop rather than skipping: the usual cause is the server
/// being unreachable, and the rest of the queue will fail the same way. They stay
/// queued for the next attempt.
private func flushFavorites(_ session: SessionContext, _ backend: any MusicBackend) async {
    let serverId = backend.connection.id
    let favorites = FavoritesStore(session.database)
    let pending = (try? await favorites.pending(serverId: serverId)) ?? []
    for op in pending {
        let type = CatalogItemType(rawValue: op.itemType) ?? .track
        do {
            if op.kind == "favorite" {
                try await backend.setFavorite((op.value ?? 0) >= 0.5, itemID: op.remoteId, type: type)
            } else {
                try await backend.setRating(op.value, itemID: op.remoteId, type: type)
            }
            // Compare-and-delete: if the user re-toggled while this (slow) write
            // was in flight, its createdAt changed and this no-ops, leaving the
            // newer intent queued.
            if let id = op.id {
                _ = try await favorites.removePending(id: id, ifUnchangedSince: op.createdAt)
            }
        } catch {
            break
        }
    }
}

// MARK: - Identity

/// Stable server id, matching the iOS app's derivation exactly.
///
/// This has to agree byte for byte across clients: it is the key every catalog
/// row is scoped by, so a desktop client that derived it differently would mirror
/// the same server into a second, parallel library.
func mozzServerId(kind: BackendKind, baseURL: URL, username: String? = nil) -> String {
    if kind == .subsonic, let username, !username.isEmpty {
        return "\(kind.rawValue)-\(username.lowercased())-\(baseURL.absoluteString)"
    }
    return "\(kind.rawValue)-\(baseURL.absoluteString)"
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

    case "plexResolve":
        // The repair for a pinned address that has stopped answering. See
        // ADR-0017: Plex gives a server several addresses, sign-in picks one,
        // and when that one dies the app looks broken rather than disconnected.
        //
        // The server id is NOT re-derived. The caller passes the id it already
        // holds and gets it back unchanged, because the catalogue, the likes and
        // the play history are keyed on it — repointing the address must not
        // orphan them.
        guard let accountToken = request.accountToken, !accountToken.isEmpty else {
            return session.failure(request, "plexResolve needs the Plex accountToken")
        }
        let resolver = PlexAuthenticator(
            clientInfo: clientInfo(),
            clientIdentifier: request.clientIdentifier ?? fallbackClientIdentifier())
        let resolved = try await resolver.resolveConnection(
            accountToken: accountToken,
            machineIdentifier: request.machineIdentifier,
            serverName: request.serverName
        )
        var wired = wire(resolved)
        if let existing = request.serverId, !existing.isEmpty { wired.serverId = existing }
        return session.success(request, wired)

    // MARK: Attach / mirror

    case "attach":
        let backend = try makeBackend(request)
        session.backends.set(backend, for: backend.connection.id)
        try await CatalogWriter(session.database).saveServer(backend.connection)
        return session.success(request, ["serverId": backend.connection.id])

    case "libraries":
        guard let backend = try requireBackend(request, session) else {
            return session.failure(request, "libraries needs an attached serverId")
        }
        let libraries = try await backend.fetchLibraries()
        return session.success(request, libraries.map { WireLibrary(id: $0.id, name: $0.name) })

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

    case "lyrics":
        guard let remoteId = request.remoteId, let serverId = request.serverId else {
            return session.failure(request, "lyrics needs remoteId and serverId")
        }
        guard let record = try await session.repository.track(
            serverId: serverId, remoteId: remoteId
        ) else {
            return session.failure(request, "no track \(remoteId)")
        }
        // The backend is deliberately optional. A server that carries no lyrics
        // for this track — or one that is not attached at the moment — still gets
        // the LRCLIB fallback, which is where most lyrics come from anyway.
        let lyricsBackend = try requireBackend(request, session)
        let resolution = await LyricsService().resolve(
            track: record.toDomain(),
            backend: lyricsBackend,
            context: .visible,
            useLRCLIB: request.useLRCLIB ?? true,
            userInitiated: true
        )
        return session.success(request, WireLyrics(
            lines: (resolution.lyrics?.lines ?? []).map {
                WireLyricLine(text: $0.text, start: $0.start)
            },
            isSynced: resolution.lyrics?.isSynced ?? false,
            source: resolution.lyrics?.source?.rawValue,
            // Distinguishes "this track has no lyrics" from "we could not find
            // out" — the client must stay quiet for the second rather than
            // asserting a negative it cannot support.
            staySilent: resolution.staySilent
        ))

    case "capabilities":
        guard let backend = try requireBackend(request, session) else {
            return session.failure(request, "capabilities needs an attached serverId")
        }
        let caps = try await resolveCapabilities(backend, session)
        return session.success(request, wire(caps))

    case "setLiked":
        guard let backend = try requireBackend(request, session) else {
            return session.failure(request, "setLiked needs an attached serverId")
        }
        guard let remoteId = request.remoteId else {
            return session.failure(request, "setLiked needs remoteId")
        }
        guard let liked = request.liked else {
            return session.failure(request, "setLiked needs liked")
        }
        let caps = try await resolveCapabilities(backend, session)
        // The one control every backend can express, in each one's own terms: a
        // boolean favourite where there is one, and the "I really like this"
        // star where there is not. `LikePolicy` owns both halves of that
        // translation so a like means the same thing on every client.
        let value: FavoriteChange.Value = caps.supportsFavorites
            ? .favorite(liked)
            : .rating(liked ? LikePolicy.likeStars : nil)
        return try await applyLike(request, session, backend, remoteId: remoteId, value: value)

    case "setRating":
        guard let backend = try requireBackend(request, session) else {
            return session.failure(request, "setRating needs an attached serverId")
        }
        guard let remoteId = request.remoteId else {
            return session.failure(request, "setRating needs remoteId")
        }
        let caps = try await resolveCapabilities(backend, session)
        guard caps.supportsRatings else {
            return session.failure(request, "this server has no ratings — use setLiked")
        }
        return try await applyLike(
            request, session, backend, remoteId: remoteId, value: .rating(request.stars))

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
            username: authenticated.kind == .subsonic ? authenticated.userID : nil
        ),
        kind: authenticated.kind.rawValue,
        baseURL: authenticated.baseURL.absoluteString,
        token: authenticated.token,
        userID: authenticated.userID,
        serverName: authenticated.serverName,
        clientIdentifier: authenticated.clientIdentifier,
        accountToken: authenticated.accountToken,
        machineIdentifier: authenticated.machineIdentifier
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
    // An account may keep its identity across a change of address. Plex hands out
    // several candidate addresses for one server — local, remote, relay — and
    // which of them works depends on the network the phone is on right now. The
    // catalogue, the likes and the play history are all keyed on this id, so
    // deriving it from whichever address happened to answer means moving between
    // Wi-Fi and cellular can orphan the library. When the caller already knows the
    // account's id, that is the identity; the derived one is only for an account
    // being met for the first time.
    var connection = ServerConnection(
        id: request.serverId ?? mozzServerId(kind: kind, baseURL: baseURL, username: request.username),
        kind: kind,
        name: request.serverName ?? kind.rawValue.capitalized,
        baseURL: baseURL,
        userID: request.userID,
        clientIdentifier: identifier
    )
    connection.musicSectionID = request.musicSectionID

    switch kind {
    case .jellyfin:
        return JellyfinBackend(
            connection: connection, token: token, clientInfo: clientInfo(),
            musicLibraryId: request.musicSectionID)
    case .plex:
        return PlexBackend(
            connection: connection, token: token, clientInfo: clientInfo(),
            musicSectionIDs: request.musicSectionID.map { [$0] })
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
                box.report(
                    phase: progress.phase.rawValue,
                    itemsSynced: progress.itemsSynced,
                    total: progress.totalCount
                )
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
