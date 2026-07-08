import Foundation
import MozzCore
import MozzNetworking

/// A ``MusicBackend`` for generic Subsonic / OpenSubsonic servers (QA'd against
/// Navidrome; Gonic/Ampache/LMS best-effort).
///
/// Immutable `Sendable` value type holding only connection config + a
/// ``SubsonicClient`` (which owns signing/decoding/validation), so it is cheap
/// to hand to the sync, playback and download domains. It resolves URLs and
/// decodes JSON; it never transfers audio bytes itself.
///
/// Sync strategy (spec items 2–4): the authoritative catalog enumeration is an
/// **album-walk** — ``enumerateAllTracks(pageSize:)`` walks `getAlbumList2` then
/// `getAlbum` per album — which yields a stable order, deduplicated songs, and a
/// *provable* expected total (the sum of album song counts) that gates pruning.
/// The flat ``fetchTracks(offset:limit:)`` path is a `search3` quick-start
/// fast-path only and NEVER reports a total (so it can never authorize a prune).
public struct SubsonicBackend: MusicBackend {
    public let connection: ServerConnection
    private let client: SubsonicClient
    /// Optional `musicFolderId` scoping (spec item 11); persisted in the generic
    /// ``ServerConnection/musicSectionID`` slot. No picker UI in v1 — this is the
    /// wired seam.
    private let musicFolderId: String?

    /// Containers iOS/AVFoundation plays directly, so we request `format=raw`
    /// (no transcode) and preserve gapless + original quality. Everything else
    /// (opus/ogg/wma or unknown) transcodes to aac (spec item 7).
    private static let directPlayContainers: Set<String> = [
        "mp3", "aac", "m4a", "alac", "flac", "wav", "aiff", "aif", "caf",
    ]

    public init(
        connection: ServerConnection,
        credential: SubsonicCredential,
        clientInfo: ClientInfo,
        transport: any HTTPTransport = URLSessionTransport(),
        musicFolderId: String? = nil,
        logger: any NetworkLogger = NoopNetworkLogger()
    ) {
        self.connection = connection
        self.musicFolderId = musicFolderId ?? connection.musicSectionID
        self.client = SubsonicClient(
            baseURL: connection.baseURL,
            credential: credential,
            clientInfo: clientInfo,
            transport: transport,
            logger: logger
        )
    }

    // MARK: Capabilities

    public func detectCapabilities() async throws -> ServerCapabilities {
        // `ping` is authoritative: it validates the chosen auth and carries the
        // server product/version + the OpenSubsonic flag.
        let ping = try await client.send("ping", as: SubsonicEmpty.self)
        let product = ping.type
        let serverVersion = ping.serverVersion ?? ping.version
        let openSubsonic = ping.openSubsonic ?? false

        // `getOpenSubsonicExtensions` is BEST-EFFORT: a 404 (classic Subsonic)
        // means "classic profile", NOT a detection failure — so it must never
        // fail capability detection (spec item 10).
        var extensions: Set<String> = []
        if openSubsonic,
           let ext = try? await client.send(
               "getOpenSubsonicExtensions",
               as: SubsonicOpenExtensionsPayload.self
           ) {
            for e in ext.payload.openSubsonicExtensions ?? [] {
                if let name = e.name { extensions.insert(name) }
            }
        }

        return ServerCapabilities(
            backend: .subsonic,
            serverVersion: serverVersion,
            supportsTranscoding: true,
            supportsOriginalFileDownload: true,
            supportsFavorites: true,          // star/unstar
            supportsRatings: true,            // setRating 1–5
            supportsLyrics: extensions.contains("songLyrics"),
            supportsSyncedLyrics: false,      // no lyric fetch/UI path in v1 scope
            supportsNormalizationGain: openSubsonic, // replayGain is OpenSubsonic
            supportsProgressReporting: true,  // scrobble
            serverProduct: product,
            isOpenSubsonic: openSubsonic
        )
    }

    // MARK: Catalog enumeration

