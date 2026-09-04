#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation
@testable import MozzRelay
import XCTest

private actor B2RecordingHTTP: RelayHTTPTransport {
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

final class B2NativeRelayObjectStoreTests: XCTestCase {
    private var configuration: B2RelayConfiguration {
        B2RelayConfiguration(
            keyID: "key-id",
            applicationKey: "app-key",
            bucketName: "mozz-relay",
            readEndpoint: URL(
                string: "https://cdn.example.test/file/mozz-relay")!,
            expiresAtMS: 2_000_000_000_000)
    }

    private func response(
        url: String = "https://example.test",
        status: Int = 200,
        headers: [String: String] = [:],
        json: String = "{}",
        body: Data? = nil
    ) -> RelayHTTPResponse {
        RelayHTTPResponse(
            data: body ?? Data(json.utf8),
            response: HTTPURLResponse(
                url: URL(string: url)!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers)!)
    }

    private var authorizationJSON: String {
        """
        {
          "authorizationToken": "account-token",
          "apiInfo": {
            "storageApi": {
              "apiUrl": "https://api.example.test",
              "downloadUrl": "https://download.example.test",
              "allowed": {
                "buckets": [{"id": "bucket-id", "name": "mozz-relay"}]
              }
            }
          }
        }
        """
    }

    func testConfigurationRoundTripsThroughPairing() throws {
        XCTAssertEqual(
            try B2RelayConfiguration.decode(configuration.encoded()),
            configuration)
    }

    func testUploadUsesNativeAuthorizationAndAReusableUploadURL() async throws {
        let sha1 = "6f87f8a6a8a9b9f0f38df4f6b8302b24f96b76f1"
        let http = B2RecordingHTTP([
            response(json: authorizationJSON),
            response(json: """
                {"uploadUrl":"https://pod.example.test/upload","authorizationToken":"upload-token"}
                """),
            response(json: #"{"contentSha1":"\#(sha1)"}"#),
            response(json: #"{"contentSha1":"\#(sha1)"}"#),
        ])
        let store = B2NativeRelayObjectStore(
            configuration: configuration, http: http)

        _ = try await store.put(
            path: "c/channel/manifests/1/device/1-hash",
            data: Data("one".utf8),
            condition: .none)
        _ = try await store.put(
            path: "c/channel/manifests/1/device/2-hash",
            data: Data("two".utf8),
            condition: .none)

        let requests = await http.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(
            requests[0].value(forHTTPHeaderField: "Authorization")?
                .hasPrefix("Basic ") == true)
        XCTAssertFalse(
            requests[0].value(forHTTPHeaderField: "Authorization")?
                .contains("app-key") == true)
        XCTAssertEqual(requests[1].url?.path, "/b2api/v4/b2_get_upload_url")
        XCTAssertEqual(
            requests[2].value(forHTTPHeaderField: "Authorization"),
            "upload-token")
        XCTAssertEqual(
            requests[2].value(forHTTPHeaderField: "X-Bz-File-Name"),
            "c%2Fchannel%2Fmanifests%2F1%2Fdevice%2F1-hash")
        XCTAssertEqual(
            requests[2].value(forHTTPHeaderField: "Content-Length"), "3")
        XCTAssertEqual(
            requests[2].value(forHTTPHeaderField: "X-Bz-Content-Sha1"),
            "fe05bcdcdc4928012781a5f1a2a77cbb5398e106")
        XCTAssertEqual(requests[3].url, requests[2].url,
                       "the upload target is reusable")
    }

    func testPrefixListingPaginatesWithNativeAPI() async throws {
        let http = B2RecordingHTTP([
            response(json: authorizationJSON),
            response(json: """
                {
                  "files":[{"fileId":"1","fileName":"c/x/a","action":"upload"}],
                  "nextFileName":"c/x/b"
                }
                """),
            response(json: """
                {
                  "files":[{"fileId":"2","fileName":"c/x/b","action":"upload"}],
                  "nextFileName":null
                }
                """),
        ])
        let store = B2NativeRelayObjectStore(
            configuration: configuration, http: http)

        let listed = try await store.list(prefix: "c/x/")
        XCTAssertEqual(listed, ["c/x/a", "c/x/b"])
        let requests = await http.requests
        let firstBody = try XCTUnwrap(requests[1].httpBody)
        let secondBody = try XCTUnwrap(requests[2].httpBody)
        let firstJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: firstBody) as? [String: Any])
        let secondJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: secondBody) as? [String: Any])
        XCTAssertEqual(firstJSON["prefix"] as? String, "c/x/")
        XCTAssertEqual(secondJSON["startFileName"] as? String, "c/x/b")
    }

    func testPublicReadDoesNotAuthorizeAgainstB2() async throws {
        let http = B2RecordingHTTP([
            response(
                status: 200,
                headers: ["ETag": "\"hash\""],
                body: Data("cipher".utf8)),
        ])
        let store = B2NativeRelayObjectStore(
            configuration: configuration, http: http)

        _ = try await store.read(path: "c/x/object", ifNoneMatch: nil)

        let requests = await http.requests
        XCTAssertEqual(
            requests[0].url?.absoluteString,
            "https://cdn.example.test/file/mozz-relay/c/x/object")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
    }

    func testNativeDownloadHostTreatsAnIdentical200AsNotModified() async throws {
        let http = B2RecordingHTTP([
            response(
                status: 200,
                headers: ["ETag": "\"same\""],
                body: Data("body B2 needlessly returned".utf8)),
        ])
        let store = B2NativeRelayObjectStore(
            configuration: configuration, http: http)

        let result = try await store.read(
            path: "c/x/object", ifNoneMatch: "\"same\"")

        XCTAssertEqual(result, .notModified)
    }

    func testNativeAdapterRefusesToPretendItHasCompareAndSwap() async {
        let http = B2RecordingHTTP([])
        let store = B2NativeRelayObjectStore(
            configuration: configuration, http: http)

        await XCTAssertThrowsErrorAsync {
            _ = try await store.put(
                path: "c/x",
                data: Data(),
                condition: .ifAbsent)
        }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testLiveB2NativeWriteListPublicReadConditionalReadAndCleanup() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let bucket = environment["B2_BUCKET"],
              let keyID = environment["B2_KEY_ID"],
              let applicationKey = environment["B2_APP_KEY"] else {
            throw XCTSkip("B2 integration credentials are not present")
        }
        let configuration = B2RelayConfiguration(
            keyID: keyID,
            applicationKey: applicationKey,
            bucketName: bucket,
            expiresAtMS: Int64(Date().addingTimeInterval(300).timeIntervalSince1970 * 1000))
        let store = B2NativeRelayObjectStore(configuration: configuration)
        let probeID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let prefix = "c/integration_\(probeID)/manifests/1/device/"
        let path = prefix + "1-probe"
        let body = Data("mozz-live-native-b2-probe".utf8)

        var failure: (any Error)?
        do {
            let etag = try await store.put(
                path: path, data: body, condition: .none)
            let listed = try await store.list(prefix: prefix)
            let first = try await store.read(path: path, ifNoneMatch: nil)
            let unchanged = try await store.read(path: path, ifNoneMatch: etag)
            XCTAssertEqual(listed, [path])
            XCTAssertEqual(
                first,
                .object(RelayStoredObject(data: body, etag: etag)))
            XCTAssertEqual(unchanged, .notModified)
        } catch {
            failure = error
        }
        try? await store.delete(path: path)
        if let failure { throw failure }
    }
}
