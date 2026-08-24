import Foundation
import MozzCore

/// A self-contained ``MusicBackend`` used for the in-simulator demo and for
/// running the performance harness without a real server. It serves a bundled
/// short audio clip for *every* track, so the entire chain — queue, gapless
/// advance, now-playing, and offline download — actually works on-device with no
/// network. The catalog itself is produced by the synthetic generator straight
/// into the database.
public struct DemoBackend: MusicBackend {
    public let connection: ServerConnection
    /// Resolves a playable/downloadable file URL for a track. The demo passes a
    /// generator that returns a full-length tone matching the track's duration
    /// (see ``DemoAudioProvider``); a fixed-URL initializer stays available for
    /// the performance harness, which never plays audio.
    private let clipProvider: @Sendable (Track) -> URL
    /// Set only when shooting App Store screenshots, where the catalog is a
    /// curated fixture on disk with real cover art and real audio. Everywhere
    /// else this is nil and the backend behaves exactly as before.
    private let screenshots: ScreenshotLibrary?

    public init(serverId: ServerID, clipProvider: @escaping @Sendable (Track) -> URL,
                screenshots: ScreenshotLibrary? = nil) {
        self.connection = ServerConnection(
            id: serverId,
            kind: .jellyfin,
            name: screenshots == nil ? "Demo Library" : "My Music",
            baseURL: URL(string: "https://synthetic.local")!,
            userID: "demo",
            clientIdentifier: "demo-client"
        )
        self.clipProvider = clipProvider
        self.screenshots = screenshots
    }

    /// Convenience: serve one fixed clip for every track (used where playback
    /// realism doesn't matter, e.g. the performance harness).
    public init(serverId: ServerID, clipURL: URL) {
        self.init(serverId: serverId, clipProvider: { _ in clipURL })
    }

    public func detectCapabilities() async throws -> ServerCapabilities {
        ServerCapabilities(
            backend: .jellyfin, serverVersion: "demo",
            supportsTranscoding: false, supportsOriginalFileDownload: true,
            supportsFavorites: true, supportsLyrics: false
        )
    }

    // The catalog is generated directly into the DB, so enumeration is unused
    // here; return empty pages.
    public func fetchArtists(offset: Int, limit: Int) async throws -> CatalogPage<Artist> { CatalogPage(items: []) }
    public func fetchAlbums(offset: Int, limit: Int) async throws -> CatalogPage<Album> { CatalogPage(items: []) }
    public func fetchTracks(offset: Int, limit: Int) async throws -> CatalogPage<Track> { CatalogPage(items: []) }
    public func fetchPlaylists(offset: Int, limit: Int) async throws -> CatalogPage<Playlist> { CatalogPage(items: []) }
    public func fetchPlaylistItems(playlistID: String, offset: Int, limit: Int) async throws -> CatalogPage<Track> { CatalogPage(items: []) }

    public func streamSource(for track: Track, options: StreamOptions) async throws -> StreamSource {
        StreamSource(url: audioURL(for: track), isTranscoded: false)
    }

    public func originalFileURL(for track: Track) throws -> URL { audioURL(for: track) }

    /// Screenshot fixtures ship real audio per track; the ordinary demo falls
    /// back to a generated tone.
    private func audioURL(for track: Track) -> URL {
        screenshots?.audioURL(forTrackID: track.id) ?? clipProvider(track)
    }

    /// The ordinary demo has no artwork at all, which is exactly why it can't be
    /// used for screenshots: with nothing to sample, the Now Playing backdrop
    /// falls back to a hashed seed colour instead of the album's own palette.
    public func artworkURL(for artwork: ArtworkRef, size: Int) -> URL? {
        screenshots?.coverURL(forArtworkKey: artwork.key)
    }

    public func setFavorite(_ isFavorite: Bool, itemID: String, type: CatalogItemType) async throws {}

    /// Serve the fixture's own `.lrc` sidecars. Without this the screenshot run
    /// would fall through to the online provider, which has never heard of these
    /// tracks — so the lyrics pane would shoot empty.
    public func fetchLyrics(for track: Track) async throws -> Lyrics? {
        screenshots?.lyrics(forTrackID: track.id)
    }

    public func setRating(_ stars: Double?, itemID: String, type: CatalogItemType) async throws {}
}
