import Crypto
import Foundation
import XCTest
@testable import MozzPairing

/// These drive both roles against each other in memory, which is the only way to
/// check the thing that actually matters: that two independent state machines
/// agree. A test that drives one side and asserts against hand-written expected
/// bytes proves the implementation matches itself.
final class PairingSessionTests: XCTestCase {
    private func nonce(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: PairingFrame.Size.nonce)
    }

    private func sessions(
        path: PairingPath,
        scanned: Pairing.QRPayload? = nil
    ) throws -> (joiner: PairingSession, member: PairingSession, joinerKey: Curve25519.KeyAgreement.PrivateKey) {
        let joinerKey = Curve25519.KeyAgreement.PrivateKey()
        let memberKey = Curve25519.KeyAgreement.PrivateKey()
        let joinerNonce = nonce(0xA1)

        let resolvedScan = scanned ?? Pairing.QRPayload(
            publicKey: joinerKey.publicKey.rawRepresentation, nonce: joinerNonce)

        let joiner = try PairingSession(role: .joiner, path: path,
                                        privateKey: joinerKey, nonce: joinerNonce)
        let member = try PairingSession(role: .member, path: path,
                                        privateKey: memberKey, nonce: nonce(0xB2),
                                        scanned: path == .qr ? resolvedScan : nil)
        return (joiner, member, joinerKey)
    }

    private func frames(_ steps: [PairingStep]) -> [PairingFrame] {
        steps.compactMap { if case let .send(frame) = $0 { return frame } else { return nil } }
    }

    private func digits(_ steps: [PairingStep]) -> [String] {
        steps.compactMap { if case let .compareDigits(value) = $0 { return value } else { return nil } }
    }

    // MARK: - Whole ceremonies

    func testQRCeremonyReachesOneAgreedTranscript() throws {
        var (joiner, member, _) = try sessions(path: .qr)

        let hello = frames(try joiner.start())
        XCTAssertEqual(hello.count, 1)

        let memberSteps = try member.receive(hello[0])
        _ = try joiner.receive(frames(memberSteps)[0])

        // The member is told to seal, and hands back the transcript it derived.
        guard case let .sealCircle(memberTranscript, joinerKey) = memberSteps.last else {
            return XCTFail("the member should have been asked to seal, got \(String(describing: memberSteps.last))")
        }
        XCTAssertEqual(joinerKey, joiner.ownPublicKey)

        let sealed = frames(try member.provideSeal(encapsulated: Data(repeating: 0xEE, count: 32),
                                                   ciphertext: Data(repeating: 0xCC, count: 64)))
        let opened = try joiner.receive(sealed[0])

        guard case let .openSeal(_, _, joinerTranscript) = opened.first else {
            return XCTFail("the joiner should have been handed a seal to open")
        }
        // The point of the whole exchange: two machines that never shared state
        // derived the same transcript.
        XCTAssertEqual(joinerTranscript, memberTranscript)
        XCTAssertTrue(opened.contains(.finished))

        // No digits anywhere on the QR path — the camera already did that job.
        XCTAssertTrue(digits(opened).isEmpty)
        XCTAssertTrue(digits(memberSteps).isEmpty)
    }

    func testDigitCeremonyShowsBothHumansTheSameSixDigits() throws {
        var (joiner, member, _) = try sessions(path: .digits)

        let hello = frames(try joiner.start())
        let memberAnswer = try member.receive(hello[0])
        let joinerSteps = try joiner.receive(frames(memberAnswer)[0])

        let joinerDigits = digits(joinerSteps)
        XCTAssertEqual(joinerDigits.count, 1)

        let reveal = frames(joinerSteps).first { if case .reveal = $0 { return true } else { return false } }
        let memberSteps = try member.receive(try XCTUnwrap(reveal))
        let memberDigits = digits(memberSteps)

        XCTAssertEqual(joinerDigits, memberDigits, "both people must be reading the same number")
        XCTAssertEqual(try XCTUnwrap(joinerDigits.first).count, 6)

        _ = try joiner.confirmDigits()
        let sealSteps = try member.confirmDigits()
        guard case .sealCircle = sealSteps.first else {
            return XCTFail("confirming should let the member seal")
        }
    }

    // MARK: - The ordering rule

    func testMemberComputesNoDigitsWhenTheCommitmentIsWrong() throws {
        var (joiner, member, _) = try sessions(path: .digits)
        let hello = frames(try joiner.start())
        _ = try member.receive(hello[0])

        // A nonce that is not the one committed to.
        XCTAssertThrowsError(try member.receive(.reveal(nonce: nonce(0xFF)))) { error in
            XCTAssertEqual(error as? PairingSessionError, .commitmentMismatch)
        }
    }

    func testAFailedCommitmentEndsTheSessionRatherThanRetrying() throws {
        var (joiner, member, _) = try sessions(path: .digits)
        let hello = frames(try joiner.start())
        _ = try member.receive(hello[0])
        XCTAssertThrowsError(try member.receive(.reveal(nonce: nonce(0xFF))))

        // The correct nonce afterwards must not rescue it. Otherwise an attacker
        // simply guesses until something sticks.
        XCTAssertThrowsError(try member.receive(.reveal(nonce: nonce(0xA1))))
    }

    // MARK: - Impostors and mistakes

    func testQRMemberRefusesADeviceItDidNotScan() throws {
        let scannedFor = Curve25519.KeyAgreement.PrivateKey()
        var (joiner, member, _) = try sessions(
            path: .qr,
            scanned: Pairing.QRPayload(publicKey: scannedFor.publicKey.rawRepresentation,
                                       nonce: nonce(0xA1)))
        let hello = frames(try joiner.start())

        XCTAssertThrowsError(try member.receive(hello[0])) { error in
            XCTAssertEqual(error as? PairingSessionError, .wrongDevice)
        }
    }

    func testACommitmentOnTheQRPathIsRefused() throws {
        var (_, member, joinerKey) = try sessions(path: .qr)
        let hello = PairingFrame.hello(version: Pairing.version,
                                       publicKey: joinerKey.publicKey.rawRepresentation,
                                       commitment: Pairing.commitment(nonceA: nonce(0xA1)), name: "x")
        XCTAssertThrowsError(try member.receive(hello)) { error in
            guard case .pathMismatch = error as? PairingSessionError else {
                return XCTFail("expected a path mismatch, got \(error)")
            }
        }
    }

    func testAMissingCommitmentOnTheDigitPathIsRefused() throws {
        var (_, member, joinerKey) = try sessions(path: .digits)
        let hello = PairingFrame.hello(version: Pairing.version,
                                       publicKey: joinerKey.publicKey.rawRepresentation,
                                       commitment: nil, name: "x")
        XCTAssertThrowsError(try member.receive(hello)) { error in
            guard case .pathMismatch = error as? PairingSessionError else {
                return XCTFail("expected a path mismatch, got \(error)")
            }
        }
    }

    func testASealCannotArriveBeforeTheHandshake() throws {
        var (joiner, _, _) = try sessions(path: .qr)
        _ = try joiner.start()
        XCTAssertThrowsError(try joiner.receive(.sealed(encapsulated: Data(repeating: 1, count: 32),
                                                        ciphertext: Data(repeating: 2, count: 32)))) { error in
            guard case .outOfOrder = error as? PairingSessionError else {
                return XCTFail("expected an ordering failure, got \(error)")
            }
        }
    }

    func testAnUnknownVersionIsRefused() throws {
        var (_, member, joinerKey) = try sessions(path: .digits)
        let hello = PairingFrame.hello(version: 0x99,
                                       publicKey: joinerKey.publicKey.rawRepresentation,
                                       commitment: Pairing.commitment(nonceA: nonce(0xA1)), name: "x")
        XCTAssertThrowsError(try member.receive(hello)) { error in
            XCTAssertEqual(error as? PairingSessionError, .unsupportedVersion(0x99))
        }
    }

    func testOnlyAJoinerStarts() throws {
        var (_, member, _) = try sessions(path: .digits)
        XCTAssertThrowsError(try member.start())
    }

    func testAMemberOnTheQRPathMustSayWhatItScanned() {
        XCTAssertThrowsError(try PairingSession(role: .member, path: .qr,
                                                privateKey: .init(), nonce: nonce(0xB2)))
    }
}
