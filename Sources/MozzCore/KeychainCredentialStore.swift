import Foundation
#if canImport(Security)
import Security
#endif

// The Keychain is an Apple framework, so this whole file is an Apple-only
// *implementation* of the platform-free ``CredentialStore`` protocol — which is
// precisely why that protocol exists. Windows and Android supply their own
// (Credential Manager / DPAPI, the Android Keystore) behind the same seam, and
// nothing above this layer changes.
//
// Without the guard, importing `Security` unconditionally makes MozzCore
// unbuildable off Apple platforms, which defeats the point of MozzCore being
// the portable layer.
#if canImport(Security)

/// Keychain-backed ``CredentialStore`` used by the app.
///
/// Items are stored as generic passwords under a single service, keyed by the
/// caller's key as the account.
///
/// Two accessibility policies, chosen per store:
///
/// * **Device-local** (default) — `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
///   readable while the device is unlocked after first unlock (so background
///   downloads and audio can resume), never migrated to another device.
/// * **Synchronizable** — rides iCloud Keychain to the user's other devices, so
///   signing in on the iPhone signs you in on the iPad. iCloud Keychain refuses
///   `ThisDeviceOnly` accessibility, so these use plain
///   `kSecAttrAccessibleAfterFirstUnlock`.
///
/// The two are separate item namespaces even for the same key: a keychain query
/// that doesn't mention `kSecAttrSynchronizable` matches only non-synchronizable
/// items, so a store never sees the other's items. Moving a key between them is
/// therefore an explicit copy — see ``RoutingCredentialStore``.
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    private let service: String
    private let synchronizable: Bool

    public init(service: String = "com.thatcube.Mozz.credentials", synchronizable: Bool = false) {
        self.service = service
        self.synchronizable = synchronizable
    }

    private func baseQuery(forKey key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        // Only set on the syncing store: an absent attribute already means
        // "non-synchronizable items only", which is exactly the local store.
        if synchronizable { query[kSecAttrSynchronizable as String] = kCFBooleanTrue }
        return query
    }

    public func string(forKey key: String) throws -> String? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                return nil
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw MozzError.transport("Keychain read failed (\(status))")
        }
    }

    public func setString(_ value: String?, forKey key: String) throws {
        guard let value else {
            try remove(forKey: key)
            return
        }
        let data = Data(value.utf8)
        let query = baseQuery(forKey: key)

        // Try update first; if the item doesn't exist, add it.
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = synchronizable
                ? kSecAttrAccessibleAfterFirstUnlock
                : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw MozzError.transport("Keychain add failed (\(addStatus))")
            }
        default:
            throw MozzError.transport("Keychain update failed (\(updateStatus))")
        }
    }

    private func remove(forKey key: String) throws {
        let status = SecItemDelete(baseQuery(forKey: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MozzError.transport("Keychain delete failed (\(status))")
        }
    }
}
#endif
