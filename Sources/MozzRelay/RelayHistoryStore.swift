import Crypto
import Foundation
import MozzCore
import MozzHistory

private actor RelayManifestWriteGate {
    static let shared = RelayManifestWriteGate()

    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func run(
        key: String,
        operation: @Sendable () async throws -> Void
    ) async throws {
        await acquire(key)
        do {
            try await operation()
            release(key)
        } catch {
            release(key)
            throw error
        }
    }

    private func acquire(_ key: String) async {
        guard !held.insert(key).inserted else { return }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    private func release(_ key: String) {
        if var queued = waiters[key], !queued.isEmpty {
            let next = queued.removeFirst()
            waiters[key] = queued.isEmpty ? nil : queued
            next.resume()
        } else {
            held.remove(key)
        }
    }
}

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
    case invalidCatalogSnapshot(String)
    case invalidPlaybackSettings(String)
    case manifestContention(String)
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
    public var allMusicLibraries: Bool?
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
        allMusicLibraries: Bool? = nil,
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
        self.allMusicLibraries = allMusicLibraries
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

// MARK: - Catalog snapshots

public struct RelayCatalogChunkReference: Codable, Sendable, Equatable {
    public var kind: CatalogSnapshotChunkKind
    public var path: String
    public var plaintextSHA256: String
    public var plaintextBytes: Int
    public var counts: CatalogSnapshotCounts

    public init(
        kind: CatalogSnapshotChunkKind,
        path: String,
        plaintextSHA256: String,
        plaintextBytes: Int,
        counts: CatalogSnapshotCounts
    ) {
        self.kind = kind
        self.path = path
        self.plaintextSHA256 = plaintextSHA256
        self.plaintextBytes = plaintextBytes
        self.counts = counts
    }
}

/// The atomic pointer to one complete catalog export.
///
/// Chunks are uploaded first and remain invisible until this index is published
/// through the device manifest. A failed export can leave harmless orphaned
/// chunks, but can never expose half a snapshot as current.
public struct RelayCatalogSnapshotIndex: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var sourceDeviceID: String
    public var scope: CatalogSnapshotScope
    public var writtenAtMS: Int64
    public var counts: CatalogSnapshotCounts
    public var chunks: [RelayCatalogChunkReference]

    public init(
        version: Int = currentVersion,
        sourceDeviceID: String,
        scope: CatalogSnapshotScope,
        writtenAtMS: Int64,
        counts: CatalogSnapshotCounts,
        chunks: [RelayCatalogChunkReference]
    ) {
        self.version = version
        self.sourceDeviceID = sourceDeviceID
        self.scope = scope
        self.writtenAtMS = writtenAtMS
        self.counts = counts
        self.chunks = chunks
    }
}

public struct RelayPlaybackSettingsSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var deviceID: String
    public var updatedAtMS: Int64
    public var settings: PlaybackSettings

    public init(
        version: Int = currentVersion,
        deviceID: String,
        updatedAtMS: Int64,
        settings: PlaybackSettings
    ) {
        self.version = version
        self.deviceID = deviceID
        self.updatedAtMS = updatedAtMS
        self.settings = settings
    }
}

