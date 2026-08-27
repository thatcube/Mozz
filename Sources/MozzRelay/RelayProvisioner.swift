#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

public enum RelayProvisioningError: Error, Equatable {
    case invalidChannelID
    case unexpectedStatus(Int)
    case malformedResponse
}

/// Creates and renews a channel's scoped B2 capability.
///
/// The Worker remembers nothing. Initial creation is rate-limited; renewal
/// proves possession of the existing child key, and the Worker verifies that
/// key is restricted to this exact channel prefix before minting another.
public actor RelayProvisioner {
    public static let renewalLeeway: TimeInterval = 7 * 24 * 60 * 60

    private let endpoint: URL
    private let http: any RelayHTTPTransport

    public init(
        endpoint: URL,
        http: any RelayHTTPTransport = URLSessionRelayHTTPTransport()
    ) {
        self.endpoint = endpoint
        self.http = http
    }

    public nonisolated static func needsRenewal(
        _ configuration: B2RelayConfiguration,
        now: Date = Date()
    ) -> Bool {
        let deadline = Date(
            timeIntervalSince1970:
                Double(configuration.expiresAtMS) / 1000)
        return deadline.timeIntervalSince(now) <= renewalLeeway
    }

    public func create(channelID: String) async throws -> B2RelayConfiguration {
        guard Self.valid(channelID) else {
            throw RelayProvisioningError.invalidChannelID
        }
        let url = endpoint
            .appendingPathComponent("v1")
            .appendingPathComponent("channels")
        return try await request(
            url: url,
            authorization: nil,
            body: ["channelId": channelID],
            expectedStatus: 201)
    }

    public func renew(
        channelID: String,
        current: B2RelayConfiguration
    ) async throws -> B2RelayConfiguration {
        guard Self.valid(channelID) else {
            throw RelayProvisioningError.invalidChannelID
        }
        let url = endpoint
            .appendingPathComponent("v1")
            .appendingPathComponent("channels")
            .appendingPathComponent(channelID)
            .appendingPathComponent("renew")
        let basic = Data(
            "\(current.keyID):\(current.applicationKey)".utf8)
            .base64EncodedString()
        return try await request(
            url: url,
            authorization: "Basic \(basic)",
            body: [:],
            expectedStatus: 200)
    }

    private func request(
        url: URL,
        authorization: String?,
        body: [String: String],
        expectedStatus: Int
    ) async throws -> B2RelayConfiguration {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization {
            request.setValue(
                authorization, forHTTPHeaderField: "Authorization")
        }
        let result = try await http.send(request)
        guard result.response.statusCode == expectedStatus else {
            throw RelayProvisioningError.unexpectedStatus(
                result.response.statusCode)
        }
        guard let configuration = try? JSONDecoder().decode(
            B2RelayConfiguration.self, from: result.data) else {
            throw RelayProvisioningError.malformedResponse
        }
        return configuration
    }

    private nonisolated static func valid(_ value: String) -> Bool {
        (16...64).contains(value.count)
            && value.unicodeScalars.allSatisfy {
                let byte = $0.value
                return (48...57).contains(byte)
                    || (65...90).contains(byte)
                    || (97...122).contains(byte)
                    || byte == 45
                    || byte == 95
            }
    }
}
