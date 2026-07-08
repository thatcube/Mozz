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
    /// Whether this URL is a **non-range-seekable progressive transcode** that
    /// must be re-resolved with a server-side start offset to seek (the player
    /// can't seek it natively). `false` for direct-play / downloaded content,
    /// which seeks natively. See ``TrackURLResolver/resolve(_:startSeconds:)``.
    public var requiresServerSeek: Bool

    public init(url: URL, isLocal: Bool, sessionID: String? = nil, requiresServerSeek: Bool = false) {
        self.url = url
        self.isLocal = isLocal
        self.sessionID = sessionID
        self.requiresServerSeek = requiresServerSeek
    }
}

/// Resolves a domain ``Track`` to a playable URL. Implemented by the app's
/// composition root (offline-first: return the downloaded file if present,
/// otherwise ask the backend for a stream URL).
public protocol TrackURLResolver: Sendable {
    func resolve(_ track: Track) async throws -> ResolvedTrackURL

    /// Resolve a URL that begins `startSeconds` into the track. Used to seek (and
    /// to recover a dropped stream at the last position) a progressive transcode
    /// that can't be seeked natively. The default ignores the offset — correct
    /// for range-seekable content — so only server-seek-capable resolvers override.
    func resolve(_ track: Track, startSeconds: TimeInterval) async throws -> ResolvedTrackURL
}

public extension TrackURLResolver {
    func resolve(_ track: Track, startSeconds: TimeInterval) async throws -> ResolvedTrackURL {
        try await resolve(track)
    }
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
        try await resolve(track, startSeconds: 0)
    }

    public func resolve(_ track: Track, startSeconds: TimeInterval) async throws -> ResolvedTrackURL {
        let source = try await backend.streamSource(for: track, options: options, startSeconds: startSeconds)
        return ResolvedTrackURL(
            url: source.url,
            isLocal: false,
            sessionID: source.sessionID,
            // Only a transcode on a backend that seeks via server offset needs
            // the re-resolve seek path; everything else seeks natively (range).
            requiresServerSeek: source.isTranscoded && backend.supportsTranscodeSeek
        )
    }
}
