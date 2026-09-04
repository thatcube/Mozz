import Foundation

/// How loudness normalization ("ReplayGain" / Apple "Sound Check") picks which
/// gain to apply.
///
/// ## Why three cases when the core stores one gain per track
///
/// This is the resolution of a real cross-platform divergence (verified against
/// the code, not the comments):
///
/// - **Swift shell (before this):** normalization was a single `Bool`
///   (`mozz.normalizationEnabled`, default *on*). On → apply the track's one
///   stored gain; off → apply nothing.
/// - **C# desktop shell:** `ReplayGainMode { Off, Track, Album }` with a
///   default of `Track`, plus fallback math in `Dsp/ReplayGain.cs`. But the
///   desktop UI only ever calls `SetReplayGain(Track)` or `SetReplayGain(Off)`
///   (`MainViewModel` lines 337/402), and the album gain is *never* populated
///   (`ReplayGainAlbumDb` has no writer; only `ReplayGainTrackDb` is set from
///   `track.NormalizationGainDB`). So `Album` mode is unreachable dead state.
///
/// The core deliberately keeps the **richer superset** (`off`/`track`/`album`)
/// rather than collapsing to a Bool, because it is the shared definition every
/// shell will read and a future server integration may expose a distinct album
/// gain. Until the core stores a separate album gain, `album` behaves like
/// `track`: both apply the single `Track.normalizationGainDB` the sync layer
/// collapses `trackGain ?? albumGain` into. That equivalence is intentional and
/// is pinned by a test — it is not a bug to "fix" by making `album` a no-op.
public enum ReplayGainMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Do not apply any loudness normalization.
    case off
    /// Normalize each track to its own measured loudness.
    case track
    /// Normalize to the album's loudness so relative levels within an album are
    /// preserved. Falls back to the per-track gain when no album gain is stored
    /// — which, with today's single-gain core model, is always.
    case album

    public var id: String { rawValue }

    /// Parse a persisted/opaque string, tolerating unknown values by falling
    /// back to the default so a corrupt or future-format row can never crash.
    public static func parse(_ raw: String?) -> ReplayGainMode {
        guard let raw, let mode = ReplayGainMode(rawValue: raw) else { return .default }
        return mode
    }

    /// Default when nothing is stored. `track` matches the C# desktop default
    /// and is equivalent to the old Swift "normalization on" behaviour.
    public static let `default`: ReplayGainMode = .track
}

/// The complete, platform-neutral definition of every setting that shapes the
/// *sound* of playback: the graphic equalizer and loudness normalization.
///
/// This is core behaviour, not shell behaviour — "presentation may differ
/// between platforms, sound may not." Historically these lived in per-platform
/// preference stores (`UserDefaults`/`@AppStorage` on Apple, `AppPreferences`
/// JSON on desktop), which meant they could never sync between devices and the
/// two platforms drifted in both which settings existed and what they meant.
/// Persisting one definition in the core's database, reachable through the
/// command Facade, fixes both.
///
/// Every value is normalized/clamped on construction, so a corrupt persisted
/// row or an out-of-range caller can never yield invalid settings.
public struct PlaybackSettings: Codable, Equatable, Sendable {
    /// The bound the ReplayGain preamp is clamped to (± dB). Shares the EQ's
    /// ±12 dB range: the same "musically useful, hard to clip by accident"
    /// reasoning applies, and it matches the desktop biquad preamp clamp.
    public static let preampRange: ClosedRange<Double> = EqualizerSettings.gainRange

    /// Whether the graphic equalizer is applied at all. Default *off* — both
    /// shells defaulted EQ off (`mozz.equalizerEnabled`).
    public private(set) var equalizerEnabled: Bool

    /// The graphic-EQ curve. Reuses ``EqualizerSettings`` verbatim (same 10 ISO
    /// bands, same ±12 dB clamp, same `{gains, preampDB}` JSON both shells
    /// already persist), so no semantics change and stored blobs stay readable.
    public private(set) var equalizer: EqualizerSettings

    /// Which loudness-normalization gain to apply. Default ``ReplayGainMode/track``.
    public private(set) var replayGainMode: ReplayGainMode

    /// A global preamp in dB added on top of the normalization gain. Clamped to
    /// ``preampRange``. Both shells had a preamp parameter defaulting to 0 with
    /// no UI; this keeps that value one definition instead of two.
    public private(set) var replayGainPreampDB: Double

    public init(equalizerEnabled: Bool = false,
                equalizer: EqualizerSettings = .flat,
                replayGainMode: ReplayGainMode = .default,
                replayGainPreampDB: Double = 0) {
        self.equalizerEnabled = equalizerEnabled
        self.equalizer = equalizer
        self.replayGainMode = replayGainMode
        self.replayGainPreampDB = Self.clampPreamp(replayGainPreampDB)
    }

    /// The neutral defaults used when nothing has been stored yet.
    public static var defaults: PlaybackSettings { PlaybackSettings() }

    public static func clampPreamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, preampRange.lowerBound), preampRange.upperBound)
    }

    // Decode through the validating initializer so a corrupt or future-format
    // persisted blob can never bypass clamping (same guarantee EqualizerSettings
    // makes). Unknown ReplayGain strings degrade to the default rather than fail.
    private enum CodingKeys: String, CodingKey {
        case equalizerEnabled, equalizer, replayGainMode, replayGainPreampDB
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let enabled = try container.decodeIfPresent(Bool.self, forKey: .equalizerEnabled) ?? false
        let eq = try container.decodeIfPresent(EqualizerSettings.self, forKey: .equalizer) ?? .flat
        let rawMode = try container.decodeIfPresent(String.self, forKey: .replayGainMode)
        let preamp = try container.decodeIfPresent(Double.self, forKey: .replayGainPreampDB) ?? 0
        self.init(equalizerEnabled: enabled,
                  equalizer: eq,
                  replayGainMode: ReplayGainMode.parse(rawMode),
                  replayGainPreampDB: preamp)
    }
}
