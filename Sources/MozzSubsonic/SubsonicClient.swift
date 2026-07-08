import Foundation
import MozzCore
import MozzNetworking

/// The single choke point for all Subsonic/OpenSubsonic wire traffic.
///
/// Responsibilities (deliberately centralized here, not spread across
/// ``SubsonicBackend``):
/// - **Signs every request identically.** JSON API calls and binary
///   (stream/download/getCoverArt) fetches both go through the same
///   `HTTPClient` signing hook, so there is exactly one place that knows how
///   to turn a ``SubsonicCredential`` into query items.
/// - **Decodes the `subsonic-response` envelope and maps its errors.**
///   Subsonic reports failures over HTTP 200 with `status: "failed"` and a
///   numeric `error.code` — `HTTPClient`'s ordinary HTTP-status validation
///   never sees these, so this layer decodes the envelope first and only then
///   decides success/failure.
/// - **Validates binary responses.** `stream`/`download`/`getCoverArt` return
///   binary data on success but an error envelope (XML by default, sometimes
///   JSON) on failure — with a 200 status. Trusting the bytes without
///   checking `Content-Type` first would let an error page get saved to disk
///   as if it were an audio file.
struct SubsonicClient: Sendable {
    let baseURL: URL
    let credential: SubsonicCredential
    private let http: HTTPClient

    init(
        baseURL: URL,
        credential: SubsonicCredential,
        transport: any HTTPTransport = URLSessionTransport()
    ) throws {
        self.baseURL = baseURL
        self.credential = credential
        // Computed ONCE (not per-request): a bad credential (e.g. md5 mode
        // missing its salt) fails fast at construction rather than on the
        // first call.
        let signingItems = try SubsonicAuth.queryItems(for: credential)
        self.http = HTTPClient(baseURL: baseURL, transport: transport, defaultQueryItems: { signingItems })
    }

    // MARK: JSON calls

    /// Call a `/rest/<action>` JSON endpoint and return its decoded envelope,
    /// having already validated `status == "ok"` (a `failed` status throws the
    /// error-code-mapped ``MozzError``, so callers never see a "successful"
    /// response that was actually a server-side rejection).
    @discardableResult
    func call(_ action: String, query: [URLQueryItem] = []) async throws -> SubsonicResponseDTO {
        let endpoint = Endpoint(path: "/rest/\(action).view", query: query)
        let envelope = try await http.send(endpoint, as: SubsonicEnvelopeDTO.self)
        let response = envelope.response
        guard response.status == "ok" else {
            throw Self.mapError(response.error)
        }
        return response
    }

    // MARK: Binary + URL building

    /// A fully signed URL for a `/rest/<action>` endpoint. Used both by
    /// ``fetchBinary(action:query:)`` (which additionally validates the
    /// response) and directly by backend URL builders (`streamSource`,
    /// `originalFileURL`, `artworkURL`) that hand a bare `URL` to
    /// AVFoundation or a background download session — those never round-trip
    /// through this client, so response validation only ever protects calls
    /// made THROUGH it (see ``fetchBinary(action:query:)`` doc).
    func signedURL(action: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("rest/\(action).view"),
            resolvingAgainstBaseURL: false
        ) else {
            throw MozzError.invalidResponse
        }
        let items = query + (try SubsonicAuth.queryItems(for: credential))
        components.queryItems = (components.queryItems ?? []) + items
        guard let url = components.url else { throw MozzError.invalidResponse }
        return url
    }

    /// Fetch a binary endpoint (`stream`/`download`/`getCoverArt`) and
    /// validate that the response is genuinely binary media, not a
    /// `subsonic-response` error envelope wearing a 200 status. See the type
    /// doc for why this matters.
    func fetchBinary(action: String, query: [URLQueryItem]) async throws -> Data {
        let endpoint = Endpoint(path: "/rest/\(action).view", query: query)
        let (data, response) = try await http.sendWithResponse(endpoint)
        try Self.validateBinaryResponse(data: data, response: response)
        return data
    }

    /// Throws a mapped ``MozzError`` if `response`/`data` look like an error
    /// envelope rather than binary media. Binary endpoints report errors as a
    /// 200 OK whose `Content-Type` is `text/xml` (the spec states this is true
    /// "regardless" of the requested format) or occasionally
    /// `application/json` — never an `audio/*`, `image/*` or
    /// `application/octet-stream` type a real stream/cover would carry.
    static func validateBinaryResponse(data: Data, response: HTTPURLResponse) throws {
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let looksBinary = contentType.hasPrefix("audio/") || contentType.hasPrefix("image/")
            || contentType.hasPrefix("video/") || contentType.hasPrefix("application/octet-stream")
        guard !looksBinary else { return }

        // Not a binary content type. If it happens to be JSON, decode the
        // precise error; otherwise (XML, or anything else undecodable)
        // surface a generic-but-safe failure rather than silently handing
        // back what would otherwise masquerade as a zero-byte "song".
        if contentType.contains("json"), let envelope = try? JSONDecoder().decode(SubsonicEnvelopeDTO.self, from: data) {
            throw mapError(envelope.response.error)
        }
        throw MozzError.invalidResponse
    }

    // MARK: Error mapping

    /// Maps the Subsonic error envelope's numeric `code` to the closest
    /// ``MozzError``. Codes 40/41/42/43/44/50 are the ones the architecture
    /// spec calls out explicitly (auth-adjacent); the remaining defined codes
    /// (0, 10, 20, 30, 60, 70) are mapped defensively too so no Subsonic
    /// failure path ever falls through unhandled.
    static func mapError(_ error: SubsonicErrorDTO?) -> MozzError {
        guard let error else { return .invalidResponse }
        switch error.code {
        case 40, 44:
            // Wrong username/password; invalid API key.
            return .unauthorized
        case 50:
            // Authenticated, but not authorized for this operation — closest
            // to a 403, which HTTPClient itself already maps to .unauthorized.
            return .unauthorized
        case 41:
            return .unsupported(error.message ?? "This server requires legacy password authentication for LDAP users, which Mozz doesn't support yet.")
        case 42:
            return .unsupported(error.message ?? "This server doesn't support the authentication method Mozz used.")
        case 43:
            // Should be unreachable: the single signing choke point never
            // sends more than one auth mechanism. Mapped defensively rather
            // than force-unwrapped/crashed on.
            return .unsupported(error.message ?? "Mozz sent conflicting authentication parameters (internal error).")
        case 70:
            return .notFound
        case 20, 30:
            return .unsupported(error.message ?? "This server uses an incompatible Subsonic protocol version.")
        case 60:
            return .unsupported(error.message ?? "This server's trial period has ended.")
        case 10:
            return .unsupported(error.message ?? "Subsonic rejected the request (a required parameter was missing).")
        default:
            return .transport(error.message ?? "Subsonic error \(error.code)")
        }
    }
}
