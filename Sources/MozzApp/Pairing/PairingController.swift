import Foundation
#if canImport(UIKit)
import UIKit
#endif
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
    /// The real one on Apple platforms: the whole circle in the **syncing**
    /// keychain, so it reaches the rest of someone's Apple devices by itself.
    ///
    /// iCloud Keychain is end-to-end encrypted and already knows which devices
    /// belong to one person, which is the question a pairing ceremony exists to
    /// answer. Where the platform can answer it for free, asking a human to
    /// compare six digits is ceremony for its own sake — Plozz gets this right
    /// by being iOS-only, and there is no reason Apple-to-Apple should be worse
    /// here just because Windows also has to work.
    ///
    /// This is not an account. Mozz stores nothing, has no user table, and
    /// cannot read any of it; it borrows an identity the person already has,
    /// which is precisely the posture ADR-0013 asked for.
    ///
    /// Both halves live in the keychain rather than only `credentialsKey`. The
    /// two-tier split in `spec/channel` is about *local* storage — keeping the
    /// channel key out of a stolen backup — and putting it somewhere stronger
    /// does not weaken that. The two keys remain separate keys, which is what
    /// governs what a leak of either exposes in the relay.
    static var live: CircleStore {
        let syncing = KeychainSecureStore(
            KeychainCredentialStore(service: "com.thatcube.Mozz.circle", synchronizable: true))
        return CircleStore(secure: syncing, plain: syncing)
    }
}

extension KeychainSecureStore: PlainStore {
    func value(forKey key: String) throws -> Data? { try secret(forKey: key) }
    func setValue(_ value: Data?, forKey key: String) throws { try setSecret(value, forKey: key) }
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
    @Published private(set) var members: [CircleMember] = []

    /// What this device calls itself to the others.
    ///
    /// iOS returns the model name rather than "Brandon's iPhone" unless the app
    /// carries an entitlement Apple grants sparingly, so this is honest about
    /// being a model rather than pretending to a personal name. It still beats
    /// three entries called Mozz, which is what a hardcoded name produced.
    static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    private let store: CircleStore
    private var work: Task<Void, Never>?
    private var awaitingAnswer: CheckedContinuation<Bool, Never>?

    init(store: CircleStore = .live) {
        self.store = store
        circle = try? store.load()
        members = (try? store.members()) ?? []
    }

    var isPaired: Bool { circle != nil }

    /// Re-read the circle from storage.
    ///
    /// The store is the truth, not this object. A circle can arrive from
    /// another of the user's Apple devices through iCloud Keychain at any
    /// moment, including while this screen is open, and a cached copy would
    /// keep showing "looking for your other devices" while the device was
    /// already in one.
    ///
    /// It also matters for a race this design allows: two Apple devices that
    /// each form a circle before iCloud has converged. Whichever one iCloud
    /// settles on is the one that exists, and a device holding the other must
    /// adopt it rather than carry on writing to a channel nobody else reads.
    func refresh() {
        members = (try? store.members()) ?? []
        let stored = try? store.load()
        guard stored != circle else { return }
        circle = stored
        if stored != nil, stage == .waitingForComputer || stage == .idle {
            stage = .joined
        }
    }

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
                    deviceName: Self.deviceName,
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
                    self?.members = (try? store.members()) ?? []
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
                    deviceName: Self.deviceName,
                    confirmDigits: { digits in
                        await self?.ask(digits) ?? false
                    })
                await MainActor.run {
                    self?.circle = try? store.load()
                    self?.members = (try? store.members()) ?? []
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
        members = []
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
