import XCTest
@testable import MozzCore

final class MusicBrainzIDTests: XCTestCase {
    private let valid = "b1a9c0e9-d987-4042-ae91-78d6a3267d69"

    func testValidatesCanonicalShapeCaseInsensitively() {
        XCTAssertTrue(MusicBrainzID.isValid(valid))
        XCTAssertTrue(MusicBrainzID.isValid(valid.uppercased()))
        XCTAssertEqual(MusicBrainzID.normalized(valid.uppercased()), valid)
        XCTAssertEqual(MusicBrainzID.normalized("  \(valid)  "), valid)
    }

    func testRejectsNonCanonical() {
        XCTAssertFalse(MusicBrainzID.isValid("not-a-uuid"))
        XCTAssertFalse(MusicBrainzID.isValid("b1a9c0e9d9874042ae9178d6a3267d69"))    // no dashes
        XCTAssertFalse(MusicBrainzID.isValid("b1a9c0e9-d987-4042-ae91-78d6a3267d6")) // too short
        XCTAssertNil(MusicBrainzID.normalized("garbage"))
        XCTAssertNil(MusicBrainzID.normalized(nil))
    }

    func testAcceptsNonV4UUID() {
        // MBIDs are NOT guaranteed UUID version 4 — validation must not check the
        // version nibble. This one has version '1'.
        let v1 = "b1a9c0e9-d987-1042-ae91-78d6a3267d69"
        XCTAssertTrue(MusicBrainzID.isValid(v1))
    }

    func testExtractsFromGUIDForms() {
        XCTAssertEqual(MusicBrainzID.extract(fromGUID: valid), valid)
        XCTAssertEqual(MusicBrainzID.extract(fromGUID: "mbid://\(valid)"), valid)
        XCTAssertEqual(MusicBrainzID.extract(fromGUID: "mbz://\(valid)"), valid)
        XCTAssertEqual(MusicBrainzID.extract(fromGUID: "musicbrainz://\(valid)"), valid)
        XCTAssertEqual(MusicBrainzID.extract(fromGUID: "https://musicbrainz.org/recording/\(valid)"), valid)
        XCTAssertEqual(MusicBrainzID.extract(fromGUID: "\(valid.uppercased())"), valid)
    }

    func testExtractsLegacyPlexAgentScheme() {
        let guid = "com.plexapp.agents.musicbrainz://\(valid)?lang=en"
        XCTAssertEqual(MusicBrainzID.extract(fromGUID: guid), valid)
    }

    func testIgnoresNonMusicBrainzGUIDs() {
        // A Plex hash GUID has no UUID and doesn't name MusicBrainz → nil.
        XCTAssertNil(MusicBrainzID.extract(fromGUID: "plex://track/5d07b3d1f4c8"))
        XCTAssertNil(MusicBrainzID.extract(fromGUID: "tmdb://12345"))
        XCTAssertNil(MusicBrainzID.extract(fromGUID: nil))
        XCTAssertNil(MusicBrainzID.extract(fromGUID: ""))
    }
}
