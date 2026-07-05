import SwiftUI
import MozzCore
import MozzDatabase

/// The Library tab root — an Apple Music-style menu of category rows (Songs,
/// Playlists, Artists, Albums, Genres) with a "Recently Added" shelf at the
/// bottom.
///
/// This view owns the tab's single `NavigationStack`; every category screen it
/// pushes (SongsView, AlbumsView, ArtistsView, …) must NOT declare its own
/// stack. Nesting `NavigationStack`s builds a pathologically deep
/// hosting/hit-test hierarchy that turns routine layout passes into multi-second
/// hangs, so the one-stack-per-tab rule is load-bearing, not stylistic.
struct LibraryHomeView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var recentlyAdded: [AlbumRecord] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { SongsView() } label: {
                        LibraryCategoryRow(title: "Songs", systemImage: "music.note")
                    }
                    NavigationLink { PlaylistsView() } label: {
                        LibraryCategoryRow(title: "Playlists", systemImage: "music.note.list")
                    }
                    NavigationLink { ArtistsView() } label: {
                        LibraryCategoryRow(title: "Artists", systemImage: "music.mic")
                    }
                    NavigationLink { AlbumsView() } label: {
                        LibraryCategoryRow(title: "Albums", systemImage: "square.stack")
                    }
                    NavigationLink { GenresView() } label: {
                        LibraryCategoryRow(title: "Genres", systemImage: "guitars")
                    }
                }

                if !recentlyAdded.isEmpty {
                    Section("Recently Added") {
                        recentlyAddedShelf
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .insetGroupedListStyle()
            .navigationTitle("Library")
            .task { await loadRecent() }
        }
    }

    private var recentlyAddedShelf: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(recentlyAdded) { album in
                    NavigationLink {
                        AlbumDetailView(album: album)
                    } label: {
                        AlbumCell(album: album)
                            .frame(width: 150)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func loadRecent() async {
        guard let serverId = env.active?.connection.id else { return }
        recentlyAdded = (try? await env.repository.recentlyAddedAlbums(serverId: serverId, limit: 20)) ?? []
    }
}

/// A single category row: tinted SF Symbol + title, matching the Apple Music
/// library menu. The chevron is supplied by the enclosing `NavigationLink`.
struct LibraryCategoryRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
                .font(.title3)
        }
        .padding(.vertical, 4)
    }
}
