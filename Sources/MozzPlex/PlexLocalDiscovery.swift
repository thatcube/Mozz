import Foundation
import MozzCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
// Android is Bionic, not Glibc, and the sockets live in its own module. Left
// out, every BSD symbol below is simply missing and the Android build fails on
// `cannot find 'socket' in scope` — which is where this was found.
import Android
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A Plex server that answered on the local network.
public struct PlexLocalServer: Sendable, Equatable, Hashable {
    /// The server's own identifier, as it reports it — the same string
    /// `/identity` returns, and what ties this back to a plex.tv resource.
    public var machineIdentifier: String
    public var name: String
    /// The address the reply came FROM, which is the whole point: it is the
    /// server's real address on this network, which is exactly what plex.tv
    /// may not know.
    public var host: String
    public var port: Int

    public init(machineIdentifier: String, name: String, host: String, port: Int) {
        self.machineIdentifier = machineIdentifier
        self.name = name
        self.host = host
        self.port = port
    }
}

/// Plex's GDM ("G'Day Mate") local discovery, as a pure parser.
///
/// A client sends `M-SEARCH * HTTP/1.0` to UDP 32414 and every Plex server on
/// the network answers with an HTTP-shaped block naming itself. It exists
/// because plex.tv cannot always tell a client how to reach a server: a server
/// only advertises the addresses it believes it has, and one in a Docker
/// bridge network believes it is at its container address. The listener's own
/// network knows better, and this is how to ask it.
public enum PlexGDMParser {
    public static let discoveryPort: UInt16 = 32414
    public static let probeMessage = "M-SEARCH * HTTP/1.0\r\n\r\n"

    /// Parse one reply. Nil for anything that is not a Plex media server
    /// announcing itself completely — another GDM speaker, a truncated packet,
    /// or a player rather than a server.
    public static func parse(_ data: Data, sourceIP: String) -> PlexLocalServer? {
        guard !sourceIP.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        var sawStatus = false
        // `isNewline`, not a comparison against "\r" or "\n". Swift treats
        // CR-LF as ONE Character - it is a single grapheme cluster - so
        // comparing against either half matches nothing, and a reply that is
        // entirely CRLF-delimited stays one unsplit line whose only recognised
        // content is the status.
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("HTTP/") {
                sawStatus = line.contains("200")
                continue
            }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !value.isEmpty { fields[key] = value }
        }
        guard sawStatus else { return nil }
        // Plex players speak GDM too, on a different port and with a different
        // content type. Answering one as though it were a server would pin the
        // library to a phone.
        guard fields["content-type"] == "plex/media-server" else { return nil }
        guard let machine = fields["resource-identifier"], !machine.isEmpty,
              let portText = fields["port"], let port = Int(portText),
              (1...65535).contains(port) else { return nil }
        return PlexLocalServer(
            machineIdentifier: machine,
            name: fields["name"] ?? "Plex",
            host: sourceIP,
            port: port)
    }

    /// Build the URL to reach a discovered server, borrowing the TLS name from
    /// an address plex.tv already advertised for it.
    ///
    /// Plex issues every server a wildcard certificate for
    /// `*.<hash>.plex.direct`, and plex.direct resolves `1-2-3-4.<hash>` to
    /// 1.2.3.4. So the address discovered here can be dressed in the same
    /// certificate the advertised ones wear, and stays HTTPS with a name that
    /// genuinely validates — rather than falling back to plaintext or to a
    /// certificate the host does not match.
    ///
    /// Without a `plex.direct` address to learn the hash from there is nothing
    /// to validate against, and it falls back to plain HTTP. That is a real
    /// downgrade and deliberately limited to the local network, where the
    /// alternative is not reaching the server at all.
    public static func localURL(
        host: String, port: Int, borrowingCertificateFrom advertised: [URL]
    ) -> URL? {
        if let hash = certificateHash(in: advertised),
           let dashed = dashedHost(host) {
            return URL(string: "https://\(dashed).\(hash).plex.direct:\(port)")
        }
        return URL(string: "http://\(host):\(port)")
    }

    /// The `<hash>` from the first `*.<hash>.plex.direct` address in the list.
    static func certificateHash(in urls: [URL]) -> String? {
        for url in urls {
            guard let host = url.host?.lowercased(),
                  host.hasSuffix(".plex.direct") else { continue }
            let labels = host.split(separator: ".")
            // <address>.<hash>.plex.direct — the hash is the label before the
            // two that spell plex.direct.
            guard labels.count >= 4 else { continue }
            let hash = String(labels[labels.count - 3])
            if !hash.isEmpty { return hash }
        }
        return nil
    }

    /// `192.168.68.71` becomes `192-168-68-71`, which is the form plex.direct
    /// resolves back to the same address.
    static func dashedHost(_ host: String) -> String? {
        let parts = host.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return nil }
        return parts.joined(separator: "-")
    }
}

