import Foundation

/// A concurrency-safe **token-bucket** limiter for being a polite client of a
/// keyless public API (LRCLIB asks callers to stay around ~1 request/second).
///
/// The bucket starts full with `burst` tokens and refills continuously at
/// `requestsPerSecond`. ``acquire()`` consumes one token, waiting only when the
/// bucket is empty — so a short burst passes with no delay (a single visible
/// lyrics lookup fans out several requests and must still feel instant) while
/// sustained background traffic is throttled toward the sustained rate.
///
/// ### Why this and not ``AsyncRateLimiter``
/// ``AsyncRateLimiter`` hands out monotonically increasing slots and advances a
/// cursor on every `acquire()`. That is the right shape for MusicBrainz, whose
/// traffic is a steady enrichment queue. It is the *wrong* shape for lyrics,
/// which fire prefetch requests that are routinely cancelled the instant the
/// user skips a track: each cancelled request has already pushed the cursor
/// seconds into the future and never rolls it back, so the schedule stays
/// poisoned and the next **visible** lookup inherits a multi-second reservation
/// — then gets cancelled itself on the next skip. Lyrics only appear once the
/// user stops skipping and the phantom backlog drains.
///
/// A token bucket is inherently cancellation-safe: a token is consumed **only**
/// when one is actually available, *after* any wait. A request cancelled while
/// waiting consumes nothing and leaves the bucket untouched, so it cannot delay
/// later callers, and a freshly arriving request proceeds as soon as a token is
/// free rather than queueing behind abandoned reservations.
///
/// `now`/`sleep` are injectable so tests assert pacing without real waits.
public actor TokenBucketLimiter {
    /// Maximum tokens the bucket can hold (the burst allowance).
    private let capacity: Double
    /// Tokens replenished per second once the burst is spent.
    private let refillPerSecond: Double
    /// Currently available tokens (fractional between whole requests).
    private var tokens: Double
    /// When `tokens` was last brought up to date.
    private var lastRefill: Date
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// - Parameters:
    ///   - requestsPerSecond: Sustained ceiling once the burst is exhausted.
    ///   - burst: How many requests may fire back-to-back with no delay after an
    ///     idle period.
    public init(
        requestsPerSecond: Double,
        burst: Int,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.refillPerSecond = max(requestsPerSecond, 0.0001)
        self.capacity = Double(max(burst, 1))
        self.tokens = Double(max(burst, 1))
        self.now = now
        self.lastRefill = now()
        self.sleep = sleep
    }

    /// Consume one token, waiting until one is available. Returns immediately
    /// while within the burst allowance.
    ///
    /// If the calling task is cancelled while waiting this returns **without**
    /// consuming a token, so a cancelled prefetch can never affect the pacing of
    /// a live request.
    public func acquire() async {
        while true {
            refill()
            if tokens >= 1 {
                tokens -= 1
                return
            }
            // Bucket empty: wait just long enough for one token to accrue.
            let wait = (1 - tokens) / refillPerSecond
            try? await sleep(wait)
            if Task.isCancelled { return }
        }
    }

    /// Brings `tokens` up to date for the time elapsed since the last refill,
    /// clamped to `capacity`.
    private func refill() {
        let current = now()
        let elapsed = current.timeIntervalSince(lastRefill)
        if elapsed > 0 {
            tokens = min(capacity, tokens + elapsed * refillPerSecond)
            lastRefill = current
        }
    }
}
