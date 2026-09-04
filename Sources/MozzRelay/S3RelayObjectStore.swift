#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif
import Crypto
import Foundation

/// The scoped credentials a channel carries through pairing.
///
/// Encoded into `CircleSecrets.relayKey` as JSON so the pairing contract stays
/// provider-neutral: B2 today, another S3-compatible store later.
public struct S3RelayConfiguration: Codable, Sendable, Equatable {
    public let accessKeyID: String
    public let secretAccessKey: String
    public let bucket: String
    public let region: String
    /// S3-compatible endpoint used for authenticated writes and manifest lists.
    public let writeEndpoint: URL
    /// Public/CDN base used for object reads.
    public let readEndpoint: URL
    public let expiresAtMS: Int64

    public init(
        accessKeyID: String,
        secretAccessKey: String,
        bucket: String,
        region: String,
        writeEndpoint: URL,
        readEndpoint: URL,
        expiresAtMS: Int64
    ) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.bucket = bucket
        self.region = region
        self.writeEndpoint = writeEndpoint
        self.readEndpoint = readEndpoint
        self.expiresAtMS = expiresAtMS
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> S3RelayConfiguration {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

public struct RelayHTTPResponse: @unchecked Sendable {
    public let data: Data
    public let response: HTTPURLResponse

    public init(data: Data, response: HTTPURLResponse) {
        self.data = data
        self.response = response
    }
}

public protocol RelayHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> RelayHTTPResponse
}

public struct URLSessionRelayHTTPTransport: RelayHTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> RelayHTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw S3RelayError.notHTTP
        }
        return RelayHTTPResponse(data: data, response: http)
    }
}

public enum S3RelayError: Error, Equatable {
    case invalidEndpoint
    case notHTTP
    case expired
    case missingETag
    case preconditionFailed(String)
    case unexpectedStatus(Int)
    case malformedList
}

/// B2/R2/S3 adapter for ``RelayObjectStore``.
///
/// Reads use the public CDN endpoint. Writes and manifest lists use the scoped
/// S3 credentials. This keeps B2 egress on the Bandwidth Alliance path while
/// leaving the Worker entirely out of normal sync.
public actor S3RelayObjectStore: RelayObjectStore {
    private let configuration: S3RelayConfiguration
    private let http: any RelayHTTPTransport
    private let now: @Sendable () -> Date

    public init(
        configuration: S3RelayConfiguration,
        http: any RelayHTTPTransport = URLSessionRelayHTTPTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.http = http
        self.now = now
    }

    public func read(
        path: String,
        ifNoneMatch: String?
    ) async throws -> RelayReadResult {
        var request = URLRequest(url: try publicURL(path: path))
        request.httpMethod = "GET"
        if let ifNoneMatch {
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }
        let result = try await http.send(request)
        switch result.response.statusCode {
        case 200:
            guard let etag = result.response.value(
                forHTTPHeaderField: "ETag") else {
                throw S3RelayError.missingETag
            }
            return .object(RelayStoredObject(data: result.data, etag: etag))
        case 304:
            return .notModified
        case 404:
            return .missing
        default:
            throw S3RelayError.unexpectedStatus(result.response.statusCode)
        }
    }

    public func put(
        path: String,
        data: Data,
        condition: RelayWriteCondition
    ) async throws -> String {
        try requireUnexpired()
        var request = URLRequest(url: try signedURL(path: path))
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        switch condition {
        case .none:
            break
        case .ifAbsent:
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        case let .ifMatch(etag):
            request.setValue(etag, forHTTPHeaderField: "If-Match")
        }
        request = try AWSV4Signer.sign(
            request,
            accessKeyID: configuration.accessKeyID,
            secretAccessKey: configuration.secretAccessKey,
            region: configuration.region,
            date: now())

        let result = try await http.send(request)
        switch result.response.statusCode {
        case 200, 201:
            guard let etag = result.response.value(
                forHTTPHeaderField: "ETag") else {
                throw S3RelayError.missingETag
            }
            return etag
        case 409, 412:
            throw S3RelayError.preconditionFailed(path)
        default:
            throw S3RelayError.unexpectedStatus(result.response.statusCode)
        }
    }

    public func list(prefix: String) async throws -> [String] {
        try requireUnexpired()
        var keys: [String] = []
        var continuation: String?

        repeat {
            var query = [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "prefix", value: prefix),
            ]
            if let continuation {
                query.append(URLQueryItem(
                    name: "continuation-token", value: continuation))
            }
            var request = URLRequest(url: try signedURL(path: "", query: query))
            request.httpMethod = "GET"
            request = try AWSV4Signer.sign(
                request,
                accessKeyID: configuration.accessKeyID,
                secretAccessKey: configuration.secretAccessKey,
                region: configuration.region,
                date: now())

            let result = try await http.send(request)
            guard result.response.statusCode == 200 else {
                throw S3RelayError.unexpectedStatus(result.response.statusCode)
            }
            let page = try S3ListPage.parse(result.data)
            keys.append(contentsOf: page.keys)
            continuation = page.isTruncated ? page.nextContinuationToken : nil
            if page.isTruncated, continuation == nil {
                throw S3RelayError.malformedList
            }
        } while continuation != nil

        return keys
    }

    /// Removes an object. Normal sync relies on bucket lifecycle rules for old
    /// content-addressed bodies; this exists for provisioning probes and
    /// explicit cleanup, not as part of the history algorithm.
    public func delete(path: String) async throws {
        try requireUnexpired()
        var request = URLRequest(url: try signedURL(path: path))
        request.httpMethod = "DELETE"
        request = try AWSV4Signer.sign(
            request,
            accessKeyID: configuration.accessKeyID,
            secretAccessKey: configuration.secretAccessKey,
            region: configuration.region,
            date: now())
        let result = try await http.send(request)
        guard result.response.statusCode == 204
                || result.response.statusCode == 200
                || result.response.statusCode == 404 else {
            throw S3RelayError.unexpectedStatus(result.response.statusCode)
        }
    }

    private func requireUnexpired() throws {
        let nowMS = Int64(now().timeIntervalSince1970 * 1000)
        guard nowMS < configuration.expiresAtMS else {
            throw S3RelayError.expired
        }
    }

    private func publicURL(path: String) throws -> URL {
        try Self.url(
            base: configuration.readEndpoint,
            pathComponents: path.split(separator: "/").map(String.init),
            query: [])
    }

    private func signedURL(
        path: String,
        query: [URLQueryItem] = []
    ) throws -> URL {
        try Self.url(
            base: configuration.writeEndpoint,
            pathComponents: [configuration.bucket]
                + path.split(separator: "/").map(String.init),
            query: query)
    }

    private static func url(
        base: URL,
        pathComponents: [String],
        query: [URLQueryItem]
    ) throws -> URL {
        guard var components = URLComponents(
            url: base, resolvingAgainstBaseURL: false),
              components.scheme != nil,
              components.host != nil else {
            throw S3RelayError.invalidEndpoint
        }
        let prefix = components.percentEncodedPath
            .split(separator: "/")
            .map(String.init)
        components.percentEncodedPath = "/"
            + (prefix + pathComponents)
                .map(AWSV4Signer.encode)
                .joined(separator: "/")
        components.percentEncodedQuery = query.isEmpty
            ? nil
            : query
                .map { (AWSV4Signer.encode($0.name), AWSV4Signer.encode($0.value ?? "")) }
                .sorted { $0 < $1 }
                .map { "\($0)=\($1)" }
                .joined(separator: "&")
        guard let url = components.url else {
            throw S3RelayError.invalidEndpoint
        }
        return url
    }
}

