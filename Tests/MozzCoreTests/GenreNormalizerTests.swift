import XCTest
@testable import MozzCore

final class GenreNormalizerTests: XCTestCase {
    func testKeyLowercasesAndFoldsSeparators() {
        XCTAssertEqual(GenreNormalizer.key("Hip-Hop"), "hip hop")
        XCTAssertEqual(GenreNormalizer.key("Hip Hop"), "hip hop")
        XCTAssertEqual(GenreNormalizer.key("hip_hop"), "hip hop")
        XCTAssertEqual(GenreNormalizer.key("HIP  HOP"), "hip hop")
        XCTAssertEqual(GenreNormalizer.key("Alternative/Indie"), "alternative indie")
        XCTAssertEqual(GenreNormalizer.key("  Dream  Pop  "), "dream pop")
        XCTAssertEqual(GenreNormalizer.key("Rock"), "rock")
    }

    func testKeyMatchesMusicBrainzLowercaseForm() {
        // Plex Title-Case must collapse to the same key as the MB lowercase tag.
        XCTAssertEqual(GenreNormalizer.key("Hip-Hop"), GenreNormalizer.key("hip hop"))
        XCTAssertEqual(GenreNormalizer.key("Alternative Rock"), GenreNormalizer.key("alternative rock"))
    }

    func testKeyEmptyForBlankOrSeparatorOnly() {
        XCTAssertEqual(GenreNormalizer.key(""), "")
        XCTAssertEqual(GenreNormalizer.key("   "), "")
        XCTAssertEqual(GenreNormalizer.key(" - / _ "), "")
    }

    func testKeysDedupesNormalizedPreservingOrderDroppingEmpties() {
        XCTAssertEqual(
            GenreNormalizer.keys(["Rock", "rock", "Hip-Hop", "hip hop", "", "  "]),
            ["rock", "hip hop"])
    }

    func testMergeUnionsBothSidesCanonically() {
        // track.genres (Title-Case) ∪ mb_tags (lowercase) → one canonical set.
        XCTAssertEqual(
            GenreNormalizer.merge(["Rock", "Hip-Hop"], ["hip hop", "electronic"]),
            ["rock", "hip hop", "electronic"])
    }

    func testDisplayTitleCasesKey() {
        XCTAssertEqual(GenreNormalizer.display("hip hop"), "Hip Hop")
        XCTAssertEqual(GenreNormalizer.display("alternative rock"), "Alternative Rock")
        XCTAssertEqual(GenreNormalizer.display("rock"), "Rock")
        XCTAssertEqual(GenreNormalizer.display(""), "")
    }
}
