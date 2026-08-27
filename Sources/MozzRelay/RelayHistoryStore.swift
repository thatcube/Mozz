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
    public var objects: [String: RelayManifestEntry]

    public init(
        version: Int = currentVersion,
        deviceID: String,
        epoch: Int,
        objects: [String: RelayManifestEntry] = [:]
    ) {
        self.version = version
        self.deviceID = deviceID
        self.epoch = epoch
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
    private var cache: [String: CachedObject] = [:]

    public init(
        objects: any RelayObjectStore,
        channelID: String,
        localDeviceID: String,
        epoch: Int,
        channelKey: Data
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

    // MARK: Write

    private func save<Value: Encodable>(
        _ value: Value,
        objectKey: String,
        pathPrefix: String,
        maximumBytes: Int,
        writtenAtMS: Int64
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

        let manifestPath = localManifestPath
        var manifest = try await readManifest(path: manifestPath)
            ?? RelayDeviceManifest(deviceID: localDeviceID, epoch: epoch)

        // The primary cost and retry guard: a device that played nothing writes
        // nothing. Encryption is randomized, so comparing ciphertext can never
        // answer this; the manifest's plaintext hash can.
        if manifest.objects[objectKey]?.plaintextSHA256 == hash {
            return
        }

        let ciphertext = try Self.seal(plaintext, path: path, key: key)
        _ = try await objects.put(path: path, data: ciphertext, condition: .none)

        manifest.objects[objectKey] = RelayManifestEntry(
            path: path,
            plaintextSHA256: hash,
            plaintextBytes: plaintext.count,
            writtenAtMS: writtenAtMS)
        let manifestPlaintext = try Self.encode(manifest)
        let manifestCiphertext = try Self.seal(
            manifestPlaintext, path: manifestPath, key: key)

        let condition: RelayWriteCondition = cache[manifestPath]
            .map { .ifMatch($0.etag) }
            ?? .ifAbsent
        let etag = try await objects.put(
            path: manifestPath,
            data: manifestCiphertext,
            condition: condition)
        cache[manifestPath] = CachedObject(
            etag: etag, plaintext: manifestPlaintext)
    }

    // MARK: Read

    private func manifests() async throws -> [(String, RelayDeviceManifest)] {
        let suffix = "/manifest/\(epoch)"
        let paths = try await objects.list(prefix: devicePrefix)
            .filter { $0.hasSuffix(suffix) }
            .sorted()
        var result: [(String, RelayDeviceManifest)] = []
        for path in paths {
            if let manifest = try await readManifest(path: path) {
                result.append((path, manifest))
            }
        }
        return result
    }

    private func readManifest(path: String) async throws -> RelayDeviceManifest? {
        guard let plaintext = try await readPlaintext(path: path) else { return nil }
        let manifest = try JSONDecoder().decode(
            RelayDeviceManifest.self, from: plaintext)
        guard manifest.version == RelayDeviceManifest.currentVersion else {
            throw RelayStoreError.unsupportedManifestVersion(manifest.version)
        }
        guard manifest.epoch == epoch,
              path == manifestPath(for: manifest.deviceID) else {
            throw RelayStoreError.manifestPathMismatch(path)
        }
        return manifest
    }

    private func readPlaintext(path: String) async throws -> Data? {
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
                object.data, path: path, key: key)
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
        guard manifestObjectPath == manifestPath(for: manifest.deviceID),
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

    private var localManifestPath: String {
        manifestPath(for: localDeviceID)
    }

    private func manifestPath(for deviceID: String) -> String {
        "c/\(channelID)/d/\(deviceID)/manifest/\(epoch)"
    }

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
