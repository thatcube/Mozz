import Foundation
import MozzCore
import MozzNetworking

/// A ``MusicBackend`` for Jellyfin.
///
/// Immutable value type holding only connection config + token, so it is
/// `Sendable` and cheap to hand to the sync, playback and download domains. It
/// resolves URLs and decodes JSON; it never transfers audio bytes itself.
public struct JellyfinBackend: MusicBackend {
    public let connection: ServerConnection
    private let token: String
    private let clientInfo: ClientInfo
    private let client: HTTPClient

    /// Audio containers we advertise as directly playable, so `universal` serves
    /// the original file when the codec is AVFoundation-friendly.
    private static let directPlayContainers = "opus,mp3,aac,m4a,alac,flac,wav,ogg,webma"

    public init(
        connection: ServerConnection,
        token: String,
        clientInfo: ClientInfo,
        transport: any HTTPTransport = URLSessionTransport(),
        logger: any NetworkLogger = NoopNetworkLogger()
    ) {
        self.connection = connection
        self.token = token
        self.clientInfo = clientInfo
        let auth = JellyfinAuth.authorizationHeader(
            clientInfo: clientInfo,
            deviceID: connection.clientIdentifier,
            token: token
        )
        self.client = HTTPClient(
            baseURL: connection.baseURL,
            transport: transport,
            defaultHeaders: ["Authorization": auth, "Accept": "application/json"],
            logger: logger
        )
    }

    private var userID: String { connection.userID ?? "" }

    // MARK: Capabilities

    public func detectCapabilities() async throws -> ServerCapabilities {
        let info = try await client.send(Endpoint(path: "System/Info/Public"), as: JFSystemInfoPublic.self)
        let version = info.Version
        return ServerCapabilities(
            backend: .jellyfin,
            serverVersion: version,
            supportsTranscoding: true,
            supportsOriginalFileDownload: true,
            supportsFavorites: true,
            supportsLyrics: SemanticVersion.isAtLeast(version, "10.8"),
            supportsSyncedLyrics: SemanticVersion.isAtLeast(version, "10.8"),
            supportsNormalizationGain: SemanticVersion.isAtLeast(version, "10.7"),
            supportsProgressReporting: true
        )
    }

    // MARK: Catalog enumeration

    public func fetchArtists(offset: Int, limit: Int) async throws -> CatalogPage<Artist> {
        let response = try await client.send(
            Endpoint(path: "Artists", query: pageQuery(offset: offset, limit: limit) + [
                URLQueryItem(name: "Fields", value: "Genres"),
                URLQueryItem(name: "EnableImageTypes", value: "Primary"),
            ]),
            as: JFItemsResponse.self
        )
        return CatalogPage(items: (response.Items ?? []).map(JellyfinMapper.artist), totalCount: response.TotalRecordCount)
    }

    public func fetchAlbums(offset: Int, limit: Int) async throws -> CatalogPage<Album> {
        // NOTE: no `ChildCount`. It forces Jellyfin to run a per-album track-count
        // subquery, which measured ~5x slower than the artist listing on a large
        // library (albums 6/s vs artists 30/s, ~100% network wait). The only
        // consumer of album.trackCount is the Artist-detail albums/singles split,
        // so the sync derives it locally from the synced tracks instead (see
        // CatalogWriter.deriveAlbumTrackCounts) — free, and off the network path.
        let response = try await client.send(
            Endpoint(path: "Items", query: itemsQuery(type: "MusicAlbum", offset: offset, limit: limit, fields: "Genres,DateCreated")),
            as: JFItemsResponse.self
        )
        return CatalogPage(items: (response.Items ?? []).map(JellyfinMapper.album), totalCount: response.TotalRecordCount)
    }

