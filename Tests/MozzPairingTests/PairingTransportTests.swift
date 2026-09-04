#if canImport(Network)
import Crypto
import Foundation
import Network
import XCTest
@testable import MozzPairing

/// The ceremony over an actual TCP socket, end to end.
///
/// Discovery is skipped on purpose: the test connects straight to the bound
/// port. Bonjour needs local-network permission, which on macOS is granted per
/// signing identity and is exactly the thing that made artwork mysteriously fail
/// earlier in this project. A test that depends on it would be flaky for reasons
/// that have nothing to do with pairing.
///
/// What this does cover is everything else: two processes' worth of state
/// machines talking through real sockets, real framing, real HPKE, ending with
/// one side holding the circle.
final class PairingTransportTests: XCTestCase {
    private let circle = CircleSecrets(
        channelId: "ch_socket",
        channelKey: Data(repeating: 0xA0, count: 32),
        credentialsKey: Data(repeating: 0xB0, count: 32),
        epoch: 1,
        relayKey: Data("relay".utf8))

    func testAWholeCeremonyOverARealSocket() async throws {
        let host = try PairingHost(advertise: false)
        try await host.start()
        let boundPort = await host.port
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                           port: try XCTUnwrap(NWEndpoint.Port(rawValue: try XCTUnwrap(boundPort))))
        defer { Task { await host.stop() } }

        let joinerKey = Curve25519.KeyAgreement.PrivateKey()
        let memberKey = Curve25519.KeyAgreement.PrivateKey()
        let joinerNonce = Data(repeating: 0xA1, count: 16)
        let scanned = Pairing.QRPayload(publicKey: joinerKey.publicKey.rawRepresentation, nonce: joinerNonce)

        // The member dials in. In the real thing it would have found this device
        // through Bonjour and be checking it against a scanned code.
        async let memberLink = PairingLink.connect(to: endpoint)
        let joinerLink = try await host.nextLink()
        let member = try await memberLink

        var joinerSession = try PairingSession(role: .joiner, path: .qr,
                                               privateKey: joinerKey, nonce: joinerNonce)
        var memberSession = try PairingSession(role: .member, path: .qr,
                                               privateKey: memberKey,
                                               nonce: Data(repeating: 0xB2, count: 16),
                                               scanned: scanned)

        // Joiner opens.
        for step in try joinerSession.start() {
            if case let .send(frame) = step { try await joinerLink.send(frame) }
        }

        // Member answers and is told to seal.
        let hello = try await member.receive()
        let memberSteps = try memberSession.receive(hello)
        var memberTranscript = Data()
        for step in memberSteps {
            switch step {
            case let .send(frame): try await member.send(frame)
            case let .sealCircle(transcript, _): memberTranscript = transcript
            default: break
            }
        }
        XCTAssertFalse(memberTranscript.isEmpty, "the member should have been asked to seal")

        // Joiner takes the answer.
        _ = try joinerSession.receive(try await joinerLink.receive())

        // Member seals and sends.
        let seal = try Pairing.sealCircle(circle,
                                          toJoiner: joinerKey.publicKey.rawRepresentation,
                                          transcriptHash: memberTranscript)
        for step in try memberSession.provideSeal(encapsulated: seal.encapsulated,
                                                  ciphertext: seal.ciphertext) {
            if case let .send(frame) = step { try await member.send(frame) }
        }

        // Joiner opens it and is in the circle.
        let sealedFrame = try await joinerLink.receive()
        let finalSteps = try joinerSession.receive(sealedFrame)
        guard case let .openSeal(encapsulated, ciphertext, transcript) = finalSteps.first else {
            return XCTFail("the joiner was never handed a seal")
        }
        let received = try Pairing.openCircle(encapsulated: encapsulated,
                                              ciphertext: ciphertext,
                                              privateKey: joinerKey,
                                              transcriptHash: transcript)
        XCTAssertEqual(received, circle)

        await joinerLink.close()
        await member.close()
    }

    func testAHostBindsAPortAndAcceptsAConnection() async throws {
        let host = try PairingHost(advertise: false)
        try await host.start()
        let boundPort = await host.port
        let port = try XCTUnwrap(boundPort)
        XCTAssertGreaterThan(port, 0)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                           port: try XCTUnwrap(NWEndpoint.Port(rawValue: port)))
        defer { Task { await host.stop() } }

        async let dialled = PairingLink.connect(to: endpoint)
        let accepted = try await host.nextLink()
        let client = try await dialled

        // A frame sent before either side has said anything else still arrives
        // intact, which is the framing layer doing its job over a real socket
        // rather than over a Data buffer.
        let frame = PairingFrame.reveal(nonce: Data(repeating: 0x5A, count: 16))
        try await client.send(frame)
        let arrived = try await accepted.receive()
        XCTAssertEqual(arrived, frame)

        await client.close()
        await accepted.close()
    }
}
#endif
