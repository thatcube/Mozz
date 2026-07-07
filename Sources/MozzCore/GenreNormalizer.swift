import Foundation

/// Canonical genre normalization for the recommendation genre engine (ADR-0007,
/// phase B4.5). Provider genres (Plex/Jellyfin, free-text ID3-derived) are
/// Title-Case with mixed separators — `"Hip-Hop"`, `"Hip Hop"`, `"hip_hop"` —
/// while MusicBrainz `mb_tags` are lowercased canonical vocabulary (`"hip hop"`).
/// Left un-normalized these are DIFFERENT keys in `GenreSimilarity` (which is a
/// plain string-keyed TF-IDF space): double-counted in the corpus IDF and never
/// matched in cosine/Jaccard.
///
/// `key` collapses those variants to one canonical matching key; `display`
/// renders a key back to a human label for UI ("because you're into Hip Hop").
///
/// This normalization is applied identically on EVERY side that feeds the genre
/// engine — corpus, candidates, seed, taste — so `GenreSimilarity`'s keys line up
/// and the math is untouched. It is Swift-side (not SQL `LOWER()`) on purpose:
/// SQLite `LOWER()` is ASCII-only and can't fold separators, and `mb_tags` are
/// already Swift-`.lowercased()` at rest, so Swift folding is the only choice
/// that's byte-consistent with the stored data.
public enum GenreNormalizer {
    /// The canonical matching key for a genre string: lowercased (full Unicode),
    /// with `-`, `_`, `/` and any run of whitespace folded to a single space, and
    /// trimmed. Returns `""` for a blank/separator-only input (callers drop empties).
    public static func key(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(raw.unicodeScalars.count)
        var pendingSpace = false
        var emittedAny = false
        for scalar in raw.lowercased().unicodeScalars {
            let isSeparator = scalar == "-" || scalar == "_" || scalar == "/"
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
            if isSeparator {
                // Coalesce runs of separators into a single space; suppress leading.
                if emittedAny { pendingSpace = true }
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(scalar)
            emittedAny = true
        }
        return String(out)
    }

    /// Normalize + dedupe a list of genres, preserving first-seen order and
    /// dropping empties. The canonical genre set for one track/seed/query.
    public static func keys(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(raw.count)
        for value in raw {
            let k = key(value)
            guard !k.isEmpty, seen.insert(k).inserted else { continue }
            out.append(k)
        }
        return out
    }

    /// The canonical union of two genre lists (e.g. `track.genres` ∪ `mb_tags`),
    /// normalized and deduped — the "effective genres" of a track.
    public static func merge(_ base: [String], _ extra: [String]) -> [String] {
        keys(base + extra)
    }

    /// A human-facing label for a normalized key: title-cases each word
    /// (`"hip hop"` → `"Hip Hop"`). Used only for display (reasons), never for
    /// matching. Idempotent enough for already-cased input.
    public static func display(_ key: String) -> String {
        key.split(separator: " ")
            .map { word -> String in
                guard let first = word.first else { return String(word) }
                return String(first).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}
