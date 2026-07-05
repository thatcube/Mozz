import Foundation

/// The single, shared definition of what counts as a "liked" song across
/// backends — so the repository query, the UI, and the recommender all agree.
///
/// The two backends model likes differently: **Jellyfin** has a boolean favorite
/// (`isFavorite`); **Plex** has no favorite, only a 0–5 star rating. Mozz unifies
/// them: a track is *liked* if it's a Jellyfin favorite **or** its Plex rating is
/// at least ``ratingThreshold``. A track only ever lives on one server (one
/// backend), so exactly one of the two signals is ever meaningful per track.
public enum LikePolicy {
    /// A Plex track counts as "liked" at or above this star rating (0–5). 4★
    /// means "I really like this", so pre-existing 4/4.5/5★ ratings a user set in
    /// Plexamp already surface as Liked — we respect their ratings.
    public static let ratingThreshold: Double = 4.0

    /// The star value a plain "like" tap assigns on a rating-based backend (Plex).
    public static let likeStars: Double = 5.0

    /// Whether a track is liked, given its favorite flag and optional rating.
    public static func isLiked(isFavorite: Bool, rating: Double?) -> Bool {
        isFavorite || (rating ?? 0) >= ratingThreshold
    }
}
