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
    @State private var recentlyAdded: [AlbumRecord] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    TightHeader(title: "Library")

                    VStack(spacing: 0) {
                        categoryLink("Songs", "music.note") { SongsView() }
                        rowDivider
                        categoryLink("Liked Songs", "heart") { LikedSongsView() }
                        rowDivider
                        categoryLink("Playlists", "music.note.list") { PlaylistsView() }
                        rowDivider
                        categoryLink("Artists", "music.mic") { ArtistsView() }
                        rowDivider
                        categoryLink("Albums", "square.stack") { AlbumsView() }
                        rowDivider
                        categoryLink("Genres", "guitars") { GenresView() }
                        rowDivider
                        categoryLink("Downloaded", "arrow.down.circle") { DownloadsView() }
                    }

                    if !recentlyAdded.isEmpty {
                        AlbumShelf(title: "Recently Added", albums: recentlyAdded)
                    }
                }
                .padding(.bottom, 24)
            }
            .hideNavigationBar()
            .minimizesBottomBarOnScroll()
            .task { await loadRecent() }
        }
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 64)
    }

    private func categoryLink<Destination: View>(
        _ title: String, _ systemImage: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink { destination() } label: {
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
