import Foundation
import MozzCore
import MozzDatabase
import MozzRelay
@testable import MozzSync
import XCTest

actor SettingsMemoryRelayStore: RelayObjectStore {
    private struct Stored {
        var data: Data
        var etag: String
    }

    private var values: [String: Stored] = [:]
    private var generation = 0

    func read(
        path: String,
        ifNoneMatch: String?
    ) async throws -> RelayReadResult {
        guard let value = values[path] else { return .missing }
        if value.etag == ifNoneMatch { return .notModified }
        return .object(RelayStoredObject(
            data: value.data,
            etag: value.etag))
    }

    func put(
        path: String,
        data: Data,
        condition: RelayWriteCondition
    ) async throws -> String {
        generation += 1
        let etag = "etag-\(generation)"
        values[path] = Stored(data: data, etag: etag)
        return etag
    }

    func list(prefix: String) async throws -> [String] {
        values.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }
}

final class PlaybackSettingsRelayCoordinatorTests: XCTestCase {
    private let key = Data(repeating: 0xB4, count: 32)

    private func relay(
        _ objects: SettingsMemoryRelayStore,
        deviceID: String
    ) throws -> RelayHistoryStore {
        try RelayHistoryStore(
            objects: objects,
            channelID: "channel",
            localDeviceID: deviceID,
            epoch: 1,
            channelKey: key)
    }

    private func settings(_ gain: Double) -> PlaybackSettings {
        PlaybackSettings(
            equalizerEnabled: true,
            equalizer: EqualizerSettings(
                gains: [gain],
                preampDB: -2),
            replayGainMode: .album,
            replayGainPreampDB: 1)
    }

    func testNewestPlaybackSettingsConvergeAndKeepTheirTimestamp() async throws {
        let objects = SettingsMemoryRelayStore()
        let phoneDatabase = try MusicDatabase.inMemory()
        let pcDatabase = try MusicDatabase.inMemory()
        _ = try await PlaybackSettingsStore(phoneDatabase).save(
            settings(2),
            updatedAtMS: 100)
        _ = try await PlaybackSettingsStore(pcDatabase).save(
            settings(5),
            updatedAtMS: 200)

        _ = try await PlaybackSettingsRelayCoordinator(
            database: phoneDatabase,
            relay: try relay(objects, deviceID: "phone"),
            localDeviceID: "phone"
        ).sync(seed: .defaults)
        _ = try await PlaybackSettingsRelayCoordinator(
            database: pcDatabase,
            relay: try relay(objects, deviceID: "pc"),
            localDeviceID: "pc"
        ).sync(seed: .defaults)
        let result = try await PlaybackSettingsRelayCoordinator(
            database: phoneDatabase,
            relay: try relay(objects, deviceID: "phone"),
            localDeviceID: "phone"
        ).sync(seed: .defaults)

        XCTAssertTrue(result.changedLocally)
        XCTAssertEqual(result.stored.updatedAtMS, 200)
        XCTAssertEqual(result.stored.settings, settings(5))
    }

    func testRemoteSettingsBeatAnUnmigratedLocalSeed() async throws {
        let objects = SettingsMemoryRelayStore()
        let source = try MusicDatabase.inMemory()
        _ = try await PlaybackSettingsStore(source).save(
            settings(4),
            updatedAtMS: 100)
        _ = try await PlaybackSettingsRelayCoordinator(
            database: source,
            relay: try relay(objects, deviceID: "phone"),
            localDeviceID: "phone"
        ).sync(seed: .defaults)

        let target = try MusicDatabase.inMemory()
        let result = try await PlaybackSettingsRelayCoordinator(
            database: target,
            relay: try relay(objects, deviceID: "pc"),
            localDeviceID: "pc"
        ).sync(seed: settings(-4))

        XCTAssertTrue(result.changedLocally)
        XCTAssertEqual(result.stored.settings, settings(4))
        let stored = try await PlaybackSettingsStore(target).loadStored()
        XCTAssertEqual(stored?.updatedAtMS, 100)
    }

    func testDeviceIDBreaksAnExactTimestampTie() {
        let lower = RelayPlaybackSettingsSnapshot(
            deviceID: "a",
            updatedAtMS: 100,
            settings: settings(1))
        let higher = RelayPlaybackSettingsSnapshot(
            deviceID: "z",
            updatedAtMS: 100,
            settings: settings(2))

        XCTAssertEqual(
            RelayHistoryStore.mergedPlaybackSettings([higher, lower]),
            higher)
    }
}
