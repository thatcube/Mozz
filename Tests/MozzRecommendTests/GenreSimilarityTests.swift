import XCTest
import MozzDatabase
@testable import MozzRecommend

final class GenreSimilarityTests: XCTestCase {
    // A library where "rock" is ubiquitous and "dream pop" is rare.
    private func space() -> GenreSimilarity {
        GenreSimilarity(totalTracks: 1000, counts: [
            "rock": 800,          // broad, ~everywhere
            "pop": 500,
            "indie pop": 40,
            "dream pop": 12,      // rare, distinctive
            "hard rock": 60,
            "blues rock": 30,
        ])
    }

    func testRareGenreOutweighsCommonGenre() {
        let s = space()
        XCTAssertGreaterThan(s.weight(for: "dream pop"), s.weight(for: "rock"),
                             "a rare genre must carry more weight than a ubiquitous one")
        XCTAssertGreaterThan(s.weight(for: "hard rock"), s.weight(for: "pop"))
    }

    func testVectorsAreL2Normalized() {
        let v = space().vector(for: ["pop", "dream pop", "indie pop"])
        let norm = v.values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        XCTAssertEqual(norm, 1.0, accuracy: 1e-9)
    }

    func testCosineIdentityAndDisjoint() {
        let s = space()
        let a = s.vector(for: ["pop", "dream pop"])
        XCTAssertEqual(s.cosine(a, a), 1.0, accuracy: 1e-9, "identical vectors → 1")
        let disjoint = s.cosine(s.vector(for: ["pop"]), s.vector(for: ["rock"]))
        XCTAssertEqual(disjoint, 0.0, accuracy: 1e-9, "no shared genre → 0")
        XCTAssertEqual(s.cosine([:], a), 0.0, "empty vector → 0")
    }

    func testCosineInZeroToOne() {
        let s = space()
        let sim = s.cosine(s.vector(for: ["pop", "dream pop", "indie pop"]),
                           s.vector(for: ["pop", "indie pop"]))
        XCTAssertGreaterThan(sim, 0)
        XCTAssertLessThanOrEqual(sim, 1.0 + 1e-9)
    }

    /// The core "AC/DC in a Zella Day station" fix: a candidate sharing only the
    /// broad "rock" tag must score far below one sharing the rare pop tags.
    func testBroadSharedTagScoresFarBelowRareSharedTags() {
        let s = space()
        let seed = s.vector(for: ["pop", "dream pop", "indie pop", "rock"])   // dream-pop track
        let hardRock = s.cosine(seed, s.vector(for: ["rock", "hard rock", "blues rock"]))  // shares only "rock"
        let dreamPop = s.cosine(seed, s.vector(for: ["pop", "dream pop"]))    // shares the rare tags
        XCTAssertLessThan(hardRock, dreamPop)
        XCTAssertLessThan(hardRock, 0.15, "broad-only match should fall below the radio similarity floor")
        XCTAssertGreaterThan(dreamPop, 0.5, "a genuine pop match should score high")
    }

    func testAffinityVectorWeightsByIDF() {
        let s = space()
        // Equal affinity on a common and a rare genre: the rare one dominates the vector.
        let v = s.vector(fromAffinities: ["rock": 1.0, "dream pop": 1.0])
        XCTAssertGreaterThan(v["dream pop"] ?? 0, v["rock"] ?? 0)
    }

    func testUnknownGenreTreatedAsRare() {
        let s = space()
        // A genre absent from the corpus is maximally rare → weight >= any known genre.
        let unknown = s.weight(for: "some-brand-new-genre")
        XCTAssertGreaterThanOrEqual(unknown, s.weight(for: "dream pop"))
        XCTAssertGreaterThan(unknown, s.weight(for: "rock"))
    }
}

final class ContentRecommenderCosineTests: XCTestCase {
    private func candidate(_ id: String, genres: [String], artistId: String? = nil) -> TrackCandidate {
        TrackCandidate(trackRef: id, remoteId: id, title: id, artistName: "Artist",
                       artistRemoteId: artistId, albumRemoteId: nil, genres: genres, addedAt: nil)
    }

    func testCosineScorerRanksRareMatchAboveBroadMatch() {
        let space = GenreSimilarity(totalTracks: 1000, counts: ["rock": 800, "dream pop": 12, "pop": 400])
        let scorer = ContentRecommender(genreSpace: space)
        let taste = TasteProfile(genreAffinity: ["dream pop": 3, "pop": 2, "rock": 1],
                                 artistAffinity: [:], positiveSignal: 6)
        let scored = scorer.score(candidates: [
            candidate("broad", genres: ["rock"]),
            candidate("rare", genres: ["dream pop", "pop"]),
        ], taste: taste)
        let byId = Dictionary(uniqueKeysWithValues: scored.map { ($0.candidate.remoteId, $0.score) })
        XCTAssertNotNil(byId["rare"])
        XCTAssertGreaterThan(byId["rare"] ?? 0, byId["broad"] ?? 0)
    }

    func testNilGenreSpaceUsesLegacySumScoring() {
        // Without a space, behavior is the original affinity-sum (unchanged).
        let scorer = ContentRecommender()
        let taste = TasteProfile(genreAffinity: ["rock": 1, "pop": 1],
                                 artistAffinity: [:], positiveSignal: 2)
        let scored = scorer.score(candidates: [candidate("t", genres: ["rock", "pop"])], taste: taste)
        // Sum scoring: 0.6 * (1 + 1) = 1.2.
        XCTAssertEqual(scored.first?.score ?? 0, 1.2, accuracy: 1e-9)
    }
}
