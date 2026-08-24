import Foundation
import MozzCore
import MozzDatabase
import MozzHistory

/// Schedules listening-history sync: publish this device's window, take in what
/// other devices published, and keep the current year's rollup fresh.
///
/// Deliberately *not* on the playback hot path. `ContinuityCoordinator` writes a
/// cursor every 15-30 seconds because a resume point goes stale in seconds;
/// history does not. A play recorded an hour late still lands in the same taste
/// profile and the same month of the same year, so this runs on activation, on
/// return to the foreground, and at a slow interval in between.
///
/// The merge itself needs no coordination (see `HistoryMerge`), so there is no
/// locking here and no ordering to get right — only the question of *when*.
@MainActor
public final class HistoryCoordinator: ObservableObject {

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
    /// Failures are swallowed on purpose: history sync is a background
    /// convenience, and the local log — which is the durable copy — is untouched
    /// by a failed round trip. Anything missed rides along in the next batch.
    public func sync(now: Date = Date()) async {
        guard let store, let database, !deviceID.isEmpty, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let sync = HistorySyncStore(database)

        // Rows written before event_uid existed have no identity to merge on, so
        // they cannot be published until they have one. Bounded per pass so a
        // very long history does not stall the first sync.
        if !hasBackfilled {
            var remaining = 4
            while remaining > 0 {
                let filled = (try? await sync.backfillUIDs(localDeviceID: deviceID)) ?? 0
                if filled == 0 { break }
                remaining -= 1
            }
            hasBackfilled = true
        }

        let since = now.addingTimeInterval(-Double(HistoryMerge.defaultWindowDays) * 86_400)

        // Take in first, then publish. A device that has been away should not
        // overwrite its slot before it has seen what happened while it was gone —
        // and importing first means this batch is written from a log that
        // already reflects the others.
        await importRemote(sync: sync, store: store, since: since)
        await publishLocal(sync: sync, store: store, since: since, now: now)
        await publishRollup(store: store, now: now)

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

    private func publishRollup(store: any HistoryStore, now: Date) async {
        guard let database else { return }
        let year = HistoryRollupBuilder.utcCalendar.component(.year, from: now)
        guard let rollup = try? await HistoryRollupBuilder(database).build(
            year: year,
            deviceID: deviceID,
            now: now
        ) else { return }
        try? await store.save(rollup)
    }

    // MARK: Year in review

    /// Every device's totals for a year, merged into one view.
    ///
    /// Reads the *published* rollups rather than recomputing from local events,
    /// so it sees listening this device never did — which is the whole point —
    /// and shows names as they read when they were played, even for things the
    /// catalog has since dropped.
    ///
    /// Falls back to this device's own year when nothing has been published, so
    /// a single-device user still gets a review.
    public func yearInReview(_ year: Int) async -> HistoryRollup? {
        let published = (try? await store?.loadRollups(year: year)) ?? []
        if let merged = HistoryRollupMerge.merged(published) { return merged }
        guard let database else { return nil }
        return try? await HistoryRollupBuilder(database).build(year: year, deviceID: deviceID)
    }
}
