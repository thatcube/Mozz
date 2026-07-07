import Foundation
import MozzCore
import MozzNetworking
#if canImport(Darwin)
import Darwin
import os
#endif

/// LAN auto-discovery of Jellyfin servers. Ported from Plozz's
/// `UDPServerDiscovery`, adapted to Mozz's `HTTPClient`/transports.
///
/// Jellyfin's native auto-discovery is a UDP request/response on port 7359: the
/// client sends `"Who is JellyfinServer?"` and each server replies with a small
/// JSON announcement. This uses BSD sockets rather than `Network.framework` for
/// two reasons:
///
///  1. **Receiving replies.** A `NWConnection` "to" the broadcast address is a
///     *connected* UDP flow, so datagrams arriving from a server's own unicast
///     address are filtered out and never delivered. A plain unconnected socket
///     with `recvfrom` accepts replies from any source.
///  2. **Avoiding the multicast entitlement.** Broadcasting on iOS 14+ requires
///     `com.apple.developer.networking.multicast`, which forces
///     TestFlight/App-Store-only distribution. Jellyfin servers answer
///     *unicast* probes too, so we sweep each host on the local subnet with
///     unicast packets — which only needs the Local Network permission — and
///     additionally try broadcast as best-effort (it no-ops without the
///     entitlement).
public protocol JellyfinDiscovering: Sendable {
    /// Streams unique reachable servers as they answer, stopping after `timeout`.
    func discover(timeout: TimeInterval) -> AsyncStream<DiscoveredServer>
}

#if canImport(Darwin)
public final class JellyfinServerDiscovery: JellyfinDiscovering, @unchecked Sendable {
    /// Largest subnet we will unicast-sweep host-by-host. `/22` (1024 hosts)
    /// comfortably covers home networks while avoiding a pathological sweep of a
    /// `/16`. Larger subnets fall back to the local `/24` + broadcast only.
    private let maxSweepHosts: UInt32
    /// Tight-timeout client factory for validating a candidate over HTTP so we
    /// surface the URL that actually answers `System/Info/Public`.
    private let makeProbeClient: @Sendable (URL) -> HTTPClient
    private static let log = Logger(subsystem: "com.thatcube.Mozz", category: "discovery")

    public init(
        maxSweepHosts: UInt32 = 1024,
        makeProbeClient: @escaping @Sendable (URL) -> HTTPClient = { url in
            HTTPClient(baseURL: url, transport: URLSessionTransport(role: .discovery), retryPolicy: .none)
        }
    ) {
        self.maxSweepHosts = maxSweepHosts
        self.makeProbeClient = makeProbeClient
    }

