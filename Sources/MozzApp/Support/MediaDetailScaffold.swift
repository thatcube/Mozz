import SwiftUI
import MozzCore
import MozzDatabase
#if canImport(UIKit)
import UIKit
#endif

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
    /// Horizontal inset applied to `content`. Defaults to 16 (song lists); the
    /// artist page passes 0 so its horizontal shelves can bleed to the edge and
    /// pad each section itself.
    var contentHorizontalPadding: CGFloat = 16
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var bg: Color = Color(white: 0.12)
    @State private var deepBg: Color = .mozzDetailBackground

    private static var fullBleedHeight: CGFloat { 500 }
    private static var centeredArtworkSize: CGFloat { 240 }
    /// Name for the ScrollView's coordinate space, so the full-bleed header can
    /// measure how far the page has been pulled down (overscroll) and reveal the
    /// mirrored reflection above the artwork.
    private static var scrollSpace: String { "mozzDetailScroll" }

    /// Identity for the palette `.task`. Includes the artwork key so the palette
    /// re-derives when the hero art arrives (or changes) after first render —
    /// otherwise a late fallback cover (e.g. an art-less artist borrowing an album
    /// cover) would show the right image but keep the seed-based placeholder color.
    private var paletteToken: String { "\(hero.seed)\u{1}\(hero.artwork?.key ?? "")" }

    /// The device's top safe-area inset (status bar / Dynamic Island height),
    /// read from the key window so the full-bleed image can be pulled up under it
    /// WITHOUT making the ScrollView ignore safe areas (which broke the
    /// horizontal margins). 0 on macOS.
    private var topSafeInset: CGFloat {
        #if os(iOS)
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?.safeAreaInsets.top) ?? 0
        #else
        0
        #endif
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Deep, same-hue base fills the whole screen (incl. under the status
            // bar) — it's the dark end of the seamless bleed and the high-contrast
            // backdrop the song list settles onto.
            deepBg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    header
                    content()
                        .padding(.horizontal, contentHorizontalPadding)
                        .padding(.top, 12)
                        .padding(.bottom, 40)
                        .frame(maxWidth: .infinity)
                        // Seamless bleed: the hero's color continues at the very
                        // top of the list, then eases into `deepBg` a few hundred
                        // points down. Pinned to the TOP of the content and given a
                        // FIXED height (never `maxHeight: .infinity`): a flexible
                        // decoration inside the ScrollView poisons the sibling
                        // header's height proposal when the page is short — see the
                        // note on `contentBackground`. `deepBg` already fills the
                        // whole page base, so there's nothing to fill below the
                        // gradient anyway.
                        .background(alignment: .top) { contentBackground }
                }
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(name: Self.scrollSpace)
            .minimizesBottomBarOnScroll()

            // Back button stays BELOW the status bar (the ZStack respects the
            // safe area even though the full-bleed image bleeds under it).
            DetailBackButton { dismiss() }
                .padding(.leading, 12)
                .padding(.top, 4)
        }
        .environment(\.colorScheme, .dark)
        .hideNavigationBar()
        .enableInteractivePop()
        // Recompute the palette whenever the seed OR the artwork changes. The
        // artwork can arrive late (e.g. the artist page falls back to a
        // representative album cover only once its albums finish loading); keying
        // on the artwork too means the background re-derives from that cover
        // instead of staying stuck on the seed-based placeholder color.
        .task(id: paletteToken) {
            // If the artwork was preloaded, resolve the palette synchronously so
            // it's correct on the first frame; otherwise fade it in when it lands.
            if let p = DominantColor.cachedPalette(
                for: hero.artwork, seed: hero.seed, backend: env.active?.backend) {
                bg = p.hero; deepBg = p.deep
            } else {
                let p = await DominantColor.palette(
                    for: hero.artwork, seed: hero.seed, backend: env.active?.backend)
                withAnimation(.easeOut(duration: 0.35)) { bg = p.hero; deepBg = p.deep }
            }
        }
    }

    @ViewBuilder private var header: some View {
        switch hero.style {
        case .fullBleed: fullBleedHeader
        case .centeredArtwork: centeredHeader
        }
    }

    // MARK: Full-bleed

    /// Full-bleed hero with an Apple-Music-style stretchy top: pulling the page
    /// DOWN grows (and zooms) the artwork to fill the opening instead of revealing
    /// the page base, so you can't pull anything empty into view. The image is
    /// bottom-anchored and always extends up under the status bar; on overscroll
    /// it grows by exactly the pull distance with its top pinned to the screen
    /// edge, while the title/actions ride the bottom down with the content.
    private var fullBleedHeader: some View {
        GeometryReader { geo in
            // Overscroll distance (0 at rest, positive when pulled down). The
            // ScrollView has already translated the header down by this amount, so
            // growing the image by the same amount keeps its top pinned to the
            // screen edge — the artwork appears to stretch/zoom.
            let stretch = max(0, geo.frame(in: .named(Self.scrollSpace)).minY)
            ZStack(alignment: .bottom) {
                Color.clear
                    .frame(width: geo.size.width, height: Self.fullBleedHeight + stretch)
                    .overlay { heroArtwork }
                    .clipped()
                    .overlay {
                        // Keep text legible + fade the image into the page color.
                        LinearGradient(
                            colors: [.clear, .clear, bg.opacity(0.55), bg],
                            startPoint: .top, endPoint: .bottom)
                    }
                VStack(spacing: 14) {
                    titleBlock(onDark: true)
                    actions()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            // Reserve the hero height MINUS the status-bar inset: the image is
            // taller than this box and bottom-anchored, so it bleeds up under the
            // status bar without the ScrollView ignoring safe areas (which broke
            // the horizontal margins — see the overflow history above).
            .frame(width: geo.size.width,
                   height: Self.fullBleedHeight - topSafeInset,
                   alignment: .bottom)
        }
        .frame(height: Self.fullBleedHeight - topSafeInset)
    }

    /// The hero artwork content (real image or the deterministic fallback). Filled
    /// via aspect-fill inside a fixed-width box, so as the box grows taller during
    /// an overscroll pull the image scales up (zooms) to keep covering it.
    @ViewBuilder private var heroArtwork: some View {
        if let url = heroURL(pixels: 1200) {
            CachedArtworkImage(url: url) { heroFallback }
        } else {
            heroFallback
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
        // Solid extracted color behind the centered artwork. It bleeds up under
        // the status bar AND grows into any downward overscroll pull, so pulling
        // the page down just reveals more of the same page color (nothing scales)
        // instead of the dark page base. The list below continues from this exact
        // color, so the fade into the deep base stays seamless.
        .background(alignment: .top) {
            GeometryReader { geo in
                let up = topSafeInset + max(0, geo.frame(in: .named(Self.scrollSpace)).minY)
                bg
                    .frame(width: geo.size.width, height: geo.size.height + up)
                    .offset(y: -up)
            }
        }
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

    /// The seamless page background behind the scrolling content. The hero's
    /// extracted color holds through the first row (so the artwork continues
    /// straight into the list with no seam) then eases into `deepBg` — the SAME
    /// hue, kept tinted rather than black — over ~420pt. `deepBg` also fills the
    /// whole page base (see `body`), so below this gradient the page keeps the
    /// settled tone with no seam.
    ///
    /// IMPORTANT: this is a FIXED-height gradient (420pt), NOT `maxHeight:
    /// .infinity`. A flexible/greedy decoration inside the ScrollView makes the
    /// content's height proposal ambiguous; when the page is shorter than the
    /// viewport SwiftUI resolves that slack by squashing the *sibling* full-bleed
    /// header's height proposal to near-zero, which collapsed the title's meta
    /// line and the Play/Shuffle row (the "few liked songs looked broken" bug).
    /// A fixed height keeps the proposal unambiguous, so short and tall pages lay
    /// out identically. Applied with `.background(alignment: .top)` so it always
    /// pins to the first row.
    private var contentBackground: some View {
        LinearGradient(
            stops: [
                .init(color: bg, location: 0.0),
                .init(color: bg, location: 0.08),
                .init(color: deepBg, location: 1.0),
            ],
            startPoint: .top, endPoint: .bottom)
            .frame(maxWidth: .infinity)
            .frame(height: 420)
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
    /// Optional "Start Station" (radio) action, offered via a long-press context
    /// menu on the Shuffle button so a plain tap still shuffles.
    var startRadio: (() -> Void)?

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
            .contextMenu {
                if let startRadio {
                    Button(action: startRadio) {
                        Label("Start Station", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
            }
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
                    Divider().padding(.leading, showArtist ? 56 : 36)
                }
            }
        }
    }
}

/// The floating circular back button for the detail page's custom chrome — a
/// translucent glass circle with a white chevron over the hero, matching the
/// app's custom navigation look (the system bar is hidden on this page).
struct DetailBackButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.backward")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }
}
