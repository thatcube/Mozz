import CryptoKit
import Foundation
import ImageIO

struct ArtworkCacheKey: Hashable, Sendable {
    let value: String
    let fileName: String

    static func disk(for url: URL) -> ArtworkCacheKey {
        make(url, stripsSizing: false)
    }

    static func offline(for url: URL) -> ArtworkCacheKey {
        make(url, stripsSizing: true)
    }

    private static let credentialNames: Set<String> = [
        "access_token", "api_key", "apikey", "p", "s", "t", "token", "x-plex-token",
    ]

    private static let sizingNames: Set<String> = [
        "fillheight", "fillwidth", "height", "maxheight", "maxwidth", "minsize",
        "quality", "size", "upscale", "width",
    ]

    private static func make(_ url: URL, stripsSizing: Bool) -> ArtworkCacheKey {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return hashed(url.absoluteString)
        }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.queryItems = components.queryItems?
            .filter {
                let name = $0.name.lowercased()
                return !credentialNames.contains(name)
                    && (!stripsSizing || !sizingNames.contains(name))
            }
            .sorted {
                let lhs = ($0.name.lowercased(), $0.value ?? "")
                let rhs = ($1.name.lowercased(), $1.value ?? "")
                return lhs < rhs
            }
        return hashed(components.string ?? url.absoluteString)
    }

    private static func hashed(_ value: String) -> ArtworkCacheKey {
        let digest = SHA256.hash(data: Data(value.utf8))
        let fileName = digest.map { String(format: "%02x", $0) }.joined() + ".artwork"
        return ArtworkCacheKey(value: value, fileName: fileName)
    }
}

/// Raw bytes stay in memory separately from decoded images so media metadata and
/// widgets can reuse the server response without degrading it through re-encoding.
final class ArtworkDataMemoryCache: @unchecked Sendable {
    private let cache = NSCache<NSString, NSData>()

    init() {
        cache.countLimit = 128
        cache.totalCostLimit = 32 * 1_024 * 1_024
    }

    func data(for key: ArtworkCacheKey) -> Data? {
        cache.object(forKey: key.fileName as NSString) as Data?
    }

    func insert(_ data: Data, for key: ArtworkCacheKey) {
        cache.setObject(data as NSData, forKey: key.fileName as NSString, cost: data.count)
    }
}

actor ArtworkDiskStore {
    static let shared = ArtworkDiskStore(
        directory: cacheDirectory(),
        byteLimit: 256 * 1_024 * 1_024
    )
    static let offline = ArtworkDiskStore(
        directory: offlineDirectory(),
        byteLimit: nil,
        excludesFromBackup: true
    )

    private let directory: URL?
    private let byteLimit: Int?
    private let excludesFromBackup: Bool

    init(directory: URL?, byteLimit: Int?, excludesFromBackup: Bool = false) {
        self.directory = directory
        self.byteLimit = byteLimit.map { max(1, $0) }
        self.excludesFromBackup = excludesFromBackup
    }

    func data(for key: ArtworkCacheKey) -> Data? {
        guard let fileURL = fileURL(for: key),
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            return nil
        }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: fileURL.path
        )
        return data
    }

    func store(_ data: Data, for key: ArtworkCacheKey) {
        guard !data.isEmpty,
              byteLimit.map({ data.count <= $0 }) ?? true,
              let fileURL = fileURL(for: key),
              ensureDirectory() else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: fileURL.path
            )
            evictIfNeeded()
        } catch {
            return
        }
    }

    private func fileURL(for key: ArtworkCacheKey) -> URL? {
        directory?.appendingPathComponent(key.fileName)
    }

    private func ensureDirectory() -> Bool {
        guard var directory else { return false }
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
            } catch {
                return false
            }
        }
        if excludesFromBackup {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
        }
        return true
    }

    /// Modification time is refreshed on each hit, giving a cheap persistent LRU
    /// approximation without an index that would add a write to every artwork read.
    private func evictIfNeeded() {
        guard let byteLimit, let directory else { return }
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
        ]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for file in files where file.pathExtension == "artwork" {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            total += size
            entries.append((file, size, values.contentModificationDate ?? .distantPast))
        }
        guard total > byteLimit else { return }
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > byteLimit {
            guard (try? FileManager.default.removeItem(at: entry.url)) != nil else { continue }
            total -= entry.size
        }
    }

    private static func cacheDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Artwork", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    /// Downloaded albums must keep their covers even when iOS reclaims Caches.
    private static func offlineDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Artwork", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }
}

actor ArtworkDataLoader {
    typealias Fetch = @Sendable (URL) async -> Data?

    static let shared = ArtworkDataLoader()

    private let memory: ArtworkDataMemoryCache
    private let disk: ArtworkDiskStore
    private let offline: ArtworkDiskStore
    private let fetch: Fetch
    private var inFlight: [ArtworkCacheKey: Task<Data?, Never>] = [:]

    init(
        memory: ArtworkDataMemoryCache = ArtworkDataMemoryCache(),
        disk: ArtworkDiskStore = .shared,
        offline: ArtworkDiskStore = .offline,
        fetch: @escaping Fetch = { url in
            await ArtworkDataLoader.fetchFromNetwork(url)
        }
    ) {
        self.memory = memory
        self.disk = disk
        self.offline = offline
        self.fetch = fetch
    }

    /// Lookup order is deliberately identical for images and metadata consumers:
    /// memory → durable download store → evictable disk cache → server.
    func data(for url: URL) async -> Data? {
        let diskKey = ArtworkCacheKey.disk(for: url)
        if let data = memory.data(for: diskKey) { return data }
        if let existing = inFlight[diskKey] { return await existing.value }

        let offlineKey = ArtworkCacheKey.offline(for: url)
        let memory = self.memory
        let disk = self.disk
        let offline = self.offline
        let fetch = self.fetch
        let task = Task<Data?, Never>.detached(priority: .utility) {
            if let data = await offline.data(for: offlineKey) {
                memory.insert(data, for: diskKey)
                return data
            }
            if let data = await disk.data(for: diskKey) {
                memory.insert(data, for: diskKey)
                return data
            }
            guard let data = await fetch(url), !data.isEmpty else { return nil }
            await disk.store(data, for: diskKey)
            memory.insert(data, for: diskKey)
            return data
        }
        inFlight[diskKey] = task
        let result = await task.value
        inFlight[diskKey] = nil
        return result
    }

    /// Promote an album cover into Application Support after its audio download
    /// succeeds. Sizing parameters are absent from this key, so every track and UI
    /// rendition of one album shares the single high-resolution response.
    @discardableResult
    func captureForOffline(_ url: URL) async -> Data? {
        let offlineKey = ArtworkCacheKey.offline(for: url)
        if let data = await offline.data(for: offlineKey) { return data }
        guard let data = await data(for: url) else { return nil }
        await offline.store(data, for: offlineKey)
        return data
    }

    private static func fetchFromNetwork(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              !data.isEmpty,
              CGImageSourceCreateWithData(data as CFData, nil) != nil else { return nil }
        if let response = response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            return nil
        }
        return data
    }
}
