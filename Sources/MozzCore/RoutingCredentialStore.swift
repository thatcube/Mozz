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
        if let value = try synced.string(forKey: key) {
            // Keep the mirror current, so the device can answer this question by
            // itself next time.
            if (try? local.string(forKey: key)) != value {
                try? local.setString(value, forKey: key)
            }
            return value
        }
        // iCloud has nothing to say. That is NOT the same as the user being
        // signed out, and treating it that way is what "it keeps signing me out
        // of Plex" was: the synchronizable item is not always readable — it has
        // not propagated to this device yet, the account is between syncs, the
        // keychain is briefly unavailable — and with the session living ONLY
        // there, every one of those looked like a sign-out and sent the user
        // back to link their account again. It would then reappear on its own
        // once the item synced, which is exactly how an intermittent fault of
        // this kind presents.
        //
        // The device-local item is the answer to both that and to the original
        // case this branch was written for (a session saved before syncing
        // existed). Either way, hand it back and push it up.
        guard let mirrored = try local.string(forKey: key) else { return nil }
        try? synced.setString(mirrored, forKey: key)
        return mirrored
    }

    public func setString(_ value: String?, forKey key: String) throws {
        guard syncedKeys.contains(key) else {
            try local.setString(value, forKey: key)
            return
        }
        try synced.setString(value, forKey: key)
        // Mirrored, including the nil of a sign-out — which is what keeps the
        // fallback above from resurrecting a session the user has ended.
        try? local.setString(value, forKey: key)
    }
}
