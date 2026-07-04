import Foundation

/// Per-server feature detection results.
///
/// Capability detection is first-class in Mozz: some features (synced lyrics,
/// favorites, forcing original-file download, ReplayGain tags) depend on the
/// backend kind *and* the specific server's version and licensing (e.g. a Plex
/// Pass). The app probes each server once, stores the result in the database
/// alongside the server row, and the UI gates features on these flags rather
/// than hard-coding per-backend assumptions.
public struct ServerCapabilities: Codable, Sendable, Hashable {
    public var backend: BackendKind
    /// Server product version string, when reported.
    public var serverVersion: String?

    /// Server can stream a transcoded copy on demand (both backends do).
    public var supportsTranscoding: Bool
    /// Server can serve the untouched original file for offline download.
    public var supportsOriginalFileDownload: Bool
    /// Server exposes per-user favorites we can read/write.
    public var supportsFavorites: Bool
    /// Server exposes plain (unsynced) lyrics.
    public var supportsLyrics: Bool
    /// Server exposes time-synced lyrics.
    public var supportsSyncedLyrics: Bool
    /// Track metadata carries a normalization/ReplayGain gain value.
    public var supportsNormalizationGain: Bool
    /// Server accepts playback progress / scrobble reports.
    public var supportsProgressReporting: Bool

    /// Plex-only: whether the account has an active Plex Pass. `nil` means not
    /// yet determined or not applicable.
    public var hasPlexPass: Bool?

    /// When these capabilities were last probed.
    public var detectedAt: Date

    public init(
        backend: BackendKind,
        serverVersion: String? = nil,
        supportsTranscoding: Bool = true,
        supportsOriginalFileDownload: Bool = true,
        supportsFavorites: Bool = true,
        supportsLyrics: Bool = false,
        supportsSyncedLyrics: Bool = false,
        supportsNormalizationGain: Bool = false,
        supportsProgressReporting: Bool = true,
        hasPlexPass: Bool? = nil,
        detectedAt: Date = Date()
    ) {
        self.backend = backend
        self.serverVersion = serverVersion
        self.supportsTranscoding = supportsTranscoding
        self.supportsOriginalFileDownload = supportsOriginalFileDownload
        self.supportsFavorites = supportsFavorites
        self.supportsLyrics = supportsLyrics
        self.supportsSyncedLyrics = supportsSyncedLyrics
        self.supportsNormalizationGain = supportsNormalizationGain
        self.supportsProgressReporting = supportsProgressReporting
        self.hasPlexPass = hasPlexPass
        self.detectedAt = detectedAt
    }
}
