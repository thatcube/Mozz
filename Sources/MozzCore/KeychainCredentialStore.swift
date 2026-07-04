import Foundation
import Security

/// Keychain-backed ``CredentialStore`` used by the app.
///
/// Items are stored as generic passwords under a single service, keyed by the
/// caller's key as the account. Accessibility is
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable while the
/// device is unlocked after first unlock (so background downloads and audio can
/// resume), never migrated to another device via backup.
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.mozz.app.credentials") {
        self.service = service
    }

    private func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
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
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
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
