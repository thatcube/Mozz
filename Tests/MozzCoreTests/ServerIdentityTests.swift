import Foundation
@testable import MozzCore
import XCTest

final class ServerIdentityTests: XCTestCase {
    func testPlexIdentityMatchesEveryDesktopShell() {
        XCTAssertEqual(
            ServerIdentity.id(
                kind: .plex,
                baseURL: URL(string: "https://ignored.plex.direct")!,
                serverMachineIdentifier: "machine-123"),
            "plex-machine-123")
    }

    func testLegacyPlexDirectURLDerivesTheStableMachineIdentity() {
        XCTAssertEqual(
            ServerIdentity.id(
                kind: .plex,
                baseURL: URL(string:
                    "https://192-168-68-71.50acfe994de74f8998deb9fc43e6262e.plex.direct:32400")!),
            "plex-50acfe994de74f8998deb9fc43e6262e")
    }

    func testSubsonicIdentityIncludesTheAccount() {
        let url = URL(string: "https://music.example.test")!
        XCTAssertNotEqual(
            ServerIdentity.id(
                kind: .subsonic, baseURL: url, username: "alice"),
            ServerIdentity.id(
                kind: .subsonic, baseURL: url, username: "bob"))
    }
}
