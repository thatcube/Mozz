import Foundation

/// A minimum-interval async limiter: `acquire()` returns spaced at least
/// `minInterval` apart, serializing concurrent callers deterministically.
///
/// The slot is reserved (by advancing `nextAllowed`) *before* the `await`, so
/// several concurrent `acquire()` calls each grab a distinct future slot rather
/// than all waking at once — the property MusicBrainz's 1 req/s rule needs. A
/// 503/429 with `Retry-After` pushes the next slot forward via ``penalize(until:)``.
///
/// `now`/`sleep` are injectable so tests assert spacing without real waits.
public actor AsyncRateLimiter {
    private let minInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var nextAllowed: Date = .distantPast

    public init(
        minInterval: TimeInterval,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.minInterval = max(0, minInterval)
        self.now = now
        self.sleep = sleep
    }

    /// Block until this caller's reserved slot; throws `CancellationError` if the
    /// wait is cancelled.
    public func acquire() async throws {
        let current = now()
        let scheduled = max(current, nextAllowed)
        // Reserve BEFORE awaiting so concurrent callers serialize.
        nextAllowed = scheduled.addingTimeInterval(minInterval)
        let wait = scheduled.timeIntervalSince(current)
        if wait > 0 { try await sleep(wait) }
    }

    /// Delay all future acquisitions until at least `date` (server back-off).
    public func penalize(until date: Date) {
        if date > nextAllowed { nextAllowed = date }
    }

    /// Test hook: the currently reserved next slot.
    public func currentNextAllowed() -> Date { nextAllowed }
}
