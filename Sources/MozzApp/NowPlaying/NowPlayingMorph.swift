import SwiftUI
import MozzCore
import MozzPlayback

// MARK: - Morph container (Candidate B: pure custom Liquid Glass)
//
// The mini island and the full-screen drawer are ONE view that morphs between
// two states. There is no native `tabViewBottomAccessory` and no cross-layer
// hand-off: the container literally *is* the island, so the collapse clip, the
// receive-bounce and the glass settle all fall out of one set of geometry
// interpolations. Two scalars drive everything:
//
//   • `p`     ∈ [0,1]  expand progress. 0 = island, 1 = full drawer. Only the
//                      open/collapse springs move it — never the drag.
//   • `dragY` ≥ 0      live finger translation while dragging the open drawer
//                      down. The whole surface rides the finger 1:1, fully
//                      opaque; the morph/fade happens ONLY on release.
//
// Because `p` stays pinned at 1 for the entire drag, the surface is full-size
// and fully opaque the whole time a finger is down — nothing clips, glasses, or
// fades mid-drag, and the mini controls stay hidden. Letting go animates `p` → 0,
// which shrinks the surface up to the island frame (clipping the body away),
// fades the body out, fades the mini controls in, dissolves the frost into
// Liquid Glass and lands the artwork in the slot.
struct NowPlayingMorphContainer: View {
    @ObservedObject var playback: PlaybackEngine
    @ObservedObject var ui: PlayerUIModel

    /// 0 = docked island, 1 = full drawer. Animated by the open/collapse springs.
    @State private var p: CGFloat = 0
    /// Live drag translation (points) while the open drawer is being pulled down.
    @State private var dragY: CGFloat = 0
    @State private var scrubbing = false
    @State private var scrubValue = 0.0

