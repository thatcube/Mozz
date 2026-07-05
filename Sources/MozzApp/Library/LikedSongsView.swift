import SwiftUI
import MozzCore
import MozzDatabase

/// The "Liked Songs" list — Jellyfin favorites and Plex tracks rated ≥ 4★,
/// unified by ``LibraryRepository/likedTracks(serverId:limit:)``. Reads the
/// local DB so it works offline; refreshes when the view appears (a like made
/// elsewhere shows up on return).
struct LikedSongsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var tracks: [TrackRecord] = []
    @State private var loaded = false

    var body: some View {
        List {
            if !tracks.isEmpty {
                Button {
                    env.playback.play(tracks: tracks.map { $0.toDomain() }, startAt: 0)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                Button {
                    env.playback.play(tracks: tracks.map { $0.toDomain() }.shuffled(), startAt: 0)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track, showArtist: true)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        env.playback.play(tracks: tracks.map { $0.toDomain() }, startAt: index)
                    }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Liked Songs")
        .overlay {
            if tracks.isEmpty && loaded {
                ContentUnavailableView("No Liked Songs", systemImage: "heart",
                    description: Text("Tap the heart on a song to add it here."))
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        tracks = (try? await env.repository.likedTracks(serverId: env.active?.connection.id)) ?? []
        loaded = true
    }
}
