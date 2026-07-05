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

    public init(serverId: ServerID, clipProvider: @escaping @Sendable (Track) -> URL) {
        self.connection = ServerConnection(
            id: serverId,
            kind: .jellyfin,
            name: "Demo Library",
            baseURL: URL(string: "https://synthetic.local")!,
            userID: "demo",
            clientIdentifier: "demo-client"
        )
        self.clipProvider = clipProvider
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
        StreamSource(url: clipProvider(track), isTranscoded: false)
    }

    public func originalFileURL(for track: Track) throws -> URL { clipProvider(track) }

    public func artworkURL(for artwork: ArtworkRef, size: Int) -> URL? { nil }

    public func setFavorite(_ isFavorite: Bool, itemID: String, type: CatalogItemType) async throws {}
}
