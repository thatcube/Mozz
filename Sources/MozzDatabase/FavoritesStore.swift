import Foundation
import GRDB
import MozzCore

/// A like/rating change to apply. On a favorite backend (Jellyfin) use
/// ``favorite``; on a rating backend (Plex) use ``rating`` (nil clears it).
public struct FavoriteChange: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case favorite(Bool)
        case rating(Double?)
    }
    public var serverId: ServerID
    public var remoteId: String
    public var itemType: CatalogItemType
    public var value: Value

    public init(serverId: ServerID, remoteId: String, itemType: CatalogItemType = .track, value: Value) {
        self.serverId = serverId
        self.remoteId = remoteId
        self.itemType = itemType
        self.value = value
    }

    /// The resulting "liked" state this change represents.
    public var isLiked: Bool {
        switch value {
        case .favorite(let f): return f
        case .rating(let r): return LikePolicy.isLiked(isFavorite: false, rating: r)
        }
    }

    var kindString: String { if case .favorite = value { return "favorite" } else { return "rating" } }
    var storedValue: Double? {
        switch value {
        case .favorite(let f): return f ? 1 : 0
        case .rating(let r): return r
        }
    }
}

/// The offline-first write side of likes/ratings. A change is applied to the
/// LOCAL track row immediately (the DB is the source of truth, so the UI updates
/// instantly and works offline) and recorded in the `favorite_outbox` to be
/// flushed to the server later. The actual network call is injected by the app
/// layer (which owns the active backend), so this stays testable off-device.
public struct FavoritesStore: Sendable {
    private let database: MusicDatabase

    public init(_ database: MusicDatabase) { self.database = database }

    /// Apply a change locally (update the track row + enqueue a pending server
    /// write, replacing any older pending write for the same track). Returns the
    /// resulting liked state.
    @discardableResult
    public func applyLocally(_ change: FavoriteChange) async throws -> Bool {
        try await database.write { db in
            switch change.value {
            case .favorite(let fav):
                try db.execute(sql: "UPDATE track SET isFavorite = ? WHERE serverId = ? AND remoteId = ?",
                               arguments: [fav, change.serverId, change.remoteId])
            case .rating(let stars):
                try db.execute(sql: "UPDATE track SET rating = ? WHERE serverId = ? AND remoteId = ?",
                               arguments: [stars, change.serverId, change.remoteId])
            }
            // Newest intent wins: the unique (serverId, remoteId) index means this
            // upsert collapses like→unlike→like into a single pending row.
            try db.execute(sql: """
                INSERT INTO favorite_outbox (serverId, remoteId, itemType, kind, value, createdAt)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(serverId, remoteId) DO UPDATE SET
                    itemType = excluded.itemType, kind = excluded.kind,
                    value = excluded.value, createdAt = excluded.createdAt
                """, arguments: [change.serverId, change.remoteId, change.itemType.rawValue,
                                 change.kindString, change.storedValue, Date().timeIntervalSince1970])
            return change.isLiked
        }
    }

    /// Pending server writes, oldest first (flush order).
    public func pending(serverId: ServerID? = nil) async throws -> [FavoriteOutboxRecord] {
        try await database.read { db in
            if let serverId {
                return try FavoriteOutboxRecord.fetchAll(db, sql:
                    "SELECT * FROM favorite_outbox WHERE serverId = ? ORDER BY createdAt", arguments: [serverId])
            }
            return try FavoriteOutboxRecord.fetchAll(db, sql: "SELECT * FROM favorite_outbox ORDER BY createdAt")
        }
    }

    /// Remove a pending op once the server write succeeds.
    public func removePending(id: Int64) async throws {
        _ = try await database.write { db in try FavoriteOutboxRecord.deleteOne(db, key: id) }
    }

    /// Compare-and-delete: remove the pending op ONLY if it still holds the value
    /// we just synced (its `createdAt` is unchanged). If the user re-toggled the
    /// track while the server write was in flight, `applyLocally` bumped this
    /// row's `createdAt` in place, so this no-ops and the newer intent stays
    /// queued for the next flush — closing the write-back staleness race on slow
    /// servers. Returns whether a row was actually deleted.
    @discardableResult
    public func removePending(id: Int64, ifUnchangedSince createdAt: Double) async throws -> Bool {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM favorite_outbox WHERE id = ? AND createdAt = ?",
                           arguments: [id, createdAt])
            return db.changesCount > 0
        }
    }

    /// The current liked state of a track (reads the local row).
    public func isLiked(serverId: ServerID, remoteId: String) async throws -> Bool {
        try await database.read { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT isFavorite, rating FROM track WHERE serverId = ? AND remoteId = ?",
                arguments: [serverId, remoteId]) else { return false }
            return LikePolicy.isLiked(isFavorite: row["isFavorite"], rating: row["rating"])
        }
    }
}
