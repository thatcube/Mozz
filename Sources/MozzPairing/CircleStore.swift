import Foundation

/// Storage backed by the platform's secure store — Keychain, Keystore, DPAPI.
///
/// Separate from ``PlainStore`` on purpose. `spec/channel` rests the entire
/// credential design on the two living in different places: someone who copies
/// the app's files or restores its backup gets a listening history, and reaching
/// the server tokens additionally requires the secure store. Two keys in one
/// file would be decoration.
public protocol SecureStore: Sendable {
    func secret(forKey key: String) throws -> Data?
    func setSecret(_ value: Data?, forKey key: String) throws
}

/// Ordinary application storage. Fine for things whose loss is embarrassing
/// rather than dangerous.
public protocol PlainStore: Sendable {
    func value(forKey key: String) throws -> Data?
    func setValue(_ value: Data?, forKey key: String) throws
}

/// Where a circle lives on one device, split across the two tiers.
///
/// `credentialsKey` goes to the secure store and everything else to plain
/// storage. That split is load-bearing rather than tidy, so
/// `CircleStoreTests` asserts the credentials key cannot be found anywhere in
/// plain storage — a refactor that "simplified" this into one blob would
/// otherwise pass every other test.
public struct CircleStore: Sendable {
    public enum Key {
        public static let credentials = "circle.credentialsKey"
        public static let rest = "circle.record"
    }

    private let secure: SecureStore
    private let plain: PlainStore

    public init(secure: SecureStore, plain: PlainStore) {
        self.secure = secure
        self.plain = plain
    }

    /// Everything except the credentials key, which is deliberately absent.
    private struct Record: Codable {
        let channelId: String
        let channelKey: Data
        let epoch: Int
        let relayKey: Data
    }

    public func save(_ secrets: CircleSecrets) throws {
        try secure.setSecret(secrets.credentialsKey, forKey: Key.credentials)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try plain.setValue(try encoder.encode(Record(channelId: secrets.channelId,
                                                     channelKey: secrets.channelKey,
                                                     epoch: secrets.epoch,
                                                     relayKey: secrets.relayKey)),
                           forKey: Key.rest)
    }

    /// `nil` when this device is not in a circle.
    ///
    /// Half a circle is treated as none. If the secure store were wiped while
    /// plain storage survived — a restore onto a new device does exactly this —
    /// returning a partial circle would mean syncing history while silently
    /// unable to read any server, which looks like corruption. Better to be
    /// plainly unpaired and ask.
    public func load() throws -> CircleSecrets? {
        guard let credentialsKey = try secure.secret(forKey: Key.credentials),
              let encoded = try plain.value(forKey: Key.rest) else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: encoded)
        return CircleSecrets(channelId: record.channelId,
                             channelKey: record.channelKey,
                             credentialsKey: credentialsKey,
                             epoch: record.epoch,
                             relayKey: record.relayKey)
    }

    /// Leave the circle. Clears the secret first: a crash midway leaves a device
    /// that cannot decrypt anything rather than one still holding tokens.
    public func clear() throws {
        try secure.setSecret(nil, forKey: Key.credentials)
        try plain.setValue(nil, forKey: Key.rest)
    }
}

/// For tests, and for platforms before their secure store is wired up.
public final class InMemoryStore: SecureStore, PlainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func secret(forKey key: String) throws -> Data? { read(key) }
    public func setSecret(_ value: Data?, forKey key: String) throws { write(value, key) }

    public func value(forKey key: String) throws -> Data? { read(key) }
    public func setValue(_ value: Data?, forKey key: String) throws { write(value, key) }

    private func read(_ key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[key]
    }

    private func write(_ value: Data?, _ key: String) {
        lock.lock(); defer { lock.unlock() }
        items[key] = value
    }

    /// Every byte held, for tests that need to assert something is *not* here.
    public var everythingStored: [Data] {
        lock.lock(); defer { lock.unlock() }
        return Array(items.values)
    }
}

/// Plain storage on top of `UserDefaults`.
public struct UserDefaultsStore: PlainStore, @unchecked Sendable {
    // UserDefaults is thread-safe but not marked Sendable.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = .standard, prefix: String = "mozz.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    public func value(forKey key: String) throws -> Data? { defaults.data(forKey: prefix + key) }

    public func setValue(_ value: Data?, forKey key: String) throws {
        if let value {
            defaults.set(value, forKey: prefix + key)
        } else {
            defaults.removeObject(forKey: prefix + key)
        }
    }
}