// MARK: - Signature V4

enum AWSV4Signer {
    static func sign(
        _ unsigned: URLRequest,
        accessKeyID: String,
        secretAccessKey: String,
        region: String,
        date: Date
    ) throws -> URLRequest {
        guard let url = unsigned.url,
              let components = URLComponents(
                  url: url, resolvingAgainstBaseURL: false),
              let host = components.host else {
            throw S3RelayError.invalidEndpoint
        }

        let timestamp = amzDate(date)
        let day = String(timestamp.prefix(8))
        let body = unsigned.httpBody ?? Data()
        let payloadHash = sha256(body)

        var headers: [String: String] = [
            "host": components.port.map { "\(host):\($0)" } ?? host,
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": timestamp,
        ]
        for (name, value) in unsigned.allHTTPHeaderFields ?? [:] {
            headers[name.lowercased()] = value
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
        }

        let names = headers.keys.sorted()
        let canonicalHeaders = names
            .map { "\($0):\(headers[$0]!)\n" }
            .joined()
        let signedHeaders = names.joined(separator: ";")
        let canonicalRequest = [
            unsigned.httpMethod ?? "GET",
            components.percentEncodedPath.isEmpty
                ? "/" : components.percentEncodedPath,
            components.percentEncodedQuery ?? "",
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(day)/\(region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            timestamp,
            scope,
            sha256(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let dateKey = hmac(
            Data(day.utf8),
            key: Data(("AWS4" + secretAccessKey).utf8))
        let regionKey = hmac(Data(region.utf8), key: dateKey)
        let serviceKey = hmac(Data("s3".utf8), key: regionKey)
        let signingKey = hmac(Data("aws4_request".utf8), key: serviceKey)
        let signature = hmac(
            Data(stringToSign.utf8), key: signingKey)
            .map { String(format: "%02x", $0) }
            .joined()

        var signed = unsigned
        signed.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
        signed.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        signed.setValue(
            "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), " +
            "SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization")
        return signed
    }

    static func encode(_ value: String) -> String {
        value.utf8.map { byte -> String in
            switch byte {
            case 48...57, 65...90, 97...122, 45, 46, 95, 126:
                return String(UnicodeScalar(byte))
            default:
                return String(format: "%%%02X", byte)
            }
        }.joined()
    }

    private static func amzDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func hmac(_ data: Data, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: data, using: SymmetricKey(data: key)))
    }
}

// MARK: - ListObjectsV2 XML

private struct S3ListPage {
    var keys: [String]
    var isTruncated: Bool
    var nextContinuationToken: String?

    static func parse(_ data: Data) throws -> S3ListPage {
        let parser = XMLParser(data: data)
        let delegate = S3ListParser()
        parser.delegate = delegate
        guard parser.parse() else { throw S3RelayError.malformedList }
        return S3ListPage(
            keys: delegate.keys,
            isTruncated: delegate.isTruncated,
            nextContinuationToken: delegate.nextContinuationToken)
    }
}

private final class S3ListParser: NSObject, XMLParserDelegate {
    var keys: [String] = []
    var isTruncated = false
    var nextContinuationToken: String?

    private var element = ""
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        element = elementName
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Key":
            keys.append(value)
        case "IsTruncated":
            isTruncated = value.lowercased() == "true"
        case "NextContinuationToken":
            nextContinuationToken = value.isEmpty ? nil : value
        default:
            break
        }
        element = ""
        text = ""
    }
}
