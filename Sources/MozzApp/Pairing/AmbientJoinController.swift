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
    }

    @Published private(set) var request: Request?

    private let store: CircleStore
    private var work: Task<Void, Never>?
    private var awaitingAnswer: CheckedContinuation<Bool, Never>?

    init(store: CircleStore = .live) {
        self.store = store
    }

    func update(enabled: Bool) {
        if enabled {
            startIfNeeded()
        } else {
            stop()
        }
    }

    private func startIfNeeded() {
        guard work == nil, (try? store.load()) == nil else { return }
        let store = self.store

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
                request = nil
                work = nil
            } catch is CancellationError {
                request = nil
                work = nil
            } catch {
                // Setup must remain usable if discovery fails. The Devices
                // screen exposes the same path and can report a detailed error.
                request = nil
                work = nil
            }
        }
    }

    private func ask(_ digits: String, peerName: String?) async -> Bool {
        request = Request(peerName: peerName ?? "Another device", digits: digits)
        return await withCheckedContinuation { awaitingAnswer = $0 }
    }

    func answer(_ accepted: Bool) {
        guard let continuation = awaitingAnswer else { return }
        awaitingAnswer = nil
        request = nil
        continuation.resume(returning: accepted)
    }

    func stop() {
        work?.cancel()
        work = nil
        request = nil
        awaitingAnswer?.resume(returning: false)
        awaitingAnswer = nil
    }
}
