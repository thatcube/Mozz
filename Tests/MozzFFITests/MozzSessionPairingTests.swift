import Foundation
import XCTest
@testable import MozzFFI

/// A whole pairing ceremony driven only through the JSON command surface —
/// which is all a Windows or Android client has.
///
/// The point is not that pairing works; `MozzPairingTests` already shows that
/// against the Swift types. The point is that a host with **no Swift types at
/// all** can complete one, because otherwise the desktop would need a second
/// implementation of the protocol and the HPKE, and the two would have to agree
/// byte for byte forever.
final class MozzSessionPairingTests: XCTestCase {

    /// Sends a command the way a host does: JSON in, JSON out.
    private func call(_ body: [String: Any]) async throws -> [String: Any] {
        var payload = body
        payload["id"] = payload["id"] ?? 1
        let data = try JSONSerialization.data(withJSONObject: payload)
        let request = try JSONDecoder().decode(SessionRequest.self, from: data)

        guard let responseText = try await dispatchPairingCommand(request) else {
            XCTFail("\(body["cmd"] ?? "?") was not recognised as a pairing command")
            return [:]
        }
        let response = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(responseText.utf8)) as? [String: Any])
        return response
    }

    private func payload(_ response: [String: Any]) throws -> [String: Any] {
        if response["ok"] as? Bool != true {
            throw NSError(domain: "pairing", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: response["error"] as? String ?? "failed"])
        }
        return try XCTUnwrap(response["payload"] as? [String: Any])
    }

    private func steps(_ response: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(try payload(response)["steps"] as? [[String: Any]])
    }

    private let circle: [String: Any] = [
        "channelId": "ch_ffi",
        "channelKey": Data(repeating: 0xA1, count: 32).base64EncodedString(),
        "credentialsKey": Data(repeating: 0xB2, count: 32).base64EncodedString(),
        "epoch": 5,
        "relayKey": Data("relay-key".utf8).base64EncodedString(),
    ]

    func testAHostWithNoSwiftTypesCanCompleteAQRCeremony() async throws {
        // The joining device asks for a code.
        let joinerBegan = try payload(try await call(["cmd": "pairingBegin", "role": "joiner", "pairingPath": "qr"]))
        let joinerId = try XCTUnwrap(joinerBegan["pairingId"] as? String)
        let qrText = try XCTUnwrap(joinerBegan["qrText"] as? String)
        let hello = try XCTUnwrap((joinerBegan["steps"] as? [[String: Any]])?.first?["frame"] as? String)

        // The member scans it.
        let memberBegan = try payload(try await call([
            "cmd": "pairingBegin", "role": "member", "pairingPath": "qr", "scannedCode": qrText,
        ]))
        let memberId = try XCTUnwrap(memberBegan["pairingId"] as? String)

        // Member takes the hello and is told to answer and to seal.
        let memberSteps = try steps(try await call([
            "cmd": "pairingReceive", "pairingId": memberId, "frame": hello,
        ]))
        let answer = try XCTUnwrap(memberSteps.first { $0["kind"] as? String == "send" }?["frame"] as? String)
        let sealStep = try XCTUnwrap(memberSteps.first { $0["kind"] as? String == "seal" })

        // Joiner takes the answer.
        _ = try steps(try await call(["cmd": "pairingReceive", "pairingId": joinerId, "frame": answer]))

        // Member seals the circle to the joiner.
        let sealedSteps = try steps(try await call([
            "cmd": "pairingSeal",
            "pairingId": memberId,
            "circle": circle,
            "transcript": try XCTUnwrap(sealStep["transcript"] as? String),
            "joinerPublicKey": try XCTUnwrap(sealStep["joinerPublicKey"] as? String),
        ]))
        let sealedFrame = try XCTUnwrap(sealedSteps.first { $0["kind"] as? String == "send" }?["frame"] as? String)

        // Joiner receives it and is handed something to open.
        let finalSteps = try steps(try await call([
            "cmd": "pairingReceive", "pairingId": joinerId, "frame": sealedFrame,
        ]))
        let openStep = try XCTUnwrap(finalSteps.first { $0["kind"] as? String == "open" })

        // And opens it — with a key the host has never seen.
        let opened = try payload(try await call([
            "cmd": "pairingOpen",
            "pairingId": joinerId,
            "encapsulated": try XCTUnwrap(openStep["encapsulated"] as? String),
            "ciphertext": try XCTUnwrap(openStep["ciphertext"] as? String),
            "transcript": try XCTUnwrap(openStep["transcript"] as? String),
        ]))

        XCTAssertEqual(opened["channelId"] as? String, "ch_ffi")
        XCTAssertEqual(opened["channelKey"] as? String, circle["channelKey"] as? String)
        XCTAssertEqual(opened["credentialsKey"] as? String, circle["credentialsKey"] as? String)
        XCTAssertEqual(opened["epoch"] as? Int, 5)
    }

    func testTheDigitPathShowsBothHostsTheSameNumber() async throws {
        let joinerBegan = try payload(try await call([
            "cmd": "pairingBegin",
            "role": "joiner",
            "pairingPath": "digits",
            "deviceName": "Fresh Windows PC",
        ]))
        let joinerId = try XCTUnwrap(joinerBegan["pairingId"] as? String)
        let hello = try XCTUnwrap((joinerBegan["steps"] as? [[String: Any]])?.first?["frame"] as? String)

        let memberBegan = try payload(try await call([
            "cmd": "pairingBegin",
            "role": "member",
            "pairingPath": "digits",
            "deviceName": "Brandon's iPhone",
        ]))
        let memberId = try XCTUnwrap(memberBegan["pairingId"] as? String)

        let memberResponse = try payload(try await call([
            "cmd": "pairingReceive", "pairingId": memberId, "frame": hello,
        ]))
        let memberSteps = try XCTUnwrap(memberResponse["steps"] as? [[String: Any]])
        XCTAssertEqual(memberResponse["peerName"] as? String, "Fresh Windows PC")
        let answer = try XCTUnwrap(memberSteps.first { $0["kind"] as? String == "send" }?["frame"] as? String)

        let joinerResponse = try payload(try await call([
            "cmd": "pairingReceive", "pairingId": joinerId, "frame": answer,
        ]))
        let joinerSteps = try XCTUnwrap(joinerResponse["steps"] as? [[String: Any]])
        XCTAssertEqual(joinerResponse["peerName"] as? String, "Brandon's iPhone")
        let joinerDigits = try XCTUnwrap(joinerSteps.first { $0["kind"] as? String == "digits" }?["digits"] as? String)
        let reveal = try XCTUnwrap(joinerSteps.first { $0["kind"] as? String == "send" }?["frame"] as? String)

        let revealed = try steps(try await call(["cmd": "pairingReceive", "pairingId": memberId, "frame": reveal]))
        let memberDigits = try XCTUnwrap(revealed.first { $0["kind"] as? String == "digits" }?["digits"] as? String)

        XCTAssertEqual(joinerDigits, memberDigits)
        XCTAssertEqual(joinerDigits.count, 6)
    }

    func testSayingTheNumbersDifferEndsTheSessionForGood() async throws {
        let began = try payload(try await call(["cmd": "pairingBegin", "role": "joiner", "pairingPath": "digits"]))
        let id = try XCTUnwrap(began["pairingId"] as? String)

        let declined = try await call(["cmd": "pairingConfirm", "pairingId": id, "matched": false])
        XCTAssertEqual(declined["ok"] as? Bool, false)

        // And the handle is gone, so a host cannot quietly carry on with it.
        let after = try await call(["cmd": "pairingReceive", "pairingId": id,
                                    "frame": Data([0x03] + Array(repeating: 0x00, count: 16)).base64EncodedString()])
        XCTAssertEqual(after["ok"] as? Bool, false)
    }

    func testAnUnknownPairingSessionIsRefused() async throws {
        let response = try await call(["cmd": "pairingEnd", "pairingId": "not-a-real-session"])
        // Ending something that is not there is harmless; receiving into it is not.
        XCTAssertNotNil(response["ok"])
    }

    func testAHostCanFormACircleWhenItIsAlone() async throws {
        let created = try payload(try await call(["cmd": "circleCreate"]))

        let channelKey = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(created["channelKey"] as? String)))
        let credentialsKey = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(created["credentialsKey"] as? String)))
        XCTAssertEqual(channelKey.count, 32)
        XCTAssertEqual(credentialsKey.count, 32)
        XCTAssertNotEqual(channelKey, credentialsKey)
        XCTAssertEqual(created["epoch"] as? Int, 1)
        // Empty until a relay is provisioned; a placeholder that looked like a
        // key would be worse than an obviously absent one.
        XCTAssertEqual(created["relayKey"] as? String, "")

        let second = try payload(try await call(["cmd": "circleCreate"]))
        XCTAssertNotEqual(created["channelId"] as? String, second["channelId"] as? String)
    }

    func testACircleFormedByAHostCanBeHandedToAJoiner() async throws {
        // The desktop's real first-run path: form a circle, then admit a phone.
        let formed = try payload(try await call(["cmd": "circleCreate"]))

        let joinerBegan = try payload(try await call(["cmd": "pairingBegin", "role": "joiner", "pairingPath": "qr"]))
        let joinerId = try XCTUnwrap(joinerBegan["pairingId"] as? String)
        let qrText = try XCTUnwrap(joinerBegan["qrText"] as? String)
        let hello = try XCTUnwrap((joinerBegan["steps"] as? [[String: Any]])?.first?["frame"] as? String)

        let memberBegan = try payload(try await call([
            "cmd": "pairingBegin", "role": "member", "pairingPath": "qr", "scannedCode": qrText,
        ]))
        let memberId = try XCTUnwrap(memberBegan["pairingId"] as? String)

        let memberSteps = try steps(try await call(["cmd": "pairingReceive", "pairingId": memberId, "frame": hello]))
        let answer = try XCTUnwrap(memberSteps.first { $0["kind"] as? String == "send" }?["frame"] as? String)
        let sealStep = try XCTUnwrap(memberSteps.first { $0["kind"] as? String == "seal" })
        _ = try steps(try await call(["cmd": "pairingReceive", "pairingId": joinerId, "frame": answer]))

        let sealedSteps = try steps(try await call([
            "cmd": "pairingSeal", "pairingId": memberId, "circle": formed,
            "transcript": try XCTUnwrap(sealStep["transcript"] as? String),
            "joinerPublicKey": try XCTUnwrap(sealStep["joinerPublicKey"] as? String),
        ]))
        let sealedFrame = try XCTUnwrap(sealedSteps.first { $0["kind"] as? String == "send" }?["frame"] as? String)

        let finalSteps = try steps(try await call(["cmd": "pairingReceive", "pairingId": joinerId, "frame": sealedFrame]))
        let openStep = try XCTUnwrap(finalSteps.first { $0["kind"] as? String == "open" })
        let opened = try payload(try await call([
            "cmd": "pairingOpen", "pairingId": joinerId,
            "encapsulated": try XCTUnwrap(openStep["encapsulated"] as? String),
            "ciphertext": try XCTUnwrap(openStep["ciphertext"] as? String),
            "transcript": try XCTUnwrap(openStep["transcript"] as? String),
        ]))

        // The joiner ends up in the circle the host formed, not some other one.
        XCTAssertEqual(opened["channelId"] as? String, formed["channelId"] as? String)
        XCTAssertEqual(opened["channelKey"] as? String, formed["channelKey"] as? String)
        XCTAssertEqual(opened["credentialsKey"] as? String, formed["credentialsKey"] as? String)
    }

    func testANonPairingCommandIsLeftForTheOtherTables() async throws {
        let data = try JSONSerialization.data(withJSONObject: ["id": 1, "cmd": "libraries"])
        let request = try JSONDecoder().decode(SessionRequest.self, from: data)
        let handled = try await dispatchPairingCommand(request)
        XCTAssertNil(handled, "pairing must not swallow commands belonging to another table")
    }
}
