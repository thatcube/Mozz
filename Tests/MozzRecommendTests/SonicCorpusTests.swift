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

/// Mutual closeness: judging a pairing from both sides, which is what stops a
/// station being built out of a track's least-bad option.
final class SonicMutualityTests: XCTestCase {
    /// A dense cluster plus one track far away from everything — the shape of a
    /// library with a single classical recording in it.
    private func libraryWithAnOutlier() -> ([(remoteId: String, vector: [Float])], Int) {
        var entries: [(remoteId: String, vector: [Float])] = []
        for i in 0..<60 {
            let jitter = Float(i % 7) * 0.01
            entries.append(("crowd\(i)", [1.0 + jitter, 0.05 * Float(i % 5), 0.02 * jitter]))
        }
        entries.append(("loner", [0.0, 0.0, 1.0]))
        return (entries, entries.count - 1)
    }

    func testTheLonerIsFurtherFromItsBestMatchThanAnyoneElseIs() {
        let (entries, lonerIndex) = libraryWithAnOutlier()
        let corpus = SonicCorpus(entries)
        let vectors = corpus.entries.map(\.vector)

        func separationOfBestMatch(_ i: Int) -> Double {
            var best = (distance: Double.infinity, index: -1)
            for j in vectors.indices where j != i {
                var dot = 0.0
                for k in 0..<vectors[i].count { dot += Double(vectors[i][k]) * Double(vectors[j][k]) }
                let distance = 1 - dot
                if distance < best.distance { best = (distance, j) }
            }
            guard let mine = corpus.distanceProfile(vectors[i]),
                  let theirs = corpus.distanceProfile(vectors[best.index]) else { return 0 }
            return Swift.max(SonicCorpus.separation(best.distance, mine),
                             SonicCorpus.separation(best.distance, theirs))
        }

        let loner = separationOfBestMatch(lonerIndex)
        let ordinary = (0..<10).map(separationOfBestMatch)
        // Every ordinary track's best match is closer, from its worse side,
        // than the loner's is.
        for value in ordinary {
            XCTAssertLessThan(value, loner)
        }
    }

    func testAPairingIsJudgedFromTheSideThatLikesItLess() {
        // The asymmetry the whole thing rests on: a distance can be a track's
        // best available option and still be an outlier from the other track's
        // point of view.
        let near = (mean: 1.0, deviation: 0.05)   // a track in a dense cluster
        let far = (mean: 1.6, deviation: 0.30)    // a track out on its own
        let distance = 1.2

        let fromFar = SonicCorpus.separation(distance, far)
        let fromNear = SonicCorpus.separation(distance, near)
        XCTAssertLessThan(fromFar, 0, "closer than that track's average")
        XCTAssertGreaterThan(fromNear, 0, "further than that track's average")
        XCTAssertGreaterThan(Swift.max(fromFar, fromNear), fromFar,
                             "the worse side is what counts")
    }

    func testTailProbabilityIsAProperTail() {
        let profile = (mean: 1.0, deviation: 0.2)
        XCTAssertEqual(SonicCorpus.tailProbability(1.0, profile), 0.5, accuracy: 1e-6)
        XCTAssertGreaterThan(SonicCorpus.tailProbability(0.6, profile), 0.97)
        XCTAssertLessThan(SonicCorpus.tailProbability(1.4, profile), 0.03)
        // A degenerate spread must not produce a NaN that poisons a ranking.
        let flat = (mean: 1.0, deviation: 0.0)
        XCTAssertEqual(SonicCorpus.tailProbability(0.5, flat), 1)
        XCTAssertEqual(SonicCorpus.tailProbability(1.5, flat), 0)
    }

    func testTheReferenceSampleSpansTheLibrary() {
        // Strided, not the first 256: a sample of the opening of a library
        // describes the opening of a library, and these statistics are supposed
        // to describe the whole of one.
        let vectors = (0..<1000).map { i in [Float(i)] }
        let sample = SonicCorpus.sample(vectors, count: SonicCorpus.referenceSample)
        XCTAssertEqual(sample.count, SonicCorpus.referenceSample)
        XCTAssertEqual(sample.first?[0], 0)
        XCTAssertGreaterThan(sample.last?[0] ?? 0, 700)

        // A library smaller than the sample is used whole.
        let small = (0..<10).map { i in [Float(i)] }
        XCTAssertEqual(SonicCorpus.sample(small, count: 256).count, 10)

        let corpus = SonicCorpus((0..<1000).map { ("t\($0)", [Float($0), Float($0 % 3), 1.0]) })
        XCTAssertEqual(corpus.reference.count, SonicCorpus.referenceSample)
    }
}
