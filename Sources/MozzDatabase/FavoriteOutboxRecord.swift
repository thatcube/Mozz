import Foundation
import GRDB
import MozzCore

/// A pending like/rating write awaiting sync to the server (offline write-back
/// queue). See migration v8 / ``FavoritesStore``.
public struct FavoriteOutboxRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "favorite_outbox"

    public var id: Int64?
    public var serverId: String
    public var remoteId: String
    public var itemType: String
    /// "favorite" or "rating".
    public var kind: String
    /// favorite → 1/0; rating → stars (nil = clear the rating).
    public var value: Double?
    public var createdAt: Double

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// Whether this pending change represents a "liked" end state.
    public var isLiked: Bool {
        kind == "favorite" ? (value ?? 0) >= 0.5 : LikePolicy.isLiked(isFavorite: false, rating: value)
    }
}
