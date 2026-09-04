import Foundation
import MozzCore

/// A minimal, serializable description of a signed-in session, persisted to the
/// credential store (Keychain) so the app reconnects on next launch without
/// re-authenticating.
struct StoredSession: Codable, Sendable {
    var kind: BackendKind
    var baseURL: URL
    var token: String
    var userID: String?
    var serverName: String
    var clientIdentifier: String
    var serverMachineIdentifier: String? = nil
    var musicSectionID: String?
    var isDemo: Bool = false
    /// Plex account token (for re-discovering servers in the picker). Nil for
    /// Jellyfin/demo.
    var accountToken: String? = nil
    /// The music library section ids the user chose to sync (Plex). Nil = all
    /// (the default). Decodes to nil for sessions saved before this field.
    var selectedMusicSectionIDs: [String]? = nil
    /// The **server's** machine identifier (Plex). What re-resolution matches on
    /// when the stored address stops answering — the address changes, this does
    /// not. Nil for sessions saved before it was recorded.
    var machineIdentifier: String? = nil
    /// The catalogue's server id, frozen the first time this session is
    /// activated.
    ///
    /// It is otherwise derived by hashing `baseURL`, which quietly makes the
    /// address the identity: repointing a Plex account at a working address
    /// would present as a different server, with an empty catalogue and no
    /// likes or play history. Freezing it lets the address change without
    /// orphaning any of that. See ADR-0017.
    var serverId: String? = nil
}

/// Reads/writes the single active ``StoredSession`` as a JSON blob under one
/// credential key.
///
/// The key is the one entry routed through iCloud Keychain (see
/// ``RoutingCredentialStore``), so a sign-in on one device brings the server up
/// on the user's other devices — and a sign-out clears it everywhere.
enum SessionPersistence {
    static let key = "session.active"

    static func save(_ session: StoredSession, to store: any CredentialStore) {
        guard let data = try? JSONEncoder().encode(session),
              let json = String(data: data, encoding: .utf8) else { return }
        try? store.setString(json, forKey: key)
    }

    static func load(_ store: any CredentialStore) -> StoredSession? {
        guard let json = try? store.string(forKey: key),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    static func clear(_ store: any CredentialStore) {
        try? store.setString(nil, forKey: key)
    }
}
