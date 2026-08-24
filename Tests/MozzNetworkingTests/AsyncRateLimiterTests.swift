import XCTest
import Foundation
import MozzCore
@testable import MozzNetworking
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A clock whose time only moves when the test says so. `recordSleep` both logs
/// the requested wait AND advances the clock by it, so the limiter's re-check
/// loop terminates deterministically (as real time would).
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    private(set) var sleeps: [TimeInterval] = []
    init(_ start: Date) { t = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func recordSleep(_ s: TimeInterval) {
        lock.lock(); sleeps.append(s); t = t.addingTimeInterval(s); lock.unlock()
    }
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
        // First acquire is immediate; each subsequent one waits one interval (the
        // clock advances by each slept amount, so waits stay one interval apart).
        XCTAssertEqual(clock.sleeps, [1.0, 1.0])
    }

    func testConcurrentAcquisitionsSerialize() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = TestClock(start)
        let limiter = AsyncRateLimiter(
            minInterval: 1.0, now: { clock.now },
            sleep: { clock.recordSleep($0) })
        await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { try await limiter.acquire() } }
        }
        // Three concurrent callers each reserve a distinct slot, so the next free
        // slot has advanced by exactly three intervals — proving they serialized
        // rather than all firing at once.
        let next = await limiter.currentNextAllowed()
        XCTAssertEqual(next.timeIntervalSince(start), 3.0, accuracy: 0.0001)
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

    func testPenaltyDelaysSubsequentAcquireAndKeepsSpacing() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = TestClock(start)
        let limiter = AsyncRateLimiter(
            minInterval: 1.0, now: { clock.now },
            sleep: { clock.recordSleep($0) })
        try await limiter.acquire()                                    // slot t0, no wait
        await limiter.penalize(until: start.addingTimeInterval(30))    // back off to t0+30
        try await limiter.acquire()                                    // must wait to t0+30
        XCTAssertEqual(clock.sleeps, [30.0])
        // Spacing continues past the penalty for the NEXT reservation.
        let next = await limiter.currentNextAllowed()
        XCTAssertEqual(next.timeIntervalSince(start), 31.0, accuracy: 0.0001)
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

    /// Real-concurrency test (real clock + real Task.sleep): several callers
    /// acquire concurrently while a back-off penalty lands mid-flight. Whatever
    /// the interleaving, every pair of grants must stay >= minInterval apart — the
    /// invariant the herd bug violated. A fake-clock test can't exercise this
    /// because a synchronous fake sleep never yields to interleave the actor.
    func testConcurrentAcquiresStaySpacedUnderPenalty() async throws {
        let interval: TimeInterval = 0.1
        let limiter = AsyncRateLimiter(minInterval: interval)
        let recorder = GrantRecorder()
        let start = Date()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try? await limiter.acquire()
                    await recorder.record(Date())
                }
            }
            group.addTask {
                // Land a back-off while the callers are still waiting on their slots.
                try? await Task.sleep(nanoseconds: 20_000_000)
                await limiter.penalize(until: Date().addingTimeInterval(0.15))
            }
        }
        let times = await recorder.sorted()
        XCTAssertEqual(times.count, 4)

        // Each grant is checked against the START, not against the grant before
        // it. That distinction is the whole point.
        //
        // A timestamp is taken when the continuation gets CPU, which is not when
        // the limiter granted — on a loaded shared runner a resumed task can sit
        // for tens of milliseconds. Comparing neighbours therefore measures
        // scheduler latency as much as the limiter: delay grant N's *observation*
        // and its gap to N+1 collapses, which is exactly how this failed in CI at
        // 0.027s when the limiter itself was behaving perfectly.
        //
        // Measured from the start the asymmetry works for us. Scheduling delay
        // only ever pushes an observation LATER, so the k-th grant appearing no
        // earlier than k intervals in is a bound that jitter cannot break — while
        // a herd, which releases everything at once, still fails it immediately.
        for (index, time) in times.enumerated() {
            let elapsed = time.timeIntervalSince(start)
            let earliest = Double(index) * interval
            // A few ms of slack for timer granularity and Date() resolution.
            XCTAssertGreaterThanOrEqual(
                elapsed, earliest - 0.01,
                "grant \(index) arrived \(elapsed)s in, before its \(earliest)s slot")
        }
    }
}

/// Collects grant timestamps from concurrent tasks.
private actor GrantRecorder {
    private var times: [Date] = []
    func record(_ t: Date) { times.append(t) }
    func sorted() -> [Date] { times.sorted() }
}
