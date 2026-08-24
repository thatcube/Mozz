import XCTest
import MozzCore
import MozzHistory
import GRDB
@testable import MozzDatabase

/// Tests for the year-in-review rollup builder.
///
/// The arithmetic here is what a "you listened to 42,000 minutes" figure is made
/// of, so the counting rules matter more than they look: an off-by-one in which
/// events count would inflate every user's year by roughly double and nobody
/// would be able to tell.
final class HistoryRollupBuilderTests: XCTestCase {

    // MARK: Fixtures

    private func seedTrack(
        _ db: MusicDatabase,
        remoteID: String,
        title: String,
        artist: String,
        artistID: String?,
        albumTitle: String,
        albumGroupKey: String,
        durationSec: Double
    ) async throws {
        try await db.write { database in
            // The album row carries the group key that consolidates a
            // server-fragmented album; the track points at it by remote id.
            let albumRemoteID = "alb-\(albumGroupKey)"
            try database.execute(sql: """
                INSERT OR IGNORE INTO album
                    (serverId, remoteId, title, artistName, albumGroupKey)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: ["srv1", albumRemoteID, albumTitle, artist, albumGroupKey])
            try database.execute(sql: """
                INSERT INTO track
                    (serverId, remoteId, title, artistName, artistRemoteId,
                     albumTitle, albumRemoteId, duration)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "srv1", remoteID, title, artist, artistID,
                    albumTitle, albumRemoteID, durationSec,
                ])
        }
    }

    private func seedEvent(
        _ db: MusicDatabase,
        remoteID: String,
        kind: String,
        at: Date,
        positionSec: Double? = nil,
        durationSec: Double? = nil
    ) async throws {
        try await db.write { database in
            try database.execute(sql: """
                INSERT INTO play_event
                    (track_ref, kind, position_sec, duration_sec, created_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [
                    "srv1:\(remoteID)", kind, positionSec, durationSec,
                    at.timeIntervalSince1970,
                ])
        }
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: iso)!
    }

    private func makeSeededDatabase() async throws -> MusicDatabase {
        let db = try MusicDatabase.inMemory()
        try await db.write { database in
            try database.execute(sql: """
                INSERT INTO server (id, kind, name, baseURL, userId, clientIdentifier)
                VALUES ('srv1', 'jellyfin', 'Test', 'https://x', 'u1', 'c1')
                """)
        }
        return db
    }

    // MARK: Counting rules

    func testCompletedPlayCountsTheWholeTrack() async throws {
        let db = try await makeSeededDatabase()
        try await seedTrack(db, remoteID: "t1", title: "Opening", artist: "Lena Vance",
                            artistID: "art-1", albumTitle: "Signal", albumGroupKey: "grp-1",
                            durationSec: 200)
        try await seedEvent(db, remoteID: "t1", kind: "completed",
                            at: date("2026-01-15T12:00:00Z"), durationSec: 200)

        let rollup = try await HistoryRollupBuilder(db).build(year: 2026, deviceID: "dev-a")
        XCTAssertEqual(rollup.monthlyMS[0], 200_000)
        XCTAssertEqual(rollup.monthlyPlays[0], 1)
    }

    func testSkipCountsOnlyHowFarItGot() async throws {
        let db = try await makeSeededDatabase()
        try await seedTrack(db, remoteID: "t1", title: "Opening", artist: "Lena Vance",
                            artistID: "art-1", albumTitle: "Signal", albumGroupKey: "grp-1",
                            durationSec: 200)
        try await seedEvent(db, remoteID: "t1", kind: "skipped",
                            at: date("2026-01-15T12:00:00Z"),
                            positionSec: 12, durationSec: 200)

        let rollup = try await HistoryRollupBuilder(db).build(year: 2026, deviceID: "dev-a")
        XCTAssertEqual(rollup.monthlyMS[0], 12_000)
    }

    func testStartedIsNotCountedSoFinishedPlaysAreNotDoubled() async throws {
        // `started` fires at the top of every play. Counting it alongside
        // `completed` would roughly double every user's year.
        let db = try await makeSeededDatabase()
        try await seedTrack(db, remoteID: "t1", title: "Opening", artist: "Lena Vance",
                            artistID: "art-1", albumTitle: "Signal", albumGroupKey: "grp-1",
                            durationSec: 200)
        try await seedEvent(db, remoteID: "t1", kind: "started",
                            at: date("2026-01-15T12:00:00Z"), durationSec: 200)
        try await seedEvent(db, remoteID: "t1", kind: "completed",
                            at: date("2026-01-15T12:03:20Z"), durationSec: 200)

        let rollup = try await HistoryRollupBuilder(db).build(year: 2026, deviceID: "dev-a")
        XCTAssertEqual(rollup.monthlyMS[0], 200_000)
        XCTAssertEqual(rollup.monthlyPlays[0], 1)
    }

    func testLikesAreOpinionsNotListening() async throws {
        let db = try await makeSeededDatabase()
        try await seedTrack(db, remoteID: "t1", title: "Opening", artist: "Lena Vance",
                            artistID: "art-1", albumTitle: "Signal", albumGroupKey: "grp-1",
                            durationSec: 200)
        try await seedEvent(db, remoteID: "t1", kind: "liked", at: date("2026-01-15T12:00:00Z"))

        let rollup = try await HistoryRollupBuilder(db).build(year: 2026, deviceID: "dev-a")
        XCTAssertEqual(rollup.totalPlays, 0)
    }

    func testAWildPositionCannotInflateTheYear() async throws {
        // One malformed row claiming a thousand hours would swamp every honest
        // one, so a listen is clamped to the track's duration.
        let db = try await makeSeededDatabase()
        try await seedTrack(db, remoteID: "t1", title: "Opening", artist: "Lena Vance",
                            artistID: "art-1", albumTitle: "Signal", albumGroupKey: "grp-1",
                            durationSec: 200)
        try await seedEvent(db, remoteID: "t1", kind: "skipped",
                            at: date("2026-01-15T12:00:00Z"),
                            positionSec: 3_600_000, durationSec: 200)

        let rollup = try await HistoryRollupBuilder(db).build(year: 2026, deviceID: "dev-a")
        XCTAssertEqual(rollup.monthlyMS[0], 200_000)
    }

    // MARK: Buckets and charts

    func testEventsLandInTheRightMonth() async throws {
        let db = try await makeSeededDatabase()
        try await seedTrack(db, remoteID: "t1", title: "Opening", artist: "Lena Vance",
                            artistID: "art-1", albumTitle: "Signal", albumGroupKey: "grp-1",
                            durationSec: 100)
        try await seedEvent(db, remoteID: "t1", kind: "completed",
                            at: date("2026-01-05T00:00:00Z"), durationSec: 100)
        try await seedEvent(db, remoteID: "t1", kind: "completed",
                            at: date("2026-07-05T00:00:00Z"), durationSec: 100)
        try await seedEvent(db, remoteID: "t1", kind: "completed",
                            at: date("2026-12-31T23:00:00Z"), durationSec: 100)

        let rollup = try await HistoryRollupBuilder(db).build(year: 2026, deviceID: "dev-a")
        XCTAssertEqual(rollup.monthlyPlays[0], 1)
        XCTAssertEqual(rollup.monthlyPlays[6], 1)
        XCTAssertEqual(rollup.monthlyPlays[11], 1)
        XCTAssertEqual(rollup.totalPlays, 3)
    }

    func testAnotherYearsListeningIsExcluded() async throws {
        let db = try await makeSeededDatabase()
        try await seedTrack(db, remoteID: "t1", title: "Opening", artist: "Lena Vance",
                            artistID: "art-1", albumTitle: "Signal", albumGroupKey: "grp-1",
                            durationSec: 100)
        try await seedEvent(db, remoteID: "t1", kind: "completed",
                            at: date("2025-12-31T23:59:00Z"), durationSec: 100)
        try await seedEvent(db, remoteID: "t1", kind: "completed",
                            at: date("2027-01-01T00:01:00Z"), durationSec: 100)

        let rollup = try await HistoryRollupBuilder(db).build(year: 2026, deviceID: "dev-a")
        XCTAssertEqual(rollup.totalPlays, 0)
    }

    func testTopChartsCarryNamesForLaterDisplay() async throws {
        let db = try await makeSeededDatabase()
        try await seedTrack(db, remoteID: "t1", title: "Golden Machine", artist: "Lena Vance",
                            artistID: "art-1", albumTitle: "Signal", albumGroupKey: "grp-1",
                            durationSec: 300)
        try await seedEvent(db, remoteID: "t1", kind: "completed",
                            at: date("2026-03-01T00:00:00Z"), durationSec: 300)

        let rollup = try await HistoryRollupBuilder(db).build(year: 2026, deviceID: "dev-a")

        // Names are captured now so a later catalog prune cannot turn the review
        // into a chart of blanks.
        XCTAssertEqual(rollup.topArtists.first?.name, "Lena Vance")
        XCTAssertEqual(rollup.topAlbums.first?.name, "Signal")
        XCTAssertEqual(rollup.topTracks.first?.name, "Golden Machine")
        XCTAssertEqual(rollup.topTracks.first?.secondaryName, "Lena Vance")
    }

    func testChartsRankByTimeListened() async throws {
        let db = try await makeSeededDatabase()
        try await seedTrack(db, remoteID: "short", title: "Interlude", artist: "Brief",
                            artistID: "art-short", albumTitle: "A", albumGroupKey: "grp-a",
                            durationSec: 90)
        try await seedTrack(db, remoteID: "long", title: "The Mix", artist: "Lengthy",
                            artistID: "art-long", albumTitle: "B", albumGroupKey: "grp-b",
                            durationSec: 3_600)

        for day in 1...10 {
            try await seedEvent(db, remoteID: "short", kind: "completed",
                                at: date(String(format: "2026-02-%02dT00:00:00Z", day)),
                                durationSec: 90)
        }
        try await seedEvent(db, remoteID: "long", kind: "completed",
                            at: date("2026-02-15T00:00:00Z"), durationSec: 3_600)

        let rollup = try await HistoryRollupBuilder(db).build(year: 2026, deviceID: "dev-a")
        // Ten plays of 90s (900s) lose to one play of an hour.
        XCTAssertEqual(rollup.topArtists.first?.key, "art-long")
    }

    func testAPlayWhoseTrackHasLeftTheCatalogStillCounts() async throws {
        // The event survives a prune because it is keyed on the durable
        // trackRef; it should still contribute time even with no name to show.
        let db = try await makeSeededDatabase()
        try await seedEvent(db, remoteID: "gone", kind: "completed",
                            at: date("2026-04-01T00:00:00Z"), durationSec: 240)

        let rollup = try await HistoryRollupBuilder(db).build(year: 2026, deviceID: "dev-a")
        XCTAssertEqual(rollup.monthlyMS[3], 240_000)
        XCTAssertEqual(rollup.topTracks.first?.key, "srv1:gone")
    }

    func testAnEmptyYearIsEmptyNotAnError() async throws {
        let db = try await makeSeededDatabase()
        let rollup = try await HistoryRollupBuilder(db).build(year: 2026, deviceID: "dev-a")
        XCTAssertEqual(rollup.totalPlays, 0)
        XCTAssertEqual(rollup.monthlyMS.count, 12)
        XCTAssertTrue(rollup.topArtists.isEmpty)
    }
}
