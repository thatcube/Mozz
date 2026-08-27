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

    func testSubsonicIdentityIncludesTheAccount() {
        let url = URL(string: "https://music.example.test")!
        XCTAssertNotEqual(
            ServerIdentity.id(
                kind: .subsonic, baseURL: url, username: "alice"),
            ServerIdentity.id(
                kind: .subsonic, baseURL: url, username: "bob"))
    }
}
