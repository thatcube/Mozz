import Foundation
import GRDB
import MozzCore
import MozzHistory

/// Builds a year's ``HistoryRollup`` from this device's local play log.
///
/// Kept out of `MozzHistory` for the same reason as `HistorySyncStore`: that
/// module has to build on platforms without GRDB, so anything touching SQL lives
/// here.
///
/// Rollups are computed **locally and published per device**. The local
/// `play_event` table is never pruned, so a device can always rebuild its own
/// full year even though the raw events it *syncs* only reach back 180 days.
/// That asymmetry is the point: the rollup is what carries a full year across
/// devices, at a few kilobytes instead of megabytes.
public struct HistoryRollupBuilder: Sendable {
    private let database: MusicDatabase

    public init(_ database: MusicDatabase) {
        self.database = database
    }

    /// What counts as listening, and how much.
    ///
    /// A `completed` play counts the track's full duration. A `skipped` one
    /// counts only how far it actually got, which is why `position_sec` is
    /// recorded at all. `started` is excluded outright: it fires at the top of
    /// every play, so counting it as well as `completed` would double every
    /// finished listen, and counting it *instead* would credit a full duration
    /// to a track abandoned after four seconds.
    ///
    /// `liked`/`unliked` are opinions rather than listening, and carry no time.
    static let listeningKinds = ["completed", "skipped"]

    /// Build this device's rollup for a calendar year.
    ///
    /// Names come from the catalog *as it stands now*, which is the best a
    /// rebuild can do — and precisely why the result is published rather than
    /// recomputed elsewhere later: once written, a rollup preserves names the
    /// catalog may go on to lose.
    public func build(
        year: Int,
        deviceID: String,
        calendar: Calendar = HistoryRollupBuilder.utcCalendar,
        now: Date = Date()
    ) async throws -> HistoryRollup {
        guard let bounds = Self.yearBounds(year, calendar: calendar) else {
            return HistoryRollup(
                deviceID: deviceID,
                year: year,
                updatedAtMS: Int64(now.timeIntervalSince1970 * 1000)
            )
        }

        // Mapped inside the read: GRDB's `Row` is not Sendable, so it must not
        // escape the database's concurrency domain.
        let rows = try await database.read { db -> [PlayRow] in
            try Row.fetchAll(db, sql: """
                SELECT
                    pe.kind          AS kind,
                    pe.created_at    AS createdAt,
                    pe.position_sec  AS positionSec,
                    pe.duration_sec  AS durationSec,
                    pe.track_ref     AS trackRef,
                    t.title          AS title,
                    t.artistName     AS artistName,
                    t.artistRemoteId AS artistRemoteId,
                    t.albumTitle     AS albumTitle,
                    al.albumGroupKey AS albumGroupKey,
                    t.duration       AS catalogDuration
                FROM play_event pe
                LEFT JOIN track t
                    ON t.serverId || ':' || t.remoteId = pe.track_ref
                -- albumGroupKey lives on `album`: servers (Jellyfin especially)
                -- split one album into several entities, and the group key is
                -- what consolidates them. Without this join a fragmented album
                -- would appear several times in a year's chart, each with a
                -- slice of its real listening time.
                LEFT JOIN album al
                    ON al.serverId = t.serverId AND al.remoteId = t.albumRemoteId
                WHERE pe.created_at >= ? AND pe.created_at < ?
                  AND pe.kind IN (?, ?)
                """, arguments: [
                    bounds.start, bounds.end,
                    Self.listeningKinds[0], Self.listeningKinds[1],
                ])
                .map(PlayRow.init)
        }

        var monthlyMS = Array(repeating: Int64(0), count: HistoryRollup.months)
        var monthlyPlays = Array(repeating: 0, count: HistoryRollup.months)
        var artists: [String: RollupEntry] = [:]
        var albums: [String: RollupEntry] = [:]
        var tracks: [String: RollupEntry] = [:]

        for row in rows {
            let date = Date(timeIntervalSince1970: row.createdAt)
            let month = calendar.component(.month, from: date) - 1
            guard month >= 0, month < HistoryRollup.months else { continue }

            let listenedMS = Self.listenedMilliseconds(
                kind: row.kind,
                positionSec: row.positionSec,
                eventDurationSec: row.durationSec,
                catalogDurationSec: row.catalogDuration
            )

            monthlyMS[month] += listenedMS
            monthlyPlays[month] += 1

            let trackRef = row.trackRef
            let title = row.title
            let artistName = row.artistName
            let albumTitle = row.albumTitle

            // An artist id is not always present (some servers omit it), so fall
            // back to the name. Grouping by name is imperfect across servers but
            // far better than dropping the play from the chart entirely.
            let artistKey = row.artistRemoteId.flatMap { $0.isEmpty ? nil : $0 } ?? artistName
            let albumKey = row.albumGroupKey.flatMap { $0.isEmpty ? nil : $0 } ?? albumTitle

            if !artistKey.isEmpty {
                Self.add(
                    to: &artists, key: artistKey, name: artistName,
                    secondary: nil, ms: listenedMS
                )
            }
            if !albumKey.isEmpty {
                Self.add(
                    to: &albums, key: albumKey, name: albumTitle,
                    secondary: artistName, ms: listenedMS
                )
            }
            Self.add(
                to: &tracks, key: trackRef, name: title,
                secondary: artistName, ms: listenedMS
            )
        }

        return HistoryRollup(
            deviceID: deviceID,
            year: year,
            monthlyMS: monthlyMS,
            monthlyPlays: monthlyPlays,
            topArtists: Self.rank(artists),
            topAlbums: Self.rank(albums),
            topTracks: Self.rank(tracks),
            updatedAtMS: Int64(now.timeIntervalSince1970 * 1000)
        )
    }

