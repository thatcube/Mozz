import Foundation
import SwiftUI

/// A parsed deep-link / Handoff destination. Both the `mozz://` URL scheme and
/// Handoff `NSUserActivity`s carry only identifiers (never the full record); the
/// concrete `AppRoute` payload is resolved from the local database when the link
/// is consumed (see `AppEnvironment.resolveDeepLink`).
///
/// This is the single shared foundation for deep links, widget tap targets, and
/// Handoff — each of them produces a `DeepLinkTarget`.
enum DeepLinkTarget: Equatable {
    case tab(AppTab)
    case album(id: String)
    case artist(id: String)
    case playlist(id: String)
    case genre(String)
    /// A payload-less library category page (Songs, Liked, Playlists, …).
    case category(AppRoute)

    // MARK: URL scheme

    /// Parse a `mozz://…` URL into a target, or `nil` if unrecognised.
    ///
    /// Forms:
    ///   `mozz://tab/{home|library|search}`
    ///   `mozz://album/<id>` · `mozz://artist/<id>` · `mozz://playlist/<id>`
    ///   `mozz://genre/<name>`
    ///   `mozz://{songs|liked|playlists|artists|albums|genres|downloads}`
    static func parse(_ url: URL) -> DeepLinkTarget? {
        guard url.scheme == "mozz", let host = url.host?.lowercased() else { return nil }
        // Path components without the leading "/".
        let parts = url.pathComponents.filter { $0 != "/" }
        let first = parts.first

        switch host {
        case "tab":
            switch first {
            case "home":    return .tab(.home)
            case "library": return .tab(.library)
            case "search":  return .tab(.search)
            default:        return nil
            }
        case "album":     return first.map { .album(id: $0) }
        case "artist":    return first.map { .artist(id: $0) }
        case "playlist":  return first.map { .playlist(id: $0) }
        case "genre":
            guard let name = first else { return nil }
            return .genre(name.removingPercentEncoding ?? name)
        case "songs":     return .category(.songs)
        case "liked":     return .category(.likedSongs)
        case "playlists": return .category(.playlists)
        case "artists":   return .category(.artists)
        case "albums":    return .category(.albums)
        case "genres":    return .category(.genres)
        case "downloads": return .category(.downloads)
        default:          return nil
        }
    }

    // MARK: Handoff

    /// The `NSUserActivity` type advertised for this target (Handoff). Only the
    /// record-backed screens participate; must match `NSUserActivityTypes` in
    /// Info.plist.
    static let albumActivity = "com.thatcube.mozz.album"
    static let artistActivity = "com.thatcube.mozz.artist"
    static let playlistActivity = "com.thatcube.mozz.playlist"
    static let genreActivity = "com.thatcube.mozz.genre"
    static let libraryActivity = "com.thatcube.mozz.library"

    static let allActivityTypes = [
        albumActivity, artistActivity, playlistActivity, genreActivity, libraryActivity,
    ]

    /// Rebuild a target from a continued `NSUserActivity`.
    static func from(activityType: String, userInfo: [AnyHashable: Any]?) -> DeepLinkTarget? {
        let id = userInfo?["id"] as? String
        switch activityType {
        case albumActivity:    return id.map { .album(id: $0) }
        case artistActivity:   return id.map { .artist(id: $0) }
        case playlistActivity: return id.map { .playlist(id: $0) }
        case genreActivity:    return id.map { .genre($0) }
        case libraryActivity:  return .tab(.library)
        default:               return nil
        }
    }
}

extension View {
    /// Advertise this screen as the user's current activity so it can be
    /// continued on another device via Handoff. The activity carries only the
    /// record id (the receiving device looks it up in its own catalog).
    func handoff(_ activityType: String, id: String?, title: String) -> some View {
        userActivity(activityType, isActive: true) { activity in
            activity.title = title
            activity.isEligibleForHandoff = true
            if let id { activity.userInfo = ["id": id] }
        }
    }
}
