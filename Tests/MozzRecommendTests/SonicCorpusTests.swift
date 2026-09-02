import XCTest
import MozzCore
@testable import MozzRecommend

/// The corpus transform, which is what makes a nearest-neighbour list mean
/// anything. See `SonicCorpus` for the measurements that motivated it.
final class SonicCorpusTests: XCTestCase {
    /// Vectors with one dimension everybody shares and one that actually
    /// separates them — the shape of a real library, exaggerated.
    private func library(count: Int) -> [(remoteId: String, vector: [Float])] {
        (0..<count).map { i in
            let group = Float(i % 2)              // the dimension that matters
            let jitter = Float(i % 5) * 0.001
            return ("t\(i)", [10.0 + jitter, group, 0.5 + jitter])
        }
    }

    func testTheSharedDimensionStopsDrowningTheOneThatVaries() {
        let raw = library(count: 40)
        let corpus = SonicCorpus(raw)

        func cosine(_ a: [Float], _ b: [Float]) -> Double {
            var dot = 0.0
            for i in 0..<a.count { dot += Double(a[i]) * Double(b[i]) }
            return dot
        }
        // t0 and t2 are the same group; t0 and t1 are not.
        let same = cosine(corpus.entries[0].vector, corpus.entries[2].vector)
        let different = cosine(corpus.entries[0].vector, corpus.entries[1].vector)
        XCTAssertGreaterThan(same, different)
        // And the gap is a real one, not a rounding artefact — which is exactly
        // what the raw vectors could not manage. (It is not larger because the
        // fixture's other two dimensions carry a little jitter of their own,
        // and standardizing gives that jitter a vote too. That is the trade:
        // dimensions are heard on their own scale, noise included.)
        XCTAssertGreaterThan(same - different, 0.1)

        var rawDot = 0.0
        for i in 0..<3 { rawDot += Double(raw[0].vector[i]) * Double(raw[1].vector[i]) }
        var rawSame = 0.0
        for i in 0..<3 { rawSame += Double(raw[0].vector[i]) * Double(raw[2].vector[i]) }
        let rawGap = abs(rawSame - rawDot) / rawSame
        XCTAssertLessThan(rawGap, 0.02, "the raw space should be the flat one")
    }

    func testASeedIsPutIntoTheSameSpaceAsTheCorpus() {
        let raw = library(count: 40)
        let corpus = SonicCorpus(raw)
        // A seed that IS one of the corpus tracks must land exactly where its
        // stored copy did, or a station's own seed would rank oddly against it.
        let seed = corpus.normalize(raw[6].vector)
        XCTAssertEqual(seed.count, corpus.entries[6].vector.count)
        for i in 0..<seed.count {
            XCTAssertEqual(seed[i], corpus.entries[6].vector[i], accuracy: 1e-5)
        }
    }

    func testASmallLibraryIsLeftAlone() {
        // Statistics over a handful of tracks describe the handful, not the
        // music, so below the floor the vectors are compared as stored.
        let raw = library(count: SonicCorpus.minimumForStatistics - 1)
        let corpus = SonicCorpus(raw)
        let magnitude = corpus.entries[0].vector.reduce(0) { $0 + $1 * $1 }
        XCTAssertEqual(Double(magnitude), 1.0, accuracy: 1e-4, "still unit length")
        // Unit-normalized but NOT re-centred: the big shared dimension survives.
        XCTAssertGreaterThan(corpus.entries[0].vector[0], 0.9)
    }

    func testEveryVectorComesOutUnitLength() {
        for entry in SonicCorpus(library(count: 40)).entries {
            let magnitude = Double(entry.vector.reduce(0) { $0 + $1 * $1 })
            XCTAssertEqual(magnitude, 1.0, accuracy: 1e-4)
        }
    }
}
