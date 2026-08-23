import Foundation

/// One page of catalog items plus, when the backend reports it, the total
/// number of items available. The sync engine pages until it receives a short
/// or empty page, so `totalCount` is advisory (used only for progress UI).
public struct CatalogPage<Item: Sendable>: Sendable {
    public var items: [Item]
    public var totalCount: Int?

    public init(items: [Item], totalCount: Int? = nil) {
        self.items = items
        self.totalCount = totalCount
    }
}

/// The kinds of catalog items that can be favorited.
public enum CatalogItemType: String, Codable, Sendable, Hashable {
    case artist
    case album
    case track
    case playlist
}

/// Options influencing how a stream URL is produced.
public struct StreamOptions: Sendable, Hashable {
    /// Upper bound on bitrate in kbps; `nil` requests the best/original.
    public var maxBitrateKbps: Int?
    /// Force a transcode even if direct play would be possible (e.g. on a
    /// metered connection). Downloads always request the original instead.
    public var forceTranscode: Bool

    public init(maxBitrateKbps: Int? = nil, forceTranscode: Bool = false) {
        self.maxBitrateKbps = maxBitrateKbps
        self.forceTranscode = forceTranscode
    }

    public static let bestAvailable = StreamOptions()
}

/// A resolved, playable URL for a track plus how it will be delivered.
public struct StreamSource: Sendable, Hashable {
    public var url: URL
    /// Whether the server will transcode (vs direct play of the original).
    public var isTranscoded: Bool
    /// The session id sent to the server, needed to report progress/stop for
    /// the same session. `nil` for backends that don't use one.
    public var sessionID: String?

    public init(url: URL, isTranscoded: Bool, sessionID: String? = nil) {
        self.url = url
        self.isTranscoded = isTranscoded
        self.sessionID = sessionID
    }
}

/// Coarse playback state reported back to the server for scrobbling / resume.
public enum PlaybackState: String, Sendable, Hashable {
    case playing
    case paused
    case stopped
}

/// A single playback progress report.
public struct PlaybackReport: Sendable, Hashable {
    public var track: Track
    public var state: PlaybackState
    public var positionSeconds: TimeInterval
    /// The stream session id, if the stream URL was created with one.
    public var sessionID: String?

    public init(
        track: Track,
        state: PlaybackState,
        positionSeconds: TimeInterval,
        sessionID: String? = nil
    ) {
        self.track = track
        self.state = state
        self.positionSeconds = positionSeconds
        self.sessionID = sessionID
    }
}

/// The fresh, music-centric backend abstraction that both Plex and Jellyfin
/// implement.
///
/// Design notes (why this shape, and how it differs from Plozz):
/// - **Catalog-first, not screen-first.** The primary job is to *enumerate the
///   whole music catalog in pages* so the sync engine can mirror it into the
///   local database. There is no `MediaProvider`/`MusicProvider` split and no
///   video concepts; the surface is exactly what a music library needs.
/// - **URLs, not bytes.** The backend resolves stream and original-file URLs;
///   it never fetches audio itself. Playback and downloads own the transfer,
///   which keeps this layer trivially testable and lets AVFoundation / the
///   background `URLSession` do what they are good at.
/// - **Capabilities are explicit.** Feature differences surface through
///   ``detectCapabilities()`` rather than callers branching on ``BackendKind``.
/// - **Sendable & stateless-ish.** Implementations hold only immutable
///   configuration (base URL, token, client info) so they are safe to share
///   across the concurrency domains that sync, playback and downloads run in.
public protocol MusicBackend: Sendable {
    /// Which backend this is (used only where a real protocol difference
    /// forces a branch; prefer capabilities elsewhere).
    var kind: BackendKind { get }

    /// The connection this backend serves.
    var connection: ServerConnection { get }

    // MARK: Capability detection

    /// Probe the server for version and optional-feature support.
    func detectCapabilities() async throws -> ServerCapabilities

    // MARK: Catalog enumeration (drives sync into the local database)

    func fetchArtists(offset: Int, limit: Int) async throws -> CatalogPage<Artist>
    func fetchAlbums(offset: Int, limit: Int) async throws -> CatalogPage<Album>
    func fetchTracks(offset: Int, limit: Int) async throws -> CatalogPage<Track>
    func fetchPlaylists(offset: Int, limit: Int) async throws -> CatalogPage<Playlist>
    /// Ordered items of a single playlist.
    func fetchPlaylistItems(playlistID: String, offset: Int, limit: Int) async throws -> CatalogPage<Track>

