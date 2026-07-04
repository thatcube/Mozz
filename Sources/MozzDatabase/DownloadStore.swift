import Foundation
import GRDB
import MozzCore

/// The write side of offline-download state. The actual byte transfer lives in
/// `MozzDownloads`; this type owns only the durable record of what is queued,
/// in flight, complete or failed, plus where each file lives and how big it is.
public struct DownloadStore: Sendable {
    private let database: MusicDatabase

    public init(_ database: MusicDatabase) {
        self.database = database
    }

    /// Queue a download for a track if one isn't already recorded. Returns the
    /// resulting record (existing or newly queued).
    @discardableResult
    public func enqueue(trackId: Int64) async throws -> DownloadRecord {
        try await database.write { db in
            if let existing = try DownloadRecord.fetchOne(db, key: trackId) {
                return existing
            }
            let record = DownloadRecord(trackId: trackId, state: .queued)
            try record.insert(db)
            return record
        }
    }

    public func markDownloading(trackId: Int64, totalBytes: Int64?) async throws {
        try await update(trackId: trackId) { record in
            record.state = DownloadState.downloading.rawValue
            record.errorMessage = nil
            if let totalBytes { record.totalBytes = totalBytes }
        }
    }

    public func updateProgress(trackId: Int64, receivedBytes: Int64, totalBytes: Int64?) async throws {
        try await update(trackId: trackId) { record in
            record.sizeBytes = receivedBytes
            if let totalBytes { record.totalBytes = totalBytes }
        }
    }

    public func markDownloaded(trackId: Int64, localPath: String, sizeBytes: Int64) async throws {
        try await update(trackId: trackId) { record in
            record.state = DownloadState.downloaded.rawValue
            record.localPath = localPath
            record.sizeBytes = sizeBytes
            record.completedAt = Date().timeIntervalSince1970
            record.errorMessage = nil
        }
    }

    public func markFailed(trackId: Int64, error: String) async throws {
        try await update(trackId: trackId) { record in
            record.state = DownloadState.failed.rawValue
            record.errorMessage = error
        }
    }

    /// Remove the download record for a track (caller deletes the file).
    public func remove(trackId: Int64) async throws {
        _ = try await database.write { db in
            try DownloadRecord.deleteOne(db, key: trackId)
        }
    }

    /// The local relative path for a track's completed download, if any.
    public func localPath(forTrackId trackId: Int64) async throws -> String? {
        try await database.read { db in
            try String.fetchOne(db, sql: """
                SELECT localPath FROM download WHERE trackId = ? AND state = ?
                """, arguments: [trackId, DownloadState.downloaded.rawValue])
        }
    }

    /// Read-modify-write helper. Creates the record if missing so progress
    /// callbacks that arrive before `enqueue` completes are never lost.
    private func update(trackId: Int64, _ mutate: @escaping @Sendable (inout DownloadRecord) -> Void) async throws {
        try await database.write { db in
            var record = try DownloadRecord.fetchOne(db, key: trackId)
                ?? DownloadRecord(trackId: trackId, state: .queued)
            mutate(&record)
            try record.save(db)
        }
    }
}
