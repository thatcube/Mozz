import SwiftUI
import MozzCore
import MozzDatabase

/// The full song catalog, alphabetical and paginated (a window of rows is ever
/// in memory, so it scrolls smoothly at 100k+). Tapping a song queues the
/// currently-loaded songs from that point and starts playback.
struct SongsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var list: PagedList<TrackRecord>

    init() {
        _list = StateObject(wrappedValue: PagedList { _, _ in [] })
    }

    var body: some View {
        List {
            if !list.items.isEmpty {
                LibraryPlayShuffleBar(play: playAll, shuffle: shuffleAll)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
            }
            ForEach(Array(list.items.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track, showArtist: true)
                    .contentShape(Rectangle())
                    .onTapGesture { play(from: index) }
                    .onAppear { list.loadMoreIfNeeded(currentIndex: index) }
            }
            if list.isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .listStyle(.plain)
        .minimizesBottomBarOnScroll()
        .navigationTitle("Songs")
        .overlay {
            if list.items.isEmpty && !list.isLoading {
                ContentUnavailableView("No Songs", systemImage: "music.note")
            }
        }
        .task { await bootstrap() }
    }

    private func play(from index: Int) {
        env.playback.play(tracks: list.items.map { $0.toDomain() }, startAt: index)
    }

    /// Play the whole song catalog in order (not just the loaded window). The
    /// full, ordered set is fetched + mapped off the main thread.
    private func playAll() {
        Task {
            let all = (try? await env.repository.allTracksForPlayback(serverId: env.active?.connection.id)) ?? []
            guard !all.isEmpty else { return }
            env.playback.setShuffle(false)
            env.playback.play(tracks: all, startAt: 0)
        }
    }

    /// Shuffle the whole song catalog with a balanced (artist-spread) order.
    private func shuffleAll() {
        Task {
            let all = (try? await env.repository.allTracksForPlayback(serverId: env.active?.connection.id)) ?? []
            guard !all.isEmpty else { return }
            env.playback.playShuffled(all)
        }
    }

    private func bootstrap() async {
        let repo = env.repository
        let serverId = env.active?.connection.id
        await MainActor.run {
            list.rebind { offset, limit in
                try await repo.tracksPage(serverId: serverId, offset: offset, limit: limit)
            }
        }
        await list.loadInitial()
    }
}
