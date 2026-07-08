import Foundation

/// Works around the iOS "local network access" permission race.
///
/// The first time the app touches a device on the local network, iOS shows a
/// one-time *"… would like to find and connect to devices on your local
/// network"* prompt — and the connection attempt that triggered it **fails
/// immediately** (surfacing here as ``MozzError/serverUnreachable``) while the
/// prompt is still on screen. The user then taps *Allow* and a second attempt
/// succeeds. That's the confusing "it failed, I tried again and it worked"
/// experience.
///
/// This helper removes the second tap: for a **local** host, a reachability
/// failure is retried a few times with a short delay, so a just-granted
/// permission takes effect transparently. It is deliberately narrow — it only
/// retries the *local-network* case, so a genuinely wrong URL or a real auth
/// rejection still fails fast:
/// - Non-local hosts (a public server / a typo in a public domain) are never
///   retried — the prompt never appears for them.
/// - Only ``MozzError/isReachabilityFailure`` errors are retried; an
///   ``MozzError/unauthorized`` (bad credentials) or a decode error surfaces
///   immediately.
///
/// Shared by every "connect to a server" entry point — Subsonic and Jellyfin
/// sign-in, and silent reconnection on launch — so the fix lives in one place.
public enum LocalNetworkPermission {
    /// Whether `url`'s host is on the local network, i.e. the only case where
    /// the iOS local-network permission prompt appears. Covers loopback, the
    /// private/link-local IPv4 ranges, link-local & unique-local IPv6, common
    /// local hostname TLDs (`.local`, `.lan`, `.home`, `.internal`,
    /// `.home.arpa`), and single-label hostnames (e.g. `nas`).
    public static func isLocalHost(_ url: URL) -> Bool {
        guard let raw = url.host, !raw.isEmpty else { return false }
        let host = raw.lowercased()

        if host == "localhost" { return true }

        // IPv6 (may arrive bracketed as `[fe80::1]`).
        let v6 = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if v6.contains(":") {
            if v6 == "::1" { return true }                              // loopback
            // fe80::/10 link-local (fe80–febf) and fc00::/7 unique-local (fc/fd).
            if v6.hasPrefix("fe8") || v6.hasPrefix("fe9")
                || v6.hasPrefix("fea") || v6.hasPrefix("feb") { return true }
            if v6.hasPrefix("fc") || v6.hasPrefix("fd") { return true }
        }

        // IPv4 dotted quad → check the private / loopback / link-local ranges.
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
            .compactMap { Int($0) }
        if octets.count == 4, host.allSatisfy({ $0.isNumber || $0 == "." }),
           octets.allSatisfy({ (0...255).contains($0) }) {
            switch (octets[0], octets[1]) {
            case (10, _), (127, _), (192, 168), (169, 254):
                return true
            case (172, let b) where (16...31).contains(b):
                return true
            default:
                return false                                           // public IPv4
            }
        }

        // Hostname heuristics: local mDNS/LAN TLDs, or a single-label name.
        let localSuffixes = [".local", ".lan", ".home", ".internal", ".home.arpa"]
        if localSuffixes.contains(where: { host.hasSuffix($0) }) { return true }
        if !host.contains(".") { return true }

        return false
    }

    /// Run `operation`, transparently retrying the local-network-permission race.
    ///
    /// For a local `url`, a ``MozzError/isReachabilityFailure`` is retried up to
    /// `attempts` times, sleeping `delay` between tries so the user has time to
    /// tap *Allow*. `onWaiting` fires before each wait (so the UI can show
    /// "Waiting for local network permission…" instead of a scary error). Any
    /// other error — or a non-local host — is thrown straight through.
    public static func retrying<T: Sendable>(
        for url: URL,
        attempts: Int = 4,
        delay: Duration = .milliseconds(1200),
        onWaiting: (@Sendable () -> Void)? = nil,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        guard isLocalHost(url), attempts > 1 else {
            return try await operation()
        }
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch let error as MozzError where error.isReachabilityFailure && attempt < attempts {
                onWaiting?()
                try await Task.sleep(for: delay)
                attempt += 1
            }
        }
    }
}
