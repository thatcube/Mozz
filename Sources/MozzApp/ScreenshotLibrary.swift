import Foundation
import MozzCore

/// A small, curated library used to shoot App Store screenshots against the real
/// UI rather than a mock-up.
///
/// Screenshots can't be assembled after the fact: Mozz derives the Now Playing
/// backdrop from the artwork's prominent colours, so the art has to be in place
/// at capture time or the gradient behind every shot is wrong. They also can't
/// depend on a live server, because a login or a sync makes the run slow and
/// non-reproducible.
///
/// So a fixture directory on disk supplies the whole catalogue — manifest,
/// cover art and audio — and the app seeds itself from it. Nothing is bundled
/// into the shipping app and nothing is committed: the directory is handed over
/// at launch by ``tools/screenshots.sh`` through `MOZZ_SCREENSHOT_LIBRARY`.
///
/// Simulator-only by construction, since that is the only place screenshots are
/// taken and the fixture must never influence a real build.
public struct ScreenshotLibrary: Sendable {
    /// One album and its tracks, as described by the fixture's `manifest.json`.
    public struct AlbumSpec: Codable, Sendable {
        public var artist: String
        public var album: String
        public var year: Int?
        public var genre: String?
        /// Cover file name, relative to the fixture directory.
        public var cover: String
        public var tracks: [TrackSpec]
    }

    public struct TrackSpec: Codable, Sendable {
        public var title: String
        /// Audio file name, relative to the fixture directory.
        public var file: String
        /// Seconds. Optional because the fixture author may not know it; the
        /// loader measures the file when it's absent.
        public var duration: Double?
        /// `.lrc` sidecar, relative to the fixture directory. Plain (untimed)
        /// lyrics parse too, but only timed ones scroll — and the scrolling,
        /// highlighted state is the one worth screenshotting.
        public var lyrics: String?
    }

    public let root: URL
    public let albums: [AlbumSpec]

    /// The fixture, if one is present.
    ///
    /// Checked in the app's own Documents directory first: the app is sandboxed,
    /// so a path handed in from the host is unreadable even though the simulator
    /// itself can see it. The capture script copies the fixture into the
    /// container after installing, which is the only location that reliably
    /// works. The environment variable is still honoured for a hand-run.
    public static func fromEnvironment() -> ScreenshotLibrary? {
        #if targetEnvironment(simulator)
        if let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first {
            let bundled = documents.appendingPathComponent(containerFolder, isDirectory: true)
            if let library = ScreenshotLibrary(rootPath: bundled.path) { return library }
        }
        if let path = ProcessInfo.processInfo.environment["MOZZ_SCREENSHOT_LIBRARY"],
           !path.isEmpty, let library = ScreenshotLibrary(rootPath: path) {
            return library
        }
        return nil
        #else
        return nil
        #endif
    }

    /// Folder name the capture script copies the fixture to, inside Documents.
    public static let containerFolder = "ScreenshotFixture"

    public init?(rootPath: String) {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let albums = try? JSONDecoder().decode([AlbumSpec].self, from: data),
              !albums.isEmpty
        else { return nil }
        self.root = root
        self.albums = albums
    }

    public func coverURL(for album: AlbumSpec) -> URL {
        root.appendingPathComponent(album.cover)
    }

    public func audioURL(for track: TrackSpec) -> URL {
        root.appendingPathComponent(track.file)
    }

    // MARK: Catalog

    /// Artwork keys are the album's own id, so a track, its album and its artist
    /// all resolve to the same cover without a lookup table.
    static func artworkKey(albumID: String) -> String { "shot-art-\(albumID)" }

