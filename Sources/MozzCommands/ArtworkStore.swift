import Crypto
import Foundation

/// One piece of artwork to fetch: whose server, which reference, at what size.
///
/// A value type so it is a cheap, correct dictionary/set key — two asks for the
/// same cover at the same size are the same ask. The size is part of the
/// identity on purpose, exactly as the desktop's `ArtworkRef` makes it: the
/// album wall draws at one resolution and the player bar at another, and asking
/// each at its own size is the whole point of requesting art at the displayed
/// size rather than one fixed large one.
public struct ArtworkQuery: Hashable, Sendable {
    public let serverId: String
    public let artworkKey: String
    public let size: Int

    public init(serverId: String, artworkKey: String, size: Int) {
        self.serverId = serverId
        self.artworkKey = artworkKey
        self.size = size
    }

    /// The stable string the caches key on. The NUL separators are safe here —
    /// this never crosses the C-string door — and keep two fields from running
    /// together (`"a" + "bc"` must not collide with `"ab" + "c"`).
    var cacheKey: String {
        "\(serverId)\u{0}\(artworkKey)\u{0}\(size)"
    }

    /// The on-disk filename: a hex SHA-256 of ``cacheKey`` plus a fixed
    /// extension. Hashed rather than encoded so an artwork key of any shape or
    /// length — Plex paths contain slashes, Jellyfin keys a pipe — becomes one
    /// short, filesystem-safe name, and so eviction can find the cache's own
    /// files by that extension without touching a neighbour's.
    var fileName: String {
        let digest = SHA256.hash(data: Data(cacheKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".artwork"
    }
}

/// The three honest answers to "give me these artwork bytes", and the reason
/// this store exists rather than a dictionary of `Data?`.
///
/// The distinction is the one the desktop draws with
/// `ArtworkUnavailableException` versus a null return, and the one that already
/// cost real debugging when the two shells got it subtly different:
///
///  - ``bytes`` — here it is.
///  - ``absent`` — the server was asked and had none. Plex and Jellyfin
///    routinely have no cover for an item; this is an ordinary answer, and it is
///    *remembered* so a dead reference is not asked again on every scroll pass.
///  - ``unavailable`` — not right now. A server still attaching, a timeout, a
///    briefly unreachable host. None of that is evidence the cover is missing,
///    so it is deliberately *not* remembered — recording it would hide a real
///    cover until the process restarts, which is exactly the bug
///    `ArtworkUnavailableException` was introduced to fix.
public enum ArtworkOutcome: Sendable, Equatable {
    case bytes(Data)
    case absent
    case unavailable
}

/// The core's one artwork store: reference → bytes, cached on disk under a
/// budget, with absence and transient failure remembered differently.
///
/// It is the shared answer to a duplication that produced a real bug: iOS and
/// the desktop each fetched, cached, and evicted artwork on their own, and only
/// one of them ever bounded the disk. Fetching bytes, storing them, and deciding
/// what to keep are decisions, so they live here; decoding bytes into a platform
/// bitmap stays in each shell.
///
/// Resolution and the network live behind the injected ``fetch`` — in the app it
/// resolves the reference through the attached backend and downloads it, in a
/// test it returns whatever the test wants — which keeps every rule below
/// verifiable with no server and no disk beyond a temp directory. This mirrors
/// the desktop's `ArtworkCache`, whose `fetch` closure carries the same three
/// outcomes, and the core's own ``LyricsService``/``LyricsDiskCache`` split of
/// decision from storage.
public actor ArtworkStore {
    public typealias Fetch = @Sendable (ArtworkQuery) async -> ArtworkOutcome

    private let directory: URL?
    private let byteLimit: Int?

    /// Keys the server has told us it has no art for, remembered for the life of
    /// this store. In memory and never persisted, exactly like the desktop's
    /// negative set: it is a session's accumulated knowledge, cheap to rebuild,
    /// and clearing it (``forgetAbsent()``) is how a newly-attached server gets
    /// every earlier "no art" a second chance.
    private var absent: Set<String> = []

    private var fetch: Fetch

    public init(directory: URL?, byteLimit: Int?, fetch: @escaping Fetch) {
        self.directory = directory
        // A zero or negative budget would evict everything the instant it was
        // written; clamp to at least one byte so "bounded" cannot mean "empty".
        self.byteLimit = byteLimit.map { max(1, $0) }
        self.fetch = fetch
    }

    /// The bytes for a reference, or why there are none.
    ///
    /// Lookup order: remembered absence → disk → fetch. A disk hit refreshes the
    /// file's modification time so it counts as recently used; a fetched cover is
    /// written to disk and the budget enforced before it is returned.
    public func artwork(_ query: ArtworkQuery) async -> ArtworkOutcome {
        let key = query.cacheKey
        if absent.contains(key) { return .absent }

        if let data = readFromDisk(query) {
            return .bytes(data)
        }

        let outcome = await fetch(query)
        switch outcome {
        case .bytes(let data):
            guard !data.isEmpty else {
                // A server that answers with an empty body has, in effect, no
                // art. Treat it as absence rather than caching zero bytes that
                // would later read back as a hit for nothing.
                absent.insert(key)
                return .absent
            }
            writeToDisk(data, for: query)
            return .bytes(data)
        case .absent:
            absent.insert(key)
            return .absent
        case .unavailable:
            return .unavailable
        }
    }

    /// Forget every remembered absence, so the next ask for each tries again.
    ///
    /// Called when a server attaches: anything written off before there was a
    /// backend to ask deserves another chance, and because the absence set is
    /// never otherwise emptied, without this a cover that failed early would
    /// stay missing until the process restarts.
    public func forgetAbsent() {
        absent.removeAll()
    }

    /// Whether a key is currently remembered as absent. Test-facing; the store's
    /// own logic reads ``absent`` directly.
    func isRememberedAbsent(_ query: ArtworkQuery) -> Bool {
        absent.contains(query.cacheKey)
    }

    // MARK: Disk

    private func fileURL(for query: ArtworkQuery) -> URL? {
        directory?.appendingPathComponent(query.fileName)
    }

    private func readFromDisk(_ query: ArtworkQuery) -> Data? {
        guard let fileURL = fileURL(for: query),
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              !data.isEmpty else {
            return nil
        }
        // Refresh recency on read. Modification time stands in for an LRU index
        // so a hit costs one timestamp write rather than an index update on the
        // scrolling hot path — the same approximation iOS and the desktop make,
        // deliberately, so all three behave alike.
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: fileURL.path)
        return data
    }

    private func writeToDisk(_ data: Data, for query: ArtworkQuery) {
        guard byteLimit.map({ data.count <= $0 }) ?? true,
              let fileURL = fileURL(for: query),
              ensureDirectory() else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: fileURL.path)
            enforceBudget()
        } catch {
            return
        }
    }

    private func ensureDirectory() -> Bool {
        guard let directory else { return false }
        if FileManager.default.fileExists(atPath: directory.path) { return true }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    /// Delete least-recently-used first until the directory fits the budget, and
    /// stop the moment it does — deleting more would throw away covers that each
    /// cost a network round trip to replace. Only the store's own `.artwork`
    /// files are candidates, so a neighbouring feature's files in the same
    /// directory are never swept. This is the semantics of the desktop's
    /// `DiskBudget.Enforce` and iOS's `evictIfNeeded`, in one place for both.
    ///
    /// Returns the number of bytes removed, which the store ignores but the
    /// tests assert on.
    @discardableResult
    func enforceBudget() -> Int {
        guard let byteLimit, let directory else { return 0 }
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
        ]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var entries: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for file in files where file.pathExtension == "artwork" {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            total += size
            // A file whose timestamp cannot be read sorts oldest, so a directory
            // of unreadable entries still drains rather than pinning the cache
            // above its budget forever.
            entries.append((file, size, values.contentModificationDate ?? .distantPast))
        }

        guard total > byteLimit else { return 0 }
        var removed = 0
        for entry in entries.sorted(by: { $0.date < $1.date }) where total - removed > byteLimit {
            guard (try? FileManager.default.removeItem(at: entry.url)) != nil else { continue }
            removed += entry.size
        }
        return removed
    }

    // MARK: Testing seams

    /// Replace the fetch closure. Test-only: it lets a suite drive the disk,
    /// budget, and absence logic without a server or a network.
    func setFetchForTesting(_ fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    // MARK: Default location

    /// The evictable on-disk cache location, mirroring iOS's `Caches/Artwork/v1`
    /// and the core's ``LyricsDiskCache`` choice of `.cachesDirectory`: covers
    /// are all re-derivable from the server, so the OS is free to reclaim them
    /// under pressure. Durable copies for downloaded albums are a separate store
    /// under Application Support, added when the downloads feature lands.
    public static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Artwork", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }
}
