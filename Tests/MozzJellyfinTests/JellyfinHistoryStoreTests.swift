import XCTest
import Foundation
import MozzCore
import MozzHistory
import MozzNetworking
@testable import MozzJellyfin

/// Captures the request body so a read-modify-write can be inspected, and
/// serves whatever `DisplayPreferences` record the test sets up. The fixture
/// transport in `MozzJellyfinTests` serves static files, which cannot express a
/// record that changes between the read and the write.
private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    /// Keyed by preferences id, because the store deliberately uses more than
    /// one record — a shared slot here would let a bug that writes to the wrong
    /// record pass unnoticed.
    private var _records: [String: JFDisplayPreferencesDto]
    private var _posted: [JFDisplayPreferencesDto] = []

    init(records: [String: JFDisplayPreferencesDto] = [:]) {
        self._records = records
    }

    convenience init(record: JFDisplayPreferencesDto) {
        self.init(records: [JellyfinHistoryStore.preferencesID: record])
    }

    convenience init(notFound: Bool) {
        self.init(records: [:])
    }

    var postedRecords: [JFDisplayPreferencesDto] {
        lock.lock(); defer { lock.unlock() }
        return _posted
    }

    /// `.../DisplayPreferences/{id}?query`
    private func preferencesID(from request: URLRequest) -> String {
        request.url?.path.components(separatedBy: "/").last ?? ""
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url ?? URL(string: "https://example.com")!
        let id = preferencesID(from: request)

        if request.httpMethod == "POST" {
            let decoded = try JSONDecoder().decode(
                JFDisplayPreferencesDto.self, from: request.httpBody ?? Data()
            )
            lock.lock()
            _posted.append(decoded)
            _records[id] = decoded   // persist, so a later read observes the write
            lock.unlock()
            return (Data("{}".utf8), HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }

        lock.lock()
        let record = _records[id]
        lock.unlock()

        guard let record else {
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        return (try JSONEncoder().encode(record),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private func makeClient(_ transport: RecordingTransport) -> HTTPClient {
    HTTPClient(baseURL: URL(string: "https://jf.example")!, transport: transport)
}

private func makeBatch(
    device: String,
    writtenAtMS: Int64 = 1_800_000_000_000,
    events: [HistoryEvent] = []
) -> HistoryBatch {
    HistoryBatch(
        deviceID: device,
        deviceName: "Test \(device)",
        writtenAtMS: writtenAtMS,
        windowStartMS: writtenAtMS - 1_000_000,
        events: events
    )
}

private func makeEvent(device: String, ref: String, atMS: Int64 = 1_799_999_000_000) -> HistoryEvent {
    HistoryEvent(
        deviceID: device,
        trackRef: ref,
        kind: "completed",
        createdAtMS: atMS,
        positionMS: 180_000,
        durationMS: 180_000
    )
}

private func encodedSlot(_ batch: HistoryBatch) -> String {
    String(data: try! HistoryMerge.makeEncoder().encode(batch), encoding: .utf8)!
}

final class JellyfinHistoryStoreTests: XCTestCase {

    // MARK: Load

    func testLoadingAnAccountThatHasNeverSyncedIsEmptyNotAnError() async throws {
        // A 404 here is the normal first-run shape, not a failure.
        let store = JellyfinHistoryStore(client: makeClient(RecordingTransport(notFound: true)), userID: "u1")
        let batches = try await store.loadBatches()
        XCTAssertTrue(batches.isEmpty)
    }

    func testLoadReturnsEveryDevicesSlot() async throws {
        let a = makeBatch(device: "dev-a", writtenAtMS: 1_800_000_000_000)
        let b = makeBatch(device: "dev-b", writtenAtMS: 1_800_000_100_000)
        let record = JFDisplayPreferencesDto(CustomPrefs: [
            JellyfinHistoryStore.key(for: "dev-a"): encodedSlot(a),
            JellyfinHistoryStore.key(for: "dev-b"): encodedSlot(b),
        ])

        let store = JellyfinHistoryStore(client: makeClient(RecordingTransport(record: record)), userID: "u1")
        let batches = try await store.loadBatches()

        XCTAssertEqual(batches.map(\.deviceID), ["dev-a", "dev-b"])
    }

    func testLoadIgnoresForeignKeysInTheSameRecord() async throws {
        let record = JFDisplayPreferencesDto(CustomPrefs: [
            JellyfinHistoryStore.key(for: "dev-a"): encodedSlot(makeBatch(device: "dev-a")),
            "someOtherApp.setting": "{\"not\":\"ours\"}",
        ])
        let store = JellyfinHistoryStore(client: makeClient(RecordingTransport(record: record)), userID: "u1")

        let batches = try await store.loadBatches()
        XCTAssertEqual(batches.map(\.deviceID), ["dev-a"])
    }

    func testOneCorruptSlotDoesNotLoseTheOthers() async throws {
        // A truncated slot must cost that device's history, not everyone's.
        let record = JFDisplayPreferencesDto(CustomPrefs: [
            JellyfinHistoryStore.key(for: "dev-a"): encodedSlot(makeBatch(device: "dev-a")),
            JellyfinHistoryStore.key(for: "dev-b"): "{ this is not json",
        ])
        let store = JellyfinHistoryStore(client: makeClient(RecordingTransport(record: record)), userID: "u1")

        let batches = try await store.loadBatches()
        XCTAssertEqual(batches.map(\.deviceID), ["dev-a"])
    }

    // MARK: Save

    func testSaveWritesThisDevicesSlot() async throws {
        let transport = RecordingTransport(notFound: true)
        let store = JellyfinHistoryStore(client: makeClient(transport), userID: "u1")
        let batch = makeBatch(device: "dev-a", events: [makeEvent(device: "dev-a", ref: "srv:t1")])

        try await store.save(batch)

        let posted = try XCTUnwrap(transport.postedRecords.last)
        let slot = try XCTUnwrap(posted.CustomPrefs?[JellyfinHistoryStore.key(for: "dev-a")])
        let decoded = try JSONDecoder().decode(HistoryBatch.self, from: Data(slot.utf8))
        XCTAssertEqual(decoded.events.map(\.trackRef), ["srv:t1"])
    }

    func testSavePreservesOtherDevicesSlots() async throws {
        // The single most important property: the POST replaces the whole
        // record, so a careless write would silently erase every other device's
        // history.
        let other = makeBatch(device: "dev-b", events: [makeEvent(device: "dev-b", ref: "srv:theirs")])
        let record = JFDisplayPreferencesDto(CustomPrefs: [
            JellyfinHistoryStore.key(for: "dev-b"): encodedSlot(other),
        ])
        let transport = RecordingTransport(record: record)
        let store = JellyfinHistoryStore(client: makeClient(transport), userID: "u1")

        try await store.save(makeBatch(device: "dev-a"))

        let posted = try XCTUnwrap(transport.postedRecords.last)
        XCTAssertNotNil(posted.CustomPrefs?[JellyfinHistoryStore.key(for: "dev-b")])
        XCTAssertNotNil(posted.CustomPrefs?[JellyfinHistoryStore.key(for: "dev-a")])
    }

    func testSavePreservesUnrelatedPreferences() async throws {
        let record = JFDisplayPreferencesDto(CustomPrefs: ["someOtherApp.setting": "keep-me"])
        let transport = RecordingTransport(record: record)
        let store = JellyfinHistoryStore(client: makeClient(transport), userID: "u1")

        try await store.save(makeBatch(device: "dev-a"))

        let posted = try XCTUnwrap(transport.postedRecords.last)
        XCTAssertEqual(posted.CustomPrefs?["someOtherApp.setting"], "keep-me")
    }

    func testSaveReplacesOnlyThisDevicesPreviousSlot() async throws {
        let transport = RecordingTransport(notFound: true)
        let store = JellyfinHistoryStore(client: makeClient(transport), userID: "u1")

        try await store.save(makeBatch(device: "dev-a", events: [makeEvent(device: "dev-a", ref: "srv:old")]))
        try await store.save(makeBatch(
            device: "dev-a",
            writtenAtMS: 1_800_000_050_000,
            events: [makeEvent(device: "dev-a", ref: "srv:new")]
        ))

        let posted = try XCTUnwrap(transport.postedRecords.last)
        let slot = try XCTUnwrap(posted.CustomPrefs?[JellyfinHistoryStore.key(for: "dev-a")])
        let decoded = try JSONDecoder().decode(HistoryBatch.self, from: Data(slot.utf8))
        // Last-writer-wins over its own history, which is always safe because
        // this device is the only author of it.
        XCTAssertEqual(decoded.events.map(\.trackRef), ["srv:new"])
    }

    // MARK: Stale slots

    func testAVeryOldDeviceSlotIsCollected() async throws {
        let now: Int64 = 1_800_000_000_000
        let ancient = makeBatch(
            device: "dev-retired",
            writtenAtMS: now - JellyfinHistoryStore.staleSlotSeconds - 1
        )
        var prefs = [JellyfinHistoryStore.key(for: "dev-retired"): encodedSlot(ancient)]

        JellyfinHistoryStore.dropStaleSlots(from: &prefs, now: now, keeping: "dev-a")
        XCTAssertTrue(prefs.isEmpty)
    }

    func testARecentDeviceSlotIsKept() async throws {
        let now: Int64 = 1_800_000_000_000
        let recent = makeBatch(device: "dev-b", writtenAtMS: now - 86_400_000)
        var prefs = [JellyfinHistoryStore.key(for: "dev-b"): encodedSlot(recent)]

        JellyfinHistoryStore.dropStaleSlots(from: &prefs, now: now, keeping: "dev-a")
        XCTAssertEqual(prefs.count, 1)
    }

    func testOwnSlotIsNeverCollectedEvenIfItLooksStale() async throws {
        // A device's own clock is the one that stamped the batch; if it jumped,
        // collecting its own history would be self-inflicted data loss.
        let now: Int64 = 1_800_000_000_000
        let mine = makeBatch(device: "dev-a", writtenAtMS: now - JellyfinHistoryStore.staleSlotSeconds - 1)
        var prefs = [JellyfinHistoryStore.key(for: "dev-a"): encodedSlot(mine)]

        JellyfinHistoryStore.dropStaleSlots(from: &prefs, now: now, keeping: "dev-a")
        XCTAssertEqual(prefs.count, 1)
    }

    func testAnUnreadableSlotIsNeverCollected() async throws {
        // A batch from a NEWER Mozz would fail to decode here. Deleting it
        // because this build cannot read it would destroy a newer client's
        // history, so unreadable slots are left strictly alone.
        var prefs = [JellyfinHistoryStore.key(for: "dev-future"): "{\"version\":99,\"unknown\":true}"]

        JellyfinHistoryStore.dropStaleSlots(from: &prefs, now: 1_800_000_000_000, keeping: "dev-a")
        XCTAssertEqual(prefs.count, 1)
    }

    func testForeignKeysAreNeverCollected() async throws {
        var prefs = ["someOtherApp.setting": "keep-me"]
        JellyfinHistoryStore.dropStaleSlots(from: &prefs, now: 1_800_000_000_000, keeping: "dev-a")
        XCTAssertEqual(prefs["someOtherApp.setting"], "keep-me")
    }

    // MARK: Rollups

    func testRollupsLiveInTheirOwnPerYearRecord() async throws {
        // A finished year never changes again, so it must not sit in the record
        // that gets rewritten on every sync.
        let transport = RecordingTransport(notFound: true)
        let store = JellyfinHistoryStore(client: makeClient(transport), userID: "u1")

        try await store.save(HistoryRollup(deviceID: "dev-a", year: 2026, updatedAtMS: 1))
        try await store.save(makeBatch(device: "dev-a"))

        // Two different preferences records were written, not one.
        let ids = Set(transport.postedRecords.compactMap(\.Id))
        XCTAssertTrue(ids.contains(JellyfinHistoryStore.rollupPreferencesID(year: 2026)))
        XCTAssertTrue(ids.contains(JellyfinHistoryStore.preferencesID))
    }

    func testRollupRoundTrips() async throws {
        let transport = RecordingTransport(notFound: true)
        let store = JellyfinHistoryStore(client: makeClient(transport), userID: "u1")

        var monthly = Array(repeating: Int64(0), count: 12)
        monthly[2] = 90_000
        try await store.save(HistoryRollup(
            deviceID: "dev-a", year: 2026, monthlyMS: monthly,
            topArtists: [RollupEntry(key: "art-1", name: "Lena Vance", plays: 3, totalMS: 90_000)],
            updatedAtMS: 5
        ))

        let loaded = try await store.loadRollups(year: 2026)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.monthlyMS[2], 90_000)
        XCTAssertEqual(loaded.first?.topArtists.first?.name, "Lena Vance")
    }

    func testLoadingRollupsForAYearNeverWrittenIsEmpty() async throws {
        let store = JellyfinHistoryStore(client: makeClient(RecordingTransport(notFound: true)), userID: "u1")
        let loaded = try await store.loadRollups(year: 2019)
        XCTAssertTrue(loaded.isEmpty)
    }

    func testSavingARollupPreservesOtherDevices() async throws {
        let transport = RecordingTransport(notFound: true)
        let a = JellyfinHistoryStore(client: makeClient(transport), userID: "u1")
        let b = JellyfinHistoryStore(client: makeClient(transport), userID: "u1")

        try await a.save(HistoryRollup(deviceID: "dev-a", year: 2026, updatedAtMS: 1))
        try await b.save(HistoryRollup(deviceID: "dev-b", year: 2026, updatedAtMS: 2))

        let loaded = try await a.loadRollups(year: 2026)
        XCTAssertEqual(Set(loaded.map(\.deviceID)), ["dev-a", "dev-b"])
    }

    // MARK: End to end

    func testTwoDevicesSharingOneRecordConverge() async throws {
        // Both devices write to the same Jellyfin record, then each reads and
        // merges the other's slot — the full round trip the feature exists for.
        let transport = RecordingTransport(notFound: true)
        let storeA = JellyfinHistoryStore(client: makeClient(transport), userID: "u1")
        let storeB = JellyfinHistoryStore(client: makeClient(transport), userID: "u1")

        try await storeA.save(makeBatch(device: "dev-a", events: [makeEvent(device: "dev-a", ref: "srv:a1")]))
        try await storeB.save(makeBatch(
            device: "dev-b",
            writtenAtMS: 1_800_000_050_000,
            events: [makeEvent(device: "dev-b", ref: "srv:b1")]
        ))

        let seenByA = HistoryMerge.newEvents(
            from: try await storeA.loadBatches(), known: [], ownDeviceID: "dev-a"
        )
        XCTAssertEqual(seenByA.map(\.trackRef), ["srv:b1"])

        let seenByB = HistoryMerge.newEvents(
            from: try await storeB.loadBatches(), known: [], ownDeviceID: "dev-b"
        )
        XCTAssertEqual(seenByB.map(\.trackRef), ["srv:a1"])
    }
}
