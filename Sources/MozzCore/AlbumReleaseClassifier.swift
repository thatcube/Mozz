import Foundation

public enum AlbumReleaseKind: String, Codable, Sendable, Hashable {
    case singleOrEP
    case album

    public var isSingleOrEP: Bool { self != .album }
}

public enum AlbumReleaseClassifier {
    /// Mozz has historically grouped releases with three tracks or fewer under
    /// "Singles & EPs"; larger releases are "Albums". Unknown counts deliberately
    /// default to 99 so incomplete server metadata stays in Albums rather than
    /// hiding a full record among singles.
    public static func isSingleOrEP(trackCount: Int?) -> Bool {
        (trackCount ?? 99) <= 3
    }

    public static func kind(trackCount: Int?) -> AlbumReleaseKind {
        isSingleOrEP(trackCount: trackCount) ? .singleOrEP : .album
    }
}
