import Foundation

/// Owns the on-disk location of downloaded audio files. The database stores a
/// *relative* path per download; this type turns that into an absolute URL and
/// performs the file operations. Keeping paths relative means the sandbox
/// container can move (as it does across app installs/updates) without
/// invalidating the catalog.
///
/// Files live under Application Support (not Caches, which the OS may purge)
/// laid out as `<root>/<serverId>/<remoteId>.<ext>`.
public struct DownloadFileStore: Sendable {
    public let root: URL
    private var fileManager: FileManager { .default }

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// The default downloads root inside the app's Application Support dir.
    public static func defaultRoot() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return base.appendingPathComponent("MozzDownloads", isDirectory: true)
    }

    /// Build the stable relative path for a track's downloaded file.
    public func relativePath(serverId: String, remoteId: String, fileExtension: String) -> String {
        let safeServer = Self.sanitize(serverId)
        let safeRemote = Self.sanitize(remoteId)
        let ext = fileExtension.isEmpty ? "audio" : fileExtension
        return "\(safeServer)/\(safeRemote).\(ext)"
    }

    public func absoluteURL(forRelativePath relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    public func fileExists(relativePath: String) -> Bool {
        fileManager.fileExists(atPath: absoluteURL(forRelativePath: relativePath).path)
    }

    /// Move a completed temp file into its final location, replacing any
    /// existing file. Returns the file size in bytes.
    @discardableResult
    public func moveIntoPlace(from temp: URL, relativePath: String) throws -> Int64 {
        let destination = absoluteURL(forRelativePath: relativePath)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temp, to: destination)
        let attrs = try fileManager.attributesOfItem(atPath: destination.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    public func delete(relativePath: String) throws {
        let url = absoluteURL(forRelativePath: relativePath)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    /// Total bytes used by all downloaded files on disk (an independent check
    /// against the database's accounting).
    public func totalBytesOnDisk() throws -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Remove every downloaded file (used by "delete all downloads").
    public func removeAll() throws {
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private static func sanitize(_ component: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = component.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let result = String(mapped)
        return result.isEmpty ? "item" : result
    }
}
