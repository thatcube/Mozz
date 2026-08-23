import Foundation
import GRDB
import MozzCore

/// A durable boundary between network paging and catalog writes.
///
/// Offsets are safe to reuse only while the same server enumeration is still
/// in flight. Completed runs remain for diagnostics, but are never mistaken for
/// resumable work.
public struct CatalogSyncCheckpoint: Sendable, Equatable {
    public var serverId: ServerID
    public var phase: String
    public var committedOffset: Int
    public var reportedTotal: Int?
    public var completed: Bool
    public var updatedAt: Date

    public init(
        serverId: ServerID,
        phase: String,
        committedOffset: Int,
        reportedTotal: Int?,
        completed: Bool,
        updatedAt: Date = Date()
    ) {
        self.serverId = serverId
        self.phase = phase
        self.committedOffset = committedOffset
        self.reportedTotal = reportedTotal
        self.completed = completed
        self.updatedAt = updatedAt
    }
}

public struct CatalogSyncStore: Sendable {
    private let database: MusicDatabase

    public init(_ database: MusicDatabase) {
        self.database = database
    }

    /// Start a mirror, preserving checkpoints only for a recent interrupted run
    /// against the exact same enumeration source.
    @discardableResult
    public func beginRun(
        serverId: ServerID,
        sourceFingerprint: String,
        resumeIfPossible: Bool,
        maximumAge: TimeInterval,
        now: Date = Date()
    ) async throws -> Bool {
        try await database.write { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT sourceFingerprint, inProgress, updatedAt
                FROM catalogSyncRun WHERE serverId = ?
                """,
                arguments: [serverId]
            )
            let canResume: Bool
            if resumeIfPossible, let row {
                let fingerprint: String = row["sourceFingerprint"]
                let inProgress: Bool = row["inProgress"]
                let updatedAt: Double = row["updatedAt"]
                canResume = inProgress
                    && fingerprint == sourceFingerprint
                    && now.timeIntervalSince1970 - updatedAt <= maximumAge
            } else {
                canResume = false
            }

            if !canResume {
                try db.execute(
                    sql: "DELETE FROM catalogSyncProgress WHERE serverId = ?",
                    arguments: [serverId]
                )
            }
            try db.execute(
                sql: """
                INSERT INTO catalogSyncRun
                    (serverId, sourceFingerprint, inProgress, updatedAt)
                VALUES (?, ?, 1, ?)
                ON CONFLICT(serverId) DO UPDATE SET
                    sourceFingerprint = excluded.sourceFingerprint,
                    inProgress = 1,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [serverId, sourceFingerprint, now.timeIntervalSince1970]
            )
            return canResume
        }
    }

    public func hasInterruptedRun(serverId: ServerID) async throws -> Bool {
        try await database.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT inProgress FROM catalogSyncRun WHERE serverId = ?",
                arguments: [serverId]
            ) ?? false
        }
    }

    public func checkpoint(serverId: ServerID, phase: String) async throws -> CatalogSyncCheckpoint? {
        try await database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT committedOffset, reportedTotal, completed, updatedAt
                FROM catalogSyncProgress WHERE serverId = ? AND phase = ?
                """,
                arguments: [serverId, phase]
            ) else {
                return nil
            }
            return CatalogSyncCheckpoint(
                serverId: serverId,
                phase: phase,
                committedOffset: row["committedOffset"],
                reportedTotal: row["reportedTotal"],
                completed: row["completed"],
                updatedAt: Date(timeIntervalSince1970: row["updatedAt"])
            )
        }
    }

    public func clearCheckpoint(serverId: ServerID, phase: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM catalogSyncProgress WHERE serverId = ? AND phase = ?",
                arguments: [serverId, phase]
            )
        }
    }

    public func completePhase(
        serverId: ServerID,
        phase: String,
        committedOffset: Int,
        reportedTotal: Int?,
        now: Date = Date()
    ) async throws {
        try await database.write { db in
            try Self.save(
                CatalogSyncCheckpoint(
                    serverId: serverId,
                    phase: phase,
                    committedOffset: committedOffset,
                    reportedTotal: reportedTotal,
                    completed: true,
                    updatedAt: now
                ),
                in: db
            )
        }
    }

    public func finishRun(serverId: ServerID, now: Date = Date()) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                UPDATE catalogSyncRun
                SET inProgress = 0, updatedAt = ?
                WHERE serverId = ?
                """,
                arguments: [now.timeIntervalSince1970, serverId]
            )
        }
    }

    static func save(_ checkpoint: CatalogSyncCheckpoint, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO catalogSyncProgress
                (serverId, phase, committedOffset, reportedTotal, completed, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(serverId, phase) DO UPDATE SET
                committedOffset = excluded.committedOffset,
                reportedTotal = excluded.reportedTotal,
                completed = excluded.completed,
                updatedAt = excluded.updatedAt
            """,
            arguments: [
                checkpoint.serverId,
                checkpoint.phase,
                checkpoint.committedOffset,
                checkpoint.reportedTotal,
                checkpoint.completed,
                checkpoint.updatedAt.timeIntervalSince1970,
            ]
        )
        // Keeping the run timestamp level with page commits prevents a healthy
        // multi-hour first sync from aging out while it is actively progressing.
        try db.execute(
            sql: "UPDATE catalogSyncRun SET updatedAt = ? WHERE serverId = ?",
            arguments: [checkpoint.updatedAt.timeIntervalSince1970, checkpoint.serverId]
        )
    }
}
