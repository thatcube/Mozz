import XCTest
import MozzCore
import GRDB
@testable import MozzDatabase
@testable import MozzRecommend

private func srv(_ id: String = "s1") -> ServerConnection {
    ServerConnection(id: id, kind: .plex, name: "T",
                     baseURL: URL(string: "https://x.local")!, userID: nil, clientIdentifier: "c1")
}
private let fixedNow = Date(timeIntervalSince1970: 2_000_000)
private let artistSeed = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
private let artistCand = "cccccccc-3333-4333-8333-cccccccccccc"
private let artistHH = "dddddddd-4444-4444-8444-dddddddddddd"

/// B4.5 — the service-level genre-engine wiring: gating (off == today), symmetric
/// mb_tags lift on radio, seed-not-found fallback, and Smart Shuffle's composed-ref
/// mb_tags merge.
final class GenreEnrichmentServiceTests: XCTestCase {
    private func makeDB() async throws -> (MusicDatabase, CatalogWriter, EnrichmentStore) {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        try await writer.saveServer(srv())
        return (db, writer, EnrichmentStore(db))
    }

    private func service(_ db: MusicDatabase, enrich: Bool) -> RecommendationService {
        RecommendationService(store: RecommendationStore(db), now: { fixedNow },
                              isEnrichmentEnabled: { enrich })
    }

    /// A candidate reachable ONLY via a shared mb_tag (its Plex genre differs from
    /// the seed's) joins the station when enriched, and is absent when off — the
    /// gating + symmetric-lift proof in one.
    func testRadioMbTagLiftGatedByEnrichmentFlag() async throws {
        let (db, writer, enrich) = try await makeDB()
        try await writer.upsertTracks([
            Track(id: "seed", title: "S", artistName: "SeedA", artistID: "sa", genres: ["Rock"], artistMbid: artistSeed),
            Track(id: "cand", title: "C", artistName: "CandA", artistID: "ca", genres: ["Jazz"], artistMbid: artistCand),
            Track(id: "polka", title: "P", artistName: "PolkaA", artistID: "pa", genres: ["Polka"]),
        ], serverId: "s1")
        // Seed and candidate share the crowd tag "electronic" only via mb_tags.
        try await enrich.setArtistTags(artistMbid: artistSeed, tags: ["electronic"], at: 100)
        try await enrich.setArtistTags(artistMbid: artistCand, tags: ["electronic"], at: 100)

        let seed = RadioSeed(title: "S", genres: ["Rock"], artistIds: [], seedTrackRef: "s1:seed")

        let on = try await service(db, enrich: true).radioBatch(
            seed: seed, serverId: "s1", limit: 10, excluding: ["seed"], similar: [])
        XCTAssertTrue(on.contains("cand"), "shared mb_tag should lift the candidate into the station")
        XCTAssertFalse(on.contains("polka"), "genre outlier stays excluded")

        let off = try await service(db, enrich: false).radioBatch(
            seed: seed, serverId: "s1", limit: 10, excluding: ["seed"], similar: [])
        XCTAssertFalse(off.contains("cand"), "with enrichment off, mb_tags are ignored (== today)")
    }

    /// A seed whose track row is missing must fall back to the caller's genres and
    /// still return a station (never empty) — the prod-safe behavior.
    func testSeedNotFoundFallsBackToCallerGenres() async throws {
        let (db, writer, _) = try await makeDB()
        try await writer.upsertTracks((1...5).map {
            Track(id: "rock\($0)", title: "R", artistName: "A\($0)", artistID: "a\($0)", genres: ["Rock"])
        }, serverId: "s1")
        let seed = RadioSeed(title: "S", genres: ["Rock"], artistIds: [], seedTrackRef: "s1:doesnotexist")
        let ids = try await service(db, enrich: true).radioBatch(
            seed: seed, serverId: "s1", limit: 5, excluding: [], similar: [])
        XCTAssertFalse(ids.isEmpty, "missing seed row must not empty the station")
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("rock") })
    }

    /// Smart Shuffle enriches a domain track by its COMPOSED track_ref (serverId:
    /// remoteId). A track that matches taste only via its mb_tag scores > 0 when
    /// enriched (proving the composed-ref lookup ran — a bare-id lookup would miss).
    func testSmartShuffleComposedRefMbTagLift() async throws {
        let (db, writer, enrich) = try await makeDB()
        // Taste: several completed plays of a hip-hop track.
        try await writer.upsertTracks([
            Track(id: "hh", title: "HH", artistName: "HHA", artistID: "hha", genres: ["Hip-Hop"], artistMbid: artistHH),
            Track(id: "x", title: "X", artistName: "XA", artistID: "xa", genres: ["Jazz"], artistMbid: artistCand),
        ], serverId: "s1")
        // Candidate x links to the taste genre only through its mb_tag "hip hop".
        try await enrich.setArtistTags(artistMbid: artistCand, tags: ["hip hop"], at: 100)
        try await db.write { d in
            for i in 0..<4 {
                try d.execute(sql: "INSERT INTO play_event (track_ref, kind, created_at) VALUES ('s1:hh','completed',?)",
                              arguments: [1_999_000 + Double(i)])
            }
        }
        let x = Track(id: "x", title: "X", artistName: "XA", artistID: "xa", genres: ["Jazz"])

        let on = try await service(db, enrich: true).tasteScores(serverId: "s1", tracks: [x])
        XCTAssertGreaterThan(on["x"] ?? 0, 0, "mb_tag (via composed ref) should link x to hip-hop taste")

        let off = try await service(db, enrich: false).tasteScores(serverId: "s1", tracks: [x])
        XCTAssertEqual(off["x"] ?? 0, 0, "with enrichment off, x (Jazz) doesn't match hip-hop taste")
    }
}
