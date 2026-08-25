import XCTest
@testable import MozzCore

final class AlbumReleaseClassifierTests: XCTestCase {
    func testClassifiesSinglesEPsAndAlbumsFromExistingSharedRules() {
        XCTAssertEqual(AlbumReleaseClassifier.kind(trackCount: 1), .singleOrEP)
        XCTAssertEqual(AlbumReleaseClassifier.kind(trackCount: 3), .singleOrEP)
        XCTAssertEqual(AlbumReleaseClassifier.kind(trackCount: 4), .album)
        XCTAssertEqual(AlbumReleaseClassifier.kind(trackCount: nil), .album)
        XCTAssertTrue(AlbumReleaseClassifier.isSingleOrEP(trackCount: 3))
        XCTAssertFalse(AlbumReleaseClassifier.isSingleOrEP(trackCount: nil))
    }
}
