import XCTest
import Foundation
@testable import MozzJellyfin

/// Tests for the pure Jellyfin UDP discovery parser + URL normalizer. These run
/// against raw datagram bytes so they need no socket or server.
final class JellyfinDiscoveryParserTests: XCTestCase {
    private func payload(_ json: [String: String?]) -> Data {
        var obj: [String: Any] = [:]
        for (k, v) in json where v != nil { obj[k] = v! }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    func testParsesBasicAnnouncement() throws {
        let data = payload([
            "Address": "http://192.168.1.50:8096",
            "Id": "abc123",
            "Name": "Living Room Jellyfin",
        ])
        let server = try XCTUnwrap(JellyfinDiscoveryParser.parse(data, sourceIP: "192.168.1.50"))
        XCTAssertEqual(server.id, "abc123")
        XCTAssertEqual(server.name, "Living Room Jellyfin")
        XCTAssertEqual(server.baseURL.absoluteString, "http://192.168.1.50:8096")
    }

    func testPrefersSourceIPOverForeignAdvertisedAddress() throws {
        // Server on a multi-NIC host advertises a foreign-subnet address, but the
        // datagram arrived from a reachable IP — that must win.
        let data = payload([
            "Address": "http://192.168.0.5:8096",
            "Id": "srv",
            "Name": "Multi-NIC",
        ])
        let server = try XCTUnwrap(JellyfinDiscoveryParser.parse(data, sourceIP: "192.168.68.71"))
        // First candidate must target the reachable source IP…
        XCTAssertEqual(server.baseURL.host, "192.168.68.71")
        XCTAssertEqual(server.baseURL.port, 8096)
        // …and the advertised (foreign) address is still kept as a fallback.
        XCTAssertTrue(server.candidateURLs.contains { $0.host == "192.168.0.5" })
    }

    func testPreservesHTTPSAndPortFromEndpointAddress() throws {
        // A reverse-proxied server advertises https on 443; the reachable-host
        // candidate should keep that scheme/port, aimed at the source IP.
        let data = payload([
            "EndpointAddress": "https://jf.example.com:8920/jellyfin",
            "Id": "proxy",
            "Name": "Proxied",
        ])
        let server = try XCTUnwrap(JellyfinDiscoveryParser.parse(data, sourceIP: "10.0.0.9"))
        let first = server.baseURL
        XCTAssertEqual(first.scheme, "https")
        XCTAssertEqual(first.host, "10.0.0.9")
        XCTAssertEqual(first.port, 8920)
        XCTAssertEqual(first.path, "/jellyfin")
    }

    func testRejectsNonJellyfinPayload() {
        XCTAssertNil(JellyfinDiscoveryParser.parse(Data("not json".utf8)))
        XCTAssertNil(JellyfinDiscoveryParser.parse(payload([:])))
    }

    func testFallsBackToSourceIPForNameWhenUnnamed() throws {
        let data = payload(["Id": "id-only", "Address": "http://192.168.1.7:8096"])
        let server = try XCTUnwrap(JellyfinDiscoveryParser.parse(data, sourceIP: "192.168.1.7"))
        XCTAssertEqual(server.name, "192.168.1.7")
    }

    // MARK: URL normalizer

    func testNormalizerAddsSchemeAndDefaultPort() {
        XCTAssertEqual(JellyfinURLNormalizer.normalize("192.168.1.5")?.absoluteString,
                       "http://192.168.1.5:8096")
        XCTAssertEqual(JellyfinURLNormalizer.normalize("jelly.example.com")?.absoluteString,
                       "http://jelly.example.com:8096")
    }

    func testNormalizerRespectsExplicitSchemeAndStripsTrailingSlash() {
        XCTAssertEqual(JellyfinURLNormalizer.normalize("https://m.tld/jf/")?.absoluteString,
                       "https://m.tld/jf")
        // An explicit http scheme should NOT get the default port injected.
        XCTAssertEqual(JellyfinURLNormalizer.normalize("http://host")?.absoluteString,
                       "http://host")
    }

    func testNormalizerRejectsEmpty() {
        XCTAssertNil(JellyfinURLNormalizer.normalize(""))
        XCTAssertNil(JellyfinURLNormalizer.normalize("   "))
    }
}
