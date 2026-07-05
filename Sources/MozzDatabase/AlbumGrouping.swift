import Foundation

/// Derives a stable "album group key" used to consolidate the fragments that a
/// server (notably Jellyfin) splits a single album into — e.g. one album
/// entity per track, all sharing the same album-artist and title. Grouping by
/// this key lets the read layer present one logical album without ever mutating
/// or deleting the faithfully-mirrored provider rows.
///
/// Key policy (per the design review):
/// - Prefer the album-artist's stable id when present; fall back to the
///   album-artist *name* only when there is no id (some albums reference an
///   album-artist id the server didn't return).
/// - Normalize the title (case/diacritic/whitespace) but never strip edition
///   markers like "(Deluxe)"/"(Remastered)", so different editions stay separate.
/// The key is computed identically at album upsert and in the backfill
/// migration, so on-disk rows and freshly-synced rows always agree.
enum AlbumGrouping {
    /// Unit-separator: cannot appear in titles/ids, so the two parts never collide.
    private static let separator = "\u{1F}"

    static func key(artistRemoteId: String?, artistName: String, title: String) -> String {
        let artistPart: String
        if let id = artistRemoteId, !id.trimmingCharacters(in: .whitespaces).isEmpty {
            artistPart = "id:" + id
        } else {
            artistPart = "name:" + normalize(artistName)
        }
        return artistPart + separator + normalize(title)
    }

    /// Case- and diacritic-insensitive, whitespace-trimmed and internally
    /// collapsed. Deterministic per device (keys are only ever compared within
    /// the same DB, so no cross-device stability is required).
    static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let collapsed = folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed
    }
}
