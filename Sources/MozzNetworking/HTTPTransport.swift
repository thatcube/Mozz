import Foundation
import MozzCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The seam that makes networking testable: the ``HTTPClient`` talks to a
/// transport, not to `URLSession` directly. Tests inject a mock that returns
/// recorded fixtures or simulated failures — no real sockets.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The production transport, backed by a configured `URLSession`.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    /// Build a session tuned for a role. Interactive calls (auth, browse) get
    /// tight timeouts so the UI never hangs; discovery gets very tight timeouts
    /// so unreachable candidate connections are abandoned quickly; bulk catalog
    /// sync gets a generous timeout because a single page of hundreds of items
    /// can take tens of seconds to generate on a slow/large self-hosted server
    /// (the request timeout is the inactivity gap, which spans the server's
    /// time-to-first-byte while it builds the response).
    public init(role: Role = .interactive) {
        let config = URLSessionConfiguration.ephemeral
        switch role {
        case .interactive:
            config.timeoutIntervalForRequest = 12
            config.timeoutIntervalForResource = 30
        case .discovery:
            config.timeoutIntervalForRequest = 3
            config.timeoutIntervalForResource = 5
        case .bulk:
            config.timeoutIntervalForRequest = 90
            config.timeoutIntervalForResource = 600
        }
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["Accept-Encoding": "gzip, deflate"]
        self.session = URLSession(configuration: config)
    }

    public enum Role: Sendable { case interactive, discovery, bulk }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MozzError.invalidResponse
            }
            return (data, http)
        } catch let error as MozzError {
            throw error
        } catch let urlError as URLError {
            switch urlError.code {
            case .cancelled:
                throw MozzError.cancelled
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                 .networkConnectionLost, .timedOut, .dnsLookupFailed, .secureConnectionFailed:
                throw MozzError.serverUnreachable
            default:
                throw MozzError.transport(urlError.localizedDescription)
            }
        } catch {
            throw MozzError.transport(error.localizedDescription)
        }
    }
}
