import SwiftUI
import MozzCore
import MozzDatabase

/// The library root: a paginated, alphabetized list of artists read straight
/// from the local DB. Uses ``PagedList`` so only a window of rows is ever in
/// memory — the list scrolls smoothly even against a 100k-track catalog.
struct ArtistsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var list: PagedList<ArtistRecord>
    @State private var totalCount: Int?

    init() {
        // Placeholder; real fetch is injected in `.task` once env is available.
        _list = StateObject(wrappedValue: PagedList { _, _ in [] })
    }

    var body: some View {
        List {
            ForEach(Array(list.items.enumerated()), id: \.element.id) { index, artist in
                NavigationLink {
                    ArtistDetailView(artist: artist)
                } label: {
                    ArtistRow(artist: artist)
                }
                .onAppear { list.loadMoreIfNeeded(currentIndex: index) }
            }
            if list.isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .listStyle(.plain)
        .minimizesBottomBarOnScroll()
        .navigationTitle(navTitle)
        .overlay {
            if list.items.isEmpty && !list.isLoading {
                ContentUnavailableView("No Music", systemImage: "music.note",
                    description: Text("Sync your library from Settings."))
            }
        }
        .task { await bootstrap() }
    }

    private var navTitle: String {
        if let totalCount { return "\(totalCount) Artists" }
        return "Artists"
    }

    private func bootstrap() async {
        let repo = env.repository
        let serverId = env.active?.connection.id
        // Rebind the paged fetch to the live repository/server.
        await MainActor.run {
            list.rebind { offset, limit in
                try await repo.artistsPage(serverId: serverId, offset: offset, limit: limit)
            }
        }
        await list.loadInitial()
        totalCount = try? await repo.artistCount(serverId: serverId)
    }
}

private struct ArtistRow: View {
    let artist: ArtistRecord
    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(artwork: artist.artworkKey.map(ArtworkRef.init(key:)), seed: artist.name, size: 44, cornerRadius: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name).font(.body)
                if let count = artist.albumCount {
                    Text(count == 1 ? "1 album" : "\(count) albums")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
