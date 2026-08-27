import Foundation
import MozzHistory
import MozzPairing
import MozzRelay

/// Turns the opaque relay capability in a circle into a live HistoryStore.
///
/// The endpoint is configurable for self-hosting. Sync is on by default, per
/// ADR-0012, and failure is degraded rather than fatal: local history remains
/// the durable copy and retries on the next lifecycle hook.
enum RelayBootstrapper {
    static let enabledKey = "mozz.deviceSyncEnabled"
    static let endpointKey = "mozz.relayEndpoint"
    static let defaultEndpoint = "https://relay.mozzmusic.com"

    struct Configured {
        let store: any HistoryStore
        let expiresAtMS: Int64
    }

    static func historyStore(
        circle: CircleSecrets,
        circleStore: CircleStore,
        localDeviceID: String
    ) async throws -> Configured {
        let endpointText = UserDefaults.standard.string(
            forKey: endpointKey) ?? defaultEndpoint
        guard let endpoint = URL(string: endpointText) else {
            throw RelayProvisioningError.malformedResponse
        }
        let provisioner = RelayProvisioner(endpoint: endpoint)

        var configuration: B2RelayConfiguration
        if circle.relayKey.isEmpty {
            configuration = try await provisioner.create(
                channelID: circle.channelId)
        } else {
            configuration = try B2RelayConfiguration.decode(circle.relayKey)
            if RelayProvisioner.needsRenewal(configuration) {
                configuration = try await provisioner.renew(
                    channelID: circle.channelId,
                    current: configuration)
            }
        }

        let encoded = try configuration.encoded()
        if encoded != circle.relayKey {
            try circleStore.save(CircleSecrets(
                channelId: circle.channelId,
                channelKey: circle.channelKey,
                credentialsKey: circle.credentialsKey,
                epoch: circle.epoch,
                relayKey: encoded))
        }

        let objects = B2NativeRelayObjectStore(
            configuration: configuration)
        let history = try RelayHistoryStore(
            objects: objects,
            channelID: circle.channelId,
            localDeviceID: localDeviceID,
            epoch: circle.epoch,
            channelKey: circle.channelKey)
        return Configured(
            store: history,
            expiresAtMS: configuration.expiresAtMS)
    }

    static func expiresSoon(
        _ expiresAtMS: Int64,
        now: Date = Date()
    ) -> Bool {
        let configuration = B2RelayConfiguration(
            keyID: "",
            applicationKey: "",
            bucketName: "",
            expiresAtMS: expiresAtMS)
        return RelayProvisioner.needsRenewal(configuration, now: now)
    }
}
