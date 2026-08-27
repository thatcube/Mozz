import Crypto
import Foundation
import MozzHistory

// MARK: - Provider boundary

/// One object as returned by B2, R2, S3, or a self-hosted equivalent.
public struct RelayStoredObject: Sendable, Equatable {
    public let data: Data
    public let etag: String

    public init(data: Data, etag: String) {
        self.data = data
        self.etag = etag
    }
}

public enum RelayReadResult: Sendable, Equatable {
    case missing
    case notModified
    case object(RelayStoredObject)
}

public enum RelayWriteCondition: Sendable, Equatable {
    case none
    case ifAbsent
    case ifMatch(String)
}

/// The entire provider-specific surface.
///
/// B2 authentication, AWS Signature V4, Cloudflare's public read URL, retries,
/// and HTTP belong in an adapter to this protocol. Channel layout and crypto do
/// not, so switching storage providers remains a configuration change rather
/// than a data migration.
public protocol RelayObjectStore: Sendable {
    func read(path: String, ifNoneMatch: String?) async throws -> RelayReadResult
    func put(
        path: String,
        data: Data,
        condition: RelayWriteCondition
    ) async throws -> String
    func list(prefix: String) async throws -> [String]
}

// MARK: - Manifest

public struct RelayManifestEntry: Codable, Sendable, Equatable {
    public let path: String
    public let plaintextSHA256: String
    public let plaintextBytes: Int
    public let writtenAtMS: Int64
}

public struct RelayDeviceManifest: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var deviceID: String
    public var epoch: Int
    public var generation: Int64
    public var objects: [String: RelayManifestEntry]

    public init(
        version: Int = currentVersion,
        deviceID: String,
        epoch: Int,
        generation: Int64 = 0,
        objects: [String: RelayManifestEntry] = [:]
    ) {
        self.version = version
        self.deviceID = deviceID
        self.epoch = epoch
        self.generation = generation
        self.objects = objects
    }
}

public enum RelayStoreError: Error, Equatable {
    case invalidPathComponent(String)
    case invalidKeyLength(Int)
    case invalidEpoch(Int)
    case objectTooLarge(actual: Int, maximum: Int)
    case changedWithoutBody(String)
    case manifestPathMismatch(String)
    case payloadDeviceMismatch(expected: String, actual: String)
    case plaintextHashMismatch(String)
    case unsupportedManifestVersion(Int)
    case unsupportedCiphertextVersion(Int)
    case missingCredentialsKey
    case invalidServerRecord(String)
}

// MARK: - Server credentials

/// One server connection as synchronized between devices.
///
/// `clientIdentifier` is deliberately absent. It identifies one app
/// installation to the media server; sharing it makes two devices register as
/// one and fight over sessions. Everything required to authenticate the chosen
/// server/profile is here, encrypted under `credentialsKey`.
public struct RelayServerRecord: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var name: String?
    public var baseURL: String?
    public var token: String?
    public var accountToken: String?
    public var userID: String?
    public var username: String?
    public var serverMachineIdentifier: String?
    public var musicSectionIDs: [String]?
    public var updatedAtMS: Int64
    public var removedAtMS: Int64?

    public init(
        id: String,
        kind: String,
        name: String? = nil,
        baseURL: String? = nil,
        token: String? = nil,
        accountToken: String? = nil,
        userID: String? = nil,
        username: String? = nil,
        serverMachineIdentifier: String? = nil,
        musicSectionIDs: [String]? = nil,
        updatedAtMS: Int64,
        removedAtMS: Int64? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.token = token
        self.accountToken = accountToken
        self.userID = userID
        self.username = username
        self.serverMachineIdentifier = serverMachineIdentifier
        self.musicSectionIDs = musicSectionIDs
        self.updatedAtMS = updatedAtMS
        self.removedAtMS = removedAtMS
    }

    public var mutationAtMS: Int64 {
        max(updatedAtMS, removedAtMS ?? .min)
    }

    public var isRemoved: Bool { removedAtMS != nil }

    public static func tombstone(
        id: String,
        kind: String,
        removedAtMS: Int64
    ) -> RelayServerRecord {
        RelayServerRecord(
            id: id,
            kind: kind,
            updatedAtMS: removedAtMS,
            removedAtMS: removedAtMS)
    }

    func validated() throws -> RelayServerRecord {
        guard !id.isEmpty, ["plex", "jellyfin", "subsonic"].contains(kind) else {
            throw RelayStoreError.invalidServerRecord(id)
        }
        if !isRemoved {
            guard let baseURL, URL(string: baseURL) != nil,
                  token?.isEmpty == false else {
                throw RelayStoreError.invalidServerRecord(id)
            }
        }
        return self
    }
}

