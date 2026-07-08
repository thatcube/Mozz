import Foundation
import MozzCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A small async JSON API client bound to a single host.
///
/// Responsibilities: build requests against a base URL, apply default headers
/// (auth), map HTTP status codes to ``MozzError``, retry transient failures
/// with backoff, and decode responses. It never touches media bytes — audio
/// streaming and downloads use their own URLs and sessions.
///
/// Providers that talk to two hosts (e.g. Plex uses both `plex.tv` and the
/// server) simply hold two clients.
public struct HTTPClient: Sendable {
    public let baseURL: URL
    private let transport: any HTTPTransport
    private let defaultHeaders: [String: String]
    private let defaultQueryItems: [URLQueryItem]
    private let retryPolicy: RetryPolicy
    private let logger: any NetworkLogger

    public init(
        baseURL: URL,
        transport: any HTTPTransport = URLSessionTransport(),
        defaultHeaders: [String: String] = [:],
        defaultQueryItems: [URLQueryItem] = [],
        retryPolicy: RetryPolicy = .default,
        logger: any NetworkLogger = NoopNetworkLogger()
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.defaultHeaders = defaultHeaders
        self.defaultQueryItems = defaultQueryItems
        self.retryPolicy = retryPolicy
        self.logger = logger
    }

    /// Return a copy with additional/overriding default headers (e.g. after
    /// auth yields a token). Keeps ``HTTPClient`` a value type.
    public func withDefaultHeaders(_ extra: [String: String]) -> HTTPClient {
        HTTPClient(
            baseURL: baseURL,
            transport: transport,
            defaultHeaders: defaultHeaders.merging(extra) { _, new in new },
            defaultQueryItems: defaultQueryItems,
            retryPolicy: retryPolicy,
            logger: logger
        )
    }

    /// Return a copy with default query items appended to *every* request (and
    /// preserved by ``makeRequest`` so the same signed URL can be reused for
    /// media/download sessions). This is the ergonomic signing hook used by
    /// Subsonic, whose every call carries the same `u`/`t`/`s`/`v`/`c`/`f`
    /// authentication parameters.
    public func withDefaultQueryItems(_ extra: [URLQueryItem]) -> HTTPClient {
        HTTPClient(
            baseURL: baseURL,
            transport: transport,
            defaultHeaders: defaultHeaders,
            defaultQueryItems: defaultQueryItems + extra,
            retryPolicy: retryPolicy,
            logger: logger
        )
    }

    // MARK: Sending

    /// Send a request and return the raw body. Retries transient failures.
    @discardableResult
    public func send(_ endpoint: Endpoint) async throws -> Data {
        let request = try makeRequest(endpoint)
        return try await withRetry {
            logger.log("\(endpoint.method.rawValue) \(SecretRedactor.redacted(request.url ?? baseURL))")
            let (data, response) = try await transport.send(request)
            try Self.validate(response, data: data, logger: logger)
            return data
        }
    }

    /// Send a request and decode the JSON body into `T`.
    public func send<T: Decodable>(
        _ endpoint: Endpoint,
        as type: T.Type,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> T {
        let data = try await send(endpoint)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            logger.log("decode \(T.self) failed: \(error)")
            throw MozzError.decodingFailed("\(T.self): \(error)")
        }
    }

    // MARK: Request building

    /// Resolve an endpoint into a `URLRequest` against the base URL. Public so
    /// providers can reuse the exact header/auth setup when handing a URL to a
    /// download session.
    public func makeRequest(_ endpoint: Endpoint) throws -> URLRequest {
        let trimmed = endpoint.path.hasPrefix("/") ? String(endpoint.path.dropFirst()) : endpoint.path
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(trimmed),
            resolvingAgainstBaseURL: false
        ) else {
            throw MozzError.invalidResponse
        }
        if !defaultQueryItems.isEmpty || !endpoint.query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + defaultQueryItems + endpoint.query
        }
        guard let url = components.url else { throw MozzError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        for (key, value) in defaultHeaders { request.setValue(value, forHTTPHeaderField: key) }
        for (key, value) in endpoint.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = endpoint.body
        return request
    }

    // MARK: Status mapping + retry

    static func validate(_ response: HTTPURLResponse, data: Data, logger: any NetworkLogger) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw MozzError.unauthorized
        case 404:
            throw MozzError.notFound
        case 409:
            throw MozzError.conflict
        default:
            logger.log("HTTP \(response.statusCode) (\(data.count) bytes)")
            throw MozzError.badStatus(response.statusCode)
        }
    }

    private func withRetry<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch let error as MozzError where error.isRetryable && attempt < retryPolicy.maxRetries {
                attempt += 1
                let delay = retryPolicy.delay(forAttempt: attempt)
                logger.log("retry \(attempt)/\(retryPolicy.maxRetries) after \(String(format: "%.2f", delay))s (\(error))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }
}
