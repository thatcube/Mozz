import Foundation

/// A release, reduced to just what deciding "which of these is the latest" needs.
/// Deliberately not an `AlbumRecord`: this lives in `MozzCore` so the rule is
/// reachable from every layer, including the C ABI facade, without dragging the
/// database's row types along with it.
public struct ReleaseRecency: Sendable, Equatable {
    public let year: Int?
    /// When this library first saw the release, not when it was published.
    public let addedAt: Double?
    public let title: String

    public init(year: Int?, addedAt: Double?, title: String) {
        self.year = year
        self.addedAt = addedAt
        self.title = title
    }
}

/// Picks the release to show as an artist's "Latest Release".
///
/// The rule has to live in one place. The phone and the desktop both draw this
/// section, and an artist whose newest record differs between the two apps would
/// be a bug nobody could explain — so the ordering is defined here and both
/// clients read it rather than each sorting for themselves.
public enum LatestRelease {
    /// Newest first: by release year, then by when the library first saw it, then
    /// by title.
    ///
    /// The tie-breakers matter more than they look. Self-hosted servers are
    /// erratic about metadata: a whole discography can arrive with no year at
    /// all, and then year alone leaves the order down to however the rows
    /// happened to come back. Falling through to `addedAt` and finally to the
    /// title means the answer is at least stable and identical on every client,
    /// which is the property being defended here.
    ///
    /// A release with no year sorts below every release that has one. Absent a
    /// year we do not know that it is new, and quietly promoting an undated
    /// record to "Latest Release" would be a confident lie.
    public static func isNewer(_ a: ReleaseRecency, than b: ReleaseRecency) -> Bool {
        if a.year != b.year {
            switch (a.year, b.year) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): break
            }
        }
        if a.addedAt != b.addedAt {
            switch (a.addedAt, b.addedAt) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): break
            }
        }
        return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }

    /// The index of the newest release, or `nil` when there are none.
    public static func newestIndex(_ releases: [ReleaseRecency]) -> Int? {
        guard !releases.isEmpty else { return nil }
        var best = 0
        for i in 1..<releases.count where isNewer(releases[i], than: releases[best]) {
            best = i
        }
        return best
    }
}
