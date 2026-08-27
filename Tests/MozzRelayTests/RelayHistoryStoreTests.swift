import Foundation
import MozzHistory
@testable import MozzRelay
import XCTest

final actor MemoryRelayObjectStore: RelayObjectStore {
    enum TestError: Error {
        case alreadyExists
        case etagMismatch
    }

    private struct Value {
        var data: Data
        var etag: String
    }

    private var values: [String: Value] = [:]
    private var generation = 0
    private(set) var putCount = 0
    private(set) var bodyReadCount = 0

    func read(path: String, ifNoneMatch: String?) async throws -> RelayReadResult {
        guard let value = values[path] else { return .missing }
        if value.etag == ifNoneMatch { return .notModified }
        bodyReadCount += 1
        return .object(RelayStoredObject(data: value.data, etag: value.etag))
    }

    func put(
        path: String,
        data: Data,
        condition: RelayWriteCondition
    ) async throws -> String {
        switch condition {
        case .none:
            break
        case .ifAbsent where values[path] != nil:
            throw TestError.alreadyExists
        case let .ifMatch(expected) where values[path]?.etag != expected:
            throw TestError.etagMismatch
        default:
            break
        }

        generation += 1
        putCount += 1
        let etag = "etag-\(generation)"
        values[path] = Value(data: data, etag: etag)
        return etag
    }

    func list(prefix: String) async throws -> [String] {
        values.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    func paths() -> [String] { values.keys.sorted() }

    func swapBodies(_ first: String, _ second: String) {
        let left = values[first]?.data
        let right = values[second]?.data
        if let right { values[first]?.data = right }
        if let left { values[second]?.data = left }
    }
}

final class RelayHistoryStoreTests: XCTestCase {
    private let key = Data(repeating: 0xC1, count: 32)

    private func store(
        _ objects: MemoryRelayObjectStore,
        device: String
    ) throws -> RelayHistoryStore {
        try RelayHistoryStore(
            objects: objects,
            channelID: "channel_123",
            localDeviceID: device,
            epoch: 1,
            channelKey: key)
    }

    private func batch(
        device: String,
        uid: String,
        writtenAtMS: Int64 = 100
    ) -> HistoryBatch {
        HistoryBatch(
            deviceID: device,
            deviceName: device,
            writtenAtMS: writtenAtMS,
            windowStartMS: 0,
            events: [
                HistoryEvent(
                    uid: uid,
                    deviceID: device,
                    trackRef: "server:track",
                    kind: "completed",
                    createdAtMS: writtenAtMS),
            ])
    }

    func testTwoDevicesPublishWithoutSharingAnyWritablePath() async throws {
        let objects = MemoryRelayObjectStore()
        let phone = try store(objects, device: "phone-id")
        let pc = try store(objects, device: "pc-id")

        async let phoneWrite: Void = phone.save(batch(device: "phone-id", uid: "phone-play"))
        async let pcWrite: Void = pc.save(batch(device: "pc-id", uid: "pc-play"))
        _ = try await (phoneWrite, pcWrite)

        let paths = await objects.paths()
        XCTAssertEqual(paths.count, 4, "one data object and one manifest per device")
        XCTAssertEqual(paths.filter { $0.contains("/d/phone-id/") }.count, 1)
        XCTAssertEqual(paths.filter { $0.contains("/d/pc-id/") }.count, 1)
        XCTAssertEqual(paths.filter { $0.contains("/manifests/1/") }.count, 2)

        let loaded = try await phone.loadBatches()
        XCTAssertEqual(Set(loaded.map(\.deviceID)), Set(["phone-id", "pc-id"]))
        XCTAssertEqual(Set(loaded.flatMap(\.events).map(\.uid)),
                       Set(["phone-play", "pc-play"]))
    }

    func testAnUnchangedBatchWritesNothing() async throws {
        let objects = MemoryRelayObjectStore()
        let relay = try store(objects, device: "phone-id")
        let value = batch(device: "phone-id", uid: "same")

        try await relay.save(value)
        let afterFirst = await objects.putCount
        try await relay.save(value)

        XCTAssertEqual(afterFirst, 2)
        let afterSecond = await objects.putCount
        XCTAssertEqual(afterSecond, afterFirst)
    }

    func testASecondReadUsesConditionalGetsAndDownloadsNoBodies() async throws {
        let objects = MemoryRelayObjectStore()
        let phone = try store(objects, device: "phone-id")
        try await phone.save(batch(device: "phone-id", uid: "once"))

        let reader = try store(objects, device: "reader-id")
        _ = try await reader.loadBatches()
        let afterFirstRead = await objects.bodyReadCount
        _ = try await reader.loadBatches()
        let afterSecondRead = await objects.bodyReadCount

        XCTAssertEqual(afterFirstRead, 2, "manifest plus history object")
        XCTAssertEqual(afterSecondRead, afterFirstRead,
                       "unchanged ETags must not download either body again")
    }

    func testChangingABatchWritesTheObjectAndItsOwnManifest() async throws {
        let objects = MemoryRelayObjectStore()
        let relay = try store(objects, device: "phone-id")
        try await relay.save(batch(device: "phone-id", uid: "first"))
        let before = await objects.putCount

        try await relay.save(batch(
            device: "phone-id", uid: "second", writtenAtMS: 200))

        let after = await objects.putCount
        XCTAssertEqual(after - before, 2)
    }

    func testCiphertextCannotBeMovedToAnotherAuthenticatedPath() async throws {
        let objects = MemoryRelayObjectStore()
        let phone = try store(objects, device: "phone-id")
        let pc = try store(objects, device: "pc-id")
        try await phone.save(batch(device: "phone-id", uid: "phone"))
        try await pc.save(batch(device: "pc-id", uid: "pc"))

        let allPaths = await objects.paths()
        let paths = allPaths.filter { !$0.contains("/manifests/") }
        XCTAssertEqual(paths.count, 2)
        await objects.swapBodies(paths[0], paths[1])

        let fresh = try store(objects, device: "reader-id")
        await XCTAssertThrowsErrorAsync {
            _ = try await fresh.loadBatches()
        }
    }

    func testTheWrongChannelKeyCannotReadAnything() async throws {
        let objects = MemoryRelayObjectStore()
        let phone = try store(objects, device: "phone-id")
        try await phone.save(batch(device: "phone-id", uid: "private"))

        let wrong = try RelayHistoryStore(
            objects: objects,
            channelID: "channel_123",
            localDeviceID: "reader-id",
            epoch: 1,
            channelKey: Data(repeating: 0xFF, count: 32))
        await XCTAssertThrowsErrorAsync {
            _ = try await wrong.loadBatches()
        }
    }

    func testADeviceCannotPublishAnotherDevicesBatch() async throws {
        let relay = try store(MemoryRelayObjectStore(), device: "phone-id")
        do {
            try await relay.save(batch(device: "pc-id", uid: "forged"))
            XCTFail("a device wrote another device's ownership slot")
        } catch let error as RelayStoreError {
            XCTAssertEqual(
                error,
                .payloadDeviceMismatch(expected: "phone-id", actual: "pc-id"))
        }
    }

    func testTwoProcessesForOneDeviceCannotCorruptTheWinningManifest() async throws {
        let objects = MemoryRelayObjectStore()
        let first = try store(objects, device: "phone-id")
        let second = try store(objects, device: "phone-id")

        let firstWrite = Task {
            try await first.save(batch(device: "phone-id", uid: "first"))
        }
        let secondWrite = Task {
            try await second.save(batch(device: "phone-id", uid: "second"))
        }
        let results = await [firstWrite, secondWrite].asyncMap { task in
            do {
                try await task.value
                return true
            } catch {
                return false
            }
        }

        XCTAssertTrue(results.contains(true), "at least one manifest write must win")
        let reader = try store(objects, device: "reader-id")
        let loaded = try await reader.loadBatches()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].events.count, 1)
        XCTAssertTrue(["first", "second"].contains(loaded[0].events[0].uid))
    }

    func testAnOversizedBatchIsRefusedBeforeAWrite() async throws {
        let objects = MemoryRelayObjectStore()
        let relay = try store(objects, device: "phone-id")
        let huge = HistoryBatch(
            deviceID: "phone-id",
            writtenAtMS: 1,
            windowStartMS: 0,
            events: [
                HistoryEvent(
                    uid: String(repeating: "x", count: 300_000),
                    deviceID: "phone-id",
                    trackRef: "s:t",
                    kind: "completed",
                    createdAtMS: 1),
            ])

        await XCTAssertThrowsErrorAsync {
            try await relay.save(huge)
        }
        let writes = await objects.putCount
        XCTAssertEqual(writes, 0)
    }

    func testPathComponentsArePortableASCIIAndCannotEscapeTheirPrefix() {
        XCTAssertThrowsError(try RelayHistoryStore(
            objects: MemoryRelayObjectStore(),
            channelID: "../another-channel",
            localDeviceID: "phone-id",
            epoch: 1,
            channelKey: key))
        XCTAssertThrowsError(try RelayHistoryStore(
            objects: MemoryRelayObjectStore(),
            channelID: "channel",
            localDeviceID: "café",
            epoch: 1,
            channelKey: key))
    }

    func testFinishedYearRollupsTravelSeparatelyFromTheHotBatch() async throws {
        let objects = MemoryRelayObjectStore()
        let phone = try store(objects, device: "phone-id")
        let pc = try store(objects, device: "pc-id")
        let rollup = HistoryRollup(
            deviceID: "phone-id",
            year: 2026,
            monthlyMS: [100],
            monthlyPlays: [1],
            updatedAtMS: 200)

        try await phone.save(rollup)

        let loadedRollups = try await pc.loadRollups(year: 2026)
        let loadedBatches = try await pc.loadBatches()
        XCTAssertEqual(loadedRollups, [rollup])
        XCTAssertTrue(loadedBatches.isEmpty)
    }
}

private extension Array {
    func asyncMap<T>(
        _ transform: (Element) async -> T
    ) async -> [T] {
        var result: [T] = []
        for element in self {
            result.append(await transform(element))
        }
        return result
    }
}

func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        // Expected.
    }
}
