import Foundation
import MozzPairing

/// Makes first-run joining visible without making someone hunt through Settings.
///
/// An unconfigured device advertises while Mozz is in setup. An established
/// device only probes when its Devices screen is open. When they meet, this
/// controller presents the actual trust decision on the device being added:
/// name the requester, compare six digits, accept or decline.
///
/// This is not background discovery and not ongoing sync. Once a device has a
/// circle, the relay keeps it in sync from anywhere; mDNS is only the on-ramp.
@MainActor
final class AmbientJoinController: ObservableObject {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let peerName: String
        let digits: String

        var spacedDigits: String {
            guard digits.count == 6 else { return digits }
            let middle = digits.index(digits.startIndex, offsetBy: 3)
            return "\(digits[..<middle]) \(digits[middle...])"
        }

        var confirmationMessage: String {
            "\(peerName) is asking to add this device.\n\n" +
                "Confirm \(spacedDigits) appears there too. Adding shares " +
                "your media servers, listening history, and library across the circle."
        }
    }

    @Published private(set) var request: Request?
    @Published private(set) var completedCircleID: String?
    @Published private(set) var isDevicesScreenActive = false
    @Published private(set) var confirmedPeerName: String?

    private let store: CircleStore
    private var work: Task<Void, Never>?
    private var workGeneration: UUID?
    private var awaitingAnswer: CheckedContinuation<Bool, Never>?
    private var setupActive = false
    private var pairingScreenRunsCeremony = false

    init(store: CircleStore = .live) {
        self.store = store
    }

    func setSetupActive(_ active: Bool) {
        setupActive = active
        reconcileListener()
    }

    func setDevicesScreenActive(_ active: Bool) {
        isDevicesScreenActive = active
        reconcileListener()
    }

    /// QR display and scanning use `PairingController`, but automatic digit
    /// joining always stays here. Suspend this listener while the screen runs an
    /// explicit ceremony so there is never a second advertised endpoint.
    func setPairingScreenRunsCeremony(_ active: Bool) {
        pairingScreenRunsCeremony = active
        reconcileListener()
    }

    private func reconcileListener() {
        if (setupActive || isDevicesScreenActive) && !pairingScreenRunsCeremony {
            startIfNeeded()
        } else {
            stop()
        }
    }

    private func startIfNeeded() {
        guard work == nil, (try? store.load()) == nil else { return }
        let store = self.store
        let generation = UUID()
        workGeneration = generation
        completedCircleID = nil

        work = Task { [weak self] in
            guard let self else { return }
            do {
                // Race the ceremony against iCloud Keychain. If one of the
                // person's Apple devices has already formed a circle, adopting
                // it must cancel this listener before an unnecessary ceremony
                // can overwrite it.
                let circle = try await withThrowingTaskGroup(of: CircleSecrets.self) { group in
                    group.addTask {
                        try await PairingCeremony.join(
                            path: .digits,
                            into: store,
                            deviceName: PairingController.deviceName,
                            deviceID: PairingController.deviceID,
                            showCode: { _, _ in },
                            confirmDigits: { digits, peerName in
                                await self.ask(digits, peerName: peerName)
                            })
                    }
                    group.addTask {
                        while !Task.isCancelled {
                            if let arrived = try store.load() { return arrived }
                            try await Task.sleep(for: .seconds(2))
                        }
                        throw CancellationError()
                    }

                    guard let first = try await group.next() else {
                        throw CancellationError()
                    }
                    group.cancelAll()
                    return first
                }

                // Whether it arrived through iCloud or a ceremony, setup now
                // has a circle and this device no longer advertises.
                _ = circle
                finish(generation, joined: circle)
            } catch is CancellationError {
                finish(generation)
            } catch {
                // Setup must remain usable if discovery fails. The Devices
                // screen exposes the same path and can report a detailed error.
                finish(generation, joined: try? store.load())
            }
        }
    }

    private func finish(_ generation: UUID, joined circle: CircleSecrets? = nil) {
        guard workGeneration == generation else { return }
        if let circle {
            completedCircleID = circle.channelId
        }
        request = nil
        confirmedPeerName = nil
        work = nil
        workGeneration = nil
    }

    private func ask(_ digits: String, peerName: String?) async -> Bool {
        request = Request(peerName: peerName ?? "Another device", digits: digits)
        return await withCheckedContinuation { awaitingAnswer = $0 }
    }

    func answer(_ accepted: Bool) {
        guard let continuation = awaitingAnswer else { return }
        let peerName = request?.peerName
        awaitingAnswer = nil
        request = nil
        confirmedPeerName = accepted ? peerName : nil
        continuation.resume(returning: accepted)
    }

    func stop() {
        work?.cancel()
        work = nil
        workGeneration = nil
        request = nil
        confirmedPeerName = nil
        awaitingAnswer?.resume(returning: false)
        awaitingAnswer = nil
    }
}
