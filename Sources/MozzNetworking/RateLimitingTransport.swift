import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An ``HTTPTransport`` decorator that rate-limits *actual outbound requests*.
///
/// It sits BELOW ``HTTPClient``'s retry loop (which calls `transport.send` once
/// per attempt), so every attempt — including retries — acquires a limiter slot.
/// That is what keeps a retrying client within a strict server budget (e.g.
/// MusicBrainz's 1 req/s).
///
/// When the server signals throttling (HTTP 503 or 429) with a `Retry-After`
/// header, the transport pushes the shared limiter's next slot forward so the
/// automatic retry actually waits the requested back-off — without changing the
/// app-wide error type. The response is returned unchanged for the client to
/// validate.
public struct RateLimitingTransport: HTTPTransport {
    private let inner: any HTTPTransport
    private let limiter: AsyncRateLimiter
    private let now: @Sendable () -> Date

    public init(
        wrapping inner: any HTTPTransport,
        limiter: AsyncRateLimiter,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inner = inner
        self.limiter = limiter
        self.now = now
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await limiter.acquire()
        let (data, response) = try await inner.send(request)
        if response.statusCode == 503 || response.statusCode == 429,
           let retryAfter = Self.retryAfterSeconds(response) {
            await limiter.penalize(until: now().addingTimeInterval(retryAfter))
        }
        return (data, response)
    }

    /// Parse a `Retry-After` header (delta-seconds, or an HTTP-date), clamped to
    /// a sane ceiling so a hostile/bogus value can't wedge the limiter for hours.
    static func retryAfterSeconds(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = (response.value(forHTTPHeaderField: "Retry-After")
            ?? response.value(forHTTPHeaderField: "retry-after"))?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let ceiling: TimeInterval = 120
        if let seconds = TimeInterval(raw) {
            return min(max(0, seconds), ceiling)
        }
        if let date = Self.httpDateFormatter.date(from: raw) {
            return min(max(0, date.timeIntervalSinceNow), ceiling)
        }
        return nil
    }

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()
}
