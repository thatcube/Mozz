import Foundation
import MozzCore
import MozzNetworking

/// One similar recording returned by ListenBrainz (only the fields we store).
public struct ListenBrainzSimilar: Sendable, Equatable {
    public var recordingMBID: String
    public var score: Double
    public init(recordingMBID: String, score: Double) {
        self.recordingMBID = recordingMBID
        self.score = score
    }
}

/// Minimal ListenBrainz Labs client: crowd listening-similarity ("people who
/// play X also play Y") + canonical recording-MBID resolution. Bound to a
/// rate-limited `HTTPClient` (its OWN limiter instance — a different host/policy
/// than MusicBrainz). Pure decode logic is transport-injected for tests.
public struct ListenBrainzClient: Sendable {
    private let client: HTTPClient
    private let algorithm: String

    public init(client: HTTPClient, algorithm: String) {
        self.client = client
        self.algorithm = algorithm
    }

    /// Build a client against `https://labs.api.listenbrainz.org` with its own
    /// `RateLimitingTransport`/limiter and the descriptive `User-Agent`.
    public static func make(
        config: EnrichmentConfig,
        limiter: AsyncRateLimiter,
        baseTransport: any HTTPTransport = URLSessionTransport(role: .interactive)
    ) -> ListenBrainzClient {
        let http = HTTPClient(
            baseURL: URL(string: "https://labs.api.listenbrainz.org")!,
            transport: RateLimitingTransport(wrapping: baseTransport, limiter: limiter),
            defaultHeaders: ["User-Agent": config.userAgent, "Accept": "application/json"])
        return ListenBrainzClient(client: http, algorithm: config.listenBrainzAlgorithm)
    }

    /// Similar recordings for a single CANONICAL recording MBID. One MBID per
    /// request: multi-seed GET batches misassociate/dedup results. An empty array
    /// is a valid "no similarity data" answer.
    public func similarRecordings(forCanonicalMbid mbid: String) async throws -> [ListenBrainzSimilar] {
        let endpoint = Endpoint(path: "similar-recordings/json", query: [
            URLQueryItem(name: "recording_mbids", value: mbid),
            URLQueryItem(name: "algorithm", value: algorithm),
        ])
        let rows = try await client.send(endpoint, as: [LBSimilarRow].self)
        var out: [ListenBrainzSimilar] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            guard let similar = MusicBrainzID.normalized(row.recording_mbid), similar != mbid,
                  let score = row.score else { continue }
            out.append(ListenBrainzSimilar(recordingMBID: similar, score: score))
        }
        return out
    }

    /// The canonical recording MBID for a raw MBID, or `nil` on no-mapping /
    /// transient failure (the endpoint 500s for some valid MBIDs; one bad id can
    /// fail a whole batch, so this is single + best-effort). Never throws.
    public func canonicalRecording(forMbid mbid: String) async -> String? {
        let endpoint = Endpoint(path: "recording-mbid-lookup/json", query: [
            URLQueryItem(name: "recording_mbid", value: mbid),
        ])
        guard let result = try? await client.send(endpoint, as: LBCanonicalResult.self) else {
            return nil
        }
        return MusicBrainzID.normalized(result.canonical_recording_mbid)
    }
}

// MARK: - Decodable mirrors (tolerant: only ids/score are required)

private struct LBSimilarRow: Decodable {
    let recording_mbid: String?
    let score: Double?
}

private struct LBCanonicalResult: Decodable {
    let canonical_recording_mbid: String?
    let original_recording_mbid: String?
}