    /// One joined play event, in a form safe to carry out of the read.
    struct PlayRow: Sendable {
        var kind: String
        var createdAt: Double
        var positionSec: Double?
        var durationSec: Double?
        var trackRef: String
        var title: String
        var artistName: String
        var artistRemoteId: String?
        var albumTitle: String
        var albumGroupKey: String?
        var catalogDuration: Double?

        init(_ row: Row) {
            kind = row["kind"]
            createdAt = row["createdAt"]
            positionSec = row["positionSec"]
            durationSec = row["durationSec"]
            trackRef = row["trackRef"]
            title = row["title"] ?? ""
            artistName = row["artistName"] ?? ""
            artistRemoteId = row["artistRemoteId"]
            albumTitle = row["albumTitle"] ?? ""
            albumGroupKey = row["albumGroupKey"]
            catalogDuration = row["catalogDuration"]
        }
    }

    // MARK: Helpers

    /// Rollup buckets are UTC so a device that moves timezone does not shuffle
    /// listening between months, and two devices in different places agree on
    /// which month a play belongs to.
    public static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    static func yearBounds(_ year: Int, calendar: Calendar) -> (start: Double, end: Double)? {
        var components = DateComponents()
        components.year = year
        components.month = 1
        components.day = 1
        guard let start = calendar.date(from: components),
              let end = calendar.date(byAdding: .year, value: 1, to: start)
        else { return nil }
        return (start.timeIntervalSince1970, end.timeIntervalSince1970)
    }

    /// How long a single event actually represents.
    ///
    /// Clamped to the track's duration, because a stale or malformed position
    /// must not be able to inflate a year's total — one bad row claiming a
    /// thousand hours would swamp every honest one.
    static func listenedMilliseconds(
        kind: String,
        positionSec: Double?,
        eventDurationSec: Double?,
        catalogDurationSec: Double?
    ) -> Int64 {
        let duration = eventDurationSec ?? catalogDurationSec ?? 0
        let raw: Double
        switch kind {
        case "completed":
            raw = duration
        case "skipped":
            raw = min(positionSec ?? 0, duration > 0 ? duration : (positionSec ?? 0))
        default:
            raw = 0
        }
        guard raw.isFinite, raw > 0 else { return 0 }
        let capped = duration > 0 ? min(raw, duration) : raw
        return Int64((capped * 1000).rounded())
    }

    private static func add(
        to table: inout [String: RollupEntry],
        key: String,
        name: String,
        secondary: String?,
        ms: Int64
    ) {
        if var existing = table[key] {
            existing.plays += 1
            existing.totalMS += ms
            if existing.name.isEmpty { existing.name = name }
            table[key] = existing
        } else {
            table[key] = RollupEntry(
                key: key, name: name, secondaryName: secondary, plays: 1, totalMS: ms
            )
        }
    }

    /// Same ordering as `HistoryRollupMerge`, so a single-device year and a
    /// merged one rank identically.
    private static func rank(_ table: [String: RollupEntry]) -> [RollupEntry] {
        table.values
            .sorted {
                if $0.totalMS != $1.totalMS { return $0.totalMS > $1.totalMS }
                if $0.plays != $1.plays { return $0.plays > $1.plays }
                return $0.key < $1.key
            }
            .prefix(HistoryRollup.topCount)
            .map { $0 }
    }
}
