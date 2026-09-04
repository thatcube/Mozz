import Foundation

/// The four things devices say to each other while pairing, and their encoding.
///
/// Kept separate from ``PairingSession`` because the codec is the part a second
/// implementation has to match byte for byte, and mixing it with state
/// transitions makes it harder to check that it does.
///
/// Every field is fixed-width except the seal, which is length-prefixed. That is
/// the same discipline the transcript uses and for the same reason: a parser
/// that cannot confuse one field with the next cannot be talked into confusing
/// them.
public enum PairingFrame: Sendable, Equatable {
    /// Joiner opens. `commitment` is present on the digit path and absent on the
    /// QR path, where the camera already carried the nonce.
    ///
    /// `name` is what the other side shows a human — "Brandon's iPhone" rather
    /// than an address. It is unauthenticated until the digits are compared, so
    /// it is a label to recognise, never a fact to rely on.
    case hello(
        version: UInt8,
        publicKey: Data,
        commitment: Data?,
        name: String,
        deviceID: String
    )

    /// Member answers with its own contribution.
    case peer(publicKey: Data, nonce: Data, name: String, deviceID: String)

    /// Joiner opens its commitment. Digit path only.
    case reveal(nonce: Data)

    /// Member hands over the circle, sealed to the joiner's public key.
    case sealed(encapsulated: Data, ciphertext: Data)

    // MARK: - Sizes

    public enum Size {
        public static let publicKey = 32
        public static let nonce = 16
        public static let commitment = 32

        /// Long enough for any device name a person would recognise, short
        /// enough that it cannot be used to pad a frame.
        public static let maxName = 64
        public static let maxDeviceID = 64

        /// A ceiling on the seal, so a peer cannot make us allocate arbitrarily
        /// by claiming a large length. The plaintext is five short JSON fields;
        /// 8 KiB is orders of magnitude more than it can legitimately need.
        public static let maxCiphertext = 8 * 1024
        /// X25519 encapsulated keys are 32 bytes. The allowance is for a future
        /// suite, not for anything that should appear today.
        public static let maxEncapsulated = 256
    }

    private enum Tag: UInt8 {
        case hello = 0x01
        case peer = 0x02
        case reveal = 0x03
        case sealed = 0x04
    }

    // MARK: - Encoding

    public func encoded() -> Data {
        var out = Data()
        switch self {
        case let .hello(version, publicKey, commitment, name, deviceID):
            out.append(Tag.hello.rawValue)
            out.append(version)
            out.append(publicKey)
            out.append(commitment == nil ? 0x00 : 0x01)
            if let commitment { out.append(commitment) }
            out.append(Self.encodeText(name, maximumBytes: Size.maxName))
            out.append(Self.encodeText(deviceID, maximumBytes: Size.maxDeviceID))

        case let .peer(publicKey, nonce, name, deviceID):
            out.append(Tag.peer.rawValue)
            out.append(publicKey)
            out.append(nonce)
            out.append(Self.encodeText(name, maximumBytes: Size.maxName))
            out.append(Self.encodeText(deviceID, maximumBytes: Size.maxDeviceID))

        case let .reveal(nonce):
            out.append(Tag.reveal.rawValue)
            out.append(nonce)

        case let .sealed(encapsulated, ciphertext):
            out.append(Tag.sealed.rawValue)
            out.append(UInt8(encapsulated.count >> 8))
            out.append(UInt8(encapsulated.count & 0xFF))
            out.append(contentsOf: withUnsafeBytes(of: UInt32(ciphertext.count).bigEndian, Array.init))
            out.append(encapsulated)
            out.append(ciphertext)
        }
        return out
    }

    // MARK: - Decoding

