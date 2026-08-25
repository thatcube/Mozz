import Foundation
import MozzCore
import MozzDatabase
import MozzRecommend

// MARK: - The session facade
//
// The probes in `MozzFFI.swift` answer "does this platform work at all". This
// file is the API a real client actually drives — a Windows or Android UI
// browsing a library.
//
// SHAPE, AND WHY
//
// One entry point, not fifty:
//
//     mozz_session_open(dbPath)          -> handle
//     mozz_session_call(handle, request) -> response
//     mozz_session_close(handle)
//
// Every operation is a JSON request naming a command. Adding a capability means
// adding a case, not exporting another C symbol and re-declaring it in every
// consumer — which matters a great deal when the consumers are written in
// different languages by different toolchains.
//
// STATEFUL, unlike the spike. The probe reopened the database on every call,
// which was fine for measuring but would be absurd for a UI: `MusicDatabase`
// holds a connection pool, and paging a list means hundreds of reads a second.
// The handle owns that pool for the life of the session.
//
// Requests carry an `id` that is echoed in the response, so a client is free to
// pipeline calls across threads without correlating by arrival order.

// MARK: - Envelope

struct SessionRequest: Decodable {
    var id: Int?
    var cmd: String
    var serverId: String?
    var offset: Int?
    var limit: Int?
    var query: String?
    var remoteId: String?
    var groupKey: String?
    var genre: String?
    /// Opaque resume position for a paged listing; see LibraryRepository.PageCursor.
    var cursor: String?

    // Server connection / sync / streaming. See `MozzSessionServer.swift`.
    var kind: String?
    var baseURL: String?
    var username: String?
    var password: String?
    var apiKey: String?
    var token: String?
    var userID: String?
    var serverName: String?
    var clientIdentifier: String?
    var musicSectionID: String?
    var pinId: Int?
    var code: String?
    var artworkKey: String?
    var size: Int?
    var maxBitrateKbps: Int?
    var forceTranscode: Bool?

    // Recommendations.
    var setId: String?
    var seed: UInt64?
    var seedTitle: String?
    var seedGenres: [String]?
    var seedArtistIds: [String]?
    var seedTrackRef: String?
    var excluding: [String]?
}

/// The server commands take the same envelope; the alias only keeps the two
/// files readable about which half of it they are using.
typealias ServerRequest = SessionRequest

private struct SessionResponse<Payload: Encodable>: Encodable {
    var id: Int?
    var ok: Bool
    var cmd: String
    var payload: Payload?
    var error: String?
    /// Where to resume a paged listing, or absent on the last page. Sits on the
    /// envelope rather than inside the payload so the payload stays a plain
    /// array — a client that ignores paging is unaffected.
    var nextCursor: String?
}

// MARK: - Wire models
//
// Deliberately NOT the database records. A record is a storage row; these are a
// view contract. Keeping them apart means a schema change does not silently
// reshape a UI written in another language, and it keeps columns the client has
// no business seeing out of the payload.

private struct WireServer: Encodable {
    var id: String
    var kind: String
    var name: String
    var baseURL: String
}

private struct WireArtist: Encodable {
    var id: Int64
    var remoteId: String
    var serverId: String
    var name: String
    var artworkKey: String?
}

private struct WireAlbum: Encodable {
    var id: Int64
    var remoteId: String
    var serverId: String
    var title: String
    var artistName: String
    var artistRemoteId: String?
    var year: Int?
    var trackCount: Int?
    var artworkKey: String?
    var groupKey: String
}

private struct WireTrack: Encodable {
    var id: Int64
    var remoteId: String
    var serverId: String
    var title: String
    var artistName: String
    var albumTitle: String?
    var albumRemoteId: String?
    var trackNumber: Int?
    var discNumber: Int?
    var durationSeconds: Double
    var artworkKey: String?
    var isFavorite: Bool
    /// ReplayGain in dB, when the server supplied one. Carried across the
    /// boundary because without it a client has no way to level a library, and
    /// the loudness difference between two albums is the most audible thing a
    /// music player can get wrong.
    var normalizationGainDB: Double?
}

private struct WirePlaylist: Encodable {
    var id: Int64
    var remoteId: String
    var serverId: String
    var title: String
    var trackCount: Int?
}