    /// Fetch full media details (audio format, file size) for specific tracks.
    /// Used to backfill data a backend deliberately omits from its light catalog
    /// sync for speed. Default: `[]` — a backend whose bulk `fetchTracks` already
    /// carries full format needs no backfill.
    func fetchTrackDetails(ids: [String]) async throws -> [Track]

    /// Authoritative, prune-safe enumeration of *every* track in the catalog.
    ///
    /// Some backends can enumerate their whole library in a stable order with a
    /// derivable expected total (e.g. Subsonic walks its album list and sums the
    /// per-album song counts). When a backend can do this it should return a
    /// stream here; the sync engine prefers it over the flat
    /// ``fetchTracks(offset:limit:)`` pager for the unbounded tracks phase and,
    /// crucially, only authorizes a destructive prune when a page reports a
    /// `totalCount` the run can prove it reached. Returning `nil` (the default)
    /// means "I have no better enumeration than the flat pager" — the engine
    /// falls back to ``fetchTracks(offset:limit:)`` and Plex/Jellyfin are
    /// entirely unaffected.
    ///
    /// The stream must yield deduplicated tracks in a stable order. A page's
    /// `totalCount`, when non-nil, is a *provable expected total*: the engine
    /// treats "distinct tracks seen ≥ totalCount" as completeness for prune
    /// authorization, so a backend must only populate it when it is a real,
    /// reached-by-exhaustion count (never an estimate).
    func enumerateAllTracks(pageSize: Int) -> AsyncThrowingStream<CatalogPage<Track>, any Error>?

    // MARK: Incremental catch-up

    /// How many tracks the server holds, asked as cheaply as the protocol allows
    /// — a count with no rows attached.
    ///
    /// This is the "is there anything new?" probe, and it is deliberately the
    /// entire cost of the common case where there isn't. A few hundred bytes
    /// answers the question; re-downloading a page of songs already in the
    /// catalog to discover the same thing would cost tens of kilobytes and, far
    /// more expensively on a phone, hold the cellular radio awake to do it.
    ///
    /// `nil` means the backend cannot count cheaply. Callers must then skip the
    /// incremental path rather than fall back to something costlier — a guess
    /// that burns battery is worse than not checking.
    func libraryTrackCount() async throws -> Int?

    /// A page of tracks ordered newest-added first, or `nil` when the backend
    /// has no notion of "recently added" it can sort on.
    ///
    /// Paired with the count probe this gives a catch-up sync: walk back from the
    /// newest track and stop at the first page holding nothing the catalog is
    /// missing. It enumerates a slice by design, so — like the quick start — it
    /// never reports a total and can never authorize a prune.
    func fetchRecentlyAddedTracks(offset: Int, limit: Int) async throws -> CatalogPage<Track>?

    /// A page of albums ordered newest-added first, or `nil` when unsupported.
    ///
    /// Catching up on tracks alone would leave a newly-added album with songs in
    /// the catalog but no album row to browse to, so the walk covers both.
    func fetchRecentlyAddedAlbums(offset: Int, limit: Int) async throws -> CatalogPage<Album>?

    // MARK: Playback & downloads

    /// Resolve a playable stream URL for a track.
    func streamSource(for track: Track, options: StreamOptions) async throws -> StreamSource

    /// Resolve a playable stream URL that begins `startSeconds` into the track.
    ///
    /// For direct-play (and any range-seekable stream) the offset is irrelevant —
    /// the player seeks natively — so the default implementation ignores it. It
    /// matters only for **progressive transcodes**, which are not byte-range
    /// seekable (e.g. Jellyfin serves them `Accept-Ranges: none`): those seek by
    /// re-requesting the stream with a server-side start offset that restarts the
    /// transcoder. Backends that support this set ``supportsTranscodeSeek`` and
    /// override this method.
    func streamSource(for track: Track, options: StreamOptions, startSeconds: TimeInterval) async throws -> StreamSource

    /// Whether the backend can seek a **transcoded** stream by re-requesting it
    /// with a server-side start offset (see ``streamSource(for:options:startSeconds:)``).
    /// `false` backends fall back to native player seeking, which only works on
    /// range-seekable (direct-play / downloaded) content.
    var supportsTranscodeSeek: Bool { get }

