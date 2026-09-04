#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation
@testable import MozzRelay
import XCTest

private actor RecordingHTTP: RelayHTTPTransport {
    private var queued: [RelayHTTPResponse]
    private(set) var requests: [URLRequest] = []

    init(_ queued: [RelayHTTPResponse]) {
        self.queued = queued
    }

    func send(_ request: URLRequest) async throws -> RelayHTTPResponse {
        requests.append(request)
        return queued.removeFirst()
    }
}

final class S3RelayObjectStoreTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_693_398_906)

    private var configuration: S3RelayConfiguration {
        S3RelayConfiguration(
            accessKeyID: "test-access",
            secretAccessKey: "test-secret",
            bucket: "mozz-relay",
            region: "us-west-004",
            writeEndpoint: URL(string: "https://s3.example.test")!,
            readEndpoint: URL(string: "https://cdn.example.test")!,
            expiresAtMS: 2_000_000_000_000)
    }

    private func response(
        url: String = "https://example.test",
        status: Int,
        headers: [String: String] = [:],
        body: Data = Data()
    ) -> RelayHTTPResponse {
        RelayHTTPResponse(
            data: body,
            response: HTTPURLResponse(
                url: URL(string: url)!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers)!)
    }

    func testCredentialsRoundTripThroughThePairingBlob() throws {
        XCTAssertEqual(
            try S3RelayConfiguration.decode(configuration.encoded()),
            configuration)
    }

    func testReadsUseThePublicEndpointWithoutLeakingCredentials() async throws {
        let http = RecordingHTTP([
            response(status: 200, headers: ["ETag": "\"abc\""], body: Data("cipher".utf8)),
        ])
        let store = S3RelayObjectStore(
            configuration: configuration, http: http, now: { self.fixedDate })

        let read = try await store.read(
            path: "c/channel/d/phone/history",
            ifNoneMatch: "\"old\"")

        XCTAssertEqual(
            read,
            .object(RelayStoredObject(
                data: Data("cipher".utf8), etag: "\"abc\"")))
        let requests = await http.requests
        XCTAssertEqual(
            requests[0].url?.absoluteString,
            "https://cdn.example.test/c/channel/d/phone/history")
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "If-None-Match"),
            "\"old\"")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(
            String(data: requests[0].httpBody ?? Data(), encoding: .utf8)?
                .contains("test-secret") ?? false)
    }

    func testWritesAreSignedAndCarryTheirCondition() async throws {
        let http = RecordingHTTP([
            response(status: 200, headers: ["ETag": "\"new\""]),
        ])
        let store = S3RelayObjectStore(
            configuration: configuration, http: http, now: { self.fixedDate })

        let etag = try await store.put(
            path: "c/channel/manifests/1/phone-id",
            data: Data("ciphertext".utf8),
            condition: .ifAbsent)

        XCTAssertEqual(etag, "\"new\"")
        let requests = await http.requests
        let request = requests[0]
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://s3.example.test/mozz-relay/c/channel/manifests/1/phone-id")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "If-None-Match"), "*")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-amz-date"),
            "20230830T123506Z")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-amz-content-sha256"),
            "305531dcc50ebca31cf1d5b31e9fc76ed51f66b3b6dd5a030c6539ae6532f979")
        let authorization = try XCTUnwrap(
            request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(authorization.hasPrefix(
            "AWS4-HMAC-SHA256 Credential=test-access/20230830/us-west-004/s3/aws4_request"))
        XCTAssertTrue(authorization.contains(
            "SignedHeaders=content-type;host;if-none-match;x-amz-content-sha256;x-amz-date"))
        XCTAssertFalse(authorization.contains("test-secret"))
    }

    func testListFollowsContinuationTokensAndDecodesXML() async throws {
        let first = Data("""
            <ListBucketResult>
              <IsTruncated>true</IsTruncated>
              <Contents><Key>c/channel/manifests/1/a</Key></Contents>
              <NextContinuationToken>next+/=</NextContinuationToken>
            </ListBucketResult>
            """.utf8)
        let second = Data("""
            <ListBucketResult>
              <IsTruncated>false</IsTruncated>
              <Contents><Key>c/channel/manifests/1/b</Key></Contents>
            </ListBucketResult>
            """.utf8)
        let http = RecordingHTTP([
            response(status: 200, body: first),
            response(status: 200, body: second),
        ])
        let store = S3RelayObjectStore(
            configuration: configuration, http: http, now: { self.fixedDate })

        let keys = try await store.list(prefix: "c/channel/manifests/1/")

        XCTAssertEqual(
            keys,
            ["c/channel/manifests/1/a", "c/channel/manifests/1/b"])
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].url?.query?.contains(
            "prefix=c%2Fchannel%2Fmanifests%2F1%2F") == true)
        XCTAssertTrue(requests[1].url?.query?.contains(
            "continuation-token=next%2B%2F%3D") == true)
        XCTAssertNotNil(
            requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertNotNil(
            requests[1].value(forHTTPHeaderField: "Authorization"))
    }

    func testExpiredCredentialsFailBeforeTouchingTheNetwork() async {
        let http = RecordingHTTP([])
        var expired = configuration
        expired = S3RelayConfiguration(
            accessKeyID: expired.accessKeyID,
            secretAccessKey: expired.secretAccessKey,
            bucket: expired.bucket,
            region: expired.region,
            writeEndpoint: expired.writeEndpoint,
            readEndpoint: expired.readEndpoint,
            expiresAtMS: 1)
        let store = S3RelayObjectStore(
            configuration: expired, http: http, now: { self.fixedDate })

        await XCTAssertThrowsErrorAsync {
            _ = try await store.list(prefix: "c/channel/manifests/1/")
        }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testPreconditionFailuresAreNotRetriedAsSuccess() async {
        let http = RecordingHTTP([response(status: 412)])
        let store = S3RelayObjectStore(
            configuration: configuration, http: http, now: { self.fixedDate })

        await XCTAssertThrowsErrorAsync {
            _ = try await store.put(
                path: "c/channel/manifests/1/phone",
                data: Data(),
                condition: .ifMatch("\"old\""))
        }
    }

    func testAWSPercentEncodingIsPathSafeAndNeverUsesPlusForSpaces() {
        XCTAssertEqual(
            AWSV4Signer.encode("a b/+"),
            "a%20b%2F%2B")
    }

    /// Opt-in live contract test. The five values live in a machine-local,
    /// gitignored environment file and are never printed.
    func testLiveB2WriteListPublicReadConditionalReadAndCleanup() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_B2_S3_LIVE"] == "1",
              let bucket = environment["B2_BUCKET"],
              let endpointText = environment["B2_ENDPOINT"],
              let region = environment["B2_REGION"],
              let accessKeyID = environment["B2_KEY_ID"],
              let secret = environment["B2_APP_KEY"] else {
            throw XCTSkip("B2 S3 integration is not explicitly enabled")
        }
        let normalizedEndpoint = endpointText.hasPrefix("http")
            ? endpointText : "https://\(endpointText)"
        let writeEndpoint = try XCTUnwrap(URL(string: normalizedEndpoint))
        let readEndpoint = writeEndpoint.appendingPathComponent(bucket)
        let configuration = S3RelayConfiguration(
            accessKeyID: accessKeyID,
            secretAccessKey: secret,
            bucket: bucket,
            region: region,
            writeEndpoint: writeEndpoint,
            readEndpoint: readEndpoint,
            expiresAtMS: Int64(Date().addingTimeInterval(300).timeIntervalSince1970 * 1000))
        let store = S3RelayObjectStore(configuration: configuration)
        let probeID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let prefix = "c/integration_\(probeID)/manifests/1/"
        let path = prefix + "device"
        let body = Data("mozz-live-relay-probe".utf8)

        var failure: (any Error)?
        do {
            let etag = try await store.put(
                path: path, data: body, condition: .ifAbsent)
            let listed = try await store.list(prefix: prefix)
            XCTAssertEqual(listed, [path])

            let first = try await store.read(path: path, ifNoneMatch: nil)
            XCTAssertEqual(
                first,
                .object(RelayStoredObject(data: body, etag: etag)))
            let unchanged = try await store.read(
                path: path, ifNoneMatch: etag)
            XCTAssertEqual(unchanged, .notModified)
        } catch {
            failure = error
        }
        try? await store.delete(path: path)
        if let failure { throw failure }
    }
}
