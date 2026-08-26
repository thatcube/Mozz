import Foundation
import XCTest
@testable import MozzPairing

/// Framing bugs do not show up in a happy-path test, because on a fast local
/// network a small frame usually arrives in one piece. They show up later, on a
/// worse network, as a hang. So these deliberately deliver bytes in the awkward
/// shapes a real socket produces.
final class PairingWireTests: XCTestCase {
    private func payload(_ byte: UInt8, _ count: Int) -> Data { Data(repeating: byte, count: count) }

    func testAWholeFrameInOneRead() throws {
        var wire = PairingWire()
        let body = payload(0xAA, 40)
        XCTAssertEqual(try wire.append(PairingWire.frame(body)), [body])
        XCTAssertEqual(wire.pendingByteCount, 0)
    }

    func testAFrameSplitAcrossTwoReads() throws {
        var wire = PairingWire()
        let framed = PairingWire.frame(payload(0xBB, 100))
        let half = framed.count / 2

        XCTAssertEqual(try wire.append(framed.prefix(half)), [], "half a frame is not a frame")
        XCTAssertEqual(try wire.append(framed.suffix(from: framed.startIndex + half)).count, 1)
    }

    func testALengthPrefixSplitDownTheMiddle() throws {
        var wire = PairingWire()
        let framed = PairingWire.frame(payload(0xCC, 10))
        // Two bytes of the length, then everything else. A reader that assumes
        // it can always see the whole prefix at once corrupts here.
        XCTAssertEqual(try wire.append(framed.prefix(2)), [])
        XCTAssertEqual(try wire.append(framed.dropFirst(2)), [payload(0xCC, 10)])
    }

    func testTwoFramesInOneRead() throws {
        var wire = PairingWire()
        var combined = PairingWire.frame(payload(0x01, 8))
        combined.append(PairingWire.frame(payload(0x02, 12)))
        XCTAssertEqual(try wire.append(combined), [payload(0x01, 8), payload(0x02, 12)])
    }

    func testAFrameAndAHalf() throws {
        var wire = PairingWire()
        let second = PairingWire.frame(payload(0x02, 30))
        var combined = PairingWire.frame(payload(0x01, 8))
        combined.append(second.prefix(10))

        XCTAssertEqual(try wire.append(combined), [payload(0x01, 8)])
        XCTAssertEqual(wire.pendingByteCount, 10, "the leftover must be kept, not dropped")
        XCTAssertEqual(try wire.append(second.dropFirst(10)), [payload(0x02, 30)])
    }

    func testByteAtATime() throws {
        var wire = PairingWire()
        let framed = PairingWire.frame(payload(0xDD, 64))
        var delivered: [Data] = []
        for byte in framed {
            delivered += try wire.append(Data([byte]))
        }
        XCTAssertEqual(delivered, [payload(0xDD, 64)], "the worst case a real socket can produce")
    }

    func testAnEmptyFrameIsStillAFrame() throws {
        var wire = PairingWire()
        XCTAssertEqual(try wire.append(PairingWire.frame(Data())), [Data()])
    }

    func testEmptyReadsChangeNothing() throws {
        var wire = PairingWire()
        XCTAssertEqual(try wire.append(Data()), [])
        XCTAssertEqual(try wire.append(PairingWire.frame(payload(0x01, 4))), [payload(0x01, 4)])
    }

    func testAnOversizedLengthIsRefusedBeforeBuffering() {
        var wire = PairingWire()
        // Claims 4 GiB. A reader that waits for it to arrive holds the buffer
        // open forever; one that reserves it first falls over immediately.
        XCTAssertThrowsError(try wire.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))) { error in
            guard case let .frameTooLarge(length) = error as? PairingWire.WireError else {
                return XCTFail("expected frameTooLarge, got \(error)")
            }
            XCTAssertEqual(length, 0xFFFF_FFFF)
        }
    }

    func testRealPairingFramesSurviveTheWire() throws {
        var wire = PairingWire()
        let sent: [PairingFrame] = [
            .hello(version: 1, publicKey: payload(0x11, 32), commitment: payload(0x22, 32)),
            .peer(publicKey: payload(0x33, 32), nonce: payload(0x44, 16)),
            .reveal(nonce: payload(0x55, 16)),
            .sealed(encapsulated: payload(0x66, 32), ciphertext: payload(0x77, 91)),
        ]
        var stream = Data()
        for frame in sent { stream.append(PairingWire.frame(frame.encoded())) }

        // Delivered in 7-byte chunks, which lands mid-frame repeatedly.
        var received: [PairingFrame] = []
        var offset = stream.startIndex
        while offset < stream.endIndex {
            let end = stream.index(offset, offsetBy: 7, limitedBy: stream.endIndex) ?? stream.endIndex
            for payload in try wire.append(Data(stream[offset..<end])) {
                received.append(try PairingFrame.decode(payload))
            }
            offset = end
        }
        XCTAssertEqual(received, sent)
        XCTAssertEqual(wire.pendingByteCount, 0)
    }
}