private struct WireCounts: Encodable {
    var artists: Int
    var albums: Int
    var tracks: Int
}

private struct WireSearchResults: Encodable {
    var artists: [WireArtist]
    var albums: [WireAlbum]
    var tracks: [WireTrack]
}

private struct WireHomeMix: Encodable {
    var id: String
    var title: String
    var subtitle: String?
    var kind: String
    var artworkKey: String?
    var generatedAt: Double
}

private struct WireRecommendationSet: Encodable {
    var id: String
    var title: String
    var kind: String
    var generatedAt: Double
}

private struct WireRecommendationItem: Encodable {
    var setId: String
    var trackRef: String
    var rank: Int
    var score: Double
    var inLibrary: Bool
    var reason: String?
}

private struct WireRadioBatch: Encodable {
    var remoteIds: [String]
    var tracks: [WireTrack]
}

private struct WireSuppression: Encodable {
    var scope: String
    var ref: String
    var createdAt: Double
}

private struct WireAction: Encodable {
    var ok: Bool
}

// MARK: - Mapping

private func wire(_ r: ArtistRecord) -> WireArtist {
    WireArtist(
        id: r.id ?? 0, remoteId: r.remoteId, serverId: r.serverId,
        name: r.name, artworkKey: r.artworkKey
    )
}

private func wire(_ r: AlbumRecord) -> WireAlbum {
    WireAlbum(
        id: r.id ?? 0, remoteId: r.remoteId, serverId: r.serverId,
        title: r.title, artistName: r.artistName, artistRemoteId: r.artistRemoteId,
        year: r.year, trackCount: r.trackCount, artworkKey: r.artworkKey,
        groupKey: r.albumGroupKey
    )
}

private func wire(_ r: TrackRecord) -> WireTrack {
    WireTrack(
        id: r.id ?? 0, remoteId: r.remoteId, serverId: r.serverId,
        title: r.title, artistName: r.artistName, albumTitle: r.albumTitle,
        albumRemoteId: r.albumRemoteId, trackNumber: r.trackNumber,
        discNumber: r.discNumber, durationSeconds: r.duration,
        artworkKey: r.artworkKey, isFavorite: r.isFavorite,
        normalizationGainDB: r.normalizationGainDB
    )
}

private func wire(_ r: PlaylistRecord) -> WirePlaylist {
    WirePlaylist(
        id: r.id ?? 0, remoteId: r.remoteId, serverId: r.serverId,
        title: r.title, trackCount: r.trackCount
    )
}

private func wire(_ m: RecommendationService.HomeMix) -> WireHomeMix {
    WireHomeMix(id: m.id, title: m.title, subtitle: m.subtitle, kind: m.kind,
                artworkKey: m.artworkKey, generatedAt: m.generatedAt)
}

private func wire(_ r: RecommendationSetRecord) -> WireRecommendationSet {
    WireRecommendationSet(id: r.id, title: r.title, kind: r.kind, generatedAt: r.generatedAt)
}

private func wire(_ r: RecommendationItemRecord) -> WireRecommendationItem {
    WireRecommendationItem(setId: r.setId, trackRef: r.trackRef, rank: r.rank,
                           score: r.score, inLibrary: r.inLibrary, reason: r.reason)
}

// MARK: - Session

/// One open library, owning the database pool for its lifetime.
final class MozzSession: @unchecked Sendable {
    let database: MusicDatabase
    let repository: LibraryRepository
    let recommendations: RecommendationService
    /// Servers this session has been given credentials for. Empty until the
    /// host calls `attach`; browsing a previously-synced library needs none.
    let backends = BackendTable()

    init(path: String) throws {
        self.database = try MusicDatabase.open(at: URL(fileURLWithPath: path))
        self.repository = LibraryRepository(database)
        self.recommendations = RecommendationService(store: RecommendationStore(database))
    }
}

/// What a command handler is allowed to touch. Response encoding lives here so
/// the two dispatch files cannot disagree about the envelope.
protocol SessionContext: AnyObject {
    var database: MusicDatabase { get }
    var repository: LibraryRepository { get }
    var recommendations: RecommendationService { get }
    var backends: BackendTable { get }
}

extension MozzSession: SessionContext {}

extension SessionContext {
    func success<P: Encodable>(_ request: SessionRequest, _ payload: P) -> String {
        sessionSuccess(request, payload)
    }

