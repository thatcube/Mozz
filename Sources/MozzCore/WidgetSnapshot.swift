import Foundation

/// Shared constants + models for the Home/Lock Screen widgets. Lives in
/// `MozzCore` (Foundation-only) so both the app and the widget extension can use
/// the same types. The app *writes* small JSON snapshots (+ artwork PNGs) into
/// the App Group container on playback / recent changes; the widget *reads* them
/// — no database or networking in the extension process.
public enum MozzWidget {
    /// App Group identifier shared by the app and the widget extension. Must
    /// match the `appGroups` entitlement in both targets (project.yml).
    public static let appGroupID = "group.com.thatcube.Mozz"

    /// WidgetKit `kind` identifiers (also used to reload timelines).
    public static let nowPlayingKind = "MozzNowPlaying"
    public static let recentlyPlayedKind = "MozzRecentlyPlayed"
}

/// The currently-playing track, as the widget needs it.
public struct NowPlayingWidgetSnapshot: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String
    public var isPlaying: Bool
    /// Filename (within the App Group artwork dir) of the cover art, if written.
    public var artworkFile: String?
    /// `mozz://` deep link the widget opens when tapped.
    public var deepLink: String

    public init(title: String, artist: String, isPlaying: Bool, artworkFile: String?, deepLink: String) {
        self.title = title
        self.artist = artist
        self.isPlaying = isPlaying
        self.artworkFile = artworkFile
        self.deepLink = deepLink
    }
}

/// One entry in the "Recently Played" widget.
public struct RecentlyPlayedItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var artworkFile: String?
    public var deepLink: String

    public init(id: String, title: String, subtitle: String, artworkFile: String?, deepLink: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.artworkFile = artworkFile
        self.deepLink = deepLink
    }
}

public struct RecentlyPlayedWidgetSnapshot: Codable, Equatable, Sendable {
    public var items: [RecentlyPlayedItem]
    public init(items: [RecentlyPlayedItem]) { self.items = items }
}

/// Reads/writes widget snapshots + artwork in the shared App Group container.
/// Every method no-ops (or returns nil) when the container is unavailable (e.g.
/// an unsigned simulator build without the provisioned entitlement), so callers
/// never need to special-case it.
public enum WidgetSnapshotStore {
    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: MozzWidget.appGroupID)
    }

    private static var artworkDir: URL? {
        guard let base = containerURL?.appendingPathComponent("WidgetArtwork", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func fileURL(_ name: String) -> URL? {
        containerURL?.appendingPathComponent(name)
    }

    // MARK: Now Playing

    public static func writeNowPlaying(_ snapshot: NowPlayingWidgetSnapshot?) {
        guard let url = fileURL("now_playing.json") else { return }
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public static func readNowPlaying() -> NowPlayingWidgetSnapshot? {
        guard let url = fileURL("now_playing.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NowPlayingWidgetSnapshot.self, from: data)
    }

    // MARK: Recently Played

    public static func writeRecentlyPlayed(_ snapshot: RecentlyPlayedWidgetSnapshot) {
        guard let url = fileURL("recently_played.json"),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func readRecentlyPlayed() -> RecentlyPlayedWidgetSnapshot? {
        guard let url = fileURL("recently_played.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecentlyPlayedWidgetSnapshot.self, from: data)
    }

    // MARK: Artwork

    /// Persist artwork bytes under `name` and return `name` on success (the value
    /// stored in a snapshot's `artworkFile`). No-ops when the container is absent.
    @discardableResult
    public static func writeArtwork(_ data: Data, name: String) -> String? {
        guard let dir = artworkDir else { return nil }
        let url = dir.appendingPathComponent(name)
        do { try data.write(to: url, options: .atomic); return name } catch { return nil }
    }

    /// Resolve a stored artwork filename to a readable file URL.
    public static func artworkURL(_ name: String?) -> URL? {
        guard let name, let dir = artworkDir else { return nil }
        let url = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
