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
