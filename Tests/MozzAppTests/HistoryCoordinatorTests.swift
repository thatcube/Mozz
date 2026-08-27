import MozzApp
import MozzDatabase
import MozzHistory
import XCTest

private actor HistoryStoreSpy: HistoryStore {
    let maximumBatchBytes = 256 * 1024
    var batches: [HistoryBatch]
    var rollups: [HistoryRollup]
    private(set) var savedBatches: [HistoryBatch] = []
    private(set) var savedRollups: [HistoryRollup] = []

    init(
        batches: [HistoryBatch] = [],
        rollups: [HistoryRollup] = []
    ) {
        self.batches = batches
        self.rollups = rollups
    }

    func loadBatches() async throws -> [HistoryBatch] { batches }
    func loadRollups(year: Int) async throws -> [HistoryRollup] {
        rollups.filter { $0.year == year }
    }
    func save(_ batch: HistoryBatch) async throws {
        savedBatches.append(batch)
    }
    func save(_ rollup: HistoryRollup) async throws {
        savedRollups.append(rollup)
    }
}

final class HistoryCoordinatorTests: XCTestCase {
    @MainActor
    func testOneSyncPublishesToEveryAvailableRelay() async throws {
        let database = try MusicDatabase.inMemory()
        let jellyfin = HistoryStoreSpy()
        let universal = HistoryStoreSpy()
        let coordinator = HistoryCoordinator()
        coordinator.activate(
            stores: [jellyfin, universal],
            database: database,
            deviceID: "phone-id",
            deviceName: "iPhone")

        await coordinator.sync(now: Date(timeIntervalSince1970: 1_800_000_000))

        let jellyfinBatches = await jellyfin.savedBatches
        let relayBatches = await universal.savedBatches
        let jellyfinRollups = await jellyfin.savedRollups
        let relayRollups = await universal.savedRollups
        XCTAssertEqual(jellyfinBatches.count, 1)
        XCTAssertEqual(relayBatches.count, 1)
        XCTAssertEqual(jellyfinBatches, relayBatches)
        XCTAssertEqual(jellyfinRollups.count, 1)
        XCTAssertEqual(relayRollups.count, 1)
        XCTAssertEqual(jellyfinRollups, relayRollups)
    }

    @MainActor
    func testTheSameDeviceRollupFromTwoRelaysCountsOnce() async {
        let rollup = HistoryRollup(
            deviceID: "phone-id",
            year: 2026,
            monthlyMS: [1_000],
            monthlyPlays: [1],
            updatedAtMS: 100)
        let jellyfin = HistoryStoreSpy(rollups: [rollup])
        let universal = HistoryStoreSpy(rollups: [rollup])
        let coordinator = HistoryCoordinator()
        coordinator.activate(
            stores: [jellyfin, universal],
            database: nil,
            deviceID: "mac-id",
            deviceName: "Mac")

        let merged = await coordinator.yearInReview(2026)

        XCTAssertEqual(merged?.totalMS, 1_000)
        XCTAssertEqual(merged?.totalPlays, 1)
    }

    @MainActor
    func testNewestCopyWinsWhenRelaysDisagreeAboutOneDevice() async {
        let old = HistoryRollup(
            deviceID: "phone-id",
            year: 2026,
            monthlyMS: [1_000],
            monthlyPlays: [1],
            updatedAtMS: 100)
        let new = HistoryRollup(
            deviceID: "phone-id",
            year: 2026,
            monthlyMS: [2_000],
            monthlyPlays: [2],
            updatedAtMS: 200)
        let coordinator = HistoryCoordinator()
        coordinator.activate(
            stores: [
                HistoryStoreSpy(rollups: [old]),
                HistoryStoreSpy(rollups: [new]),
            ],
            database: nil,
            deviceID: "mac-id",
            deviceName: "Mac")

        let merged = await coordinator.yearInReview(2026)

        XCTAssertEqual(merged?.totalMS, 2_000)
        XCTAssertEqual(merged?.totalPlays, 2)
    }
}
