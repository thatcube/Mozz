import Foundation
import MozzCore
import MozzNetworking

/// A ``MusicBackend`` for Plex Media Server.
///
/// Talks only to the chosen server connection (the plex.tv PIN/OAuth + resource
/// discovery dance lives in ``PlexAuthenticator``). Immutable/`Sendable`: it
/// resolves URLs and decodes JSON, never transferring audio itself.
///
/// Plex requires a *music library section* id to browse. If the connection does
/// not yet carry one, call ``musicSections()`` to resolve it and reconstruct
/// the backend with an updated ``ServerConnection``.
public struct PlexBackend: MusicBackend {
    /// Plex library item type ids.
    private enum PlexType {
        static let artist = 8
        static let album = 9
        static let track = 10
    }

    public let connection: ServerConnection
    private let token: String
    private let clientInfo: ClientInfo
    private let client: HTTPClient
    /// The music library section ids to browse during sync. Plex is
    /// section-scoped and a server can host several music libraries; a sync spans
    /// ALL of these into the one catalog (the user's default is "all"). Defaults
    /// to the connection's single resolved section for back-compat.
    public let musicSectionIDs: [String]

    public init(
        connection: ServerConnection,
        token: String,
        clientInfo: ClientInfo,
        transport: any HTTPTransport = URLSessionTransport(),
        logger: any NetworkLogger = NoopNetworkLogger(),
        musicSectionIDs: [String]? = nil
    ) {
        self.connection = connection
        self.token = token
        self.clientInfo = clientInfo
        self.musicSectionIDs = musicSectionIDs ?? connection.musicSectionID.map { [$0] } ?? []
        self.client = HTTPClient(
            baseURL: connection.baseURL,
            transport: transport,
            defaultHeaders: PlexHeaders.common(clientInfo: clientInfo, clientIdentifier: connection.clientIdentifier, token: token),
            logger: logger
        )
    }

    private var sectionID: String { connection.musicSectionID ?? "" }

    // MARK: Section resolution

    /// A music library section on the server.
    public struct MusicSection: Sendable, Hashable {
        public var id: String
        public var title: String
    }

    /// The music (`artist`-type) library sections on this server.
    public func musicSections() async throws -> [MusicSection] {
        let response = try await client.send(Endpoint(path: "library/sections"), as: PlexContainerResponse.self)
        return (response.MediaContainer.Directory ?? [])
            .filter { $0.type == "artist" }
            .compactMap { directory in
                guard let key = directory.key else { return nil }
                return MusicSection(id: key, title: directory.title ?? "Music")
            }
    }

    /// A library section of any kind, used only for diagnostics when no *music*
    /// section is found — so the failure can name what the server DOES expose.
    public struct AnySection: Sendable, Hashable {
        public var key: String?
        public var type: String?
        public var title: String?
    }

    /// Every library section on the server (any type). Kept separate from
    /// ``musicSections()`` so the happy path stays lean; called only to build a
    /// helpful error when music resolution comes back empty.
    public func allLibrarySections() async throws -> [AnySection] {
        let response = try await client.send(Endpoint(path: "library/sections"), as: PlexContainerResponse.self)
        return (response.MediaContainer.Directory ?? [])
            .map { AnySection(key: $0.key, type: $0.type, title: $0.title) }
    }

    // MARK: Capabilities

    public func detectCapabilities() async throws -> ServerCapabilities {
        let response = try await client.send(Endpoint(path: "/"), as: PlexContainerResponse.self)
        return ServerCapabilities(
            backend: .plex,
            serverVersion: response.MediaContainer.version,
            supportsTranscoding: true,
            supportsOriginalFileDownload: true,
            // Plex has 5-star ratings, not a boolean favorite; the UI gates the
            // heart off supportsFavorites and shows a rating chip off this flag.
            supportsFavorites: false,
            supportsRatings: true,
            supportsLyrics: false,
            supportsSyncedLyrics: false,
            supportsNormalizationGain: false,
            supportsProgressReporting: true,
            hasPlexPass: nil
        )
    }

    // MARK: Catalog enumeration

    public func fetchArtists(offset: Int, limit: Int) async throws -> CatalogPage<Artist> {
        try await sectionPage(type: PlexType.artist, offset: offset, limit: limit, map: PlexMapper.artist)
    }

    public func fetchAlbums(offset: Int, limit: Int) async throws -> CatalogPage<Album> {
        try await sectionPage(type: PlexType.album, offset: offset, limit: limit, map: PlexMapper.album)
    }

    public func fetchTracks(offset: Int, limit: Int) async throws -> CatalogPage<Track> {
        try await sectionPage(type: PlexType.track, offset: offset, limit: limit, map: PlexMapper.track)
    }