    /// The catalogue rows this fixture represents.
    ///
    /// Ids are derived from the manifest's position so a re-run produces exactly
    /// the same catalogue — screenshots stay diffable across runs.
    public func catalog() -> (artists: [Artist], albums: [Album], tracks: [Track]) {
        var artists: [Artist] = []
        var albumRows: [Album] = []
        var trackRows: [Track] = []
        var artistIDs: [String: String] = [:]

        for (albumIndex, spec) in albums.enumerated() {
            let albumID = "shot-alb-\(albumIndex)"
            let artistID: String
            if let existing = artistIDs[spec.artist] {
                artistID = existing
            } else {
                artistID = "shot-art-\(artistIDs.count)"
                artistIDs[spec.artist] = artistID
                artists.append(Artist(
                    id: artistID,
                    name: spec.artist,
                    sortName: spec.artist,
                    artwork: ArtworkRef(key: Self.artworkKey(albumID: albumID)),
                    albumCount: 1,
                    genres: [spec.genre ?? "Electronic"],
                    isFavorite: false
                ))
            }

            let artwork = ArtworkRef(key: Self.artworkKey(albumID: albumID))
            albumRows.append(Album(
                id: albumID,
                title: spec.album,
                sortTitle: spec.album,
                artistName: spec.artist,
                artistID: artistID,
                year: spec.year,
                artwork: artwork,
                trackCount: spec.tracks.count,
                genres: [spec.genre ?? "Electronic"],
                isFavorite: albumIndex == 0,
                addedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(albumIndex) * 86_400)
            ))

            for (trackIndex, track) in spec.tracks.enumerated() {
                let url = audioURL(for: track)
                let duration = track.duration ?? Self.estimatedDuration(ofFileAt: url) ?? 180
                trackRows.append(Track(
                    id: "shot-trk-\(albumIndex)-\(trackIndex)",
                    title: track.title,
                    sortTitle: track.title,
                    albumTitle: spec.album,
                    albumID: albumID,
                    artistName: spec.artist,
                    artistID: artistID,
                    albumArtistName: spec.artist,
                    trackNumber: trackIndex + 1,
                    discNumber: 1,
                    duration: duration,
                    format: AudioFormat(container: "mp3", codec: "mp3", bitrateKbps: 320,
                                        sampleRateHz: 44_100, channels: 2),
                    fileSizeBytes: Int64((try? FileManager.default
                        .attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 5_000_000),
                    mediaKey: "shot-media-\(albumIndex)-\(trackIndex)",
                    artwork: artwork,
                    genres: [spec.genre ?? "Electronic"],
                    isFavorite: trackIndex == 0,
                    normalizationGainDB: nil,
                    addedAt: Date(timeIntervalSince1970: 1_700_000_000
                                  + Double(albumIndex) * 86_400 + Double(trackIndex) * 60)
                ))
            }
        }
        return (artists, albumRows, trackRows)
    }

    /// Duration for a fixture track.
    ///
    /// The manifest normally carries it (the fixture builder measures each file),
    /// which keeps this synchronous — `AVAsset` duration is async since iOS 16
    /// and `catalog()` has no reason to be. When it's missing, estimate from file
    /// size at a nominal 320 kbps, which is close enough for a scrubber.
    static func estimatedDuration(ofFileAt url: URL) -> Double? {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64, size > 0 else { return nil }
        return Double(size) * 8 / 320_000
    }

    /// Map an ``ArtworkRef`` back to its cover file.
    public func coverURL(forArtworkKey key: String) -> URL? {
        for (index, spec) in albums.enumerated()
        where Self.artworkKey(albumID: "shot-alb-\(index)") == key {
            return coverURL(for: spec)
        }
        return nil
    }

    /// Map a track id back to its audio file.
    public func audioURL(forTrackID id: String) -> URL? {
        spec(forTrackID: id).map(audioURL(for:))
    }

    /// Lyrics for a fixture track, read from its `.lrc` sidecar.
    public func lyrics(forTrackID id: String) -> Lyrics? {
        guard let path = spec(forTrackID: id)?.lyrics,
              let text = try? String(contentsOf: root.appendingPathComponent(path),
                                     encoding: .utf8)
        else { return nil }
        return Lyrics(lrc: text) ?? Lyrics(plainText: text)
    }

    private func spec(forTrackID id: String) -> TrackSpec? {
        let parts = id.split(separator: "-")
        guard parts.count == 4, parts[0] == "shot", parts[1] == "trk",
              let albumIndex = Int(parts[2]), let trackIndex = Int(parts[3]),
              albums.indices.contains(albumIndex),
              albums[albumIndex].tracks.indices.contains(trackIndex)
        else { return nil }
        return albums[albumIndex].tracks[trackIndex]
    }
}
