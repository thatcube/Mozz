import Crypto
import Foundation

public enum PairingRole: Sendable, Equatable {
    /// The device asking to be let in. It has nothing yet, so it displays.
    case joiner
    /// A device already in the circle. It has secrets to give, so it scans.
    case member
}

public enum PairingPath: Sendable, Equatable {
    /// The camera is the authentication; no digits are compared.
    case qr
    /// No camera, so a full commit-and-reveal with a human comparing digits.
    case digits
}

/// What the caller must do next. The session decides *what* happens and in what
/// order; the caller owns everything that touches the world — sockets, screens,
/// the circle's secrets, HPKE.
///
/// The split is deliberate. Every rule worth getting right here is a rule about
/// ordering, and ordering is exactly what a state machine can be tested for when
/// it is not also holding a socket open.
public enum PairingStep: Sendable, Equatable {
    case send(PairingFrame)
    /// Show these to the human and wait. Digit path only.
    case compareDigits(String)
    /// Member: seal the circle to this key and hand the result back via
    /// ``PairingSession/provideSeal(encapsulated:ciphertext:)``.
    case sealCircle(transcriptHash: Data, joinerPublicKey: Data)
    /// Joiner: open this and you are in the circle.
    case openSeal(encapsulated: Data, ciphertext: Data, transcriptHash: Data)
    case finished
}

public enum PairingSessionError: Error, Equatable {
    /// A frame arrived that this state has no meaning for. Covers replays and
    /// anything trying to skip a step.
    case outOfOrder(expected: String, got: String)
    /// QR path: the device that answered is not the one whose code we scanned.
    case wrongDevice
    /// The revealed nonce does not match what was committed to.
    case commitmentMismatch
    case pathMismatch(String)
    case unsupportedVersion(UInt8)
}

/// The pairing ceremony, as a state machine over frames.
///
/// Both paths and both roles live here so that the ordering rules exist in one
/// place rather than four. The rule that matters most — a member must verify the
/// commitment *before* computing digits — is a property of this type, and
/// `PairingSessionTests` asserts it by checking that a bad reveal produces no
/// digits at all rather than digits that happen not to match.
public struct PairingSession {
    private enum State: Equatable {
        case fresh
        case awaitingPeer
        case awaitingReveal
        case awaitingConfirmation
        case awaitingSeal
        case awaitingSealMaterial
        case finished
        case failed
    }

    public let role: PairingRole
    public let path: PairingPath

    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private let ownNonce: Data
    private let scanned: Pairing.QRPayload?
    private let ownName: String
    private let ownDeviceID: String

    private var state: State = .fresh
    private var peerPublicKey: Data?
    private var joinerNonce: Data?
    private var memberNonce: Data?
    private var commitment: Data?

    /// - Parameter scanned: the QR payload this member read with its camera.
    ///   Required for a member on the QR path, meaningless otherwise — it is what
    ///   lets the member tell the device it scanned from any other device that
    ///   answers.
    public init(
        role: PairingRole,
        path: PairingPath,
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        nonce: Data,
        scanned: Pairing.QRPayload? = nil,
        name: String = "Mozz",
        deviceID: String = UUID().uuidString
    ) throws {
        guard nonce.count == PairingFrame.Size.nonce else {
            throw PairingError.wrongLength(field: "nonce",
                                           expected: PairingFrame.Size.nonce,
                                           got: nonce.count)
        }
        if role == .member, path == .qr, scanned == nil {
            throw PairingSessionError.pathMismatch("a member on the QR path must supply what it scanned")
        }
        self.role = role
        self.path = path
        self.privateKey = privateKey
        self.ownNonce = nonce
        self.scanned = scanned
        self.ownName = PairingFrame.normalizedText(
            name, maximumBytes: PairingFrame.Size.maxName)
        self.ownDeviceID = PairingFrame.normalizedText(
            deviceID, maximumBytes: PairingFrame.Size.maxDeviceID)
    }

