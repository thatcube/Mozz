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
    /// The generic OpenSubsonic / Subsonic API. One conformer covers every
    /// server that speaks that dialect (Navidrome — QA'd; Gonic, Ampache, LMS —
    /// best-effort). The specific server product is detected at runtime and
    /// surfaced via ``ServerCapabilities/serverProductType`` for display.
    case subsonic

    /// Human-facing name for the backend. This is the *protocol* label, not the
    /// server product — the app shows the detected product name (e.g.
    /// "Navidrome 0.51") alongside where relevant.
    public var displayName: String {
        switch self {
        case .plex: return "Plex"
        case .jellyfin: return "Jellyfin"
        case .subsonic: return "Subsonic"
        }
    }
}
