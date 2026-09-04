import Foundation

/// Derives a stable "album group key" used to consolidate the fragments that a
/// server (notably Jellyfin) splits a single album into — e.g. one album
/// entity per track, all sharing the same album-artist and title. Grouping by
/// this key lets the read layer present one logical album without ever mutating
/// or deleting the faithfully-mirrored provider rows.
///
/// Key policy (per ADR-0006 / the design review):
/// - Prefer the album-artist's stable id when present; fall back to the
///   album-artist *name* only when there is no id (some albums reference an
///   album-artist id the server didn't return).
/// - Normalize the title (case/diacritic/whitespace) but never strip edition
///   markers like "(Deluxe)"/"(Remastered)", so different editions stay separate.
/// - **Title first**: the normalized sort-title leads the key so that
///   `ORDER BY albumGroupKey` yields alphabetical order and the
///   `(serverId, albumGroupKey)` index drives grouped paging with early
///   termination — no materialize-all-groups-then-sort.
/// The key is computed identically at album upsert and in the backfill
/// migration, so on-disk rows and freshly-synced rows always agree.
enum AlbumGrouping {
    /// Unit-separator: it cannot appear in a title or an id, so the two parts
    /// of a key never collide with each other.
    ///
    /// It does, however, appear in the **result**. An `albumGroupKey` contains
    /// a U+001F, so anything that later takes a group key and joins it with
    /// something else must not reach for this character too. Page cursors did
    /// exactly that — `PageCursor.token` used U+001F as its own separator — and
    /// an album cursor came back split into two keys, so the seek clause was
    /// built for one key while its arguments were bound for two and SQLite
    /// rejected the statement. Paging albums failed on the second page for
    /// every client that carries a cursor as text.
    ///
    /// The lesson is not "pick a rarer character". It is that a serialiser
    /// should not depend on what its input happens not to contain.
    private static let separator = "\u{1F}"

    static func key(artistRemoteId: String?, artistName: String, sortTitle: String) -> String {
        let artistPart: String
        if let id = artistRemoteId, !id.trimmingCharacters(in: .whitespaces).isEmpty {
            artistPart = "id:" + id
        } else {
            artistPart = "name:" + normalize(artistName)
        }
        return normalize(sortTitle) + separator + artistPart
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
