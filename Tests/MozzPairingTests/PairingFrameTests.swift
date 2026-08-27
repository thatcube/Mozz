import Foundation
import XCTest
@testable import MozzPairing

/// The codec is what a second implementation has to match byte for byte, so
/// these check the refusals as much as the round trips. A parser that accepts
/// more than the spec allows is how two implementations quietly diverge.
final class PairingFrameTests: XCTestCase {
    private func data(_ byte: UInt8, _ count: Int) -> Data { Data(repeating: byte, count: count) }

    func testEveryFrameSurvivesARoundTrip() throws {
        let cases: [PairingFrame] = [
            .hello(version: Pairing.version, publicKey: data(0x11, 32), commitment: nil,
                   name: "iPhone", deviceID: "phone-id"),
            .hello(version: Pairing.version, publicKey: data(0x11, 32), commitment: data(0x22, 32),
                   name: "iPhone", deviceID: "phone-id"),
            .peer(publicKey: data(0x33, 32), nonce: data(0x44, 16),
                  name: "MacBook", deviceID: "mac-id"),
            .reveal(nonce: data(0x55, 16)),
            .sealed(encapsulated: data(0x66, 32), ciphertext: data(0x77, 91)),
        ]
        for frame in cases {
            XCTAssertEqual(try PairingFrame.decode(frame.encoded()), frame, "\(frame) did not survive")
        }
    }

    func testAnEmptyCiphertextStillRoundTrips() throws {
        let frame = PairingFrame.sealed(encapsulated: data(0x01, 32), ciphertext: Data())
        XCTAssertEqual(try PairingFrame.decode(frame.encoded()), frame)
    }

    func testTrailingBytesAreRefused() {
        var encoded = PairingFrame.reveal(nonce: data(0x55, 16)).encoded()
        encoded.append(0x00)
        XCTAssertThrowsError(try PairingFrame.decode(encoded)) { error in
            guard case .malformed = error as? PairingError else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testATruncatedFrameIsRefused() {
        let encoded = PairingFrame.peer(
            publicKey: data(0x33, 32),
            nonce: data(0x44, 16),
            name: "MacBook",
            deviceID: "mac-id").encoded()
        XCTAssertThrowsError(try PairingFrame.decode(encoded.dropLast()))
    }

    func testALegacyHelloIsRefusedBeforeParsingItsOldShape() {
        XCTAssertThrowsError(try PairingFrame.decode(Data([0x01, 0x01]))) { error in
            XCTAssertEqual(error as? PairingError, .unsupportedVersion(0x01))
        }
    }

    func testAnUnknownTagIsRefused() {
        XCTAssertThrowsError(try PairingFrame.decode(Data([0x7F])))
    }

    func testAnAbsurdCiphertextLengthIsRefusedBeforeAllocating() {
        // Claims 4 GiB while carrying nothing. A decoder that trusts the length
        // and allocates first is a denial of service on a phone.
        var encoded = Data([0x04, 0x00, 0x20])
        encoded.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        encoded.append(data(0x01, 32))
        XCTAssertThrowsError(try PairingFrame.decode(encoded)) { error in
            guard case let .malformed(message) = error as? PairingError else {
                return XCTFail("expected malformed, got \(error)")
            }
            XCTAssertTrue(message.contains("exceeds"), "expected a limit message, got \(message)")
        }
    }

    func testAnAbsurdEncapsulatedLengthIsRefused() {
        var encoded = Data([0x04, 0xFF, 0xFF])
        encoded.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try PairingFrame.decode(encoded))
    }

    func testTheCommitmentFlagMustBeZeroOrOne() {
        var encoded = Data([0x01, Pairing.version])
        encoded.append(data(0x11, 32))
        encoded.append(0x02)
        encoded.append(0x00)
        XCTAssertThrowsError(try PairingFrame.decode(encoded))
    }

    func testHelloWithAndWithoutACommitmentDifferInLength() {
        let bare = PairingFrame.hello(
            version: Pairing.version, publicKey: data(0x11, 32), commitment: nil,
            name: "iPhone", deviceID: "phone-id").encoded()
        let full = PairingFrame.hello(
            version: Pairing.version, publicKey: data(0x11, 32), commitment: data(0x22, 32),
            name: "iPhone", deviceID: "phone-id").encoded()
        // Previous fixed fields, then length-prefixed name and id.
        XCTAssertEqual(bare.count, 35 + 7 + 9)
        XCTAssertEqual(full.count, 67 + 7 + 9)
    }
}
