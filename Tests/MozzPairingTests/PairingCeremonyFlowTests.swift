#if canImport(Network)
import Crypto
import Foundation
import Network
import XCTest
@testable import MozzPairing

/// The coordinator driving both sides over real sockets, which is as close to
/// what the app will do as anything can get without a second device.
///
/// Bonjour is bypassed the same way and for the same reason as in
/// `PairingTransportTests`: local-network permission is per signing identity on
/// macOS, and a test that depends on it fails for reasons unrelated to pairing.
final class PairingCeremonyFlowTests: XCTestCase {
    private let circle = CircleSecrets(
        channelId: "ch_ceremony",
        channelKey: Data(repeating: 0x11, count: 32),
        credentialsKey: Data(repeating: 0x22, count: 32),
        epoch: 2,
        relayKey: Data("relay".utf8))

    /// Lets the member wait for the code the joiner displays, the way a person
    /// waits for it to appear on screen before pointing a camera at it.
    private actor CodeBox {
        private var payload: Pairing.QRPayload?
        private var waiting: [CheckedContinuation<Pairing.QRPayload, Never>] = []

        func put(_ value: Pairing.QRPayload) {
            payload = value
            for continuation in waiting { continuation.resume(returning: value) }
            waiting.removeAll()
        }

        func take() async -> Pairing.QRPayload {
            if let payload { return payload }
            return await withCheckedContinuation { waiting.append($0) }
        }
    }

    private func pair(path: PairingPath, memberConfirms: Bool = true) async throws -> CircleSecrets {
        let host = try PairingHost(advertise: false)
        try await host.start()
        let boundPort = await host.port
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                           port: try XCTUnwrap(NWEndpoint.Port(rawValue: try XCTUnwrap(boundPort))))
        defer { Task { await host.stop() } }

        let store = CircleStore(secure: InMemoryStore(), plain: InMemoryStore())
        let box = CodeBox()

        async let joined = PairingCeremony.join(
            path: path,
            into: store,
            host: host,
            showCode: { _, payload in Task { await box.put(payload) } })

        let scanned = await box.take()
        let link = try await PairingLink.connect(to: endpoint)
        try await PairingCeremony.runMember(circle, path: path,
                                            scanned: path == .qr ? scanned : nil,
                                            link: link,
                                            confirmDigits: { _, _ in memberConfirms })

        let result = try await joined
        // The circle must be on disk, not merely returned. A caller that forgot
        // to persist would otherwise produce a device that paired and forgot.
        XCTAssertEqual(try store.load(), result)
        return result
    }

    func testAQRCeremonyEndsWithTheCircleSaved() async throws {
        let paired = try await pair(path: .qr)
        XCTAssertEqual(paired, circle)
    }

    func testADigitCeremonyEndsWithTheCircleSaved() async throws {
        let paired = try await pair(path: .digits)
        XCTAssertEqual(paired, circle)
    }

    func testTheDigitsShownToBothPeopleMatch() async throws {
        let host = try PairingHost(advertise: false)
        try await host.start()
        let boundPort = await host.port
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                           port: try XCTUnwrap(NWEndpoint.Port(rawValue: try XCTUnwrap(boundPort))))
        defer { Task { await host.stop() } }

        let seen = DigitCollector()
        let store = CircleStore(secure: InMemoryStore(), plain: InMemoryStore())
        let box = CodeBox()

        async let joined = PairingCeremony.join(
            path: .digits,
            into: store,
            host: host,
            showCode: { _, payload in Task { await box.put(payload) } },
            confirmDigits: { digits, peerName in
                await seen.add(digits, peerName: peerName)
                return true
            })

        _ = await box.take()
        let link = try await PairingLink.connect(to: endpoint)
        try await PairingCeremony.runMember(circle, path: .digits, scanned: nil, link: link,
                                            deviceName: "Established Mac",
                                            confirmDigits: { digits, peerName in
                                                await seen.add(digits, peerName: peerName)
                                                return true
                                            })
        _ = try await joined

        let observations = await seen.all
        XCTAssertEqual(observations.count, 2, "both people should have been shown a number")
        XCTAssertEqual(observations.first?.digits, observations.last?.digits,
                       "and it must be the same number")
        XCTAssertEqual(observations.first?.digits.count, 6)
        XCTAssertEqual(Set(observations.compactMap(\.peerName)),
                       Set(["Established Mac", "Mozz"]),
                       "each side must name the device on its other screen")
    }

    func testSayingTheDigitsDoNotMatchStopsTheCeremony() async throws {
        do {
            _ = try await pair(path: .digits, memberConfirms: false)
            XCTFail("declining should not produce a circle")
        } catch {
            // Either side refusing is enough; the joiner never gets a seal.
        }
    }

    private actor DigitCollector {
        struct Observation {
            let digits: String
            let peerName: String?
        }

        private(set) var all: [Observation] = []
        func add(_ digits: String, peerName: String?) {
            all.append(Observation(digits: digits, peerName: peerName))
        }
    }
}
#endif
