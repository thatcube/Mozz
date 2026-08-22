import Foundation

/// User-facing preferences for lyrics.
enum LyricsSettings {
    /// Whether Mozz may consult the keyless public LRCLIB lookup when the user's
    /// own server has no lyrics for a track.
    ///
    /// On by default — it's where most synced lyrics actually come from — but it
    /// is the one part of the feature that sends anything off the user's network
    /// (a track title, artist and duration), so it gets an explicit off-switch.
    /// When off, only the server is consulted.
    static let onlineLookupKey = "mozz.lyricsOnlineLookup"

    /// Whether downloading a track also saves its lyrics for offline listening.
    ///
    /// On by default — it is the whole point of downloading that the track works
    /// with no signal — but it does mean a lookup per downloaded track, so
    /// anyone downloading a large library on a metered connection can turn it off.
    static let offlineCaptureKey = "mozz.lyricsOfflineCapture"
}