/// Asks the local network which Plex servers are on it.
public protocol PlexLocallyDiscovering: Sendable {
    func discover(timeout: TimeInterval) async -> [PlexLocalServer]
}

#if !os(Windows)
/// GDM over BSD sockets.
///
/// Deliberately not `Network.framework`, for the two reasons
/// `JellyfinServerDiscovery` documents at length and which apply identically
/// here: a `NWConnection` to a broadcast address is a *connected* flow and
/// filters out the unicast replies servers actually send, and broadcasting on
/// iOS needs the multicast entitlement, which would restrict how Mozz can be
/// distributed. Plex servers answer unicast probes, so the subnet is swept
/// host by host — which needs only the Local Network permission — with
/// broadcast attempted alongside as best effort.
///
/// Sockets rather than Network.framework also means this is one implementation
/// for the phone, the tablet and the desktop instead of an Apple one and a
/// gap everywhere else.
public struct PlexLocalDiscovery: PlexLocallyDiscovering {
    /// Largest subnet to sweep host by host. A `/22` covers any home network;
    /// beyond that, sweeping every address is a worse citizen than being
    /// slightly less thorough, so it falls back to the local `/24`.
    private let maximumSweepHosts: UInt32

    public init(maximumSweepHosts: UInt32 = 1024) {
        self.maximumSweepHosts = maximumSweepHosts
    }

