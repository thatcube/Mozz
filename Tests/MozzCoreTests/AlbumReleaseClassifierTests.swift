import XCTest
@testable import MozzCore

final class AlbumReleaseClassifierTests: XCTestCase {
    func testClassifiesSinglesEPsAndAlbumsFromSharedRules() {
        XCTAssertEqual(AlbumReleaseClassifier.kind(trackCount: 1, totalDurationSeconds: 180), .single)
        XCTAssertEqual(AlbumReleaseClassifier.kind(trackCount: 3, totalDurationSeconds: 29 * 60), .single)
        XCTAssertEqual(AlbumReleaseClassifier.kind(trackCount: 4, totalDurationSeconds: 20 * 60), .ep)
        XCTAssertEqual(AlbumReleaseClassifier.kind(trackCount: 6, totalDurationSeconds: nil), .ep)
        XCTAssertEqual(AlbumReleaseClassifier.kind(trackCount: 3, totalDurationSeconds: 31 * 60), .album)
        XCTAssertEqual(AlbumReleaseClassifier.kind(trackCount: 7, totalDurationSeconds: 20 * 60), .album)
        XCTAssertEqual(AlbumReleaseClassifier.kind(trackCount: nil, totalDurationSeconds: 20 * 60), .album)
    }
}
