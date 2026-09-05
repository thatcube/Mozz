import Foundation
import MozzCore
import MozzNetworking
@testable import MozzPlex
import XCTest

/// Finding a Plex server by asking the network rather than the account.
///
/// The case this exists for: a server in a Docker bridge network advertises its
/// container address as "local", because that is the only address it believes
/// it has. plex.tv repeats that faithfully, no client can reach it, and the
/// listener is told their server is unreachable while every other Plex app
/// works. The reply to a local probe comes FROM the address that actually
/// works, which is the one thing neither the server nor plex.tv knows.
final class PlexLocalDiscoveryTests: XCTestCase {
    private let clientInfo = ClientInfo(
        product: "Mozz", version: "1.0", deviceName: "Test",
        platform: "iOS", platformVersion: "18")

    private func reply(
        machine: String = "c1f3d6597895238bb5c660ca489a5c2cd1ae623d",
        name: String = "Brandoland",
        port: String = "32400",
        contentType: String = "plex/media-server"
    ) -> Data {
        Data("""
            HTTP/1.0 200 OK\r
            Name: \(name)\r
            Port: \(port)\r
            Resource-Identifier: \(machine)\r
            Content-Type: \(contentType)\r
            Version: 1.43.3\r
            \r

            """.utf8)
    }

    // MARK: Reading a reply

    func testAServerAnnouncementIsRead() throws {
        let server = try XCTUnwrap(
            PlexGDMParser.parse(reply(), sourceIP: "192.168.68.71"))
        XCTAssertEqual(server.machineIdentifier, "c1f3d6597895238bb5c660ca489a5c2cd1ae623d")
        XCTAssertEqual(server.name, "Brandoland")
        XCTAssertEqual(server.port, 32400)
        XCTAssertEqual(server.host, "192.168.68.71",
                       "the address it answered from is the address that works")
    }

    func testAPlayerIsNotAServer() {
        // Plex players speak GDM too. Answering one as though it were a server
        // would pin the library to somebody's phone.
        XCTAssertNil(PlexGDMParser.parse(
            reply(contentType: "plex/media-player"), sourceIP: "192.168.68.9"))
    }

    func testAnIncompleteOrFailedAnnouncementIsIgnored() {
        XCTAssertNil(PlexGDMParser.parse(reply(machine: ""), sourceIP: "192.168.68.71"))
        XCTAssertNil(PlexGDMParser.parse(reply(port: "not-a-port"), sourceIP: "192.168.68.71"))
        XCTAssertNil(PlexGDMParser.parse(Data("garbage".utf8), sourceIP: "192.168.68.71"))
        XCTAssertNil(PlexGDMParser.parse(reply(), sourceIP: ""),
                     "without a source address there is nothing to connect to")
    }

    // MARK: Dressing it in the right certificate

    func testTheDiscoveredAddressBorrowsTheAdvertisedCertificate() {
        // Plex issues every server a wildcard cert for *.<hash>.plex.direct, and
        // plex.direct resolves 1-2-3-4.<hash> to 1.2.3.4. So a discovered
        // address can wear the same certificate the advertised ones wear and
        // stay HTTPS with a name that genuinely validates.
        let advertised = [
            URL(string: "https://172-18-0-1.50acfe994de74f8998deb9fc43e6262e.plex.direct:32400")!,
        ]
        let url = PlexGDMParser.localURL(
            host: "192.168.68.71", port: 32400, borrowingCertificateFrom: advertised)
        XCTAssertEqual(
            url?.absoluteString,
            "https://192-168-68-71.50acfe994de74f8998deb9fc43e6262e.plex.direct:32400")
    }

    func testWithNoCertificateToBorrowItFallsBackToPlainHTTP() {
        // A real downgrade, and deliberately limited to the local network —
        // where the alternative is not reaching the server at all.
        let url = PlexGDMParser.localURL(
            host: "192.168.68.71", port: 32400,
            borrowingCertificateFrom: [URL(string: "https://plex.example.com:32400")!])
        XCTAssertEqual(url?.absoluteString, "http://192.168.68.71:32400")
    }

    func testANonIPv4HostIsNotDashed() {
        XCTAssertNil(PlexGDMParser.dashedHost("plex.example.com"))
        XCTAssertNil(PlexGDMParser.dashedHost("192.168.68"))
        XCTAssertEqual(PlexGDMParser.dashedHost("10.0.0.1"), "10-0-0-1")
    }

    // MARK: End to end

