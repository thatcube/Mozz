import Foundation
import MozzCore
import MozzNetworking

/// A ``MusicBackend`` for OpenSubsonic / Subsonic servers.
///
/// **Sync model: album-walk, prune-safe.** The authoritative catalog
/// enumeration walks `getAlbumList2(type=alphabeticalByArtist, size/offset)`
/// paging through every album, then `getAlbum(id)` for each album to collect
/// the songs. That gives us:
///
/// 1. A stable ordering across sync runs (`alphabeticalByArtist` is
///    deterministic, unlike `search3` with an empty query which is documented
///    to be unstable under mutation and can silently skip pages).
/// 2. A *derivable* expected total = Σ album.songCount — reported on each
///    yielded page so ``LibrarySyncEngine``'s completeness check can safely
///    gate the destructive prune. Without this we'd risk deleting the user's
///    downloaded tracks on a partial/flaky sync.
/// 3. Natural deduplication: the sync engine already dedupes track ids by set
///    membership, so a song that appears on multiple albums (compilations,
///    "best of"s) doesn't inflate the seen count.
///
/// `search3(query="")` is left available as a fast-path *quick-start* option
/// (probed at construction) but is NEVER authorized to prune — a bounded quick
/// start on any backend uses `SyncPlan.quickStart` which sets `prune=false`.
public struct SubsonicBackend: MusicBackend {
    public let connection: ServerConnection
    public let credentials: SubsonicCredentials
    public let clientInfo: ClientInfo
    /// The optional music folder scope (mirrors Plex musicSectionID / Jellyfin
    /// musicLibraryId) — persisted on the connection so the user can pick which
    /// library to sync when the server has more than one.
    public let musicFolderId: String?
    public let client: SubsonicClient
    /// Detected once, immutable per backend instance. `nil` on the first
    /// `detectCapabilities` call (a lightweight discovery lands them there).
    private let cachedProduct: DetectedProduct?

    /// The pieces of the OpenSubsonic /ping envelope we keep around: the server
    /// product type + version (for display) and whether an OpenSubsonic
    /// extensions endpoint is present. All are best-effort.
    public struct DetectedProduct: Sendable, Hashable {
        public var protocolVersion: String?
        public var productType: String?
        public var productVersion: String?
        public var openSubsonic: Bool
        public var extensions: [String]

        public var displayVersion: String? {
            switch (productType, productVersion, protocolVersion) {
            case (let t?, let v?, _): return "\(t) \(v)"
            case (let t?, nil, _): return t
            case (nil, _, let p?): return "Subsonic API \(p)"
            default: return nil
            }
        }
    }

    public init(
        connection: ServerConnection,
        credentials: SubsonicCredentials,
        clientInfo: ClientInfo,
        transport: any HTTPTransport = URLSessionTransport(),
        musicFolderId: String? = nil,
        detectedProduct: DetectedProduct? = nil,
        logger: any NetworkLogger = NoopNetworkLogger()
    ) {
        self.connection = connection
        self.credentials = credentials
        self.clientInfo = clientInfo
        self.musicFolderId = musicFolderId ?? connection.musicSectionID
        self.cachedProduct = detectedProduct
        self.client = SubsonicClient(
            baseURL: connection.baseURL,
            credentials: credentials,
            clientInfo: clientInfo,
            transport: transport,
            logger: logger
        )
    }

    // MARK: Capability detection