    func failure(_ request: SessionRequest, _ message: String) -> String {
        sessionFailure(request.id, request.cmd, message)
    }
}

/// Handles are integers rather than pointers: a C# `IntPtr` round-tripping a
/// Swift object pointer is easy to get subtly wrong, and an integer that indexes
/// a guarded table turns a use-after-free into a clean "unknown handle" error
/// instead of a crash.
private final class SessionRegistry: @unchecked Sendable {
    static let shared = SessionRegistry()
    private let lock = NSLock()
    private var sessions: [Int64: MozzSession] = [:]
    private var nextHandle: Int64 = 1

    func open(path: String) throws -> Int64 {
        let session = try MozzSession(path: path)
        lock.lock(); defer { lock.unlock() }
        let handle = nextHandle
        nextHandle += 1
        sessions[handle] = session
        return handle
    }

    func session(_ handle: Int64) -> MozzSession? {
        lock.lock(); defer { lock.unlock() }
        return sessions[handle]
    }

    func close(_ handle: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions.removeValue(forKey: handle) != nil
    }
}

// MARK: - Entry points

/// Open a library. Returns a positive handle, or 0 on failure.
@_cdecl("mozz_session_open")
public func mozz_session_open(_ dbPath: UnsafePointer<CChar>?) -> Int64 {
    guard let path = dbPath.map({ String(cString: $0) }), !path.isEmpty else { return 0 }
    return (try? SessionRegistry.shared.open(path: path)) ?? 0
}

/// Close a library. Returns 1 if the handle was live, 0 otherwise.
@_cdecl("mozz_session_close")
public func mozz_session_close(_ handle: Int64) -> Int32 {
    SessionRegistry.shared.close(handle) ? 1 : 0
}

/// Execute one command. The returned string is caller-owned; release it with
/// `mozz_ffi_free_string`.
@_cdecl("mozz_session_call")
public func mozz_session_call(
    _ handle: Int64,
    _ requestJSON: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let json = requestJSON.map({ String(cString: $0) }) else {
        return copySessionString(sessionFailure(nil, "", "no request"))
    }
    guard let request = try? JSONDecoder().decode(SessionRequest.self, from: Data(json.utf8)) else {
        return copySessionString(sessionFailure(nil, "", "malformed request"))
    }
    guard let session = SessionRegistry.shared.session(handle) else {
        return copySessionString(sessionFailure(request.id, request.cmd, "unknown session handle"))
    }

    // The dispatch layer deals only in `String`; the single C allocation happens
    // here, at the ABI edge. That also keeps the value crossing `runBlockingSession`
    // Sendable — an `UnsafeMutablePointer` is not, and hoisting it through the
    // task boundary is an error under the Swift 6 language mode.
    do {
        return copySessionString(try runBlockingSession { try await dispatch(request, session) })
    } catch {
        return copySessionString(sessionFailure(request.id, request.cmd, String(describing: error)))
    }
}

/// A malformed cursor is treated as "from the start" rather than an error: it
/// can only come from a client that mangled a token we gave it, and restarting
/// the listing is a better answer than refusing to show anything.
private func pageCursor(_ request: SessionRequest) -> LibraryRepository.PageCursor? {
    request.cursor.flatMap(LibraryRepository.PageCursor.init(token:))
}

// MARK: - Dispatch

