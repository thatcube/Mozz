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
    /// Server exposes per-user star ratings (Plex `userRating`). Distinct from
    /// favorites: Plex has ratings but no boolean favorite; Jellyfin is the
    /// reverse. The UI shows a heart when `supportsFavorites`, a rating chip when
    /// `supportsRatings`.
    public var supportsRatings: Bool
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

    /// The detected server *product* string when known (e.g. "Navidrome",
    /// "Gonic", "Ampache", "LMS"). Distinct from ``backend`` (the *protocol*):
    /// several products all speak Subsonic/OpenSubsonic and we display which one
    /// is on the other end for support/UX.
    public var serverProductType: String?
    /// True when the server advertises the OpenSubsonic extensions endpoint —
    /// i.e. it is an OpenSubsonic-capable server rather than a strict classic
    /// Subsonic implementation. Missing/false is a legitimate "classic" profile,
    /// not a failure.
    public var isOpenSubsonic: Bool

    /// When these capabilities were last probed.
    public var detectedAt: Date

    public init(
        backend: BackendKind,
        serverVersion: String? = nil,
        supportsTranscoding: Bool = true,
        supportsOriginalFileDownload: Bool = true,
        supportsFavorites: Bool = true,
        supportsRatings: Bool = false,
        supportsLyrics: Bool = false,
        supportsSyncedLyrics: Bool = false,
        supportsNormalizationGain: Bool = false,
        supportsProgressReporting: Bool = true,
        hasPlexPass: Bool? = nil,
        serverProductType: String? = nil,
        isOpenSubsonic: Bool = false,
        detectedAt: Date = Date()
    ) {
        self.backend = backend
        self.serverVersion = serverVersion
        self.supportsTranscoding = supportsTranscoding
        self.supportsOriginalFileDownload = supportsOriginalFileDownload
        self.supportsFavorites = supportsFavorites
        self.supportsRatings = supportsRatings
        self.supportsLyrics = supportsLyrics
        self.supportsSyncedLyrics = supportsSyncedLyrics
        self.supportsNormalizationGain = supportsNormalizationGain
        self.supportsProgressReporting = supportsProgressReporting
        self.hasPlexPass = hasPlexPass
        self.serverProductType = serverProductType
        self.isOpenSubsonic = isOpenSubsonic
        self.detectedAt = detectedAt
    }
}

/// Where the capabilities used for a session came from — which also dictates
/// whether they should be written back to the store.
public enum CapabilitySource: Sendable, Equatable {
    /// Freshly probed from the live server — authoritative, persist it.
    case detected
    /// Server unreachable (offline); reusing the last-known stored record.
    /// Must NOT be re-persisted (it already is the stored row, and re-saving
    /// risks clobbering it with a partial value).
    case cached
    /// Nothing known yet (first activation, offline): conservative defaults,
    /// persisted so a row exists; corrected on the next successful detection.
    case fallback
}

public struct ResolvedCapabilities: Sendable {
    public var capabilities: ServerCapabilities
    public var source: CapabilitySource

    public init(capabilities: ServerCapabilities, source: CapabilitySource) {
        self.capabilities = capabilities
        self.source = source
    }

    /// Whether these capabilities should be written to the store.
    public var shouldPersist: Bool { source != .cached }
}

/// Decides which capabilities a (re)activation should use, and whether to
/// persist them.
///
/// The rule exists to fix a real bug: when a server is unreachable at launch,
/// `detectCapabilities()` fails, and naively falling back to
/// `ServerCapabilities(backend:)` **overwrites the last-known detected
/// capabilities with generic defaults** — silently changing gated features
/// (e.g. a server's detected synced-lyrics support) until the next online sync.
/// Live detection wins; otherwise keep the cached record untouched; only fall
/// back to defaults when nothing is stored yet.
public enum CapabilityResolver {
    public static func resolve(
        detected: ServerCapabilities?,
        cached: ServerCapabilities?,
        backend: BackendKind
    ) -> ResolvedCapabilities {
        if let detected {
            return ResolvedCapabilities(capabilities: detected, source: .detected)
        }
        if let cached {
            return ResolvedCapabilities(capabilities: cached, source: .cached)
        }
        return ResolvedCapabilities(capabilities: ServerCapabilities(backend: backend), source: .fallback)
    }
}
