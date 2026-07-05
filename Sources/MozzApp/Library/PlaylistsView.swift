import SwiftUI
import MozzCore
import MozzDatabase

/// All playlists for the active server. Playlists are few, so this loads them
/// in one shot (no pagination).
struct PlaylistsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var playlists: [PlaylistRecord] = []
    @State private var loaded = false

    var body: some View {
        List {
            ForEach(playlists) { playlist in
                NavigationLink {
                    PlaylistDetailView(playlist: playlist)
                } label: {
                    HStack(spacing: 12) {
                        ArtworkView(artwork: playlist.artworkKey.map(ArtworkRef.init(key:)),
                                    seed: playlist.title, size: 44, cornerRadius: 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.title).lineLimit(1)
                            if let count = playlist.trackCount {
                                Text(count == 1 ? "1 song" : "\(count) songs")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Playlists")
        .overlay {
            if playlists.isEmpty && loaded {
                ContentUnavailableView("No Playlists", systemImage: "music.note.list")
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let serverId = env.active?.connection.id else { loaded = true; return }
        playlists = (try? await env.repository.allPlaylists(serverId: serverId)) ?? []
        loaded = true
    }
}

/// A playlist's tracks, in playlist order, with play/shuffle.
struct PlaylistDetailView: View {
    @EnvironmentObject private var env: AppEnvironment
    let playlist: PlaylistRecord

    @State private var tracks: [TrackRecord] = []
    @State private var loaded = false

    var body: some View {
        List {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track, showArtist: true)
                    .contentShape(Rectangle())
                    .onTapGesture { play(from: index) }
            }
        }
        .listStyle(.plain)
        .navigationTitle(playlist.title)
        .inlineNavigationTitle()
        .overlay {
            if tracks.isEmpty && loaded {
                ContentUnavailableView("Empty Playlist", systemImage: "music.note.list")
            }
        }
        .task { await load() }
    }

    private func play(from index: Int) {
        env.playback.play(tracks: tracks.map { $0.toDomain() }, startAt: index)
    }

    private func load() async {
        guard let serverId = env.active?.connection.id else { loaded = true; return }
        tracks = (try? await env.repository.tracks(forPlaylistRemoteId: playlist.remoteId, serverId: serverId)) ?? []
        loaded = true
    }
}
