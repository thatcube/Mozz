import Crypto
import Foundation
import MozzPairing

/// Pairing over the FFI, so a non-Apple client drives the *same* ceremony
/// instead of a second implementation that has to agree with it byte for byte.
///
/// The split follows what is actually platform-specific. The protocol and the
/// crypto are portable Swift and live here. The socket and the discovery are
/// not — Network.framework does not exist on Windows — so the host owns those
/// and pumps frames through these commands.
///
/// One property is worth stating plainly because it is the reason to do it this
/// way at all: **the device's private key never crosses the boundary.** The host
/// sees frames and, at the end, the circle it is entitled to. It never sees the
/// key that opened the seal, so a host process that is compromised cannot
/// impersonate the device in a later ceremony.
actor PairingRegistry {
    static let shared = PairingRegistry()

    private var sessions: [String: PairingSession] = [:]

    func begin(_ session: PairingSession) -> String {
        let id = UUID().uuidString
        sessions[id] = session
        return id
    }

    func withSession<T>(_ id: String, _ body: (inout PairingSession) throws -> T) throws -> T {
        guard var session = sessions[id] else { throw PairingCommandError.noSuchSession }
        defer { sessions[id] = session }
        return try body(&session)
    }

    func end(_ id: String) { sessions[id] = nil }
}

enum PairingCommandError: Error, LocalizedError {
    case noSuchSession
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .noSuchSession:
            return "That pairing session has ended. Start again."
        case let .missing(field):
            return "pairing command needs \(field)"
        }
    }
}

// MARK: - Wire shapes

/// A ``PairingStep`` in a form JSON can carry.
struct WirePairingStep: Encodable {
    let kind: String
    var frame: String?
    var digits: String?
    var transcript: String?
    var joinerPublicKey: String?
    var encapsulated: String?
    var ciphertext: String?

    init(_ step: PairingStep) {
        switch step {
        case let .send(frame):
            kind = "send"
            self.frame = frame.encoded().base64EncodedString()
        case let .compareDigits(value):
            kind = "digits"
            digits = value
        case let .sealCircle(transcriptHash, joinerKey):
            kind = "seal"
            transcript = transcriptHash.base64EncodedString()
            joinerPublicKey = joinerKey.base64EncodedString()
        case let .openSeal(encapsulatedKey, cipher, transcriptHash):
            kind = "open"
            encapsulated = encapsulatedKey.base64EncodedString()
            ciphertext = cipher.base64EncodedString()
            transcript = transcriptHash.base64EncodedString()
        case .finished:
            kind = "finished"
        }
    }
}

struct WirePairingBegan: Encodable {
    let pairingId: String
    let publicKey: String
    /// Present for a joiner: the text to render as a QR code.
    var qrText: String?
    var steps: [WirePairingStep]
}

struct WirePairingSteps: Encodable {
    let steps: [WirePairingStep]
}

struct WireCircleSecrets: Codable {
    let channelId: String
    let channelKey: String
    let credentialsKey: String
    let epoch: Int
    let relayKey: String

    init(_ secrets: CircleSecrets) {
        channelId = secrets.channelId
        channelKey = secrets.channelKey.base64EncodedString()
        credentialsKey = secrets.credentialsKey.base64EncodedString()
        epoch = secrets.epoch
        relayKey = secrets.relayKey.base64EncodedString()
    }

    func decoded() throws -> CircleSecrets {
        guard let channel = Data(base64Encoded: channelKey),
              let credentials = Data(base64Encoded: credentialsKey),
              let relay = Data(base64Encoded: relayKey) else {
            throw PairingCommandError.missing("valid base64 in circle")
        }
        return CircleSecrets(channelId: channelId, channelKey: channel,
                             credentialsKey: credentials, epoch: epoch, relayKey: relay)
    }
}

// MARK: - Dispatch

/// Returns `nil` when the command is not a pairing one, so the caller keeps
/// walking its own table and produces a single "unknown command" error.
///
/// Every failure becomes a response rather than an exception. A host across an
/// FFI boundary has no way to catch a Swift error, so anything thrown here
/// would reach it as a crash or a silent nothing; a failure envelope is
/// something it can act on.
func dispatchPairingCommand(
    _ request: SessionRequest
) async throws -> String? {
    do {
        return try await pairingCommand(request)
    } catch let error as PairingCommandError {
        return sessionFailure(request.id, request.cmd,
                              error.errorDescription ?? "pairing failed")
    } catch let error as PairingSessionError {
        return sessionFailure(request.id, request.cmd, describe(error))
    } catch {
        return sessionFailure(request.id, request.cmd, "\(error)")
    }
}

