import Foundation

/// A ``CredentialStore`` that splits keys between two backing stores: the ones
/// named in `syncedKeys` go to a store that replicates through iCloud Keychain,
/// everything else stays device-local.
///
/// This exists because the split is *per key*, not per app. The signed-in
/// session should follow the user to their iPad; the client identifier must NOT
/// — it's the device id the app presents to Plex/Jellyfin, and two devices
/// claiming the same one register as a single device on the server.
///
/// Reads of a synced key fall back to the local store once and **promote** what
/// they find, so a user who signed in before this existed keeps their session
/// instead of being logged out by the upgrade.
public final class RoutingCredentialStore: CredentialStore, @unchecked Sendable {
    private let local: any CredentialStore
    private let synced: any CredentialStore
    private let syncedKeys: Set<String>

    public init(local: any CredentialStore, synced: any CredentialStore, syncedKeys: Set<String>) {
        self.local = local
        self.synced = synced
        self.syncedKeys = syncedKeys
    }

    public func string(forKey key: String) throws -> String? {
        guard syncedKeys.contains(key) else { return try local.string(forKey: key) }
        if let value = try synced.string(forKey: key) { return value }
        // Nothing in iCloud yet. A pre-upgrade session is still sitting in the
        // device-local item, so move it across — after which this device's
        // session is what seeds the user's other devices.
        guard let legacy = try local.string(forKey: key) else { return nil }
        try? synced.setString(legacy, forKey: key)
        try? local.setString(nil, forKey: key)
        return legacy
    }

    public func setString(_ value: String?, forKey key: String) throws {
        guard syncedKeys.contains(key) else {
            try local.setString(value, forKey: key)
            return
        }
        try synced.setString(value, forKey: key)
        // Drop any stale device-local copy, so a sign-out can't be undone by the
        // promotion path above resurrecting the pre-upgrade item on next launch.
        try? local.setString(nil, forKey: key)
    }
}
