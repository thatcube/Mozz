import Foundation

/// Minimal dotted-numeric version comparison, used by capability detection to
/// gate features on a server's reported version (e.g. Jellyfin synced lyrics
/// need 10.8+). Non-numeric components are ignored; missing components compare
/// as zero, so `"10.8" >= "10.8.0"` holds.
public enum SemanticVersion {
    public static func isAtLeast(_ version: String?, _ minimum: String) -> Bool {
        guard let version else { return false }
        let lhs = components(version)
        let rhs = components(minimum)
        for index in 0..<Swift.max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return true
    }

    private static func components(_ version: String) -> [Int] {
        version.split(whereSeparator: { $0 == "." || $0 == "-" }).compactMap { Int($0) }
    }
}