private func describe(_ error: PairingSessionError) -> String {
    switch error {
    case .wrongDevice:
        return "That code belongs to a different device."
    case .commitmentMismatch:
        return "The other device answered incorrectly. Start again."
    case let .unsupportedVersion(version):
        return "That device is running a different version of pairing (\(version))."
    case let .pathMismatch(reason):
        return reason
    case let .outOfOrder(expected, got):
        return "Pairing steps arrived out of order (expected \(expected), got \(got))."
    }
}

private func pairingCommand(
    _ request: SessionRequest
) async throws -> String? {
    switch request.cmd {

    case "pairingBegin":
        let role: PairingRole = (request.role == "member") ? .member : .joiner
        let path: PairingPath = (request.pairingPath == "digits") ? .digits : .qr

        var scanned: Pairing.QRPayload?
        if let code = request.scannedCode, !code.isEmpty {
            scanned = try Pairing.decodeQR(code)
        }

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        var nonce = Data(count: 16)
        for index in 0..<16 { nonce[index] = UInt8.random(in: 0...255) }

        var session = try PairingSession(role: role, path: path,
                                         privateKey: privateKey, nonce: nonce, scanned: scanned)
        var steps: [WirePairingStep] = []
        var qrText: String?
        if role == .joiner {
            qrText = try Pairing.encodeQR(
                Pairing.QRPayload(publicKey: privateKey.publicKey.rawRepresentation, nonce: nonce))
            steps = try session.start().map(WirePairingStep.init)
        }

        let id = await PairingRegistry.shared.begin(session)
        return sessionSuccess(request, WirePairingBegan(pairingId: id,
                                                        publicKey: session.ownPublicKey.base64EncodedString(),
                                                        qrText: qrText,
                                                        steps: steps))

    case "pairingReceive":
        guard let id = request.pairingId else { throw PairingCommandError.missing("pairingId") }
        guard let encoded = request.frame, let bytes = Data(base64Encoded: encoded) else {
            throw PairingCommandError.missing("frame")
        }
        let frame = try PairingFrame.decode(bytes)
        let steps = try await PairingRegistry.shared.withSession(id) { session in
            try session.receive(frame).map(WirePairingStep.init)
        }
        return sessionSuccess(request, WirePairingSteps(steps: steps))

    case "pairingConfirm":
        guard let id = request.pairingId else { throw PairingCommandError.missing("pairingId") }
        guard request.matched == true else {
            await PairingRegistry.shared.end(id)
            return sessionFailure(request.id, request.cmd,
                                  "The numbers did not match, so nothing was shared.")
        }
        let steps = try await PairingRegistry.shared.withSession(id) { session in
            try session.confirmDigits().map(WirePairingStep.init)
        }
        return sessionSuccess(request, WirePairingSteps(steps: steps))

    case "pairingSeal":
        guard let id = request.pairingId else { throw PairingCommandError.missing("pairingId") }
        guard let wire = request.circle else { throw PairingCommandError.missing("circle") }
        guard let transcript = request.transcript.flatMap({ Data(base64Encoded: $0) }),
              let joinerKey = request.joinerPublicKey.flatMap({ Data(base64Encoded: $0) }) else {
            throw PairingCommandError.missing("transcript and joinerPublicKey")
        }
        let seal = try Pairing.sealCircle(try wire.decoded(),
                                          toJoiner: joinerKey,
                                          transcriptHash: transcript)
        let steps = try await PairingRegistry.shared.withSession(id) { session in
            try session.provideSeal(encapsulated: seal.encapsulated,
                                    ciphertext: seal.ciphertext).map(WirePairingStep.init)
        }
        return sessionSuccess(request, WirePairingSteps(steps: steps))

    case "pairingOpen":
        guard let id = request.pairingId else { throw PairingCommandError.missing("pairingId") }
        guard let encapsulated = request.encapsulated.flatMap({ Data(base64Encoded: $0) }),
              let ciphertext = request.ciphertext.flatMap({ Data(base64Encoded: $0) }),
              let transcript = request.transcript.flatMap({ Data(base64Encoded: $0) }) else {
            throw PairingCommandError.missing("encapsulated, ciphertext and transcript")
        }
        // Opening happens here, with a key the host has never seen.
        let circle = try await PairingRegistry.shared.withSession(id) { session in
            try session.openSealedCircle(encapsulated: encapsulated,
                                         ciphertext: ciphertext,
                                         transcriptHash: transcript)
        }
        await PairingRegistry.shared.end(id)
        return sessionSuccess(request, WireCircleSecrets(circle))

    case "pairingEnd":
        guard let id = request.pairingId else { throw PairingCommandError.missing("pairingId") }
        await PairingRegistry.shared.end(id)
        return sessionSuccess(request, WirePairingSteps(steps: []))

    default:
        return nil
    }
}
