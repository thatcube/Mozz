import Crypto
import Foundation
import XCTest

@testable import MozzPairing

/// The pairing contract, checked against `spec/pairing/pairing-fixtures.json`.
///
/// These are byte comparisons on purpose. An implementation that reaches the
/// right answer by a different route is fine; one that agrees on six cases and
/// disagrees on the seventh is the thing fixtures exist to catch, and the
/// seventh is usually the one nobody thought to try.
final class PairingFixtureTests: XCTestCase {
    private struct Fixtures: Decodable {
        struct Case: Decodable {
            let name: String
            let note: String
            let input: [String: String]
            let expected: String
        }
        let cases: [Case]
    }

    private func fixtures() throws -> Fixtures {
        // Walk up from this file rather than assuming a working directory,
        // because `swift test` and Xcode disagree about what that is.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("spec/pairing/pairing-fixtures.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: candidate))
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("spec/pairing/pairing-fixtures.json not found")
    }

    private func hex(_ s: String) -> Data {
        var out = Data()
        var i = s.startIndex
        while i < s.endIndex, let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex) {
            out.append(UInt8(s[i..<j], radix: 16) ?? 0)
            i = j
        }
        return out
    }

    /// Run every case in the file. A new case in the spec fails here until it is
    /// handled, which is the point: the fixture file is the source of truth and
    /// this test is what makes ignoring it impossible.
    func testEveryFixtureCaseMatches() throws {
        for c in try fixtures().cases {
            switch c.name {
            case "qr-payload-canonical":
                let encoded = try Pairing.encodeQR(
                    .init(publicKey: hex(c.input["publicKey"]!), nonce: hex(c.input["nonce"]!)))
                XCTAssertEqual(encoded, c.expected, "\(c.name): \(c.note)")

                // And it must survive a round trip, or a reader on another
                // platform could accept something this encoder never produces.
                let back = try Pairing.decodeQR(encoded)
                XCTAssertEqual(back.publicKey, hex(c.input["publicKey"]!))
                XCTAssertEqual(back.nonce, hex(c.input["nonce"]!))

            case "commit-binding":
                let commit = Pairing.commitment(nonceA: hex(c.input["nonceA"]!))
                XCTAssertEqual(commit.map { String(format: "%02x", $0) }.joined(), c.expected,
                               "\(c.name): \(c.note)")

            case "transcript-order", "transcript-swapped":
                let t = try Pairing.transcriptHash(
                    joinerPublicKey: hex(c.input["joinerPublicKey"]!),
                    memberPublicKey: hex(c.input["memberPublicKey"]!),
                    joinerDeviceID: c.input["joinerDeviceID"]!,
                    memberDeviceID: c.input["memberDeviceID"]!,
                    joinerName: c.input["joinerName"]!,
                    memberName: c.input["memberName"]!,
                    nonceA: hex(c.input["nonceA"]!),
                    nonceB: hex(c.input["nonceB"]!))
                XCTAssertEqual(t.map { String(format: "%02x", $0) }.joined(), c.expected,
                               "\(c.name): \(c.note)")

            case "sas-digits-basic", "sas-digits-leading-zeros":
                let d = Pairing.digits(
                    sharedSecret: hex(c.input["sharedSecret"]!),
                    transcriptHash: hex(c.input["transcriptHash"]!))
                XCTAssertEqual(d, c.expected, "\(c.name): \(c.note)")

            case "sas-digits-rejection":
                // The case that matters. The stream's first word is above the
                // limit and MUST be discarded; an implementation that reduces it
                // anyway passes every other case here and is biased forever.
                let value = Pairing.uniformValue(from: Array(hex(c.input["stream"]!)))
                XCTAssertEqual(String(format: "%06u", value), c.expected, "\(c.name): \(c.note)")

            case "channel-info-binding":
                let info = Pairing.channelInfo(transcriptHash: hex(c.input["transcriptHash"]!))
                XCTAssertEqual(info.map { String(format: "%02x", $0) }.joined(), c.expected,
                               "\(c.name): \(c.note)")

            default:
                XCTFail("fixture case '\(c.name)' has no handler — add one rather than ignoring it")
            }
        }
    }

    // MARK: Properties the fixtures cannot express

    /// Swapping the two keys must change the digits, or the transcript is not
    /// actually binding who is who.
    func testSwappingTheKeysChangesTheTranscript() throws {
        let a = Data(repeating: 0x11, count: 32)
        let b = Data(repeating: 0x22, count: 32)
        let n1 = Data(repeating: 0xAA, count: 16)
        let n2 = Data(repeating: 0xBB, count: 16)

        let forward = try Pairing.transcriptHash(
            joinerPublicKey: a, memberPublicKey: b,
            joinerDeviceID: "a", memberDeviceID: "b",
            joinerName: "A", memberName: "B",
            nonceA: n1, nonceB: n2)
        let swapped = try Pairing.transcriptHash(
            joinerPublicKey: b, memberPublicKey: a,
            joinerDeviceID: "a", memberDeviceID: "b",
            joinerName: "A", memberName: "B",
            nonceA: n1, nonceB: n2)

        XCTAssertNotEqual(forward, swapped, "the transcript must bind which side is which")
    }

    func testChangingADeviceIdentityChangesTheTranscript() throws {
        let key = Data(repeating: 0x11, count: 32)
        let nonce = Data(repeating: 0xAA, count: 16)
        let baseline = try Pairing.transcriptHash(
            joinerPublicKey: key, memberPublicKey: key,
            joinerDeviceID: "phone-id", memberDeviceID: "pc-id",
            joinerName: "Brandon's iPhone", memberName: "Gaming PC",
            nonceA: nonce, nonceB: nonce)
        let relabelled = try Pairing.transcriptHash(
            joinerPublicKey: key, memberPublicKey: key,
            joinerDeviceID: "phone-id", memberDeviceID: "pc-id",
            joinerName: "Brandon's iPhone", memberName: "Brandon's MacBook",
            nonceA: nonce, nonceB: nonce)
        let impersonated = try Pairing.transcriptHash(
            joinerPublicKey: key, memberPublicKey: key,
            joinerDeviceID: "phone-id", memberDeviceID: "other-id",
            joinerName: "Brandon's iPhone", memberName: "Gaming PC",
            nonceA: nonce, nonceB: nonce)

        XCTAssertNotEqual(baseline, relabelled,
                          "a recognisable name cannot be substituted without changing digits")
        XCTAssertNotEqual(baseline, impersonated,
                          "relay ownership cannot be substituted without changing digits")
    }

    /// A truncated code must be refused rather than parsed. Accepting a short
    /// read would pair against a partial key.
    func testATruncatedCodeIsRefused() throws {
        let good = try Pairing.encodeQR(
            .init(publicKey: Data(repeating: 7, count: 32), nonce: Data(repeating: 9, count: 16)))
        let truncated = String(good.dropLast(4))
        XCTAssertThrowsError(try Pairing.decodeQR(truncated))
    }

    func testSomethingThatIsNotAMozzCodeIsRefused() {
        XCTAssertThrowsError(try Pairing.decodeQR("https://example.com")) { error in
            XCTAssertEqual(error as? PairingError, .notAMozzCode)
        }
    }

    /// A newer version must be refused clearly rather than misparsed, so an old
    /// build tells the user to update instead of failing strangely.
    func testAFutureVersionIsRefusedByVersion() throws {
        var body = Data([0x02, Pairing.Role.joiner.rawValue])
        body.append(Data(repeating: 1, count: 32))
        body.append(Data(repeating: 2, count: 16))
        let text = "MOZZ1:" + Pairing.base64URLNoPadding(body)

        XCTAssertThrowsError(try Pairing.decodeQR(text)) { error in
            XCTAssertEqual(error as? PairingError, .unsupportedVersion(0x02))
        }
    }

    /// The encoding must never emit padding, because a QR encoder that strips
    /// `=` would otherwise produce something that parses on one platform only.
    func testTheEncodingCarriesNoPadding() throws {
        let text = try Pairing.encodeQR(
            .init(publicKey: Data(repeating: 3, count: 32), nonce: Data(repeating: 4, count: 16)))
        XCTAssertFalse(text.contains("="), "padding would not survive some QR encoders")
    }

    /// Rejection sampling has to actually reject. Over many draws the digits
    /// must cover the range rather than clustering, which is the observable
    /// consequence of getting the uniformity wrong.
    func testDigitsAreSixCharactersAndVary() {
        var seen = Set<String>()
        for i in 0..<200 {
            let secret = Data((0..<32).map { UInt8(($0 &+ i) & 0xFF) })
            let d = Pairing.digits(sharedSecret: secret, transcriptHash: Data(repeating: 0x5A, count: 32))
            XCTAssertEqual(d.count, 6, "digits must always render as six characters")
            seen.insert(d)
        }
        XCTAssertGreaterThan(seen.count, 150, "digits should vary with the secret")
    }
}
