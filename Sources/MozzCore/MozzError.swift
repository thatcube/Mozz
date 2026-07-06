import Foundation

/// The single error type surfaced across Mozz's backend, networking, sync and
/// download layers. Providers map their transport/HTTP failures into these
/// cases so higher layers can react uniformly (e.g. prompt re-auth on
/// ``unauthorized``, retry on ``transport`` / ``serverUnreachable``).
public enum MozzError: Error, Sendable, Hashable {
    /// Credentials are missing, expired or rejected (HTTP 401/403).
    case unauthorized
    /// The requested resource does not exist (HTTP 404).
    case notFound
    /// The request conflicts with server state (HTTP 409).
    case conflict
    /// A well-formed HTTP response with an unexpected status code.
    case badStatus(Int)
    /// The server could not be reached at all (DNS/connection failure,
    /// airplane mode). Distinct from ``badStatus`` because it is retryable and,
    /// for offline playback, expected.
    case serverUnreachable
    /// The response body could not be decoded into the expected shape.
    case decodingFailed(String)
    /// The response was structurally invalid (missing container, etc.).
    case invalidResponse
    /// A feature was requested that this server/backend does not support.
    case unsupported(String)
    /// The operation was cancelled.
    case cancelled
    /// A lower-level transport error that does not map to the above.
    case transport(String)

    /// Whether retrying the same request could plausibly succeed.
    public var isRetryable: Bool {
        switch self {
        case .serverUnreachable, .transport:
            return true
        case .badStatus(let code):
            // 5xx and 429 are worth retrying; 4xx (except 429) are not.
            return code == 429 || (500...599).contains(code)
        case .unauthorized, .notFound, .conflict, .decodingFailed,
             .invalidResponse, .unsupported, .cancelled:
            return false
        }
    }

    /// Whether the failure indicates the network/server was unreachable, as
    /// opposed to a server-side rejection. Used by the offline resolver to
    /// decide whether to fall back to a downloaded copy.
    public var isReachabilityFailure: Bool {
        switch self {
        case .serverUnreachable, .transport:
            return true
        default:
            return false
        }
    }
}

extension MozzError: LocalizedError {
    /// A human-readable message. Without this, `localizedDescription` falls back
    /// to the opaque "The operation couldn't be completed. (MozzCore.MozzError
    /// error N.)" — which hid the descriptive text carried by `unsupported`,
    /// `decodingFailed` and `transport` (e.g. the reason a Plex sync failed).
    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Your sign-in has expired or was rejected. Please sign in again."
        case .notFound:
            return "The requested item was not found on the server."
        case .conflict:
            return "The request conflicted with the server's current state."
        case .badStatus(let code):
            return "The server returned an unexpected status (\(code))."
        case .serverUnreachable:
            return "Couldn't reach the server. Check your connection and try again."
        case .decodingFailed(let detail):
            return "Couldn't read the server's response. \(detail)"
        case .invalidResponse:
            return "The server's response was not in the expected format."
        case .unsupported(let detail):
            return detail
        case .cancelled:
            return "The operation was cancelled."
        case .transport(let detail):
            return detail
        }
    }
}
