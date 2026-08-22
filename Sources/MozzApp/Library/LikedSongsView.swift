import SwiftUI
import MozzCore
import MozzDatabase

/// "Liked Songs" on the shared immersive scaffold — Jellyfin favorites and Plex
/// tracks rated ≥ 4★, unified by ``LibraryRepository/likedTracks(serverId:limit:)``.
/// Reads the local DB so it works offline. The collection has no cover of its
/// own, so (like Mozz Weekly) the hero blends a color from a representative
/// liked track's artwork — re-rolled at random each time the screen is opened so
/// a growing list of likes doesn't always greet you with the same cover. Reloads
/// on return so a like/unlike made elsewhere is reflected.
struct LikedSongsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var tracks: [TrackRecord] = []
    @State private var heroArtwork: ArtworkRef?
    @State private var heroSeed = "liked-songs"
    @State private var loaded = false
    @State private var didInitialLoad = false

    var body: some View {
        MediaDetailScaffold(
            hero: MediaHero(style: .fullBleed, artwork: heroArtwork, seed: heroSeed),
            title: "Liked Songs",
            meta: tracks.isEmpty ? nil : (tracks.count == 1 ? "1 song" : "\(tracks.count) songs"),
            actions: { DetailPlayActions(play: { play(from: 0) }, shuffle: shuffle) },
            content: {
                if tracks.isEmpty && loaded {
                    ContentUnavailableView {
                        Label("No Liked Songs", mozz: "heart")
                    } description: {
                        Text("Tap the heart on a song to add it here.")
                    }
                        .padding(.top, 40)
                } else {
                    DetailSongRows(tracks: tracks, showArtist: true) { play(from: $0) }
                }
            }
        )
        .task {
            await load()
            didInitialLoad = true
        }
        // Reload on every subsequent appearance (the first is covered by `.task`)
        // so unliking a song elsewhere drops it from the list on return.
        .onAppear { if didInitialLoad { Task { await load() } } }
    }

    private func play(from index: Int) {
        env.playback.play(tracks: tracks.map { $0.toDomain() }, startAt: index)
    }

    private func shuffle() {
        env.playback.playShuffled(tracks.map { $0.toDomain() })
    }

    private func load() async {
        let result = (try? await env.repository.likedTracks(serverId: env.active?.connection.id)) ?? []
        tracks = result
        updateHero(from: result)
        loaded = true
    }

    /// Rotating hero backdrop: a random liked cover, drawn from the *distinct*
    /// artwork keys so an album with a dozen likes doesn't crowd out everything
    /// else. Picked once per visit — the reload on return keeps the same backdrop
    /// unless that cover is no longer liked (or there are no likes left).
    private func updateHero(from result: [TrackRecord]) {
        let keys = Set(result.compactMap(\.artworkKey))
        guard !keys.isEmpty else {
            heroArtwork = nil
            heroSeed = "liked-songs"
            return
        }
        if let current = heroArtwork?.key, keys.contains(current) { return }
        guard let key = keys.randomElement() else { return }
        heroArtwork = ArtworkRef(key: key)
        heroSeed = key
    }
}
