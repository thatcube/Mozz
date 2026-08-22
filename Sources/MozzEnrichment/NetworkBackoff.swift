import Foundation

/// A small circuit breaker for **optional** network work, so a bad connection
/// costs one failed attempt rather than one per song forever.
///
/// The whole point of this type is to do nothing at all on a healthy connection.
/// It only counts *consecutive transport failures* — an answer of "there are no
/// lyrics for this track" is a success, not a failure — and a single success
/// resets it completely. So the ordinary case of listening with working internet
/// never trips it, and never waits on it.
///
/// When it does trip it stays closed for a short, doubling cooldown, then lets a
/// single probe through (half-open). That probe succeeding reopens the gate
/// immediately, so recovering from a dead spot takes one request, not a full
/// cooldown. Callers can also bypass it outright for anything the user explicitly
/// asked for — a deliberate tap should always try, however bad the network is.
public actor NetworkBackoff {
    /// Consecutive transport failures before the gate closes at all. Deliberately
    /// more than one: a single blip on an otherwise fine connection should cost
    /// nothing.
    private let threshold: Int
    /// Cooldown after the threshold is first crossed.
    private let baseCooldown: TimeInterval
    /// Ceiling on the doubling, so a long outage still retries periodically
    /// rather than giving up until the app restarts.
    private let maxCooldown: TimeInterval
    private let now: @Sendable () -> Date

    private var consecutiveFailures = 0
    private var closedUntil: Date?
    /// True once a cooldown has elapsed and we are allowing one probe through.
    /// Kept so a *second* caller during the same window doesn't also get through.
    private var probeInFlight = false

    public init(
        threshold: Int = 3,
        baseCooldown: TimeInterval = 30,
        maxCooldown: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.threshold = max(1, threshold)
        self.baseCooldown = max(1, baseCooldown)
        self.maxCooldown = max(baseCooldown, maxCooldown)
        self.now = now
    }

    /// Whether an attempt should be made now.
    ///
    /// Returns `true` on a healthy connection, always. Once tripped it returns
    /// `false` until the cooldown elapses, then `true` exactly once so a single
    /// probe can test the water.
    public func shouldAttempt() -> Bool {
        guard let closedUntil else { return true }
        guard now() >= closedUntil else { return false }
        // Cooldown elapsed: let one probe through and hold the gate for anyone
        // else until it reports back.
        if probeInFlight { return false }
        probeInFlight = true
        return true
    }

    /// The attempt reached the server (including a definitive "not found").
    /// Clears everything — recovery is immediate, not gradual.
    public func recordSuccess() {
        consecutiveFailures = 0
        closedUntil = nil
        probeInFlight = false
    }

    /// The attempt could not reach the server at all.
    public func recordFailure() {
        probeInFlight = false
        consecutiveFailures += 1
        guard consecutiveFailures >= threshold else { return }
        let doublings = consecutiveFailures - threshold
        let cooldown = min(maxCooldown, baseCooldown * pow(2, Double(doublings)))
        closedUntil = now().addingTimeInterval(cooldown)
    }

    /// Test/diagnostic view of the gate.
    public var isOpen: Bool {
        guard let closedUntil else { return true }
        return now() >= closedUntil
    }
}
