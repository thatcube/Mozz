import Foundation
import MozzCore
import MozzNetworking

/// The single choke point for talking to a Subsonic / OpenSubsonic server.
///
/// Every concern that must be identical on *every* request lives here so it can
/// never be forgotten at a call site (spec item 6):
/// - **Signing.** Common params (`v`, `c`, `f=json`) plus the credential's auth
///   params (`apiKey`, or `u`/`t`/`s`) are attached to every request via the
///   ``HTTPClient``'s `defaultQueryItems`, and the SAME signed items are reused
///   to build media/artwork/download URLs so those are signed identically (and,
///   with a stable salt/apiKey, are deterministic across launches).
/// - **Envelope decoding.** Subsonic returns errors over **HTTP 200** with
///   `status == "failed"` + an `error.code`. ``send(_:query:as:)`` decodes the
///   `subsonic-response` envelope and maps the code to ``MozzError`` so a failed
///   call never looks like success.
/// - **Binary safety.** ``fetchBinary(_:query:)`` (and the static
///   ``validateBinary(status:contentType:)``) reject a response whose HTTP
///   status or content-type indicates an XML/JSON/HTML *error body*, so an error
///   page is NEVER written to disk as an audio file.
public struct SubsonicClient: Sendable {
    public let baseURL: URL
    private let credential: SubsonicCredential
    private let clientInfo: ClientInfo
    private let client: HTTPClient
    private let transport: any HTTPTransport
    /// The signing items shared by API calls and media URLs (so an artwork URL
    /// is signed exactly like a `getCoverArt` API call would be).
    private let signingItems: [URLQueryItem]

    /// The Subsonic API protocol version we advertise. 1.16.1 is the last
    /// classic-Subsonic version and is accepted by every OpenSubsonic server; the
    /// concrete server product/version is detected separately from `ping`.
    public static let apiVersion = "1.16.1"

    public init(
        baseURL: URL,
        credential: SubsonicCredential,
        clientInfo: ClientInfo,
        transport: any HTTPTransport = URLSessionTransport(),
        logger: any NetworkLogger = NoopNetworkLogger()
    ) {
        self.baseURL = baseURL
        self.credential = credential
        self.clientInfo = clientInfo
        self.transport = transport
        var items = [
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: clientInfo.product),
            URLQueryItem(name: "f", value: "json"),
        ]
        items.append(contentsOf: credential.signingQueryItems())
        self.signingItems = items
        self.client = HTTPClient(
            baseURL: baseURL,
            transport: transport,
            defaultQueryItems: items,
            logger: logger
        )
    }

    // MARK: JSON API

    /// Send a signed request to `/rest/{name}.view`, decode the
    /// `subsonic-response` envelope, and return its body. Throws a mapped
    /// ``MozzError`` if the envelope reports `status == "failed"`.
    @discardableResult
    func send<Payload: Decodable>(
        _ name: String,
        query: [URLQueryItem] = [],
        as payload: Payload.Type
    ) async throws -> SubsonicResponseBody<Payload> {
        let endpoint = Endpoint(path: "rest/\(name).view", query: query)
        let envelope = try await client.send(endpoint, as: SubsonicEnvelope<Payload>.self)
        let body = envelope.response
        if body.isFailed {
            throw Self.mapError(code: body.error?.code, message: body.error?.message)
        }
        return body
    }

    // MARK: Binary (stream / download / cover art bytes)

    /// Fetch the raw bytes of a signed binary endpoint (`stream`, `download`,
    /// `getCoverArt`), validating the HTTP status and content-type first so a
    /// Subsonic XML/JSON error body — which arrives over HTTP 200 — is rejected
    /// as an error instead of being handed back as "audio".
    public func fetchBinary(_ name: String, query: [URLQueryItem] = []) async throws -> Data {
        let endpoint = Endpoint(path: "rest/\(name).view", query: query)
        let request = try client.makeRequest(endpoint)
        let (data, response) = try await transport.send(request)
        try Self.validateBinary(
            status: response.statusCode,
            contentType: response.value(forHTTPHeaderField: "Content-Type")
        )
        return data
    }

    /// Build a signed media URL for `/rest/{name}.view` (used for stream,
    /// download and cover-art URLs handed to AVFoundation / the download
    /// session). Reuses the exact signing of the JSON path, so — with a stable
    /// salt or apiKey — the URL is deterministic across launches.
    public func mediaURL(_ name: String, query: [URLQueryItem] = []) -> URL? {
        let endpoint = Endpoint(path: "rest/\(name).view", query: query)
        return try? client.makeRequest(endpoint).url
    }

    // MARK: Validation

    /// Reject a binary response whose HTTP status or content-type shows it is an
    /// error body rather than media. Content-types treated as "not audio":
    /// anything `text/*`, plus `application/xml` and `application/json` (the two
    /// shapes a Subsonic error takes). Audio/octet-stream and unknown types pass
    /// (be permissive about real audio MIME types we don't enumerate).
    public static func validateBinary(status: Int, contentType: String?) throws {
        switch status {
        case 200...299:
            break
        case 401, 403:
            throw MozzError.unauthorized
        case 404:
            throw MozzError.notFound
        default:
            throw MozzError.badStatus(status)
        }
        guard let contentType else { return }
        let lower = contentType.lowercased()
        let mime = lower.split(separator: ";").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? lower
        if mime.hasPrefix("text/")
            || mime == "application/xml"
            || mime == "application/json"
            || mime.contains("xml") {
            throw MozzError.invalidResponse
        }
    }

    /// Map a Subsonic `error.code` to a ``MozzError``. Codes per the Subsonic
    /// API: 40 wrong credentials, 44 invalid apiKey, 50 not authorized → auth
    /// failures; 70 the requested data was not found; the rest (0/10/20/30/41/
    /// 42/43/60) surface as ``MozzError/unsupported(_:)`` carrying the server's
    /// message so the real reason is not lost.
    public static func mapError(code: Int?, message: String?) -> MozzError {
        let detail = message ?? "Subsonic error \(code.map(String.init) ?? "?")"
        switch code {
        case 40, 44, 50:
            return .unauthorized
        case 70:
            return .notFound
        default:
            return .unsupported(detail)
        }
    }
}
