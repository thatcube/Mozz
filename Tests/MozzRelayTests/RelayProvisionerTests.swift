#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation
@testable import MozzRelay
import XCTest

private actor ProvisioningHTTP: RelayHTTPTransport {
    let response: RelayHTTPResponse
    private(set) var request: URLRequest?

    init(status: Int, body: Data) {
        response = RelayHTTPResponse(
            data: body,
            response: HTTPURLResponse(
                url: URL(string: "https://relay.example")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Cache-Control": "no-store"])!)
    }

    func send(_ request: URLRequest) async throws -> RelayHTTPResponse {
        self.request = request
        return response
    }
}

final class RelayProvisionerTests: XCTestCase {
    private let channel = "abcdefghijklmnop"

    private func configuration(
        expiresAtMS: Int64 = 2_000_000_000_000
    ) -> B2RelayConfiguration {
        B2RelayConfiguration(
            keyID: "child-id",
            applicationKey: "child-secret",
            bucketName: "mozz-relay",
            readEndpoint: URL(
                string: "https://sync.mozzmusic.com/file/mozz-relay")!,
            expiresAtMS: expiresAtMS)
    }

    func testCreateUsesTheChannelEndpointAndDecodesTheCapability() async throws {
        let expected = configuration()
        let http = ProvisioningHTTP(status: 201, body: try expected.encoded())
        let provisioner = RelayProvisioner(
            endpoint: URL(string: "https://relay.mozzmusic.com")!,
            http: http)

        let created = try await provisioner.create(channelID: channel)
        XCTAssertEqual(created, expected)
        let recorded = await http.request
        let request = try XCTUnwrap(recorded)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://relay.mozzmusic.com/v1/channels")
        let body = try XCTUnwrap(request.httpBody)
        let decoded = try JSONDecoder().decode(
            [String: String].self, from: body)
        XCTAssertEqual(decoded, ["channelId": channel])
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testRenewalProvesTheExistingCapabilityWithoutPuttingItInTheBody() async throws {
        let current = configuration(expiresAtMS: 1)
        let replacement = configuration(expiresAtMS: 2)
        let http = ProvisioningHTTP(
            status: 200, body: try replacement.encoded())
        let provisioner = RelayProvisioner(
            endpoint: URL(string: "https://relay.mozzmusic.com")!,
            http: http)

        let renewed = try await provisioner.renew(
            channelID: channel, current: current)
        XCTAssertEqual(renewed, replacement)
        let recorded = await http.request
        let request = try XCTUnwrap(recorded)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://relay.mozzmusic.com/v1/channels/\(channel)/renew")
        let authorization = try XCTUnwrap(
            request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(authorization.hasPrefix("Basic "))
        XCTAssertFalse(
            String(data: request.httpBody ?? Data(), encoding: .utf8)?
                .contains("child-secret") == true)
    }

    func testRenewalBeginsSevenDaysBeforeExpiry() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let sixDays = configuration(
            expiresAtMS: Int64(now.addingTimeInterval(6 * 86_400).timeIntervalSince1970 * 1000))
        let eightDays = configuration(
            expiresAtMS: Int64(now.addingTimeInterval(8 * 86_400).timeIntervalSince1970 * 1000))

        XCTAssertTrue(RelayProvisioner.needsRenewal(sixDays, now: now))
        XCTAssertFalse(RelayProvisioner.needsRenewal(eightDays, now: now))
    }

    func testAnInvalidChannelNeverTouchesTheWorker() async {
        let http = ProvisioningHTTP(status: 500, body: Data())
        let provisioner = RelayProvisioner(
            endpoint: URL(string: "https://relay.mozzmusic.com")!,
            http: http)

        await XCTAssertThrowsErrorAsync {
            _ = try await provisioner.create(channelID: "../escape")
        }
        let request = await http.request
        XCTAssertNil(request)
    }

    func testRateLimitAndServiceFailuresAreNotSuccessShaped() async {
        let http = ProvisioningHTTP(
            status: 429, body: Data(#"{"error":"rate_limited"}"#.utf8))
        let provisioner = RelayProvisioner(
            endpoint: URL(string: "https://relay.mozzmusic.com")!,
            http: http)

        await XCTAssertThrowsErrorAsync {
            _ = try await provisioner.create(channelID: channel)
        }
    }
}
