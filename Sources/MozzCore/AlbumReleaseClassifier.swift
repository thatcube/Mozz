import Foundation

public enum AlbumReleaseKind: String, Codable, Sendable, Hashable {
    case single
    case ep
    case album

    public var isSingleOrEP: Bool { self != .album }
}

public enum AlbumReleaseClassifier {
    /// The common digital-store boundary is three tracks or less for a single,
    /// with 30 minutes as the guardrail that keeps long-form two/three-track
    /// releases from being mislabeled. EPs cover short releases up to six tracks;
    /// anything larger is treated as an album so clients agree on shelf splits.
    public static func kind(
        trackCount: Int?,
        totalDurationSeconds: TimeInterval?
    ) -> AlbumReleaseKind {
        guard let trackCount, trackCount > 0 else { return .album }
        let duration = totalDurationSeconds ?? 0
        let isLongForm = duration > 30 * 60

        if trackCount <= 3 {
            return isLongForm ? .album : .single
        }
        if trackCount <= 6 {
            return isLongForm ? .album : .ep
        }
        return .album
    }
}