    public func fetchTracks(offset: Int, limit: Int) async throws -> CatalogPage<Track> {
        // NOTE: deliberately WITHOUT `MediaSources`. On a large (esp. lossless)
        // library that field is the single heaviest part of the payload — the
        // server serializes every media stream for every track — which dominates
        // sync time. The catalog is fully browsable without it (lists don't show
        // codec/bitrate), so we sync tracks light and fast here and backfill the
        // audio format + file size lazily via `fetchTrackDetails` (see the
        // background media backfill). `NormalizationGain` is a cheap top-level
        // field, so loudness normalization keeps working immediately.
        let response = try await client.send(
            Endpoint(path: "Items", query: itemsQuery(type: "Audio", offset: offset, limit: limit, fields: "Genres,DateCreated,NormalizationGain")),
            as: JFItemsResponse.self
        )
        return CatalogPage(items: (response.Items ?? []).map(JellyfinMapper.track), totalCount: response.TotalRecordCount)
    }

    /// Backfill audio format + file size for specific tracks (the data omitted
    /// from `fetchTracks` for speed) by fetching them with `MediaSources`.
    public func fetchTrackDetails(ids: [String]) async throws -> [Track] {
        guard !ids.isEmpty else { return [] }
        let response = try await client.send(
            Endpoint(path: "Items", query: [
                URLQueryItem(name: "userId", value: userID),
                URLQueryItem(name: "Ids", value: ids.joined(separator: ",")),
                URLQueryItem(name: "Fields", value: "Genres,DateCreated,MediaSources,NormalizationGain"),
                URLQueryItem(name: "EnableImageTypes", value: "Primary"),
                URLQueryItem(name: "EnableTotalRecordCount", value: "false"),
            ]),
            as: JFItemsResponse.self
        )
        return (response.Items ?? []).map(JellyfinMapper.track)
    }

    public func fetchPlaylists(offset: Int, limit: Int) async throws -> CatalogPage<Playlist> {
        let response = try await client.send(
            Endpoint(path: "Items", query: itemsQuery(type: "Playlist", offset: offset, limit: limit, fields: "ChildCount")),
            as: JFItemsResponse.self
        )
        return CatalogPage(items: (response.Items ?? []).map(JellyfinMapper.playlist), totalCount: response.TotalRecordCount)
    }

    public func fetchPlaylistItems(playlistID: String, offset: Int, limit: Int) async throws -> CatalogPage<Track> {
        let response = try await client.send(
            Endpoint(path: "Playlists/\(playlistID)/Items", query: [
                URLQueryItem(name: "userId", value: userID),
                URLQueryItem(name: "StartIndex", value: "\(offset)"),
                URLQueryItem(name: "Limit", value: "\(limit)"),
                URLQueryItem(name: "Fields", value: "Genres,MediaSources,NormalizationGain"),
                URLQueryItem(name: "EnableTotalRecordCount", value: "false"),
            ]),
            as: JFItemsResponse.self
        )
        return CatalogPage(items: (response.Items ?? []).map(JellyfinMapper.track), totalCount: response.TotalRecordCount)
    }

    // MARK: Playback & downloads

