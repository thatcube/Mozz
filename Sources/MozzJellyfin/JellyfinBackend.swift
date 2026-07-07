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
    /// Whether the first page of each catalog phase requests the server's total
    /// record count. That count is a full COUNT(*) over the whole table (~15s on a
    /// large library), needed by the full sync for the progress bar + prune
    /// completeness — but pointless for the bounded quick start, which sets this
    /// false so its single page returns fast.
    private let includeTotalCount: Bool
    /// The music library's item id, used as `ParentId` to scope catalog queries.
    /// Without it, `Recursive=true&IncludeItemTypes=Audio` makes the server scan
    /// EVERY item across ALL libraries (movies, TV, …) to filter audio — on a
    /// large multi-library server that's a full-table scan per page (measured
    /// ~30s/page). With it, the server applies a cheap indexed `TopParentId`
    /// filter. Resolved once per sync via `resolveMusicLibraryId()`.
    private let musicLibraryId: String?

    /// Audio containers we advertise as directly playable, so `universal` serves
    /// the original file when the codec is AVFoundation-friendly.
    private static let directPlayContainers = "opus,mp3,aac,m4a,alac,flac,wav,ogg,webma"

    public init(
        connection: ServerConnection,
        token: String,
        clientInfo: ClientInfo,
        transport: any HTTPTransport = URLSessionTransport(),
        includeTotalCount: Bool = true,
        musicLibraryId: String? = nil,
        logger: any NetworkLogger = NoopNetworkLogger()
    ) {
        self.connection = connection
        self.token = token
        self.clientInfo = clientInfo
        self.includeTotalCount = includeTotalCount
        self.musicLibraryId = musicLibraryId
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

    // MARK: Diagnostics

    /// Run a controlled matrix of `/Items` queries (varying one parameter at a
    /// time) against the live server and return a human-readable timing line for
    /// each. Used by the `MOZZ_SYNCPROBE` launch hook to isolate what actually
    /// drives album/track query cost. Best-effort: a failing probe reports the
    /// error instead of throwing so the rest of the matrix still runs.
    public func diagnoseItemQueryCost() async -> [String] {
        func run(_ label: String, _ query: [URLQueryItem]) async -> String {
            let start = Date()
            do {
                let r = try await client.send(Endpoint(path: "Items", query: query), as: JFItemsResponse.self)
                let dt = Date().timeIntervalSince(start)
                let n = r.Items?.count ?? 0
                let rate = dt > 0 && n > 0 ? Double(n) / dt : 0
                return String(format: "%@: %d in %.2fs (%.0f/s)", label, n, dt, rate)
            } catch {
                return "\(label): ERROR \(String(describing: error))"
            }
        }
        // Build an /Items query with individually toggleable cost factors so each
        // probe differs from the baseline in exactly one dimension.
        func q(type: String, limit: Int, sort: String?, fields: String,
               images: Bool, count: Bool, parent: Bool,
               userData: Bool = true, includeUserId: Bool = true) -> [URLQueryItem] {
            var items: [URLQueryItem] = [
                URLQueryItem(name: "StartIndex", value: "0"),
                URLQueryItem(name: "Limit", value: "\(limit)"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: type),
                URLQueryItem(name: "EnableTotalRecordCount", value: count ? "true" : "false"),
            ]
            if includeUserId { items.append(URLQueryItem(name: "userId", value: userID)) }
            if !userData { items.append(URLQueryItem(name: "EnableUserData", value: "false")) }
            if let sort {
                items.append(URLQueryItem(name: "SortBy", value: sort))
                items.append(URLQueryItem(name: "SortOrder", value: "Descending"))
            }
            if !fields.isEmpty { items.append(URLQueryItem(name: "Fields", value: fields)) }
            if images {
                items.append(URLQueryItem(name: "EnableImageTypes", value: "Primary"))
                items.append(URLQueryItem(name: "ImageTypeLimit", value: "1"))
            } else {
                items.append(URLQueryItem(name: "EnableImages", value: "false"))
            }
            if parent, let musicLibraryId {
                items.append(URLQueryItem(name: "ParentId", value: musicLibraryId))
            }
            return items
        }
        let trackFields = "Genres,DateCreated,NormalizationGain"
        var out: [String] = ["--- /Items cost probe (Audio) ---"]
        // Warm the server/query caches so the measured probes are all warm.
        _ = await run("warmup", q(type: "Audio", limit: 100, sort: "DateCreated", fields: trackFields, images: true, count: false, parent: true))
        // (1) Page-size sweep at fixed params: separates a fixed per-query cost
        //     (sort/count/plan) from per-item serialization cost.
        out.append(await run("size=50   base", q(type: "Audio", limit: 50, sort: "DateCreated", fields: trackFields, images: true, count: false, parent: true)))
        out.append(await run("size=200  base", q(type: "Audio", limit: 200, sort: "DateCreated", fields: trackFields, images: true, count: false, parent: true)))
        out.append(await run("size=500  base", q(type: "Audio", limit: 500, sort: "DateCreated", fields: trackFields, images: true, count: false, parent: true)))
        // (2) One-variable-off probes at size=200 vs the size=200 baseline above.
        out.append(await run("size=200  sort=SortName", q(type: "Audio", limit: 200, sort: "SortName", fields: trackFields, images: true, count: false, parent: true)))
        out.append(await run("size=200  sort=none", q(type: "Audio", limit: 200, sort: nil, fields: trackFields, images: true, count: false, parent: true)))
        out.append(await run("size=200  fields=none", q(type: "Audio", limit: 200, sort: "DateCreated", fields: "", images: true, count: false, parent: true)))
        out.append(await run("size=200  images=off", q(type: "Audio", limit: 200, sort: "DateCreated", fields: trackFields, images: false, count: false, parent: true)))
        out.append(await run("size=200  parent=off", q(type: "Audio", limit: 200, sort: "DateCreated", fields: trackFields, images: true, count: false, parent: false)))
        out.append(await run("size=200  count=on", q(type: "Audio", limit: 200, sort: "DateCreated", fields: trackFields, images: true, count: true, parent: true)))
        // (2b) The untested suspect: per-row UserData (favorite/play-state) work,
        //      and dropping userId entirely. Plus a ParentId on/off re-check.
        out.append(await run("size=200  userdata=off", q(type: "Audio", limit: 200, sort: "DateCreated", fields: trackFields, images: true, count: false, parent: true, userData: false)))
        out.append(await run("size=200  no-userid", q(type: "Audio", limit: 200, sort: "DateCreated", fields: trackFields, images: true, count: false, parent: true, includeUserId: false)))
        out.append(await run("size=200  lean(all-off)", q(type: "Audio", limit: 200, sort: nil, fields: "", images: false, count: false, parent: true, userData: false)))
        out.append(await run("size=200  parent=on #2", q(type: "Audio", limit: 200, sort: "DateCreated", fields: trackFields, images: true, count: false, parent: true)))
        out.append(await run("size=200  parent=off #2", q(type: "Audio", limit: 200, sort: "DateCreated", fields: trackFields, images: true, count: false, parent: false)))
        // (3) Album parallels — albums measured ~8x slower than /Artists.
        out.append("--- /Items cost probe (MusicAlbum) ---")
        out.append(await run("album size=200 base", q(type: "MusicAlbum", limit: 200, sort: "DateCreated", fields: "Genres,DateCreated", images: true, count: false, parent: true)))
        out.append(await run("album size=200 sort=SortName", q(type: "MusicAlbum", limit: 200, sort: "SortName", fields: "Genres,DateCreated", images: true, count: false, parent: true)))
        out.append(await run("album size=200 fields=none", q(type: "MusicAlbum", limit: 200, sort: "DateCreated", fields: "", images: true, count: false, parent: true)))
        out.append(await run("album size=200 images=off", q(type: "MusicAlbum", limit: 200, sort: "DateCreated", fields: "Genres,DateCreated", images: false, count: false, parent: true)))
        // (4) THE big lever: can the server serve parallel /Items requests? Cost
        //     is purely per-item with an idle CPU, so if N concurrent requests
        //     overlap we get an ~Nx speedup. Compare 4x200-item track pages
        //     fetched sequentially vs concurrently (distinct StartIndex windows).
        out.append("--- concurrency probe (4x200 Audio pages) ---")
        func page(_ start: Int) -> [URLQueryItem] {
            q(type: "Audio", limit: 200, sort: "DateCreated", fields: trackFields, images: true, count: false, parent: true)
                .filter { $0.name != "StartIndex" } + [URLQueryItem(name: "StartIndex", value: "\(start)")]
        }
        let starts = [0, 200, 400, 600]
        let httpClient = self.client
        let seqStart = Date()
        for s in starts {
            _ = try? await httpClient.send(Endpoint(path: "Items", query: page(s)), as: JFItemsResponse.self)
        }
        let seqDt = Date().timeIntervalSince(seqStart)
        out.append(String(format: "sequential 4x200: %.2fs", seqDt))
        let conStart = Date()
        await withTaskGroup(of: Void.self) { group in
            for s in starts {
                let query = page(s)
                group.addTask {
                    _ = try? await httpClient.send(Endpoint(path: "Items", query: query), as: JFItemsResponse.self)
                }
            }
        }
        let conDt = Date().timeIntervalSince(conStart)
        out.append(String(format: "concurrent 4x200: %.2fs (%.1fx vs sequential)", conDt, conDt > 0 ? seqDt / conDt : 0))
        // Also try 8-wide to see if the server scales further or saturates.
        let starts8 = stride(from: 0, to: 1600, by: 200).map { $0 }
        let con8Start = Date()
        await withTaskGroup(of: Void.self) { group in
            for s in starts8 {
                let query = page(s)
                group.addTask {
                    _ = try? await httpClient.send(Endpoint(path: "Items", query: query), as: JFItemsResponse.self)
                }
            }
        }
        let con8Dt = Date().timeIntervalSince(con8Start)
        out.append(String(format: "concurrent 8x200: %.2fs (%.0f items/s)", con8Dt, con8Dt > 0 ? 1600 / con8Dt : 0))
        return out
    }

    // MARK: Catalog enumeration

    /// Find the music library's item id so catalog queries can scope to it via
    /// `ParentId` (see `musicLibraryId`). Reads the user's top-level library
    /// folders and returns the first one whose `CollectionType` is "music".
    /// Cheap (one small request, a handful of folders) and best-effort: on any
    /// failure or a server with no tagged music library we return nil and the
    /// caller falls back to unscoped (whole-server) queries.
    public func resolveMusicLibraryId() async -> String? {
        do {
            let response = try await client.send(
                Endpoint(path: "Users/\(userID)/Views"),
                as: JFItemsResponse.self
            )
            let folders = response.Items ?? []
            if let music = folders.first(where: { $0.CollectionType?.lowercased() == "music" }) {
                return music.Id
            }
            // Some servers don't tag the collection type on Views; fall back to
            // the media-folders endpoint which reports it more reliably.
            let media = try await client.send(
                Endpoint(path: "Library/MediaFolders"),
                as: JFItemsResponse.self
            )
            return (media.Items ?? []).first(where: { $0.CollectionType?.lowercased() == "music" })?.Id
        } catch {
            return nil
        }
    }

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
        //
        // (We tried `enableImages=false` here — safe, since an Audio item's
        // AlbumPrimaryImageTag survives it — but measured ZERO speedup on a real
        // server: per-item image work is cheap in-memory, not the bottleneck. So
        // we keep images on to preserve any track's own distinct artwork.)
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
        var query: [URLQueryItem] = [
            URLQueryItem(name: "userId", value: userID),
            URLQueryItem(name: "StartIndex", value: "\(offset)"),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            // Sort by DateCreated DESCENDING — newest first. This makes the sync
            // land the user's most recently-added music first, so the app is
            // useful on relevant content within a minute (and the quick-start tier
            // grabs exactly that recent slice). DateCreated is a direct, indexed
            // column (cheap server-side, unlike Artist/PlayCount subquery sorts).
            // A stable sort is REQUIRED for correct StartIndex/Limit paging;
            // DateCreated also gets an automatic SortName tiebreaker server-side.
            URLQueryItem(name: "SortBy", value: "DateCreated"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Recursive", value: "true"),
            // Total record count ONLY on the first page. With EnableTotalRecordCount
            // the server runs a separate full COUNT(*) before the page SELECT;
            // false takes Jellyfin's single-query fast path. We need the total once
            // (progress bar + the prune-completeness guard), so page 0 pays it and
            // every later page skips it.
            URLQueryItem(name: "EnableTotalRecordCount", value: (includeTotalCount && offset == 0) ? "true" : "false"),
        ]
        // Scope every catalog query to the music library. Without ParentId the
        // server treats `Recursive=true` as "search the whole server" and scans
        // every item across every library (movies, TV, photos, …) to filter for
        // the requested type — a full-table scan per page on a large multi-library
        // box (measured ~30s/page). ParentId turns it into an indexed TopParentId
        // filter over just the music items.
        if let musicLibraryId {
            query.append(URLQueryItem(name: "ParentId", value: musicLibraryId))
        }
        return query
    }

    private func itemsQuery(type: String, offset: Int, limit: Int, fields: String) -> [URLQueryItem] {
        pageQuery(offset: offset, limit: limit) + [
            URLQueryItem(name: "IncludeItemTypes", value: type),
            URLQueryItem(name: "Fields", value: fields),
            URLQueryItem(name: "EnableImageTypes", value: "Primary"),
            // We only ever use the single Primary image, so cap images per type at
            // 1 to trim the image work the server does per item (safe — the Primary
            // tag we need is still returned).
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
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