    /// The whole point, in one test.
    ///
    /// plex.tv advertises a Docker bridge address that nothing answers on, and
    /// a remote address that does. The network says the server is really at
    /// 192.168.68.71. That address has to win: it is local and it answers.
    func testALocallyDiscoveredAddressBeatsTheAdvertisedRemoteOne() async throws {
        let transport = PlexFixtureTransport([
            .init(contains: "api/v2/resources", fixture: "plex_resources_duplicate_machine"),
            // The container address answers on nothing; the remote one is slow;
            // the discovered LAN address is immediate.
            .init(contains: "96-126-104-168", fixture: "plex_identity", delay: 0.30),
            .init(contains: "192-168-68-71", fixture: "plex_identity"),
        ])
        let auth = PlexAuthenticator(
            clientInfo: clientInfo, clientIdentifier: "cid",
            transport: transport, probeTransport: transport,
            localDiscovery: StubDiscovery([
                PlexLocalServer(
                    machineIdentifier: "50acfe994de74f8998deb9fc43e6262e",
                    name: "Brandoland", host: "192.168.68.71", port: 32400),
            ]))

        let connections = try await auth.discoverConnections(accountToken: "acct")
        XCTAssertTrue(
            connections.contains { $0.uri.host?.hasPrefix("192-168-68-71") == true },
            "the discovered address joins the candidates")

        let session = try await auth.resolveConnection(
            accountToken: "acct",
            machineIdentifier: "50acfe994de74f8998deb9fc43e6262e")
        XCTAssertEqual(
            session.baseURL.host,
            "192-168-68-71.50acfe994de74f8998deb9fc43e6262e.plex.direct",
            "no server configuration required")
    }

    func testAServerNobodyAnswersForIsNotInvented() async throws {
        let transport = PlexFixtureTransport([
            .init(contains: "api/v2/resources", fixture: "plex_resources_duplicate_machine"),
            .init(contains: "192-168-68-71", fixture: "plex_identity"),
        ])
        // A different machine answered on the network — someone else's server,
        // or a second one of the user's. It must not be attached to this
        // account's resource.
        let auth = PlexAuthenticator(
            clientInfo: clientInfo, clientIdentifier: "cid",
            transport: transport, probeTransport: transport,
            localDiscovery: StubDiscovery([
                PlexLocalServer(machineIdentifier: "someone-elses-server",
                                name: "Not Yours", host: "192.168.68.99", port: 32400),
            ]))

        let connections = try await auth.discoverConnections(accountToken: "acct")
        XCTAssertFalse(connections.contains { $0.uri.host?.contains("192-168-68-99") == true })
    }

    func testDiscoveryFindingNothingCostsTheAdvertisedAddressesNothing() async throws {
        // Cellular, a network that blocks broadcast, or simply no server
        // nearby. The account's own addresses must still be there.
        let transport = PlexFixtureTransport([
            .init(contains: "api/v2/resources", fixture: "plex_resources_duplicate_machine"),
        ])
        let auth = PlexAuthenticator(
            clientInfo: clientInfo, clientIdentifier: "cid",
            transport: transport, probeTransport: transport,
            localDiscovery: StubDiscovery([]))

        let connections = try await auth.discoverConnections(accountToken: "acct")
        XCTAssertEqual(connections.count, 3)
    }
}

private struct StubDiscovery: PlexLocallyDiscovering {
    let servers: [PlexLocalServer]
    init(_ servers: [PlexLocalServer]) { self.servers = servers }
    func discover(timeout: TimeInterval) async -> [PlexLocalServer] { servers }
}

/// Telling a nearby address from a distant one.
///
/// The judgement behind "should this device move closer": a phone that fell
/// back to its server's public address should notice when the LAN one becomes
/// reachable again, and must not mistake one public address for another and
/// rewrite itself on every launch.
final class PlexAddressTests: XCTestCase {
    private func url(_ string: String) -> URL { URL(string: string)! }

    func testAPlexDirectNameSpellsItsAddress() {
        XCTAssertTrue(PlexAddress.isLocal(
            url("https://192-168-68-71.50acfe99.plex.direct:32400")))
        XCTAssertFalse(PlexAddress.isLocal(
            url("https://96-126-104-168.50acfe99.plex.direct:8443")),
            "a relay is not the local network")
    }

    func testEveryPrivateRangeCounts() {
        for host in ["10-0-0-1", "172-16-0-1", "172-31-255-1", "192-168-1-1", "169-254-0-1"] {
            XCTAssertTrue(PlexAddress.isLocal(url("https://\(host).h.plex.direct:32400")), host)
        }
        // 172.32 is outside the private block, and the boundary is exactly
        // where a hand-written check tends to be wrong.
        XCTAssertFalse(PlexAddress.isLocal(url("https://172-32-0-1.h.plex.direct:32400")))
        XCTAssertFalse(PlexAddress.isLocal(url("https://172-15-0-1.h.plex.direct:32400")))
    }

    func testAPlainAddressIsReadDirectly() {
        XCTAssertTrue(PlexAddress.isLocal(url("http://192.168.1.50:32400")))
        XCTAssertFalse(PlexAddress.isLocal(url("https://plex.example.com:32400")))
    }

    func testWhatCannotBeReadCountsAsRemote() {
        // At worst that costs a lookup which finds nothing better; the reverse
        // would pin someone to an address that is not actually near them.
        XCTAssertFalse(PlexAddress.isLocal(url("https://truenas.collie-matrix.ts.net")))
        XCTAssertFalse(PlexAddress.isLocal(url("https://999-1-1-1.h.plex.direct:32400")))
    }
}