    public func fetchArtists(offset: Int, limit: Int) async throws -> CatalogPage<Artist> {
        // getArtists returns the WHOLE indexed artist list in one call; slice it
        // to satisfy the engine's offset/limit paging.
        let body = try await client.send(
            "getArtists", query: musicFolderQuery(), as: SubsonicArtistsPayload.self
        )
        let all = (body.payload.artists?.index ?? [])
            .flatMap { $0.artist ?? [] }
            .map(SubsonicMapper.artist)
            .filter { !$0.id.isEmpty }
        return CatalogPage(items: Self.slice(all, offset: offset, limit: limit), totalCount: all.count)
    }

    public func fetchAlbums(offset: Int, limit: Int) async throws -> CatalogPage<Album> {
        // getAlbumList2 pages natively via size/offset (server caps size at 500;
        // a short page is not terminal for the engine, only an empty one is).
        let size = min(max(limit, 1), 500)
        let body = try await client.send("getAlbumList2", query: [
            URLQueryItem(name: "type", value: "alphabeticalByName"),
            URLQueryItem(name: "size", value: "\(size)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
        ] + musicFolderQuery(), as: SubsonicAlbumList2Payload.self)
        let albums = (body.payload.albumList2?.album ?? [])
            .map(SubsonicMapper.album)
            .filter { !$0.id.isEmpty }
        // No reliable total for getAlbumList2; a full album enumeration to
        // exhaustion is still complete for the (non-empty ⇒ complete) prune
        // default, and pruning is ultimately gated by the strict tracks phase.
        return CatalogPage(items: albums, totalCount: nil)
    }

    public func fetchTracks(offset: Int, limit: Int) async throws -> CatalogPage<Track> {
        // search3(query="") is a QUICK-START fast path only. It is unstable
        // (window can shift as the library changes) and MUST NEVER report a
        // total, so it can never authorize a prune (spec item 2). The prune-safe
        // authoritative path is `enumerateAllTracks` (album-walk).
        do {
            let body = try await client.send("search3", query: [
                URLQueryItem(name: "query", value: ""),
                URLQueryItem(name: "songCount", value: "\(limit)"),
                URLQueryItem(name: "songOffset", value: "\(offset)"),
                URLQueryItem(name: "artistCount", value: "0"),
                URLQueryItem(name: "albumCount", value: "0"),
            ] + musicFolderQuery(), as: SubsonicSearchResult3Payload.self)
            let songs = (body.payload.searchResult3?.song ?? [])
                .map(SubsonicMapper.track)
                .filter { !$0.id.isEmpty }
            return CatalogPage(items: songs, totalCount: nil)
        } catch let error as MozzError {
            // Best-effort quick start: swallow a server's *semantic* rejection of
            // the empty-query probe (some classic servers) and yield no slice —
            // the album-walk remains authoritative. Reachability / auth /
            // cancellation still propagate.
            switch error {
            case .unauthorized, .cancelled, .serverUnreachable, .transport:
                throw error
            default:
                return CatalogPage(items: [], totalCount: nil)
            }
        }
    }

    public func fetchPlaylists(offset: Int, limit: Int) async throws -> CatalogPage<Playlist> {
        let body = try await client.send("getPlaylists", as: SubsonicPlaylistsPayload.self)
        let all = (body.payload.playlists?.playlist ?? [])
            .map(SubsonicMapper.playlist)
            .filter { !$0.id.isEmpty }
        return CatalogPage(items: Self.slice(all, offset: offset, limit: limit), totalCount: all.count)
    }

    public func fetchPlaylistItems(playlistID: String, offset: Int, limit: Int) async throws -> CatalogPage<Track> {
        let body = try await client.send(
            "getPlaylist",
            query: [URLQueryItem(name: "id", value: playlistID)],
            as: SubsonicPlaylistPayload.self
        )
        let all = (body.payload.playlist?.entry ?? [])
            .map(SubsonicMapper.track)
            .filter { !$0.id.isEmpty }
        return CatalogPage(items: Self.slice(all, offset: offset, limit: limit), totalCount: all.count)
    }

    /// Prune-safe bulk enumeration (spec items 2–4). Walks the album list to
    /// build a stable, ordered album set and a derivable expected total (the sum
    /// of per-album song counts, but only when EVERY album reports one), then
    /// fetches each album's songs, deduplicated by song id, buffered into pages.
    /// The expected total is the completeness proof the sync engine requires
    /// before it will prune (protecting offline downloads); when it can't be
    /// derived, pages carry `totalCount == nil` and the engine will NOT prune.
    public func enumerateAllTracks(pageSize: Int) -> AsyncThrowingStream<CatalogPage<Track>, any Error>? {
        enumerateAllTracks(pageSize: pageSize, albumWindow: 500)
    }

    /// Testable core of the album-walk enumerator. `albumWindow` is the
    /// getAlbumList2 page size (500 in production); exposing it internally lets
    /// tests drive multi-page pagination with small fixtures and prove that an
    /// empty-id album inside a *full* window never truncates the walk.
    func enumerateAllTracks(pageSize: Int, albumWindow: Int) -> AsyncThrowingStream<CatalogPage<Track>, any Error>? {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    // Phase 1: enumerate every album (id + songCount).
                    let listSize = albumWindow
                    var albumIDs: [String] = []
                    var songCounts: [Int?] = []
                    var offset = 0
                    while true {
                        try Task.checkCancellation()
                        let page = try await albumListPage(size: listSize, offset: offset)
                        albumIDs.append(contentsOf: page.ids)
                        songCounts.append(contentsOf: page.counts)
                        // Advance offset and decide termination by the RAW server
                        // count, never the post-filter id count. A full window that
                        // happens to contain an empty-id album still filters shorter,
                        // and treating that as terminal would silently drop every
                        // later page — and, because the derived expected total would
                        // then match the truncated set, green-light a prune that
                        // deletes unseen tracks and their offline downloads. Only a
                        // genuinely short/empty server window is terminal.
                        offset += page.rawCount
                        if page.rawCount < listSize { break }
                    }

                    // Expected total = Σ songCount, but ONLY when every album
                    // reported a count. Missing even one makes it unprovable, so
                    // we send nil (⇒ engine will not prune).
                    let expectedTotal: Int? = songCounts.allSatisfy { $0 != nil }
                        ? songCounts.reduce(0) { $0 + ($1 ?? 0) }
                        : nil

                    // Phase 2: walk albums in order, dedup songs by id, page.
                    var buffer: [Track] = []
                    var seen = Set<String>()
                    for id in albumIDs {
                        try Task.checkCancellation()
                        let songs = try await albumSongs(albumID: id)
                        for song in songs {
                            let track = SubsonicMapper.track(song)
                            guard !track.id.isEmpty, seen.insert(track.id).inserted else { continue }
                            buffer.append(track)
                            if buffer.count >= pageSize {
                                continuation.yield(CatalogPage(items: buffer, totalCount: expectedTotal))
                                buffer.removeAll(keepingCapacity: true)
                            }
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(CatalogPage(items: buffer, totalCount: expectedTotal))
                    } else if albumIDs.isEmpty {
                        // Empty library: emit one empty page carrying the (0)
                        // expected total so completeness can still be proven.
                        continuation.yield(CatalogPage(items: [], totalCount: expectedTotal))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    // MARK: Playback & downloads

    public func streamSource(for track: Track, options: StreamOptions) async throws -> StreamSource {
        let container = (track.format.container ?? "").lowercased()
        let directPlayable = Self.directPlayContainers.contains(container)
        // Transcode only when we must: an unsupported/unknown container, a forced
        // transcode, or an explicit bitrate cap. Otherwise `format=raw` preserves
        // gapless playback + original quality (spec item 7).
        let transcode = options.forceTranscode || options.maxBitrateKbps != nil || !directPlayable
        var query = [URLQueryItem(name: "id", value: track.id)]
        if transcode {
            query.append(URLQueryItem(name: "format", value: "aac"))
            if let maxBitrate = options.maxBitrateKbps {
                query.append(URLQueryItem(name: "maxBitRate", value: "\(maxBitrate)"))
            }
        } else {
            query.append(URLQueryItem(name: "format", value: "raw"))
        }
        guard let url = client.mediaURL("stream", query: query) else {
            throw MozzError.invalidResponse
        }
        // Subsonic scrobbles by track id + time (no server-issued session id).
        return StreamSource(url: url, isTranscoded: transcode, sessionID: nil)
    }

    public func originalFileURL(for track: Track) throws -> URL {
        guard let url = client.mediaURL("download", query: [
            URLQueryItem(name: "id", value: track.id),
        ]) else {
            throw MozzError.invalidResponse
        }
        return url
    }

    public func artworkURL(for artwork: ArtworkRef, size: Int) -> URL? {
        // Signed via the stable salt/apiKey, so the URL is deterministic across
        // launches and the artwork cache (keyed on the resolved URL) doesn't
        // thrash (spec item 8).
        client.mediaURL("getCoverArt", query: [
            URLQueryItem(name: "id", value: artwork.key),
            URLQueryItem(name: "size", value: "\(size)"),
        ])
    }

    // MARK: Writes

    public func setFavorite(_ isFavorite: Bool, itemID: String, type: CatalogItemType) async throws {
        let name = isFavorite ? "star" : "unstar"
        // star/unstar take the id under a type-specific param.
        let param: String
        switch type {
        case .artist: param = "artistId"
        case .album:  param = "albumId"
        case .track, .playlist: param = "id"
        }
        _ = try await client.send(name, query: [URLQueryItem(name: param, value: itemID)], as: SubsonicEmpty.self)
    }

    public func setRating(_ stars: Double?, itemID: String, type: CatalogItemType) async throws {
        // Subsonic setRating is an integer 0–5 (0 clears the rating).
        let value = Int((stars ?? 0).rounded())
        let clamped = min(5, max(0, value))
        _ = try await client.send("setRating", query: [
            URLQueryItem(name: "id", value: itemID),
            URLQueryItem(name: "rating", value: "\(clamped)"),
        ], as: SubsonicEmpty.self)
    }

    public func reportPlayback(_ report: PlaybackReport) async throws {
        // Subsonic scrobble: a `submission=false` "now playing" at start, and a
        // `submission=true` play submission at stop. Progress ticks in between
        // carry no extra information for Subsonic, so they're skipped.
        let submission: Bool
        switch report.state {
        case .stopped:
            submission = true
        case .playing where report.positionSeconds == 0:
            submission = false
        default:
            return
        }
        _ = try await client.send("scrobble", query: [
            URLQueryItem(name: "id", value: report.track.id),
            URLQueryItem(name: "submission", value: submission ? "true" : "false"),
        ], as: SubsonicEmpty.self)
    }

    // MARK: Helpers

    private func musicFolderQuery() -> [URLQueryItem] {
        guard let musicFolderId else { return [] }
        return [URLQueryItem(name: "musicFolderId", value: musicFolderId)]
    }

    /// Fetch one album-list window. Returns the filtered (id, songCount) arrays
    /// for enumeration plus the RAW pre-filter page length, which the caller
    /// MUST use for offset advancement and terminal detection so an empty-id
    /// album inside a full window cannot truncate the walk (see enumerateAllTracks).
    private func albumListPage(size: Int, offset: Int) async throws -> (ids: [String], counts: [Int?], rawCount: Int) {
        let body = try await client.send("getAlbumList2", query: [
            URLQueryItem(name: "type", value: "alphabeticalByArtist"),
            URLQueryItem(name: "size", value: "\(size)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
        ] + musicFolderQuery(), as: SubsonicAlbumList2Payload.self)
        let raw = body.payload.albumList2?.album ?? []
        let albums = raw.filter { ($0.id?.value ?? "").isEmpty == false }
        return (albums.map { $0.id?.value ?? "" }, albums.map { $0.songCount }, raw.count)
    }

    private func albumSongs(albumID: String) async throws -> [SubsonicChild] {
        let body = try await client.send(
            "getAlbum",
            query: [URLQueryItem(name: "id", value: albumID)],
            as: SubsonicAlbumPayload.self
        )
        return body.payload.album?.song ?? []
    }

    private static func slice<T>(_ items: [T], offset: Int, limit: Int) -> [T] {
        guard offset < items.count, offset >= 0 else { return [] }
        let end = min(offset + max(limit, 0), items.count)
        return Array(items[offset..<end])
    }
}
