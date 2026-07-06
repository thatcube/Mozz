import SwiftUI
import MozzCore
import MozzDatabase

/// The distinct genres in the library. Tapping one shows its albums.
struct GenresView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var genres: [String] = []
    @State private var loaded = false

    var body: some View {
        List {
            ForEach(genres, id: \.self) { genre in
                NavigationLink(value: AppRoute.genre(genre)) {
                    Text(genre)
                }
            }
        }
        .listStyle(.plain)
        .minimizesBottomBarOnScroll()
        .navigationTitle("Genres")
        .overlay {
            if genres.isEmpty && loaded {
                ContentUnavailableView("No Genres", systemImage: "guitars")
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let serverId = env.active?.connection.id else { loaded = true; return }
        genres = (try? await env.repository.genres(serverId: serverId)) ?? []
        loaded = true
    }
}

/// Albums tagged with a given genre, as a grid.
struct GenreDetailView: View {
    @EnvironmentObject private var env: AppEnvironment
    let genre: String

    @State private var albums: [AlbumRecord] = []
    @State private var loaded = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(albums) { album in
                    NavigationLink(value: AppRoute.album(album)) {
                        AlbumCell(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(genre)
        .inlineNavigationTitle()
        .minimizesBottomBarOnScroll()
        .overlay {
            if albums.isEmpty && loaded {
                ContentUnavailableView("No Albums", systemImage: "square.stack")
            }
        }
        .task { await load() }
        .handoff(DeepLinkTarget.genreActivity, id: genre, title: genre)
    }

    private func load() async {
        guard let serverId = env.active?.connection.id else { loaded = true; return }
        albums = (try? await env.repository.albums(forGenre: genre, serverId: serverId)) ?? []
        loaded = true
    }
}
