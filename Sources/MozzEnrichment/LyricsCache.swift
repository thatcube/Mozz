import Foundation
import MozzCore

/// In-memory memo of resolved lyrics for this session, keyed by
/// ``LyricsCacheKey``. Bounded so a long listening session can't grow it without
/// limit; evicting the oldest entry is harmless because a miss just falls through
/// to the disk cache (also fast).
///
/// The doubly-optional return distinguishes "no entry, go resolve" (`nil`) from
/// "we have an entry and it says there are no lyrics" (`.some(nil)`).
public actor LyricsMemoCache {
    public static let shared = LyricsMemoCache()

    private var entries: [String: Lyrics?] = [:]
    private var order: [String] = []
    private let limit: Int

    public init(limit: Int = 64) {
        self.limit = max(1, limit)
    }

    public func value(for key: String) -> Lyrics?? {
        guard let entry = entries[key] else { return nil }
        return .some(entry)
    }

    public func set(_ value: Lyrics?, for key: String) {
        if entries.index(forKey: key) == nil {
            order.append(key)
            if order.count > limit {
                let evicted = order.removeFirst()
                entries.removeValue(forKey: evicted)
            }
        }
        entries[key] = value
    }

    public func removeAll() {
        entries.removeAll()
        order.removeAll()
    }
}

/// Persistent on-disk cache of resolved lyrics, in the Caches directory so the OS
/// can reclaim it under pressure without losing user data.
///
/// Entries carry **no TTL** — once a track has been resolved we trust that answer
/// until the file is evicted or the schema version is bumped. The "what if lyrics
/// get uploaded later" case is handled by a background re-check of remembered
/// negatives, debounced via each entry's `lastChecked`. So the user never sees a
/// "Searching…" or "No lyrics" flash for a song we already know is instrumental,
/// yet a fresh upload still surfaces on a later play with no manual cache-bust.
///
/// A song's JSON is roughly 3 KB, so even a few thousand remembered tracks costs
/// only a handful of megabytes.
public actor LyricsDiskCache {
    /// The opportunistic cache: whatever we happened to look up while playing.
    /// Lives in Caches, so the OS may reclaim it — losing it costs one lookup.
    public static let shared = LyricsDiskCache()

    /// The **offline** store, for tracks the user deliberately downloaded.
    ///
    /// Deliberately NOT in Caches. The whole point of downloading is that the
    /// music works with no network, and iOS is free to evict a Caches directory
    /// whenever it likes — so lyrics saved alongside a download have to live in
    /// Application Support, where they survive until the user removes them. It is
    /// excluded from iCloud backup: it is all re-derivable, just not re-derivable
    /// *offline*, which is exactly why it has to be on disk.
    public static let offline = LyricsDiskCache(directory: offlineDirectory())

    private struct Entry: Codable {
        let lyrics: Lyrics?
        /// When the *authoritative* resolution that produced this entry ran. Used
        /// to debounce the background re-check of remembered negatives.
        let lastChecked: Date
    }

    private var entries: [String: Entry] = [:]
    private let fileURL: URL?
    private var loaded = false
    private var dirty = false
    private var persistTask: Task<Void, Never>?

    /// The filename carries a schema version so bumping it cleanly invalidates
    /// every cached entry in one go — the escape hatch for a resolver bug that
    /// poisoned negatives, or a change to the `Lyrics` shape.
    private static let cacheFileName = "mozz-lyrics-cache-v1.json"
    private static let cacheFilePrefix = "mozz-lyrics-cache"

    public init(directory: URL? = LyricsDiskCache.defaultDirectory()) {
        self.fileURL = directory?.appendingPathComponent(Self.cacheFileName)
        if let directory { Self.removeSupersededCaches(in: directory) }
    }

    /// The cached entry for `key`:
    /// - `.some(.some(lyrics))` — a positive hit, use these lyrics;
    /// - `.some(.none)` — a remembered "no lyrics"; skip the network and stay
    ///   quiet (the caller may kick a background re-check);
    /// - `nil` — no entry, resolve it.
    public func cached(_ key: String) -> Lyrics?? {
        loadIfNeeded()
        guard let entry = entries[key] else { return nil }
        return .some(entry.lyrics)
    }

    /// Seconds since `key` was last authoritatively resolved, or `nil` when there
    /// is no entry. Callers use this to decide whether a remembered negative is
    /// old enough to deserve a background re-check.
    public func entryAge(_ key: String) -> TimeInterval? {
        loadIfNeeded()
        guard let entry = entries[key] else { return nil }
        return Date().timeIntervalSince(entry.lastChecked)
    }

    public func store(_ lyrics: Lyrics?, for key: String) {
        loadIfNeeded()
        entries[key] = Entry(lyrics: lyrics, lastChecked: Date())
        dirty = true
        schedulePersist()
    }

    /// Records that we re-checked `key` and found nothing new, without changing
    /// the stored answer. Resets the debounce clock so the next background refresh
    /// waits the full interval again.
    public func touch(_ key: String) {
        loadIfNeeded()
        guard let entry = entries[key] else { return }
        entries[key] = Entry(lyrics: entry.lyrics, lastChecked: Date())
        dirty = true
        schedulePersist()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return
        }
        entries = decoded
    }

    /// Debounces writes so a burst of `store` calls (an album prefetch sweep)
    /// produces one disk write rather than one per track.
    private func schedulePersist() {
        guard dirty else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.persist()
        }
    }

    private func persist() {
        guard dirty, let fileURL else { return }
        dirty = false
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Deletes older-versioned cache files so each schema bump self-cleans its
    /// predecessor rather than leaving orphans on disk.
    private static func removeSupersededCaches(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for file in files
        where file.lastPathComponent != cacheFileName
            && file.lastPathComponent.hasPrefix(cacheFilePrefix)
            && file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    public static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    /// Durable storage for downloaded tracks' lyrics, created on first use.
    public static func offlineDirectory() -> URL? {
        guard var directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        directory.appendPathComponent("Lyrics", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? directory.setResourceValues(resourceValues)
        }
        return directory
    }
}

/// Builds the cache key for a track's lyrics.
///
/// Scoping by the owning connection is required, not cosmetic: server track IDs
/// are only locally unique, so two different Plex/Jellyfin servers (or a Plex and
/// a Jellyfin item) can collide on raw `id` alone and leak one library's lyrics —
/// or its remembered negatives — into another.
public enum LyricsCacheKey {
    public static func make(trackID: String, connectionID: String?) -> String {
        guard let connectionID, !connectionID.isEmpty else { return trackID }
        return "\(connectionID)::\(trackID)"
    }
}
