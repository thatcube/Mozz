import Foundation

/// A Jellyfin server found on the local network, with the base URLs worth
/// trying in priority order (most-likely-reachable first). `baseURL` is the
/// best bet; the login UI uses it to prefill the server field.
public struct DiscoveredServer: Sendable, Identifiable, Equatable, Hashable {
    /// The server's Jellyfin id when it advertised one, else the primary URL.
    public let id: String
    public let name: String
    /// Candidate base URLs, reachable-first. `baseURL` == `candidateURLs.first`.
    public let candidateURLs: [URL]

    public init(id: String, name: String, candidateURLs: [URL]) {
        self.id = id
        self.name = name
        self.candidateURLs = candidateURLs
    }

    public var baseURL: URL { candidateURLs.first! }
}

/// Turns messy user- or discovery-supplied host strings into a canonical base
/// `URL`. Ported from Plozz's `ServerURLNormalizer`.
///
/// Rules:
///  * adds a scheme (`http://`) when none is present;
///  * defaults to Jellyfin's port `8096` for a scheme-less bare `http` host;
///  * strips a trailing slash;
///  * returns `nil` for input that can't form a valid host.
///
/// Examples:
///  * `192.168.1.5`       → `http://192.168.1.5:8096`
///  * `jelly.example.com` → `http://jelly.example.com:8096`
///  * `https://m.tld/jf/` → `https://m.tld/jf`
public enum JellyfinURLNormalizer {
    public static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let hadScheme = trimmed.contains("://")
        let withScheme = hadScheme ? trimmed : "http://\(trimmed)"

        guard var components = URLComponents(string: withScheme),
              let host = components.host, !host.isEmpty else {
            return nil
        }

        // Apply the Jellyfin default port only when the user typed a bare host
        // over plain http with no explicit port.
        if !hadScheme, components.port == nil, components.scheme == "http" {
            components.port = 8096
        }

        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.url
    }
}

/// The JSON a Jellyfin server broadcasts in reply to the UDP discovery probe
/// `"Who is JellyfinServer?"` on port 7359.
private struct JellyfinDiscoveryResponse: Decodable {
    let Address: String?
    let Id: String?
    let Name: String?
    let EndpointAddress: String?
}

/// Pure parsing of Jellyfin UDP discovery datagrams → `DiscoveredServer`.
///
/// Kept free of any networking so it can be unit-tested directly against raw
/// bytes captured from a real server. Ported from Plozz's
/// `JellyfinDiscoveryParser`.
public enum JellyfinDiscoveryParser {
    /// The probe message we send. Jellyfin servers listen for this exact string
    /// on UDP port 7359 and reply to the sender.
    public static let probeMessage = "Who is JellyfinServer?"
    public static let discoveryPort: UInt16 = 7359

    /// Decodes a single UDP response payload into an announcement, or `nil` if
    /// it isn't a usable Jellyfin reply.
    ///
    /// - Parameters:
    ///   - data: the raw datagram bytes.
    ///   - sourceIP: the address the datagram actually arrived from. Preferred
    ///     over the payload's `Address`/`EndpointAddress` because it is known to
    ///     be reachable on this LAN (multi-NIC hosts and a misconfigured
    ///     "Published server URL" routinely advertise a foreign-subnet address).
    public static func parse(_ data: Data, sourceIP: String? = nil) -> DiscoveredServer? {
        guard let response = try? JSONDecoder().decode(JellyfinDiscoveryResponse.self, from: data),
              response.Id != nil || response.Name != nil || response.Address != nil else {
            return nil
        }

        var candidates: [URL] = []
        func add(_ url: URL?) {
            guard let url, !candidates.contains(url) else { return }
            candidates.append(url)
        }
        func add(_ raw: String?) {
            guard let raw, !raw.isEmpty else { return }
            add(JellyfinURLNormalizer.normalize(raw))
        }

        // The server's own advertised endpoint, normalized. It may be on a
        // foreign subnet/host, but it carries the scheme, port and path the
        // server actually serves on (https, reverse-proxy path, non-default
        // port, …) — information the bare source IP lacks.
        let advertised = JellyfinURLNormalizer.normalize(response.EndpointAddress ?? "")
            ?? JellyfinURLNormalizer.normalize(response.Address ?? "")

        if let sourceIP, !sourceIP.isEmpty {
            // 1. Best bet: the reachable host, but using the scheme/port/path the
            //    server advertised.
            if let advertised { add(hostSwapped(advertised, host: sourceIP)) }
            // 2. The reachable host on Jellyfin's default http port.
            add(sourceIP)
        }
        // 3/4. The server's own addresses, exactly as advertised (last resort —
        //      only works when the published address is correct for this LAN).
        add(response.EndpointAddress)
        add(response.Address)

        guard let primary = candidates.first else { return nil }

        let id = response.Id ?? primary.absoluteString
        let name = response.Name ?? sourceIP ?? primary.host ?? "Jellyfin Server"
        return DiscoveredServer(id: id, name: name, candidateURLs: candidates)
    }

    /// Returns `template` with its host replaced by `host`, preserving scheme,
    /// port and path — aims the server's advertised endpoint at a reachable IP.
    private static func hostSwapped(_ template: URL, host: String) -> URL? {
        guard var components = URLComponents(url: template, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.host = host
        return components.url
    }
}
