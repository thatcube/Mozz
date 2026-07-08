import Foundation
import MozzCore
import MozzNetworking

/// A ``MusicBackend`` for Subsonic / OpenSubsonic servers.
///
/// v1 is scoped/QA'd against Navidrome; other OpenSubsonic servers (Gonic,
/// Ampache, LMS) are best-effort — the wire protocol is generic, so
/// server-specific quirks surface as runtime capability differences
/// (``detectCapabilities()``), never as a separate `BackendKind` or conformer.
///
/// Immutable value type holding only connection config + a signed
/// ``SubsonicClient``, so it is `Sendable` and cheap to hand to the sync,
/// playback and download domains — mirrors ``JellyfinBackend``'s shape.
public struct SubsonicBackend: MusicBackend {
    public let connection: ServerConnection
    private let client: SubsonicClient
    /// The music folder to scope catalog queries to (mirrors Plex
    /// `musicSectionID` / Jellyfin `musicLibraryId`) — reuses
    /// `ServerConnection.musicSectionID` as Subsonic's `musicFolderId`
    /// (architecture point 11). `nil` syncs every folder the account can see,
    /// which is correct for the common case of a server with a single
    /// (implicit) folder.
    private let musicFolderId: String?

    /// `getAlbumList2` walk page size for the bulk track enumerator's
    /// upfront album-listing pass (see ``enumerateAllTracks(pageSize:)``).
    /// Independent of the caller's requested *track*-yield page size — this
    /// controls only how the album metadata itself is paged in.
    private static let albumWalkPageSize = 500

    /// Containers/codecs AVFoundation plays natively, so Mozz asks the server
    /// for the untouched original (`format=raw`) rather than paying a
    /// transcode's latency/CPU cost and losing gapless precision. Everything
    /// else (opus, ogg, wma, …) — or a track requested under a bitrate cap —
    /// transcodes to AAC (architecture point 7).
    private static let directPlayContainers: Set<String> = ["mp3", "aac", "m4a", "alac", "flac", "wav"]

    public init(
        connection: ServerConnection,
        token: String,
        transport: any HTTPTransport = URLSessionTransport()
    ) throws {
        self.connection = connection
        let credential = try SubsonicCredential.decoded(from: token)
        self.client = try SubsonicClient(baseURL: connection.baseURL, credential: credential, transport: transport)
        self.musicFolderId = connection.musicSectionID
    }

    private var musicFolderQuery: [URLQueryItem] {
        guard let musicFolderId else { return [] }
        return [URLQueryItem(name: "musicFolderId", value: musicFolderId)]
    }

    // MARK: Capabilities

    public func detectCapabilities() async throws -> ServerCapabilities {
        let response = try await client.call("ping")
        // getOpenSubsonicExtensions is BEST-EFFORT (architecture point 10):
        // many classic-profile servers 404 it entirely — a normal "no
        // extensions" outcome, not a failed probe, so any error (404 or
        // otherwise) is swallowed rather than surfaced.
        let extensionNames: Set<String>
        if let extensions = try? await client.call("getOpenSubsonicExtensions").openSubsonicExtensions {
            extensionNames = Set(extensions.map(\.name))
        } else {
            extensionNames = []
        }
        let isOpenSubsonic = (response.openSubsonic ?? false) || !extensionNames.isEmpty
        return ServerCapabilities(
            backend: .subsonic,
            serverVersion: response.serverVersion ?? response.version,
            supportsTranscoding: true,
            supportsOriginalFileDownload: true,
            // Subsonic uniquely supports BOTH concepts at once (unlike Plex,
            // which only has ratings, and Jellyfin, which only has
            // favorites): star/unstar -> favorites, setRating -> ratings.
            supportsFavorites: true,
            supportsRatings: true,
            // Diagnostic-only in v1: OUT OF SCOPE explicitly excludes a
            // lyrics fetch/UI path, but gating this on the detected
            // extension keeps the Diagnostics screen honest about what the
            // server actually offers.
            supportsLyrics: extensionNames.contains("songLyrics"),
            supportsSyncedLyrics: false,
            // `replayGain` is an OpenSubsonic `Child` field; classic-profile
            // servers never send it.
            supportsNormalizationGain: isOpenSubsonic,
            supportsProgressReporting: true,
            serverProduct: response.type,
            isOpenSubsonic: isOpenSubsonic
        )
    }

    // MARK: Catalog enumeration

    public func fetchArtists(offset: Int, limit: Int) async throws -> CatalogPage<Artist> {
        // getArtists has no true offset/size pagination — it always returns
        // the WHOLE alphabetically-indexed list in one response. Refetching
        // it on every "page" is wasteful but simple and correct: this listing
        // is a relatively cheap query even for a huge library (unlike
        // per-song metadata), and the artists phase runs once per sync, not
        // once per track.
        let response = try await client.call("getArtists", query: musicFolderQuery)
        let all = (response.artists?.index ?? []).flatMap { $0.artist ?? [] }
        let slice = all.dropFirst(offset).prefix(limit)
        return CatalogPage(items: slice.map(SubsonicMapper.artist), totalCount: all.count)
    }

