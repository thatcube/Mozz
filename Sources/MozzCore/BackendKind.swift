import Foundation

/// The media-server backends Mozz can talk to.
///
/// Mozz is deliberately backend-agnostic: everything above the provider layer
/// (the database, the UI, playback, downloads) works in terms of Mozz's own
/// domain models and never branches on `BackendKind` except where a genuine
/// protocol difference forces it (e.g. building an auth header).
public enum BackendKind: String, Codable, Sendable, Hashable, CaseIterable {
    case plex
    case jellyfin
    /// Subsonic / OpenSubsonic REST API. A single generic conformer covers the
    /// whole family (Navidrome, Gonic, Ampache, LMS, …); the *specific* product
    /// and version are runtime-detected facts on ``ServerCapabilities``
    /// (`serverProduct`/`isOpenSubsonic`), not separate `BackendKind` cases —
    /// there is exactly one Subsonic wire protocol to speak, and branching the
    /// enum per server product would just duplicate the same client for no
    /// behavioral difference. v1 is scoped/QA'd against Navidrome; other
    /// OpenSubsonic servers are best-effort.
    case subsonic

    /// Human-facing name for the backend.
    public var displayName: String {
        switch self {
        case .plex: return "Plex"
        case .jellyfin: return "Jellyfin"
        case .subsonic: return "Subsonic"
        }
    }
}