private func dispatch(
    _ request: SessionRequest,
    _ session: MozzSession
) async throws -> String {
    let repo = session.repository
    let serverId = request.serverId
    // `offset` is gone from the big listings — they page by cursor now. It stays
    // on the request envelope only so an older client's message still decodes.
    // Capped so a malformed request cannot ask for the whole library in one
    // allocation; a UI pages, and 1,000 rows is already far more than a screen.
    let limit = min(max(1, request.limit ?? 100), 1_000)

    switch request.cmd {
    case "ping":
        return sessionSuccess(request, ["ok": true])

    case "servers":
        let servers = try await repo.servers().map {
            WireServer(id: $0.id, kind: $0.kind.rawValue, name: $0.name,
                       baseURL: $0.baseURL.absoluteString)
        }
        return sessionSuccess(request, servers)

    case "counts":
        let counts = WireCounts(
            artists: try await repo.artistCount(serverId: serverId),
            albums: try await repo.albumCount(serverId: serverId),
            tracks: try await repo.trackCount(serverId: serverId)
        )
        return sessionSuccess(request, counts)

    // The three big listings page by cursor, not offset. OFFSET is O(offset) and
    // is wrong whenever the table changes mid-walk, which is exactly what a
    // background sync does — see the note above the keyset methods in
    // LibraryRepository. An absent cursor means "from the start".
    case "artists":
        let page = try await repo.artistsPage(serverId: serverId, after: pageCursor(request), limit: limit)
        return sessionSuccess(request, page.rows.map(wire), nextCursor: page.next?.token)

    case "albums":
        let page = try await repo.albumsPage(serverId: serverId, after: pageCursor(request), limit: limit)
        return sessionSuccess(request, page.rows.map(wire), nextCursor: page.next?.token)

    case "tracks":
        let page = try await repo.tracksPage(serverId: serverId, after: pageCursor(request), limit: limit)
        return sessionSuccess(request, page.rows.map(wire), nextCursor: page.next?.token)

    case "artistAlbums":
        guard let remoteId = request.remoteId, let serverId else {
            return sessionFailure(request.id, request.cmd, "artistAlbums needs remoteId and serverId")
        }
        let rows = try await repo.albums(forArtistRemoteId: remoteId, serverId: serverId)
        return sessionSuccess(request, rows.map(wire))

    case "albumTracks":
        guard let serverId else {
            return sessionFailure(request.id, request.cmd, "albumTracks needs serverId")
        }
        // Prefer the group key: servers (Jellyfin especially) split one album
        // into several entities, and asking by remote id alone returns a slice.
        if let groupKey = request.groupKey {
            let rows = try await repo.tracks(forAlbumGroupKey: groupKey, serverId: serverId)
            return sessionSuccess(request, rows.map(wire))
        }
        guard let remoteId = request.remoteId else {
            return sessionFailure(request.id, request.cmd, "albumTracks needs remoteId or groupKey")
        }
        let rows = try await repo.tracks(forAlbumGroupContaining: remoteId, serverId: serverId)
        return sessionSuccess(request, rows.map(wire))

    case "playlists":
        guard let serverId else {
            return sessionFailure(request.id, request.cmd, "playlists needs serverId")
        }
        let rows = try await repo.allPlaylists(serverId: serverId)
        return sessionSuccess(request, rows.map(wire))

    case "playlistTracks":
        guard let remoteId = request.remoteId, let serverId else {
            return sessionFailure(request.id, request.cmd, "playlistTracks needs remoteId and serverId")
        }
        let rows = try await repo.tracks(forPlaylistRemoteId: remoteId, serverId: serverId)
        return sessionSuccess(request, rows.map(wire))

    case "recentlyAddedAlbums":
        guard let serverId else {
            return sessionFailure(request.id, request.cmd, "recentlyAddedAlbums needs serverId")
        }
        let rows = try await repo.recentlyAddedAlbums(serverId: serverId, limit: limit)
        return sessionSuccess(request, rows.map(wire))

    case "recentlyPlayedTracks":
        guard let serverId else {
            return sessionFailure(request.id, request.cmd, "recentlyPlayedTracks needs serverId")
        }
        let rows = try await repo.recentlyPlayedTracks(serverId: serverId, limit: limit)
        return sessionSuccess(request, rows.map(wire))

    case "likedTracks":
        let rows = try await repo.likedTracks(serverId: serverId, limit: limit)
        return sessionSuccess(request, rows.map(wire))

    case "genres":
        guard let serverId else {
            return sessionFailure(request.id, request.cmd, "genres needs serverId")
        }
        return sessionSuccess(request, try await repo.genres(serverId: serverId))

    case "genreAlbums":
        guard let genre = request.genre, let serverId else {
            return sessionFailure(request.id, request.cmd, "genreAlbums needs genre and serverId")
        }
        let rows = try await repo.albums(forGenre: genre, serverId: serverId)
        return sessionSuccess(request, rows.map(wire))

    case "search":
        guard let query = request.query else {
            return sessionFailure(request.id, request.cmd, "search needs query")
        }
        let results = try await repo.search(query, serverId: serverId, limitPerType: limit)
        return sessionSuccess(request, WireSearchResults(
            artists: results.artists.map(wire),
            albums: results.albums.map(wire),
            tracks: results.tracks.map(wire)
        ))

    case "homeMixes":
        let mixes = try await session.recommendations.homeMixes().map(wire)
        return sessionSuccess(request, mixes)

    case "generateHomeMixes":
        guard let serverId else {
            return sessionFailure(request.id, request.cmd, "generateHomeMixes needs serverId")
        }
        try await session.recommendations.generateHomeMixes(serverId: serverId, seed: request.seed)
        return sessionSuccess(request, WireAction(ok: true))

    case "mix":
        guard let setId = request.setId else {
            return sessionFailure(request.id, request.cmd, "mix needs setId")
        }
        guard let set = try await session.recommendations.set(id: setId) else {
            return sessionFailure(request.id, request.cmd, "mix not found: \(setId)")
        }
        return sessionSuccess(request, wire(set))

    case "mixTracks":
        guard let setId = request.setId else {
            return sessionFailure(request.id, request.cmd, "mixTracks needs setId")
        }
        let rows = try await session.recommendations.tracks(forSetId: setId)
        return sessionSuccess(request, rows.map(wire))

    case "generateMozzWeekly":
        guard let serverId else {
            return sessionFailure(request.id, request.cmd, "generateMozzWeekly needs serverId")
        }
        let set = try await session.recommendations.generateMozzWeekly(serverId: serverId, limit: limit, seed: request.seed)
        return sessionSuccess(request, wire(set))

    case "mozzWeeklyTracks":
        let rows = try await session.recommendations.mozzWeeklyTracks()
        return sessionSuccess(request, rows.map(wire))

    case "mozzWeeklyItems":
        let rows = try await session.recommendations.mozzWeeklyItems()
        return sessionSuccess(request, rows.map(wire))

    case "radioBatch":
        guard let serverId else {
            return sessionFailure(request.id, request.cmd, "radioBatch needs serverId")
        }
        let seed = RadioSeed(title: request.seedTitle ?? "Radio",
                             genres: request.seedGenres ?? [],
                             artistIds: request.seedArtistIds ?? [],
                             seedTrackRef: request.seedTrackRef)
        let remoteIds = try await session.recommendations.radioBatch(
            seed: seed, serverId: serverId, limit: limit, excluding: Set(request.excluding ?? []))
        var tracks: [WireTrack] = []
        tracks.reserveCapacity(remoteIds.count)
        for remoteId in remoteIds {
            if let track = try await repo.track(serverId: serverId, remoteId: remoteId) {
                tracks.append(wire(track))
            }
        }
        return sessionSuccess(request, WireRadioBatch(remoteIds: remoteIds, tracks: tracks))

    case "suppressTrack":
        guard let remoteId = request.remoteId, let serverId else {
            return sessionFailure(request.id, request.cmd, "suppressTrack needs remoteId and serverId")
        }
        try await session.recommendations.suppressTrack(remoteId: remoteId, serverId: serverId)
        return sessionSuccess(request, WireAction(ok: true))

    case "suppressArtist":
        guard let remoteId = request.remoteId, let serverId else {
            return sessionFailure(request.id, request.cmd, "suppressArtist needs remoteId and serverId")
        }
        try await session.recommendations.suppressArtist(remoteId: remoteId, serverId: serverId)
        return sessionSuccess(request, WireAction(ok: true))

    case "unsuppressTrack":
        guard let remoteId = request.remoteId, let serverId else {
            return sessionFailure(request.id, request.cmd, "unsuppressTrack needs remoteId and serverId")
        }
        try await session.recommendations.unsuppressTrack(remoteId: remoteId, serverId: serverId)
        return sessionSuccess(request, WireAction(ok: true))

    case "unsuppressArtist":
        guard let remoteId = request.remoteId, let serverId else {
            return sessionFailure(request.id, request.cmd, "unsuppressArtist needs remoteId and serverId")
        }
        try await session.recommendations.unsuppressArtist(remoteId: remoteId, serverId: serverId)
        return sessionSuccess(request, WireAction(ok: true))

    case "suppressions":
        guard let serverId else {
            return sessionFailure(request.id, request.cmd, "suppressions needs serverId")
        }
        let rows = try await session.recommendations.suppressions(serverId: serverId)
            .map { WireSuppression(scope: $0.scope, ref: $0.ref, createdAt: $0.createdAt) }
        return sessionSuccess(request, rows)

    default:
        // Not a catalog command — try the server/sync/streaming table before
        // declaring it unknown, so both halves share one envelope and one error.
        if let response = try await dispatchServerCommand(request, session) { return response }
        return sessionFailure(request.id, request.cmd, unknownCommandMessage(request.cmd))
    }
}

