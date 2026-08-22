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
}