public struct RelayFavoriteSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var deviceID: String
    public var scope: CatalogSnapshotScope
    public var records: [FavoriteMutationState]

    public init(
        version: Int = currentVersion,
        deviceID: String,
        scope: CatalogSnapshotScope,
        records: [FavoriteMutationState]
    ) {
        self.version = version
        self.deviceID = deviceID
        self.scope = scope
        self.records = records
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
    public static let maximumCatalogChunkBytes = 2 * 1024 * 1024

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
    private var catalogPathsByScope: [String: Set<String>] = [:]

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

    // MARK: Playback settings

    public func loadPlaybackSettingsSnapshots() async throws
        -> [RelayPlaybackSettingsSnapshot] {
        var snapshots: [RelayPlaybackSettingsSnapshot] = []
        for (manifestPath, manifest) in try await manifests() {
            guard let entry = manifest.objects["playbackSettings"] else {
                continue
            }
            try validate(
                entry: entry,
                manifestPath: manifestPath,
                manifest: manifest)
            guard let plaintext = try await readPlaintext(
                path: entry.path) else {
                continue
            }
            try validate(plaintext: plaintext, against: entry)
            let snapshot = try JSONDecoder().decode(
                RelayPlaybackSettingsSnapshot.self,
                from: plaintext)
            guard snapshot.version
                    == RelayPlaybackSettingsSnapshot.currentVersion,
                  snapshot.deviceID == manifest.deviceID,
                  snapshot.updatedAtMS >= 0 else {
                throw RelayStoreError.invalidPlaybackSettings(
                    "playback settings identity is invalid")
            }
            snapshots.append(snapshot)
        }
        return snapshots
    }

    public func save(
        _ snapshot: RelayPlaybackSettingsSnapshot
    ) async throws {
        guard snapshot.deviceID == localDeviceID,
              snapshot.version
                == RelayPlaybackSettingsSnapshot.currentVersion,
              snapshot.updatedAtMS >= 0 else {
            throw RelayStoreError.payloadDeviceMismatch(
                expected: localDeviceID,
                actual: snapshot.deviceID)
        }
        try await save(
            snapshot,
            objectKey: "playbackSettings",
            pathPrefix: "\(devicePrefix)\(localDeviceID)/state/" +
                "\(epoch)/playback-settings",
            maximumBytes: 32 * 1024,
            writtenAtMS: snapshot.updatedAtMS)
    }

    public static func mergedPlaybackSettings(
        _ snapshots: [RelayPlaybackSettingsSnapshot]
    ) -> RelayPlaybackSettingsSnapshot? {
        snapshots.max {
            if $0.updatedAtMS != $1.updatedAtMS {
                return $0.updatedAtMS < $1.updatedAtMS
            }
            return $0.deviceID < $1.deviceID
        }
    }

    public func loadFavoriteSnapshots(
        scope: CatalogSnapshotScope
    ) async throws -> [RelayFavoriteSnapshot] {
        let scopeID = try Self.catalogScopeID(scope)
        var snapshots: [RelayFavoriteSnapshot] = []
        for (manifestPath, manifest) in try await manifests() {
            guard let entry = manifest.objects["favorites:\(scopeID)"] else {
                continue
            }
            try validate(entry: entry, manifestPath: manifestPath, manifest: manifest)
            guard let plaintext = try await readPlaintext(path: entry.path) else { continue }
            try validate(plaintext: plaintext, against: entry)
            let snapshot = try JSONDecoder().decode(RelayFavoriteSnapshot.self, from: plaintext)
            guard snapshot.version == RelayFavoriteSnapshot.currentVersion,
                  snapshot.deviceID == manifest.deviceID,
                  snapshot.scope == scope,
                  snapshot.records.allSatisfy(Self.validFavorite) else {
                throw RelayStoreError.invalidPlaybackSettings("favorite snapshot identity is invalid")
            }
            snapshots.append(snapshot)
        }
        return snapshots
    }

    public func save(_ snapshot: RelayFavoriteSnapshot) async throws {
        guard snapshot.deviceID == localDeviceID else {
            throw RelayStoreError.payloadDeviceMismatch(
                expected: localDeviceID, actual: snapshot.deviceID)
        }
        guard snapshot.records.allSatisfy(Self.validFavorite) else {
            throw RelayStoreError.invalidPlaybackSettings(
                "favorite mutation is invalid")
        }
        let scopeID = try Self.catalogScopeID(snapshot.scope)
        try await save(
            snapshot,
            objectKey: "favorites:\(scopeID)",
            pathPrefix: "\(devicePrefix)\(localDeviceID)/state/\(epoch)/favorites/\(scopeID)",
            maximumBytes: Self.maximumCatalogChunkBytes,
            writtenAtMS: snapshot.records.map(\.updatedAtMS).max() ?? 0)
    }

    public static func mergedFavoriteRecords(
        _ snapshots: [RelayFavoriteSnapshot]
    ) -> [FavoriteMutationState] {
        var selected: [String: FavoriteMutationState] = [:]
        for record in snapshots.flatMap(\.records) {
            guard let current = selected[record.remoteID] else {
                selected[record.remoteID] = record
                continue
            }
            if record.updatedAtMS > current.updatedAtMS
                || (record.updatedAtMS == current.updatedAtMS
                    && record.sourceDeviceID > current.sourceDeviceID) {
                selected[record.remoteID] = record
            }
        }
        return selected.values.sorted { $0.remoteID < $1.remoteID }
    }

    private static func validFavorite(_ record: FavoriteMutationState) -> Bool {
        !record.remoteID.isEmpty
            && !record.sourceDeviceID.isEmpty
            && ["track", "album", "artist"].contains(record.itemType)
            && ["favorite", "rating"].contains(record.kind)
            && record.updatedAtMS >= 0
    }

    // MARK: Catalog snapshots

    public static func catalogScopeID(
        _ scope: CatalogSnapshotScope
    ) throws -> String {
        sha256(try encode(scope))
    }

    /// Upload one immutable chunk without changing the visible snapshot.
    public func saveCatalogChunk(
        _ chunk: CatalogSnapshotChunk,
        scope: CatalogSnapshotScope
    ) async throws -> RelayCatalogChunkReference {
        let scopeID = try Self.catalogScopeID(scope)
        try validateCatalogChunk(
            chunk,
            expectedDeviceID: localDeviceID,
            expectedScopeID: scopeID)
        let plaintext = try Self.encode(chunk)
        guard plaintext.count <= Self.maximumCatalogChunkBytes else {
            throw RelayStoreError.objectTooLarge(
                actual: plaintext.count,
                maximum: Self.maximumCatalogChunkBytes)
        }
        let hash = Self.sha256(plaintext)
        let scopePrefix = "\(devicePrefix)\(localDeviceID)/catalog/\(epoch)/" +
            "\(scopeID)/"
        let path = "\(scopePrefix)\(chunk.kind.rawValue)/\(hash)"
        if catalogPathsByScope[scopeID] == nil {
            catalogPathsByScope[scopeID] = Set(
                try await objects.list(prefix: scopePrefix))
        }
        if catalogPathsByScope[scopeID]?.contains(path) != true {
            let ciphertext = try Self.seal(plaintext, path: path, key: key)
            _ = try await objects.put(
                path: path,
                data: ciphertext,
                condition: .none)
            catalogPathsByScope[scopeID, default: []].insert(path)
        }
        return RelayCatalogChunkReference(
            kind: chunk.kind,
            path: path,
            plaintextSHA256: hash,
            plaintextBytes: plaintext.count,
            counts: chunk.counts)
    }

    /// Make a fully-uploaded snapshot visible in one manifest generation.
    public func saveCatalogSnapshot(
        _ snapshot: RelayCatalogSnapshotIndex
    ) async throws {
        let scopeID = try Self.catalogScopeID(snapshot.scope)
        try validateCatalogSnapshot(
            snapshot,
            expectedDeviceID: localDeviceID,
            expectedScopeID: scopeID)
        try await save(
            snapshot,
            objectKey: "catalog:\(scopeID)",
            pathPrefix: "\(devicePrefix)\(localDeviceID)/catalog/\(epoch)/" +
                "\(scopeID)/index",
            maximumBytes: Self.maximumPlaintextBytes,
            writtenAtMS: snapshot.writtenAtMS)
    }

    /// Select the newest whole snapshot for an exact server/account/library
    /// scope. Catalogs are caches, not mergeable event logs: combining entities
    /// from two points in time can resurrect items deleted on the server.
    public func latestCatalogSnapshot(
        scope: CatalogSnapshotScope
    ) async throws -> RelayCatalogSnapshotIndex? {
        let scopeID = try Self.catalogScopeID(scope)
        let objectKey = "catalog:\(scopeID)"
        var selected: RelayCatalogSnapshotIndex?
        for (manifestPath, manifest) in try await manifests() {
            guard let entry = manifest.objects[objectKey] else { continue }
            try validate(
                entry: entry,
                manifestPath: manifestPath,
                manifest: manifest)
            guard let plaintext = try await readPlaintext(path: entry.path) else {
                continue
            }
            try validate(plaintext: plaintext, against: entry)
            let candidate = try JSONDecoder().decode(
                RelayCatalogSnapshotIndex.self,
                from: plaintext)
            try validateCatalogSnapshot(
                candidate,
                expectedDeviceID: manifest.deviceID,
                expectedScopeID: scopeID)
            guard candidate.scope == scope else {
                throw RelayStoreError.invalidCatalogSnapshot(
                    "scope hash does not match the encrypted scope")
            }
            if let current = selected {
                let newer = candidate.writtenAtMS > current.writtenAtMS
                    || (candidate.writtenAtMS == current.writtenAtMS
                        && candidate.sourceDeviceID > current.sourceDeviceID)
                if newer { selected = candidate }
            } else {
                selected = candidate
            }
        }
        return selected
    }

    public func loadCatalogChunk(
        _ reference: RelayCatalogChunkReference,
        from snapshot: RelayCatalogSnapshotIndex
    ) async throws -> CatalogSnapshotChunk {
        let scopeID = try Self.catalogScopeID(snapshot.scope)
        let expectedPrefix = "\(devicePrefix)" +
            "\(try Self.pathComponent(snapshot.sourceDeviceID))/catalog/" +
            "\(epoch)/\(scopeID)/"
        guard reference.path.hasPrefix(expectedPrefix) else {
            throw RelayStoreError.manifestPathMismatch(reference.path)
        }
        guard let plaintext = try await readPlaintext(
            path: reference.path,
            maximumBytes: Self.maximumCatalogChunkBytes) else {
            throw RelayStoreError.invalidCatalogSnapshot(
                "catalog chunk is missing")
        }
        try validate(plaintext: plaintext, against: reference)
        let chunk = try JSONDecoder().decode(
            CatalogSnapshotChunk.self,
            from: plaintext)
        try validateCatalogChunk(
            chunk,
            expectedDeviceID: snapshot.sourceDeviceID,
            expectedScopeID: scopeID)
        guard chunk.kind == reference.kind,
              chunk.counts == reference.counts else {
            throw RelayStoreError.invalidCatalogSnapshot(
                "catalog chunk metadata does not match its index")
        }
        return chunk
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
        try await RelayManifestWriteGate.shared.run(
            key: "\(channelID)/\(epoch)/\(localDeviceID)"
        ) {
            try await self.saveEncoded(
                plaintext,
                objectKey: objectKey,
                pathPrefix: pathPrefix,
                writtenAtMS: writtenAtMS,
                using: objectKeyEncryption)
        }
    }

    private func saveEncoded(
        _ plaintext: Data,
        objectKey: String,
        pathPrefix: String,
        writtenAtMS: Int64,
        using objectKeyEncryption: SymmetricKey?
    ) async throws {
        let hash = Self.sha256(plaintext)
        // Content-addressed objects are immutable. If two app processes for the
        // same device race, they write different paths and then contend only on
        // the manifest. A single mutable "current" path lets the losing process
        // replace the body before the winning manifest lands, producing a
        // manifest/hash mismatch for every reader.
        let path = "\(pathPrefix)/\(hash)"

        let initialManifest = try await latestManifest(for: localDeviceID)
            ?? RelayDeviceManifest(deviceID: localDeviceID, epoch: epoch)

        // The primary cost and retry guard: a device that played nothing writes
        // nothing. Encryption is randomized, so comparing ciphertext can never
        // answer this; the manifest's plaintext hash can.
        if initialManifest.objects[objectKey]?.plaintextSHA256 == hash {
            return
        }

        let ciphertext = try Self.seal(
            plaintext,
            path: path,
            key: objectKeyEncryption ?? key)
        _ = try await objects.put(path: path, data: ciphertext, condition: .none)

        let entry = RelayManifestEntry(
            path: path,
            plaintextSHA256: hash,
            plaintextBytes: plaintext.count,
            writtenAtMS: writtenAtMS)
        var manifest = initialManifest
        for _ in 0..<3 {
            if manifest.objects[objectKey]?.plaintextSHA256 == hash {
                return
            }
            manifest.objects[objectKey] = entry
            manifest.generation += 1
            let manifestPlaintext = try Self.encode(manifest)
            let manifestHash = Self.sha256(manifestPlaintext)
            let manifestPath = "\(manifestPrefix)\(localDeviceID)/" +
                "\(manifest.generation)-\(manifestHash)"
            let manifestCiphertext = try Self.seal(
                manifestPlaintext,
                path: manifestPath,
                key: key)
            let etag = try await objects.put(
                path: manifestPath,
                data: manifestCiphertext,
                condition: .none)
            cache[manifestPath] = CachedObject(
                etag: etag,
                plaintext: manifestPlaintext)

            // Another process may have written the same generation and won the
            // deterministic path tie. If so, merge its manifest and publish the
            // missing pointer at the next generation before returning.
            let visible = try await latestManifest(for: localDeviceID)
            if visible?.objects[objectKey]?.plaintextSHA256 == hash {
                return
            }
            manifest = visible ?? RelayDeviceManifest(
                deviceID: localDeviceID,
                epoch: epoch)
        }
        throw RelayStoreError.manifestContention(objectKey)
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
        using decryptionKey: SymmetricKey? = nil,
        maximumBytes: Int? = nil
    ) async throws -> Data? {
        let maximumBytes = maximumBytes ?? Self.maximumPlaintextBytes
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
            guard object.data.count <= maximumBytes + 64 else {
                throw RelayStoreError.objectTooLarge(
                    actual: object.data.count,
                    maximum: maximumBytes + 64)
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

    private func validate(
        plaintext: Data,
        against reference: RelayCatalogChunkReference
    ) throws {
        guard plaintext.count == reference.plaintextBytes,
              Self.sha256(plaintext) == reference.plaintextSHA256 else {
            throw RelayStoreError.plaintextHashMismatch(reference.path)
        }
    }

    private func validateCatalogSnapshot(
        _ snapshot: RelayCatalogSnapshotIndex,
        expectedDeviceID: String,
        expectedScopeID: String
    ) throws {
        guard snapshot.version == RelayCatalogSnapshotIndex.currentVersion,
              snapshot.sourceDeviceID == expectedDeviceID,
              !snapshot.scope.serverID.isEmpty,
              !snapshot.scope.accountID.isEmpty else {
            throw RelayStoreError.invalidCatalogSnapshot(
                "catalog index identity is invalid")
        }
        let expectedPrefix = "\(devicePrefix)" +
            "\(try Self.pathComponent(expectedDeviceID))/catalog/" +
            "\(epoch)/\(expectedScopeID)/"
        var summed = CatalogSnapshotCounts()
        var paths = Set<String>()
        for reference in snapshot.chunks {
            guard reference.path.hasPrefix(expectedPrefix),
                  reference.plaintextBytes > 0,
                  reference.plaintextBytes <= Self.maximumCatalogChunkBytes,
                  paths.insert(reference.path).inserted else {
                throw RelayStoreError.invalidCatalogSnapshot(
                    "catalog index contains an invalid chunk reference")
            }
            summed = summed + reference.counts
        }
        guard summed == snapshot.counts else {
            throw RelayStoreError.invalidCatalogSnapshot(
                "catalog index counts do not match its chunks")
        }
    }

    private func validateCatalogChunk(
        _ chunk: CatalogSnapshotChunk,
        expectedDeviceID: String,
        expectedScopeID: String
    ) throws {
        let populatedKinds = [
            !chunk.artists.isEmpty,
            !chunk.albums.isEmpty,
            !chunk.tracks.isEmpty,
            !chunk.playlists.isEmpty,
            !chunk.playlistItems.isEmpty,
        ].filter { $0 }.count
        let kindMatches =
            (chunk.kind == .artists && !chunk.artists.isEmpty)
            || (chunk.kind == .albums && !chunk.albums.isEmpty)
            || (chunk.kind == .tracks && !chunk.tracks.isEmpty)
            || (chunk.kind == .playlists && !chunk.playlists.isEmpty)
            || (chunk.kind == .playlistItems
                && !chunk.playlistItems.isEmpty)
        let playlistItemsAreValid = chunk.playlistItems.allSatisfy {
            !$0.playlistRemoteID.isEmpty
                && $0.startPosition >= 0
                && !$0.trackRemoteIDs.isEmpty
        }
        guard chunk.version == CatalogSnapshotChunk.currentVersion,
              chunk.sourceDeviceID == expectedDeviceID,
              chunk.scopeID == expectedScopeID,
              populatedKinds == 1,
              kindMatches,
              playlistItemsAreValid,
              chunk.recordCount > 0 else {
            throw RelayStoreError.invalidCatalogSnapshot(
                "catalog chunk shape is invalid")
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
