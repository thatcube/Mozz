import Foundation

public enum HTTPMethod: String, Sendable, Hashable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

/// A backend-relative API request. Resolved against an ``HTTPClient``'s base
/// URL. Media URLs (stream/download/artwork) are built directly by providers,
/// so this type is only ever used for JSON API calls.
public struct Endpoint: Sendable {
    public var method: HTTPMethod
    /// Path appended to the client base URL (leading slash optional).
    public var path: String
    public var query: [URLQueryItem]
    public var headers: [String: String]
    public var body: Data?

    public init(
        method: HTTPMethod = .get,
        path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// Convenience for a JSON POST with an `Encodable` body.
    public static func jsonPost(
        _ path: String,
        body: some Encodable,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> Endpoint {
        var headers = headers
        headers["Content-Type"] = "application/json"
        return Endpoint(
            method: .post,
            path: path,
            query: query,
            headers: headers,
            body: try encoder.encode(body)
        )
    }
}