    /// What the other device calls itself. Unauthenticated until the digits are
    /// compared, so it is a label to recognise, never a fact to rely on.
    public private(set) var peerName: String?
    /// Stable ownership prefix for the peer's relay objects.
    public private(set) var peerDeviceID: String?

    public var ownPublicKey: Data { privateKey.publicKey.rawRepresentation }

    /// The joiner's opening move. A member has nothing to say until it is spoken to.
    public mutating func start() throws -> [PairingStep] {
        guard role == .joiner else {
            throw PairingSessionError.pathMismatch("only a joiner starts the ceremony")
        }
        guard state == .fresh else {
            throw PairingSessionError.outOfOrder(expected: "fresh", got: "\(state)")
        }
        joinerNonce = ownNonce
        state = .awaitingPeer
        return [.send(.hello(version: Pairing.version,
                             publicKey: ownPublicKey,
                             commitment: path == .digits ? Pairing.commitment(nonceA: ownNonce) : nil,
                             name: ownName,
                             deviceID: ownDeviceID))]
    }

    public mutating func receive(_ frame: PairingFrame) throws -> [PairingStep] {
        do {
            return try step(frame)
        } catch {
            state = .failed
            throw error
        }
    }

    private mutating func step(_ frame: PairingFrame) throws -> [PairingStep] {
        switch (state, frame) {
        case let (.fresh, .hello(
            version, publicKey, incomingCommitment, incomingName, incomingDeviceID
        )):
            guard role == .member else {
                throw PairingSessionError.outOfOrder(expected: "nothing", got: "hello")
            }
            guard version == Pairing.version else {
                throw PairingSessionError.unsupportedVersion(version)
            }
            peerPublicKey = publicKey
            memberNonce = ownNonce
            peerName = incomingName
            peerDeviceID = incomingDeviceID
            let answer = PairingStep.send(.peer(
                publicKey: ownPublicKey,
                nonce: ownNonce,
                name: ownName,
                deviceID: ownDeviceID))

            switch path {
            case .qr:
                guard incomingCommitment == nil else {
                    throw PairingSessionError.pathMismatch("a commitment arrived on the QR path")
                }
                guard let scanned, constantTimeEquals(publicKey, scanned.publicKey) else {
                    // Not the device whose code we scanned. On a network with
                    // several devices advertising, this is the ordinary case of
                    // reaching the wrong one — and it is also exactly what an
                    // impostor looks like, so it is refused rather than retried
                    // here.
                    throw PairingSessionError.wrongDevice
                }
                joinerNonce = scanned.nonce
                state = .awaitingSealMaterial
                return [answer, .sealCircle(transcriptHash: try transcript(),
                                            joinerPublicKey: publicKey)]

            case .digits:
                guard let incomingCommitment else {
                    throw PairingSessionError.pathMismatch("no commitment arrived on the digit path")
                }
                commitment = incomingCommitment
                state = .awaitingReveal
                return [answer]
            }

        case let (.awaitingPeer, .peer(publicKey, nonce, incomingName, incomingDeviceID)):
            peerPublicKey = publicKey
            memberNonce = nonce
            peerName = incomingName
            peerDeviceID = incomingDeviceID

            switch path {
            case .qr:
                state = .awaitingSeal
                return []
            case .digits:
                state = .awaitingConfirmation
                return [.send(.reveal(nonce: ownNonce)),
                        .compareDigits(try digits())]
            }

        case let (.awaitingReveal, .reveal(nonce)):
            // Order is the whole point. Verify, and only then derive anything
            // from the nonce we were given.
            guard let commitment, constantTimeEquals(Pairing.commitment(nonceA: nonce), commitment) else {
                throw PairingSessionError.commitmentMismatch
            }
            joinerNonce = nonce
            state = .awaitingConfirmation
            return [.compareDigits(try digits())]

        case let (.awaitingSeal, .sealed(encapsulated, ciphertext)):
            state = .finished
            return [.openSeal(encapsulated: encapsulated,
                              ciphertext: ciphertext,
                              transcriptHash: try transcript()),
                    .finished]

        default:
            throw PairingSessionError.outOfOrder(expected: "\(state)", got: describe(frame))
        }
    }