    public func discover(timeout: TimeInterval) -> AsyncStream<DiscoveredServer> {
        let maxSweepHosts = self.maxSweepHosts
        let makeProbeClient = self.makeProbeClient

        return AsyncStream { continuation in
            let cancelled = AtomicFlag()
            let task = Task {
                // Validate each announcement's candidates concurrently so a slow
                // (or wrong) candidate for one server never holds up another.
                await withTaskGroup(of: Void.self) { group in
                    let stream = Self.announcements(
                        timeout: timeout, maxSweepHosts: maxSweepHosts, cancelled: cancelled
                    )
                    for await announcement in stream {
                        if Task.isCancelled { break }
                        group.addTask {
                            if let server = await Self.resolve(announcement, makeProbeClient: makeProbeClient) {
                                continuation.yield(server)
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                cancelled.set()
                task.cancel()
            }
        }
    }

    // MARK: - Candidate resolution

    /// Probes an announcement's candidate URLs in priority order and returns one
    /// keyed on the first that a Jellyfin server actually answers on. If none
    /// answer in time (slow server, HTTP blocked, …) the best-effort first
    /// candidate is surfaced anyway — the server clearly exists, so the user
    /// shouldn't see "nothing".
    private static func resolve(
        _ announcement: DiscoveredServer,
        makeProbeClient: @Sendable (URL) -> HTTPClient
    ) async -> DiscoveredServer? {
        for url in announcement.candidateURLs {
            if Task.isCancelled { return nil }
            let client = makeProbeClient(url)
            guard let info = try? await client.send(
                Endpoint(path: "System/Info/Public"), as: JFSystemInfoPublic.self
            ), info.Id != nil || info.ServerName != nil else { continue }
            log.info("Validated \(info.ServerName ?? announcement.name, privacy: .public) at \(url.absoluteString, privacy: .public)")
            return DiscoveredServer(
                id: info.Id ?? announcement.id,
                name: info.ServerName ?? announcement.name,
                candidateURLs: [url]
            )
        }
        log.info("No candidate validated; surfacing best-effort \(announcement.name, privacy: .public)")
        return announcement
    }

    // MARK: - Announcement stream

    /// Bridges the blocking BSD-socket loop (run on a background queue) into an
    /// `AsyncStream` of parsed, de-duplicated announcements.
    private static func announcements(
        timeout: TimeInterval,
        maxSweepHosts: UInt32,
        cancelled: AtomicFlag
    ) -> AsyncStream<DiscoveredServer> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "com.thatcube.Mozz.discovery.socket")
            queue.async {
                Self.run(timeout: timeout, maxSweepHosts: maxSweepHosts, cancelled: cancelled) { announcement in
                    continuation.yield(announcement)
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Socket loop

    private static func run(
        timeout: TimeInterval,
        maxSweepHosts: UInt32,
        cancelled: AtomicFlag,
        yield: (DiscoveredServer) -> Void
    ) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            log.error("Discovery socket() failed (errno \(errno))")
            return
        }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Short receive timeout so the loop can re-probe and notice cancellation.
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Bind an ephemeral local port so replies have somewhere to land.
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_addr.s_addr = INADDR_ANY
        local.sin_port = 0
        _ = withUnsafePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        let targets = Self.probeTargets(maxSweepHosts: maxSweepHosts)
        let probe = Array(JellyfinDiscoveryParser.probeMessage.utf8)
        log.info("Discovery probing \(targets.count) target(s)")

        func sendProbes() {
            for target in targets {
                var dst = sockaddr_in()
                dst.sin_family = sa_family_t(AF_INET)
                dst.sin_port = JellyfinDiscoveryParser.discoveryPort.bigEndian
                dst.sin_addr.s_addr = target
                _ = probe.withUnsafeBytes { raw in
                    withUnsafePointer(to: &dst) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }

        var seen = Set<String>()
        let deadline = Date().addingTimeInterval(timeout)
        var lastProbe = Date()
        sendProbes()

        var buffer = [UInt8](repeating: 0, count: 8192)
        while Date() < deadline && !cancelled.isSet {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLen)
                }
            }

            if n > 0 {
                let data = Data(buffer[0..<n])
                let sourceIP = Self.ipString(from: from)
                if let announcement = JellyfinDiscoveryParser.parse(data, sourceIP: sourceIP),
                   seen.insert(announcement.id).inserted {
                    log.info("Announce \(announcement.name, privacy: .public) — \(announcement.candidateURLs.count) candidate(s)")
                    yield(announcement)
                }
            }

            // Re-probe roughly once a second to ride out dropped UDP packets.
            if Date().timeIntervalSince(lastProbe) > 1 {
                sendProbes()
                lastProbe = Date()
            }
        }
    }

    // MARK: - Targets

    /// Builds the set of destination addresses (network byte order) to probe:
    /// every host on each local IPv4 subnet (unicast sweep), each subnet's
    /// directed broadcast, and the limited broadcast `255.255.255.255`.
    private static func probeTargets(maxSweepHosts: UInt32) -> [in_addr_t] {
        var targets: [in_addr_t] = []
        var seen = Set<in_addr_t>()
        func append(_ addr: in_addr_t) {
            if seen.insert(addr).inserted { targets.append(addr) }
        }

        for iface in localIPv4Interfaces() {
            let host = UInt32(bigEndian: iface.address)
            let mask = UInt32(bigEndian: iface.netmask)
            guard mask != 0 else { continue }
            let network = host & mask
            let broadcast = network | ~mask
            let hostCount = broadcast - network  // excludes network + broadcast

            if hostCount > 1 && hostCount <= maxSweepHosts {
                var addr = network + 1
                while addr < broadcast {
                    append(in_addr_t(addr).bigEndian)
                    addr += 1
                }
            } else if hostCount > maxSweepHosts {
                // Subnet too large to sweep fully (e.g. a /16). Still unicast the
                // local /24 around our own address — the overwhelmingly common
                // real-world segment — so a nearby server is found without a
                // pathological full-range sweep.
                let net24 = host & 0xFFFF_FF00
                let bcast24 = net24 | 0x0000_00FF
                var addr = net24 + 1
                while addr < bcast24 {
                    append(in_addr_t(addr).bigEndian)
                    addr += 1
                }
            }
            append(in_addr_t(broadcast).bigEndian)
        }

        append(INADDR_BROADCAST)  // 255.255.255.255 (byte-order agnostic)
        return targets
    }

    private struct Interface { let address: in_addr_t; let netmask: in_addr_t }

    /// Active, broadcast-capable, non-loopback IPv4 LAN interfaces and their
    /// netmasks. Point-to-point links (VPN tunnels, cellular) are skipped: a
    /// unicast LAN sweep over them is meaningless and a broadcast undeliverable.
    private static func localIPv4Interfaces() -> [Interface] {
        var result: [Interface] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard let sa = cur.pointee.ifa_addr,
                  sa.pointee.sa_family == sa_family_t(AF_INET),
                  (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  (flags & IFF_POINTOPOINT) == 0,
                  (flags & IFF_BROADCAST) != 0,
                  let nm = cur.pointee.ifa_netmask else { continue }

            let address = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let netmask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            result.append(Interface(address: address, netmask: netmask))
        }
        return result
    }

    private static func ipString(from addr: sockaddr_in) -> String {
        var sin = addr.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &sin, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }
}

/// Minimal thread-safe flag for signalling cancellation into the socket loop.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
#endif
