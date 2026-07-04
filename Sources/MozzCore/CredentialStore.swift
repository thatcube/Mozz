import Foundation

/// Secure key/value storage for secrets (server tokens, the stable client
/// identifier). Kept behind a protocol so tests use an in-memory double and the
/// app uses the keychain, and so the rest of the code never imports `Security`.
public protocol CredentialStore: Sendable {
    /// Returns the stored string for `key`, or `nil` if absent.
    func string(forKey key: String) throws -> String?
    /// Stores `value` for `key`; passing `nil` removes it.
    func setString(_ value: String?, forKey key: String) throws
}

public extension CredentialStore {
    /// The auth token for a server connection.
    func token(for serverID: ServerID) throws -> String? {
        try string(forKey: "token.\(serverID)")
    }

    /// Store (or, with `nil`, clear) the auth token for a server connection.
    func setToken(_ token: String?, for serverID: ServerID) throws {
        try setString(token, forKey: "token.\(serverID)")
    }

    /// The stable per-install client identifier. Generated once and never
    /// changed thereafter, because Plex treats a new identifier as a brand-new
    /// device (re-triggering authorization and cluttering the account).
    func clientIdentifier(generatingIfMissing: Bool = true) throws -> String {
        if let existing = try string(forKey: "clientIdentifier"), !existing.isEmpty {
            return existing
        }
        guard generatingIfMissing else { return "" }
        let generated = UUID().uuidString
        try setString(generated, forKey: "clientIdentifier")
        return generated
    }
}

/// A thread-safe in-memory credential store for tests and previews.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]

    public init(seed: [String: String] = [:]) {
        self.storage = seed
    }

    public func string(forKey key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func setString(_ value: String?, forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let value {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }
}
