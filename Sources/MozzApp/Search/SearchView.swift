import SwiftUI
import MozzCore
import MozzDatabase

/// Full-text search over the local FTS5 index. Queries run against the DB with a
/// short debounce; results are grouped into artists / albums / tracks. Because
/// search hits SQLite directly, it stays well under the sub-100ms bar even at
/// 100k tracks.
///
/// Uses the same scroll-away `ScreenHeader` as Home and Library so the title
/// lands in the identical spot with the avatar aligned to it, and a custom
/// search field *below* the title (Apple Music style) rather than the nav-bar
/// `.searchable`, which would push the title into a different position and force
/// the avatar into the compact bar. The title + field stay pinned above the
/// results (a persistent field is the norm on a search screen).
struct SearchView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var query = ""
    @State private var results = SearchResults(artists: [], albums: [], tracks: [])
    @State private var searchTask: Task<Void, Never>?
    @State private var lastLatencyMs: Double?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScreenHeader(title: "Search")
                searchField
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                resultsList
            }
            .hideNavigationBar()
            .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Artists, albums, songs", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .plainTextFieldStyle()
            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.gray.opacity(0.15), in: Capsule())
    }

    private var resultsList: some View {
        List {
            if !results.artists.isEmpty {
                Section("Artists") {
                    ForEach(results.artists) { artist in
                        NavigationLink { ArtistDetailView(artist: artist) } label: {
                            Label(artist.name, systemImage: "music.mic")
                        }
                    }
                }
            }
            if !results.albums.isEmpty {
                Section("Albums") {
                    ForEach(results.albums) { album in
                        NavigationLink { AlbumDetailView(album: album) } label: {
                            VStack(alignment: .leading) {
                                Text(album.title)
                                Text(album.artistName).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !results.tracks.isEmpty {
                Section("Tracks") {
                    ForEach(results.tracks) { track in
                        TrackRow(track: track, showArtist: true)
                            .contentShape(Rectangle())
                            .onTapGesture { env.playback.play(tracks: [track.toDomain()]) }
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if query.isEmpty {
                ContentUnavailableView("Search Your Library", systemImage: "magnifyingglass")
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let ms = lastLatencyMs {
                Text(String(format: "found in %.1f ms", ms))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.bottom, 4)
            }
        }
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = SearchResults(artists: [], albums: [], tracks: [])
            lastLatencyMs = nil
            return
        }
        let repo = env.repository
        let serverId = env.active?.connection.id
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let start = Date()
            let found = (try? await repo.search(trimmed, serverId: serverId)) ??
                SearchResults(artists: [], albums: [], tracks: [])
            guard !Task.isCancelled else { return }
            results = found
            lastLatencyMs = Date().timeIntervalSince(start) * 1000
        }
    }
}
