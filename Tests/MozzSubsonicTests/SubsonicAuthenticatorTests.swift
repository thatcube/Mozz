import XCTest
import Foundation
import MozzCore
import MozzNetworking
@testable import MozzSubsonic

/// Covers ``SubsonicAuthenticator`` — tri-mode sign-in, credential envelope
/// construction (plaintext password discarded), and `ping`-is-authoritative
/// verification (architecture points 5 and 10).
final class SubsonicAuthenticatorTests: XCTestCase {
    private func makeAuthenticator(transport: any HTTPTransport) -> SubsonicAuthenticator {
        SubsonicAuthenticator(
            baseURL: URL(string: "https://music.example.com")!,
            clientIdentifier: "client-uuid",
            transport: transport
        )
    }

    func testAuthenticateWithPasswordDiscardsPlaintextAndPersistsStableSalt() async throws {
        let transport = FixtureTransport([.init(contains: "ping", fixture: "sub_ping_ok")])
        let session = try await makeAuthenticator(transport: transport)
            .authenticate(username: "brandon", password: "hunter2")
        XCTAssertEqual(session.kind, .subsonic)
        XCTAssertEqual(session.userID, "brandon")
        XCTAssertEqual(session.serverName, "Navidrome")

        let credential = try SubsonicCredential.decoded(from: session.token)
        XCTAssertEqual(credential.mode, .md5)
        XCTAssertEqual(credential.username, "brandon")
        XCTAssertNotNil(credential.salt)
        // The plaintext password must never appear anywhere in the persisted
        // envelope — only the derived md5(password+salt) token.
        XCTAssertNotEqual(credential.secret, "hunter2")
        XCTAssertFalse(session.token.contains("hunter2"))
        XCTAssertEqual(credential.secret, SubsonicAuth.md5Token(password: "hunter2", salt: credential.salt!))
    }

    func testAuthenticateWithApiKeyProducesApiKeyCredential() async throws {
        let transport = FixtureTransport([.init(contains: "ping", fixture: "sub_ping_ok")])
        let session = try await makeAuthenticator(transport: transport)
            .authenticate(username: "brandon", apiKey: "my-api-key")
        let credential = try SubsonicCredential.decoded(from: session.token)
        XCTAssertEqual(credential.mode, .apiKey)
        XCTAssertEqual(credential.secret, "my-api-key")
        XCTAssertNil(credential.salt)
    }

    func testAuthenticateFailureSurfacesMappedError() async throws {
        let transport = FixtureTransport([.init(contains: "ping", fixture: "sub_error_wrongauth")])
        do {
            _ = try await makeAuthenticator(transport: transport).authenticate(username: "brandon", password: "wrong")
            XCTFail("expected sign-in to fail")
        } catch let error as MozzError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testServerNameFallsBackToHostWhenTypeMissing() async throws {
        let transport = FixtureTransport([.init(contains: "ping", fixture: "sub_ping_classic")])
        let session = try await makeAuthenticator(transport: transport)
            .authenticate(username: "brandon", apiKey: "key")
        XCTAssertEqual(session.serverName, "music.example.com")
    }

    func testUsernameIsTrimmedButNotLowercased() async throws {
        let transport = FixtureTransport([.init(contains: "ping", fixture: "sub_ping_ok")])
        let session = try await makeAuthenticator(transport: transport)
            .authenticate(username: "  Brandon  ", apiKey: "key")
        // Subsonic usernames are case-sensitive server-side — only
        // whitespace is trimmed, never re-cased.
        XCTAssertEqual(session.userID, "Brandon")
    }
}

final class SubsonicURLNormalizerTests: XCTestCase {
    func testBareHostGetsHTTPSScheme() {
        XCTAssertEqual(SubsonicURLNormalizer.normalize("navidrome.example.com")?.absoluteString, "https://navidrome.example.com")
    }

    func testExplicitSchemeIsPreserved() {
        XCTAssertEqual(SubsonicURLNormalizer.normalize("http://192.168.1.10:4533")?.absoluteString, "http://192.168.1.10:4533")
    }

    func testTrailingSlashIsStripped() {
        XCTAssertEqual(SubsonicURLNormalizer.normalize("https://navidrome.example.com/")?.absoluteString, "https://navidrome.example.com")
    }

    func testEmptyStringIsNil() {
        XCTAssertNil(SubsonicURLNormalizer.normalize("   "))
    }

    func testNoDefaultPortIsInjected() {
        // Unlike JellyfinURLNormalizer, Subsonic servers have no shared
        // default port — must never guess one.
        let url = SubsonicURLNormalizer.normalize("navidrome.example.com")
        XCTAssertNil(url?.port)
    }
}