    /// The human said the digits match.
    public mutating func confirmDigits() throws -> [PairingStep] {
        guard state == .awaitingConfirmation else {
            throw PairingSessionError.outOfOrder(expected: "awaitingConfirmation", got: "\(state)")
        }
        switch role {
        case .joiner:
            state = .awaitingSeal
            return []
        case .member:
            state = .awaitingSealMaterial
            guard let peerPublicKey else { throw PairingSessionError.outOfOrder(expected: "a peer key", got: "none") }
            return [.sealCircle(transcriptHash: try transcript(), joinerPublicKey: peerPublicKey)]
        }
    }

    /// Open a seal addressed to this session, using the private key it already
    /// holds.
    ///
    /// Exists so a caller never needs the private key to finish a ceremony,
    /// which is what lets a non-Swift host drive pairing over an FFI without the
    /// key ever crossing the boundary.
    public func openSealedCircle(
        encapsulated: Data,
        ciphertext: Data,
        transcriptHash: Data
    ) throws -> CircleSecrets {
        try Pairing.openCircle(encapsulated: encapsulated,
                               ciphertext: ciphertext,
                               privateKey: privateKey,
                               transcriptHash: transcriptHash)
    }

    /// The member's caller has done the HPKE seal and hands back the result.
    public mutating func provideSeal(encapsulated: Data, ciphertext: Data) throws -> [PairingStep] {
        guard state == .awaitingSealMaterial else {
            throw PairingSessionError.outOfOrder(expected: "awaitingSealMaterial", got: "\(state)")
        }
        state = .finished
        return [.send(.sealed(encapsulated: encapsulated, ciphertext: ciphertext)), .finished]
    }

    // MARK: - Derivations

    private func transcript() throws -> Data {
        guard let peerPublicKey, let joinerNonce, let memberNonce else {
            throw PairingSessionError.outOfOrder(expected: "a complete transcript", got: "missing parts")
        }
        guard let peerDeviceID, let peerName else {
            throw PairingSessionError.outOfOrder(
                expected: "peer identity", got: "missing parts")
        }
        let (joinerKey, memberKey, joinerID, memberID, joinerName, memberName) =
            role == .joiner
            ? (ownPublicKey, peerPublicKey, ownDeviceID, peerDeviceID, ownName, peerName)
            : (peerPublicKey, ownPublicKey, peerDeviceID, ownDeviceID, peerName, ownName)
        return try Pairing.transcriptHash(joinerPublicKey: joinerKey,
                                          memberPublicKey: memberKey,
                                          joinerDeviceID: joinerID,
                                          memberDeviceID: memberID,
                                          joinerName: joinerName,
                                          memberName: memberName,
                                          nonceA: joinerNonce,
                                          nonceB: memberNonce)
    }

    private func digits() throws -> String {
        guard let peerPublicKey else {
            throw PairingSessionError.outOfOrder(expected: "a peer key", got: "none")
        }
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return Pairing.digits(sharedSecret: shared.withUnsafeBytes { Data($0) },
                              transcriptHash: try transcript())
    }

    private func describe(_ frame: PairingFrame) -> String {
        switch frame {
        case .hello: return "hello"
        case .peer: return "peer"
        case .reveal: return "reveal"
        case .sealed: return "sealed"
        }
    }

    /// Compares without leaking where two values first differ. The commitment
    /// check does not obviously need this, but a comparison that is only
    /// sometimes constant-time is a habit that eventually gets used somewhere it
    /// matters.
    private func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (l, r) in zip(lhs, rhs) { difference |= l ^ r }
        return difference == 0
    }
}
