import SwiftUI
import MozzCore
import MozzDatabase

/// The full album catalog as a paginated grid (Apple Music-style). Uses a
/// `LazyVGrid`, so only visible cells are realized — memory stays flat even at
/// 10k+ albums — and pages in more as the user nears the end.
struct AlbumsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var list: PagedList<AlbumRecord>

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    init() {
        _list = StateObject(wrappedValue: PagedList { _, _ in [] })
    }

    var body: some View {
        ScrollView {
            if !list.items.isEmpty {
                LibraryPlayShuffleBar(play: playAll, shuffle: shuffleAll)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(Array(list.items.enumerated()), id: \.element.id) { index, album in
                    NavigationLink(value: AppRoute.album(album)) {
                        AlbumCell(album: album)
                    }
                    .buttonStyle(.plain)
                    .onAppear { list.loadMoreIfNeeded(currentIndex: index) }
                }
            }
            .padding()
            if list.isLoading {
                ProgressView().padding()
            }
        }
        .minimizesBottomBarOnScroll()
        .navigationTitle("Albums")
        .overlay {
            if list.items.isEmpty && !list.isLoading {
                ContentUnavailableView("No Albums", systemImage: "square.stack")
            }
        }
        .task { await bootstrap() }
    }

    /// Play every album's tracks in album order (not just the loaded window).
    private func playAll() {
        Task {
            let all = (try? await env.repository.allAlbumTracksForPlayback(serverId: env.active?.connection.id)) ?? []
            guard !all.isEmpty else { return }
            env.playback.setShuffle(false)
            env.playback.play(tracks: all, startAt: 0)
        }
    }

    /// Shuffle every album's tracks with a balanced (artist-spread) order,
    /// biased away from recently-played tracks so it feels fresh each session.
    private func shuffleAll() {
        Task {
            let serverId = env.active?.connection.id
            let all = (try? await env.repository.allAlbumTracksForPlayback(serverId: serverId)) ?? []
            guard !all.isEmpty else { return }
            var recency: [String: Double]?
            if let serverId {
                recency = try? await env.recommendations.recencyScores(serverId: serverId)
            }
            env.playback.playShuffled(all, recencyScores: recency)
        }
    }

    private func bootstrap() async {
        let repo = env.repository
        let serverId = env.active?.connection.id
        await MainActor.run {
            list.rebind { offset, limit in
                try await repo.albumsPage(serverId: serverId, offset: offset, limit: limit)
            }
        }
        await list.loadInitial()
    }
}
