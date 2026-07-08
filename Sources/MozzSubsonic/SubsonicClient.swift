import Foundation
import MozzCore
import MozzNetworking

/// Choke point for every Subsonic API call: signs the request via default query
/// items on ``HTTPClient``, decodes the `subsonic-response` envelope, and maps
/// ``SSError`` codes into ``MozzError``. Also validates binary media responses
/// so an XML/JSON error body served over HTTP 200 is NEVER written to disk as
/// an audio file (a classic Subsonic-client bug that permanently corrupts the
/// user's offline library).
///
/// Immutable + `Sendable` because everything above it (sync, playback,
/// downloads) shares a single client across concurrency domains.
public struct SubsonicClient: Sendable {
    public let baseURL: URL
    public let credentials: SubsonicCredentials
    public let clientInfo: ClientInfo
    let httpClient: HTTPClient

    public init(
        baseURL: URL,
        credentials: SubsonicCredentials,
        clientInfo: ClientInfo,
        transport: any HTTPTransport = URLSessionTransport(),
        logger: any NetworkLogger = NoopNetworkLogger()
    ) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.clientInfo = clientInfo
        self.httpClient = HTTPClient(
            baseURL: baseURL,
            transport: transport,
            defaultHeaders: ["Accept": "application/json"],
            defaultQueryItems: SubsonicAuthCoder.queryItems(for: credentials, clientInfo: clientInfo),
            logger: logger
        )
    }

    /// Return the full signed URL for an endpoint — used for media (stream,
    /// download, cover art) URLs handed to AVFoundation / URLSession downloads.
    /// The URL includes the signing query items appended by ``HTTPClient``.
    public func url(path: String, query: [URLQueryItem] = []) throws -> URL {
        let request = try httpClient.makeRequest(Endpoint(path: "rest/\(path)", query: query))
        guard let url = request.url else { throw MozzError.invalidResponse }
        return url
    }

    /// Send a JSON API call and return the typed payload under `payloadKey`.
    /// Throws ``MozzError`` on a `failed` envelope or a non-JSON binary body.
    public func send<T: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        payloadKey: String,
        as type: T.Type
    ) async throws -> T {
        let endpoint = Endpoint(path: "rest/\(path)", query: query)
        let data = try await httpClient.send(endpoint)
        let decoder = JSONDecoder()
        decoder.userInfo[.subsonicPayloadKey] = payloadKey
        let envelope: SSEnvelope<T>
        do {
            envelope = try decoder.decode(SSEnvelope<T>.self, from: data)
        } catch {
            throw MozzError.decodingFailed("subsonic envelope: \(error)")
        }
        let response = envelope.response
        if response.status == "failed" {
            throw Self.mapError(response.error)
        }
        guard let payload = response.payload else {
            throw MozzError.invalidResponse
        }
        return payload
    }

    /// Send a call where we only care that it succeeded (ping, star/unstar,
    /// setRating, scrobble). Still decodes the envelope so a `failed` status is
    /// surfaced as ``MozzError``.
    @discardableResult
    public func sendVoid(_ path: String, query: [URLQueryItem] = []) async throws -> SubsonicResponseMeta {
        let endpoint = Endpoint(path: "rest/\(path)", query: query)
        let data = try await httpClient.send(endpoint)
        let decoder = JSONDecoder()
        decoder.userInfo[.subsonicPayloadKey] = "__unused__"
        do {
            let envelope = try decoder.decode(SSEnvelope<SSPing>.self, from: data)
            let r = envelope.response
            if r.status == "failed" {
                throw Self.mapError(r.error)
            }
            return SubsonicResponseMeta(
                version: r.version, type: r.type, serverVersion: r.serverVersion
            )
        } catch let error as MozzError {
            throw error
        } catch {
            throw MozzError.decodingFailed("subsonic envelope: \(error)")
        }
    }
}

/// Non-error metadata extracted from a `subsonic-response` envelope. Public so
/// callers can read the server product/version reported alongside `ok`.
public struct SubsonicResponseMeta: Sendable, Hashable {
    public var version: String?
    public var type: String?
    public var serverVersion: String?
}

extension SubsonicClient {
    /// Validate a binary media response (stream / download / cover art) by HTTP
    /// status + content-type. On any XML/JSON body (Subsonic serves errors over
    /// HTTP 200 with a subsonic-response payload) we DECODE the envelope to map
    /// the specific ``MozzError``, otherwise raise ``MozzError/invalidResponse``.
    ///
    /// This is the single most important safety guard in the whole conformer:
    /// without it, a `.mp3` on disk can silently be an XML "Wrong username or
    /// password" body, permanently corrupting the offline library.
    public static func validateBinaryResponse(
        statusCode: Int, contentType: String?, data: Data
    ) throws {
        if statusCode >= 400 {
            throw MozzError.badStatus(statusCode)
        }
        let type = (contentType ?? "").lowercased()
        if type.hasPrefix("audio/") || type.hasPrefix("image/") || type.hasPrefix("video/") {
            return
        }
        if type.contains("json") {
            let decoder = JSONDecoder()
            decoder.userInfo[.subsonicPayloadKey] = "__unused__"
            if let envelope = try? decoder.decode(SSEnvelope<SSPing>.self, from: data),
               envelope.response.status == "failed" {
                throw mapError(envelope.response.error)
            }
        }
        throw MozzError.invalidResponse
    }

    /// Map Subsonic error codes to ``MozzError``.
    ///
    /// - 10 required parameter missing → transport
    /// - 20 / 30 client / server upgrade required → unsupported
    /// - 40-44 auth failures (bad creds, LDAP token unsupported, apiKey unsupported,
    ///   conflicting auth, invalid apiKey) → unauthorized
    /// - 50 not authorized for the requested op → unsupported
    /// - 60 trial expired → unsupported
    /// - 70 not found → notFound
    static func mapError(_ error: SSError?) -> MozzError {
        guard let error else { return MozzError.invalidResponse }
        switch error.code {
        case 40, 41, 42, 43, 44:
            return .unauthorized
        case 50:
            return .unsupported(error.message ?? "User not authorized")
        case 70:
            return .notFound
        case 20, 30:
            return .unsupported(error.message ?? "Client/server version mismatch")
        case 60:
            return .unsupported(error.message ?? "Trial period expired")
        default:
            return .transport("Subsonic error \(error.code): \(error.message ?? "unknown")")
        }
    }
}


