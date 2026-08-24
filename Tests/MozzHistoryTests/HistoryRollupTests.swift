import Foundation
import Testing
@testable import MozzHistory

// Rollups merge as a state-based CRDT: each device publishes its own complete
// totals, and merging replaces that device's contribution before summing across
// devices. The laws worth proving are the same ones the raw-event union has to
// satisfy — plus the ones totals introduce, since a careless sum double-counts
// where a set union simply wouldn't.

private func entry(_ key: String, name: String? = nil, plays: Int, ms: Int64) -> RollupEntry {
    RollupEntry(key: key, name: name ?? key, plays: plays, totalMS: ms)
}

private func rollup(
    device: String,
    year: Int = 2026,
    januaryMS: Int64 = 0,
    artists: [RollupEntry] = [],
    updatedAtMS: Int64 = 1_000
) -> HistoryRollup {
    var monthly = Array(repeating: Int64(0), count: HistoryRollup.months)
    monthly[0] = januaryMS
    var plays = Array(repeating: 0, count: HistoryRollup.months)
    plays[0] = januaryMS > 0 ? 1 : 0
    return HistoryRollup(
        deviceID: device,
        year: year,
        monthlyMS: monthly,
        monthlyPlays: plays,
        topArtists: artists,
        updatedAtMS: updatedAtMS
    )
}

@Suite("Rollup shape")
struct RollupShapeTests {

    @Test("Monthly arrays are always twelve entries")
    func monthlyArraysArePadded() {
        // A short or overlong array from a malformed payload must not be able to
        // index out of bounds during a merge.
        let short = HistoryRollup(deviceID: "a", year: 2026, monthlyMS: [1, 2], updatedAtMS: 0)
        #expect(short.monthlyMS.count == HistoryRollup.months)

        let long = HistoryRollup(
            deviceID: "a", year: 2026,
            monthlyMS: Array(repeating: 1, count: 40), updatedAtMS: 0
        )
        #expect(long.monthlyMS.count == HistoryRollup.months)
    }

    @Test("Totals are the sum of the months")
    func totals() {
        let r = HistoryRollup(
            deviceID: "a", year: 2026,
            monthlyMS: Array(repeating: 1_000, count: 12),
            monthlyPlays: Array(repeating: 2, count: 12),
            updatedAtMS: 0
        )
        #expect(r.totalMS == 12_000)
        #expect(r.totalPlays == 24)
    }
}

@Suite("Rollup merge")
struct RollupMergeTests {

    @Test("Nothing to merge yields nothing")
    func emptyMerge() {
        #expect(HistoryRollupMerge.merged([]) == nil)
    }

    @Test("Two devices' listening adds up")
    func sumsAcrossDevices() {
        let merged = HistoryRollupMerge.merged([
            rollup(device: "a", januaryMS: 1_000),
            rollup(device: "b", januaryMS: 2_500),
        ])
        #expect(merged?.monthlyMS[0] == 3_500)
    }

    @Test("Merging is idempotent — a device is not counted twice")
    func idempotent() {
        // The trap totals have and sets don't: merging the same input twice must
        // not double the year.
        let a = rollup(device: "a", januaryMS: 1_000)
        let once = HistoryRollupMerge.merged([a])
        let twice = HistoryRollupMerge.merged([a, a])
        #expect(once?.monthlyMS[0] == twice?.monthlyMS[0])
    }

    @Test("Merging is commutative")
    func commutative() {
        let a = rollup(device: "a", januaryMS: 1_000, artists: [entry("art-1", plays: 2, ms: 1_000)])
        let b = rollup(device: "b", januaryMS: 2_000, artists: [entry("art-2", plays: 1, ms: 2_000)])

        let forward = HistoryRollupMerge.merged([a, b])
        let reverse = HistoryRollupMerge.merged([b, a])

        #expect(forward?.monthlyMS == reverse?.monthlyMS)
        #expect(forward?.topArtists.map(\.key) == reverse?.topArtists.map(\.key))
    }

    @Test("A device's newer rollup supersedes its older one")
    func newerSupersedesOlder() {
        // Two rollups from one device for one year are successive snapshots, not
        // two contributions — adding them would double that device's year.
        let stale = rollup(device: "a", januaryMS: 1_000, updatedAtMS: 100)
        let fresh = rollup(device: "a", januaryMS: 5_000, updatedAtMS: 200)

        #expect(HistoryRollupMerge.merged([stale, fresh])?.monthlyMS[0] == 5_000)
        #expect(HistoryRollupMerge.merged([fresh, stale])?.monthlyMS[0] == 5_000)
    }

    @Test("The same artist heard on two devices is one entry")
    func combinesEntriesByKey() {
        let merged = HistoryRollupMerge.merged([
            rollup(device: "a", artists: [entry("art-1", plays: 3, ms: 3_000)]),
            rollup(device: "b", artists: [entry("art-1", plays: 2, ms: 2_000)]),
        ])
        let artists = try? #require(merged?.topArtists)
        #expect(artists?.count == 1)
        #expect(artists?.first?.plays == 5)
        #expect(artists?.first?.totalMS == 5_000)
    }

    @Test("A name recorded on one device fills a blank from another")
    func recoversMissingNames() {
        // One device's catalog may have lost the item; the other's hasn't.
        let merged = HistoryRollupMerge.merged([
            rollup(device: "a", artists: [RollupEntry(key: "art-1", name: "", plays: 1, totalMS: 10)]),
            rollup(device: "b", artists: [RollupEntry(key: "art-1", name: "Lena Vance", plays: 1, totalMS: 10)]),
        ])
        #expect(merged?.topArtists.first?.name == "Lena Vance")
    }

    @Test("Ranking is by time listened, not play count")
    func ranksByTime() {
        // 40 plays of a 90-second interlude is not a bigger year than 20 plays
        // of an hour-long mix.
        let merged = HistoryRollupMerge.merged([
            rollup(device: "a", artists: [
                entry("interlude", plays: 40, ms: 40 * 90_000),
                entry("longmix", plays: 20, ms: 20 * 3_600_000),
            ]),
        ])
        #expect(merged?.topArtists.first?.key == "longmix")
    }

    @Test("Ties break deterministically so two devices show the same order")
    func deterministicTies() {
        let merged = HistoryRollupMerge.merged([
            rollup(device: "a", artists: [
                entry("zulu", plays: 1, ms: 1_000),
                entry("alpha", plays: 1, ms: 1_000),
            ]),
        ])
        #expect(merged?.topArtists.map(\.key) == ["alpha", "zulu"])
    }

    @Test("Merged lists are capped at the top-N cutoff")
    func capsMergedLists() {
        let many = (0..<(HistoryRollup.topCount + 50)).map {
            entry("art-\($0)", plays: 1, ms: Int64($0))
        }
        let merged = HistoryRollupMerge.merged([rollup(device: "a", artists: many)])
        #expect(merged?.topArtists.count == HistoryRollup.topCount)
    }

    @Test("A rollup from a newer client is skipped, not guessed at")
    func skipsFutureVersions() {
        var future = rollup(device: "b", januaryMS: 9_999)
        future.version = HistoryRollup.currentVersion + 1

        let merged = HistoryRollupMerge.merged([rollup(device: "a", januaryMS: 1_000), future])
        #expect(merged?.monthlyMS[0] == 1_000)
    }

    @Test("Entries with no key are ignored")
    func ignoresKeylessEntries() {
        let merged = HistoryRollupMerge.merged([
            rollup(device: "a", artists: [RollupEntry(key: "", name: "?", plays: 1, totalMS: 1)]),
        ])
        #expect(merged?.topArtists.isEmpty == true)
    }
}
