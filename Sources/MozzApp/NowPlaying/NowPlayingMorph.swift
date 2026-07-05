import SwiftUI
import MozzCore
import MozzPlayback
#if canImport(UIKit)
import UIKit
#endif

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
    /// True only during the collapse, so the downward receive-bounce fires on the
    /// way into the island and never while opening or dragging.
    @State private var receiving = false
    @State private var scrubbing = false
    @State private var scrubValue = 0.0
    /// Live island-press state: `pressed` drives the whole-island scale, `location`
    /// (pill-local) drives the finger-following glow. Kept in an `@Observable` so
    /// the high-frequency `location` updates re-render ONLY the lightweight glow
    /// layer — not this container (which builds the drawer's up-next list).
    @State private var press = IslandPressState()

    /// How much the docked island grows while touched.
    private static let pressScale: CGFloat = 1.04
    private static let pressSpring = Animation.spring(response: 0.28, dampingFraction: 0.62)
    /// Horizontal bloom of the glow on release — it stretches to this multiple as
    /// it fades, so the light diffuses left/right along the rail before vanishing.
    private static let glowReleaseSpread: CGFloat = 4.5

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
                              pRaw: p, dragY: dragY, receiving: receiving,
                              isExpanded: ui.isFullPresented)
                ZStack(alignment: .topLeading) {
                    surface(m)
                    // Finger-following specular glow: a soft highlight on the glass
                    // that tracks the touch point, like Apple's interactive Liquid
                    // Glass. It reads `press.location`, so tracking the finger
                    // re-renders ONLY this layer, never the container. (We render
                    // our own instead of `.glassEffect(.interactive())` because that
                    // API adds its own press-scale that fought our unified scale.)
                    if m.p < 0.5 {
                        IslandGlow(press: press, width: m.islandW,
                                   height: Morph.islandHeight, radius: m.radius)
                            .frame(width: m.islandW, height: Morph.islandHeight)
                            .position(x: m.surfaceCenterX, y: m.miniCenterY)
                            .allowsHitTesting(false)
                    }
                    // The island content is a self-contained subview owning its own
                    // swipe/slide state, so swiping to change tracks re-renders ONLY
                    // the island — not the whole full-player overlay (that was a big
                    // source of jank). The parent just places it: it rides the
                    // surface's top edge DOWN into the island on collapse
                    // (miniCenterY), is hidden while expanding (miniOpacity), and
                    // rides the base top so the receive-grow can rise past it.
                    IslandContent(playback: playback) { ui.isFullPresented = true }
                        .frame(width: m.islandW, height: Morph.islandHeight)
                        .position(x: m.surfaceCenterX, y: m.miniCenterY)
                        .opacity(m.miniOpacity)
                        .allowsHitTesting(m.p < 0.5)
                    travelingArtwork(m)
                    // Instant, whole-island press detection. A UIKit 0-duration
                    // long-press recognizer (installed on the window, so it sits
                    // above the real touch target that SwiftUI draws into a shared
                    // host view) reports touch-DOWN with zero delay — the SwiftUI
                    // drag/long-press gestures wait to disambiguate a stationary
                    // finger, which lagged the scale. It observes without stealing
                    // the touch, and this transparent layer spans the ENTIRE pill,
                    // so a press anywhere — artwork, titles OR the buttons — scales
                    // the whole island as one unit and lights the glow. Gated to the
                    // docked state.
                    Color.clear
                        .frame(width: m.islandW, height: Morph.islandHeight)
                        .onTouchChanged { active, loc in
                            guard m.p < 0.5 else { return }
                            press.location = loc      // instant, tracks the finger
                            withAnimation(Self.pressSpring) { press.pressed = active }
                            if active {
                                press.spread = 1      // snap back to natural width
                                withAnimation(.easeOut(duration: 0.16)) { press.glow = 1 }
                            } else {
                                // Release: bloom outward left/right while fading.
                                withAnimation(.easeOut(duration: 0.45)) {
                                    press.glow = 0
                                    press.spread = Self.glowReleaseSpread
                                }
                            }
                        }
                        .position(x: m.surfaceCenterX, y: m.miniCenterY)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                // Press-scale the WHOLE island as one unit: scale the entire
                // overlay around the island's centre, so glass, artwork and text
                // grow together. When docked the rest of the overlay is
                // transparent, so only the island is visibly affected.
                .scaleEffect(press.pressed ? Self.pressScale : 1,
                             anchor: UnitPoint(x: m.surfaceCenterX / max(geo.size.width, 1),
                                               y: m.miniCenterY / max(geo.size.height, 1)))
                .onChange(of: ui.isFullPresented, initial: true) { _, want in
                    animate(to: want)
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Surface (Liquid Glass background + fading drawer body)

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

    /// The single animator.
    /// - `open`  grows the drawer.
    /// - `!open` collapses it into the island. The spring itself is unchanged
    ///   (the feel you liked); `receiving` gates a downward bounce that fires
    ///   only during this collapse. `p` is clamped in the geometry, so the
    ///   spring's own overshoot can't wobble the surface — the only bounce is the
    ///   deliberate downward one.
    private func animate(to open: Bool) {
        if open {
            receiving = false
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                p = 1; dragY = 0
            }
        } else {
            receiving = true
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                p = 0; dragY = 0
            } completion: {
                receiving = false
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

// MARK: - Island content (self-contained: swipe + title/artist slide)

/// Shared spring for the island text slide.
private let islandTextSpring = Animation.spring(response: 0.34, dampingFraction: 1.0)

/// Live press state for the docked island. `@Observable` so SwiftUI's
/// per-property observation re-renders only the views that read a given field:
/// the whole-island scale reads `pressed` (toggles ~twice per touch), while the
/// finger-following glow reads `location` (updates every move) — so tracking the
/// finger never re-renders the heavy morph container.
@Observable @MainActor final class IslandPressState {
    var pressed = false
    /// Glow opacity (0…1). Fades in fast on touch, out slowly on release.
    var glow: Double = 0
    /// Horizontal spread of the glow (1 = natural). On release it grows so the
    /// light blooms outward left/right along the rail as it fades — like Apple's.
    var spread: CGFloat = 1
    /// Touch point in island-pill-local coordinates (0…islandW, 0…islandHeight).
    var location: CGPoint = .zero
}

/// A soft specular highlight on the island glass that follows the finger — our
/// own take on Apple's interactive Liquid Glass glow. It brightens the glass with
/// a radial `plusLighter` pool centred on the touch, clipped to the pill and
/// fading with the press. Reading `press.location`/`press.pressed` here (and not
/// in the parent) keeps finger-tracking re-renders scoped to just this view.
private struct IslandGlow: View {
    var press: IslandPressState
    let width: CGFloat
    let height: CGFloat
    let radius: CGFloat

    var body: some View {
        // A narrow, dim core right under the finger that washes out very gradually
        // across a wide radius — a small bright point with a long, faint, far-
        // reaching tail (like Apple's), rather than a wide bright plateau.
        //
        // The centre is LOCKED to the rail vertically (y = 0.5) and clamped to the
        // pill horizontally, so — like Apple — dragging your finger off the island
        // never lets the highlight leave it: it just slides along the rail and
        // stays put at the nearest edge.
        //
        // On release the whole gradient is stretched horizontally about the touch
        // point (`spread`) as it fades (`glow`), so the light blooms outward to the
        // left and right along the rail before dissipating — clipped to the pill.
        let nx = min(max(press.location.x / max(width, 1), 0), 1)
        return RadialGradient(
            stops: [
                .init(color: .white.opacity(0.15),  location: 0.0),
                .init(color: .white.opacity(0.12),  location: 0.12),
                .init(color: .white.opacity(0.075), location: 0.28),
                .init(color: .white.opacity(0.038), location: 0.50),
                .init(color: .white.opacity(0.014), location: 0.74),
                .init(color: .white.opacity(0.0),   location: 1.0),
            ],
            center: UnitPoint(x: nx, y: 0.5),
            startRadius: 0, endRadius: 280)
        .frame(width: width, height: height)
        .scaleEffect(x: press.spread, y: 1, anchor: UnitPoint(x: nx, y: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .blendMode(.plusLighter)
        .opacity(press.glow)
        .allowsHitTesting(false)
    }
}

/// The docked island's content row: [artwork slot][title/artist][play][next].
///
/// It's a self-contained view so an in-island swipe re-renders ONLY this view,
/// not the whole full-player overlay. While swiping, the title/artist follow the
/// thumb; on release past a threshold it changes track and the title/artist
/// slide across (incoming always from the correct fixed side); otherwise they
/// spring back. Only a swipe animates — every other change (opening a song,
/// auto-advance, the buttons) swaps instantly. The traveling artwork is owned by
/// the parent, so this only reserves its slot.
private struct IslandContent: View {
    @ObservedObject var playback: PlaybackEngine
    var onExpand: () -> Void

    @State private var dragX: CGFloat = 0        // live thumb-follow (0 at rest)
    @State private var navDir = 1                // +1 next, -1 previous
    @State private var animateSwipe = false      // true only for a swipe commit
    @State private var commitStart: CGFloat = 0  // finger offset at commit
    @State private var zoneW: CGFloat = 220      // measured text-zone width
    @State private var commitTick = 0            // bumped to fire a haptic pop
    @State private var armedDir = 0              // side currently past the threshold

    /// Scales with Dynamic Type (10 at default) so we can subtract its growth from
    /// the title/artist line spacing — the two lines pull together at large sizes,
    /// where the stacked line-heights otherwise leave a big gap, while default
    /// sizes are left untouched.
    @ScaledMetric(relativeTo: .subheadline) private var typeUnit: CGFloat = 10
    private var titleArtistSpacing: CGFloat { max(-8, 1 - (typeUnit - 10)) }
    /// Upward nudge to visually centre the text glyphs (font line boxes pad the
    /// top more than the bottom). Scales with type: ~0.5pt at default, ~0.7pt at
    /// xxxLarge — where the ~4px imbalance is actually visible.
    @ScaledMetric(relativeTo: .subheadline) private var textVerticalNudge: CGFloat = 0.5

    var body: some View {
        HStack(spacing: 10) {
            // The artwork + titles zone owns all island touch handling (press,
            // tap-open, swipe). A single high-priority gesture claims the touch
            // immediately, so there's no scroll/tap disambiguation delay — press
            // feedback is instant. The play/next buttons are SIBLINGS (outside
            // this gesture) so they keep working.
            HStack(spacing: 10) {
                Color.clear.frame(width: Morph.islandArtSide, height: Morph.islandArtSide)

                VStack(alignment: .leading, spacing: titleArtistSpacing) {
                    IslandSlideText(text: playback.currentTrack?.title ?? "",
                                    dir: navDir, zoneW: zoneW, animate: animateSwipe,
                                    liveDrag: dragX, commitStart: commitStart,
                                    font: .subheadline.weight(.semibold), secondary: false)
                    IslandSlideText(text: playback.currentTrack?.artistName ?? "",
                                    dir: navDir, zoneW: zoneW, animate: animateSwipe,
                                    liveDrag: dragX, commitStart: commitStart,
                                    font: .caption2, secondary: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { g in
                    Color.clear.preference(key: IslandTitleWidthKey.self, value: g.size.width)
                })
                .clipped()
                // Nudge the text block up to correct font line-box asymmetry (the
                // glyphs sit slightly low inside their line boxes, so the visual
                // top gap is larger than the bottom). Scales with Dynamic Type, so
                // it's imperceptible at default and evens out the gap at xxxLarge.
                .offset(y: -textVerticalNudge)
                .onPreferenceChange(IslandTitleWidthKey.self) { zoneW = max($0, 1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .highPriorityGesture(islandGesture)

            Button { playback.togglePlayPause() } label: {
                Image(systemName: playback.snapshot.status == .playing ? "pause.fill" : "play.fill")
                    .font(.title3).frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                // Skip button runs the same slide as a swipe (from rest).
                commitTick &+= 1
                changeTrack(goNext: true, from: 0)
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3).frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!playback.snapshot.hasNext)
            .opacity(playback.snapshot.hasNext ? 1 : 0.4)
        }
        .padding(.leading, Morph.islandArtLeading)
        .padding(.trailing, Morph.islandContentPad)
        // Subtle "pop" the instant a swipe crosses the threshold / a commit fires.
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.9), trigger: commitTick)
        // Cap Dynamic Type so the compact island doesn't blow up at the large
        // accessibility sizes and overflow the pill — the same thing Apple does
        // for the tab bar / now-playing bar. Standard sizes still scale.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// Shared slide-commit used by both the swipe and the skip button. `startX`
    /// is where the outgoing line begins its exit (the finger's release position
    /// for a swipe, or 0 for a button press from rest).
    private func changeTrack(goNext: Bool, from startX: CGFloat) {
        commitStart = startX
        animateSwipe = true
        navDir = goNext ? 1 : -1
        if goNext { playback.next() } else { playback.previous() }
        withAnimation(islandTextSpring) { dragX = 0 }
        DispatchQueue.main.async { animateSwipe = false }
    }

    private static let commitDist: CGFloat = 55   // drag distance that arms a commit
    private static let tapSlop: CGFloat = 8         // movement under this = a tap
    private static let openDist: CGFloat = 40       // upward drag that opens the player

    /// One high-priority gesture for the artwork+titles zone: tap or swipe-up to
    /// open, horizontal swipe to change track. (Press-scale is handled separately
    /// by the parent's whole-pill touch-down reader.)
    private var islandGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let w = value.translation.width, h = value.translation.height
                guard abs(w) > abs(h), abs(w) > Self.tapSlop else {
                    if dragX != 0 { dragX = 0 }    // vertical / tap: don't follow
                    armedDir = 0
                    return
                }
                let canGo = w < 0
                    ? playback.snapshot.hasNext
                    : (playback.snapshot.hasPrevious || playback.snapshot.elapsed > 3)
                dragX = canGo ? w : w * 0.3
                var qual = 0
                if w <= -Self.commitDist, playback.snapshot.hasNext { qual = 1 }
                else if w >= Self.commitDist,
                        playback.snapshot.hasPrevious || playback.snapshot.elapsed > 3 { qual = -1 }
                if qual != 0, qual != armedDir { commitTick &+= 1 }
                armedDir = qual
            }
            .onEnded { value in
                let w = value.translation.width, h = value.translation.height
                let pw = value.predictedEndTranslation.width
                let ph = value.predictedEndTranslation.height
                armedDir = 0
                // Barely moved → tap → open.
                if abs(w) < Self.tapSlop, abs(h) < Self.tapSlop { onExpand(); return }
                if abs(w) > abs(h) {
                    let goNext = (w < -Self.commitDist || pw < -140) && playback.snapshot.hasNext
                    let goPrev = (w > Self.commitDist || pw > 140)
                        && (playback.snapshot.hasPrevious || playback.snapshot.elapsed > 3)
                    if goNext || goPrev {
                        commitTick &+= 1
                        changeTrack(goNext: goNext, from: dragX)
                    } else {
                        withAnimation(islandTextSpring) { dragX = 0 }
                    }
                } else {
                    // Vertical up → open.
                    if h < -Self.openDist || ph < -120 { onExpand() }
                    withAnimation(islandTextSpring) { dragX = 0 }
                }
            }
    }
}

/// A single line of island text.
///
/// At rest / while dragging it shows one string offset by `liveDrag` (the zone
/// follows the thumb). On a swipe-driven change (`animate`) it renders BOTH the
/// outgoing and incoming strings: the outgoing continues off from the finger's
/// release position (`commitStart`), the incoming ALWAYS enters from the correct
/// fixed side (`+zoneW` for next, `-zoneW` for previous) — independent of how far
/// you dragged, so a big swipe can't make it come from the wrong side. Both lines
/// use the same fixed sides, so title + artist stay in sync, and computing both
/// from the current `dir` in one pass prevents forward/back intersection. Any
/// non-swipe change swaps instantly. `dir`: +1 next (moves left), -1 previous.
private struct IslandSlideText: View {
    let text: String
    let dir: Int
    let zoneW: CGFloat
    let animate: Bool
    let liveDrag: CGFloat
    let commitStart: CGFloat
    let font: Font
    let secondary: Bool

    @State private var current: String
    @State private var outgoing: String?
    @State private var currentX: CGFloat = 0
    @State private var outgoingX: CGFloat = 0
    @State private var transitioning = false
    @State private var gen = 0

    init(text: String, dir: Int, zoneW: CGFloat, animate: Bool,
         liveDrag: CGFloat, commitStart: CGFloat, font: Font, secondary: Bool) {
        self.text = text; self.dir = dir; self.zoneW = zoneW; self.animate = animate
        self.liveDrag = liveDrag; self.commitStart = commitStart
        self.font = font; self.secondary = secondary
        _current = State(initialValue: text)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if let outgoing {
                label(outgoing).offset(x: outgoingX)
            }
            label(current).offset(x: transitioning ? currentX : liveDrag)
        }
        .onChange(of: text) { _, new in
            guard new != current else { return }
            guard animate else {                 // instant swap for non-swipe changes
                transitioning = false
                outgoing = nil
                current = new
                return
            }
            let enter = dir > 0 ? zoneW : -zoneW  // incoming always from the correct side
            let exit  = dir > 0 ? -zoneW : zoneW  // outgoing leaves the opposite side
            outgoing = current
            outgoingX = commitStart               // continue from the finger
            current = new
            currentX = enter
            transitioning = true
            gen += 1
            let token = gen
            // Defer one tick so the start offsets render, then slide to rest.
            DispatchQueue.main.async {
                withAnimation(islandTextSpring) {
                    currentX = 0
                    outgoingX = exit
                } completion: {
                    if gen == token { outgoing = nil; transitioning = false }
                }
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(font)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            // Pin each line to the zone width so long titles truncate to an
            // ellipsis up front (no full-width overlap that snaps on arrival).
            .frame(width: zoneW, alignment: .leading)
    }
}

/// Publishes the island text-zone width so both title and artist share one
/// travel distance.
private struct IslandTitleWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
    /// Raw spring value; may briefly leave [0,1]. Everything below uses the
    /// clamped `p`, so the spring's overshoot can't wobble the surface.
    let pRaw: CGFloat
    let dragY: CGFloat
    /// True during the collapse — enables the upward receive-bounce.
    let receiving: Bool
    /// Target state: `true` while expanded/opening, `false` while docked/collapsing.
    /// The mini controls are hidden whenever this is true, so the drawer opens
    /// OVER them (they never flash during an open).
    let isExpanded: Bool

    var p: CGFloat { min(max(pRaw, 0), 1) }

    // MARK: tunables
    static let islandHeight: CGFloat = BottomBar.islandHeight
    static let islandHMargin: CGFloat = BottomBar.hMargin       // pill inset from the screen edges
    static let islandContentPad: CGFloat = 12   // trailing inset (play/next side)
    static let islandArtLeading: CGFloat = 20   // leading inset — shifts art+titles right
    static let islandArtSide: CGFloat = 34      // was 42 (−8, smaller island artwork)
    static let islandArtRadius: CGFloat = 8
    static let islandBottomGap: CGFloat = BottomBar.islandGap    // gap between island and tab bar
    static let tabBarHeight: CGFloat = BottomBar.tabHeight       // floating tab-bar height
    static let expandedRadius: CGFloat = 24
    static let expandedArtRadius: CGFloat = 10
    static let bottomOverhang: CGFloat = 120    // surface runs off-screen at p=1
    static let receiveDepth: CGFloat = 4        // how far the island grows UP on the catch
    static let receiveZone: CGFloat = 0.18      // last fraction of collapse the bounce lives in
    static let miniFadeFull: CGFloat = 0.10     // p at/below which mini controls are fully shown
    static let miniFadeEnd: CGFloat = 0.34      // p at/above which mini controls are hidden
    static let expArtTopGap: CGFloat = 39       // grabber + gap above big artwork
    static let expArtMaxSide: CGFloat = 340

    // Island (collapsed) frame -----------------------------------------------
    // Anchored to the screen's bottom EDGE (matching the floating tab bar, which
    // sits `BottomBar.edgeMargin` from the edge), so the island floats a fixed
    // `islandBottomGap` above the tab bar regardless of the safe-area inset.
    var islandW: CGFloat { width - 2 * Self.islandHMargin }
    var islandBottom: CGFloat { height - BottomBar.edgeMargin - Self.tabBarHeight - Self.islandBottomGap }
    var islandTop: CGFloat { islandBottom - Self.islandHeight }
    var islandCenterY: CGFloat { islandBottom - Self.islandHeight / 2 }
    var islandLeft: CGFloat { (width - islandW) / 2 }
    var islandArtCenterX: CGFloat { islandLeft + Self.islandArtLeading + Self.islandArtSide / 2 }
    var islandRadius: CGFloat { Self.islandHeight / 2 }

    // Expanded artwork --------------------------------------------------------
    var expArtSide: CGFloat { min(width - 90, Self.expArtMaxSide) }
    var expArtCenterY: CGFloat { safeTop + Self.expArtTopGap + expArtSide / 2 }

    // Morphing surface --------------------------------------------------------
    // The surface is anchored by its BOTTOM edge: it lands exactly on the
    // island's bottom and NEVER moves below it (Apple pins the bottom and grows
    // the island UPWARD to receive the drawer). `receiveGrow` extends the TOP up
    // for the catch bounce; the bottom stays put.
    var surfaceW: CGFloat { lerp(islandW, width, p) }
    var surfaceHExpanded: CGFloat { height + Self.bottomOverhang }
    var baseH: CGFloat { lerp(Self.islandHeight, surfaceHExpanded, p) }
    /// Upward receive-bounce: a half-sine that is 0 at rest (p=0) and 0 at the
    /// zone edge, peaking in between — so as the drawer lands the island grows
    /// taller UPWARD by up to `receiveDepth`pt, then settles with no rebound and
    /// without ever moving the bottom edge. Active only during the collapse.
    var receiveGrow: CGFloat {
        guard receiving, p < Self.receiveZone else { return 0 }
        let u = Double(p / Self.receiveZone)   // 1 at zone edge → 0 at rest
        return Self.receiveDepth * CGFloat(sin(.pi * u))
    }
    var surfaceH: CGFloat { baseH + receiveGrow }
    /// Bottom edge. `dragY`/`p` are clamped ≥ their rest, so the bottom lands on
    /// islandBottom and never overshoots below (or lifts above) it.
    var bottomEdge: CGFloat { lerp(islandTop, 0, p) + max(0, dragY) + baseH }
    var surfaceCenterX: CGFloat { width / 2 }
    var surfaceCenterY: CGFloat { bottomEdge - surfaceH / 2 }
    var radius: CGFloat { lerp(islandRadius, Self.expandedRadius, p) }
    /// The surface's top edge WITHOUT the receive-grow. The mini controls ride
    /// this down into the island, so the grow can raise the glass above them
    /// without carrying them up.
    var baseTop: CGFloat { lerp(islandTop, 0, p) + max(0, dragY) }
    /// Center of the mini-control row: rides the top edge down, resting centered
    /// in the island at p=0 (baseTop == islandTop ⇒ islandCenterY).
    var miniCenterY: CGFloat { baseTop + Self.islandHeight / 2 }

    // Traveling artwork -------------------------------------------------------
    var artSide: CGFloat { lerp(Self.islandArtSide, expArtSide, p) }
    var artRadius: CGFloat { lerp(Self.islandArtRadius, Self.expandedArtRadius, p) }
    var artCenterX: CGFloat { lerp(islandArtCenterX, width / 2, p) }
    var artCenterY: CGFloat { lerp(islandCenterY, expArtCenterY, p) + max(0, dragY) }

    // Opacities ---------------------------------------------------------------
    // While a finger is down `p` is pinned at 1, so anything keyed purely on `p`
    // stays put during the drag and only animates on release — the mini controls
    // must NEVER appear until you let go.
    /// Mini controls are hidden while expanding/expanded (the drawer opens OVER
    /// them — they never flash on open). While docked/collapsing they fade in as
    /// the island forms: fully shown by `miniFadeFull`, gone by `miniFadeEnd`.
    var miniOpacity: CGFloat {
        guard !isExpanded else { return 0 }
        return clamp((Self.miniFadeEnd - p) / (Self.miniFadeEnd - Self.miniFadeFull))
    }
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

// MARK: - Instant touch-down reporting (UIKit)

private extension View {
    /// Reports touch-DOWN / move / up on this view **instantly**, with the touch
    /// point in this view's local coordinates. SwiftUI's own DragGesture /
    /// LongPressGesture wait to disambiguate a stationary finger (they only fire on
    /// movement), which lagged the island press-scale. This bridges a UIKit
    /// 0-duration long-press recognizer that fires on `touchesBegan` and, being
    /// non-cancelling + simultaneous, observes without stealing the touch from
    /// SwiftUI gestures/buttons underneath. No-op off iOS.
    @ViewBuilder
    func onTouchChanged(_ action: @escaping (Bool, CGPoint) -> Void) -> some View {
        #if canImport(UIKit)
        self.background(TouchDownReader(onChange: action))
        #else
        self
        #endif
    }
}

#if canImport(UIKit)
/// Installs a 0-duration `UILongPressGestureRecognizer` on the **window** so
/// touch-down is reported with zero delay, scoped to this view's bounds, without
/// consuming the touch (so the SwiftUI swipe/tap gestures and buttons still work).
///
/// It must attach to the window — not the representable's immediate `superview` —
/// because SwiftUI draws `Text`/`Image`/shapes into a shared backing view rather
/// than a `UIView` per element, so the immediate superview is usually NOT an
/// ancestor of the real touch target and the recognizer never fires. The window
/// is always an ancestor, and `shouldReceive` re-scopes delivery to this view's
/// bounds. `allowableMovement` is unbounded so the press survives a swipe.
private struct TouchDownReader: UIViewRepresentable {
    var onChange: (Bool, CGPoint) -> Void

    func makeUIView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        context.coordinator.onChange = onChange
        context.coordinator.view = view
        view.onEnterHierarchy = { [weak view] in
            guard let view, let window = view.window,
                  context.coordinator.recognizer == nil else { return }
            let press = UILongPressGestureRecognizer(
                target: context.coordinator, action: #selector(Coordinator.handle(_:)))
            press.minimumPressDuration = 0
            press.allowableMovement = .greatestFiniteMagnitude
            press.cancelsTouchesInView = false
            press.delaysTouchesBegan = false
            press.delaysTouchesEnded = false
            press.delegate = context.coordinator
            window.addGestureRecognizer(press)
            context.coordinator.recognizer = press
            context.coordinator.host = window
        }
        return view
    }

    func updateUIView(_ uiView: PassthroughView, context: Context) {
        context.coordinator.onChange = onChange
    }

    static func dismantleUIView(_ uiView: PassthroughView, coordinator: Coordinator) {
        if let r = coordinator.recognizer { coordinator.host?.removeGestureRecognizer(r) }
        coordinator.recognizer = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChange: ((Bool, CGPoint) -> Void)?
        weak var view: PassthroughView?
        weak var recognizer: UIGestureRecognizer?
        weak var host: UIView?

        @objc func handle(_ g: UILongPressGestureRecognizer) {
            guard let view else { return }
            let loc = g.location(in: view)
            switch g.state {
            case .began, .changed: onChange?(true, loc)
            case .ended, .cancelled, .failed: onChange?(false, loc)
            default: break
            }
        }

        // Run alongside SwiftUI's gestures rather than fighting them.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        // Only react to touches inside this view's own bounds (the island pill),
        // so touches elsewhere on the window are ignored.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view, view.window != nil else { return false }
            return view.bounds.contains(touch.location(in: view))
        }
    }

    /// Transparent, never the hit-test target — it exists only as a bounds anchor
    /// for the window recognizer's `shouldReceive` scoping.
    final class PassthroughView: UIView {
        var onEnterHierarchy: (() -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onEnterHierarchy?() }
        }
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }
}
#endif

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
