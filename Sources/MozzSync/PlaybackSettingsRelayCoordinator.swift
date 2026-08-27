import Foundation
import MozzCore
import MozzDatabase
import MozzRelay

public enum PlaybackSettingsRelayError: Error, Equatable {
    case missingLocalState
}

public struct PlaybackSettingsRelayResult: Sendable, Equatable {
    public var stored: StoredPlaybackSettings
    public var changedLocally: Bool

    public init(
        stored: StoredPlaybackSettings,
        changedLocally: Bool
    ) {
        self.stored = stored
        self.changedLocally = changedLocally
    }
}

/// Converges the one shared playback-settings record across every device.
public actor PlaybackSettingsRelayCoordinator {
    private let store: PlaybackSettingsStore
    private let relay: RelayHistoryStore
    private let localDeviceID: String

    public init(
        database: MusicDatabase,
        relay: RelayHistoryStore,
        localDeviceID: String
    ) {
        self.store = PlaybackSettingsStore(database)
        self.relay = relay
        self.localDeviceID = localDeviceID
    }

    public func sync(
        seed: PlaybackSettings
    ) async throws -> PlaybackSettingsRelayResult {
        let remote = RelayHistoryStore.mergedPlaybackSettings(
            try await relay.loadPlaybackSettingsSnapshots())
        var local = try await store.loadStored()
        var changedLocally = false

        // Timestamp zero is the v19 pre-sync row. The shells still owned the
        // effective preferences in that version, so treat the supplied shell
        // value as the migration seed unless a real remote mutation exists.
        if local == nil || local?.updatedAtMS == 0 {
            if let remote {
                _ = try await store.save(
                    remote.settings,
                    updatedAtMS: remote.updatedAtMS)
                local = StoredPlaybackSettings(
                    settings: remote.settings,
                    updatedAtMS: remote.updatedAtMS)
                changedLocally = true
            } else {
                let timestamp = Int64(
                    Date().timeIntervalSince1970 * 1_000)
                _ = try await store.save(
                    seed,
                    updatedAtMS: timestamp)
                local = StoredPlaybackSettings(
                    settings: seed,
                    updatedAtMS: timestamp)
            }
        }

        guard var selected = local else {
            throw PlaybackSettingsRelayError.missingLocalState
        }
        let localSnapshot = RelayPlaybackSettingsSnapshot(
            deviceID: localDeviceID,
            updatedAtMS: selected.updatedAtMS,
            settings: selected.settings)
        let winner = RelayHistoryStore.mergedPlaybackSettings(
            [localSnapshot] + (remote.map { [$0] } ?? []))
        if let winner,
           winner.deviceID != localDeviceID,
           (winner.updatedAtMS > selected.updatedAtMS
            || winner.settings != selected.settings) {
            _ = try await store.save(
                winner.settings,
                updatedAtMS: winner.updatedAtMS)
            selected = StoredPlaybackSettings(
                settings: winner.settings,
                updatedAtMS: winner.updatedAtMS)
            changedLocally = true
        }

        try await relay.save(RelayPlaybackSettingsSnapshot(
            deviceID: localDeviceID,
            updatedAtMS: selected.updatedAtMS,
            settings: selected.settings))
        return PlaybackSettingsRelayResult(
            stored: selected,
            changedLocally: changedLocally)
    }
}