    public func discover(timeout: TimeInterval = 2) async -> [PlexLocalServer] {
        let maximumSweepHosts = self.maximumSweepHosts
        // The socket loop blocks. Off the cooperative pool, so two seconds of
        // waiting for UDP cannot stall unrelated work.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.run(
                    timeout: timeout, maximumSweepHosts: maximumSweepHosts))
            }
        }
    }

    private static func run(
        timeout: TimeInterval, maximumSweepHosts: UInt32
    ) -> [PlexLocalServer] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        // A short receive timeout rather than one long one, so the loop wakes
        // often enough to re-probe and to notice its own deadline.
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_addr.s_addr = Self.anyAddress
        local.sin_port = 0
        _ = withUnsafePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        let targets = probeTargets(maximumSweepHosts: maximumSweepHosts)
        guard !targets.isEmpty else { return [] }
        let probe = Array(PlexGDMParser.probeMessage.utf8)

        func sendProbes(before deadline: Date) {
            for target in targets {
                // The deadline governs sending as well as waiting. A sweep is
                // thousands of datagrams and a slow interface can make each one
                // cost; without this, one round of probing could outlast the
                // whole discovery budget and the caller would wait on it.
                if Date() >= deadline { return }
                var destination = sockaddr_in()
                destination.sin_family = sa_family_t(AF_INET)
                destination.sin_port = PlexGDMParser.discoveryPort.bigEndian
                destination.sin_addr.s_addr = target
                _ = probe.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    return withUnsafePointer(to: &destination) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, base, raw.count, 0, $0,
                                   socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }

        var found: [String: PlexLocalServer] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        var lastProbe = Date()
        sendProbes(before: deadline)

        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLength)
                }
            }
            if count > 0,
               let server = PlexGDMParser.parse(
                Data(buffer[0..<count]), sourceIP: ipString(from: from)) {
                // First answer per server wins: a second reply is the same
                // machine on the same address, since UDP is happy to deliver
                // a probe twice.
                if found[server.machineIdentifier] == nil {
                    found[server.machineIdentifier] = server
                }
            }
            // UDP drops packets, and a sweep of a thousand hosts drops more
            // than a few. Re-probing about once a second is what makes this
            // reliable rather than usually-reliable.
            if Date().timeIntervalSince(lastProbe) > 1 {
                sendProbes(before: deadline)
                lastProbe = Date()
            }
        }
        return Array(found.values)
    }

    /// Every host on each local IPv4 subnet, each subnet's directed broadcast,
    /// and the limited broadcast. Adapted from `JellyfinServerDiscovery`, which
    /// solved the same problem for the same reasons.
    private static func probeTargets(maximumSweepHosts: UInt32) -> [in_addr_t] {
        var targets: [in_addr_t] = []
        var seen = Set<in_addr_t>()
        func append(_ address: in_addr_t) {
            if seen.insert(address).inserted { targets.append(address) }
        }

        for interface in localIPv4Interfaces() {
            let host = UInt32(bigEndian: interface.address)
            let mask = UInt32(bigEndian: interface.netmask)
            guard mask != 0 else { continue }
            let network = host & mask
            let broadcast = network | ~mask
            let hostCount = broadcast - network

            if hostCount > 1 && hostCount <= maximumSweepHosts {
                var address = network + 1
                while address < broadcast {
                    append(in_addr_t(address).bigEndian)
                    address += 1
                }
            } else if hostCount > maximumSweepHosts {
                let network24 = host & 0xFFFF_FF00
                let broadcast24 = network24 | 0x0000_00FF
                var address = network24 + 1
                while address < broadcast24 {
                    append(in_addr_t(address).bigEndian)
                    address += 1
                }
            }
            append(in_addr_t(broadcast).bigEndian)
        }
        append(Self.broadcastAddress)
        // A hard ceiling on the whole sweep, not just per interface. A machine
        // with several networks - a laptop with Docker bridges, a VM host -
        // multiplies the per-interface cap by however many it has, and the
        // point of a bound is that it holds however odd the host turns out to
        // be. The broadcast addresses are added first so they survive the trim.
        let ceiling = 4096
        guard targets.count > ceiling else { return targets }
        return Array(targets.suffix(ceiling))
    }

    /// Spelled out rather than taken from the platform. `INADDR_ANY` and
    /// `INADDR_BROADCAST` are C macros, and Bionic does not re-export them to
    /// Swift the way Darwin does — so on Android the names simply do not exist.
    /// The values are fixed by the internet protocol, not by the libc.
    private static let anyAddress: in_addr_t = 0
    private static let broadcastAddress: in_addr_t = 0xFFFF_FFFF

    /// Interface flags, likewise spelled out. Darwin exposes these as `Int32`
    /// and Bionic as a `net_device_flags` enum, so naming them directly is what
    /// lets one implementation serve the phone, the tablet and the desktop.
    /// The values are the same everywhere BSD sockets are.
    private static let flagUp: Int32 = 0x1
    private static let flagBroadcast: Int32 = 0x2
    private static let flagLoopback: Int32 = 0x8
    private static let flagPointToPoint: Int32 = 0x10

    private struct Interface { let address: in_addr_t; let netmask: in_addr_t }

    /// Up, non-loopback, broadcast-capable IPv4 interfaces. Point-to-point
    /// links are skipped: a LAN sweep down a VPN tunnel or a cellular link is
    /// meaningless and the broadcast undeliverable.
    private static func localIPv4Interfaces() -> [Interface] {
        var result: [Interface] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard let sa = current.pointee.ifa_addr,
                  sa.pointee.sa_family == sa_family_t(AF_INET),
                  (flags & Self.flagUp) != 0,
                  (flags & Self.flagLoopback) == 0,
                  (flags & Self.flagPointToPoint) == 0,
                  (flags & Self.flagBroadcast) != 0,
                  let netmask = current.pointee.ifa_netmask else { continue }
            let address = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr
            }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr
            }
            result.append(Interface(address: address, netmask: mask))
        }
        return result
    }

    private static func ipString(from address: sockaddr_in) -> String {
        var sin = address.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &sin, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }
}
#else
/// Winsock is a different API from BSD sockets, and the desktop reaches its
/// server through plex.tv's addresses today. Discovery returning nothing is
/// exactly the behaviour Windows already has.
public struct PlexLocalDiscovery: PlexLocallyDiscovering {
    public init(maximumSweepHosts: UInt32 = 1024) {}
    public func discover(timeout: TimeInterval = 2) async -> [PlexLocalServer] { [] }
}
#endif