    public func detectCapabilities() async throws -> ServerCapabilities {
        // ping is authoritative for "the chosen auth works". A `failed`
        // envelope maps to MozzError in the client.
        let ping = try await client.sendVoid("ping.view")

        // getOpenSubsonicExtensions is BEST-EFFORT — anything short of a
        // successful decode means "classic Subsonic profile", not a detection
        // failure. Classic servers surface the missing endpoint in wildly
        // different ways: some 404 the HTTP request (mapped to .notFound), some
        // return a `failed` envelope with code 70 (mapped to .notFound), some
        // return code 30 (mapped to .unsupported), a few 400/500 the request
        // (mapped to .badStatus). We treat ALL of those uniformly.
        var extensions: [SSExtension] = []
        var openSubsonic = false
        do {
            extensions = try await client.send(
                "getOpenSubsonicExtensions.view",
                payloadKey: "openSubsonicExtensions",
                as: [SSExtension].self
            )
            openSubsonic = true
        } catch MozzError.unauthorized {
            // A 401/403 on THIS call means the credential doesn't allow
            // extension introspection but ping succeeded — that's still
            // authenticated. Fall back to classic profile.
            openSubsonic = false
        } catch is MozzError {
            openSubsonic = false
        }

        let hasExtension: (String) -> Bool = { name in
            extensions.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }

        // Star -> favorites is a mandatory Subsonic op, always supported.
        // Ratings (setRating) has been in the API since 1.6, so we assume it.
        // Synced/plain lyrics require the `songLyrics` extension (OpenSubsonic).
        // ReplayGain / normalization gain is only reliable when the server
        // advertises the extension AND populates the block on songs.
        return ServerCapabilities(
            backend: .subsonic,
            serverVersion: ping.version ?? ping.serverVersion,
            supportsTranscoding: true,
            supportsOriginalFileDownload: true,
            supportsFavorites: true,
            supportsRatings: true,
            supportsLyrics: hasExtension("songLyrics"),
            supportsSyncedLyrics: hasExtension("songLyrics"),
            supportsNormalizationGain: hasExtension("replayGain"),
            supportsProgressReporting: true,
            serverProductType: ping.type,
            isOpenSubsonic: openSubsonic
        )
    }

    // MARK: Catalog enumeration

    public func fetchArtists(offset: Int, limit: Int) async throws -> CatalogPage<Artist> {
        // `getArtists` returns the FULL indexed list in one call — it isn't
        // paged server-side. So we treat it as "everything on page 0" and
        // return an empty page for offset > 0 so the sync engine stops.
        guard offset == 0 else { return CatalogPage(items: [], totalCount: nil) }
        var query = [URLQueryItem]()
        if let musicFolderId {
            query.append(URLQueryItem(name: "musicFolderId", value: musicFolderId))
        }
        let payload = try await client.send(
            "getArtists.view", query: query,
            payloadKey: "artists", as: SSArtistsIndex.self
        )
        let all = (payload.index ?? []).flatMap { $0.artist ?? [] }
        let mapped = all.map(SubsonicMapper.artist)
        return CatalogPage(items: mapped, totalCount: mapped.count)
    }

