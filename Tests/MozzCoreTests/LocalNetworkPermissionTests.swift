import XCTest
@testable import MozzCore

final class LocalNetworkPermissionTests: XCTestCase {

    // MARK: isLocalHost

    func testDetectsLocalHosts() {
        let local = [
            "http://192.168.1.10:4533",
            "http://10.0.0.5",
            "http://172.16.0.9",
            "http://172.31.255.1",
            "http://169.254.3.4",
            "http://127.0.0.1:4533",
            "http://localhost:4533",
            "http://navidrome.local",
            "http://nas.lan",
            "http://server.home",
            "http://music.internal",
            "http://nas",              // single-label hostname
            "http://[fe80::1]",
            "http://[fd12:3456::1]",
        ]
        for s in local {
            XCTAssertTrue(LocalNetworkPermission.isLocalHost(URL(string: s)!), "\(s) should be local")
        }
    }

    func testDetectsRemoteHosts() {
        let remote = [
            "https://music.example.com",
            "https://navidrome.mydomain.org",
            "http://8.8.8.8",
            "http://172.32.0.1",       // just outside the 172.16/12 private range
            "http://172.15.0.1",       // just below it
            "https://demo.navidrome.org",
        ]
        for s in remote {
            XCTAssertFalse(LocalNetworkPermission.isLocalHost(URL(string: s)!), "\(s) should be remote")
        }
    }

    // MARK: retrying

    /// Simulates the iOS permission race: the first N connects are refused
    /// (serverUnreachable) while the prompt is up, then it succeeds. The helper
    /// must transparently retry to success for a LOCAL host.
    func testRetriesReachabilityFailureOnLocalHostThenSucceeds() async throws {
        let failures = Counter()
        let waits = Box()
        let value = try await LocalNetworkPermission.retrying(
            for: URL(string: "http://192.168.1.10:4533")!,
            attempts: 4, delay: .milliseconds(1),
            onWaiting: { waits.bump() }
        ) {
            if await failures.next() < 2 { throw MozzError.serverUnreachable }
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(waits.count, 2, "should have waited before each of the 2 retries")
    }

    /// A remote host never shows the prompt, so a reachability failure must NOT
    /// be retried — it fails fast.
    func testDoesNotRetryRemoteHost() async {
        let failures = Counter()
        do {
            _ = try await LocalNetworkPermission.retrying(
                for: URL(string: "https://music.example.com")!,
                attempts: 4, delay: .milliseconds(1)
            ) { () async throws -> Int in
                _ = await failures.next()
                throw MozzError.serverUnreachable
            }
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(error as? MozzError, .serverUnreachable)
        }
        let count = await failures.value
        XCTAssertEqual(count, 1, "remote host must be attempted exactly once")
    }

    /// A genuine auth rejection is not a reachability failure, so it must surface
    /// immediately even on a local host (no pointless retries on bad creds).
    func testDoesNotRetryAuthFailure() async {
        let failures = Counter()
        do {
            _ = try await LocalNetworkPermission.retrying(
                for: URL(string: "http://192.168.1.10:4533")!,
                attempts: 4, delay: .milliseconds(1)
            ) { () async throws -> Int in
                _ = await failures.next()
                throw MozzError.unauthorized
            }
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(error as? MozzError, .unauthorized)
        }
        let count = await failures.value
        XCTAssertEqual(count, 1, "auth failure must not be retried")
    }

    /// If the permission is never granted, the helper gives up after `attempts`
    /// and surfaces the real error.
    func testGivesUpAfterAttempts() async {
        let failures = Counter()
        do {
            _ = try await LocalNetworkPermission.retrying(
                for: URL(string: "http://192.168.1.10:4533")!,
                attempts: 3, delay: .milliseconds(1)
            ) { () async throws -> Int in
                _ = await failures.next()
                throw MozzError.serverUnreachable
            }
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(error as? MozzError, .serverUnreachable)
        }
        let count = await failures.value
        XCTAssertEqual(count, 3, "should attempt exactly `attempts` times")
    }
}

/// A tiny async-safe call counter for the retry tests.
private actor Counter {
    private(set) var value = 0
    func next() -> Int { defer { value += 1 }; return value }
}

/// A sync-callable counter for `onWaiting`. Accessed sequentially by the retry
/// loop (one attempt awaits before the next), so unchecked is safe here.
private final class Box: @unchecked Sendable {
    private(set) var count = 0
    func bump() { count += 1 }
}
