import Foundation

// MARK: - Yearly rollups
//
// The raw event log answers "what has this listener been into lately". A year in
// review asks something different, and the difference matters architecturally:
//
//   * **Span.** Taste decays with a 30-day half-life, so `HistoryMerge` syncs a
//     180-day window and drops the oldest events when space runs short. That is
//     right for recommendations and *fatal* for a year in review — trimming
//     January means January never appears in December's summary.
//   * **Size.** A year of raw events for a heavy listener is tens of thousands
//     of records, megabytes per device, in a record every device re-uploads on
//     every write. A year of *totals* is a few kilobytes.
//   * **Durability of names.** Play events are keyed on `trackRef` and outlive
//     the catalog by design. So when a server drops an album, the events remain
//     but nothing can name them any more — a review built purely from raw events
//     would show a chart of blanks. Rollups capture the names at play time.
//
// Hence two artifacts with different retention, sharing one merge shape.
//
// WHY THE MERGE STILL NEEDS NO COORDINATION
//
// Raw events merge as a G-Set: immutable facts, union by identity. Totals cannot
// work that way — adding two devices' counts twice would double them. But the
// same per-device-slot arrangement solves it: each device publishes *its own*
// complete totals, and merging **replaces** each device's contribution before
// summing across devices. That is a state-based CRDT, so it stays idempotent,
// commutative and associative, and still needs no compare-and-swap.
//
// The one honest caveat is top-N truncation, described on ``merged(_:)``.

/// One ranked thing — an artist, an album or a track — with the totals behind it.
public struct RollupEntry: Codable, Sendable, Hashable, Identifiable {
    /// Stable identity to merge on: an artist's remote id, an album's group key,
    /// or a track's `trackRef`.
    public var key: String
    /// Captured when the play happened, not looked up later, so a review can
    /// still name something the server has since removed.
    public var name: String
    /// Artist for an album or track; `nil` for an artist entry.
    public var secondaryName: String?
    public var plays: Int
    public var totalMS: Int64

    public var id: String { key }

    public init(
        key: String,
        name: String,
        secondaryName: String? = nil,
        plays: Int,
        totalMS: Int64
    ) {
        self.key = key
        self.name = name
        self.secondaryName = secondaryName
        self.plays = plays
        self.totalMS = totalMS
    }
}

/// One device's totals for one calendar year.
///
/// Published per device alongside that device's raw-event batch, and kept for
/// as long as the year is interesting rather than for as long as taste needs —
/// which is the whole reason it exists separately.
public struct HistoryRollup: Codable, Sendable, Hashable {
    public var version: Int
    public var deviceID: String
    /// Calendar year, e.g. 2026. Years are separate records so an old one can be
    /// frozen and never rewritten once it ends.
    public var year: Int
    /// Listening time per month, January at index 0. Always 12 entries.
    public var monthlyMS: [Int64]
    /// Play count per month, January at index 0. Always 12 entries.
    public var monthlyPlays: [Int]
    public var topArtists: [RollupEntry]
    public var topAlbums: [RollupEntry]
    public var topTracks: [RollupEntry]
    public var updatedAtMS: Int64

    public static let currentVersion = 1
    public static let months = 12

    /// How many entries each list keeps.
    ///
    /// Generous on purpose — see the truncation caveat on ``merged(_:)``. At
    /// roughly 80 bytes an entry, three lists of 200 cost about 48 KB, which is
    /// affordable next to a 256 KB event budget and is dwarfed by what a year of
    /// raw events would cost.
    public static let topCount = 200

    public init(
        version: Int = HistoryRollup.currentVersion,
        deviceID: String,
        year: Int,
        monthlyMS: [Int64] = Array(repeating: 0, count: HistoryRollup.months),
        monthlyPlays: [Int] = Array(repeating: 0, count: HistoryRollup.months),
        topArtists: [RollupEntry] = [],
        topAlbums: [RollupEntry] = [],
        topTracks: [RollupEntry] = [],
        updatedAtMS: Int64
    ) {
        self.version = version
        self.deviceID = deviceID
        self.year = year
        self.monthlyMS = HistoryRollup.padded(monthlyMS, to: 0)
        self.monthlyPlays = HistoryRollup.padded(monthlyPlays, to: 0)
        self.topArtists = topArtists
        self.topAlbums = topAlbums
        self.topTracks = topTracks
        self.updatedAtMS = updatedAtMS
    }

