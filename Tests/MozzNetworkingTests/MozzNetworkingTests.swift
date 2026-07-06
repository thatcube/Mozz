import XCTest
import MozzCore
@testable import MozzNetworking

/// A transport double that returns queued results in order (repeating the last
/// one), recording every request for assertions. Used to test the client with
/// no real network.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Stub { let status: Int; let data: Data }

    private let lock = NSLock()
    private var results: [Result<Stub, Error>]
    private var _requests: [URLRequest] = []

    init(results: [Result<Stub, Error>]) {
        self.results = results
    }

    convenience init(status: Int, json: String) {
        self.init(results: [.success(Stub(status: status, data: Data(json.utf8)))])
    }

    var recordedRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    var callCount: Int { recordedRequests.count }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result: Result<Stub, Error> = {
            lock.lock(); defer { lock.unlock() }
            _requests.append(request)
            if results.count > 1 {
                return results.removeFirst()
            }
            return results.first ?? .failure(MozzError.invalidResponse)
        }()

        switch result {
        case .success(let stub):
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: nil)!
            return (stub.data, response)
        case .failure(let error):
            throw error
        }
    }
}

private struct Sample: Codable, Equatable { let name: String; let count: Int }

private let fastRetry = RetryPolicy(maxRetries: 2, baseDelay: 0.001, maxDelay: 0.001)

final class HTTPClientDecodingTests: XCTestCase {
    func testDecodesJSON() async throws {
        let transport = MockTransport(status: 200, json: #"{"name":"ok","count":3}"#)
        let client = HTTPClient(baseURL: URL(string: "https://host")!, transport: transport)
        let value = try await client.send(Endpoint(path: "thing"), as: Sample.self)
        XCTAssertEqual(value, Sample(name: "ok", count: 3))
    }

    func testDecodingFailureMapsToMozzError() async throws {
        let transport = MockTransport(status: 200, json: #"{"unexpected":true}"#)
        let client = HTTPClient(baseURL: URL(string: "https://host")!, transport: transport)
        do {
            _ = try await client.send(Endpoint(path: "thing"), as: Sample.self)
            XCTFail("expected decode failure")
        } catch let error as MozzError {
            guard case .decodingFailed = error else { return XCTFail("wrong case: \(error)") }
        }
    }
}

final class HTTPStatusMappingTests: XCTestCase {
    private func error(forStatus status: Int) async -> MozzError? {
        let transport = MockTransport(results: [.success(.init(status: status, data: Data()))])
        let client = HTTPClient(baseURL: URL(string: "https://host")!, transport: transport, retryPolicy: .none)
        do {
            _ = try await client.send(Endpoint(path: "x"))
            return nil
        } catch let error as MozzError {
            return error
        } catch {
            return nil
        }
    }

    func testMapsStatusCodes() async {
        let unauthorized = await error(forStatus: 401)
        XCTAssertEqual(unauthorized, .unauthorized)
        let forbidden = await error(forStatus: 403)
        XCTAssertEqual(forbidden, .unauthorized)
        let notFound = await error(forStatus: 404)
        XCTAssertEqual(notFound, .notFound)
        let conflict = await error(forStatus: 409)
        XCTAssertEqual(conflict, .conflict)
        let server = await error(forStatus: 503)
        XCTAssertEqual(server, .badStatus(503))
    }
}

final class RetryTests: XCTestCase {
    func testRetriesTransientThenSucceeds() async throws {
        let transport = MockTransport(results: [
            .failure(MozzError.serverUnreachable),
            .success(.init(status: 200, data: Data(#"{"name":"ok","count":1}"#.utf8))),
        ])
        let client = HTTPClient(baseURL: URL(string: "https://host")!, transport: transport, retryPolicy: fastRetry)
        let value = try await client.send(Endpoint(path: "x"), as: Sample.self)
        XCTAssertEqual(value.name, "ok")
        XCTAssertEqual(transport.callCount, 2, "should have retried once")
    }

    func testGivesUpAfterMaxRetries() async {
        let transport = MockTransport(results: [.failure(MozzError.serverUnreachable)])
        let client = HTTPClient(baseURL: URL(string: "https://host")!, transport: transport,
                                retryPolicy: RetryPolicy(maxRetries: 1, baseDelay: 0.001, maxDelay: 0.001))
        do {
            _ = try await client.send(Endpoint(path: "x"))
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? MozzError, .serverUnreachable)
        }
        XCTAssertEqual(transport.callCount, 2, "1 initial + 1 retry")
    }

    func testNonRetryableNotRetried() async {
        let transport = MockTransport(results: [.success(.init(status: 404, data: Data()))])
        let client = HTTPClient(baseURL: URL(string: "https://host")!, transport: transport,
                                retryPolicy: RetryPolicy(maxRetries: 3, baseDelay: 0.001))
        _ = try? await client.send(Endpoint(path: "x"))
        XCTAssertEqual(transport.callCount, 1, "404 must not be retried")
    }
}

final class RequestBuildingTests: XCTestCase {
    func testBuildsURLWithPathQueryAndHeaders() throws {
        let client = HTTPClient(
            baseURL: URL(string: "https://host/base")!,
            defaultHeaders: ["X-Default": "1"]
        )
        let endpoint = Endpoint(
            path: "/library/sections",
            query: [URLQueryItem(name: "type", value: "8")],
            headers: ["X-Custom": "2"]
        )
        let request = try client.makeRequest(endpoint)
        XCTAssertEqual(request.url?.absoluteString, "https://host/base/library/sections?type=8")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Default"), "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Custom"), "2")
    }

    func testWithDefaultHeadersMerges() throws {
        let client = HTTPClient(baseURL: URL(string: "https://host")!, defaultHeaders: ["A": "1"])
            .withDefaultHeaders(["B": "2", "A": "override"])
        let request = try client.makeRequest(Endpoint(path: "x"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "A"), "override")
        XCTAssertEqual(request.value(forHTTPHeaderField: "B"), "2")
    }
}

final class SecretRedactorTests: XCTestCase {
    func testRedactsSensitiveQueryValues() {
        let url = URL(string: "https://host/audio?api_key=SECRET&X-Plex-Token=TOK&keep=yes")!
        let redacted = SecretRedactor.redacted(url)
        XCTAssertFalse(redacted.contains("SECRET"))
        XCTAssertFalse(redacted.contains("TOK"))
        XCTAssertTrue(redacted.contains("keep=yes"))
        XCTAssertTrue(redacted.contains("REDACTED"))
    }

    func testRedactsAuthHeaders() {
        let redacted = SecretRedactor.redacted(headers: [
            "Authorization": "MediaBrowser Token=abc",
            "Accept": "application/json",
        ])
        XCTAssertEqual(redacted["Authorization"], "REDACTED")
        XCTAssertEqual(redacted["Accept"], "application/json")
    }
}