/// Every command the dispatcher accepts.
///
/// Kept beside the error rather than derived from the switch, because Swift
/// cannot enumerate a switch — so the honest thing is to admit the list is
/// hand-maintained and make the failure it protects against loud.
let mozzSessionCommands = [
    "ping", "servers", "counts", "artists", "albums", "tracks",
    "artistAlbums", "albumTracks", "playlists", "playlistTracks",
    "recentlyAddedAlbums", "recentlyPlayedTracks", "likedTracks",
    "genres", "genreAlbums", "search", "homeMixes", "generateHomeMixes",
    "mix", "mixTracks", "generateMozzWeekly", "mozzWeeklyTracks",
    "mozzWeeklyItems", "radioBatch", "suppressTrack", "suppressArtist",
    "unsuppressTrack", "unsuppressArtist", "suppressions",
    "connect", "plexPin", "plexPinCheck", "attach", "libraries",
    "sync", "syncStatus", "streamURL", "artworkURL",
].sorted()

/// A wrong command name is one of the few mistakes that can only be made across
/// the FFI boundary, and it is invisible: a client written in another language
/// gets "unknown command" and no indication that it is one capital letter away
/// from working. `streamUrl` for `streamURL` cost real time, so the error now
/// names the near miss.
func unknownCommandMessage(_ cmd: String) -> String {
    let lowered = cmd.lowercased()
    if let match = mozzSessionCommands.first(where: { $0.lowercased() == lowered }) {
        return "unknown command '\(cmd)' — did you mean '\(match)'? (case matters)"
    }
    let prefixed = mozzSessionCommands.filter {
        $0.lowercased().hasPrefix(lowered.prefix(4)) || lowered.hasPrefix($0.lowercased().prefix(4))
    }
    if !prefixed.isEmpty {
        return "unknown command '\(cmd)' — did you mean \(prefixed.map { "'\($0)'" }.joined(separator: " or "))?"
    }
    return "unknown command '\(cmd)' — known commands: \(mozzSessionCommands.joined(separator: ", "))"
}

