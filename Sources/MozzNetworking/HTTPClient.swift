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
    /// Query items appended to every request URL. Used by backends like Subsonic
    /// where every API call carries a fixed set of signing/protocol params
    /// (`u=`, `t=`, `s=` or `apiKey=`, plus `v=`, `c=`, `f=json`) — the client
    /// merges them once so the per-endpoint call sites stay clean and no code
    /// path can accidentally omit them. Non-secret request-scoped params on the
    /// `Endpoint` win over these when names collide.
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

    /// Return a copy with additional/overriding default query items (e.g. after
    /// re-signing a Subsonic session). Items with the same name replace the
    /// existing entry.
    public func withDefaultQueryItems(_ extra: [URLQueryItem]) -> HTTPClient {
        var merged = defaultQueryItems.filter { existing in
            !extra.contains(where: { $0.name == existing.name })
        }
        merged.append(contentsOf: extra)
        return HTTPClient(
            baseURL: baseURL,
            transport: transport,
            defaultHeaders: defaultHeaders,
            defaultQueryItems: merged,
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
        // Merge in this order: any existing query items on the base URL, the
        // client's default items (signing/protocol params), then the endpoint's
        // own items. Endpoint items with a name that collides with a default
        // item WIN so a call site can override a signing param when it truly
        // needs to (rarely) without mutating the client's defaults.
        var merged = components.queryItems ?? []
        if !defaultQueryItems.isEmpty {
            let endpointNames = Set(endpoint.query.map(\.name))
            merged.append(contentsOf: defaultQueryItems.filter { !endpointNames.contains($0.name) })
        }
        if !endpoint.query.isEmpty {
            merged.append(contentsOf: endpoint.query)
        }
        if !merged.isEmpty { components.queryItems = merged }
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
