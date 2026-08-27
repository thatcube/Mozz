import Crypto
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
        public static let members = "circle.members"
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

    /// The devices this one knows are in the circle.
    ///
    /// Local knowledge, not authoritative membership: a device learns about
    /// another when it takes part in a ceremony with it, or when the relay
    /// carries its writes. Without this, "you are in a circle" is a claim with
    /// nothing behind it — someone looking at the screen cannot tell whether it
    /// worked, which is exactly the question the screen exists to answer.
    public func members() throws -> [CircleMember] {
        guard let encoded = try plain.value(forKey: Key.members) else { return [] }
        return (try? JSONDecoder().decode([CircleMember].self, from: encoded)) ?? []
    }

    /// Records a device, replacing any earlier entry for the same stable id.
    ///
    /// Names are labels and can collide or change. Using one as identity made
    /// two iPhones called "iPhone" overwrite each other in the roster and would
    /// do the same to relay ownership if allowed to escape this type.
    public func remember(_ member: CircleMember) throws {
        var known = try members().filter { $0.id != member.id }
        known.append(member)
        known.sort { $0.joinedAt > $1.joinedAt }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try plain.setValue(try encoder.encode(known), forKey: Key.members)
    }

    public func replaceMembers(_ members: [CircleMember]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try plain.setValue(
            try encoder.encode(members.sorted { $0.joinedAt > $1.joinedAt }),
            forKey: Key.members)
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

    /// The circle this device is in, creating one if it is not in any yet.
    ///
    /// Someone has to go first. `join` needs a member to seal a circle to it and
    /// `admit` needs a circle to hand over, so without this every device waits
    /// for a circle that never comes into existence. A device that is alone and
    /// is asked to admit another simply forms one.
    public func loadOrCreate() throws -> CircleSecrets {
        if let existing = try load() { return existing }
        let created = CircleSecrets.new()
        try save(created)
        return created
    }

    /// Leave the circle. Clears the secret first: a crash midway leaves a device
    /// that cannot decrypt anything rather than one still holding tokens.
    public func clear() throws {
        try secure.setSecret(nil, forKey: Key.credentials)
        try plain.setValue(nil, forKey: Key.rest)
        try plain.setValue(nil, forKey: Key.members)
    }
}

/// A device known to be in the circle.
public struct CircleMember: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let joinedAt: Date
    /// True for the device reading this, so a list can say "this device".
    public let isSelf: Bool

    public init(
        id: String,
        name: String,
        joinedAt: Date = Date(),
        isSelf: Bool = false
    ) {
        self.id = id
        self.name = name
        self.joinedAt = joinedAt
        self.isSelf = isSelf
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, joinedAt, isSelf
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        // Builds before stable relay ownership stored names only. Preserve those
        // rows in the UI under a migration id; the next successful ceremony
        // replaces them with the authenticated device id.
        id = try values.decodeIfPresent(String.self, forKey: .id)
            ?? "legacy:\(name)"
        joinedAt = try values.decode(Date.self, forKey: .joinedAt)
        isSelf = try values.decode(Bool.self, forKey: .isSelf)
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
