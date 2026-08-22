import XCTest
@testable import MozzEnrichment

final class NetworkBackoffTests: XCTestCase {

    /// A clock we control, so the tests assert real cooldown behaviour without
    /// sleeping.
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { now += seconds }
        var read: @Sendable () -> Date { { [self] in now } }
    }

    // MARK: The healthy case must be untouched

    func testStaysOpenOnAHealthyConnection() async {
        let clock = Clock()
        let backoff = NetworkBackoff(now: clock.read)
        for _ in 0..<50 {
            let allowed = await backoff.shouldAttempt()
            XCTAssertTrue(allowed)
            await backoff.recordSuccess()
        }
    }

    /// The single most important property: someone just listening on working
    /// internet must never be gated, even if the odd request fails.
    func testOccasionalFailuresDoNotClose() async {
        let clock = Clock()
        let backoff = NetworkBackoff(threshold: 3, now: clock.read)
        for _ in 0..<10 {
            _ = await backoff.shouldAttempt()
            await backoff.recordFailure()
            _ = await backoff.shouldAttempt()
            await backoff.recordSuccess()
            let open = await backoff.isOpen
            XCTAssertTrue(open, "an isolated failure between successes must not close the gate")
        }
    }

    // MARK: Closing

    func testClosesOnlyAfterConsecutiveFailures() async {
        let clock = Clock()
        let backoff = NetworkBackoff(threshold: 3, baseCooldown: 30, now: clock.read)
        for _ in 0..<2 {
            _ = await backoff.shouldAttempt()
            await backoff.recordFailure()
        }
        var open = await backoff.isOpen
        XCTAssertTrue(open, "still open below the threshold")

        _ = await backoff.shouldAttempt()
        await backoff.recordFailure()
        open = await backoff.isOpen
        XCTAssertFalse(open, "closed once the threshold is reached")

        let allowed = await backoff.shouldAttempt()
        XCTAssertFalse(allowed)
    }

    // MARK: Recovery

    /// After the cooldown exactly one probe goes through — not a fresh flood.
    func testAllowsASingleProbeAfterCooldown() async {
        let clock = Clock()
        let backoff = NetworkBackoff(threshold: 1, baseCooldown: 30, now: clock.read)
        _ = await backoff.shouldAttempt()
        await backoff.recordFailure()

        var allowed = await backoff.shouldAttempt()
        XCTAssertFalse(allowed, "closed during the cooldown")

        clock.advance(31)
        allowed = await backoff.shouldAttempt()
        XCTAssertTrue(allowed, "one probe after the cooldown")
        let second = await backoff.shouldAttempt()
        XCTAssertFalse(second, "but only one until it reports back")
    }

    /// Recovery is immediate — a single success reopens the gate rather than
    /// making the user wait out the rest of a cooldown.
    func testSuccessReopensImmediately() async {
        let clock = Clock()
        let backoff = NetworkBackoff(threshold: 1, baseCooldown: 30, now: clock.read)
        _ = await backoff.shouldAttempt()
        await backoff.recordFailure()
        clock.advance(31)
        _ = await backoff.shouldAttempt()
        await backoff.recordSuccess()

        let allowed = await backoff.shouldAttempt()
        XCTAssertTrue(allowed)
        let open = await backoff.isOpen
        XCTAssertTrue(open)
    }

    func testCooldownDoublesAndIsCapped() async {
        let clock = Clock()
        let backoff = NetworkBackoff(threshold: 1, baseCooldown: 10, maxCooldown: 40, now: clock.read)
        // 1st failure → 10s
        _ = await backoff.shouldAttempt()
        await backoff.recordFailure()
        clock.advance(9)
        var allowed = await backoff.shouldAttempt()
        XCTAssertFalse(allowed)
        clock.advance(2)
        allowed = await backoff.shouldAttempt()
        XCTAssertTrue(allowed)

        // 2nd → 20s, 3rd → 40s, 4th → capped at 40s.
        await backoff.recordFailure()
        clock.advance(21)
        _ = await backoff.shouldAttempt()
        await backoff.recordFailure()
        clock.advance(41)
        _ = await backoff.shouldAttempt()
        await backoff.recordFailure()
        clock.advance(41)
        allowed = await backoff.shouldAttempt()
        XCTAssertTrue(allowed, "the cooldown must stop growing at the cap")
    }
}
