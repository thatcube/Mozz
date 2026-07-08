import XCTest
import Foundation
import MozzCore
import MozzNetworking
@testable import MozzEnrichment

private let recA = "b1a9c0e9-d987-4042-ae91-78d6a3267d69"
private let artistA = "f22942a1-6f70-4f48-866e-238cb2308fbd"

final class MusicBrainzClientMatchTests: XCTestCase {
    private func rec(_ id: String, score: Int?, length: Int? = nil,
                     artist: String? = nil) -> MBRecording {
        let credit = artist.map { [MBArtistCredit(artist: MBArtist(id: $0, name: "A"))] }
        return MBRecording(id: id, score: score, length: length, artistCredit: credit)
    }

    func testPicksHighestScoreAboveThreshold() {
        let match = MusicBrainzClient.pickMatch(
            from: [rec("bad", score: 50), rec(recA, score: 95, artist: artistA)],
            durationMs: nil, minScore: 90, durationToleranceMs: 10_000)
        XCTAssertEqual(match?.recordingMBID, recA)
        XCTAssertEqual(match?.artistMBID, artistA)
    }

    func testRejectsBelowThreshold() {
        let match = MusicBrainzClient.pickMatch(
            from: [rec(recA, score: 80)], durationMs: nil, minScore: 90, durationToleranceMs: 10_000)
        XCTAssertNil(match)
    }

    func testDurationToleranceRejectsWrongLength() {
        // Recording is 5 minutes; track is 3 minutes → outside tolerance.
        let match = MusicBrainzClient.pickMatch(
            from: [rec(recA, score: 100, length: 300_000)],
            durationMs: 180_000, minScore: 90, durationToleranceMs: 10_000)
        XCTAssertNil(match)
    }

    func testDurationWithinToleranceAccepted() {
        let match = MusicBrainzClient.pickMatch(
            from: [rec(recA, score: 100, length: 181_000)],
            durationMs: 180_000, minScore: 90, durationToleranceMs: 10_000)
        XCTAssertEqual(match?.recordingMBID, recA)
    }

    func testDropsVariousArtistsArtistMBID() {
        let match = MusicBrainzClient.pickMatch(
            from: [rec(recA, score: 100, artist: MusicBrainzID.variousArtists)],
            durationMs: nil, minScore: 90, durationToleranceMs: 10_000)
        XCTAssertEqual(match?.recordingMBID, recA)
        XCTAssertNil(match?.artistMBID) // VA placeholder skipped
    }

    func testSkipsInvalidRecordingID() {
        let match = MusicBrainzClient.pickMatch(
            from: [rec("not-a-uuid", score: 100), rec(recA, score: 92)],
            durationMs: nil, minScore: 90, durationToleranceMs: 10_000)
        XCTAssertEqual(match?.recordingMBID, recA)
    }

    func testLucenePhraseEscaping() {
        XCTAssertEqual(MusicBrainzClient.phrase("(Live)"), "\"(Live)\"")
        XCTAssertEqual(MusicBrainzClient.phrase("a\"b"), "\"a\\\"b\"")
        XCTAssertEqual(MusicBrainzClient.phrase("a\\b"), "\"a\\\\b\"")
    }
}

