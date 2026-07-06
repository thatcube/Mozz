import SwiftUI
import MozzCore
import MozzDatabase

/// The Library tab root — an Apple Music-style menu of category rows (Songs,
/// Playlists, Artists, Albums, Genres, Downloaded) with a "Recently Added" shelf
/// at the bottom.
///
/// Uses the same tight custom header (title + trailing avatar, via `TightHeader`)
/// as Home and Search so the title sits right under the status bar and in the
/// identical spot on every tab, over a plain `ScrollView`. The navigation bar is
/// hidden (`hideNavigationBar`) so only the custom header shows.
/// (not an inset-grouped `List`) so nothing offsets the content.
///
/// This view owns the tab's single `NavigationStack`; every screen it pushes
/// (SongsView, AlbumsView, DownloadsView, …) must NOT declare its own stack.
/// Nesting `NavigationStack`s builds a pathologically deep hosting/hit-test
/// hierarchy that turns routine layout passes into multi-second hangs, so the
/// one-stack-per-tab rule is load-bearing, not stylistic.
struct LibraryHomeView: View {
    @EnvironmentObject private var env: AppEnvironment
    /// This tab's navigation path (value-based routing), owned by MainTabsView.
    @Binding var path: [AppRoute]
    @State private var recentlyAdded: [AlbumRecord] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    TightHeader(title: "Library")

                    VStack(spacing: 0) {
                        categoryLink("Songs", "music.note", route: .songs)
                        rowDivider
                        categoryLink("Liked Songs", "heart", route: .likedSongs)
                        rowDivider
                        categoryLink("Playlists", "music.note.list", route: .playlists)
                        rowDivider
                        categoryLink("Artists", "music.mic", route: .artists)
                        rowDivider
                        categoryLink("Albums", "square.stack", route: .albums)
                        rowDivider
                        categoryLink("Genres", "guitars", route: .genres)
                        rowDivider
                        categoryLink("Downloaded", "arrow.down.circle", route: .downloads)
                    }

                    if !recentlyAdded.isEmpty {
                        AlbumShelf(title: "Recently Added", albums: recentlyAdded)
                    }
                }
                .padding(.bottom, 24)
            }
            .hideNavigationBar()
            .minimizesBottomBarOnScroll()
            .scrollsToTopOnSignal()
            .appRouteDestinations()
            .task { await loadRecent() }
        }
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 64)
    }

    private func categoryLink(_ title: String, _ systemImage: String, route: AppRoute) -> some View {
        NavigationLink(value: route) {
            LibraryCategoryRow(title: title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }

    private func loadRecent() async {
        guard let serverId = env.active?.connection.id else { return }
        recentlyAdded = (try? await env.repository.recentlyAddedAlbums(serverId: serverId, limit: 20)) ?? []
    }
}

/// A single category row: tinted SF Symbol + title + trailing chevron, matching
/// the Apple Music library menu.
struct LibraryCategoryRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            Text(title).font(.title3)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}
