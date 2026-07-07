import Foundation

/// Helpers for MusicBrainz identifiers (MBIDs).
///
/// An MBID is a canonical UUID (8-4-4-4-12 lowercase hex). MusicBrainz does NOT
/// guarantee they are UUID *version 4*, so validation checks only the canonical
/// shape — never the version/variant nibbles (rejecting on version would drop
/// valid ids). All comparisons are lowercased.
public enum MusicBrainzID {
    /// The MusicBrainz "Various Artists" placeholder artist MBID. Harvesting this
    /// as a track's artist MBID (from a compilation's artist-credit) would poison
    /// artist-scoped lookups, so callers skip it.
    public static let variousArtists = "89ad4ac3-39f7-470e-963a-56509c546377"

    /// Canonical MBID shape: 8-4-4-4-12 hex, case-insensitive.
    /// Anchored so a longer string with an embedded UUID does not match here.
    private static let canonical = try! NSRegularExpression(
        pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
        options: [.caseInsensitive])

    /// Unanchored UUID pattern, for extracting an MBID from inside a URI/URL.
    private static let embedded = try! NSRegularExpression(
        pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
        options: [.caseInsensitive])

    /// `true` if `raw` is a canonical MBID (any case).
    public static func isValid(_ raw: String) -> Bool {
        let r = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        return canonical.firstMatch(in: raw, options: [.anchored], range: r) != nil
    }

    /// A trimmed, lowercased MBID if `raw` is canonical; otherwise `nil`.
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(trimmed) else { return nil }
        return trimmed.lowercased()
    }

    /// Extract a normalized MBID from a provider "GUID" string, or `nil`.
    ///
    /// Handles the forms Plex/Jellyfin expose:
    /// - bare `<uuid>` (Jellyfin `ProviderIds` values)
    /// - `mbid://<uuid>`, `mbz://<uuid>`, `musicbrainz://<uuid>`
    /// - `https://musicbrainz.org/<entity>/<uuid>`
    /// - legacy Plex agent `com.plexapp.agents.musicbrainz://<uuid>?lang=en`
    ///
    /// Only strings that name MusicBrainz (or are a bare UUID) are mined, so an
    /// unrelated `plex://track/<hash>` GUID never yields a false MBID.
    public static func extract(fromGUID raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A bare canonical UUID is taken as-is.
        if let exact = normalized(trimmed) { return exact }

        // Otherwise only mine strings that reference MusicBrainz.
        let lower = trimmed.lowercased()
        guard lower.contains("musicbrainz") || lower.hasPrefix("mbid://")
            || lower.hasPrefix("mbz://") else { return nil }

        let r = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = embedded.firstMatch(in: trimmed, options: [], range: r),
              let range = Range(match.range, in: trimmed) else { return nil }
        return String(trimmed[range]).lowercased()
    }
}
