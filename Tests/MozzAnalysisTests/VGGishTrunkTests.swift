import XCTest
import Foundation
@testable import MozzAnalysis

/// Proves the hand-written convolution stack computes what PyTorch computes.
///
/// This is the test that makes porting a model defensible at all. Six
/// convolutions is not much code, but "not much code" and "the same numbers as
/// the reference implementation" are different claims, and only one of them
/// keeps an iPhone's vectors comparable with a Pixel's.
///
/// The weights are not in the repository — they are 9 MB and belong wherever
/// each platform ships resources — so this skips unless `MOZZ_VGGISH_WEIGHTS`
/// points at the file `tools/export-vggish.py` produced.
final class VGGishTrunkTests: XCTestCase {
    private func trunk() throws -> VGGishTrunk {
        guard let path = ProcessInfo.processInfo.environment["MOZZ_VGGISH_WEIGHTS"] else {
            throw XCTSkip("set MOZZ_VGGISH_WEIGHTS to the exported vggish-trunk.bin")
        }
        return try VGGishTrunk(weights: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json",
                                                  subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTheEmbeddingMatchesPyTorch() throws {
        let trunk = try trunk()
        let fixture = try fixture("conv-fixture")
        let input = try XCTUnwrap(fixture["input"] as? [Double]).map(Float.init)
        let expected = try XCTUnwrap(fixture["embedding"] as? [Double]).map(Float.init)

        let embedding = trunk.embed(patch: input)
        XCTAssertEqual(embedding.count, VGGishTrunk.embeddingSize)
        XCTAssertEqual(embedding.count, expected.count)

        // Half-precision weights, and a different summation order from
        // PyTorch's, so exact equality is not the bar — agreeing to well
        // within the differences that separate one track from another is.
        var worst: Float = 0
        for (got, want) in zip(embedding, expected) {
            worst = Swift.max(worst, abs(got - want))
        }
        XCTAssertLessThan(worst, 0.01, "largest per-value deviation from PyTorch")

        // And the thing that actually matters downstream: the same direction.
        var dot = 0.0, gotNorm = 0.0, wantNorm = 0.0
        for (got, want) in zip(embedding, expected) {
            dot += Double(got) * Double(want)
            gotNorm += Double(got) * Double(got)
            wantNorm += Double(want) * Double(want)
        }
        let cosine = dot / (gotNorm.squareRoot() * wantNorm.squareRoot())
        XCTAssertGreaterThan(cosine, 0.9999, "cosine against the reference embedding")
    }

    func testHalfPrecisionWidensExactly() {
        // The values that break naive conversions: zero, subnormals, the
        // largest finite half, and a plain fraction.
        XCTAssertEqual(VGGishTrunk.float(fromHalf: 0x0000), 0)
        XCTAssertEqual(VGGishTrunk.float(fromHalf: 0x8000), -0.0)
        XCTAssertEqual(VGGishTrunk.float(fromHalf: 0x3C00), 1)
        XCTAssertEqual(VGGishTrunk.float(fromHalf: 0xC000), -2)
        XCTAssertEqual(VGGishTrunk.float(fromHalf: 0x3555), 0.333251953125, accuracy: 1e-9)
        XCTAssertEqual(VGGishTrunk.float(fromHalf: 0x7BFF), 65504)
        XCTAssertEqual(VGGishTrunk.float(fromHalf: 0x0001), 5.9604645e-08, accuracy: 1e-14)
        XCTAssertEqual(VGGishTrunk.float(fromHalf: 0x03FF), 6.0975552e-05, accuracy: 1e-11)
    }

    func testRefusesSomethingThatIsNotWeights() {
        XCTAssertThrowsError(try VGGishTrunk(weights: Data("not weights at all".utf8)))
        XCTAssertThrowsError(try VGGishTrunk(weights: Data()))
    }
}