public struct RelayServerSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var deviceID: String
    public var writtenAtMS: Int64
    public var servers: [RelayServerRecord]

    public init(
        version: Int = currentVersion,
        deviceID: String,
        writtenAtMS: Int64,
        servers: [RelayServerRecord]
    ) {
        self.version = version
        self.deviceID = deviceID
        self.writtenAtMS = writtenAtMS
        self.servers = servers
    }
}

// MARK: - Encrypted history store

/// Listening history over the zero-knowledge relay.
///
/// Each device owns one object prefix and one manifest. There is no
/// channel-wide writable object, so ten devices can publish at once without
/// compare-and-swap or last-writer-wins erasing nine of them.
public actor RelayHistoryStore: HistoryStore {
    public nonisolated let maximumBatchBytes = 256 * 1024
    public static let maximumPlaintextBytes = 512 * 1024

    private struct CachedObject {
        let etag: String
        let plaintext: Data
    }

    private let objects: any RelayObjectStore
    private let channelID: String
    private let localDeviceID: String
    private let epoch: Int
    private let key: SymmetricKey
    private let credentialsKey: SymmetricKey?
    private var cache: [String: CachedObject] = [:]

    public init(
        objects: any RelayObjectStore,
        channelID: String,
        localDeviceID: String,
        epoch: Int,
        channelKey: Data,
        credentialsKey: Data? = nil
    ) throws {
        guard channelKey.count == 32 else {
            throw RelayStoreError.invalidKeyLength(channelKey.count)
        }
        guard epoch > 0 else { throw RelayStoreError.invalidEpoch(epoch) }
        self.objects = objects
        self.channelID = try Self.pathComponent(channelID)
        self.localDeviceID = try Self.pathComponent(localDeviceID)
        self.epoch = epoch
        self.key = SymmetricKey(data: channelKey)
        if let credentialsKey {
            guard credentialsKey.count == 32 else {
                throw RelayStoreError.invalidKeyLength(credentialsKey.count)
            }
            self.credentialsKey = SymmetricKey(data: credentialsKey)
        } else {
            self.credentialsKey = nil
        }
    }

    public func loadBatches() async throws -> [HistoryBatch] {
        var batches: [HistoryBatch] = []
        for (path, manifest) in try await manifests() {
            guard let entry = manifest.objects["history"] else { continue }
            try validate(entry: entry, manifestPath: path, manifest: manifest)
            guard let plaintext = try await readPlaintext(path: entry.path) else {
                continue
            }
            try validate(plaintext: plaintext, against: entry)
            let batch = try JSONDecoder().decode(HistoryBatch.self, from: plaintext)
            guard batch.deviceID == manifest.deviceID else {
                throw RelayStoreError.payloadDeviceMismatch(
                    expected: manifest.deviceID, actual: batch.deviceID)
            }
            batches.append(batch)
        }
        return batches
    }

    public func save(_ batch: HistoryBatch) async throws {
        guard batch.deviceID == localDeviceID else {
            throw RelayStoreError.payloadDeviceMismatch(
                expected: localDeviceID, actual: batch.deviceID)
        }
        try await save(
            batch,
            objectKey: "history",
            pathPrefix: "\(devicePrefix)\(localDeviceID)/history/\(epoch)/batch",
            maximumBytes: maximumBatchBytes,
            writtenAtMS: batch.writtenAtMS)
    }

    public func loadRollups(year: Int) async throws -> [HistoryRollup] {
        var rollups: [HistoryRollup] = []
        let objectKey = "rollup:\(year)"
        for (path, manifest) in try await manifests() {
            guard let entry = manifest.objects[objectKey] else { continue }
            try validate(entry: entry, manifestPath: path, manifest: manifest)
            guard let plaintext = try await readPlaintext(path: entry.path) else {
                continue
            }
            try validate(plaintext: plaintext, against: entry)
            let rollup = try JSONDecoder().decode(HistoryRollup.self, from: plaintext)
            guard rollup.deviceID == manifest.deviceID else {
                throw RelayStoreError.payloadDeviceMismatch(
                    expected: manifest.deviceID, actual: rollup.deviceID)
            }
            guard rollup.year == year else { continue }
            rollups.append(rollup)
        }
        return rollups
    }

    public func save(_ rollup: HistoryRollup) async throws {
        guard rollup.deviceID == localDeviceID else {
            throw RelayStoreError.payloadDeviceMismatch(
                expected: localDeviceID, actual: rollup.deviceID)
        }
        try await save(
            rollup,
            objectKey: "rollup:\(rollup.year)",
            pathPrefix: "\(devicePrefix)\(localDeviceID)/history/\(epoch)/rollup/\(rollup.year)",
            maximumBytes: Self.maximumPlaintextBytes,
            writtenAtMS: rollup.updatedAtMS)
    }

    // MARK: Server credentials

    public func loadServerSnapshots() async throws -> [RelayServerSnapshot] {
        guard let credentialsKey else {
            throw RelayStoreError.missingCredentialsKey
        }
        var snapshots: [RelayServerSnapshot] = []
        for (path, manifest) in try await manifests() {
            guard let entry = manifest.objects["servers"] else { continue }
            try validate(entry: entry, manifestPath: path, manifest: manifest)
            guard let plaintext = try await readPlaintext(
                path: entry.path, using: credentialsKey) else {
                continue
            }
            try validate(plaintext: plaintext, against: entry)
            let snapshot = try JSONDecoder().decode(
                RelayServerSnapshot.self, from: plaintext)
            guard snapshot.version == RelayServerSnapshot.currentVersion else {
                continue
            }
            guard snapshot.deviceID == manifest.deviceID else {
                throw RelayStoreError.payloadDeviceMismatch(
                    expected: manifest.deviceID, actual: snapshot.deviceID)
            }
            _ = try snapshot.servers.map { try $0.validated() }
            snapshots.append(snapshot)
        }
        return snapshots
    }

    public func save(_ snapshot: RelayServerSnapshot) async throws {
        guard let credentialsKey else {
            throw RelayStoreError.missingCredentialsKey
        }
        guard snapshot.deviceID == localDeviceID else {
            throw RelayStoreError.payloadDeviceMismatch(
                expected: localDeviceID, actual: snapshot.deviceID)
        }
        _ = try snapshot.servers.map { try $0.validated() }
        try await save(
            snapshot,
            objectKey: "servers",
            pathPrefix: "\(devicePrefix)\(localDeviceID)/servers/\(epoch)/snapshot",
            maximumBytes: 128 * 1024,
            writtenAtMS: snapshot.writtenAtMS,
            using: credentialsKey)
    }

    /// Merge snapshots by stable server id. A tombstone is a write, not an
    /// absence, and wins an exact timestamp tie so deletion cannot be undone by
    /// a stale active record from another device.
    public static func mergedServerRecords(
        _ snapshots: [RelayServerSnapshot]
    ) -> [RelayServerRecord] {
        var selected: [String: (RelayServerRecord, String)] = [:]
        for snapshot in snapshots {
            for record in snapshot.servers {
                guard let current = selected[record.id] else {
                    selected[record.id] = (record, snapshot.deviceID)
                    continue
                }
                let shouldReplace =
                    record.mutationAtMS > current.0.mutationAtMS
                    || (record.mutationAtMS == current.0.mutationAtMS
                        && record.isRemoved && !current.0.isRemoved)
                    || (record.mutationAtMS == current.0.mutationAtMS
                        && record.isRemoved == current.0.isRemoved
                        && snapshot.deviceID > current.1)
                if shouldReplace {
                    selected[record.id] = (record, snapshot.deviceID)
                }
            }
        }
        return selected.values.map(\.0).sorted { $0.id < $1.id }
    }

    // MARK: Write

    private func save<Value: Encodable>(
        _ value: Value,
        objectKey: String,
        pathPrefix: String,
        maximumBytes: Int,
        writtenAtMS: Int64,
        using objectKeyEncryption: SymmetricKey? = nil
    ) async throws {
        let plaintext = try Self.encode(value)
        guard plaintext.count <= maximumBytes else {
            throw RelayStoreError.objectTooLarge(
                actual: plaintext.count, maximum: maximumBytes)
        }
        let hash = Self.sha256(plaintext)
        // Content-addressed objects are immutable. If two app processes for the
        // same device race, they write different paths and then contend only on
        // the manifest. A single mutable "current" path lets the losing process
        // replace the body before the winning manifest lands, producing a
        // manifest/hash mismatch for every reader.
        let path = "\(pathPrefix)/\(hash)"

        var manifest = try await latestManifest(for: localDeviceID)
            ?? RelayDeviceManifest(deviceID: localDeviceID, epoch: epoch)

        // The primary cost and retry guard: a device that played nothing writes
        // nothing. Encryption is randomized, so comparing ciphertext can never
        // answer this; the manifest's plaintext hash can.
        if manifest.objects[objectKey]?.plaintextSHA256 == hash {
            return
        }

        let ciphertext = try Self.seal(
            plaintext,
            path: path,
            key: objectKeyEncryption ?? key)
        _ = try await objects.put(path: path, data: ciphertext, condition: .none)

        manifest.objects[objectKey] = RelayManifestEntry(
            path: path,
            plaintextSHA256: hash,
            plaintextBytes: plaintext.count,
            writtenAtMS: writtenAtMS)
        manifest.generation += 1
        let manifestPlaintext = try Self.encode(manifest)
        let manifestHash = Self.sha256(manifestPlaintext)
        let manifestPath = "\(manifestPrefix)\(localDeviceID)/" +
            "\(manifest.generation)-\(manifestHash)"
        let manifestCiphertext = try Self.seal(
            manifestPlaintext, path: manifestPath, key: key)
        let etag = try await objects.put(
            path: manifestPath,
            data: manifestCiphertext,
            condition: .none)
        cache[manifestPath] = CachedObject(
            etag: etag, plaintext: manifestPlaintext)
    }

    // MARK: Read

    private func manifests() async throws -> [(String, RelayDeviceManifest)] {
        let paths = try await objects.list(prefix: manifestPrefix).sorted()
        var newest: [String: (String, RelayDeviceManifest)] = [:]
        for path in paths {
            if let manifest = try await readManifest(path: path) {
                if let current = newest[manifest.deviceID],
                   (current.1.generation, current.0)
                    >= (manifest.generation, path) {
                    continue
                }
                newest[manifest.deviceID] = (path, manifest)
            }
        }
        return newest.values.sorted { $0.0 < $1.0 }
    }

    private func latestManifest(
        for deviceID: String
    ) async throws -> RelayDeviceManifest? {
        let prefix = "\(manifestPrefix)\(try Self.pathComponent(deviceID))/"
        let paths = try await objects.list(prefix: prefix).sorted()
        var latest: (String, RelayDeviceManifest)?
        for path in paths {
            guard let manifest = try await readManifest(path: path) else { continue }
            if let current = latest,
               (current.1.generation, current.0)
                >= (manifest.generation, path) {
                continue
            }
            latest = (path, manifest)
        }
        return latest?.1
    }

    private func readManifest(path: String) async throws -> RelayDeviceManifest? {
        guard let plaintext = try await readPlaintext(path: path) else { return nil }
        let manifest = try JSONDecoder().decode(
            RelayDeviceManifest.self, from: plaintext)
        guard manifest.version == RelayDeviceManifest.currentVersion else {
            throw RelayStoreError.unsupportedManifestVersion(manifest.version)
        }
        let expectedPrefix = "\(manifestPrefix)" +
            "\(try Self.pathComponent(manifest.deviceID))/"
        guard manifest.epoch == epoch,
              path.hasPrefix(expectedPrefix),
              path.dropFirst(expectedPrefix.count)
                .hasPrefix("\(manifest.generation)-") else {
            throw RelayStoreError.manifestPathMismatch(path)
        }
        return manifest
    }

    private func readPlaintext(
        path: String,
        using decryptionKey: SymmetricKey? = nil
    ) async throws -> Data? {
        let cached = cache[path]
        switch try await objects.read(path: path, ifNoneMatch: cached?.etag) {
        case .missing:
            cache[path] = nil
            return nil
        case .notModified:
            guard let cached else {
                throw RelayStoreError.changedWithoutBody(path)
            }
            return cached.plaintext
        case let .object(object):
            guard object.data.count <= Self.maximumPlaintextBytes + 64 else {
                throw RelayStoreError.objectTooLarge(
                    actual: object.data.count,
                    maximum: Self.maximumPlaintextBytes + 64)
            }
            let plaintext = try Self.open(
                object.data,
                path: path,
                key: decryptionKey ?? key)
            cache[path] = CachedObject(
                etag: object.etag, plaintext: plaintext)
            return plaintext
        }
    }

    private func validate(
        entry: RelayManifestEntry,
        manifestPath manifestObjectPath: String,
        manifest: RelayDeviceManifest
    ) throws {
        let expectedPrefix = "\(devicePrefix)\(try Self.pathComponent(manifest.deviceID))/"
        let expectedManifestPrefix = "\(manifestPrefix)" +
            "\(try Self.pathComponent(manifest.deviceID))/"
        guard manifestObjectPath.hasPrefix(expectedManifestPrefix),
              entry.path.hasPrefix(expectedPrefix) else {
            throw RelayStoreError.manifestPathMismatch(entry.path)
        }
    }

    private func validate(
        plaintext: Data,
        against entry: RelayManifestEntry
    ) throws {
        guard plaintext.count == entry.plaintextBytes,
              Self.sha256(plaintext) == entry.plaintextSHA256 else {
            throw RelayStoreError.plaintextHashMismatch(entry.path)
        }
    }

    // MARK: Layout and crypto

    private var devicePrefix: String { "c/\(channelID)/d/" }
    private var manifestPrefix: String { "c/\(channelID)/manifests/\(epoch)/" }

    private static func pathComponent(_ value: String) throws -> String {
        guard !value.isEmpty, value.count <= 128,
              value.unicodeScalars.allSatisfy({
                  let byte = $0.value
                  return (48...57).contains(byte)
                      || (65...90).contains(byte)
                      || (97...122).contains(byte)
                      || byte == 45
                      || byte == 95
              }) else {
            throw RelayStoreError.invalidPathComponent(value)
        }
        return value
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func seal(
        _ plaintext: Data,
        path: String,
        key: SymmetricKey
    ) throws -> Data {
        let box = try ChaChaPoly.seal(
            plaintext,
            using: key,
            authenticating: Data(path.utf8))
        return Data([1]) + box.combined
    }

    private static func open(
        _ ciphertext: Data,
        path: String,
        key: SymmetricKey
    ) throws -> Data {
        guard ciphertext.first == 1 else {
            throw RelayStoreError.unsupportedCiphertextVersion(
                Int(ciphertext.first ?? 0))
        }
        let box = try ChaChaPoly.SealedBox(combined: ciphertext.dropFirst())
        return try ChaChaPoly.open(
            box,
            using: key,
            authenticating: Data(path.utf8))
    }
}
