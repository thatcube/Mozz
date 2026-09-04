#if canImport(Network)
import Crypto
import Foundation
import Network

/// Runs a whole ceremony, so a screen never has to know the protocol.
///
/// The human parts are callbacks — show this code, do these digits match — and
/// everything else happens without asking. A view that has to sequence frames
/// itself will eventually sequence them differently on one platform, which is
/// the failure this exists to prevent.
public enum PairingCeremony {
    public enum CeremonyError: Error, Equatable {
        case declined
        case noDeviceFound
    }

    /// The joining device: display, wait, and come back holding the circle.
    ///
    /// Advertises because it is the one asking to be let in. The circle is saved
    /// before returning, so a caller that forgets to persist cannot produce a
    /// device that paired and then forgot.
    public static func join(
        path: PairingPath,
        into store: CircleStore,
        deviceName: String = "Mozz",
        deviceID: String = UUID().uuidString,
        host: PairingHost? = nil,
        showCode: @Sendable (String, Pairing.QRPayload) -> Void,
        confirmDigits: (_ digits: String, _ peerName: String?) async -> Bool = { _, _ in true }
    ) async throws -> CircleSecrets {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        var nonce = Data(count: 16)
        for index in 0..<16 { nonce[index] = UInt8.random(in: 0...255) }

        let payload = Pairing.QRPayload(publicKey: privateKey.publicKey.rawRepresentation, nonce: nonce)
        showCode(try Pairing.encodeQR(payload), payload)

        // Advertised under the device's own name, so the other side lists
        // "Brandon's iPhone" rather than three entries called Mozz.
        let host = try host ?? PairingHost(advertise: true, name: deviceName)
        try await host.start()
        defer { Task { await host.stop() } }

        let link = try await host.nextLink()
        var session = try PairingSession(role: .joiner, path: path, privateKey: privateKey,
                                         nonce: nonce, name: deviceName, deviceID: deviceID)

        for step in try session.start() where isSend(step) {
            try await send(step, over: link)
        }

        while true {
            let steps = try session.receive(try await link.receive())
            for step in steps {
                switch step {
                case .send:
                    try await send(step, over: link)
                case let .compareDigits(digits):
                    guard await confirmDigits(digits, session.peerName) else {
                        throw CeremonyError.declined
                    }
                    for confirmed in try session.confirmDigits() where isSend(confirmed) {
                        try await send(confirmed, over: link)
                    }
                case let .openSeal(encapsulated, ciphertext, transcript):
                    let circle = try Pairing.openCircle(encapsulated: encapsulated,
                                                        ciphertext: ciphertext,
                                                        privateKey: privateKey,
                                                        transcriptHash: transcript)
                    try store.save(circle)
                    try store.remember(CircleMember(
                        id: deviceID, name: deviceName, isSelf: true))
                    if let peerID = session.peerDeviceID, let peer = session.peerName {
                        try store.remember(CircleMember(id: peerID, name: peer))
                    }
                    await link.close()
                    return circle
                default:
                    break
                }
            }
        }
    }

    /// A device already in the circle, admitting another.
    ///
    /// `scanned` is the QR payload from the camera on the QR path, `nil` on the
    /// digit path. Several devices may be advertising at once; each is tried in
    /// turn, and one that is not the device scanned is rejected by
    /// ``PairingSession`` rather than by anything here.
    /// Admit a device, forming a circle first if this one is alone.
    ///
    /// The first pairing anyone does is between two devices, neither of which is
    /// in a circle yet. The one holding the music forms it.
    public static func admit(
        from store: CircleStore,
        path: PairingPath,
        scanned: Pairing.QRPayload?,
        deviceName: String = "Mozz",
        deviceID: String = UUID().uuidString,
        endpoints: AsyncStream<NWEndpoint> = browseForPairingDevices(),
        confirmDigits: (_ digits: String, _ peerName: String?) async -> Bool = { _, _ in true }
    ) async throws {
        try await admit(try store.loadOrCreate(), path: path, scanned: scanned,
                        deviceName: deviceName, deviceID: deviceID, store: store,
                        endpoints: endpoints, confirmDigits: confirmDigits)
    }

