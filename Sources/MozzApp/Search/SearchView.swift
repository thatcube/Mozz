import SwiftUI
import MozzCore
import MozzDatabase

/// Full-text search over the local FTS5 index. Queries run against the DB with a
/// short debounce; results are grouped into artists / albums / tracks. Because
/// search hits SQLite directly, it stays well under the sub-100ms bar even at
/// 100k tracks.
struct SearchView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var query = ""
    @State private var results = SearchResults(artists: [], albums: [], tracks: [])
    @State private var searchTask: Task<Void, Never>?
    @State private var lastLatencyMs: Double?

    var body: some View {
        NavigationStack {
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
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Artists, albums, songs")
            .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
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
