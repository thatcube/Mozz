import Foundation

/// Identifies a configured server connection.
///
/// Stable across launches and app updates. Generated once when the user adds a
/// server and stored in the database; the auth token for the connection lives
/// separately in the ``CredentialStore`` keyed by this id.
public typealias ServerID = String

/// A configured, addressable connection to a media server.
///
/// This is the value the app persists (minus the secret token, which lives in
/// the keychain). A ``MusicBackend`` is constructed from one of these.
public struct ServerConnection: Codable, Sendable, Hashable, Identifiable {
    public var id: ServerID
    public var kind: BackendKind
    /// Friendly server name for display (e.g. "Living Room Plex").
    public var name: String
    /// Base URL used for all API calls, e.g. `https://192.168.1.10:32400`.
    public var baseURL: URL
    /// The authenticated user's id on this server (Jellyfin needs it for many
    /// endpoints; Plex uses it for multi-user servers).
    public var userID: String?
    /// The stable client identifier this device presents to the server. Must
    /// never be regenerated once issued, or Plex will treat the app as a new
    /// device on every launch.
    public var clientIdentifier: String
    /// For Plex, the library section id that holds music; nil until resolved.
    public var musicSectionID: String?

    public init(
        id: ServerID,
        kind: BackendKind,
        name: String,
        baseURL: URL,
        userID: String? = nil,
        clientIdentifier: String,
        musicSectionID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.userID = userID
        self.clientIdentifier = clientIdentifier
        self.musicSectionID = musicSectionID
    }
}
