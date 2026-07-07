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
    private let minTagVotes: Int
    private let maxTags: Int

    public init(client: HTTPClient, minScore: Int, durationToleranceMs: Double,
                minTagVotes: Int = 2, maxTags: Int = 6) {
        self.client = client
        self.minScore = minScore
        self.durationToleranceMs = durationToleranceMs
        self.minTagVotes = minTagVotes
        self.maxTags = maxTags
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
                                 durationToleranceMs: config.durationToleranceMs,
                                 minTagVotes: config.minTagVotes, maxTags: config.maxTags)
    }

    /// The community genre tags for an artist, lowercased — vote-thresholded (drops
    /// noisy 1-vote tags), highest-count first, capped at `maxTags`. Empty when the
    /// artist has no genres. Uses artist genres (dense) rather than recording tags
    /// (almost always empty). Throws on transport/decode/cancel (caller decides).
    public func artistGenres(forArtistMbid mbid: String) async throws -> [String] {
        let endpoint = Endpoint(path: "ws/2/artist/\(mbid)", query: [
            URLQueryItem(name: "inc", value: "genres"),
            URLQueryItem(name: "fmt", value: "json"),
        ])
        let response = try await client.send(endpoint, as: MBArtistGenresResponse.self)
        // Lowercase first so case variants collapse; sort by count desc with a
        // name tiebreak (deterministic across fetches even when counts tie); then
        // de-dupe BEFORE the cap so duplicates can't consume cap slots.
        let ranked = (response.genres ?? [])
            .filter { ($0.count ?? 0) >= minTagVotes }
            .compactMap { genre -> (name: String, count: Int)? in
                genre.name.map { ($0.lowercased(), genre.count ?? 0) }
            }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        var seen = Set<String>()
        var result: [String] = []
        for entry in ranked where seen.insert(entry.name).inserted {
            result.append(entry.name)
            if result.count == maxTags { break }
        }
        return result
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

        let arid = MusicBrainzID.normalized(artistMBID)
            .flatMap { $0 == MusicBrainzID.variousArtists ? nil : $0 }
        // Try the artist-constrained search first when we have an MBID. Fall back
        // to an unconstrained search ONLY when the constrained one returned no
        // candidates at all (a stale/mismatched arid). If it returned candidates
        // that simply didn't clear the score/duration gate, do NOT drop the arid —
        // an unconstrained search could otherwise accept a confident match from a
        // different same-named artist.
        if let arid {
            let recordings = try await searchRecordings(artist: trimmedArtist, title: trimmedTitle, arid: arid)
            if let match = Self.pickMatch(from: recordings, durationMs: durationMs,
                                          minScore: minScore, durationToleranceMs: durationToleranceMs) {
                return match
            }
            if !recordings.isEmpty { return nil }
        }
        let recordings = try await searchRecordings(artist: trimmedArtist, title: trimmedTitle, arid: nil)
        return Self.pickMatch(from: recordings, durationMs: durationMs,
                              minScore: minScore, durationToleranceMs: durationToleranceMs)
    }

    private func searchRecordings(artist: String, title: String, arid: String?) async throws -> [MBRecording] {
        var terms = ["recording:\(Self.phrase(title))", "artist:\(Self.phrase(artist))"]
        if let arid { terms.append("arid:\(arid)") }
        let endpoint = Endpoint(path: "ws/2/recording", query: [
            URLQueryItem(name: "query", value: terms.joined(separator: " AND ")),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "5"),
        ])
        let response = try await client.send(endpoint, as: MBRecordingSearchResponse.self)
        return response.recordings ?? []
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
            // Only apply the duration gate when BOTH lengths are actually known
            // (a non-positive want means "unknown" — see EnrichmentStore).
            if let want = durationMs, want > 0, let have = lengthMs,
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

// MARK: - Decodable mirrors of the MusicBrainz artist genres JSON

struct MBArtistGenresResponse: Decodable {
    let genres: [MBGenre]?
}

struct MBGenre: Decodable {
    let name: String?
    let count: Int?
}
