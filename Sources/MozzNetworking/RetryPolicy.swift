import Foundation

/// Controls automatic retries for transient failures (unreachable server, 5xx,
/// 429). Uses exponential backoff with full jitter to avoid thundering herds
/// when a server recovers. Non-retryable errors (401/404/decoding) fail fast.
public struct RetryPolicy: Sendable {
    public var maxRetries: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval

    public init(maxRetries: Int = 2, baseDelay: TimeInterval = 0.3, maxDelay: TimeInterval = 4) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// No retries — used for tests and for latency-critical paths.
    public static let none = RetryPolicy(maxRetries: 0)
    public static let `default` = RetryPolicy()

    /// Delay before the given 1-based attempt, with full jitter.
    public func delay(forAttempt attempt: Int, random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }) -> TimeInterval {
        let exponential = baseDelay * pow(2, Double(attempt - 1))
        let capped = min(maxDelay, exponential)
        return random(0...capped)
    }
}