/// Serves canned JSON and captures the request, with no rate-limit delay.
private final class CannedTransport: HTTPTransport, @unchecked Sendable {
    let json: String
    private let lock = NSLock()
    private(set) var lastRequest: URLRequest?
    init(json: String) { self.json = json }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); lastRequest = request; lock.unlock()
        return (Data(json.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class MusicBrainzClientRequestTests: XCTestCase {
    private func makeClient(_ transport: any HTTPTransport) -> MusicBrainzClient {
        MusicBrainzClient.make(
            config: EnrichmentConfig(userAgent: "MozzTest/1 ( test@example.com )"),
            limiter: AsyncRateLimiter(minInterval: 0),
            baseTransport: transport)
    }

    func testBestRecordingParsesAndBuildsQuery() async throws {
        let transport = CannedTransport(json: """
            {"recordings":[{"id":"\(recA)","score":100,"length":181000,
              "artist-credit":[{"artist":{"id":"\(artistA)","name":"Aphex Twin"}}]}]}
            """)
        let match = try await makeClient(transport).bestRecording(
            artist: "Aphex Twin", title: "Xtal (Live)", durationMs: 180_000, artistMBID: artistA)
        XCTAssertEqual(match?.recordingMBID, recA)
        XCTAssertEqual(match?.artistMBID, artistA)
        let url = try XCTUnwrap(transport.lastRequest?.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "query" }?.value
        XCTAssertEqual(url.path, "/ws/2/recording")
        XCTAssertTrue(query?.contains("recording:") ?? false)
        XCTAssertTrue(query?.contains("artist:") ?? false)
        XCTAssertTrue(query?.contains("arid:\(artistA)") ?? false)
    }

    func testBestRecordingReturnsNilOnEmpty() async throws {
        let transport = CannedTransport(json: "{\"recordings\":[]}")
        let match = try await makeClient(transport).bestRecording(
            artist: "X", title: "Y", durationMs: nil, artistMBID: nil)
        XCTAssertNil(match)
    }

    func testArtistGenresParsesFiltersSortsAndLowercases() async throws {
        // count 1 dropped (< minTagVotes=2); sorted by count desc; lowercased;
        // capped at maxTags; deduped.
        let transport = CannedTransport(json: """
            {"genres":[
              {"name":"Alternative Rock","count":41},
              {"name":"Noise","count":1},
              {"name":"Electronic","count":12},
              {"name":"electronic","count":3},
              {"name":"Trip Hop","count":7}]}
            """)
        let genres = try await makeClient(transport).artistGenres(forArtistMbid: artistA)
        XCTAssertEqual(genres, ["alternative rock", "electronic", "trip hop"])
        let url = try XCTUnwrap(transport.lastRequest?.url)
        XCTAssertEqual(url.path, "/ws/2/artist/\(artistA)")
        let inc = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "inc" }?.value
        XCTAssertEqual(inc, "genres")
    }

    func testArtistGenresRespectsMaxTagsCap() async throws {
        let transport = CannedTransport(json: """
            {"genres":[
              {"name":"a","count":9},{"name":"b","count":8},{"name":"c","count":7},
              {"name":"d","count":6},{"name":"e","count":5},{"name":"f","count":4},
              {"name":"g","count":3},{"name":"h","count":2}]}
            """)
        let genres = try await makeClient(transport).artistGenres(forArtistMbid: artistA)
        XCTAssertEqual(genres.count, 6)          // default maxTags
        XCTAssertEqual(genres, ["a", "b", "c", "d", "e", "f"])
    }

    func testArtistGenresEmptyWhenNoneOrAllBelowThreshold() async throws {
        let none = CannedTransport(json: "{\"genres\":[]}")
        let g1 = try await makeClient(none).artistGenres(forArtistMbid: artistA)
        XCTAssertTrue(g1.isEmpty)

        let lowVotes = CannedTransport(json: "{\"genres\":[{\"name\":\"x\",\"count\":1}]}")
        let g2 = try await makeClient(lowVotes).artistGenres(forArtistMbid: artistA)
        XCTAssertTrue(g2.isEmpty)

        let missing = CannedTransport(json: "{}")
        let g3 = try await makeClient(missing).artistGenres(forArtistMbid: artistA)
        XCTAssertTrue(g3.isEmpty)
    }

    func testAridFallbackWhenConstrainedSearchEmpty() async throws {
        // Empty for the arid-constrained query; a match for the unconstrained one.
        let transport = QueryVaryingTransport(
            aridJSON: "{\"recordings\":[]}",
            plainJSON: "{\"recordings\":[{\"id\":\"\(recA)\",\"score\":95}]}")
        let match = try await makeClient(transport).bestRecording(
            artist: "Aphex Twin", title: "Xtal", durationMs: nil,
            artistMBID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        XCTAssertEqual(match?.recordingMBID, recA) // found via fallback
        XCTAssertEqual(transport.requestCount, 2)  // constrained (empty), then fallback
    }

    func testNoFallbackWhenConstrainedResultsRejected() async throws {
        // Constrained search returns a candidate, but it fails the score gate.
        // We must NOT drop the arid and accept a different-artist match.
        let transport = QueryVaryingTransport(
            aridJSON: "{\"recordings\":[{\"id\":\"\(recA)\",\"score\":40}]}",
            plainJSON: "{\"recordings\":[{\"id\":\"\(recA)\",\"score\":100}]}")
        let match = try await makeClient(transport).bestRecording(
            artist: "Aphex Twin", title: "Xtal", durationMs: nil,
            artistMBID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        XCTAssertNil(match)                        // rejected → no fallback
        XCTAssertEqual(transport.requestCount, 1)  // no second request
    }
}

/// Returns one JSON body for arid-constrained queries and another otherwise, so
/// the arid fallback / no-fallback paths can be exercised.
private final class QueryVaryingTransport: HTTPTransport, @unchecked Sendable {
    let aridJSON: String
    let plainJSON: String
    private let lock = NSLock()
    private(set) var requestCount = 0
    init(aridJSON: String, plainJSON: String) {
        self.aridJSON = aridJSON
        self.plainJSON = plainJSON
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); requestCount += 1; lock.unlock()
        let url = request.url?.absoluteString.removingPercentEncoding ?? ""
        let json = url.contains("arid:") ? aridJSON : plainJSON
        return (Data(json.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