    var body: some View {
        // Outer reader supplies the real safe-area insets; the inner reader,
        // ignoring the safe area, supplies the true full-screen size. We need
        // both: the island is placed off the bottom inset, the drawer bleeds
        // full-screen.
        GeometryReader { safeGeo in
            let safeTop = safeGeo.safeAreaInsets.top
            let safeBottom = safeGeo.safeAreaInsets.bottom
            GeometryReader { geo in
                let m = Morph(width: geo.size.width, height: geo.size.height,
                              safeTop: safeTop, safeBottom: safeBottom,
                              p: p, dragY: dragY)
                ZStack(alignment: .topLeading) {
                    surface(m)
                    travelingArtwork(m)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .onChange(of: ui.isFullPresented, initial: true) { _, want in
                    animate(to: want)
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Surface (background + drawer body + mini controls)

    private func surface(_ m: Morph) -> some View {
        ZStack(alignment: .top) {
            // Opaque frosted panel for the expanded drawer. It fades out during
            // the collapse, revealing the Liquid Glass behind — so mid-collapse
            // the shrinking bubble is translucent, exactly like Apple's.
            RoundedRectangle(cornerRadius: m.radius, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    LinearGradient(colors: [.black.opacity(0.04), .black.opacity(0.26)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .opacity(m.solidBgOpacity)

            drawerBody(m)
                .frame(width: m.width, height: m.surfaceHExpanded, alignment: .top)
                .opacity(m.bodyOpacity)
                .allowsHitTesting(m.p > 0.5)

            miniControls(m)
                .frame(width: m.islandW, height: Morph.islandHeight)
                .opacity(m.miniOpacity)
                .allowsHitTesting(m.p < 0.5)
        }
        .frame(width: m.surfaceW, height: m.surfaceH, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: m.radius, style: .continuous))
        .liquidGlass(radius: m.radius)
        .position(x: m.surfaceCenterX, y: m.surfaceCenterY)
    }

    // MARK: Traveling artwork (single image, big-center ⇄ small-left)

    private func travelingArtwork(_ m: Morph) -> some View {
        MorphArtwork(track: playback.currentTrack, side: m.artSide, cornerRadius: m.artRadius)
            .shadow(color: .black.opacity(0.35 * m.bodyOpacity),
                    radius: 18 * m.p, y: 10 * m.p)
            .position(x: m.artCenterX, y: m.artCenterY)
            .allowsHitTesting(false)
    }

    // MARK: Mini controls == the island content row (hidden until release)

    private func miniControls(_ m: Morph) -> some View {
        HStack(spacing: 10) {
            // Reserve the artwork's slot; the traveling artwork lands here.
            Color.clear.frame(width: Morph.islandArtSide, height: Morph.islandArtSide)

            VStack(alignment: .leading, spacing: 1) {
                Text(playback.currentTrack?.title ?? "")
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(playback.currentTrack?.artistName ?? "")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { playback.togglePlayPause() } label: {
                Image(systemName: playback.snapshot.status == .playing ? "pause.fill" : "play.fill")
                    .font(.title3).frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { playback.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.title3).frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!playback.snapshot.hasNext)
            .opacity(playback.snapshot.hasNext ? 1 : 0.4)
        }
        // Artwork + titles shifted right (bigger leading inset); play/next keep
        // the tighter trailing inset so they don't move.
        .padding(.leading, Morph.islandArtLeading)
        .padding(.trailing, Morph.islandContentPad)
        // Tapping the pill (outside the buttons) expands into the drawer.
        .contentShape(Rectangle())
        .onTapGesture { ui.isFullPresented = true }
    }

    // MARK: Drawer body (everything below the top edge; fades + clips on collapse)

    private func drawerBody(_ m: Morph) -> some View {
        VStack(spacing: 0) {
            header(m)

            scrubber
                .padding(.horizontal, 32)
                .padding(.top, 22)
            transport
                .padding(.top, 14)
            secondaryControls
                .padding(.top, 20)
            if let track = playback.currentTrack {
                formatBadge(track: track).padding(.top, 12)
            }
            upNext.padding(.top, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Grabber + reserved artwork slot + titles. Owns the dismiss drag so the
    /// scrubber and up-next scroll keep their own gestures.
    private func header(_ m: Morph) -> some View {
        VStack(spacing: 0) {
            Capsule().fill(.white.opacity(0.5)).frame(width: 40, height: 5)
                .padding(.top, m.safeTop + 8)
                .opacity(m.grabberOpacity)

            // Reserves the big artwork's rest space; the traveling artwork is
            // drawn as an absolute sibling so the layout offset never moves it.
            Color.clear
                .frame(width: m.expArtSide, height: m.expArtSide)
                .padding(.top, 26)

            VStack(spacing: 5) {
                Text(playback.currentTrack?.title ?? "").font(.title2.bold())
                    .multilineTextAlignment(.center).lineLimit(2)
                Text(playback.currentTrack?.artistName ?? "").font(.title3)
                    .foregroundStyle(.secondary).lineLimit(1)
                if let album = playback.currentTrack?.albumTitle {
                    Text(album).font(.subheadline).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .padding(.top, 26)
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }

    // MARK: Gestures / animation

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                guard p > 0.5 else { return }
                dragY = max(0, value.translation.height)
            }
            .onEnded { value in
                guard p > 0.5 else { return }
                let far = value.translation.height > 140
                let flung = value.predictedEndTranslation.height > 340
                if far || flung {
                    // Route through the shared flag so the collapse always runs
                    // the same spring, whether triggered here or externally.
                    ui.isFullPresented = false
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { dragY = 0 }
                }
            }
    }

    /// The single animator. `open` grows the drawer; `!open` collapses it into
    /// the island with a gentle receive-bounce (low damping = small overshoot).
    private func animate(to open: Bool) {
        if open {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                p = 1; dragY = 0
            }
        } else {
            withAnimation(.spring(response: 0.44, dampingFraction: 0.72)) {
                p = 0; dragY = 0
            }
        }
    }

    // MARK: Drawer controls

    private var scrubber: some View {
        let snapshot = playback.snapshot
        return VStack(spacing: 4) {
            Slider(
                value: Binding(get: { scrubbing ? scrubValue : snapshot.elapsed },
                               set: { scrubValue = $0 }),
                in: 0...max(snapshot.duration, 1),
                onEditingChanged: { editing in
                    scrubbing = editing
                    if !editing { playback.seek(to: scrubValue) }
                }
            )
            HStack {
                Text(Format.duration(scrubbing ? scrubValue : snapshot.elapsed))
                Spacer()
                Text(Format.duration(snapshot.duration))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 44) {
            Button { playback.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                .disabled(!playback.snapshot.hasPrevious)
            Button { playback.togglePlayPause() } label: {
                Image(systemName: playback.snapshot.status == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            Button { playback.next() } label: { Image(systemName: "forward.fill").font(.title) }
                .disabled(!playback.snapshot.hasNext)
        }
        .tint(.primary)
    }

    private var secondaryControls: some View {
        HStack(spacing: 60) {
            Button { playback.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(playback.snapshot.isShuffled ? Color.accentColor : .secondary)
            }
            Button { playback.cycleRepeatMode() } label: {
                Image(systemName: repeatIcon(playback.snapshot.repeatMode))
                    .foregroundStyle(playback.snapshot.repeatMode == .off ? .secondary : Color.accentColor)
            }
        }
        .font(.title3)
    }

    private func formatBadge(track: Track) -> some View {
        let parts = [track.format.codec?.uppercased(), track.format.sampleRateHz.map { "\($0 / 1000) kHz" }]
            .compactMap { $0 }
        return Text(parts.joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary)
    }

    @ViewBuilder private var upNext: some View {
        if !playback.upNext.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Up Next").font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(playback.upNext.prefix(100).enumerated()), id: \.offset) { _, track in
                            HStack {
                                Text(track.title).lineLimit(1)
                                Spacer()
                                Text(track.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
        } else {
            Spacer(minLength: 0)
        }
    }

    private func repeatIcon(_ mode: MozzPlayback.RepeatMode) -> String {
        switch mode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

// MARK: - Geometry

/// All frames and opacities are pure functions of `(p, dragY)` and the screen
/// metrics, so the whole morph is deterministic and reversible.
private struct Morph {
    let width: CGFloat
    let height: CGFloat
    let safeTop: CGFloat
    let safeBottom: CGFloat
    let p: CGFloat
    let dragY: CGFloat

    // MARK: tunables
    static let islandHeight: CGFloat = 56
    static let islandHMargin: CGFloat = 14      // pill inset from the screen edges
    static let islandContentPad: CGFloat = 12   // trailing inset (play/next side)
    static let islandArtLeading: CGFloat = 20   // leading inset — shifts art+titles right
    static let islandArtSide: CGFloat = 34      // was 42 (−8, smaller island artwork)
    static let islandArtRadius: CGFloat = 8
    static let islandBottomGap: CGFloat = 8     // gap between island and tab bar
    static let tabBarHeight: CGFloat = 50       // floating tab-bar estimate
    static let expandedRadius: CGFloat = 24
    static let expandedArtRadius: CGFloat = 10
    static let bottomOverhang: CGFloat = 120    // surface runs off-screen at p=1
    static let expArtTopGap: CGFloat = 39       // grabber + gap above big artwork
    static let expArtMaxSide: CGFloat = 340

    // Island (collapsed) frame -----------------------------------------------
    var islandW: CGFloat { width - 2 * Self.islandHMargin }
    var islandBottom: CGFloat { height - safeBottom - Self.tabBarHeight - Self.islandBottomGap }
    var islandTop: CGFloat { islandBottom - Self.islandHeight }
    var islandCenterY: CGFloat { islandBottom - Self.islandHeight / 2 }
    var islandLeft: CGFloat { (width - islandW) / 2 }
    var islandArtCenterX: CGFloat { islandLeft + Self.islandArtLeading + Self.islandArtSide / 2 }
    var islandRadius: CGFloat { Self.islandHeight / 2 }

    // Expanded artwork --------------------------------------------------------
    var expArtSide: CGFloat { min(width - 90, Self.expArtMaxSide) }
    var expArtCenterY: CGFloat { safeTop + Self.expArtTopGap + expArtSide / 2 }

    // Morphing surface --------------------------------------------------------
    var surfaceW: CGFloat { lerp(islandW, width, p) }
    var surfaceHExpanded: CGFloat { height + Self.bottomOverhang }
    var surfaceH: CGFloat { lerp(Self.islandHeight, surfaceHExpanded, p) }
    /// Top edge follows the finger 1:1 at p=1, and lands on the island's top on
    /// collapse. `dragY` is folded back to 0 by the collapse spring alongside p.
    var topEdge: CGFloat { lerp(islandTop, 0, p) + dragY }
    var surfaceCenterX: CGFloat { width / 2 }
    var surfaceCenterY: CGFloat { topEdge + surfaceH / 2 }
    var radius: CGFloat { lerp(islandRadius, Self.expandedRadius, p) }

    // Traveling artwork -------------------------------------------------------
    var artSide: CGFloat { lerp(Self.islandArtSide, expArtSide, p) }
    var artRadius: CGFloat { lerp(Self.islandArtRadius, Self.expandedArtRadius, p) }
    var artCenterX: CGFloat { lerp(islandArtCenterX, width / 2, p) }
    var artCenterY: CGFloat { lerp(islandCenterY, expArtCenterY, p) + dragY }

    // Opacities ---------------------------------------------------------------
    // While a finger is down `p` is pinned at 1, so anything keyed purely on `p`
    // stays put during the drag and only animates on release — the mini controls
    // must NEVER appear until you let go.
    /// 0 for the whole drag (p==1); fades in only as the collapse runs (p→0).
    var miniOpacity: CGFloat { clamp(1 - p) }
    /// Body fades out fast (gone by p≈0.55) so the collapse reads as a morph.
    var bodyOpacity: CGFloat { clamp((p - 0.55) / 0.45) }
    /// Frost → glass: opaque while expanded/dragging, clear by p≈0.30.
    var solidBgOpacity: CGFloat { clamp((p - 0.30) / 0.70) }
    /// Grabber rides with the drawer body and fades out with it on collapse.
    var grabberOpacity: CGFloat { bodyOpacity }
}

private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
private func clamp(_ x: CGFloat, _ lo: CGFloat = 0, _ hi: CGFloat = 1) -> CGFloat { min(max(x, lo), hi) }

// MARK: - Liquid Glass background

private extension View {
    /// The island's Liquid Glass on iOS/macOS 26+, a material fallback below it.
    @ViewBuilder
    func liquidGlass(radius: CGFloat) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            self.background(
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.ultraThinMaterial)
            )
        }
    }
}

// MARK: - Artwork

/// One traveling artwork. Its display size animates, but the pixel size used to
/// resolve the backend URL is fixed, so scaling never triggers a reload and the
/// image never flashes its placeholder mid-flight.
private struct MorphArtwork: View {
    let track: Track?
    let side: CGFloat
    var cornerRadius: CGFloat = 10

    @EnvironmentObject private var env: AppEnvironment
    private let base: CGFloat = 340

    var body: some View {
        Group {
            if let url = resolvedURL {
                CachedArtworkImage(url: url) { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var resolvedURL: URL? {
        guard let artwork = track?.artwork, let backend = env.active?.backend else { return nil }
        return backend.artworkURL(for: artwork, size: Int(base * 2))
    }

    private var placeholder: some View {
        let seed = track?.albumTitle ?? track?.title ?? ""
        let hash = abs(seed.hashValue)
        let hue = Double(hash % 360) / 360.0
        return LinearGradient(
            colors: [Color(hue: hue, saturation: 0.5, brightness: 0.7),
                     Color(hue: (hue + 0.1).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.45)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay(
            Image(systemName: "music.note")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: side * 0.4, height: side * 0.4)
                .foregroundStyle(.white.opacity(0.85))
        )
    }
}
