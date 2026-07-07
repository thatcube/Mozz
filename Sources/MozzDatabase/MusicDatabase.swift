import Foundation
import GRDB

/// The on-device catalog database: Mozz's single source of truth.
///
/// Wraps a GRDB `DatabaseWriter` (a `DatabasePool` on device for
/// concurrent WAL reads during a sync write; a `DatabaseQueue` in memory for
/// tests). GRDB types never appear in this type's public surface, so callers
/// (`MozzSync`, `MozzApp`, `MozzDownloads`) work purely in terms of records and
/// domain models and never import GRDB.
public final class MusicDatabase: Sendable {
    let dbWriter: any DatabaseWriter

    init(dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try Schema.makeMigrator().migrate(dbWriter)
    }

    /// Open (creating if needed) an on-disk catalog with a WAL-mode pool.
    public static func open(at url: URL) throws -> MusicDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var config = Configuration()
        // Busy timeout so brief writer contention doesn't surface as errors.
        config.busyMode = .timeout(5)
        // WAL allows concurrent reads during a write, but the reader pool is
        // finite (GRDB default 5). During a sync write the UI issues many
        // concurrent reads (browse pages, artwork, search); a bigger pool keeps
        // an as-you-type search from starving the browse/artwork reads.
        config.maximumReaderCount = 10
        config.prepareDatabase { db in
            // In WAL mode `synchronous = NORMAL` is safe (a crash can only lose
            // the last uncommitted transaction — never corrupt the file) and
            // avoids an fsync on every commit. The catalog sync commits one
            // transaction per page, so on a large library this removes ~100
            // forced disk syncs and markedly speeds up the write-bound tail. The
            // catalog is a rebuildable cache anyway (a resync restores anything a
            // power-loss dropped), so there's no durability concern here.
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            // A larger page cache (~16 MB) keeps b-tree/index pages hot during
            // the bulk write instead of round-tripping to disk.
            try db.execute(sql: "PRAGMA cache_size = -16000")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        return try MusicDatabase(dbWriter: pool)
    }

    /// An isolated in-memory catalog for tests and previews.
    public static func inMemory() throws -> MusicDatabase {
        try MusicDatabase(dbWriter: try DatabaseQueue())
    }

    /// Run a read on a background reader. Reads never block writes (WAL).
    public func read<T: Sendable>(_ body: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await dbWriter.read(body)
    }

    /// Run a write transaction on the single writer connection.
    public func write<T: Sendable>(_ body: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await dbWriter.write(body)
    }

    /// Total number of tracks in the catalog (fast; uses the covering index).
    public func trackCount() async throws -> Int {
        try await dbWriter.read { db in
            try TrackRecord.fetchCount(db)
        }
    }
}