    public func fetchAlbums(offset: Int, limit: Int) async throws -> CatalogPage<Album> {
        let response = try await client.call("getAlbumList2", query: [
            URLQueryItem(name: "type", value: "alphabeticalByArtist"),
            URLQueryItem(name: "size", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
        ] + musicFolderQuery)
        let albums = response.albumList2?.album ?? []
        // getAlbumList2 carries no total-record-count field (unlike
        // Jellyfin's `TotalRecordCount`) — the flat pager already tolerates a
        // nil total (it pages until a short/empty page), so there's nothing
        // meaningful to report here.
        return CatalogPage(items: albums.map(SubsonicMapper.album), totalCount: nil)
    }

    /// The bounded, NON-authoritative flat track pager. Used ONLY by the
    /// quick-start slice (see ``hasBulkEnumerator``/``enumerateAllTracks(pageSize:)``)
    /// and any other direct caller — the real, prune-safe full sync always
    /// prefers ``enumerateAllTracks(pageSize:)`` instead.
    ///
    /// Backed by `search3` with an empty query — an OpenSubsonic-documented
    /// "browse everything" idiom, but one whose ordering/pagination stability
    /// is NOT guaranteed the way `getAlbumList2`'s is (architecture point 2).
    /// A server that rejects/ignores an empty query degrades to an empty
    /// page rather than throwing: this path is explicitly optional and
    /// best-effort ("per-server-probed" — probed by actual use rather than a
    /// separate preflight call), and swallowing the error here just skips the
    /// fast preview; the real full sync is entirely unaffected since it never
    /// calls `search3`.
    public func fetchTracks(offset: Int, limit: Int) async throws -> CatalogPage<Track> {
        do {
            let response = try await client.call("search3", query: [
                URLQueryItem(name: "query", value: ""),
                URLQueryItem(name: "songCount", value: "\(limit)"),
                URLQueryItem(name: "songOffset", value: "\(offset)"),
                URLQueryItem(name: "artistCount", value: "0"),
                URLQueryItem(name: "albumCount", value: "0"),
            ] + musicFolderQuery)
            let songs = response.searchResult3?.song ?? []
            return CatalogPage(items: songs.map(SubsonicMapper.track), totalCount: nil)
        } catch {
            return CatalogPage(items: [], totalCount: nil)
        }
    }

    public func fetchPlaylists(offset: Int, limit: Int) async throws -> CatalogPage<Playlist> {
        // getPlaylists is a one-shot, unpaginated list — like getArtists —
        // but playlist counts are typically small (dozens, not thousands), so
        // slicing one full fetch is cheap.
        let response = try await client.call("getPlaylists")
        let all = response.playlists?.playlist ?? []
        let slice = all.dropFirst(offset).prefix(limit)
        return CatalogPage(items: slice.map(SubsonicMapper.playlist), totalCount: all.count)
    }

    public func fetchPlaylistItems(playlistID: String, offset: Int, limit: Int) async throws -> CatalogPage<Track> {
        let response = try await client.call("getPlaylist", query: [URLQueryItem(name: "id", value: playlistID)])
        let all = response.playlist?.entry ?? []
        let slice = all.dropFirst(offset).prefix(limit)
        return CatalogPage(items: slice.map(SubsonicMapper.track), totalCount: all.count)
    }

    // MARK: Bulk enumeration (authoritative, prune-safe)

    public var hasBulkEnumerator: Bool { true }

    /// The authoritative, whole-catalog track enumeration (architecture point
    /// 2): walk `getAlbumList2` fully to build an ordered album plan (stable
    /// order + a derivable expected total = the sum of every album's
    /// `songCount`, or `nil` if even one album omits it — see architecture
    /// point 3), then walk each album's songs via `getAlbum`, deduping by
    /// song id (a song can legitimately be cross-linked from more than one
    /// album listing) and yielding fixed-size batches that all carry the SAME
    /// precomputed total.
    ///
    /// `search3(query: "")` (see ``fetchTracks(offset:limit:)``) is
    /// deliberately NEVER used here: its ordering/pagination stability isn't
    /// guaranteed, so it must never be trusted to authorize a prune.
    public func enumerateAllTracks(pageSize: Int) -> AsyncThrowingStream<BulkTrackPage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Phase 1: enumerate every album (id + songCount) in the
                    // stable alphabetical-by-artist order. Small per-album
                    // metadata only — cheap even for a huge library.
                    var albums: [AlbumID3DTO] = []
                    var offset = 0
                    while true {
                        try Task.checkCancellation()
                        let response = try await client.call("getAlbumList2", query: [
                            URLQueryItem(name: "type", value: "alphabeticalByArtist"),
                            URLQueryItem(name: "size", value: "\(Self.albumWalkPageSize)"),
                            URLQueryItem(name: "offset", value: "\(offset)"),
                        ] + musicFolderQuery)
                        let page = response.albumList2?.album ?? []
                        if page.isEmpty { break }
                        albums.append(contentsOf: page)
                        offset += page.count
                        if page.count < Self.albumWalkPageSize { break }
                    }

                    // A derivable total requires EVERY album to report a
                    // songCount; one missing count makes the sum unknowable,
                    // and an unknown total must never authorize a prune (see
                    // LibrarySyncEngine.phaseCompleted's `requiresKnownTotal`).
                    let expectedTotal: Int? = albums.reduce(Optional(0)) { partial, album in
                        guard let partial, let count = album.songCount else { return nil }
                        return partial + count
                    }

                    var seenSongIDs = Set<String>()
                    var pending: [Track] = []
                    pending.reserveCapacity(pageSize)
                    func flush(force: Bool = false) {
                        guard force ? !pending.isEmpty : pending.count >= pageSize else { return }
                        continuation.yield(CatalogPage(items: pending, totalCount: expectedTotal))
                        pending.removeAll(keepingCapacity: true)
                    }

                    // Phase 2: walk each album's songs in the SAME order,
                    // deduping by song id.
                    for album in albums {
                        try Task.checkCancellation()
                        let response = try await client.call("getAlbum", query: [
                            URLQueryItem(name: "id", value: album.id),
                        ])
                        for song in response.album?.song ?? [] {
                            guard seenSongIDs.insert(song.id).inserted else { continue }
                            pending.append(SubsonicMapper.track(song))
                            flush()
                        }
                    }
                    flush(force: true)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Playback & downloads

    private func isDirectPlayFriendly(_ track: Track) -> Bool {
        guard let container = track.format.container?.lowercased() else { return false }
        return Self.directPlayContainers.contains(container)
    }

    public func streamSource(for track: Track, options: StreamOptions) async throws -> StreamSource {
        let direct = !options.forceTranscode && options.maxBitrateKbps == nil && isDirectPlayFriendly(track)
        var query: [URLQueryItem] = [URLQueryItem(name: "id", value: track.id)]
        if direct {
            // `format=raw` is the well-known Subsonic-client idiom to force
            // the untouched original regardless of the server's own
            // (per-user-configurable) default transcoding preference — direct
            // play must be a client decision, not a server guess.
            query.append(URLQueryItem(name: "format", value: "raw"))
        } else {
            query.append(URLQueryItem(name: "format", value: "aac"))
            if let maxBitrate = options.maxBitrateKbps {
                query.append(URLQueryItem(name: "maxBitRate", value: "\(maxBitrate)"))
            }
        }
        let url = try client.signedURL(action: "stream", query: query)
        return StreamSource(url: url, isTranscoded: !direct, sessionID: nil)
    }

    public func originalFileURL(for track: Track) throws -> URL {
        try client.signedURL(action: "download", query: [URLQueryItem(name: "id", value: track.id)])
    }

    public func artworkURL(for artwork: ArtworkRef, size: Int) -> URL? {
        try? client.signedURL(action: "getCoverArt", query: [
            URLQueryItem(name: "id", value: artwork.key),
            URLQueryItem(name: "size", value: "\(size)"),
        ])
    }

    // MARK: Writes

    public func setFavorite(_ isFavorite: Bool, itemID: String, type: CatalogItemType) async throws {
        guard type != .playlist else {
            throw MozzError.unsupported("Subsonic playlists don't support favorites.")
        }
        _ = try await client.call(isFavorite ? "star" : "unstar", query: [
            URLQueryItem(name: "id", value: itemID),
        ])
    }

    public func setRating(_ stars: Double?, itemID: String, type: CatalogItemType) async throws {
        guard type != .playlist else {
            throw MozzError.unsupported("Subsonic playlists don't support ratings.")
        }
        // Subsonic ratings are whole stars 1-5 (0 clears) — no half-star
        // granularity, so this is a lossy round, not a rescale.
        let rating = stars.map { Int($0.rounded()) } ?? 0
        _ = try await client.call("setRating", query: [
            URLQueryItem(name: "id", value: itemID),
            URLQueryItem(name: "rating", value: "\(rating)"),
        ])
    }

    public func reportPlayback(_ report: PlaybackReport) async throws {
        // `submission=true` records a real scrobble; Mozz only sends one on a
        // definitive "this play ended" (`.stopped`) rather than inferring a
        // completion threshold here. Every other state is a lightweight
        // "now playing" ping (`submission=false`) so a server's "currently
        // playing"/last-played views stay live without over-counting plays.
        let isSubmission = report.state == .stopped
        _ = try await client.call("scrobble", query: [
            URLQueryItem(name: "id", value: report.track.id),
            URLQueryItem(name: "time", value: "\(Int64(Date().timeIntervalSince1970 * 1000))"),
            URLQueryItem(name: "submission", value: isSubmission ? "true" : "false"),
        ])
    }
}
