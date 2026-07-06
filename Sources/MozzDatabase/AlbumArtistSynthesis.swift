import GRDB

/// Backfills artist rows for album-artists that a server *references on albums*
/// but omits from its artist listing. Jellyfin's `/Artists` endpoint drops some
/// album-artists — DJs, producers, remixers, and combined credits like
/// "Yungblud, Halsey" — so ~7% of a real library's albums pointed at an artist
/// that had no row and were therefore unbrowsable under any artist.
///
/// The album already carries the album-artist's id *and* name, so we can create
/// the missing artist rows purely from synced albums — no extra network, works
/// offline. Runs both at sync time (its ids kept out of the artist prune) and as
/// a one-off migration so installed catalogs get the fix without a re-sync.
enum AlbumArtistSynthesis {
    /// Create/refresh artist rows for one server's album-artists that are missing
    /// from the `artist` table. Idempotent UPSERT on (serverId, remoteId): ids
    /// stay stable across runs, and if the server later *does* return the real
    /// artist (same id), the normal artist upsert simply takes over the row.
    /// Returns the synthesized remote ids so the caller can keep them alive
    /// through the artist prune.
    @discardableResult
    static func run(_ db: Database, serverId: String) throws -> [String] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT DISTINCT artistRemoteId, artistName FROM album
            WHERE serverId = ? AND artistRemoteId IS NOT NULL AND artistRemoteId <> ''
              AND artistRemoteId NOT IN (SELECT remoteId FROM artist WHERE serverId = ?)
            """, arguments: [serverId, serverId])
        guard !rows.isEmpty else { return [] }
        let stmt = try db.makeStatement(sql: """
            INSERT INTO artist (serverId, remoteId, name, sortName, isFavorite, genres)
            VALUES (?, ?, ?, ?, 0, '[]')
            ON CONFLICT(serverId, remoteId) DO UPDATE SET name = excluded.name, sortName = excluded.sortName
            """)
        var ids: [String] = []
        for row in rows {
            let remoteId: String = row["artistRemoteId"]
            let name: String = row["artistName"] ?? "Unknown Artist"
            try stmt.execute(arguments: [serverId, remoteId, name, name])
            ids.append(remoteId)
        }
        return ids
    }
}
