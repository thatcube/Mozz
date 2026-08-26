import Crypto
import Foundation

/// The pairing wire format, exactly as `spec/pairing/README.md` describes it.
///
/// Pairing is the only moment secrets move between devices, and every later
/// feature inherits whatever trust it establishes. So this is written against
/// the spec rather than the spec being written against it, and the fixtures in
/// `spec/pairing/pairing-fixtures.json` are what let a second implementation be
/// checked before either is trusted.
///
/// Nothing here is Apple-specific. `swift-crypto` provides the same primitives
/// on Windows and Android, which the FFI spike proved rather than assumed
/// (CI run 32934126070).
public enum Pairing {
    /// Wire version. Bumping this is a breaking change and both encodings must
    /// ship together for a release — a device that cannot pair with the phone
    /// it paired with yesterday is worse than whatever the change fixed.
    public static let version: UInt8 = 0x01

    /// Who is speaking. Only the joiner ever produces a QR in v1.
    public enum Role: UInt8 {
        case joiner = 0x02
    }

    // MARK: Labels

    /// Every hash and derivation carries a distinct label.
    ///
    /// Reusing one across two purposes lets output from one step be replayed as
    /// input to another, which is the failure that takes otherwise-correct
    /// protocols apart.
    public enum Label {
        public static let qr = "mozz/pair/v1/qr"
        public static let commit = "mozz/pair/v1/commit"
        public static let sas = "mozz/pair/v1/sas"
        public static let channel = "mozz/pair/v1/channel"
    }

    // MARK: QR payload

    /// What a joining device displays.
    public struct QRPayload: Equatable, Sendable {
        public let publicKey: Data   // 32 bytes, X25519, raw
        public let nonce: Data       // 16 bytes

        public init(publicKey: Data, nonce: Data) {
            self.publicKey = publicKey
            self.nonce = nonce
        }
    }

    /// Encode a QR payload to the string a camera will read.
    ///
    /// Carries a *public* key and nothing else of value: a photograph of it is
    /// not a credential, because it only lets the holder offer to receive the
    /// circle secrets and a member still has to choose to send them.
    public static func encodeQR(_ payload: QRPayload) throws -> String {
        guard payload.publicKey.count == 32 else {
            throw PairingError.wrongLength(field: "publicKey", expected: 32, got: payload.publicKey.count)
        }
        guard payload.nonce.count == 16 else {
            throw PairingError.wrongLength(field: "nonce", expected: 16, got: payload.nonce.count)
        }

        var body = Data([version, Role.joiner.rawValue])
        body.append(payload.publicKey)
        body.append(payload.nonce)
        return "MOZZ1:" + base64URLNoPadding(body)
    }

    /// Decode what a camera read, rejecting anything it cannot fully account for.
    public static func decodeQR(_ text: String) throws -> QRPayload {
        guard text.hasPrefix("MOZZ1:") else { throw PairingError.notAMozzCode }
        let encoded = String(text.dropFirst("MOZZ1:".count))
        guard let body = decodeBase64URLNoPadding(encoded) else {
            throw PairingError.malformed("payload is not base64url")
        }
        // 1 version + 1 role + 32 key + 16 nonce. A payload of any other length
        // is rejected rather than truncated: a short read here would silently
        // pair against a partial key.
        guard body.count == 50 else {
            throw PairingError.wrongLength(field: "body", expected: 50, got: body.count)
        }
        guard body[body.startIndex] == version else {
            throw PairingError.unsupportedVersion(body[body.startIndex])
        }
        guard body[body.index(body.startIndex, offsetBy: 1)] == Role.joiner.rawValue else {
            throw PairingError.malformed("only a joiner may present a code")
        }

        let key = body.subdata(in: body.index(body.startIndex, offsetBy: 2)..<body.index(body.startIndex, offsetBy: 34))
        let nonce = body.subdata(in: body.index(body.startIndex, offsetBy: 34)..<body.endIndex)
        return QRPayload(publicKey: key, nonce: nonce)
    }

    // MARK: Commitment

    /// The joiner's commitment to its nonce, sent before the member reveals its own.
    ///
    /// Without this, whichever side speaks second could choose its contribution
    /// after seeing the other's and steer the digits toward a transcript it had
    /// already prepared.
    public static func commitment(nonceA: Data) -> Data {
        var input = Data(Label.commit.utf8)
        input.append(0x00)
        input.append(nonceA)
        return Data(SHA256.hash(data: input))
    }

    // MARK: Transcript

