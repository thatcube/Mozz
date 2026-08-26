import Crypto
import Foundation

/// Everything a device needs to be in a circle. This is the entire payload of
/// the pairing ceremony — the one moment these values move between machines.
public struct CircleSecrets: Equatable, Sendable, Codable {
    /// Names the channel in the relay. Not a secret; it is in every request path.
    public let channelId: String
    /// Encrypts history, library snapshots, likes and settings.
    public let channelKey: Data
    /// Encrypts `servers/` and nothing else. Belongs in the platform secure
    /// store, which is what makes it a different blast radius rather than a
    /// second name for the same one.
    public let credentialsKey: Data
    /// Bumped when the circle re-keys, per spec/pairing "Rotation".
    public let epoch: Int
    /// The scoped B2 application key from ADR-0012.
    public let relayKey: Data

    public init(channelId: String, channelKey: Data, credentialsKey: Data, epoch: Int, relayKey: Data) {
        self.channelId = channelId
        self.channelKey = channelKey
        self.credentialsKey = credentialsKey
        self.epoch = epoch
        self.relayKey = relayKey
    }
}

extension Pairing {
    /// `Curve25519_SHA256_ChachaPoly`, proven to work off Apple platforms by the
    /// FFI probe rather than assumed (CI run 32934126070). That is why this can
    /// live in the shared core instead of being written once per platform.
    public static let hpkeSuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    /// The bytes the seal is authenticated against.
    ///
    /// Binding the joiner's public key here means a seal cannot be replayed at a
    /// different device even by someone who captured it, because opening it
    /// requires both the matching private key *and* an AAD naming that same key.
    public static func sealAAD(joinerPublicKey: Data) -> Data {
        var aad = Data([version])
        aad.append(joinerPublicKey)
        return aad
    }

    /// The plaintext, as the spec fixes it: JSON with sorted keys.
    ///
    /// Worth being precise about why. This does *not* have to be byte-identical
    /// across implementations for the protocol to work — the ciphertext is
    /// parsed as JSON by whoever opens it, and the AAD does not contain it. It
    /// is pinned so that golden fixtures are possible at all, which is how a
    /// second implementation gets checked before either is trusted.
    static func canonicalJSON(_ secrets: CircleSecrets) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(secrets)
    }

    /// Member side: hand the circle to a joiner whose ceremony just succeeded.
    ///
    /// - Parameter transcriptHash: from the completed ceremony. It goes into the
    ///   HPKE `info`, which is what makes the seal worthless to anyone who did
    ///   not take part in that exact exchange — including a machine-in-the-middle
    ///   that substituted a key, because its transcript differs and the seal will
    ///   not open.
    public static func sealCircle(
        _ secrets: CircleSecrets,
        toJoiner joinerPublicKey: Data,
        transcriptHash: Data
    ) throws -> (encapsulated: Data, ciphertext: Data) {
        guard joinerPublicKey.count == 32 else {
            throw PairingError.wrongLength(field: "joinerPublicKey", expected: 32, got: joinerPublicKey.count)
        }
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: joinerPublicKey)
        var sender = try HPKE.Sender(
            recipientKey: recipient,
            ciphersuite: hpkeSuite,
            info: channelInfo(transcriptHash: transcriptHash)
        )
        let ciphertext = try sender.seal(
            try canonicalJSON(secrets),
            authenticating: sealAAD(joinerPublicKey: joinerPublicKey)
        )
        return (sender.encapsulatedKey, ciphertext)
    }

    /// Joiner side: open what the member sealed, and be in the circle.
    ///
    /// Throws if the transcript disagrees, which is the whole security argument
    /// reduced to a single failure: a ceremony that was tampered with produces a
    /// seal that cannot be opened, so there is no state in which a device joins a
    /// circle it did not verify.
    public static func openCircle(
        encapsulated: Data,
        ciphertext: Data,
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        transcriptHash: Data
    ) throws -> CircleSecrets {
        var recipient = try HPKE.Recipient(
            privateKey: privateKey,
            ciphersuite: hpkeSuite,
            info: channelInfo(transcriptHash: transcriptHash),
            encapsulatedKey: encapsulated
        )
        let plaintext = try recipient.open(
            ciphertext,
            authenticating: sealAAD(joinerPublicKey: privateKey.publicKey.rawRepresentation)
        )
        return try JSONDecoder().decode(CircleSecrets.self, from: plaintext)
    }
}
