import Foundation
import MozzCore
import MozzPairing
import SwiftUI

/// Bridges the app's keychain store, which speaks strings, to the pairing
/// store, which speaks bytes. Kept here rather than in MozzPairing so that
/// module stays free of anything Apple-specific — Windows and Android supply
/// their own.
struct KeychainSecureStore: SecureStore {
    private let inner: CredentialStore

    init(_ inner: CredentialStore = KeychainCredentialStore()) {
        self.inner = inner
    }

    func secret(forKey key: String) throws -> Data? {
        guard let encoded = try inner.string(forKey: key) else { return nil }
        return Data(base64Encoded: encoded)
    }

    func setSecret(_ value: Data?, forKey key: String) throws {
        try inner.setString(value?.base64EncodedString(), forKey: key)
    }
}

extension CircleStore {
    /// The real one: the secret in the keychain, everything else in defaults.
    static var live: CircleStore {
        CircleStore(secure: KeychainSecureStore(), plain: UserDefaultsStore())
    }
}

/// Drives a pairing ceremony for the screens.
///
/// The ceremony decides what happens next; this only turns those steps into
/// something a view can render, and turns a tap into the answer the ceremony is
/// waiting for.
@MainActor
final class PairingController: ObservableObject {
    enum Stage: Equatable {
        case idle
        /// Joiner: this is your code, hold it up to the other device.
        case showingCode(String)
        /// Joiner on the digit path: nothing to show yet, the other device has
        /// to find us first.
        case waitingForComputer
        /// The human has answered and the other device has not finished yet.
        case finishing
        /// Member: pointing the camera.
        case scanning
        case connecting
        /// Both, digit path: do these match?
        case comparing(String)
        case joined
        case failed(String)
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var circle: CircleSecrets?

    private let store: CircleStore
    private var work: Task<Void, Never>?
    private var awaitingAnswer: CheckedContinuation<Bool, Never>?

    init(store: CircleStore = .live) {
        self.store = store
        circle = try? store.load()
    }

    var isPaired: Bool { circle != nil }

    // MARK: - Joining

    /// This device asks to be let in. It displays; another device scans.
    func join(path: PairingPath = .qr) {
        cancel()
        stage = .connecting
        let store = self.store
        work = Task { [weak self] in
            do {
                let joined = try await PairingCeremony.join(
                    path: path,
                    into: store,
                    showCode: { text, _ in
                        // On the digit path there is nothing to hold up to a
                        // camera — a code appearing and then being replaced by
                        // digits would just be confusing.
                        Task { @MainActor in
                            self?.stage = path == .digits ? .waitingForComputer : .showingCode(text)
                        }
                    },
                    confirmDigits: { digits in
                        await self?.ask(digits) ?? false
                    })
                await MainActor.run {
                    self?.circle = joined
                    self?.stage = .joined
                }
            } catch is CancellationError {
                await MainActor.run { self?.stage = .idle }
            } catch {
                let message = Self.explain(error)
                await MainActor.run { self?.stage = .failed(message) }
            }
        }
    }

    // MARK: - Admitting

    func beginScanning() {
        cancel()
        stage = .scanning
    }

    /// A code came back from the camera.
    func admit(scannedText: String, path: PairingPath = .qr) {
        let payload: Pairing.QRPayload
        do {
            payload = try Pairing.decodeQR(scannedText)
        } catch {
            stage = .failed("That is not a Mozz pairing code.")
            return
        }

        cancel()
        stage = .connecting
        let store = self.store
        work = Task { [weak self] in
            do {
                // Forms a circle if this device is alone, which is what the
                // very first pairing always is.
                try await PairingCeremony.admit(
                    from: store, path: path, scanned: payload,
                    confirmDigits: { digits in
                        await self?.ask(digits) ?? false
                    })
                await MainActor.run {
                    self?.circle = try? store.load()
                    self?.stage = .joined
                }
            } catch is CancellationError {
                await MainActor.run { self?.stage = .idle }
            } catch {
                let message = Self.explain(error)
                await MainActor.run { self?.stage = .failed(message) }
            }
        }
    }

    // MARK: - The human's answer

    func answer(_ matched: Bool) {
        guard let continuation = awaitingAnswer else { return }
        awaitingAnswer = nil
        // Move off the comparison BEFORE resuming. Without this the screen keeps
        // showing the same two buttons, so a tap that worked perfectly reads as
        // one that was ignored — and the obvious response is to tap it again.
        stage = matched ? .finishing : .failed("You said the numbers did not match, so nothing was shared.")
        continuation.resume(returning: matched)
    }

    private func ask(_ digits: String) async -> Bool {
        stage = .comparing(digits)
        return await withCheckedContinuation { continuation in
            awaitingAnswer = continuation
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        // Release anyone waiting on an answer, or the ceremony's task never
        // unwinds and the screen leaks a suspended continuation.
        awaitingAnswer?.resume(returning: false)
        awaitingAnswer = nil
    }

    func reset() {
        cancel()
        stage = .idle
    }

    func leaveCircle() {
        cancel()
        try? store.clear()
        circle = nil
        stage = .idle
    }

    private static func explain(_ error: Error) -> String {
        switch error {
        case PairingCeremony.CeremonyError.declined:
            return "The numbers did not match, so nothing was shared."
        case PairingCeremony.CeremonyError.noDeviceFound:
            return "No device nearby is waiting to be paired. Both devices need to be on the same network."
        case PairingSessionError.wrongDevice:
            return "That code belongs to a different device."
        case PairingSessionError.commitmentMismatch:
            return "The other device answered incorrectly. Start again."
        default:
            return "Pairing did not finish. Try again."
        }
    }
}