    /// Force a monthly array to exactly 12 entries.
    ///
    /// A malformed or future-shaped payload must not crash a review or, worse,
    /// index out of bounds while merging.
    static func padded<T>(_ values: [T], to filler: T) -> [T] {
        if values.count == months { return values }
        if values.count > months { return Array(values.prefix(months)) }
        return values + Array(repeating: filler, count: months - values.count)
    }

    public var totalMS: Int64 { monthlyMS.reduce(0, +) }
    public var totalPlays: Int { monthlyPlays.reduce(0, +) }
}

// MARK: - Merging

public enum HistoryRollupMerge {

    /// Combine every device's rollup for one year into a single view.
    ///
    /// Each device's slot holds that device's own complete totals, so merging is
    /// a plain sum across devices — no deltas, nothing to double-count, and
    /// re-merging the same set yields the same answer.
    ///
    /// **The truncation caveat, stated plainly.** Each device publishes only its
    /// top ``HistoryRollup/topCount`` entries, so an artist ranked just below the
    /// cutoff on *every* device is missing from the merge even if their combined
    /// total would have placed them well inside it. This is inherent to merging
    /// truncated top-K lists and cannot be fixed by ranking differently — only by
    /// shipping every key, which is exactly the cost the rollup exists to avoid.
    /// With a 200-entry cutoff it takes a very evenly spread listener across many
    /// devices for the effect to reach the top of a chart.
    ///
    /// Rollups from a newer encoding are skipped rather than guessed at, matching
    /// how `HistoryMerge` treats future batches.
    public static func merged(_ rollups: [HistoryRollup]) -> HistoryRollup? {
        let usable = rollups.filter { $0.version <= HistoryRollup.currentVersion }
        guard let first = usable.first else { return nil }

        // One rollup per device. If a device somehow published two for the same
        // year, the newer one wins — it supersedes rather than adds to the older.
        var latest: [String: HistoryRollup] = [:]
        for rollup in usable {
            if let existing = latest[rollup.deviceID], existing.updatedAtMS >= rollup.updatedAtMS {
                continue
            }
            latest[rollup.deviceID] = rollup
        }

        var monthlyMS = Array(repeating: Int64(0), count: HistoryRollup.months)
        var monthlyPlays = Array(repeating: 0, count: HistoryRollup.months)
        var artists: [String: RollupEntry] = [:]
        var albums: [String: RollupEntry] = [:]
        var tracks: [String: RollupEntry] = [:]

        for rollup in latest.values {
            let ms = HistoryRollup.padded(rollup.monthlyMS, to: 0)
            let plays = HistoryRollup.padded(rollup.monthlyPlays, to: 0)
            for month in 0..<HistoryRollup.months {
                monthlyMS[month] += ms[month]
                monthlyPlays[month] += plays[month]
            }
            accumulate(rollup.topArtists, into: &artists)
            accumulate(rollup.topAlbums, into: &albums)
            accumulate(rollup.topTracks, into: &tracks)
        }

        return HistoryRollup(
            deviceID: "",  // merged view belongs to no single device
            year: first.year,
            monthlyMS: monthlyMS,
            monthlyPlays: monthlyPlays,
            topArtists: rank(artists),
            topAlbums: rank(albums),
            topTracks: rank(tracks),
            updatedAtMS: latest.values.map(\.updatedAtMS).max() ?? first.updatedAtMS
        )
    }

    private static func accumulate(_ entries: [RollupEntry], into table: inout [String: RollupEntry]) {
        for entry in entries where !entry.key.isEmpty {
            if var existing = table[entry.key] {
                existing.plays += entry.plays
                existing.totalMS += entry.totalMS
                // Keep whichever name is present; a device whose catalog still
                // had the item wins over one that recorded a blank.
                if existing.name.isEmpty { existing.name = entry.name }
                if existing.secondaryName?.isEmpty ?? true {
                    existing.secondaryName = entry.secondaryName
                }
                table[entry.key] = existing
            } else {
                table[entry.key] = entry
            }
        }
    }

    /// Rank by listening time, then plays, then key.
    ///
    /// Time first because it is the honest measure of what someone actually
    /// listened to — 40 plays of a 90-second interlude is not a bigger year than
    /// 20 plays of an hour-long mix. The final key comparison keeps the order
    /// deterministic, so two devices showing the same year show it identically
    /// rather than shuffling ties.
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
