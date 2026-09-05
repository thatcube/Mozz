import Foundation
import GRDB
import MozzCore
@testable import MozzDatabase
import XCTest

/// Moving a library from one server id to another.
///
/// This exists because it happened. A Plex library was filed under an id
/// derived from a `*.plex.direct` hostname, whose middle component looks like a
/// machine identifier and is not one — it identifies the connection. When the
/// client started sending the real machine id, the catalog appeared to vanish
/// and 1,715 analysed vectors were left under a `track_ref` prefix nothing
/// looked up any more.
final class ServerIdentityRekeyTests: XCTestCase {
    private let old = "plex-50acfe994de74f8998deb9fc43e6262e"
    private let new = "plex-c1f3d6597895238bb5c660ca489a5c2cd1ae623d"
    private let baseURL = URL(
        string: "https://172-18-0-1.50acfe994de74f8998deb9fc43e6262e.plex.direct:32400")!

    private func library(_ database: MusicDatabase, serverId: String) async throws {
        let writer = CatalogWriter(database)
        try await writer.saveServer(ServerConnection(
            id: serverId, kind: .plex, name: "Brandoland",
            baseURL: baseURL, userID: nil, clientIdentifier: "c"))
        try await writer.upsertTracks((1...4).map {
            Track(id: "t\($0)", title: "Track \($0)",
                  artistName: "Artist", artistID: "a", duration: 180)
        }, serverId: serverId)
        let store = RecommendationStore(database)
        for index in 1...4 {
            try await store.saveSonicEmbedding(
                [Float(index), 0.5], engine: "mozz-vggish@1", bpm: nil,
                trackRef: "\(serverId):t\(index)", at: 1_000)
        }
    }

    func testTheLibraryAndItsAnalysisMoveTogether() async throws {
        let database = try MusicDatabase.inMemory()
        try await library(database, serverId: old)

        let moved = try await ServerIdentityRekey.apply(in: database, from: old, to: new)
        XCTAssertNotNil(moved)

        let tracks = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE serverId = ?",
                             arguments: [self.new]) ?? 0
        }
        XCTAssertEqual(tracks, 4)

        // The part that actually costs something to lose.
        let vectors = try await database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM track_features
                WHERE embedding IS NOT NULL AND substr(track_ref, 1, ?) = ?
                """, arguments: ["\(self.new):".count, "\(self.new):"]) ?? 0
        }
        XCTAssertEqual(vectors, 4, "the analysis has to arrive with the catalog")

        let strays = try await database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM track_features WHERE track_ref LIKE ?
                """, arguments: ["\(self.old):%"]) ?? 0
        }
        XCTAssertEqual(strays, 0)
    }

    func testTheVectorItselfIsUnchanged() async throws {
        let database = try MusicDatabase.inMemory()
        try await library(database, serverId: old)
        let before = try await RecommendationStore(database)
            .sonicEmbedding(trackRef: "\(old):t2", engine: "mozz-vggish@1")

        try await ServerIdentityRekey.apply(in: database, from: old, to: new)

        let after = try await RecommendationStore(database)
            .sonicEmbedding(trackRef: "\(new):t2", engine: "mozz-vggish@1")
        XCTAssertEqual(after, before, "a rename must not touch the numbers")
    }

    func testItRefusesWhenTheDestinationAlreadyHasALibrary() async throws {
        let database = try MusicDatabase.inMemory()
        try await library(database, serverId: old)
        try await library(database, serverId: new)

        // Merging two catalogs is a different and much harder problem than a
        // rename, and getting it wrong silently is worse than doing nothing.
        let moved = try await ServerIdentityRekey.apply(in: database, from: old, to: new)
        XCTAssertNil(moved)
    }

    func testItDoesNothingWhenThereIsNothingToMove() async throws {
        let database = try MusicDatabase.inMemory()
        let moved = try await ServerIdentityRekey.apply(in: database, from: old, to: new)
        XCTAssertNil(moved)
    }

    func testARemoteIdContainingAColonSurvives() async throws {
        let database = try MusicDatabase.inMemory()
        try await library(database, serverId: old)
        try await RecommendationStore(database).saveSonicEmbedding(
            [1, 2], engine: "mozz-vggish@1", bpm: nil,
            trackRef: "\(old):library/metadata/12:34", at: 1_000)

        try await ServerIdentityRekey.apply(in: database, from: old, to: new)

        let vector = try await RecommendationStore(database).sonicEmbedding(
            trackRef: "\(new):library/metadata/12:34", engine: "mozz-vggish@1")
        XCTAssertEqual(vector, [1, 2], "only the prefix is the server id")
    }

    // MARK: Recognising the case in the first place

    func testAPlexDirectHostnameIsRecognisedAsTheSupersededId() {
        XCTAssertEqual(
            ServerIdentityRekey.supersededPlexID(
                for: new, kind: .plex, baseURL: baseURL),
            old,
            "the hostname component is the connection's id, not the machine's")
    }

    func testAnIdThatAlreadyAgreesIsNotMigrated() {
        XCTAssertNil(ServerIdentityRekey.supersededPlexID(
            for: old, kind: .plex, baseURL: baseURL))
    }

    func testOtherBackendsAreLeftAlone() {
        XCTAssertNil(ServerIdentityRekey.supersededPlexID(
            for: "jellyfin-x", kind: .jellyfin,
            baseURL: URL(string: "https://jf.example")!))
    }
}