    public func streamSource(for track: Track, options: StreamOptions) async throws -> StreamSource {
        let sessionID = UUID().uuidString
        var query: [URLQueryItem] = [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "DeviceId", value: connection.clientIdentifier),
            URLQueryItem(name: "PlaySessionId", value: sessionID),
            URLQueryItem(name: "Container", value: Self.directPlayContainers),
            URLQueryItem(name: "TranscodingContainer", value: "ts"),
            URLQueryItem(name: "TranscodingProtocol", value: "hls"),
            URLQueryItem(name: "AudioCodec", value: "aac"),
            URLQueryItem(name: "api_key", value: token),
        ]
        var transcoded = options.forceTranscode
        if let maxBitrate = options.maxBitrateKbps {
            query.append(URLQueryItem(name: "MaxStreamingBitrate", value: "\(maxBitrate * 1000)"))
            transcoded = true
        }
        guard let url = mediaURL(path: "Audio/\(track.id)/universal", query: query) else {
            throw MozzError.invalidResponse
        }
        return StreamSource(url: url, isTranscoded: transcoded, sessionID: sessionID)
    }

    public func originalFileURL(for track: Track) throws -> URL {
        guard let url = mediaURL(path: "Items/\(track.id)/Download", query: [
            URLQueryItem(name: "api_key", value: token),
        ]) else {
            throw MozzError.invalidResponse
        }
        return url
    }

    public func artworkURL(for artwork: ArtworkRef, size: Int) -> URL? {
        let parts = artwork.key.split(separator: "|", maxSplits: 1).map(String.init)
        guard let itemID = parts.first else { return nil }
        var query: [URLQueryItem] = [
            URLQueryItem(name: "fillWidth", value: "\(size)"),
            URLQueryItem(name: "fillHeight", value: "\(size)"),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "api_key", value: token),
        ]
        if parts.count == 2 {
            query.append(URLQueryItem(name: "tag", value: parts[1]))
        }
        return mediaURL(path: "Items/\(itemID)/Images/Primary", query: query)
    }

    // MARK: Writes

    public func setFavorite(_ isFavorite: Bool, itemID: String, type: CatalogItemType) async throws {
        let endpoint = Endpoint(
            method: isFavorite ? .post : .delete,
            path: "Users/\(userID)/FavoriteItems/\(itemID)"
        )
        _ = try await client.send(endpoint)
    }

    public func setRating(_ stars: Double?, itemID: String, type: CatalogItemType) async throws {
        // Jellyfin music has no per-track star rating — it uses favorites, which
        // `setFavorite` handles. supportsRatings is false so the UI shows a heart.
        throw MozzError.unsupported("Jellyfin uses favorites, not star ratings")
    }

    public func reportPlayback(_ report: PlaybackReport) async throws {
        struct Body: Encodable {
            let ItemId: String
            let PlaySessionId: String?
            let PositionTicks: Int64
            let IsPaused: Bool
        }
        let body = Body(
            ItemId: report.track.id,
            PlaySessionId: report.sessionID,
            PositionTicks: Int64(report.positionSeconds * JellyfinMapper.ticksPerSecond),
            IsPaused: report.state == .paused
        )
        let path: String
        if report.state == .stopped {
            path = "Sessions/Playing/Stopped"
        } else if report.state == .playing && report.positionSeconds == 0 {
            path = "Sessions/Playing"
        } else {
            path = "Sessions/Playing/Progress"
        }
        _ = try await client.send(try Endpoint.jsonPost(path, body: body))
    }

    // MARK: Helpers

    private func pageQuery(offset: Int, limit: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "userId", value: userID),
            URLQueryItem(name: "StartIndex", value: "\(offset)"),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Recursive", value: "true"),
            // Request the total record count ONLY on the first page. Jellyfin
            // recomputes it with a full COUNT query on every request, which is
            // cheap for a few thousand artists but expensive for tens of
            // thousands of albums/songs — and doing it on every page was a major
            // drag on large libraries. The first page's total is all the sync
            // engine needs (prune-completeness + the progress bar's total); later
            // pages skip the COUNT entirely.
            URLQueryItem(name: "EnableTotalRecordCount", value: offset == 0 ? "true" : "false"),
        ]
    }

    private func itemsQuery(type: String, offset: Int, limit: Int, fields: String) -> [URLQueryItem] {
        pageQuery(offset: offset, limit: limit) + [
            URLQueryItem(name: "IncludeItemTypes", value: type),
            URLQueryItem(name: "Fields", value: fields),
            URLQueryItem(name: "EnableImageTypes", value: "Primary"),
        ]
    }

    /// Resolve a media/API path + query against the server base URL. Used for
    /// stream/download/artwork URLs, which carry the token as a query param.
    func mediaURL(path: String, query: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(
            url: connection.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        components.queryItems = query
        return components.url
    }
}
