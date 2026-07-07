import Foundation
import MozzCore
import MozzNetworking

/// A resolved MusicBrainz recording match.
public struct MusicBrainzRecordingMatch: Sendable, Equatable {
    /// The recording MBID (what ListenBrainz similarity keys on).
    public var recordingMBID: String
    /// The primary artist-credit MBID, when present and not the "Various Artists"
    /// placeholder.
    public var artistMBID: String?
    public var score: Int
    public var lengthMs: Double?

    public init(recordingMBID: String, artistMBID: String?, score: Int, lengthMs: Double?) {
        self.recordingMBID = recordingMBID
        self.artistMBID = artistMBID
        self.score = score
        self.lengthMs = lengthMs
    }
}

/// Minimal MusicBrainz web-service client: resolves an (artist, title) pair to a
/// recording MBID via `/ws/2/recording` search. Bound to a rate-limited
/// `HTTPClient` so all outbound calls (including HTTPClient retries) stay within
/// MusicBrainz's 1 req/s policy. Pure decode + match logic is transport-injected
/// for tests.
public struct MusicBrainzClient: Sendable {
    private let client: HTTPClient
    private let minScore: Int
    private let durationToleranceMs: Double

    public init(client: HTTPClient, minScore: Int, durationToleranceMs: Double) {
        self.client = client
        self.minScore = minScore
        self.durationToleranceMs = durationToleranceMs
    }

    /// Build a client against `https://musicbrainz.org`, wrapping `transport` in a
    /// `RateLimitingTransport` fed by `limiter` and sending the required
    /// `User-Agent`. Pass the SAME `limiter` used elsewhere so every MusicBrainz
    /// call across the app shares one budget.
    public static func make(
        config: EnrichmentConfig,
        limiter: AsyncRateLimiter,
        baseTransport: any HTTPTransport = URLSessionTransport(role: .interactive)
    ) -> MusicBrainzClient {
        let http = HTTPClient(
            baseURL: URL(string: "https://musicbrainz.org")!,
            transport: RateLimitingTransport(wrapping: baseTransport, limiter: limiter),
            defaultHeaders: ["User-Agent": config.userAgent, "Accept": "application/json"])
        return MusicBrainzClient(client: http, minScore: config.minScore,
                                 durationToleranceMs: config.durationToleranceMs)
    }

    /// The best recording match for a track, or `nil` if none clears the score
    /// (and, when both durations are known, the duration-tolerance) gate.
    ///
    /// When `artistMBID` is a known non-placeholder MBID it's added as an `arid:`
    /// constraint to sharpen the search. The artist MBID in the result comes free
    /// from the matched recording's primary artist-credit.
    public func bestRecording(artist: String, title: String,
                              durationMs: Double?, artistMBID: String?) async throws
        -> MusicBrainzRecordingMatch? {
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArtist.isEmpty, !trimmedTitle.isEmpty else { return nil }

        var terms = ["recording:\(Self.phrase(trimmedTitle))",
                     "artist:\(Self.phrase(trimmedArtist))"]
        if let arid = MusicBrainzID.normalized(artistMBID), arid != MusicBrainzID.variousArtists {
            terms.append("arid:\(arid)")
        }
        let endpoint = Endpoint(path: "ws/2/recording", query: [
            URLQueryItem(name: "query", value: terms.joined(separator: " AND ")),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "5"),
        ])
        let response = try await client.send(endpoint, as: MBRecordingSearchResponse.self)
        return Self.pickMatch(from: response.recordings ?? [], durationMs: durationMs,
                              minScore: minScore, durationToleranceMs: durationToleranceMs)
    }

    /// Pure match selection (unit-tested): highest-scoring recording that clears
    /// the score gate and, when both durations are known, the duration tolerance.
    static func pickMatch(from recordings: [MBRecording], durationMs: Double?,
                          minScore: Int, durationToleranceMs: Double)
        -> MusicBrainzRecordingMatch? {
        for recording in recordings {
            guard let mbid = MusicBrainzID.normalized(recording.id) else { continue }
            let score = recording.score ?? 0
            guard score >= minScore else { continue }
            let lengthMs = recording.length.map(Double.init)
            if let want = durationMs, let have = lengthMs,
               abs(have - want) > durationToleranceMs { continue }
            var artistMBID = MusicBrainzID.normalized(recording.artistCredit?.first?.artist?.id)
            if artistMBID == MusicBrainzID.variousArtists { artistMBID = nil }
            return MusicBrainzRecordingMatch(recordingMBID: mbid, artistMBID: artistMBID,
                                             score: score, lengthMs: lengthMs)
        }
        return nil
    }

    /// A Lucene phrase: wrap in quotes and escape `\` and `"` (MusicBrainz docs
    /// require escaping literal values). Quoting makes reserved characters common
    /// in titles — `( ) : ! + - "(Live)" "(feat. X)"` — literal.
    static func phrase(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

// MARK: - Decodable mirrors of the MusicBrainz recording-search JSON

struct MBRecordingSearchResponse: Decodable {
    let recordings: [MBRecording]?
}

struct MBRecording: Decodable {
    let id: String
    let score: Int?
    let length: Int?
    let artistCredit: [MBArtistCredit]?

    enum CodingKeys: String, CodingKey {
        case id, score, length
        case artistCredit = "artist-credit"
    }
}

struct MBArtistCredit: Decodable {
    let artist: MBArtist?
}

struct MBArtist: Decodable {
    let id: String?
    let name: String?
}
