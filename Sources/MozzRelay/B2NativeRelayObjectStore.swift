#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto
import Foundation

/// Direct Backblaze B2 credentials scoped to one channel prefix.
///
/// B2's native API is the default for B2 because Microsoft Defender permits
/// its API and upload hosts while resetting the S3 endpoint. The object-store
/// protocol above it remains provider-neutral.
public struct B2RelayConfiguration: Codable, Sendable, Equatable {
    public let keyID: String
    public let applicationKey: String
    public let bucketName: String
    /// Cloudflare/custom-domain base ending at `/file/{bucket}`. When absent,
    /// authorization supplies B2's public download host.
    public let readEndpoint: URL?
    public let expiresAtMS: Int64

    public init(
        keyID: String,
        applicationKey: String,
        bucketName: String,
        readEndpoint: URL? = nil,
        expiresAtMS: Int64
    ) {
        self.keyID = keyID
        self.applicationKey = applicationKey
        self.bucketName = bucketName
        self.readEndpoint = readEndpoint
        self.expiresAtMS = expiresAtMS
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> B2RelayConfiguration {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

public enum B2RelayError: Error, Equatable {
    case expired
    case noScopedBucket(String)
    case unsupportedCondition
    case missingUploadURL
    case malformedResponse
    case unexpectedStatus(Int)
}

/// Backblaze's native object API behind ``RelayObjectStore``.
public actor B2NativeRelayObjectStore: RelayObjectStore {
    private struct Authorization: Sendable {
        let token: String
        let apiURL: URL
        let downloadURL: URL
        let bucketID: String
    }

    private struct UploadTarget: Sendable {
        let url: URL
        let token: String
    }

    private let configuration: B2RelayConfiguration
    private let http: any RelayHTTPTransport
    private let now: @Sendable () -> Date
    private var authorization: Authorization?
    private var uploadTarget: UploadTarget?

    public init(
        configuration: B2RelayConfiguration,
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
        let readBase: URL
        if let configured = configuration.readEndpoint {
            readBase = configured
        } else {
            let auth = try await authorize()
            readBase = auth.downloadURL
                .appendingPathComponent("file")
                .appendingPathComponent(configuration.bucketName)
        }
        var request = URLRequest(url: try Self.objectURL(
            base: readBase, path: path))
        request.httpMethod = "GET"
        if let ifNoneMatch {
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }
        let result = try await http.send(request)
        switch result.response.statusCode {
        case 200:
            guard let etag = result.response.value(forHTTPHeaderField: "ETag")
                    ?? result.response.value(forHTTPHeaderField: "X-Bz-Content-Sha1")
                    .map({ "\"\($0)\"" }) else {
                throw S3RelayError.missingETag
            }
            // B2's native public download host ignores If-None-Match and returns
            // 200 with the same ETag. Preserve the object-store contract here;
            // the production Cloudflare endpoint returns a real 304 and avoids
            // transferring the body in the first place.
            if etag == ifNoneMatch { return .notModified }
            return .object(RelayStoredObject(data: result.data, etag: etag))
        case 304:
            return .notModified
        case 404:
            return .missing
        default:
            throw B2RelayError.unexpectedStatus(result.response.statusCode)
        }
    }

    public func put(
        path: String,
        data: Data,
        condition: RelayWriteCondition
    ) async throws -> String {
        try requireUnexpired()
        // RelayHistoryStore only writes immutable, content-addressed paths.
        // B2 Native has no compare-and-swap; pretending a check then upload is
        // atomic would be a correctness bug, so unsupported conditions fail
        // explicitly rather than weakening silently.
        guard condition == .none else {
            throw B2RelayError.unsupportedCondition
        }

        let target = try await getUploadTarget()
        var request = URLRequest(url: target.url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue(target.token, forHTTPHeaderField: "Authorization")
        request.setValue(
            AWSV4Signer.encode(path),
            forHTTPHeaderField: "X-Bz-File-Name")
        request.setValue(
            "application/octet-stream",
            forHTTPHeaderField: "Content-Type")
        request.setValue(
            String(data.count),
            forHTTPHeaderField: "Content-Length")
        request.setValue(
            Self.sha1(data),
            forHTTPHeaderField: "X-Bz-Content-Sha1")

        let result = try await http.send(request)
        guard result.response.statusCode == 200 else {
            // Upload URLs are invalidated by some failures. Do not retry a
            // write here; clear it so the next scheduled sync obtains a fresh
            // target and the caller sees this failure.
            uploadTarget = nil
            throw B2RelayError.unexpectedStatus(result.response.statusCode)
        }
        let response = try JSONDecoder().decode(
            UploadResponse.self, from: result.data)
        return "\"\(response.contentSha1)\""
    }

    public func list(prefix: String) async throws -> [String] {
        try requireUnexpired()
        let auth = try await authorize()
        var names: [String] = []
        var next: String?

        repeat {
            let body = ListRequest(
                bucketId: auth.bucketID,
                startFileName: next,
                maxFileCount: 10_000,
                prefix: prefix)
            let result = try await apiRequest(
                base: auth.apiURL,
                operation: "b2_list_file_names",
                token: auth.token,
                body: body)
            let page = try JSONDecoder().decode(ListResponse.self, from: result)
            names.append(contentsOf: page.files.compactMap {
                $0.action == "upload" ? $0.fileName : nil
            })
            next = page.nextFileName
        } while next != nil

        return names
    }

    /// Cleanup for live provisioning tests. Normal old versions expire by
    /// bucket lifecycle rather than issuing one delete per sync.
    public func delete(path: String) async throws {
        let auth = try await authorize()
        let listed = try await apiRequest(
            base: auth.apiURL,
            operation: "b2_list_file_names",
            token: auth.token,
            body: ListRequest(
                bucketId: auth.bucketID,
                startFileName: path,
                maxFileCount: 1,
                prefix: path))
        let page = try JSONDecoder().decode(ListResponse.self, from: listed)
        guard let file = page.files.first(where: { $0.fileName == path }) else {
            return
        }
        _ = try await apiRequest(
            base: auth.apiURL,
            operation: "b2_delete_file_version",
            token: auth.token,
            body: DeleteRequest(fileName: path, fileId: file.fileId))
    }

    // MARK: Authorization and upload URL

    private func authorize() async throws -> Authorization {
        if let authorization { return authorization }
        try requireUnexpired()
        let url = URL(
            string: "https://api.backblazeb2.com/b2api/v4/b2_authorize_account")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let basic = Data(
            "\(configuration.keyID):\(configuration.applicationKey)".utf8)
            .base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        let result = try await http.send(request)
        guard result.response.statusCode == 200 else {
            throw B2RelayError.unexpectedStatus(result.response.statusCode)
        }
        let wire = try JSONDecoder().decode(
            AuthorizationResponse.self, from: result.data)
        guard let bucket = wire.apiInfo.storageApi.allowed.buckets.first(
            where: { $0.name == configuration.bucketName }) else {
            throw B2RelayError.noScopedBucket(configuration.bucketName)
        }
        guard let apiURL = URL(string: wire.apiInfo.storageApi.apiUrl),
              let downloadURL = URL(
                  string: wire.apiInfo.storageApi.downloadUrl) else {
            throw B2RelayError.malformedResponse
        }
        let resolved = Authorization(
            token: wire.authorizationToken,
            apiURL: apiURL,
            downloadURL: downloadURL,
            bucketID: bucket.id)
        authorization = resolved
        return resolved
    }

    private func getUploadTarget() async throws -> UploadTarget {
        if let uploadTarget { return uploadTarget }
        let auth = try await authorize()
        let data = try await apiRequest(
            base: auth.apiURL,
            operation: "b2_get_upload_url",
            token: auth.token,
            body: UploadURLRequest(bucketId: auth.bucketID))
        let wire = try JSONDecoder().decode(UploadURLResponse.self, from: data)
        guard let url = URL(string: wire.uploadUrl) else {
            throw B2RelayError.missingUploadURL
        }
        let target = UploadTarget(url: url, token: wire.authorizationToken)
        uploadTarget = target
        return target
    }

    private func apiRequest<Body: Encodable>(
        base: URL,
        operation: String,
        token: String,
        body: Body
    ) async throws -> Data {
        let url = base
            .appendingPathComponent("b2api")
            .appendingPathComponent("v4")
            .appendingPathComponent(operation)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let result = try await http.send(request)
        guard result.response.statusCode == 200 else {
            if result.response.statusCode == 401 {
                authorization = nil
                uploadTarget = nil
            }
            throw B2RelayError.unexpectedStatus(result.response.statusCode)
        }
        return result.data
    }

    private func requireUnexpired() throws {
        let nowMS = Int64(now().timeIntervalSince1970 * 1000)
        guard nowMS < configuration.expiresAtMS else {
            throw B2RelayError.expired
        }
    }

    private static func objectURL(base: URL, path: String) throws -> URL {
        guard var components = URLComponents(
            url: base, resolvingAgainstBaseURL: false),
              components.scheme != nil,
              components.host != nil else {
            throw S3RelayError.invalidEndpoint
        }
        let prefix = components.percentEncodedPath
            .split(separator: "/").map(String.init)
        components.percentEncodedPath = "/"
            + (prefix + path.split(separator: "/").map(String.init))
                .map(AWSV4Signer.encode)
                .joined(separator: "/")
        guard let url = components.url else {
            throw S3RelayError.invalidEndpoint
        }
        return url
    }

    private static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - B2 wire types

private struct AuthorizationResponse: Decodable {
    let authorizationToken: String
    let apiInfo: APIInfo

    struct APIInfo: Decodable {
        let storageApi: StorageAPI
    }

    struct StorageAPI: Decodable {
        let apiUrl: String
        let downloadUrl: String
        let allowed: Allowed
    }

    struct Allowed: Decodable {
        let buckets: [Bucket]
    }

    struct Bucket: Decodable {
        let id: String
        let name: String
    }
}

private struct UploadURLRequest: Encodable {
    let bucketId: String
}

private struct UploadURLResponse: Decodable {
    let uploadUrl: String
    let authorizationToken: String
}

private struct UploadResponse: Decodable {
    let contentSha1: String
}

private struct ListRequest: Encodable {
    let bucketId: String
    let startFileName: String?
    let maxFileCount: Int
    let prefix: String
}

private struct ListResponse: Decodable {
    let files: [File]
    let nextFileName: String?

    struct File: Decodable {
        let fileId: String
        let fileName: String
        let action: String
    }
}

private struct DeleteRequest: Encodable {
    let fileName: String
    let fileId: String
}
