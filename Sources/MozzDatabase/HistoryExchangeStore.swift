import Foundation
import GRDB
import MozzCore
import MozzHistory

/// Portable history operations exposed to non-Swift clients through the FFI.
///
/// This adapter deliberately lives in `MozzDatabase`: it can see the GRDB-backed
/// `play_event` table and the platform-neutral `MozzHistory` wire types, while
/// callers such as `MozzFFI` only depend on `MozzDatabase`.
public struct HistoryExchangeStore: Sendable {
    private let database: MusicDatabase
    private let sync: HistorySyncStore

    public init(_ database: MusicDatabase) {
        self.database = database
        self.sync = HistorySyncStore(database)
    }

    public static let defaultMaximumBatchBytes = 256 * 1024

    /// Append a local playback event and assign its sync uid immediately.
    @discardableResult
    public func recordLocalPlayEvent(
        _ event: PlayEvent,
        serverId: ServerID,
        deviceID: String
    ) async throws -> HistoryExchangeEvent {
        let trackRef = PlayEventStore.trackRef(serverId: serverId, remoteId: event.trackID)
        let createdAtMS = HistorySyncStore.milliseconds(event.createdAt.timeIntervalSince1970)
        let positionMS = event.positionSeconds.map(HistorySyncStore.milliseconds)
        let durationMS = event.durationSeconds.map(HistorySyncStore.milliseconds)
        let historyEvent = HistoryEvent(
            deviceID: deviceID,
            trackRef: trackRef,
            kind: event.kind.rawValue,
            createdAtMS: createdAtMS,
            positionMS: positionMS,
            durationMS: durationMS,
            context: event.context,
            contextID: event.contextID
        )

        try await database.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO play_event
                    (track_ref, kind, position_sec, duration_sec,
                     context, context_id, device, created_at, event_uid)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    historyEvent.trackRef,
                    historyEvent.kind,
                    event.positionSeconds,
                    event.durationSeconds,
                    event.context,
                    event.contextID,
                    deviceID,
                    event.createdAt.timeIntervalSince1970,
                    historyEvent.uid,
                ])
        }

        return HistoryExchangeEvent(historyEvent)
    }

    /// Recent raw play events, newest first, paged by keyset cursor.
    public func recentEventsPage(
        serverId: ServerID? = nil,
        after cursor: HistoryEventPageCursor?,
        limit: Int
    ) async throws -> PlayHistoryEventPage {
        var predicates: [String] = []
        var args: StatementArguments = []
        if let serverId {
            let pattern = Self.likePrefix(serverId + ":") + "%"
            predicates.append("track_ref LIKE ? ESCAPE '\\'")
            args += [pattern]
        }
        if let cursor {
            // The leading bound is intentionally redundant. It lets SQLite seek
            // into idx_play_event_time instead of scanning from the newest row.
            predicates.append("created_at <= ? AND (created_at < ? OR (created_at = ? AND id < ?))")
            args += [cursor.createdAt, cursor.createdAt, cursor.createdAt, cursor.id]
        }
        let whereSQL = predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND ")
        args += [limit]
        let queryArgs = args

        let rows: [PlayHistoryEventSummary] = try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, event_uid, track_ref, kind, position_sec, duration_sec,
                       context, context_id, device, created_at
                FROM play_event
                \(whereSQL)
                ORDER BY created_at DESC, id DESC
                LIMIT ?
                """, arguments: queryArgs)
                .map(PlayHistoryEventSummary.init)
        }

        let next = rows.count == limit
            ? rows.last.flatMap { row in
                HistoryEventPageCursor(createdAt: Double(row.createdAtMS) / 1000, id: row.id)
            }
            : nil
        return PlayHistoryEventPage(rows: rows, next: next)
    }

    /// Build this device's current history batch for a peer or relay.
    public func exportBatch(
        localDeviceID: String,
        deviceName: String,
        sinceMS: Int64?,
        now: Date = Date(),
        windowDays: Int = HistoryMerge.defaultWindowDays,
        maximumBytes: Int = HistoryExchangeStore.defaultMaximumBatchBytes
    ) async throws -> HistoryExchangeBatch {
        try await backfillAll(localDeviceID: localDeviceID)
        let since = sinceMS.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            ?? now.addingTimeInterval(-Double(windowDays) * 86_400)
        let exported = try await sync.exportableEvents(
            localDeviceID: localDeviceID,
            since: since,
            limit: 50_000
        )
        let windowed = HistoryMerge.window(
            events: exported,
            now: now,
            windowDays: windowDays,
            maximumBytes: maximumBytes
        )
        return HistoryExchangeBatch(HistoryBatch(
            deviceID: localDeviceID,
            deviceName: deviceName,
            writtenAtMS: Int64(now.timeIntervalSince1970 * 1000),
            windowStartMS: windowed.windowStartMS,
            events: windowed.events
        ))
    }

    /// Merge remote batches into the local log.
    @discardableResult
    public func importBatches(
        _ batches: [HistoryExchangeBatch],
        localDeviceID: String
    ) async throws -> Int {
        try await backfillAll(localDeviceID: localDeviceID)
        let historyBatches = batches.map(\.historyBatch)
        let oldestMS = historyBatches
            .flatMap { [$0.windowStartMS] + $0.events.map(\.createdAtMS) }
            .min()
        let since = Date(timeIntervalSince1970: Double(oldestMS ?? 0) / 1000)
        let known = try await sync.knownUIDs(since: since)
        let fresh = HistoryMerge.newEvents(
            from: historyBatches,
            known: known,
            ownDeviceID: localDeviceID
        )
        return try await sync.importEvents(fresh)
    }

    public func yearRollup(
        year: Int,
        localDeviceID: String,
        now: Date = Date()
    ) async throws -> HistoryExchangeRollup {
        try await backfillAll(localDeviceID: localDeviceID)
        return HistoryExchangeRollup(try await HistoryRollupBuilder(database).build(
            year: year,
            deviceID: localDeviceID,
            now: now
        ))
    }

    private func backfillAll(localDeviceID: String) async throws {
        while try await sync.backfillUIDs(localDeviceID: localDeviceID) > 0 {}
    }

    private static func likePrefix(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

public struct HistoryEventPageCursor: Sendable, Hashable {
    let createdAt: Double
    let id: Int64

    init(createdAt: Double, id: Int64) {
        self.createdAt = createdAt
        self.id = id
    }

    public var token: String {
        Data("\(createdAt)\u{1F}\(id)".utf8).base64EncodedString()
    }

    public init?(token: String) {
        guard let data = Data(base64Encoded: token),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.components(separatedBy: "\u{1F}")
        guard parts.count == 2,
              let createdAt = Double(parts[0]),
              let id = Int64(parts[1]) else { return nil }
        self.createdAt = createdAt
        self.id = id
    }
}

public struct PlayHistoryEventPage: Sendable {
    public var rows: [PlayHistoryEventSummary]
    public var next: HistoryEventPageCursor?
}

public struct PlayHistoryEventSummary: Codable, Sendable, Hashable {
    public var id: Int64
    public var eventUID: String?
    public var trackRef: String
    public var kind: String
    public var positionSeconds: Double?
    public var durationSeconds: Double?
    public var context: String?
    public var contextID: String?
    public var deviceID: String?
    public var createdAtMS: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case eventUID = "eventUid"
        case trackRef
        case kind
        case positionSeconds
        case durationSeconds
        case context
        case contextID
        case deviceID
        case createdAtMS
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(eventUID, forKey: .eventUID)
        try container.encode(trackRef, forKey: .trackRef)
        try container.encode(kind, forKey: .kind)
        try container.encode(positionSeconds, forKey: .positionSeconds)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(context, forKey: .context)
        try container.encode(contextID, forKey: .contextID)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(createdAtMS, forKey: .createdAtMS)
    }

    init(_ row: Row) {
        id = row["id"]
        eventUID = row["event_uid"]
        trackRef = row["track_ref"]
        kind = row["kind"]
        positionSeconds = row["position_sec"]
        durationSeconds = row["duration_sec"]
        context = row["context"]
        contextID = row["context_id"]
        deviceID = row["device"]
        createdAtMS = HistorySyncStore.milliseconds(row["created_at"])
    }
}

public struct HistoryExchangeEvent: Codable, Sendable, Hashable {
    public var uid: String
    public var deviceID: String
    public var trackRef: String
    public var kind: String
    public var createdAtMS: Int64
    public var positionMS: Int64?
    public var durationMS: Int64?
    public var context: String?
    public var contextID: String?

    init(_ event: HistoryEvent) {
        uid = event.uid
        deviceID = event.deviceID
        trackRef = event.trackRef
        kind = event.kind
        createdAtMS = event.createdAtMS
        positionMS = event.positionMS
        durationMS = event.durationMS
        context = event.context
        contextID = event.contextID
    }

    public func encode(to encoder: any Encoder) throws {
        enum CodingKeys: String, CodingKey {
            case uid, deviceID, trackRef, kind, createdAtMS, positionMS, durationMS, context, contextID
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uid, forKey: .uid)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(trackRef, forKey: .trackRef)
        try container.encode(kind, forKey: .kind)
        try container.encode(createdAtMS, forKey: .createdAtMS)
        try container.encode(positionMS, forKey: .positionMS)
        try container.encode(durationMS, forKey: .durationMS)
        try container.encode(context, forKey: .context)
        try container.encode(contextID, forKey: .contextID)
    }

    var historyEvent: HistoryEvent {
        HistoryEvent(
            uid: uid,
            deviceID: deviceID,
            trackRef: trackRef,
            kind: kind,
            createdAtMS: createdAtMS,
            positionMS: positionMS,
            durationMS: durationMS,
            context: context,
            contextID: contextID
        )
    }
}

public struct HistoryExchangeBatch: Codable, Sendable, Hashable {
    public var version: Int
    public var deviceID: String
    public var deviceName: String
    public var writtenAtMS: Int64
    public var windowStartMS: Int64
    public var events: [HistoryExchangeEvent]

    init(_ batch: HistoryBatch) {
        version = batch.version
        deviceID = batch.deviceID
        deviceName = batch.deviceName
        writtenAtMS = batch.writtenAtMS
        windowStartMS = batch.windowStartMS
        events = batch.events.map(HistoryExchangeEvent.init)
    }

    var historyBatch: HistoryBatch {
        HistoryBatch(
            version: version,
            deviceID: deviceID,
            deviceName: deviceName,
            writtenAtMS: writtenAtMS,
            windowStartMS: windowStartMS,
            events: events.map(\.historyEvent)
        )
    }
}

public struct HistoryExchangeRollup: Codable, Sendable, Hashable {
    public var version: Int
    public var deviceID: String
    public var year: Int
    public var monthlyMS: [Int64]
    public var monthlyPlays: [Int]
    public var topArtists: [HistoryExchangeRollupEntry]
    public var topAlbums: [HistoryExchangeRollupEntry]
    public var topTracks: [HistoryExchangeRollupEntry]
    public var updatedAtMS: Int64

    init(_ rollup: HistoryRollup) {
        version = rollup.version
        deviceID = rollup.deviceID
        year = rollup.year
        monthlyMS = rollup.monthlyMS
        monthlyPlays = rollup.monthlyPlays
        topArtists = rollup.topArtists.map(HistoryExchangeRollupEntry.init)
        topAlbums = rollup.topAlbums.map(HistoryExchangeRollupEntry.init)
        topTracks = rollup.topTracks.map(HistoryExchangeRollupEntry.init)
        updatedAtMS = rollup.updatedAtMS
    }
}

public struct HistoryExchangeRollupEntry: Codable, Sendable, Hashable {
    public var key: String
    public var name: String
    public var secondaryName: String?
    public var plays: Int
    public var totalMS: Int64

    init(_ entry: RollupEntry) {
        key = entry.key
        name = entry.name
        secondaryName = entry.secondaryName
        plays = entry.plays
        totalMS = entry.totalMS
    }
}