    /// The URL of the untouched original file, for offline download. Throws
    /// ``MozzError/unsupported(_:)`` if the server cannot serve originals.
    func originalFileURL(for track: Track) throws -> URL

    /// Build a tokenized artwork URL for a reference at (at least) the given
    /// pixel size. Returns `nil` if the reference cannot be resolved.
    func artworkURL(for artwork: ArtworkRef, size: Int) -> URL?

    /// A directly loadable URL for the **signed-in user's** profile photo at
    /// (at least) `size` px, or `nil` when the account has no photo — or the
    /// server has no concept of one.
    ///
    /// Async because no backend can form this URL from local state alone: it has
    /// to ask the server who the user is first (Jellyfin needs the image tag,
    /// Plex the account thumb). Callers treat `nil` as "show the generic icon",
    /// so a failed request is indistinguishable from "no photo" by design — this
    /// is decoration and must never surface an error.
    func userAvatarURL(size: Int) async -> URL?

    // MARK: Writes (gated by capabilities)

    /// Set or clear a favorite. Throws ``MozzError/unsupported(_:)`` if the
    /// server has no favorites concept.
    func setFavorite(_ isFavorite: Bool, itemID: String, type: CatalogItemType) async throws

    /// Set or clear a 0–5 star rating (half-steps). `stars == nil` clears it.
    /// Throws ``MozzError/unsupported(_:)`` if the server has no ratings concept
    /// (Jellyfin — it uses favorites instead).
    func setRating(_ stars: Double?, itemID: String, type: CatalogItemType) async throws

    /// Report playback progress / scrobble. No-op by default.
    func reportPlayback(_ report: PlaybackReport) async throws

    // MARK: Lyrics

    /// The track's lyrics as stored by the server, or `nil` when it genuinely has
    /// none.
    ///
    /// The distinction between "no lyrics" and "couldn't ask" is load-bearing: the
    /// resolver caches a negative answer, so a conformer MUST return `nil` only for
    /// an authoritative empty answer from a server it actually reached, and
    /// **throw** for any transport failure (offline, DNS, TLS, timeout, expired
    /// session). Returning `nil` on a network blip would burn a permanent "no
    /// lyrics" into the cache for a track that has them.
    ///
    /// Default: `nil` — correct for a backend with no lyrics concept.
    func fetchLyrics(for track: Track) async throws -> Lyrics?
}

public extension MusicBackend {
    var kind: BackendKind { connection.kind }

    /// Default: no server-side transcode seeking; native player seeking is used.
    var supportsTranscodeSeek: Bool { false }

    /// Default: ignore the offset and resolve the normal stream URL. Correct for
    /// range-seekable content (direct play / downloads), which the player seeks
    /// natively. Backends with a non-seekable progressive transcode override this.
    func streamSource(for track: Track, options: StreamOptions, startSeconds: TimeInterval) async throws -> StreamSource {
        try await streamSource(for: track, options: options)
    }

    /// Default: progress reporting is optional and silently ignored.
    func reportPlayback(_ report: PlaybackReport) async throws {}

    /// Default: no backfill needed (the bulk sync already carries full details).
    func fetchTrackDetails(ids: [String]) async throws -> [Track] { [] }

    /// Default: no specialized bulk enumeration; the sync engine uses the flat
    /// ``fetchTracks(offset:limit:)`` pager instead.
    func enumerateAllTracks(pageSize: Int) -> AsyncThrowingStream<CatalogPage<Track>, any Error>? { nil }

    /// Default: no cheap count, so the incremental catch-up sits this backend out
    /// and its library refreshes on the explicit "Sync Now" instead.
    func libraryTrackCount() async throws -> Int? { nil }

    /// Default: no date-added ordering to walk.
    func fetchRecentlyAddedTracks(offset: Int, limit: Int) async throws -> CatalogPage<Track>? { nil }

    /// Default: no date-added ordering to walk.
    func fetchRecentlyAddedAlbums(offset: Int, limit: Int) async throws -> CatalogPage<Album>? { nil }

    /// Default: no user photo. Correct for every server that doesn't store one
    /// (and for the offline demo backend).
    func userAvatarURL(size: Int) async -> URL? { nil }

    /// Default: the backend has no lyrics concept. An authoritative "none" rather
    /// than a failure, so the resolver is free to fall back to LRCLIB.
    func fetchLyrics(for track: Track) async throws -> Lyrics? { nil }
}