    public func fetchPlaylists(offset: Int, limit: Int) async throws -> CatalogPage<Playlist> {
        let response = try await client.send(
            Endpoint(path: "playlists", query: [
                URLQueryItem(name: "playlistType", value: "audio"),
            ] + containerQuery(offset: offset, limit: limit)),
            as: PlexContainerResponse.self
        )
        let items = (response.MediaContainer.Metadata ?? []).compactMap(PlexMapper.playlist)
        return CatalogPage(items: items, totalCount: response.MediaContainer.totalSize)
    }

    public func fetchPlaylistItems(playlistID: String, offset: Int, limit: Int) async throws -> CatalogPage<Track> {
        let response = try await client.send(
            Endpoint(path: "playlists/\(playlistID)/items", query: containerQuery(offset: offset, limit: limit)),
            as: PlexContainerResponse.self
        )
        let items = (response.MediaContainer.Metadata ?? []).compactMap(PlexMapper.track)
        return CatalogPage(items: items, totalCount: response.MediaContainer.totalSize)
    }

    // MARK: Playback & downloads

    public func streamSource(for track: Track, options: StreamOptions) async throws -> StreamSource {
        // Transcode when asked to (metered / bitrate cap); otherwise direct-play
        // the original Part.
        //
        // NOTE (progressive transcode deferred): unlike Jellyfin/Subsonic, Plex
        // transcodes stay on HLS here on purpose. Plex's progressive endpoint
        // (`.../transcode/universal/start.mp3`) returns `Transfer-Encoding:
        // chunked` with no `Content-Length`, `Accept-Ranges: none` and
        // `Connection: close`. AVPlayer's CoreMedia HTTP stack can't stream that
        // (CFHTTP error -16845 surfacing as NSURLError -1008), so making Plex
        // EQ-able on transcode would require downloading the transcode to a temp
        // file (with XING VBR-header injection) or a localhost re-serving proxy
        // — both real UX regressions. Since Plex transcodes are rare (most Plex
        // playback is direct-play, which already exposes an AVAssetTrack and is
        // EQ-able) and nothing in the app forces a transcode today, we keep the
        // working HLS path rather than ship a half-working progressive one. See
        // docs/adr/ADR-0009-progressive-audio-transcoding.md.
        if options.forceTranscode || options.maxBitrateKbps != nil {
            let sessionID = UUID().uuidString
            var query: [URLQueryItem] = [
                URLQueryItem(name: "path", value: "/library/metadata/\(track.id)"),
                URLQueryItem(name: "protocol", value: "hls"),
                URLQueryItem(name: "mediaIndex", value: "0"),
                URLQueryItem(name: "partIndex", value: "0"),
                URLQueryItem(name: "hasMDE", value: "1"),
                URLQueryItem(name: "session", value: sessionID),
                URLQueryItem(name: "X-Plex-Client-Identifier", value: connection.clientIdentifier),
                URLQueryItem(name: "X-Plex-Token", value: token),
            ]
            if let maxBitrate = options.maxBitrateKbps {
                query.append(URLQueryItem(name: "maxAudioBitrate", value: "\(maxBitrate)"))
            }
            guard let url = mediaURL(path: "music/:/transcode/universal", query: query) else {
                throw MozzError.invalidResponse
            }
            return StreamSource(url: url, isTranscoded: true, sessionID: sessionID)
        }

        guard let key = track.mediaKey else { throw MozzError.unsupported("Track has no direct-play part") }
        guard let url = mediaURL(path: key, query: [URLQueryItem(name: "X-Plex-Token", value: token)]) else {
            throw MozzError.invalidResponse
        }
        return StreamSource(url: url, isTranscoded: false, sessionID: nil)
    }

    public func originalFileURL(for track: Track) throws -> URL {
        guard let key = track.mediaKey else { throw MozzError.unsupported("Track has no downloadable part") }
        guard let url = mediaURL(path: key, query: [
            URLQueryItem(name: "download", value: "1"),
            URLQueryItem(name: "X-Plex-Token", value: token),
        ]) else {
            throw MozzError.invalidResponse
        }
        return url
    }

