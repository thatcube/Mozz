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
    /// A generic Subsonic / OpenSubsonic server (Navidrome, Gonic, Ampache,
    /// LMS, …). Deliberately *not* named `navidrome`: one conformer speaks the
    /// shared protocol, and the concrete server product/version is detected at
    /// runtime (see ``ServerCapabilities/serverProduct``) rather than baked into
    /// the enum.
    case subsonic

    /// Human-facing name for the backend. For Subsonic this is the protocol
    /// name; the detected server product (e.g. "Navidrome") is shown separately
    /// from ``ServerCapabilities`` where a more specific label is useful.
    public var displayName: String {
        switch self {
        case .plex: return "Plex"
        case .jellyfin: return "Jellyfin"
        case .subsonic: return "Subsonic"
        }
    }
}
