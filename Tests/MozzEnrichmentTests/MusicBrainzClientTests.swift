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
    private func makeClient(_ transport: CannedTransport) -> MusicBrainzClient {
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
}