    public func fetchAlbums(offset: Int, limit: Int) async throws -> CatalogPage<Album> {
        // Stable ordering is critical: `alphabeticalByArtist` is deterministic
        // across sync runs (unlike `newest` which shifts every time an album
        // is added, breaking offset paging mid-sync).
        var query: [URLQueryItem] = [
            URLQueryItem(name: "type", value: "alphabeticalByArtist"),
            URLQueryItem(name: "size", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let musicFolderId {
            query.append(URLQueryItem(name: "musicFolderId", value: musicFolderId))
        }
        let payload = try await client.send(
            "getAlbumList2.view", query: query,
            payloadKey: "albumList2", as: SSAlbumList2.self
        )
        let items = (payload.album ?? []).map(SubsonicMapper.album)
        // The server doesn't tell us the grand total — sync stops on empty page.
        return CatalogPage(items: items, totalCount: nil)
    }

    public func fetchTracks(offset: Int, limit: Int) async throws -> CatalogPage<Track> {
        // Fallback pager for callers that want a flat pager (rare). Uses
        // `search3` under an empty query. NOTE: this is UNSTABLE under mutation
        // (documented; the server does not guarantee ordering across pages).
        // The sync engine uses ``enumerateAllTracks`` instead, which walks
        // albums for stability and a derivable expected total. We keep this
        // implementation only so the protocol contract is satisfied.
        var query: [URLQueryItem] = [
            URLQueryItem(name: "query", value: ""),
            URLQueryItem(name: "artistCount", value: "0"),
            URLQueryItem(name: "albumCount", value: "0"),
            URLQueryItem(name: "songCount", value: String(limit)),
            URLQueryItem(name: "songOffset", value: String(offset)),
        ]
        if let musicFolderId {
            query.append(URLQueryItem(name: "musicFolderId", value: musicFolderId))
        }
        let payload = try await client.send(
            "search3.view", query: query,
            payloadKey: "searchResult3", as: SSSearchResult3.self
        )
        let items = (payload.song ?? []).map(SubsonicMapper.track)
        return CatalogPage(items: items, totalCount: nil)
    }

    /// **The prune-safe track enumerator.** Walks `getAlbumList2` in
    /// deterministic `alphabeticalByArtist` order, then fetches each album with
    /// `getAlbum(id)` to collect its songs. As we go, we sum `songCount` from
    /// each album into a running expected total that we report on every yielded
    /// page — so the sync engine's completeness check can require
    /// `seen >= total` before allowing a destructive prune.
    public func enumerateAllTracks(pageSize: Int) -> AsyncThrowingStream<CatalogPage<Track>, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Album list page size ~ 500 is the Subsonic convention;
                    // per-album track counts vary so this is just the album
                    // walk's granularity, not the yielded page size.
                    let albumPageSize = 500
                    var albumOffset = 0
                    var expectedTotal = 0
                    /// Set to `false` the moment any album on any listing page
                    /// omits `songCount`. Once unprovable, we STOP emitting a
                    /// total on yielded pages so LibrarySyncEngine's prune
                    /// guard (which requires a positive reported total) will
                    /// correctly refuse to prune — matching the spec's
                    /// "if not provable, DO NOT prune" invariant.
                    var totalIsProvable = true
                    var trackBuffer: [Track] = []

                    while !Task.isCancelled {
                        var albumQuery: [URLQueryItem] = [
                            URLQueryItem(name: "type", value: "alphabeticalByArtist"),
                            URLQueryItem(name: "size", value: String(albumPageSize)),
                            URLQueryItem(name: "offset", value: String(albumOffset)),
                        ]
                        if let musicFolderId {
                            albumQuery.append(URLQueryItem(name: "musicFolderId", value: musicFolderId))
                        }
                        let albumsPayload = try await client.send(
                            "getAlbumList2.view", query: albumQuery,
                            payloadKey: "albumList2", as: SSAlbumList2.self
                        )
                        let albums = albumsPayload.album ?? []
                        if albums.isEmpty { break }

                        // Sum the DECLARED songCount for the WHOLE listing page
                        // BEFORE fetching any album details. This is critical
                        // for prune safety: `expectedTotal` must be a strict
                        // upper bound on `seen` mid-walk so that a network drop
                        // during the last album can never leave the sync
                        // engine with `seen >= total` (which would authorise
                        // deleting unseen tracks + their downloaded files).
                        for a in albums {
                            if let n = a.songCount {
                                expectedTotal += n
                            } else {
                                // Missing songCount on ANY album means the
                                // expected total is a floor, not a truth.
                                totalIsProvable = false
                            }
                        }
                        let reportableTotal: Int? = totalIsProvable ? expectedTotal : nil

                        for album in albums {
                            if Task.isCancelled { break }
                            let detail = try await client.send(
                                "getAlbum.view",
                                query: [URLQueryItem(name: "id", value: album.id.value)],
                                payloadKey: "album", as: SSAlbumWithSongs.self
                            )
                            let songs = (detail.song ?? []).map(SubsonicMapper.track)
                            trackBuffer.append(contentsOf: songs)
                            while trackBuffer.count >= pageSize {
                                let chunk = Array(trackBuffer.prefix(pageSize))
                                trackBuffer.removeFirst(pageSize)
                                continuation.yield(CatalogPage(items: chunk, totalCount: reportableTotal))
                            }
                        }
                        albumOffset += albums.count
                    }

                    if !trackBuffer.isEmpty {
                        let finalTotal: Int? = totalIsProvable ? expectedTotal : nil
                        continuation.yield(CatalogPage(items: trackBuffer, totalCount: finalTotal))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func fetchPlaylists(offset: Int, limit: Int) async throws -> CatalogPage<Playlist> {
        guard offset == 0 else { return CatalogPage(items: [], totalCount: nil) }
        let payload = try await client.send(
            "getPlaylists.view",
            payloadKey: "playlists", as: SSPlaylists.self
        )
        let items = (payload.playlist ?? []).map(SubsonicMapper.playlist)
        return CatalogPage(items: items, totalCount: items.count)
    }

    public func fetchPlaylistItems(playlistID: String, offset: Int, limit: Int) async throws -> CatalogPage<Track> {
        guard offset == 0 else { return CatalogPage(items: [], totalCount: nil) }
        let payload = try await client.send(
            "getPlaylist.view",
            query: [URLQueryItem(name: "id", value: playlistID)],
            payloadKey: "playlist", as: SSPlaylistDetail.self
        )
        let items = (payload.entry ?? []).map(SubsonicMapper.track)
        return CatalogPage(items: items, totalCount: items.count)
    }

    // MARK: Playback & downloads

    /// Direct-play iOS-friendly formats. Everything else transcodes to aac (or
    /// stays aac if the server can't). This preserves gapless + quality for
    /// what AVFoundation can play natively, and only pays the transcode cost
    /// where iOS genuinely can't decode the source (opus, ogg, wma).
    static let directPlaySuffixes: Set<String> = [
        "mp3", "aac", "m4a", "mp4", "alac", "flac", "wav", "wave", "aiff", "aif",
    ]

    public func streamSource(for track: Track, options: StreamOptions) async throws -> StreamSource {
        let container = (track.format.container ?? "").lowercased()
        let codec = (track.format.codec ?? "").lowercased()
        let iosPlayable = Self.directPlaySuffixes.contains(container)
            || Self.directPlaySuffixes.contains(codec)

        // Decide whether we can direct-play. A bitrate cap ALWAYS transcodes
        // (the server can't recompress without decoding). A caller-forced
        // transcode always transcodes. Otherwise, iOS-playable containers get
        // `format=raw` so we get gapless + full quality, and unsupported
        // containers (opus / ogg / wma) transcode to aac.
        let mustTranscode = options.forceTranscode
            || options.maxBitrateKbps != nil
            || !iosPlayable

        var query: [URLQueryItem] = [URLQueryItem(name: "id", value: track.id)]
        if mustTranscode {
            query.append(URLQueryItem(name: "format", value: "aac"))
            if let bitrate = options.maxBitrateKbps {
                query.append(URLQueryItem(name: "maxBitRate", value: String(bitrate)))
            }
        } else {
            query.append(URLQueryItem(name: "format", value: "raw"))
        }
        let url = try client.url(path: "stream.view", query: query)
        // Subsonic has no per-stream session id concept the way Jellyfin does.
        return StreamSource(url: url, isTranscoded: mustTranscode, sessionID: nil)
    }

    public func originalFileURL(for track: Track) throws -> URL {
        // The `download` endpoint always returns the original, untouched file.
        // Callers must validate the response with
        // ``SubsonicClient.validateBinaryResponse`` before writing to disk —
        // Subsonic surfaces errors over HTTP 200 with an XML/JSON body.
        try client.url(path: "download.view", query: [URLQueryItem(name: "id", value: track.id)])
    }

    public func artworkURL(for artwork: ArtworkRef, size: Int) -> URL? {
        // Deterministic URL: signing params come from the client's default query
        // items (stable across launches when the credential envelope is stable),
        // so the artwork cache keys on a URL that doesn't churn.
        try? client.url(
            path: "getCoverArt.view",
            query: [
                URLQueryItem(name: "id", value: artwork.key),
                URLQueryItem(name: "size", value: String(size)),
            ]
        )
    }

    // MARK: Writes

    public func setFavorite(_ isFavorite: Bool, itemID: String, type: CatalogItemType) async throws {
        let path = isFavorite ? "star.view" : "unstar.view"
        let paramName: String
        switch type {
        case .artist: paramName = "artistId"
        case .album:  paramName = "albumId"
        case .track:  paramName = "id"
        case .playlist:
            throw MozzError.unsupported("Subsonic has no favorite/star concept for playlists")
        }
        _ = try await client.sendVoid(path, query: [URLQueryItem(name: paramName, value: itemID)])
    }

    public func setRating(_ stars: Double?, itemID: String, type: CatalogItemType) async throws {
        // Subsonic setRating takes an integer 0-5. `nil` (clear) maps to 0.
        let value = max(0, min(5, Int((stars ?? 0).rounded())))
        _ = try await client.sendVoid("setRating.view", query: [
            URLQueryItem(name: "id", value: itemID),
            URLQueryItem(name: "rating", value: String(value)),
        ])
    }

    public func reportPlayback(_ report: PlaybackReport) async throws {
        // Subsonic `scrobble` covers now-playing (submission=false) and
        // completed-play (submission=true). Progress reports use now-playing;
        // stopped reports scrobble a final submission.
        let submission = report.state == .stopped
        _ = try await client.sendVoid("scrobble.view", query: [
            URLQueryItem(name: "id", value: report.track.id),
            URLQueryItem(name: "submission", value: submission ? "true" : "false"),
        ])
    }
}

/// `search3` payload (used only for the fallback flat `fetchTracks`).
struct SSSearchResult3: Decodable {
    let song: [SSSong]?
}