    /// What both sides agree was said. Any disagreement produces different
    /// digits, which is what makes a substituted key visible to a human.
    ///
    /// Every field is fixed-width and the order is fixed, so no length prefixes
    /// are needed and no field can be mistaken for its neighbour.
    public static func transcriptHash(
        joinerPublicKey: Data,
        memberPublicKey: Data,
        nonceA: Data,
        nonceB: Data
    ) throws -> Data {
        guard joinerPublicKey.count == 32 else {
            throw PairingError.wrongLength(field: "joinerPublicKey", expected: 32, got: joinerPublicKey.count)
        }
        guard memberPublicKey.count == 32 else {
            throw PairingError.wrongLength(field: "memberPublicKey", expected: 32, got: memberPublicKey.count)
        }
        guard nonceA.count == 16 else {
            throw PairingError.wrongLength(field: "nonceA", expected: 16, got: nonceA.count)
        }
        guard nonceB.count == 16 else {
            throw PairingError.wrongLength(field: "nonceB", expected: 16, got: nonceB.count)
        }

        var input = Data(Label.sas.utf8)
        input.append(0x00)
        input.append(version)
        input.append(joinerPublicKey)
        input.append(memberPublicKey)
        input.append(nonceA)
        input.append(nonceB)
        return Data(SHA256.hash(data: input))
    }

    // MARK: The six digits

    /// The largest whole multiple of 1,000,000 below 2³².
    ///
    /// 2³² is 4,294,967,296, so 967,296 values sit above the last whole million.
    /// Discarding those is what makes the result exactly uniform rather than
    /// nearly so.
    public static let rejectionLimit: UInt32 = 4_294_000_000

    /// Derive the six-digit short authentication string.
    ///
    /// Uniform by rejection sampling, deliberately. Plozz takes 24 bits and
    /// reduces mod a million, leaving 777,216 values in a slightly likelier
    /// band — far too small to help an attacker, free to remove, and certain to
    /// be copied by a second implementation reading only the code. So it is
    /// removed here and written down in the spec as a requirement.
    ///
    /// A draw is rejected about once in 4,400 times, which means an
    /// implementation that has never exercised the retry path is untested
    /// rather than correct. `spec/pairing` carries a fixture for exactly that.
    public static func digits(sharedSecret: Data, transcriptHash: Data) -> String {
        let value = uniformValue(from: sasStream(sharedSecret: sharedSecret, transcriptHash: transcriptHash))
        return String(format: "%06u", value)
    }

    /// Pull uniform values out of a byte stream, four bytes at a time.
    ///
    /// Split out, and public, so a fixture can drive it with a stream chosen to
    /// hit the rejection path — which random inputs essentially never do, since
    /// it happens about once in 4,400 draws. A second implementation has to
    /// reproduce this exactly, so it is part of the contract rather than a
    /// private detail.
    public static func uniformValue(from stream: [UInt8]) -> UInt32 {
        var offset = 0
        while offset + 4 <= stream.count {
            let v = (UInt32(stream[offset]) << 24)
                | (UInt32(stream[offset + 1]) << 16)
                | (UInt32(stream[offset + 2]) << 8)
                | UInt32(stream[offset + 3])
            offset += 4
            if v < rejectionLimit {
                return v % 1_000_000
            }
            // Above the limit: discard entirely and draw again. Reducing it here
            // is the bug this whole function exists to avoid, and it would pass
            // every test that does not deliberately hit this branch.
        }
        // Exhausting the stream means the caller supplied too little material.
        // Returning zero would be a silent, guessable SAS, so this is a
        // programming error rather than a runtime condition.
        preconditionFailure("SAS stream exhausted; supply more key material")
    }

    /// HKDF output, long enough that the rejection path can be taken repeatedly.
    static func sasStream(sharedSecret: Data, transcriptHash: Data, byteCount: Int = 64) -> [UInt8] {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt: transcriptHash,
            info: Data(Label.sas.utf8),
            outputByteCount: byteCount)
        return key.withUnsafeBytes { Array($0) }
    }

    // MARK: Sealing

    /// The `info` an HPKE seal is bound to.
    ///
    /// Binding the transcript means a sealed payload cannot be replayed into a
    /// *different* ceremony: the recipient derives the same `info` only if it
    /// saw the same transcript.
    public static func channelInfo(transcriptHash: Data) -> Data {
        var info = Data(Label.channel.utf8)
        info.append(0x00)
        info.append(transcriptHash)
        return info
    }

    // MARK: base64url

    /// RFC 4648 §5 without padding.
    ///
    /// Unpadded because a QR encoder that helpfully strips `=` would otherwise
    /// produce a payload that parses on one platform and not another.
    public static func base64URLNoPadding(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URLNoPadding(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Restore whatever padding was stripped; Foundation requires it.
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }
}

/// Why a pairing input was refused.
///
/// Separate cases rather than one message, because a caller shows different
/// things for "that is not a Mozz code" and "that code is from a newer version".
public enum PairingError: Error, Equatable {
    case notAMozzCode
    case malformed(String)
    case unsupportedVersion(UInt8)
    case wrongLength(field: String, expected: Int, got: Int)
}
