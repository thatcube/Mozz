import Foundation
import MozzContinuity
import MozzHistory
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
    /// The music library item ids used as `ParentId` to scope catalog queries.
    ///
    /// Without one, `Recursive=true&IncludeItemTypes=Audio` makes the server scan
    /// EVERY item across ALL libraries (movies, TV, …) to filter audio — on a
    /// large multi-library server that's a full-table scan per page (measured
    /// ~30s/page). With it, the server applies a cheap indexed `TopParentId`
    /// filter. Resolved via `fetchLibraries()` + the user's selection.
    ///
    /// Currently only the **first** id is applied (see `scopedLibraryId`).
    /// Spanning several libraries means concatenating each one's pages into a
    /// single offset stream, and the sync's prune guard trusts the reported
    /// grand total — get the boundary or the total wrong and a partial
    /// enumeration authorizes deleting the rest of the catalog. That is worth
    /// doing deliberately rather than as a side effect of adding a picker, so
    /// the list is carried here and the selection is single-choice for now.
    private let musicLibraryIds: [String]

    /// The library actually applied as `ParentId`.
    private var scopedLibraryId: String? { musicLibraryIds.first }

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
        musicLibraryIds: [String]? = nil,
        logger: any NetworkLogger = NoopNetworkLogger()
    ) {
        self.connection = connection
        self.token = token
        self.clientInfo = clientInfo
        self.includeTotalCount = includeTotalCount
        // `musicLibraryId` is the single-library form kept for existing callers;
        // `musicLibraryIds` supersedes it when the user has picked several.
        self.musicLibraryIds = musicLibraryIds ?? musicLibraryId.map { [$0] } ?? []
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
            supportsProgressReporting: true,
            // Captured for cross-device continuity (ADR-0010): this is the
            // server's own stable id, which — unlike the base URL — is the same
            // whether we reached it over the LAN or from outside.
            serverIdentity: info.Id
        )
    }

    /// A cross-device continuity store backed by this user's `DisplayPreferences`
    /// (ADR-0010).
    public func makeContinuityStore(serverIdentity: String?) -> any ContinuityStore {
        JellyfinContinuityStore(
            client: client,
            userID: userID,
            fingerprint: ServerAccountFingerprint(
                backend: .jellyfin,
                serverID: serverIdentity ?? "",
                accountID: userID
            )
        )
    }

    /// Cross-device listening history, on the same `DisplayPreferences`
    /// substrate as continuity but in its own record — see `JellyfinHistoryStore`.
    public func makeHistoryStore() -> any HistoryStore {
        JellyfinHistoryStore(client: client, userID: userID)
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
            if parent, let scopedLibraryId {
                items.append(URLQueryItem(name: "ParentId", value: scopedLibraryId))
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
        // (4) CRITICAL: split SERVER+network time from on-device JSON DECODE
        //     time. The other probes time send→decoded; if decoding Jellyfin's
        //     fat BaseItemDto on the phone is the real cost, the fix is client-
        //     side. Fetch raw Data (no decode) and time it, then decode that same
        //     in-memory Data N times and time that. Also report payload bytes so
        //     rows/s can be normalized against Plex/Artists by size.
        out.append("--- split fetch-vs-decode (200 Audio) ---")
        let splitQuery = q(type: "Audio", limit: 200, sort: "DateCreated", fields: trackFields, images: true, count: false, parent: true)
        do {
            let rawStart = Date()
            let data = try await client.send(Endpoint(path: "Items", query: splitQuery))
            let rawDt = Date().timeIntervalSince(rawStart)
            let bytes = data.count
            // Decode the already-fetched bytes 3x to get a stable per-decode cost.
            let decStart = Date()
            var decoded = 0
            for _ in 0..<3 {
                let r = try JSONDecoder().decode(JFItemsResponse.self, from: data)
                decoded = r.Items?.count ?? 0
            }
            let decDt = Date().timeIntervalSince(decStart) / 3
            out.append(String(format: "raw fetch 200: %.2fs  |  decode 200: %.3fs  |  bytes=%d (%.0f B/row)  rows=%d",
                              rawDt, decDt, bytes, decoded > 0 ? Double(bytes) / Double(decoded) : 0, decoded))
            out.append(String(format: "→ fetch=%.0f%% decode=%.0f%% of end-to-end",
                              rawDt / (rawDt + decDt) * 100, decDt / (rawDt + decDt) * 100))
        } catch {
            out.append("split probe ERROR: \(String(describing: error))")
        }
        // Server think-time: Limit=1 isolates fixed per-request overhead (TTFB for
        // a single row) from per-row cost. If ~0, there's no fixed cost and time
        // is purely per-row (confirms the linear-through-origin finding).
        do {
            let oneStart = Date()
            _ = try await client.send(Endpoint(path: "Items", query: q(type: "Audio", limit: 1, sort: "DateCreated", fields: trackFields, images: true, count: false, parent: true)))
            out.append(String(format: "raw fetch 1 (fixed overhead): %.3fs", Date().timeIntervalSince(oneStart)))
        } catch {
            out.append("limit=1 probe ERROR: \(String(describing: error))")
        }
        // (5) NEW LEVER from source research: /Users/{id}/Items/Latest has a
        //     purpose-built query path. Our quick-start IS "newest N tracks", so
        //     test it head-to-head vs /Items for 150 rows. (Latest returns a bare
        //     JSON array of items, groups by album by default → GroupItems=false
        //     for individual tracks.) If it deserializes the same fat data blob
        //     per row it won't beat /Items; measure rather than assume.
        out.append("--- /Items/Latest vs /Items (150 newest Audio) ---")
        do {
            let itemsStart = Date()
            let a = try await client.send(Endpoint(path: "Items", query: q(type: "Audio", limit: 150, sort: "DateCreated", fields: trackFields, images: true, count: false, parent: true)), as: JFItemsResponse.self)
            let itemsDt = Date().timeIntervalSince(itemsStart)
            var latestQuery: [URLQueryItem] = [
                URLQueryItem(name: "userId", value: userID),
                URLQueryItem(name: "Limit", value: "150"),
                URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
                URLQueryItem(name: "GroupItems", value: "false"),
                URLQueryItem(name: "Fields", value: trackFields),
                URLQueryItem(name: "EnableImageTypes", value: "Primary"),
                URLQueryItem(name: "ImageTypeLimit", value: "1"),
            ]
            if let scopedLibraryId { latestQuery.append(URLQueryItem(name: "ParentId", value: scopedLibraryId)) }
            let latestStart = Date()
            // Latest returns a bare [BaseItemDto] array, not the {Items:[]} wrapper.
            let raw = try await client.send(Endpoint(path: "Users/\(userID)/Items/Latest", query: latestQuery))
            let latestItems = try JSONDecoder().decode([JFBaseItem].self, from: raw)
            let latestDt = Date().timeIntervalSince(latestStart)
            out.append(String(format: "/Items 150: %.2fs (%.0f/s, %d rows)  |  /Items/Latest 150: %.2fs (%.0f/s, %d rows)",
                              itemsDt, itemsDt > 0 ? Double(a.Items?.count ?? 0) / itemsDt : 0, a.Items?.count ?? 0,
                              latestDt, latestDt > 0 ? Double(latestItems.count) / latestDt : 0, latestItems.count))
        } catch {
            out.append("latest probe ERROR: \(String(describing: error))")
        }
        // (6) THE big lever: can the server serve parallel /Items requests? Cost
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
    /// Every music library this user can see, for the picker.
    ///
    /// `resolveMusicLibraryId()` deliberately returns only the first; this
    /// returns them all so the user can choose which one Mozz syncs. Same
    /// two-step lookup, because some servers don't tag `CollectionType` on
    /// `Views` and only report it reliably on `Library/MediaFolders`.
    public func fetchLibraries() async throws -> [MusicLibrary] {
        func music(_ response: JFItemsResponse) -> [MusicLibrary] {
            (response.Items ?? [])
                .filter { $0.CollectionType?.lowercased() == "music" }
                .compactMap { item -> MusicLibrary? in
                    let id = item.Id
                    guard !id.isEmpty else { return nil }
                    return MusicLibrary(id: id, name: item.Name ?? "Music")
                }
        }
        if let views = try? await client.send(
            Endpoint(path: "Users/\(userID)/Views"), as: JFItemsResponse.self
        ) {
            let libraries = music(views)
            if !libraries.isEmpty { return libraries }
        }
        guard let media = try? await client.send(
            Endpoint(path: "Library/MediaFolders"), as: JFItemsResponse.self
        ) else { return [] }
        return music(media)
    }

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

    /// Whether a paged query at `offset` actually asked the server to count the
    /// whole set (see `pageQuery`).
    ///
    /// This matters far more than it looks. With `EnableTotalRecordCount=false`
    /// Jellyfin still populates `TotalRecordCount` — with the size of the page
    /// it just returned. Passing that straight through as a catalog total meant
    /// a resumed sync, which by definition starts at a non-zero offset, reported
    /// "6480 → 0" or "9495 → 1000" and looked exactly like a library that had
    /// been emptied. The sync engine dutifully threw away the checkpoint and
    /// re-walked the whole phase, so resuming a long sync never actually
    /// resumed. A count we did not ask for is not a count: report `nil`.
    private func reportedTotal(_ raw: Int?, offset: Int) -> Int? {
        (includeTotalCount && offset == 0) ? raw : nil
    }

    public func fetchArtists(offset: Int, limit: Int) async throws -> CatalogPage<Artist> {
        let response = try await client.send(
            Endpoint(path: "Artists", query: pageQuery(offset: offset, limit: limit) + [
                URLQueryItem(name: "Fields", value: "Genres"),
                URLQueryItem(name: "EnableImageTypes", value: "Primary"),
            ]),
            as: JFItemsResponse.self
        )
        return CatalogPage(items: (response.Items ?? []).map(JellyfinMapper.artist),
                           totalCount: reportedTotal(response.TotalRecordCount, offset: offset))
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
        return CatalogPage(items: (response.Items ?? []).map(JellyfinMapper.album),
                           totalCount: reportedTotal(response.TotalRecordCount, offset: offset))
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
            Endpoint(path: "Items", query: itemsQuery(type: "Audio", offset: offset, limit: limit, fields: "Genres,DateCreated,NormalizationGain,ProviderIds")),
            as: JFItemsResponse.self
        )
        return CatalogPage(items: (response.Items ?? []).map(JellyfinMapper.track),
                           totalCount: reportedTotal(response.TotalRecordCount, offset: offset))
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
                URLQueryItem(name: "Fields", value: "Genres,MediaSources,NormalizationGain,ProviderIds"),
                URLQueryItem(name: "EnableTotalRecordCount", value: "false"),
            ]),
            as: JFItemsResponse.self
        )
        return CatalogPage(items: (response.Items ?? []).map(JellyfinMapper.track), totalCount: response.TotalRecordCount)
    }

    // MARK: Playback & downloads

    public var supportsTranscodeSeek: Bool { true }

    public func streamSource(for track: Track, options: StreamOptions) async throws -> StreamSource {
        try await streamSource(for: track, options: options, startSeconds: 0)
    }

    /// Jellyfin is the one backend that will honour a rate and channel request,
    /// and it is deliberately not asked to. The client downmixes and resamples
    /// for every backend so the analyzer sees one input spec regardless of where
    /// a track came from — a Jellyfin-only shortcut here would make a Jellyfin
    /// library's vectors subtly incomparable with everyone else's.
    public func analysisAudioSource(forTrackID trackID: String) throws -> AnalysisAudioSource? {
        let ticks = Int64(AnalysisAudio.leadInSeconds) * 10_000_000
        let query: [URLQueryItem] = [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "DeviceId", value: connection.clientIdentifier),
            URLQueryItem(name: "PlaySessionId", value: "mozz-analysis-\(trackID)"),
            URLQueryItem(name: "TranscodingContainer", value: "mp3"),
            URLQueryItem(name: "TranscodingProtocol", value: "http"),
            URLQueryItem(name: "AudioCodec", value: "mp3"),
            URLQueryItem(name: "MaxStreamingBitrate", value: "\(AnalysisAudio.bitrateKbps * 1000)"),
            URLQueryItem(name: "StartTimeTicks", value: "\(ticks)"),
            URLQueryItem(name: "api_key", value: token),
        ]
        guard let url = mediaURL(path: "Audio/\(trackID)/universal", query: query) else { return nil }
        // `StartTimeTicks` is server-side, as on Plex.
        return AnalysisAudioSource(url: url, startsAtLeadIn: true)
    }

    public func streamSource(for track: Track, options: StreamOptions, startSeconds: TimeInterval) async throws -> StreamSource {
        let sessionID = UUID().uuidString
        var query: [URLQueryItem] = [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "DeviceId", value: connection.clientIdentifier),
            URLQueryItem(name: "PlaySessionId", value: sessionID),
            URLQueryItem(name: "Container", value: Self.directPlayContainers),
            // Progressive (HTTP) transcode instead of HLS: this restores
            // Jellyfin's own GetDeviceProfile default (Container=mp3,
            // AudioCodec=mp3, Protocol=http) and, crucially, produces a stream
            // that exposes an AVAssetTrack — so the per-item MTAudioProcessing
            // tap (EQ + ReplayGain normalization) works on transcodes too. HLS
            // transcodes have no track and can't be processed. Seeking uses
            // StartTimeTicks (server restarts ffmpeg), ~same latency as HLS.
            URLQueryItem(name: "TranscodingContainer", value: "mp3"),
            URLQueryItem(name: "TranscodingProtocol", value: "http"),
            URLQueryItem(name: "AudioCodec", value: "mp3"),
            URLQueryItem(name: "api_key", value: token),
        ]
        var transcoded = options.forceTranscode
        if let maxBitrate = options.maxBitrateKbps {
            query.append(URLQueryItem(name: "MaxStreamingBitrate", value: "\(maxBitrate * 1000)"))
            transcoded = true
        }
        // Progressive transcodes aren't byte-range seekable (Jellyfin serves them
        // `Accept-Ranges: none`); seeking is done by re-requesting the stream with
        // a server-side start offset in ticks (1 tick = 100ns), which restarts
        // ffmpeg from that point. Gate on `transcoded`: a direct-play request is
        // range-seekable (seeks natively) and StartTimeTicks would needlessly
        // force it to transcode.
        if transcoded, startSeconds > 0 {
            let ticks = Int64((startSeconds * 10_000_000).rounded())
            query.append(URLQueryItem(name: "StartTimeTicks", value: "\(ticks)"))
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

    /// Jellyfin stores a per-user profile image. `Users/Me` reports whether one
    /// exists (`PrimaryImageTag`) — without that check the image request is a
    /// guaranteed 404 for the many users who never set a photo. The tag is passed
    /// through as the cache tag so the server can serve it with strong caching.
    ///
    /// Uses the legacy `Users/{id}/Images/Primary` path (rather than 10.9's
    /// `UserImage`) because it is still routed to the same handler and also works
    /// on the older servers Mozz supports, and `maxWidth`/`maxHeight` rather than
    /// `fillWidth` for the same reason. Unlike item artwork this endpoint requires
    /// auth, hence the `api_key` — the URL is loaded by a plain image loader that
    /// carries no headers, so it must not be logged.
    public func userAvatarURL(size: Int) async -> URL? {
        await signedInAccount(size: size).avatarURL
    }

    public func signedInAccount(size: Int) async -> SignedInAccount {
        guard let me = try? await client.send(Endpoint(path: "Users/Me"), as: JFUser.self) else {
            let username = connection.userID.nonEmpty
            return SignedInAccount(displayName: username, username: username)
        }
        let username = me.Name.nonEmpty ?? connection.userID.nonEmpty
        let avatarURL: URL?
        if let tag = me.PrimaryImageTag.nonEmpty,
           let id = (me.Id ?? connection.userID).nonEmpty {
            avatarURL = mediaURL(path: "Users/\(id)/Images/Primary", query: [
            URLQueryItem(name: "maxWidth", value: "\(size)"),
            URLQueryItem(name: "maxHeight", value: "\(size)"),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "tag", value: tag),
            URLQueryItem(name: "api_key", value: token),
            ])
        } else {
            avatarURL = nil
        }
        return SignedInAccount(displayName: username, username: username, avatarURL: avatarURL)
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

    // MARK: Lyrics

    /// `GET /Audio/{id}/Lyrics`. The server answers 404 when a track has no
    /// lyrics, which is an authoritative "none" and maps to `nil`; every other
    /// failure is a transport problem and is rethrown so the resolver never caches
    /// a false negative.
    public func fetchLyrics(for track: Track) async throws -> Lyrics? {
        // Lyrics are optional, so this asks once and gets out of the way. The
        // shared client retries, which on a weak connection means extra requests
        // competing with the stream the user actually cares about.
        let client = self.client.withRetryPolicy(.none)
        let dto: JFLyricDto
        do {
            dto = try await client.send(
                Endpoint(path: "Audio/\(track.id)/Lyrics"),
                as: JFLyricDto.self
            )
        } catch MozzError.notFound {
            return nil
        } catch MozzError.decodingFailed {
            // A 200 whose body isn't a lyric document (some servers answer with an
            // empty body rather than 404). Treat as an authoritative "none".
            return nil
        }
        guard let rawLines = dto.Lyrics, !rawLines.isEmpty else { return nil }
        var lines = rawLines.map { line in
            LyricLine(
                text: line.Text ?? "",
                start: line.Start.map { Double($0) / JellyfinMapper.ticksPerSecond }
            )
        }
        // The player's active-line scan assumes ascending order, so guard against a
        // server that returns timed lines out of order. Only sort when there ARE
        // timestamps — reordering plain lines would scramble their reading order.
        if lines.contains(where: { $0.start != nil }) {
            lines.sort { ($0.start ?? 0) < ($1.start ?? 0) }
        }
        let lyrics = Lyrics(lines: lines)
        return lyrics.isEmpty ? nil : lyrics.taggingSource(.jellyfin)
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
        if let scopedLibraryId {
            query.append(URLQueryItem(name: "ParentId", value: scopedLibraryId))
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

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self, !value.isEmpty else { return nil }
        return value
    }
}