    public static func admit(
        _ circle: CircleSecrets,
        path: PairingPath,
        scanned: Pairing.QRPayload?,
        deviceName: String = "Mozz",
        deviceID: String = UUID().uuidString,
        store: CircleStore? = nil,
        endpoints: AsyncStream<NWEndpoint> = browseForPairingDevices(),
        confirmDigits: (_ digits: String, _ peerName: String?) async -> Bool = { _, _ in true }
    ) async throws {
        for await endpoint in endpoints {
            let link: PairingLink
            do {
                link = try await PairingLink.connect(to: endpoint)
            } catch {
                continue
            }
            do {
                let admitted = try await runMember(circle, path: path, scanned: scanned,
                                                   link: link, deviceName: deviceName,
                                                   deviceID: deviceID,
                                                   confirmDigits: confirmDigits)
                if let store {
                    try store.remember(CircleMember(
                        id: deviceID, name: deviceName, isSelf: true))
                    if let admitted {
                        try store.remember(CircleMember(
                            id: admitted.id, name: admitted.name))
                    }
                }
                await link.close()
                return
            } catch PairingSessionError.wrongDevice {
                // Ordinary in a house with several Mozz devices. Try the next.
                await link.close()
                continue
            } catch {
                await link.close()
                throw error
            }
        }
        throw CeremonyError.noDeviceFound
    }

    /// Split out so a caller holding its own link — a test, or a transport that
    /// is not Bonjour — can run the member side directly.
    @discardableResult
    public static func runMember(
        _ circle: CircleSecrets,
        path: PairingPath,
        scanned: Pairing.QRPayload?,
        link: PairingLink,
        deviceName: String = "Mozz",
        deviceID: String = UUID().uuidString,
        confirmDigits: (_ digits: String, _ peerName: String?) async -> Bool = { _, _ in true }
    ) async throws -> (id: String, name: String)? {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        var nonce = Data(count: 16)
        for index in 0..<16 { nonce[index] = UInt8.random(in: 0...255) }

        var session = try PairingSession(role: .member, path: path,
                                         privateKey: privateKey, nonce: nonce,
                                         scanned: scanned, name: deviceName,
                                         deviceID: deviceID)

        while true {
            let steps = try session.receive(try await link.receive())
            var sealed = false
            for step in steps {
                switch step {
                case .send:
                    try await send(step, over: link)
                case let .compareDigits(digits):
                    guard await confirmDigits(digits, session.peerName) else {
                        throw CeremonyError.declined
                    }
                    for confirmed in try session.confirmDigits() {
                        if case let .sealCircle(transcript, joinerKey) = confirmed {
                            try await seal(circle, to: joinerKey, transcript: transcript,
                                           session: &session, link: link)
                            sealed = true
                        }
                    }
                case let .sealCircle(transcript, joinerKey):
                    try await seal(circle, to: joinerKey, transcript: transcript,
                                   session: &session, link: link)
                    sealed = true
                default:
                    break
                }
            }
            if sealed {
                guard let id = session.peerDeviceID, let name = session.peerName else {
                    return nil
                }
                return (id, name)
            }
        }
    }

    private static func seal(
        _ circle: CircleSecrets,
        to joinerKey: Data,
        transcript: Data,
        session: inout PairingSession,
        link: PairingLink
    ) async throws {
        let seal = try Pairing.sealCircle(circle, toJoiner: joinerKey, transcriptHash: transcript)
        for step in try session.provideSeal(encapsulated: seal.encapsulated, ciphertext: seal.ciphertext) {
            try await send(step, over: link)
        }
    }

    private static func isSend(_ step: PairingStep) -> Bool {
        if case .send = step { return true }
        return false
    }

    private static func send(_ step: PairingStep, over link: PairingLink) async throws {
        guard case let .send(frame) = step else { return }
        try await link.send(frame)
    }
}
#endif
