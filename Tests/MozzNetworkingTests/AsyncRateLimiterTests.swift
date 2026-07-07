import XCTest
import Foundation
import MozzCore
@testable import MozzNetworking
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A clock whose time only moves when the test says so, so limiter spacing is
/// deterministic without real sleeps.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    private(set) var sleeps: [TimeInterval] = []
    init(_ start: Date) { t = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func recordSleep(_ s: TimeInterval) { lock.lock(); sleeps.append(s); lock.unlock() }
}

/// Inner transport that always returns a fixed status, capturing send count.
private final class StubTransport: HTTPTransport, @unchecked Sendable {
    let status: Int
    let headers: [String: String]
    private let lock = NSLock()
    private(set) var sendCount = 0
    init(status: Int = 200, headers: [String: String] = [:]) {
        self.status = status; self.headers = headers
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); sendCount += 1; lock.unlock()
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: nil, headerFields: headers)!
        return (Data(), resp)
    }
}

final class AsyncRateLimiterTests: XCTestCase {
    func testSpacesSequentialAcquisitions() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let limiter = AsyncRateLimiter(
            minInterval: 1.0, now: { clock.now },
            sleep: { clock.recordSleep($0) })
        try await limiter.acquire()
        try await limiter.acquire()
        try await limiter.acquire()
        // First acquire is immediate; each subsequent one waits one more interval.
        XCTAssertEqual(clock.sleeps, [1.0, 2.0])
    }

    func testConcurrentAcquisitionsSerialize() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let limiter = AsyncRateLimiter(
            minInterval: 1.0, now: { clock.now },
            sleep: { clock.recordSleep($0) })
        await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { try await limiter.acquire() } }
        }
        // Three concurrent callers each reserve a distinct slot: waits of 0, 1, 2s
        // (the 0-wait one records nothing). Distinct, deterministic spacing.
        XCTAssertEqual(clock.sleeps.sorted(), [1.0, 2.0])
    }

    func testRateLimitingTransportSpacesEverySend() async throws {
        // Two sends (as HTTPClient's retry loop would do) each acquire a slot, so
        // the second is spaced by one interval.
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let limiter = AsyncRateLimiter(
            minInterval: 1.0, now: { clock.now },
            sleep: { clock.recordSleep($0) })
        let transport = RateLimitingTransport(
            wrapping: StubTransport(), limiter: limiter, now: { clock.now })
        let req = URLRequest(url: URL(string: "https://musicbrainz.org/ws/2/recording")!)
        _ = try await transport.send(req)
        _ = try await transport.send(req)
        XCTAssertEqual(clock.sleeps, [1.0])
    }

    func testRetryAfterOn503PenalizesLimiter() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = TestClock(start)
        let limiter = AsyncRateLimiter(
            minInterval: 1.0, now: { clock.now },
            sleep: { clock.recordSleep($0) })
        let transport = RateLimitingTransport(
            wrapping: StubTransport(status: 503, headers: ["Retry-After": "30"]),
            limiter: limiter, now: { clock.now })
        _ = try await transport.send(URLRequest(url: URL(string: "https://musicbrainz.org/x")!))
        let next = await limiter.currentNextAllowed()
        XCTAssertGreaterThanOrEqual(next.timeIntervalSince(start), 30)
    }

    func testRetryAfterParsing() {
        func resp(_ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 503,
                            httpVersion: nil, headerFields: headers)!
        }
        XCTAssertEqual(RateLimitingTransport.retryAfterSeconds(resp(["Retry-After": "12"])), 12)
        XCTAssertEqual(RateLimitingTransport.retryAfterSeconds(resp(["Retry-After": "99999"])), 120) // clamped
        XCTAssertNil(RateLimitingTransport.retryAfterSeconds(resp([:])))
    }
}
