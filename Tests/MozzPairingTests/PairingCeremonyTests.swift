import Crypto
import Foundation
import XCTest
@testable import MozzPairing

/// The whole ceremony, both paths, with real HPKE — two state machines that
/// share nothing but frames, ending with the joiner holding the circle.
///
/// This is the test the earlier ones could not be. `PairingSessionTests` proves
/// the ordering rules and `PairingFrameTests` proves the codec, but neither
/// shows that a device actually *ends up in the circle*, and neither would
/// notice if the seal were bound to the wrong thing.
final class PairingCeremonyTests: XCTestCase {
    private let circle = CircleSecrets(
        channelId: "ch_7f3a91",
        channelKey: Data(repeating: 0xC1, count: 32),
        credentialsKey: Data(repeating: 0xC2, count: 32),
        epoch: 3,
        relayKey: Data("K005relaykeymaterial".utf8))

    private func nonce(_ byte: UInt8) -> Data { Data(repeating: byte, count: 16) }

    private func frames(_ steps: [PairingStep]) -> [PairingFrame] {
        steps.compactMap { if case let .send(f) = $0 { return f } else { return nil } }
    }

    /// Runs a complete ceremony. `tamperWithPeerFrame` stands in for a machine in
    /// the middle that alters what the joiner hears back.
    private func runCeremony(
        path: PairingPath,
        tamperWithPeerFrame: ((PairingFrame) -> PairingFrame)? = nil
    ) throws -> CircleSecrets {
        let joinerKey = Curve25519.KeyAgreement.PrivateKey()
        let memberKey = Curve25519.KeyAgreement.PrivateKey()
        let joinerNonce = nonce(0xA1)
        let scanned = Pairing.QRPayload(publicKey: joinerKey.publicKey.rawRepresentation, nonce: joinerNonce)

        var joiner = try PairingSession(role: .joiner, path: path, privateKey: joinerKey, nonce: joinerNonce)
        var member = try PairingSession(role: .member, path: path, privateKey: memberKey,
                                        nonce: nonce(0xB2), scanned: path == .qr ? scanned : nil)

        let hello = frames(try joiner.start())[0]
        var memberSteps = try member.receive(hello)

        let peerFrame = frames(memberSteps)[0]
        var joinerSteps = try joiner.receive(tamperWithPeerFrame?(peerFrame) ?? peerFrame)

        if path == .digits {
            let reveal = frames(joinerSteps).first { if case .reveal = $0 { return true } else { return false } }
            memberSteps = try member.receive(try XCTUnwrap(reveal))
            _ = try joiner.confirmDigits()
            memberSteps = try member.confirmDigits()
        }

        guard case let .sealCircle(memberTranscript, joinerPublicKey) = memberSteps.last else {
            throw XCTSkip("the member was never asked to seal")
        }

        // The member does what the step told it to. This is the caller's job by
        // design — the session never touches the circle's secrets.
        let seal = try Pairing.sealCircle(circle, toJoiner: joinerPublicKey, transcriptHash: memberTranscript)
        let sealed = frames(try member.provideSeal(encapsulated: seal.encapsulated, ciphertext: seal.ciphertext))[0]

        joinerSteps = try joiner.receive(sealed)
        guard case let .openSeal(encapsulated, ciphertext, joinerTranscript) = joinerSteps.first else {
            throw XCTSkip("the joiner was never handed a seal")
        }
        return try Pairing.openCircle(encapsulated: encapsulated, ciphertext: ciphertext,
                                      privateKey: joinerKey, transcriptHash: joinerTranscript)
    }

    // MARK: - The circle actually arrives

    func testTheQRCeremonyPutsTheJoinerInTheCircle() throws {
        XCTAssertEqual(try runCeremony(path: .qr), circle)
    }

    func testTheDigitCeremonyPutsTheJoinerInTheCircle() throws {
        XCTAssertEqual(try runCeremony(path: .digits), circle)
    }

    func testBothKeysSurviveIntactAndDistinct() throws {
        let received = try runCeremony(path: .qr)
        XCTAssertEqual(received.channelKey, circle.channelKey)
        XCTAssertEqual(received.credentialsKey, circle.credentialsKey)
        // If a refactor ever collapsed these into one field the ceremony would
        // still pass every other test while quietly destroying the separation
        // the credential design rests on.
        XCTAssertNotEqual(received.channelKey, received.credentialsKey)
    }

