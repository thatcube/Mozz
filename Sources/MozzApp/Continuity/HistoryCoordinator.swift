import Foundation
import MozzCore
import MozzDatabase
import MozzHistory

/// Schedules listening-history work: keep the local log merge-ready, refresh the
/// current year's rollup, and — where a relay is available — publish this
/// device's window and take in what other devices published.
///
/// **Backend-agnostic by design (ADR-0011).** No music server offers a universal
/// place to keep this: Jellyfin has a real per-user KV store, Subsonic has only a
/// play queue, and Plex has nothing client-writable at all. So the *mechanism* is
/// device-to-device over the authenticated pairing channel, and per-server
/// storage is only ever an optional store-and-forward relay on top.
///
/// Which means the local half of this runs for **every** backend, always: events
/// are given their cross-device identity, and the year's rollup is built. A Plex
/// user has a complete year in review from day one; what they wait on is another
/// device's contribution, not the feature.
///
/// Deliberately *not* on the playback hot path. `ContinuityCoordinator` writes a
/// cursor every 15-30 seconds because a resume point goes stale in seconds;
/// history does not. A play recorded an hour late still lands in the same taste
/// profile and the same month of the same year.
@MainActor
public final class HistoryCoordinator: ObservableObject {

    /// This device's totals for the current year, refreshed on each sync.
    /// Present on every backend — see ``sync(now:)``.
    @Published public private(set) var currentYear: HistoryRollup?

    /// The soonest two syncs may occur.
    ///
    /// Every sync is a read plus a whole-record POST, and the payload carries
    /// every device's slot. Syncing on each foreground would be wasteful for a
    /// user who checks the app repeatedly; half an hour loses nothing, because
    /// the local log is the durable copy and unsent events simply go in the next
    /// batch.
    static let minimumInterval: TimeInterval = 30 * 60

    private var store: (any HistoryStore)?
    private var database: MusicDatabase?
    private var deviceID = ""
    private var deviceName = ""

    private var lastSyncedAt: Date?
    private var isSyncing = false
    /// Set once the pre-`event_uid` rows have all been given one. Until then a
    /// device cannot publish, because rows without a uid have no identity to
    /// merge on.
    private var hasBackfilled = false

    public init() {}

    // MARK: Lifecycle

    /// Point the coordinator at a signed-in server, or clear it on sign-out.
    public func activate(
        store: (any HistoryStore)?,
        database: MusicDatabase?,
        deviceID: String,
        deviceName: String
    ) {
        self.store = store
        self.database = database
        self.deviceID = deviceID
        self.deviceName = deviceName
        lastSyncedAt = nil
        hasBackfilled = false
    }

    /// Sync if enough time has passed. Safe to call often.
    public func syncIfDue(now: Date = Date()) async {
        guard let lastSyncedAt else {
            await sync(now: now)
            return
        }
        guard now.timeIntervalSince(lastSyncedAt) >= Self.minimumInterval else { return }
        await sync(now: now)
    }

    /// Run a sync regardless of the interval.
    ///
    /// The local steps — giving events their identity, rebuilding the year —
    /// run for every backend. Only publishing and collecting need a relay, so a
    /// Plex or Subsonic user is not short a feature here; they are short a
    /// *second device's contribution*, which the peer channel supplies (ADR-0011).
    ///
    /// Failures are swallowed on purpose: this is a background convenience, and
    /// the local log — the durable copy — is untouched by a failed round trip.
    /// Anything missed rides along in the next batch.
    public func sync(now: Date = Date()) async {
        guard let database, !deviceID.isEmpty, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let sync = HistorySyncStore(database)

        // Rows written before event_uid existed have no identity to merge on, so
        // they cannot be published — or reconciled against an incoming batch —
        // until they have one. Bounded per pass so a very long history does not
        // stall the first sync.
        if !hasBackfilled {
            var remaining = 4
            while remaining > 0 {
                let filled = (try? await sync.backfillUIDs(localDeviceID: deviceID)) ?? 0
                if filled == 0 { break }
                remaining -= 1
            }
            hasBackfilled = true
        }

        if let store {
            let since = now.addingTimeInterval(-Double(HistoryMerge.defaultWindowDays) * 86_400)
            // Take in first, then publish. A device that has been away should not
            // overwrite its slot before it has seen what happened while it was
            // gone — and importing first means this batch is written from a log
            // that already reflects the others.
            await importRemote(sync: sync, store: store, since: since)
            await publishLocal(sync: sync, store: store, since: since, now: now)
        }

        // Always. The year in review is built from local events, so it works on
        // every backend whether or not anything can be relayed.
        await refreshRollup(store: store, now: now)

        lastSyncedAt = now
    }

    // MARK: Steps

    private func importRemote(
        sync: HistorySyncStore,
        store: any HistoryStore,
        since: Date
    ) async {
        guard let batches = try? await store.loadBatches(), !batches.isEmpty else { return }
        guard let known = try? await sync.knownUIDs(since: since) else { return }

        let fresh = HistoryMerge.newEvents(
            from: batches,
            known: known,
            ownDeviceID: deviceID
        )
        guard !fresh.isEmpty else { return }
        _ = try? await sync.importEvents(fresh)
    }

    private func publishLocal(
        sync: HistorySyncStore,
        store: any HistoryStore,
        since: Date,
        now: Date
    ) async {
        guard let events = try? await sync.exportableEvents(
            localDeviceID: deviceID,
            since: since
        ) else { return }

        let windowed = HistoryMerge.window(
            events: events,
            now: now,
            maximumBytes: store.maximumBatchBytes
        )
        // An empty window is still worth publishing once: it tells other devices
        // this one exists and is current, which is what keeps its slot from
        // being collected as stale.
        let batch = HistoryBatch(
            deviceID: deviceID,
            deviceName: deviceName,
            writtenAtMS: Int64(now.timeIntervalSince1970 * 1000),
            windowStartMS: windowed.windowStartMS,
            events: windowed.events
        )
        try? await store.save(batch)
    }

    /// Rebuild this device's rollup for the current year, and relay it if there
    /// is anywhere to relay it to.
    ///
    /// The build is unconditional: a year in review is assembled from the local
    /// log, so it works identically on every backend. Publishing is what a relay
    /// adds, and its absence costs other devices' contributions — not the review.
    private func refreshRollup(store: (any HistoryStore)?, now: Date) async {
        guard let database else { return }
        let year = HistoryRollupBuilder.utcCalendar.component(.year, from: now)
        guard let rollup = try? await HistoryRollupBuilder(database).build(
            year: year,
            deviceID: deviceID,
            now: now
        ) else { return }
        currentYear = rollup
        try? await store?.save(rollup)
    }

    // MARK: Year in review

    /// Every device's totals for a year, merged into one view.
    ///
    /// Reads the *published* rollups rather than recomputing from local events,
    /// so it sees listening this device never did — which is the whole point —
    /// and shows names as they read when they were played, even for things the
    /// catalog has since dropped.
    ///
    /// Falls back to building from the local log when nothing has been
    /// published — which is the normal path on a backend with no relay, and the
    /// reason a year in review is available on every backend rather than only
    /// where a server happens to offer somewhere to write.
    public func yearInReview(_ year: Int) async -> HistoryRollup? {
        let published = (try? await store?.loadRollups(year: year)) ?? []
        if let merged = HistoryRollupMerge.merged(published) { return merged }
        guard let database else { return nil }
        return try? await HistoryRollupBuilder(database).build(year: year, deviceID: deviceID)
    }
}
