import SwiftUI
import MozzCore
import MozzDatabase

/// Describes the top-of-page hero for a media detail. The *style* is independent
/// of the content type, so a caller chooses how the artwork is presented while
/// the rest of the page stays identical:
/// - `.fullBleed` — the artwork bleeds to the top edge and fades into the
///   extracted color (artists; big cover photos).
/// - `.centeredArtwork` — the artwork sits in a centered box, so a square cover
///   is shown in full (albums; playlists).
struct MediaHero {
    enum Style { case fullBleed, centeredArtwork }
    var style: Style
    var artwork: ArtworkRef?
    /// Stable string used for the deterministic fallback color / placeholder when
    /// there's no artwork (offline demo).
    var seed: String

    init(style: Style, artwork: ArtworkRef?, seed: String) {
        self.style = style
        self.artwork = artwork
        self.seed = seed
    }
}

/// The shared media-detail page: a hero that blends into a color extracted from
/// the artwork, then a title / subtitle / meta block, caller-supplied actions,
/// and a caller-supplied content slot (song list, shelves, …). Used by Playlist,
/// Mozz Weekly, Album, Artist and Liked Songs so they all share this look.
struct MediaDetailScaffold<Actions: View, Content: View>: View {
    let hero: MediaHero
    let title: String
    var subtitle: String?
    var meta: String?
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    @EnvironmentObject private var env: AppEnvironment
    @State private var bg: Color = Color(white: 0.12)
    @State private var resolvedColor = false

    private static var fullBleedHeight: CGFloat { 440 }
    private static var centeredArtworkSize: CGFloat { 240 }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                content()
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity)
                    .background(Color.mozzDetailBackground)
            }
        }
        .scrollIndicators(.hidden)
        // The hero color fills the whole backdrop (incl. under the status bar, so
        // there's no white band); the content section paints its own near-black
        // over it. Force a dark treatment so the page reads like Apple Music's
        // always-dark detail pages and white hero text stays legible.
        .background(bg.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .heroNavigationChrome()
        .task(id: hero.seed) {
            resolvedColor = false
            let color = await DominantColor.background(
                for: hero.artwork, seed: hero.seed, backend: env.active?.backend)
            withAnimation(.easeOut(duration: 0.35)) { bg = color; resolvedColor = true }
        }
    }

    @ViewBuilder private var header: some View {
        switch hero.style {
        case .fullBleed: fullBleedHeader
        case .centeredArtwork: centeredHeader
        }
    }

    // MARK: Full-bleed

    private var fullBleedHeader: some View {
        ZStack(alignment: .bottom) {
            fullBleedImage
                .overlay {
                    // Keep text legible + fade the image into the page color.
                    LinearGradient(
                        colors: [.clear, .clear, bg.opacity(0.55), bg],
                        startPoint: .top, endPoint: .bottom)
                }
                .ignoresSafeArea(edges: .top)
            VStack(spacing: 14) {
                titleBlock(onDark: true)
                actions()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder private var fullBleedImage: some View {
        if let url = heroURL(pixels: 1200) {
            CachedArtworkImage(url: url) { heroFallback }
                .frame(maxWidth: .infinity)
                .frame(height: Self.fullBleedHeight)
                .clipped()
        } else {
            heroFallback.frame(height: Self.fullBleedHeight)
        }
    }

    // MARK: Centered artwork

    private var centeredHeader: some View {
        VStack(spacing: 16) {
            ArtworkView(artwork: hero.artwork, seed: hero.seed,
                        size: Self.centeredArtworkSize, cornerRadius: 14)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
                .padding(.top, 12)
            titleBlock(onDark: true)
            actions()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .background(
            LinearGradient(colors: [bg, bg, bg.opacity(0)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    // MARK: Shared bits

    /// Title + subtitle + meta. Always rendered light because it sits over the
    /// dark hero color (extracted colors are brightness-capped), so it reads in
    /// both light and dark mode.
    @ViewBuilder private func titleBlock(onDark: Bool) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            if let subtitle {
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
            if let meta {
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var heroFallback: some View {
        LinearGradient(colors: [bg.opacity(0.85), bg], startPoint: .top, endPoint: .bottom)
    }

    private func heroURL(pixels: CGFloat) -> URL? {
        guard let artwork = hero.artwork, let backend = env.active?.backend else { return nil }
        return backend.artworkURL(for: artwork, size: Int(pixels))
    }
}

/// The Play + Shuffle action row shared by every media detail. Styled light so
/// it reads over the dark hero color: a white Play pill (dark label) + a
/// white-outline Shuffle.
struct DetailPlayActions: View {
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) {
                Label("Play", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.black)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)

            Button(action: shuffle) {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
        .controlSize(.large)
    }
}

/// A vertical song list for a media detail's content slot (playlist, album, Mozz
/// Weekly, …). Tapping a row plays from that index. `showArtist` off makes rows
/// show their track number (albums); on shows the artist (playlists/mixes).
struct DetailSongRows: View {
    let tracks: [TrackRecord]
    var showArtist = true
    var downloadStates: [Int64: DownloadState] = [:]
    var progress: [Int64: Double] = [:]
    let onPlay: (Int) -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(
                    track: track,
                    downloadState: track.id.flatMap { downloadStates[$0] },
                    progress: track.id.flatMap { progress[$0] },
                    showArtist: showArtist
                )
                .contentShape(Rectangle())
                .onTapGesture { onPlay(index) }
                .padding(.vertical, 5)
                if index < tracks.count - 1 {
                    Divider().padding(.leading, showArtist ? 0 : 36)
                }
            }
        }
    }
}