// MARK: - Response helpers

func sessionSuccess<P: Encodable>(
    _ request: SessionRequest,
    _ payload: P,
    nextCursor: String? = nil
) -> String {
    encodeSession(SessionResponse(id: request.id, ok: true, cmd: request.cmd,
                                  payload: payload, error: nil, nextCursor: nextCursor))
}

func sessionFailure(
    _ id: Int?,
    _ cmd: String,
    _ message: String
) -> String {
    encodeSession(SessionResponse<String>(id: id, ok: false, cmd: cmd,
                                          payload: nil, error: message, nextCursor: nil))
}

private func encodeSession<P: Encodable>(_ response: SessionResponse<P>) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(response),
          let json = String(data: data, encoding: .utf8) else {
        return #"{"ok":false,"error":"failed to encode response"}"#
    }
    return json
}

private func copySessionString(_ string: String) -> UnsafeMutablePointer<CChar>? {
    let bytes = Array(string.utf8CString)
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
    buffer.update(from: bytes, count: bytes.count)
    return buffer
}

// MARK: - async bridge

private final class SessionResultBox<T>: @unchecked Sendable {
    var result: Result<T, any Error>?
}

/// Bridges async to the synchronous C ABI.
///
/// Still a parked thread, and still not something a UI thread should call
/// directly — clients must dispatch these off their main thread. A callback or
/// polled-completion API is the eventual answer, but every call here is a
/// database read measured in single-digit milliseconds, so the simpler shape
/// buys correctness now and can change without the request format moving.
private func runBlockingSession<T: Sendable>(
    _ body: @escaping @Sendable () async throws -> T
) throws -> T {
    let box = SessionResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await body()) }
        catch { box.result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    switch box.result {
    case .success(let value): return value
    case .failure(let error): throw error
    case nil: throw MozzError.invalidResponse
    }
}