    public func artworkURL(for artwork: ArtworkRef, size: Int) -> URL? {
        // Use Plex's photo transcoder so the UI gets exactly the pixel size it
        // asks for. The inner `url` is the relative thumb path; the token is a
        // query param (media URL, no headers).
        mediaURL(path: "photo/:/transcode", query: [
            URLQueryItem(name: "url", value: artwork.key),
            URLQueryItem(name: "width", value: "\(size)"),
            URLQueryItem(name: "height", value: "\(size)"),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "upscale", value: "1"),
            URLQueryItem(name: "X-Plex-Token", value: token),
        ])
    }

    // MARK: Writes

    public func setFavorite(_ isFavorite: Bool, itemID: String, type: CatalogItemType) async throws {
        // Plex has no boolean favorite for music. Express a "like" as 5 stars and
        // an "unlike" as clearing the rating, so any caller works even though the
        // UI (gated on supportsFavorites=false) shows a rating chip, not a heart.
        try await setRating(isFavorite ? 5 : nil, itemID: itemID, type: type)
    }

    public func setRating(_ stars: Double?, itemID: String, type: CatalogItemType) async throws {
        // Plex `userRating` is 0–10 (10 == 5 stars). Clearing sends 0. Plex's
        // rate endpoint is a GET with query params, like the timeline scrobble.
        let plexRating = stars.map { max(0, min(10, Int(($0 * 2).rounded()))) } ?? 0
        let endpoint = Endpoint(path: ":/rate", query: [
            URLQueryItem(name: "key", value: itemID),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "rating", value: "\(plexRating)"),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: connection.clientIdentifier),
        ])
        _ = try await client.send(endpoint)
    }

    public func reportPlayback(_ report: PlaybackReport) async throws {
        let timeMs = Int(report.positionSeconds * 1000)
        let durationMs = Int(report.track.duration * 1000)
        let endpoint = Endpoint(path: ":/timeline", query: [
            URLQueryItem(name: "ratingKey", value: report.track.id),
            URLQueryItem(name: "key", value: "/library/metadata/\(report.track.id)"),
            URLQueryItem(name: "state", value: report.state.rawValue),
            URLQueryItem(name: "time", value: "\(timeMs)"),
            URLQueryItem(name: "duration", value: "\(durationMs)"),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: connection.clientIdentifier),
        ])
        _ = try await client.send(endpoint)
    }

    // MARK: Helpers

    private func sectionPage<T: Sendable>(
        type: Int,
        offset: Int,
        limit: Int,
        map: (PlexMetadata) -> T?
    ) async throws -> CatalogPage<T> {
        let sections = musicSectionIDs.isEmpty ? (sectionID.isEmpty ? [] : [sectionID]) : musicSectionIDs
        guard !sections.isEmpty else {
            throw MozzError.unsupported("Plex music section not resolved; call musicSections() first")
        }
        // Present the selected sections as one concatenated stream so the generic
        // (global-offset) sync paging spans them all. We advance to the next
        // section only when the current one is truly EXHAUSTED (start + returned
        // >= its totalSize) — never on a merely short page, which some servers
        // return mid-section (advancing on a short page would skip or duplicate
        // items). Every section's `totalSize` is summed into the combined total,
        // so the sync's completeness/prune guard sees the true grand total and a
        // truncated section can't authorize a wipe. `X-Plex-Container-Size: 0`
        // cheaply returns just a section's total once the window is full.
        var skip = offset
        var items: [T] = []
        var combinedTotal = 0
        var windowFilled = false
        for section in sections {
            let want = windowFilled ? 0 : max(0, limit - items.count)
            let response = try await client.send(
                Endpoint(path: "library/sections/\(section)/all", query: [
                    URLQueryItem(name: "type", value: "\(type)"),
                    URLQueryItem(name: "sort", value: "titleSort:asc"),
                ] + containerQuery(offset: max(0, skip), limit: want)),
                as: PlexContainerResponse.self
            )
            let sectionTotal = response.MediaContainer.totalSize ?? (response.MediaContainer.Metadata?.count ?? 0)
            combinedTotal += sectionTotal
            if windowFilled { continue } // only summing remaining sections' totals
            if skip >= sectionTotal {
                skip -= sectionTotal // this whole section precedes the window
                continue
            }
            let batch = (response.MediaContainer.Metadata ?? []).compactMap(map)
            items.append(contentsOf: batch)
            if skip + batch.count >= sectionTotal {
                skip = 0 // section exhausted — the window may continue into the next
            } else {
                windowFilled = true // short page mid-section: resume here next call
            }
            if items.count >= limit { windowFilled = true }
        }
        return CatalogPage(items: items, totalCount: combinedTotal)
    }

    private func containerQuery(offset: Int, limit: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "X-Plex-Container-Start", value: "\(offset)"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(limit)"),
            // Ask Plex to inline each item's external ids (MusicBrainz `Guid`s) so
            // enrichment can capture embedded MBIDs during the normal sync with no
            // extra per-item requests (ADR-0007/B1). Harmless on servers/agents
            // that don't provide them — the array simply stays absent.
            URLQueryItem(name: "includeGuids", value: "1"),
        ]
    }

    /// Build a media/API URL against the server base. Used for stream, download
    /// and artwork URLs, which carry the token as a query parameter.
    func mediaURL(path: String, query: [URLQueryItem]) -> URL? {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(
            url: connection.baseURL.appendingPathComponent(trimmed),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        components.queryItems = query
        return components.url
    }
}
