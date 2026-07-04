import Foundation

/// A track resolved to a concrete, playable URL plus whether it is a local
/// (downloaded) file. The playback layer never decides *where* audio comes
/// from — it delegates to a ``TrackURLResolver`` so the offline/downloads layer
/// can prefer a local file when one exists (this is what makes airplane-mode
/// playback automatic).
public struct ResolvedTrackURL: Sendable, Hashable {
    public var url: URL
    public var isLocal: Bool
    /// Server stream session id, if any, to report progress/stop for the same
    /// session. `nil` for local files.
    public var sessionID: String?

    public init(url: URL, isLocal: Bool, sessionID: String? = nil) {
        self.url = url
        self.isLocal = isLocal
        self.sessionID = sessionID
    }
}

/// Resolves a domain ``Track`` to a playable URL. Implemented by the app's
/// composition root (offline-first: return the downloaded file if present,
/// otherwise ask the backend for a stream URL).
public protocol TrackURLResolver: Sendable {
    func resolve(_ track: Track) async throws -> ResolvedTrackURL
}

/// A resolver that always streams via a backend — the fallback when nothing is
/// downloaded. The offline resolver in MozzDownloads wraps this.
public struct StreamingTrackURLResolver: TrackURLResolver {
    private let backend: any MusicBackend
    private let options: StreamOptions

    public init(backend: any MusicBackend, options: StreamOptions = .bestAvailable) {
        self.backend = backend
        self.options = options
    }

    public func resolve(_ track: Track) async throws -> ResolvedTrackURL {
        let source = try await backend.streamSource(for: track, options: options)
        return ResolvedTrackURL(url: source.url, isLocal: false, sessionID: source.sessionID)
    }
}
