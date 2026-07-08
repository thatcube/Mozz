import SwiftUI
import MozzCore
import MozzDatabase

/// Any recommendation set (Mozz Weekly, Supermix, a Daily/Artist mix, Replay …)
/// as a full page on the shared immersive scaffold. A mix has no cover of its
/// own, so the hero blends a color from the first track's artwork (chosen once,
/// stably, when the tracks load — matching the Home tile so there's no pop-in).
struct MixDetailView: View {
    @EnvironmentObject private var env: AppEnvironment
    let setId: String
    var fallbackTitle: String = "Mix"
    var subtitle: String? = "Made for You"

    @State private var tracks: [TrackRecord] = []
    @State private var title = ""
    @State private var heroArtwork: ArtworkRef?
    @State private var heroSeed = ""
    @State private var loaded = false

    var body: some View {
        MediaDetailScaffold(
            hero: MediaHero(style: .fullBleed, artwork: heroArtwork,
                            seed: heroSeed.isEmpty ? setId : heroSeed),
            title: title.isEmpty ? fallbackTitle : title,
            subtitle: subtitle,
            meta: tracks.isEmpty ? nil : (tracks.count == 1 ? "1 song" : "\(tracks.count) songs"),
            actions: { DetailPlayActions(play: { play(from: 0) }, shuffle: shuffle) },
            content: {
                if tracks.isEmpty && loaded {
                    ContentUnavailableView {
                        Label("Nothing Yet", mozz: "sparkles")
                    } description: {
                        Text("Play more music and this mix will fill in.")
                    }
                        .padding(.top, 40)
                } else {
                    DetailSongRows(tracks: tracks, showArtist: true) { play(from: $0) }
                }
            }
        )
        .task { await load() }
    }

    private func play(from index: Int) {
        env.playback.play(tracks: tracks.map { $0.toDomain() }, startAt: index)
    }

    private func shuffle() {
        env.playback.playShuffled(tracks.map { $0.toDomain() })
    }

    private func load() async {
        if let set = try? await env.recommendations.set(id: setId) { title = set.title }
        tracks = (try? await env.recommendations.tracks(forSetId: setId)) ?? []
        if let pick = tracks.first(where: { $0.artworkKey != nil }), let key = pick.artworkKey {
            heroArtwork = ArtworkRef(key: key)
            heroSeed = key
        }
        loaded = true
    }
}
