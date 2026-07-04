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

    // MARK: Playback & downloads

    /// Resolve a playable stream URL for a track.
    func streamSource(for track: Track, options: StreamOptions) async throws -> StreamSource

    /// The URL of the untouched original file, for offline download. Throws
    /// ``MozzError/unsupported(_:)`` if the server cannot serve originals.
    func originalFileURL(for track: Track) throws -> URL

    /// Build a tokenized artwork URL for a reference at (at least) the given
    /// pixel size. Returns `nil` if the reference cannot be resolved.
    func artworkURL(for artwork: ArtworkRef, size: Int) -> URL?

    // MARK: Writes (gated by capabilities)

    /// Set or clear a favorite. Throws ``MozzError/unsupported(_:)`` if the
    /// server has no favorites concept.
    func setFavorite(_ isFavorite: Bool, itemID: String, type: CatalogItemType) async throws

    /// Report playback progress / scrobble. No-op by default.
    func reportPlayback(_ report: PlaybackReport) async throws
}

public extension MusicBackend {
    var kind: BackendKind { connection.kind }

    /// Default: progress reporting is optional and silently ignored.
    func reportPlayback(_ report: PlaybackReport) async throws {}
}
