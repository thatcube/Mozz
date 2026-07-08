import SwiftUI
import MozzDatabase

/// Every screen reachable by a push inside the three main tabs (Home, Library,
/// Search). Value-based navigation (`NavigationStack(path:)` + `NavigationLink(value:)`
/// + `navigationDestination(for:)`) instead of value-less `NavigationLink { Dest }`
/// so that:
///   • pop-to-root is a real, animated `path.removeAll()` (not an `.id()` rebuild
///     that snapped, reset scroll, dropped VoiceOver/keyboard focus, and re-ran `.task`);
///   • navigation is programmatic — future deep links, widgets, Handoff, and
///     `SceneStorage` state restoration can build/restore a path.
///
/// Payloads carry the record structs (Hashable). Detail views are unchanged — this
/// only changes how they are *pushed*; the pushed content (headers, full-bleed
/// artwork scaffold, etc.) is identical.
enum AppRoute: Hashable {
    case album(AlbumRecord)
    case artist(ArtistRecord)
    case artistAllSongs(ArtistRecord)
    case playlist(PlaylistRecord)
    case genre(String)
    case mix(setId: String, title: String, subtitle: String)
    // Library category pages (no payload).
    case songs
    case likedSongs
    case playlists
    case artists
    case albums
    case genres
    case downloads

    /// The destination view for this route. Registered once per tab stack via
    /// `appRouteDestinations()`; SwiftUI resolves every `NavigationLink(value:)` in
    /// the stack through here. `@EnvironmentObject`s flow in from the stack, so the
    /// views construct exactly as before.
    @ViewBuilder var destination: some View {
        switch self {
        case .album(let a):                 AlbumDetailView(album: a)
        case .artist(let a):                ArtistDetailView(artist: a)
        case .artistAllSongs(let a):        ArtistAllSongsView(artist: a)
        case .playlist(let p):              PlaylistDetailView(playlist: p)
        case .genre(let g):                 GenreDetailView(genre: g)
        case .mix(let id, let t, let s):    MixDetailView(setId: id, fallbackTitle: t, subtitle: s)
        case .songs:                        SongsView()
        case .likedSongs:                   LikedSongsView()
        case .playlists:                    PlaylistsView()
        case .artists:                      ArtistsView()
        case .albums:                       AlbumsView()
        case .genres:                       GenresView()
        case .downloads:                    DownloadsView()
        }
    }
}

extension View {
    /// Register the shared `AppRoute` destinations for the enclosing tab stack.
    /// Applied on the stack root (NOT inside a lazy container — WWDC22 10054: a
    /// `navigationDestination` inside `List`/`LazyVGrid` may not be loaded when the
    /// push happens), so it covers every value-based push anywhere in the stack.
    func appRouteDestinations() -> some View {
        navigationDestination(for: AppRoute.self) { $0.destination }
    }
}

/// Where a navigation command originated, which decides how it is applied.
enum NavOrigin: Hashable {
    /// Issued from inside a tab (a row "…"/context menu) — push onto the *current*
    /// tab's stack.
    case tab
    /// Issued from the Now Playing player, which lives OUTSIDE the tab stacks —
    /// push onto a canonical tab and collapse the player to reveal it.
    case player
}

/// A one-shot request to push an already-resolved `AppRoute`. Menus resolve the
/// track → record asynchronously, then hand a concrete route to `MainTabsView`
/// via `AppEnvironment.pendingNav` (mirrors the `pendingDeepLink` command bus so
/// both share the same latest-wins generation token).
struct NavCommand: Hashable {
    let route: AppRoute
    let origin: NavOrigin
}