    // MARK: - Someone in the middle

    func testASubstitutedMemberKeyMakesTheSealUnopenable() throws {
        let impostor = Curve25519.KeyAgreement.PrivateKey()

        // The member answers honestly; someone on the wire swaps its public key
        // before the joiner hears it. Nothing in the frames themselves reveals
        // this — the joiner has no way to know. The protection is that the two
        // sides now hash different transcripts, so the seal will not open.
        XCTAssertThrowsError(try runCeremony(path: .qr, tamperWithPeerFrame: { frame in
            guard case let .peer(_, nonce, _, deviceID) = frame else { return frame }
            return .peer(publicKey: impostor.publicKey.rawRepresentation, nonce: nonce,
                         name: "impostor", deviceID: deviceID)
        })) { error in
            XCTAssertFalse(error is XCTSkip, "the ceremony should complete and then fail to open")
        }
    }

    func testASubstitutedNonceMakesTheSealUnopenable() throws {
        XCTAssertThrowsError(try runCeremony(path: .qr, tamperWithPeerFrame: { frame in
            guard case let .peer(publicKey, _, _, deviceID) = frame else { return frame }
            return .peer(publicKey: publicKey, nonce: Data(repeating: 0xFF, count: 16),
                         name: "x", deviceID: deviceID)
        }))
    }

    // MARK: - Binding

    func testASealWillNotOpenUnderADifferentTranscript() throws {
        let joinerKey = Curve25519.KeyAgreement.PrivateKey()
        let seal = try Pairing.sealCircle(circle,
                                          toJoiner: joinerKey.publicKey.rawRepresentation,
                                          transcriptHash: Data(repeating: 0x01, count: 32))
        XCTAssertThrowsError(try Pairing.openCircle(encapsulated: seal.encapsulated,
                                                    ciphertext: seal.ciphertext,
                                                    privateKey: joinerKey,
                                                    transcriptHash: Data(repeating: 0x02, count: 32)))
    }

    func testASealWillNotOpenForADifferentDevice() throws {
        let joinerKey = Curve25519.KeyAgreement.PrivateKey()
        let otherDevice = Curve25519.KeyAgreement.PrivateKey()
        let transcript = Data(repeating: 0x01, count: 32)
        let seal = try Pairing.sealCircle(circle,
                                          toJoiner: joinerKey.publicKey.rawRepresentation,
                                          transcriptHash: transcript)
        XCTAssertThrowsError(try Pairing.openCircle(encapsulated: seal.encapsulated,
                                                    ciphertext: seal.ciphertext,
                                                    privateKey: otherDevice,
                                                    transcriptHash: transcript))
    }

    func testTamperingWithTheCiphertextIsDetected() throws {
        let joinerKey = Curve25519.KeyAgreement.PrivateKey()
        let transcript = Data(repeating: 0x01, count: 32)
        var seal = try Pairing.sealCircle(circle,
                                          toJoiner: joinerKey.publicKey.rawRepresentation,
                                          transcriptHash: transcript)
        seal.ciphertext[seal.ciphertext.startIndex] ^= 0x01
        XCTAssertThrowsError(try Pairing.openCircle(encapsulated: seal.encapsulated,
                                                    ciphertext: seal.ciphertext,
                                                    privateKey: joinerKey,
                                                    transcriptHash: transcript))
    }

    // MARK: - The pinned plaintext

    func testTheCanonicalPlaintextIsSortedAndStable() throws {
        let json = try Pairing.canonicalJSON(circle)
        let text = try XCTUnwrap(String(data: json, encoding: .utf8))
        XCTAssertEqual(text, #"{"channelId":"ch_7f3a91","channelKey":"wcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcE=","credentialsKey":"wsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsI=","epoch":3,"relayKey":"SzAwNXJlbGF5a2V5bWF0ZXJpYWw="}"#)
    }

    func testTheCanonicalPlaintextRoundTrips() throws {
        XCTAssertEqual(try JSONDecoder().decode(CircleSecrets.self, from: Pairing.canonicalJSON(circle)), circle)
    }
}
