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

    /// Human-facing name for the backend.
    public var displayName: String {
        switch self {
        case .plex: return "Plex"
        case .jellyfin: return "Jellyfin"
        }
    }
}
