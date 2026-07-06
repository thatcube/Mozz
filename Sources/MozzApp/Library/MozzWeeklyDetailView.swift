import SwiftUI
import MozzCore
import MozzDatabase

/// "Mozz Weekly" as a full playlist page on the shared media-detail scaffold.
/// A mix has no cover of its own, so the hero blends a color from a RANDOM
/// track's artwork in the set (chosen once, stably, when the tracks load).
struct MozzWeeklyDetailView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var tracks: [TrackRecord] = []
    @State private var title = "Mozz Weekly"
    @State private var heroArtwork: ArtworkRef?
    @State private var heroSeed = "mozz-weekly"
    @State private var loaded = false

    var body: some View {
        MediaDetailScaffold(
            hero: MediaHero(style: .fullBleed, artwork: heroArtwork, seed: heroSeed),
            title: title,
            subtitle: "Made for You",
            meta: tracks.isEmpty ? nil : (tracks.count == 1 ? "1 song" : "\(tracks.count) songs"),
            actions: { DetailPlayActions(play: { play(from: 0) }, shuffle: shuffle) },
            content: {
                if tracks.isEmpty && loaded {
                    ContentUnavailableView("Nothing Yet", systemImage: "sparkles",
                        description: Text("Play some music and your weekly mix will appear here."))
                        .padding(.top, 40)
                } else {
                    DetailSongRows(tracks: tracks) { play(from: $0) }
                }
            }
        )
        .task { await load() }
    }

    private func play(from index: Int) {
        env.playback.play(tracks: tracks.map { $0.toDomain() }, startAt: index)
    }

    private func shuffle() {
        env.playback.play(tracks: tracks.map { $0.toDomain() }.shuffled(), startAt: 0)
    }

    private func load() async {
        await env.ensureMozzWeekly()
        tracks = (try? await env.recommendations.mozzWeeklyTracks()) ?? []
        if let set = try? await env.recommendations.mozzWeeklySet() { title = set.title }
        // Pick a stable random track's artwork as the hero backdrop source.
        // Deterministic pick (matches Home's representative track) so the hero
        // artwork can be preloaded before the page opens — no image pop-in.
        if let pick = tracks.first(where: { $0.artworkKey != nil }) ?? tracks.first {
            heroArtwork = pick.artworkKey.map(ArtworkRef.init(key:))
            heroSeed = pick.artworkKey ?? pick.title
        }
        loaded = true
    }
}

/// The tappable "Mozz Weekly" box on Home — a featured card that opens the full
/// mix page. Shows a representative cover, the title and a song count.
struct MozzWeeklyCard: View {
    let title: String
    let subtitle: String
    let artwork: ArtworkRef?
    let seed: String

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(artwork: artwork, seed: seed, size: 72, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text("Mozz Weekly").font(.headline)
                Text(title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