    /// Decode exactly one frame. Trailing bytes are an error rather than
    /// something to ignore: a frame with something after it is not a frame we
    /// understand, and quietly discarding the remainder is how parsers become
    /// smuggling routes.
    public static func decode(_ data: Data) throws -> PairingFrame {
        var reader = Reader(data)
        let tag = try reader.byte(field: "tag")
        let frame: PairingFrame

        switch Tag(rawValue: tag) {
        case .hello:
            let version = try reader.byte(field: "version")
            // The rest of hello changed in v2 when authenticated device ids were
            // added. Refuse an old shape before trying to parse it as the current
            // one, so an update mismatch is not reported as corrupt framing.
            guard version == Pairing.version else {
                throw PairingError.unsupportedVersion(version)
            }
            let publicKey = try reader.take(Size.publicKey, field: "publicKey")
            let hasCommitment = try reader.byte(field: "hasCommitment")
            let commitment: Data?
            switch hasCommitment {
            case 0x00:
                commitment = nil
            case 0x01:
                commitment = try reader.take(Size.commitment, field: "commitment")
            default:
                throw PairingError.malformed("hasCommitment must be 0 or 1, got \(hasCommitment)")
            }
            frame = .hello(version: version, publicKey: publicKey, commitment: commitment,
                           name: try Self.decodeText(
                               &reader, field: "name", maximumBytes: Size.maxName),
                           deviceID: try Self.decodeText(
                               &reader, field: "deviceID", maximumBytes: Size.maxDeviceID))

        case .peer:
            frame = .peer(publicKey: try reader.take(Size.publicKey, field: "publicKey"),
                          nonce: try reader.take(Size.nonce, field: "nonce"),
                          name: try Self.decodeText(
                              &reader, field: "name", maximumBytes: Size.maxName),
                          deviceID: try Self.decodeText(
                              &reader, field: "deviceID", maximumBytes: Size.maxDeviceID))

        case .reveal:
            frame = .reveal(nonce: try reader.take(Size.nonce, field: "nonce"))

        case .sealed:
            let encLength = Int(try reader.byte(field: "encapsulatedLength")) << 8
                | Int(try reader.byte(field: "encapsulatedLength"))
            var ciphertextLength = 0
            for _ in 0..<4 {
                ciphertextLength = ciphertextLength << 8 | Int(try reader.byte(field: "ciphertextLength"))
            }
            guard encLength <= Size.maxEncapsulated else {
                throw PairingError.malformed("encapsulated key of \(encLength) bytes exceeds the limit")
            }
            guard ciphertextLength <= Size.maxCiphertext else {
                throw PairingError.malformed("ciphertext of \(ciphertextLength) bytes exceeds the limit")
            }
            frame = .sealed(encapsulated: try reader.take(encLength, field: "encapsulated"),
                            ciphertext: try reader.take(ciphertextLength, field: "ciphertext"))

        case nil:
            throw PairingError.malformed("unknown frame tag \(tag)")
        }

        guard reader.isExhausted else {
            throw PairingError.malformed("\(reader.remaining) unexpected bytes after the frame")
        }
        return frame
    }

    static func normalizedText(_ value: String, maximumBytes: Int) -> String {
        let bytes = Array(value.utf8.prefix(maximumBytes))
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func encodeText(_ value: String, maximumBytes: Int) -> Data {
        // Truncate by UTF-8 bytes, not characters, or a name of emoji would
        // encode longer than the length byte can describe.
        let bytes = Array(normalizedText(value, maximumBytes: maximumBytes).utf8)
        return Data([UInt8(bytes.count)]) + Data(bytes)
    }

    private static func decodeText(
        _ reader: inout Reader,
        field: String,
        maximumBytes: Int
    ) throws -> String {
        let length = Int(try reader.byte(field: "\(field)Length"))
        guard length <= maximumBytes else {
            throw PairingError.malformed("\(field) of \(length) bytes exceeds the limit")
        }
        let bytes = try reader.take(length, field: field)
        // A name that is not valid UTF-8 is a display problem, not a protocol
        // one: refuse the name, not the ceremony.
        return String(data: bytes, encoding: .utf8) ?? "Unknown device"
    }

    private struct Reader {
        private let data: Data
        private var offset: Int

        init(_ data: Data) {
            self.data = data
            self.offset = data.startIndex
        }

        var remaining: Int { data.endIndex - offset }
        var isExhausted: Bool { remaining == 0 }

        mutating func byte(field: String) throws -> UInt8 {
            try take(1, field: field)[0]
        }

        mutating func take(_ count: Int, field: String) throws -> Data {
            guard remaining >= count else {
                throw PairingError.wrongLength(field: field, expected: count, got: remaining)
            }
            defer { offset += count }
            return Data(data[offset..<(offset + count)])
        }
    }
}
