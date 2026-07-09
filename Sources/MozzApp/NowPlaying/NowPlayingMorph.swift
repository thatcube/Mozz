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
    var playback: PlaybackEngine
    @ObservedObject var ui: PlayerUIModel
    /// Tab-bar minimize progress (0 = docked island above the bar, 1 = island
    /// dropped into the bar's centre pill between the split blobs). Scroll-driven.
    var minimize: CGFloat = 0

    /// 0 = docked island, 1 = full drawer. Animated by the open/collapse springs.
    @State private var p: CGFloat = 0
    /// Live drag translation (points) while the open drawer is being pulled down.
    @State private var dragY: CGFloat = 0
    /// True once a queue top-overscroll has committed to dismissing the drawer, so
    /// trailing overscroll callbacks during teardown don't re-inflate `dragY`.
    @State private var dismissingViaPull = false
    /// True only during the collapse, so the downward receive-bounce fires on the
    /// way into the island and never while opening or dragging.
    @State private var receiving = false
    /// Live island-press state: `pressed` drives the whole-island scale, `location`
    /// (pill-local) drives the finger-following glow. Kept in an `@Observable` so
    /// the high-frequency `location` updates re-render ONLY the lightweight glow
    /// layer — not this container (which builds the drawer's up-next list).
    @State private var press = IslandPressState()

    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Single source of truth for the current track's rating on the player
    /// (ratings/Plex path). Lifted here so the collapsed star, the hold-drag
    /// reveal, and the root-hosted sticky bubble all share it — rating writes
    /// don't propagate back through the playback engine, so the view layer owns
    /// the optimistic value. Reseeded when the track changes.
    @State private var playerRating: Double?
    /// Whether the sticky tap picker (hosted at the morph root) is open.
    @State private var ratingPickerOpen = false
    /// Whether the queue panel (Continue Playing + History) is showing in place of
    /// the now-playing hero. Only meaningful while fully expanded; reset on collapse.
    @State private var queueOpen = false
    /// Queue-open animation progress (0 = hero cover big-center, 1 = cover docked
    /// into the queue's compact-header thumbnail slot). Driven as a spring alongside
    /// `queueOpen` so the single traveling artwork *slides* into place instead of the
    /// big cover cross-fading with a separate thumbnail.
    @State private var queueP: CGFloat = 0
    /// A SECOND, slower open/close progress that drives ONLY the queue body's rise +
    /// fade (see `PlayerQueuePanel.bodyP`). Animated alongside `queueP` in
    /// `driveQueue()` but on `queueBodySpring` (a gentler, longer response) for the
    /// OPEN so the body glides into place after the fast artwork/card hand-off; the
    /// CLOSE reuses the fast `queueSpring` so it retracts in lock-step with `queueP`
    /// and the existing unmount-on-completion stays correct.
    @State private var queueBodyP: CGFloat = 0
    /// A THIRD open/close progress that drives ONLY the hero row's lift + fade
    /// (`HeroLift` / `RangeFadeOut` in `titleRow`). Animated alongside `queueP` in
    /// `driveQueue()` but on `queueHeroSpring` (a slower response) for the OPEN so the
    /// hero title/artist visibly *travels* up and out at its own gentler pace, decoupled
    /// from the fast artwork dock. The CLOSE reuses the fast `queueSpring` so the hero
    /// snaps back in lock-step with the rest.
    @State private var queueHeroP: CGFloat = 0
    /// True only once the queue-open spring has fully settled (and false the moment
    /// a close/open starts, and while the queue is closed). Gates the seamless
    /// hand-off between the traveling artwork/star (shown during the transition)
    /// and the card's own scrolling artwork/star (shown at rest).
    @State private var queueSettled = false
    /// Bumped every time the queue opens, so the panel resets its scroll to the
    /// now-playing card at the top (never left showing History or scrolled) on
    /// each reopen — not just the first appearance.
    @State private var queueOpenNonce = 0
    /// Monotonic id bumped on every `setQueue` call. Each open/close spring's
    /// `completion:` captures the id and only applies its terminal state if it's still
    /// current — so when you toggle the queue faster than the spring settles, a stale
    /// completion from the superseded transition can't fire out of order and strand
    /// the view in a corrupt state (e.g. `queueSettled == true` while `queueOpen ==
    /// false`, which hides both the traveling AND the card artwork → blank drawer).
    @State private var queueTransition = 0
    /// The user's *latest* queue intent (true = open, false = close), set
    /// synchronously in `setQueue`. Distinct from `queueOpen` (the mount flag, which
    /// lingers true through a close until its spring completes). It's the single
    /// source of truth for direction: the toggle button and `driveQueue()` read it,
    /// and flipping it fires `.onChange(of: queueWantsOpen)` which deterministically
    /// animates `queueP` to the latest target — so no fast toggle can strand the hero
    /// row (previously a late `onAppear` could resurrect a superseded open and pin
    /// `queueP` at 1: hero stuck at the top, queue logically closed → next open
    /// teleported).
    @State private var queueWantsOpen = false
    /// Whether `queueTop` was *already mounted* when the current open began. A fresh
    /// open (panel was unmounted) is kicked by `queueTop.onAppear` so it animates
    /// from a committed q=0 frame (no snap); a re-open *while still mounted* (during a
    /// close) is kicked by `.onChange(of: queueWantsOpen)` instead, since `onAppear`
    /// won't fire again. This flag routes each open to exactly one of those.
    @State private var queueWasMounted = false
    /// True only once the expand spring has fully settled (and false the moment a
    /// collapse/expand starts). Gates expensive-at-rest effects — the artwork's
    /// soft shadow and the backdrop's live drift — OFF during the transition, so
    /// the spring settles without per-frame shadow re-rasterization or a competing
    /// 30fps mesh tick. That's what removes the "settling feels laggy" hitch.
    @State private var settled = false
    #if canImport(UIKit)
    /// Live current-output-route (device name + icon) for the AirPlay control.
    @StateObject private var routeMonitor = AudioRouteMonitor()
    #endif
    /// Live Low Power Mode state — used to keep the cheaper mid-morph surface even
    /// after settling on throttled devices (see `useGlassSurface`).
    @StateObject private var power = LowPowerModeObserver()

    @AppStorage(PlayerBackgroundStyle.storageKey) private var bgStyleRaw = PlayerBackgroundStyle.default.rawValue
    /// User setting: use Liquid Glass chrome for the player (default on). When off,
    /// the player uses a cheaper opaque chrome surface.
    @AppStorage("mozz.liquidGlass") private var liquidGlassEnabled = true
    // Observed so the island/player chrome token re-resolves live when the dark
    // flavor (Dim↔Black) toggles; see `MozzScreenBackground`.
    @AppStorage(Color.MozzDarkStyle.storageKey) private var darkStyleRaw = Color.MozzDarkStyle.default.rawValue
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Colors sampled from the current artwork for the adaptive backdrop.
    @State private var artGrid: ArtworkColorGrid?

    private var bgStyle: PlayerBackgroundStyle {
        PlayerBackgroundStyle(rawValue: bgStyleRaw) ?? .default
    }
    /// The color scheme the player surface presents its content in: forced dark on
    /// the artwork/OLED backdrops (the surface is dark regardless of the app's
    /// appearance), or the system scheme in `theme` mode. Applied to the drawer body
    /// AND the root-level traveling star cluster so the star/overflow keep the same
    /// on-surface color as they hand off between the two (otherwise the traveling
    /// cluster — which lives outside the surface — would resolve `.primary` to black
    /// on a light-appearance device and pop to white the instant the card takes over).
    private var surfaceColorScheme: ColorScheme {
        bgStyle == .theme ? systemColorScheme : .dark
    }
    /// Identity for the palette task: re-derive when the artwork changes.
    private var artworkToken: String {
        (playback.currentTrack?.artwork?.key) ?? (playback.currentTrack?.id ?? "none")
    }
    /// Identity for artwork prefetching: changes when the current track or the
    /// next few up-next tracks change, so we warm their covers ahead of a skip.
    private var prefetchToken: String {
        ([playback.currentTrack?.id] + playback.upNext.prefix(3).map { $0.id })
            .compactMap { $0 }.joined(separator: "|")
    }

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
                              pRaw: p, receiving: receiving,
                              isExpanded: ui.isFullPresented, minimize: minimize,
                              queue: queueP)
                ZStack(alignment: .topLeading) {
                    surface(m)
                    // Enlarged, invisible tap target so edge taps open the player
                    // instead of "falling through" to the page/tab-bar behind. It
                    // sits BELOW IslandContent (so the play/pause/next buttons and
                    // the swipe zone keep priority) but consumes taps in the margin
                    // around the pill. Docked state only.
                    if m.p < 0.5 {
                        Color.clear
                            .frame(width: m.islandTapW, height: m.islandTapH)
                            .contentShape(Rectangle())
                            .onTapGesture { ui.isFullPresented = true }
                            .position(x: m.surfaceCenterX, y: m.islandTapCenterY)
                    }
                    // Finger-following specular glow: a soft highlight on the glass
                    // that tracks the touch point, like Apple's interactive Liquid
                    // Glass. It reads `press.location`, so tracking the finger
                    // re-renders ONLY this layer, never the container. (We render
                    // our own instead of `.glassEffect(.interactive())` because that
                    // API adds its own press-scale that fought our unified scale.)
                    if m.p < 0.5 {
                        IslandGlow(press: press, width: m.islandDropW,
                                   height: m.islandDropH, radius: m.radius)
                            .frame(width: m.islandDropW, height: m.islandDropH)
                            .position(x: m.surfaceCenterX, y: m.miniCenterY)
                            .allowsHitTesting(false)
                    }
                    // The island content is a self-contained subview owning its own
                    // swipe/slide state, so swiping to change tracks re-renders ONLY
                    // the island — not the whole full-player overlay (that was a big
                    // source of jank). The parent just places it: it rides the
                    // surface's top edge DOWN into the island on collapse
                    // (miniCenterY), is hidden while expanding (miniOpacity), and
                    // shrinks into the centre pill (islandDropW) when minimized.
                    IslandContent(playback: playback, onExpand: { ui.isFullPresented = true },
                                  collapse: m.dropT, pillWidth: m.islandDropW,
                                  maxPillWidth: m.islandW)
                        .frame(width: m.islandDropW, height: m.islandDropH)
                        // Clip the mini controls to the pill shape so nothing
                        // renders past its edges (top included) during the collapse
                        // morph — the text/buttons dissolve at the pill boundary
                        // instead of poking out above it.
                        .clipShape(Capsule())
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
                        .frame(width: m.islandDropW, height: m.islandTapH)
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
                        .position(x: m.surfaceCenterX, y: m.islandTapCenterY)
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
                // Sticky rating bubble (ratings/Plex path): hosted here at the
                // morph root — a screen-spanning ancestor — so it can catch
                // outside taps and animate its own height (a system popover can't).
                .overlayPreferenceValue(PlayerRatingAnchorKey.self) { anchor in
                    ratingPickerOverlay(anchor: anchor, geo: geo)
                }
                .onChange(of: playback.currentTrack?.id) { _, _ in
                    playerRating = playback.currentTrack?.rating
                    ratingPickerOpen = false
                }
                .onChange(of: ui.isFullPresented) { _, open in
                    if !open {
                        ratingPickerOpen = false
                    }
                }
                .onAppear { playerRating = playback.currentTrack?.rating }
                // Derive the adaptive backdrop palette from the artwork; resolve
                // synchronously if cached (correct on first frame), else crossfade.
                .task(id: artworkToken) {
                    if let cached = ArtworkPalette.cachedGrid(
                        for: playback.currentTrack?.artwork, backend: env.active?.backend, seed: artworkToken) {
                        artGrid = cached
                    } else {
                        let g = await ArtworkPalette.grid(
                            for: playback.currentTrack?.artwork, backend: env.active?.backend, seed: artworkToken)
                        withAnimation(.easeInOut(duration: 0.5)) { artGrid = g }
                    }
                }
                // Warm the current + upcoming covers at the player's pixel size so
                // skipping finds the artwork already cached — no placeholder flash.
                .onChange(of: prefetchToken, initial: true) { _, _ in
                    prefetchNearbyArtwork()
                }
                // Live finger translation for drag-to-dismiss, applied as ONE
                // container offset here — isolated behind a binding so reading
                // `dragY` re-runs only this modifier, never the parent body. The
                // morph geometry above is dragY-free, so a drag no longer rebuilds
                // the surface + the whole queue subtree every frame (which read as
                // stutter). `$dragY` is a binding, so the parent body takes no
                // dependency on the value and isn't invalidated as it changes.
                .modifier(DragTranslate(dragY: $dragY))
            }
            .ignoresSafeArea()
        }
    }

    /// Prefetch the current + next few covers at the player's pixel size (matching
    /// `MorphArtwork`: base 340 × 2 = 680) so a skip finds the art already cached
    /// and renders it on the first frame instead of flashing a placeholder.
    private func prefetchNearbyArtwork() {
        guard let backend = env.active?.backend else { return }
        let tracks = [playback.currentTrack].compactMap { $0 } + playback.upNext.prefix(3)
        for track in tracks {
            if let artwork = track.artwork, let url = backend.artworkURL(for: artwork, size: 680) {
                ArtworkImageLoader.shared.prefetch(url)
            }
        }
    }

    /// The root-hosted sticky rating bubble + a full-screen tap-catcher, anchored
    /// above the player's rating star.
    @ViewBuilder
    private func ratingPickerOverlay(anchor: Anchor<CGRect>?, geo: GeometryProxy) -> some View {
        if ratingPickerOpen, let anchor, let track = playback.currentTrack {
            let rect = geo[anchor]
            let gap: CGFloat = 6
            let bottomSpace = max(0, geo.size.height - (rect.minY - gap))
            ZStack {
                // Tap-catcher: dismiss on any tap outside the bubble.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { closeRatingPicker() }
                    .accessibilityHidden(true)
                // Bottom-pinned bubble: grows upward as the Clear row appears, its
                // tail staying on the star. No height measurement needed.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    RatingBubbleContent(rating: playerRating) { setPlayerRating($0, track: track) }
                        .padding(.bottom, RatingTuning.revealTailHeight)
                        .glassBackground(TailedBubble())
                        .fixedSize()
                        .offset(x: rect.midX - geo.size.width / 2)
                        // Native popover feel: scale-pop UP OUT OF the tail (the
                        // anchor at the star) on present; a quick pure fade on
                        // dismiss (no scale/slide).
                        .transition(reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .scale(scale: 0.82, anchor: .bottom).combined(with: .opacity),
                                removal: .opacity))
                        .accessibilityAddTraits(.isModal)
                        .accessibilityAction(.escape) { closeRatingPicker() }
                    Color.clear.frame(height: bottomSpace).allowsHitTesting(false)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .ignoresSafeArea()
        }
    }

    private func setPlayerRating(_ value: Double?, track: Track) {
        playerRating = value
        Task { await env.setRating(value, track: track) }
    }

    private func closeRatingPicker() {
        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.16)) { ratingPickerOpen = false }
    }

    // MARK: Surface (Liquid Glass background + fading drawer body)

    /// Whether the player uses real Liquid Glass (blur) vs a cheap opaque chrome
    /// surface. Decided per MODE and held CONSTANT through the morph (never swapped
    /// mid-animation — that black↔glass flip was the jarring part). Glass is the
    /// default; it drops to solid when the user turns it off, in Low Power Mode, or
    /// with Reduce Transparency on (accessibility) — all cases where a consistent
    /// opaque surface is smoother / preferred.
    private var useGlassSurface: Bool {
        liquidGlassEnabled && !power.isLowPower && !reduceTransparency
    }

    /// Opaque chrome surface used when glass is off — a theme-aware elevated color
    /// that matches the surrounding nav, not pure black.
    private var cheapSurfaceFill: Color { .mozzChrome }

    private func surface(_ m: Morph) -> some View {
        ZStack(alignment: .top) {
            // Opaque panel for the expanded drawer. A frosted material base (so
            // mid-collapse the shrinking bubble stays translucent, revealing the
            // Liquid Glass behind) with the artwork-adaptive backdrop painted on
            // top. Both fade out together via `solidBgOpacity` during the collapse.
            RoundedRectangle(cornerRadius: m.radius, style: .continuous)
                .fill(useGlassSurface ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(cheapSurfaceFill))
                .overlay {
                    PlayerBackdrop(style: bgStyle, grid: artGrid, animated: settled && useGlassSurface)
                }
                .clipShape(RoundedRectangle(cornerRadius: m.radius, style: .continuous))
                .opacity(m.solidBgOpacity)

            drawerBody(m)
                .frame(width: m.width, height: m.surfaceHExpanded, alignment: .top)
                // Drag-to-dismiss anywhere the content doesn't claim the touch:
                // a clear, hit-testable layer directly behind the body. Interactive
                // children (buttons, scrubber, the queue scroll) sit in front and
                // consume their own gestures, so only the non-interactive gaps fall
                // through to this dismiss drag. (The queue's own top-overscroll →
                // dismiss is handled separately via onPull.)
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(dragGesture)
                        .allowsHitTesting(m.p > 0.5)
                )
                .opacity(m.bodyOpacity)
                .allowsHitTesting(m.p > 0.5)
                // On the adaptive/OLED backdrop the surface is dark-colored, so
                // render the drawer content light (matches the detail pages). In
                // `theme` mode it follows the system scheme.
                .environment(\.colorScheme, surfaceColorScheme)
        }
        .frame(width: m.surfaceW, height: m.surfaceH, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: m.radius, style: .continuous))
        .liquidGlass(radius: m.radius, enabled: useGlassSurface, fallbackFill: cheapSurfaceFill)
        .position(x: m.surfaceCenterX, y: m.surfaceCenterY)
    }

    // MARK: Traveling artwork (single image, big-center ⇄ small-left)

    private func travelingArtwork(_ m: Morph) -> some View {
        // Apple-Music-style paused shrink: at rest the cover sits 25% smaller,
        // growing to full size while playing. Only in the expanded player (scaled
        // by `m.p`) so the island/mini art is unaffected — and unwound (×(1−q)) as
        // the cover docks into the fixed-size queue thumbnail slot, so it fills that
        // slot exactly instead of sitting under-sized.
        let isPlaying = playback.snapshot.status == .playing || playback.snapshot.status == .buffering
        let pausedScale = 1 - Self.pausedArtShrink * m.p * (1 - m.q) * (isPlaying ? 0 : 1)
        // Shadow only once settled, at a CONSTANT blur radius: an animated blur
        // radius re-rasterizes the shadow every frame (a classic hitch during the
        // expand). Gated on `settled` + faded via color opacity, the shadow costs
        // nothing during the transition and rasterizes once at rest. Dropped while
        // the queue is open — the compact thumbnail carries no drop shadow.
        let showShadow = settled && !queueOpen
        return MorphArtwork(track: playback.currentTrack, side: m.artSide, cornerRadius: m.artRadius)
            .scaleEffect(pausedScale)
            .shadow(color: .black.opacity(showShadow ? 0.35 : 0), radius: 16, y: 8)
            .position(x: m.artCenterX, y: m.artCenterY)
            // Hidden once the queue settles: the card's own (scrolling) artwork
            // takes over at the identical slot, so it can scroll & clip with the
            // list. Instant swap at a coincident position → no pop.
            .opacity(queueSettled ? 0 : 1)
            .allowsHitTesting(false)
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.72),
                       value: isPlaying)
            .animation(.easeOut(duration: 0.3), value: showShadow)
    }

    // MARK: Star + overflow cluster (rating/like + per-track menu)

    /// The star (rating on Plex / like on Jellyfin) + overflow cluster. Rendered in
    /// two places — the hero title row and the queue card's trailing slot — with a
    /// directional move-up + cross-fade between them (no single traveling copy).
    @ViewBuilder
    private func starOverflowCluster(interactive: Bool, emitsAnchor: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let track = playback.currentTrack {
                if env.usesRatings {
                    FluidRatingControl(
                        rating: $playerRating,
                        onSet: { setPlayerRating($0, track: track) },
                        onRequestPicker: {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.76)) { ratingPickerOpen = true }
                        },
                        emitsAnchor: emitsAnchor
                    )
                } else {
                    PlayerLikeControl(track: track)
                }
            }
            // Per-track overflow — shares the row/detail action set (P1 factory).
            if let track = playback.currentTrack {
                Menu {
                    TrackActionButtons(track: track, downloadState: nil, internalId: nil, surface: .player)
                } label: {
                    AppIcon.overflow.styled(size: PlayerControlMetrics.utilityGlyph)
                        .foregroundStyle(.primary)
                        .playerHitTarget()
                }
                .accessibilityLabel("More actions")
            }
        }
        .allowsHitTesting(interactive)
    }

    /// How much the cover shrinks when paused (fraction), in the expanded player.
    private static let pausedArtShrink: CGFloat = 0.25

    // MARK: Drawer body (everything below the top edge; fades + clips on collapse)

    private func drawerBody(_ m: Morph) -> some View {
        VStack(spacing: 0) {
            // Top region: the now-playing hero and the queue occupy the same
            // space and cross-fade. The queue is an overlay on the hero so it
            // inherits the hero's fixed height — it never competes with the
            // trailing Spacer for vertical space, so the controls below never
            // shift and the queue list isn't squished.
            header(m)
                .allowsHitTesting(!queueOpen)
                .overlay(alignment: .top) {
                    if queueOpen {
                        // No `.transition` here: the entrance is driven entirely
                        // by the internal `q`-modifiers (the card title/star
                        // cross-fade rise and the body's rise-from-below-the-
                        // scrubber). `setQueue(open:)` mounts this at q=0 — where
                        // those are already offset-below and faded to zero — then
                        // springs q→1 on the next runloop so they interpolate in
                        // rather than snapping to their resting state.
                        queueTop(m)
                    }
                }
                // Deterministic driver for every toggle except a fresh open (which
                // `queueTop.onAppear` handles). Attached to the always-mounted header
                // so it fires reliably on each intent flip — close, and re-open while
                // the panel is still mounted mid-close.
                .onChange(of: queueWantsOpen) { _, wantsOpen in
                    if wantsOpen && !queueWasMounted { return }  // fresh open → onAppear
                    driveQueue()
                }

            scrubber
                .padding(.horizontal, 32)
                .padding(.top, 22)
            transport
                .padding(.top, 54)
            if let track = playback.currentTrack {
                formatBadge(track: track).padding(.top, 10)
            }
            Spacer(minLength: 8)
            VStack(spacing: 10) {
                bottomButtonRow
                    .padding(.horizontal, 48)
                #if canImport(UIKit)
                routeLabel
                #endif
            }
            // The surface overhangs the screen by `bottomOverhang`; lift the
            // row out of that off-screen region so it sits at the safe-area
            // bottom rather than 120pt below it.
            .padding(.bottom, Morph.bottomOverhang + m.safeBottom + 12)
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

            titleRow(m)
                .padding(.top, 22)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }

    /// The hero's now-playing metadata: title/artist on the left, the interactive
    /// star + overflow cluster on the right. On queue-open the WHOLE row lifts up and
    /// fades out early as one unit (Apple-style), while the card's own title + star
    /// fade in below by the docked artwork — a directional cross-fade, no single
    /// traveling copy.
    private func titleRow(_ m: Morph) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(playback.currentTrack?.title ?? "")
                    .font(.title2.bold()).lineLimit(1)
                Text(playback.currentTrack?.artistName ?? "")
                    .font(.title3).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            // The real interactive star/like + overflow while the queue is closed.
            // Handed off (by cross-fade) to the card's own cluster once open.
            starOverflowCluster(interactive: !queueOpen, emitsAnchor: !queueOpen)
        }
        .font(.title3)
        // Lift the whole row UP a long way as the queue opens — it should travel
        // toward the card row (roughly halfway or more up the screen), not just
        // nudge. It stays fully visible through the early climb, then fades out
        // across a back-loaded window (RangeFadeOut) so you actually see it move
        // before it hands off to the card row catching below it.
        .modifier(HeroLift(progress: queueHeroP,
                           start: Self.heroLiftStart,
                           end: Self.heroLiftEnd,
                           distance: Self.heroRowLift))
        .modifier(RangeFadeOut(progress: queueHeroP,
                               start: Self.heroFadeStart,
                               end: Self.heroFadeEnd))
    }

    /// Progress (in q, 0…1) by which the hero row completes its full upward lift.
    /// Below this it climbs `heroRowLift * (q / heroLiftEnd)`; past it the row holds
    /// at full lift — invisible by then anyway, since it has faded out. This makes the
    /// *duration* of the visible climb tunable independently of the whole transition:
    /// with the old `q`-linear travel the row only reached ~half its lift before
    /// fading, so most of the climb was never seen. Applied via the `HeroLift`
    /// Animatable modifier so SwiftUI samples the clamped ramp per frame (a plain
    /// offset from animated state would linearize the endpoints and skip the corner).
    private static let heroLiftEnd: CGFloat = 0.9

    /// Progress (in `queueHeroP`, 0…1) at which the hero row BEGINS its upward lift.
    /// Below this it holds in place (still at full opacity), then climbs over
    /// [`heroLiftStart`, `heroLiftEnd`] — a delayed rise so the row sits a beat before
    /// travelling. Keep below `heroFadeEnd` or the climb happens after the row has
    /// already faded out (and so is never seen). Gated via the `HeroLift` Animatable
    /// modifier so the hold corner is sampled per frame. `0` = no delay (lift from the
    /// start).
    private static let heroLiftStart: CGFloat = 0

    /// How far the hero title/star row lifts as the queue opens (points). Large on
    /// purpose: the row should visibly climb toward the card row, not just fade in
    /// place. It fades out (see `heroFadeEnd`) before reaching the full lift.
    private static let heroRowLift: CGFloat = 360

    /// The hero row holds full opacity until `heroFadeStart`, then fades 1→0 by
    /// `heroFadeEnd` — a back-loaded fade so it climbs (staying visible) before
    /// dissolving, handing off to the card row + the queue body rising up beneath.
    private static let heroFadeStart: CGFloat = 0.56
    private static let heroFadeEnd: CGFloat = 0.92

    /// How far the card's title/artist + star rise into place from just below their
    /// own final spot as the queue opens (points). Short, directional cross-fade —
    /// they "catch" the hero row fading out above them. The card artwork does NOT
    /// use this (it docks via the traveling artwork), and the queue body's much
    /// larger rise-from-the-scrubber lives in `PlayerQueuePanel`.
    private static let cardRowRise: CGFloat = 80

    /// Where the card's title/star begin their entrance along the open progress
    /// (0…1) — now gates BOTH the rise (`GatedRise`) and the fade (`LateFade`), so the
    /// row holds down + invisible until here, then rises + fades in together after the
    /// hero row has mostly cleared (a delayed hand-off rather than a slide already
    /// underway).
    private static let cardFadeStart: CGFloat = 0.7

    /// The queue view shown in place of the hero when `queueOpen`: a pinned
    /// grabber over the scrollable History / now-playing card / Continue-Playing
    /// list. The card scrolls as one unit with the list (see `PlayerQueuePanel`).
    private func queueTop(_ m: Morph) -> some View {
        VStack(spacing: 0) {
            Capsule().fill(.white.opacity(0.5)).frame(width: 40, height: 5)
                .padding(.top, m.safeTop + 8)
                .contentShape(Rectangle())
                .gesture(dragGesture)

            PlayerQueuePanel(
                playback: playback,
                queueP: m.q,
                bodyP: queueBodyP,
                bodyRise: queueBodyRise(m),
                resetToken: queueOpenNonce,
                onSelect: { orderPosition in playback.jump(toOrderPosition: orderPosition) },
                onClearHistory: { withAnimation(.easeInOut(duration: 0.25)) { playback.clearHistory() } },
                onClearQueue: { withAnimation(.easeInOut(duration: 0.25)) { playback.clearUpNext() } },
                onPull: { raw in handleQueuePull(raw) },
                onPullEnd: { raw, velocity in handleQueuePullEnd(raw, velocity) },
                card: { nowPlayingCard(m) },
                queueControls: { shuffleRepeatPills }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Fresh open only: this fires once the subtree has mounted + laid out at q=0,
        // so the whole entrance (artwork dock, card cross-fade, body rise) interpolates
        // 0→1 from a committed frame instead of snapping. Re-opens while still mounted
        // are driven by `.onChange(of: queueWantsOpen)` (onAppear won't refire).
        .onAppear { driveQueue() }
    }

    /// How far the queue body (pills + "Queue" header + Continue-Playing list) drops
    /// below its resting spot at q=0, so it rises up from below the scrub bar as the
    /// queue opens. Derived from the drawer's own geometry — the header is dominated
    /// by the big artwork, and the scrubber sits just beneath it — so this is a solid
    /// device-scaled proxy for "the panel's height" that's known SYNCHRONOUSLY at
    /// mount. (The panel can't measure its own viewport in time: it remounts on every
    /// open and its GeometryReader reads 0 for the first frames, which is exactly what
    /// left the body pinned in place.) Overshoot is harmless — the panel is clipped,
    /// so a body that starts a little past the scrubber just rises in from off-screen.
    private func queueBodyRise(_ m: Morph) -> CGFloat {
        m.safeTop + 45 + m.expArtSide
    }

    /// The now-playing card at the center of the queue: artwork + title/artist +
    /// star/overflow. (The shuffle/repeat pills sit just below it in the queue's
    /// sticky controls block, not in this card.) The artwork and star are reserved
    /// (empty) slots during the open transition — the traveling artwork/star cover
    /// them — and become the card's own scrolling copies once the queue settles.
    private func nowPlayingCard(_ m: Morph) -> some View {
        HStack(spacing: 12) {
            // Card's own artwork — visible once settled so it scrolls & clips
            // with the list; hidden during the transition (the traveling
            // artwork covers this exact slot). Tapping it (once settled) closes
            // the queue and returns to the now-playing hero.
            MorphArtwork(track: playback.currentTrack,
                         side: Morph.queueArtSide, cornerRadius: Morph.queueArtRadius)
                .opacity(queueSettled ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture { if queueSettled { setQueue(open: false) } }
                .allowsHitTesting(queueSettled)
            VStack(alignment: .leading, spacing: 2) {
                Text(playback.currentTrack?.title ?? "")
                    .font(.headline).lineLimit(1)
                Text(playback.currentTrack?.artistName ?? "")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            // Rise into place from a little below as the queue opens, so the
            // card titles appear to "catch" the hero titles fading out above
            // them — a directional cross-fade, not a plain fade. The fade-in is
            // DELAYED (LateFade) so it starts around the time the hero row has
            // mostly cleared, overlapping rather than waiting for it to finish.
            .modifier(GatedRise(progress: m.q, start: Self.cardFadeStart, distance: Self.cardRowRise))
            .modifier(LateFade(progress: m.q, start: Self.cardFadeStart))
            Spacer(minLength: 8)
            // Card's own star + overflow at its final resting slot. Rises + fades
            // in on the SAME delayed curve and SAME upward offset as the card
            // title, so the title/artist + star move up and fade in as ONE row —
            // the top half of the directional cross-fade with the hero cluster
            // lifting away above. Interactive + owns the rating anchor only once
            // settled (the hero cluster owns it while the queue is closed, so
            // exactly one anchor is ever published).
            starOverflowCluster(interactive: queueSettled, emitsAnchor: queueSettled)
                .modifier(GatedRise(progress: m.q, start: Self.cardFadeStart, distance: Self.cardRowRise))
                .modifier(LateFade(progress: m.q, start: Self.cardFadeStart))
        }
        .padding(.top, 8)
    }

    /// Shuffle + repeat pills directly beneath the current song.
    private var shuffleRepeatPills: some View {
        let snapshot = playback.snapshot
        return HStack(spacing: 12) {
            QueuePill(glyph: AppIcon.shuffle, label: "Shuffle",
                      active: snapshot.isShuffled) {
                playback.toggleShuffle()
                // Toggling shuffle rewrites the play order (enabling pins the
                // current track to the front so history empties; disabling
                // restores it), which swings `detentTop`. Re-dock so the current
                // song snaps back to the top with the fresh order instead of
                // leaving the user stranded mid-list.
                queueOpenNonce &+= 1
            }
            QueuePill(glyph: AppIcon.repeatTracks,
                      label: snapshot.repeatMode == .one ? "Repeat One" : "Repeat",
                      active: snapshot.repeatMode != .off,
                      badge: snapshot.repeatMode == .one ? "1" : nil) {
                playback.cycleRepeatMode()
            }
        }
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

    /// Live top-pull from the queue: once the list is at its very top and the
    /// finger keeps dragging down, the whole player drawer follows the finger 1:1
    /// (the queue cancels its own rubber-band so the content stays rigid and only
    /// the drawer moves), toward dismissal.
    private func handleQueuePull(_ pull: CGFloat) {
        guard p > 0.5, !dismissingViaPull else { return }
        dragY = pull
    }

    /// Finger-lift while pulling the queue's top down: dismiss if pulled far or
    /// flung down hard (real velocity, points/second); otherwise spring the drawer
    /// back to rest.
    private func handleQueuePullEnd(_ pull: CGFloat, _ velocity: CGFloat) {
        guard p > 0.5, !dismissingViaPull else { return }
        if pull > 120 || velocity > 800 {
            dismissingViaPull = true
            ui.isFullPresented = false
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { dragY = 0 }
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
            // Clear the pull-dismiss latch on (re)present; it stays set through the
            // whole collapse so trailing overscroll callbacks can't re-inflate dragY.
            dismissingViaPull = false
            receiving = false
            settled = false
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                p = 1; dragY = 0
            } completion: {
                // Only now (fully at rest) enable the shadow + backdrop drift.
                settled = true
            }
        } else {
            receiving = true
            settled = false
            // Invalidate any in-flight queue open/close completion: the collapse below
            // drives `queueP` to 0 and its own completion resets the queue flags, so a
            // stale queue completion firing afterwards must not flip `queueSettled`
            // back on (which would blank the drawer on the next expand).
            queueTransition &+= 1
            // NOTE: don't reset `queueWantsOpen` here — it feeds `.onChange`, and
            // flipping it now would kick `driveQueue()` which (seeing queueP heading
            // to 0) would unmount `queueTop` at the START of the collapse. We keep it
            // true through the collapse (queueP is driven to 0 by this spring) and
            // reset it in the completion, once fully collapsed.
            // Keep `queueSettled` TRUE through the collapse: the card's own in-flow
            // star + artwork then ride down and fade WITH the drawer body (which is
            // clipped to the surface). Flipping it false here would revive the
            // root-level traveling star and, as `queueP`→0, send it flying UP toward
            // the hero slot — off the top of the screen, since the traveling cluster
            // sits OUTSIDE the surface clip. Reset once fully collapsed instead.
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                p = 0; dragY = 0; queueP = 0
            } completion: {
                receiving = false
                // Fully collapsed now (body faded out): reset the queue flags so a
                // fresh present starts from the hero header with the traveling star,
                // without any flash.
                queueOpen = false
                queueSettled = false
                queueWantsOpen = false
            }
        }
    }

    /// Open/close the queue, driving `queueP` as a spring and managing
    /// `queueSettled` (the traveling ⇄ card artwork/star hand-off flag).
    /// Toggle the queue. This ONLY records intent (`queueWantsOpen`) and manages the
    /// mount flag — it never springs `queueP` itself. The animation is driven by
    /// `driveQueue()`, kicked from exactly one place per transition:
    ///   • fresh open (panel unmounted)  → `queueTop.onAppear`  (committed q=0 frame)
    ///   • re-open while mounted / close → `.onChange(of: queueWantsOpen)`
    /// so `queueP` deterministically animates to the *latest* intent no matter how
    /// fast you toggle — no `onAppear`-vs-lingering-mount race can strand the hero row.
    private func setQueue(open: Bool) {
        // Ignore a tap that matches the current intent (e.g. a double close): it would
        // only churn the transition token and fire a redundant onChange.
        guard open != queueWantsOpen else { return }
        // Supersede any in-flight transition so its completion can't apply terminal
        // flags after this newer toggle.
        queueTransition &+= 1
        if open {
            // `queueWasMounted` distinguishes a re-open-during-close (panel still up,
            // onAppear won't refire) from a fresh open (panel remounts, onAppear fires).
            queueWasMounted = queueOpen
            queueOpen = true
            queueSettled = false
            queueOpenNonce &+= 1
        } else {
            queueSettled = false
        }
        // Flip intent LAST so `.onChange(of:)` sees the mount flags already updated.
        queueWantsOpen = open
        if reduceMotion {
            queueP = open ? 1 : 0
            queueBodyP = open ? 1 : 0
            queueHeroP = open ? 1 : 0
            queueSettled = open
            if !open { queueOpen = false }
        }
    }

    /// The single writer of the open/close spring. Reads the *current* intent, so it
    /// always animates `queueP` toward the latest target; the completion is token-
    /// guarded so a superseded transition can't commit `queueSettled`/unmount late.
    /// Called from `queueTop.onAppear` (fresh open) and `.onChange(of: queueWantsOpen)`
    /// (re-open while mounted, and every close) — see `setQueue` for the routing.
    private func driveQueue() {
        guard !reduceMotion else { return }
        let token = queueTransition
        if queueWantsOpen {
            guard queueP < 1 else { return }
            withAnimation(Self.queueSpring) {
                queueP = 1
            } completion: {
                guard token == queueTransition else { return }
                queueSettled = true
            }
            // Body climbs on its own gentler, longer spring so it settles into place
            // after the fast hand-off above — not tied to the queueP completion.
            withAnimation(Self.queueBodySpring) {
                queueBodyP = 1
            }
            // Hero lifts + fades on its own slower spring so its travel reads as a
            // deliberate hand-off rather than a quick snap, decoupled from the artwork.
            withAnimation(Self.queueHeroSpring) {
                queueHeroP = 1
            }
        } else {
            // Already collapsed: nothing to animate, just drop the mount.
            guard queueP > 0 else { queueOpen = false; queueBodyP = 0; queueHeroP = 0; return }
            withAnimation(Self.queueSpring) {
                queueP = 0
            } completion: {
                guard token == queueTransition else { return }
                queueOpen = false
            }
            // Retract the body in lock-step with queueP (fast spring) so it finishes
            // together and the unmount-on-queueP-completion above stays clean.
            withAnimation(Self.queueSpring) {
                queueBodyP = 0
            }
            // Hero snaps back with the fast spring too — no reason to linger on close.
            withAnimation(Self.queueSpring) {
                queueHeroP = 0
            }
        }
    }

    /// DEBUG slow-motion knob for the queue open/close transition. Every phase of the
    /// hand-off (hero lift + `RangeFadeOut`, card rise + `LateFade`, `BodyRise`) is
    /// keyed on `queueP` (0→1), so scaling the one spring that drives `queueP` slows
    /// the WHOLE sequence proportionally — the relative timing of each phase is
    /// preserved, just stretched out so it can be observed and tuned. Set back to `1`
    /// for production feel.
    private static let queueTimeScale: CGFloat = 1

    /// Shared open/close spring for the queue transition (× `queueTimeScale`).
    private static let queueSpring = Animation.spring(response: 0.56 * queueTimeScale,
                                                      dampingFraction: 0.86)

    /// Gentler, longer spring for the queue BODY's rise/fade on OPEN only, so its
    /// climb visibly takes longer than the fast `queueSpring` hand-off (artwork dock +
    /// hero→card title cross-fade) above it. Higher `response` = slower climb; high
    /// damping keeps it from overshooting on the long travel. The close still uses
    /// `queueSpring` (see `driveQueue`), so this only stretches the entrance.
    private static let queueBodySpring = Animation.spring(response: 0.85 * queueTimeScale,
                                                          dampingFraction: 0.92)

    /// Slower spring for the hero row's lift/fade on OPEN only, so the title/artist
    /// visibly travel up and out at a gentler pace than the fast artwork dock instead
    /// of snapping away. Higher `response` = slower; the close reuses `queueSpring`
    /// (see `driveQueue`) so retract stays snappy.
    private static let queueHeroSpring = Animation.spring(response: 0.75 * queueTimeScale,
                                                          dampingFraction: 0.88)

    // MARK: Drawer controls

    private var scrubber: some View {
        let snapshot = playback.snapshot
        return SeekBar(elapsed: snapshot.elapsed, duration: snapshot.duration) { target in
            playback.seek(to: target)
        }
    }

    private var transport: some View {
        let playing = playback.snapshot.status == .playing
        return HStack(spacing: 44) {
            PlayerIconButton(glyph: .skipBack,
                             glyphSize: PlayerControlMetrics.skipGlyph,
                             hitSize: PlayerControlMetrics.skipHit,
                             isEnabled: playback.snapshot.hasPrevious,
                             label: "Previous") { playback.previous() }
            PlayPauseButton(playing: playing) { playback.togglePlayPause() }
            PlayerIconButton(glyph: .skipForward,
                             glyphSize: PlayerControlMetrics.skipGlyph,
                             hitSize: PlayerControlMetrics.skipHit,
                             isEnabled: playback.snapshot.hasNext,
                             label: "Next") { playback.next() }
        }
    }

    private func formatBadge(track: Track) -> some View {
        let parts = [track.format.codec?.uppercased(), track.format.sampleRateHz.map { "\($0 / 1000) kHz" }]
            .compactMap { $0 }
        return Text(parts.joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary)
    }

    /// The bottom control row: an equalizer button (opens the EQ sheet, tinted
    /// when the EQ is on), the current-output-route control (shows the real device
    /// The bottom control row: a (dummy) lyrics button, the current-output-route
    /// control (shows the real device icon; tap to open the AirPlay picker), and
    /// the queue toggle. Lyrics + a per-track context menu aren't built yet, so
    /// lyrics is a disabled placeholder. (The equalizer lives in Settings for now.)
    private var bottomButtonRow: some View {
        HStack {
            PlayerIconButton(glyph: .lyrics, tint: .secondary, isEnabled: false,
                             label: "Lyrics") { }
            Spacer()
            #if canImport(UIKit)
            routeControl
            #endif
            Spacer()
            PlayerIconButton(glyph: .queue, tint: queueWantsOpen ? .primary : .secondary,
                             haptics: false,
                             label: "Queue") { setQueue(open: !queueWantsOpen) }
        }
    }

    #if canImport(UIKit)
    /// The output-route control: the real device icon (AirPods / headphones /
    /// AirPlay / car / TV / speaker) drawn over an invisible `AVRoutePickerView`
    /// (so a tap still opens the system picker). Tinted to signal when audio is
    /// routed off the phone speaker.
    private var routeControl: some View {
        ZStack {
            AirPlayRoutePicker(tint: .clear)   // invisible glyph, still tappable
            Image(systemName: routeMonitor.output.icon)
                .font(.system(size: PlayerControlMetrics.utilityGlyph))
                .foregroundStyle(routeMonitor.output.showsLabel ? Color.primary : Color.secondary)
                .allowsHitTesting(false)
        }
        .frame(width: PlayerControlMetrics.minHit, height: PlayerControlMetrics.minHit)
    }

    /// The route line under the controls. For external speakers/rooms (AirPlay,
    /// CarPlay, TV) it reads "iPhone → Name"; for personal audio (AirPods,
    /// headphones) just the device name; nothing on the built-in speaker — like
    /// Apple Music.
    @ViewBuilder private var routeLabel: some View {
        let out = routeMonitor.output
        if out.showsLabel {
            HStack(spacing: 5) {
                if out.showsSourcePrefix {
                    Text("iPhone").foregroundStyle(.secondary)
                    Image(mozz: "arrow.forward").font(.caption2).foregroundStyle(.secondary)
                }
                Text(out.name).foregroundStyle(.primary)
            }
            .font(.footnote)
            .lineLimit(1)
        }
    }
    #endif
}

// MARK: - Island content (self-contained: swipe + title/artist slide)

/// Shared spring for the island text slide.
private let islandTextSpring = Animation.spring(response: 0.34, dampingFraction: 1.0)
/// The outgoing (leaving) title/artist clears out faster than the incoming
/// settles, so the old text doesn't linger under the new one.
private let islandExitAnimation = Animation.easeOut(duration: 0.20)
/// The outgoing text aims WELL past the zone edge (this × zoneW), so it becomes
/// fully hidden early in the ease (during its fast part) rather than only at the
/// decelerating tail — otherwise a long title's tail lingers as the new one
/// settles. It's off-screen for the slow remainder, so the overshoot is unseen.
private let islandExitOvershoot: CGFloat = 1.9
/// The incoming text STARTS this far past the edge (× zoneW), beyond the fade, so
/// the spring's fast initial burst happens off-screen and the visible motion is
/// the slower settle — it reads as sliding in from the edge, not appearing
/// mid-zone. Symmetric with the exit overshoot.
private let islandEnterOvershoot: CGFloat = 1.9

// MARK: - Marquee (classic music-player horizontal scroll for overflowing text)

/// How fast the marquee glides (points per second). Slow enough to read.
private let marqueeSpeed: CGFloat = 26
/// Overflow smaller than this doesn't bother scrolling (a couple clipped pixels
/// aren't worth the motion).
private let marqueeMinOverflow: CGFloat = 8
/// Dwell at the start before scrolling out, and at the end before returning, so
/// the reader can catch the beginning/end of the line.
private let marqueeStartDwell: Duration = .milliseconds(2600)
private let marqueeEndDwell: Duration = .milliseconds(1100)
/// A tiny settle pause between the return finishing and the next cycle starting.
private let marqueeLoopGap: Duration = .milliseconds(250)
/// Spring used to ease the title back to home (offset 0) when a glide is
/// interrupted — by a collapse/expand morph or a swipe. Roughly matches the
/// scroll-minimize morph spring so the text returns in lockstep with the pill
/// instead of teleporting.
private let marqueeReturn = Animation.spring(response: 0.45, dampingFraction: 0.9)

/// Publishes a measured intrinsic (untruncated) text width up the view tree.
private struct MarqueeWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

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
    var playback: PlaybackEngine
    var onExpand: () -> Void
    /// How far the island has dropped into the tab bar's centre pill (0…1). At 1
    /// the skip/next button is gone (Apple's minimized island keeps only
    /// play/pause), giving the narrower pill more room for the title/artist.
    var collapse: CGFloat = 0
    /// The pill's current content width (from the parent's morph). Drives the text
    /// zone width DETERMINISTICALLY — the old measure→pin→remeasure loop kept the
    /// labels full-island-wide when the pill collapsed, so text spilled left and
    /// the buttons overflowed onto the Search circle.
    var pillWidth: CGFloat = 0
    /// The DOCKED (largest) pill width. The text truncates once at this width so it
    /// doesn't re-truncate (which "races" the ellipsis) as the pill narrows during
    /// the collapse — the narrowing pill just clips the tail instead.
    var maxPillWidth: CGFloat = 0

    @State private var dragX: CGFloat = 0        // live thumb-follow (0 at rest)
    @State private var navDir = 1                // +1 next, -1 previous
    @State private var animateSwipe = false      // true only for a swipe commit
    @State private var commitStart: CGFloat = 0  // finger offset at commit
    @State private var commitTick = 0            // bumped to fire a haptic pop
    @State private var armedDir = 0              // side currently past the threshold

    /// Text-zone width for a given pill width + collapse: the pill minus the fixed
    /// row parts (leading inset, artwork, gaps, play button, collapsing skip,
    /// trailing inset). Deterministic — no measurement, no feedback loop.
    private func zoneWidth(pill: CGFloat, collapse: CGFloat) -> CGFloat {
        let skip = (30 + 10) * (1 - collapse)     // skip button + its HStack gap
        let fixed = Morph.islandArtLeading        // 20 leading inset
                  + Morph.islandArtSide           // 34 artwork
                  + 10                            // artwork → text gap
                  + 10                            // text → play gap
                  + 30                            // play button
                  + skip
                  + Morph.islandContentPad        // 12 trailing inset
        return max(pill - fixed, 1)
    }
    /// Current text-zone width (drives layout so the play button sits correctly).
    private var zoneW: CGFloat { zoneWidth(pill: pillWidth, collapse: collapse) }
    /// Docked text-zone width — the stable width the text truncates at.
    private var stableZoneW: CGFloat {
        zoneWidth(pill: max(maxPillWidth, pillWidth), collapse: 0)
    }
    // A text line locks (stays put, ignores the thumb) when the track it'd change
    // to shares that line's text — so the artist never "scrolls" when swiping
    // between same-artist tracks. Set at drag time so they stay correct through
    // the commit settle (when currentTrack has already advanced).
    @State private var lockTitle = false
    @State private var lockArtist = false

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

    /// Width of the soft fade at each edge of the text zone — the outgoing/incoming
    /// (and live-drag) title/artist dissolve through it instead of hard-clipping.
    /// Matches the artwork↔text gap (the inner HStack spacing) so the fade sits in
    /// that gap: the resting text is fully opaque, and text only dissolves as it
    /// slides into the gap.
    private static let textEdgeFade: CGFloat = 10
    /// The left fade ends this far short of the artwork (1pt), so it clears just to
    /// the RIGHT of the artwork rather than exactly at its edge.
    private static let textLeftFadeInset: CGFloat = 1
    private static var textLeftFade: CGFloat { textEdgeFade - textLeftFadeInset }
    /// The RIGHT fade is longer than the gap so the tail dissolves gradually into
    /// the play button (a softer, longer ramp than the left).
    private static let textRightFade: CGFloat = textEdgeFade + 12

    /// Horizontal fade mask applied over the text zone AFTER it's been expanded by
    /// the fade widths on each side (see body). The clear→opaque ramps therefore
    /// fall in those expansion strips — the gaps to the artwork (left) and the play
    /// button (right) — leaving the whole measured text area opaque. The left strip
    /// is 1pt narrower so it clears just right of the artwork.
    private var edgeFadeMask: some View {
        let padded = zoneW + Self.textLeftFade + Self.textRightFade
        let leftFrac = min(Self.textLeftFade / max(padded, 1), 0.5)
        let rightFrac = min(Self.textRightFade / max(padded, 1), 0.5)
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: leftFrac),
                .init(color: .black, location: 1 - rightFrac),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing)
    }

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
                                    dir: navDir, zoneW: zoneW, renderW: stableZoneW, animate: animateSwipe,
                                    liveDrag: lockTitle ? 0 : dragX, commitStart: commitStart,
                                    font: .subheadline.weight(.semibold), secondary: false, marquees: true)
                    IslandSlideText(text: playback.currentTrack?.artistName ?? "",
                                    dir: navDir, zoneW: zoneW, renderW: stableZoneW, animate: animateSwipe,
                                    liveDrag: lockArtist ? 0 : dragX, commitStart: commitStart,
                                    font: .caption2, secondary: true, marquees: false)
                }
                // Hard-constrain the text column to the CURRENT zone width (which
                // shrinks as the pill collapses) and left-align, so the play button
                // stays pinned to the right and the stable-width labels overflow to
                // the right where the mask below clips them — no re-truncation.
                .frame(width: zoneW, alignment: .leading)
                // Soft fade at the zone edges (replaces a hard clip): the sliding
                // text dissolves as it enters/leaves. Expand the maskable region by
                // the fade width on each side, apply the fade there, then restore
                // the layout with negative padding — so the ramps live in the gaps
                // (to the artwork on the left, the play button on the right) and the
                // resting text stays fully opaque. The left strip is 1pt narrower so
                // the fade clears just to the right of the artwork, not on its edge.
                .padding(.leading, Self.textLeftFade)
                .padding(.trailing, Self.textRightFade)
                .mask(edgeFadeMask)
                .padding(.leading, -Self.textLeftFade)
                .padding(.trailing, -Self.textRightFade)
                // Nudge the text block up to correct font line-box asymmetry (the
                // glyphs sit slightly low inside their line boxes, so the visual
                // top gap is larger than the bottom). Scales with Dynamic Type, so
                // it's imperceptible at default and evens out the gap at xxxLarge.
                .offset(y: -textVerticalNudge)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .highPriorityGesture(islandGesture)

            Button { playback.togglePlayPause() } label: {
                (playback.snapshot.status == .playing ? AppIcon.pause : AppIcon.play)
                    .styled(size: 20)
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                // Skip button runs the same slide as a swipe (from rest).
                commitTick &+= 1
                changeTrack(goNext: true, from: 0)
            } label: {
                Image(mozz: "forward.fill")
                    .font(.title3).frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!playback.snapshot.hasNext)
            // Fades out and collapses its width as the island drops into the centre
            // pill, so the minimized island keeps only play/pause (like Apple's).
            .opacity((playback.snapshot.hasNext ? 1 : 0.4) * Double(1 - collapse))
            .frame(width: 30 * (1 - collapse))
            .allowsHitTesting(collapse < 0.5)
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

    /// Lock a title/artist line (stops it following the thumb) when the track the
    /// current drag direction would land on shares that line's text — so the line
    /// never "scrolls" only to spring back. `previous()` restarts the current
    /// track when >3s in, so in that case the target IS the current track (both
    /// lines unchanged). No target (nothing to skip to) ⇒ no lock, so the
    /// rubber-band feedback is preserved.
    private func updateLineLocks(goNext: Bool) {
        let target: Track? = goNext
            ? playback.peekNextTrack
            : (playback.snapshot.elapsed > 3 ? playback.currentTrack : playback.peekPreviousTrack)
        guard let target else { lockTitle = false; lockArtist = false; return }
        let cur = playback.currentTrack
        lockTitle = (target.title) == (cur?.title ?? "")
        lockArtist = (target.artistName) == (cur?.artistName ?? "")
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
                    lockTitle = false; lockArtist = false
                    return
                }
                let canGo = w < 0
                    ? playback.snapshot.hasNext
                    : (playback.snapshot.hasPrevious || playback.snapshot.elapsed > 3)
                dragX = canGo ? w : w * 0.3
                updateLineLocks(goNext: w < 0)
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
    /// Fixed width the label renders (and truncates) at. Held constant during the
    /// collapse DROP so the title doesn't re-truncate — which SwiftUI would animate
    /// as a snapshot cross-fade ("the ellipsis flies off, the full text fades in").
    /// The narrowing pill clips the tail instead. Equals `zoneW` while docked.
    let renderW: CGFloat
    let animate: Bool
    let liveDrag: CGFloat
    let commitStart: CGFloat
    let font: Font
    let secondary: Bool
    /// Whether this line is allowed to auto-scroll (marquee) when it overflows. Only
    /// the title opts in: running the title AND artist together desynced into a busy
    /// double-scroll, so the artist stays put and just clips.
    let marquees: Bool

    @State private var current: String
    @State private var outgoing: String?
    @State private var currentX: CGFloat = 0
    @State private var outgoingX: CGFloat = 0
    @State private var transitioning = false
    @State private var gen = 0
    /// Intrinsic (untruncated) width of `current`, measured off-screen. Drives
    /// whether the line needs to scroll and how far.
    @State private var naturalW: CGFloat = 0
    /// Live marquee scroll offset (0 = start, negative = scrolled left to reveal
    /// the tail). Driven entirely by the marquee task, which eases it back to 0
    /// (never snaps) whenever a glide is interrupted, so the offset can be read
    /// directly with no gating flag.
    @State private var marqueeX: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(text: String, dir: Int, zoneW: CGFloat, renderW: CGFloat, animate: Bool,
         liveDrag: CGFloat, commitStart: CGFloat, font: Font, secondary: Bool,
         marquees: Bool) {
        self.text = text; self.dir = dir; self.zoneW = zoneW; self.renderW = renderW
        self.animate = animate
        self.liveDrag = liveDrag; self.commitStart = commitStart
        self.font = font; self.secondary = secondary; self.marquees = marquees
        _current = State(initialValue: text)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if let outgoing {
                label(outgoing).offset(x: outgoingX)
            }
            // ONE label structure in every state (no conditional view swap) so the
            // morph never cross-fades between a truncated and a full-width variant —
            // that swap is what made the title "race" upward on collapse. `fixedSize`
            // means it never truncates, so there's a real tail for the marquee to
            // reveal and no re-truncation snapshot to animate.
            //
            // Offset priority: a swipe commit (currentX) wins; then a live finger
            // drag (liveDrag) so track-swipe follows the thumb; otherwise the marquee
            // (marqueeX, which the task holds at 0 whenever it isn't actively
            // gliding). No gating flag — marqueeX is authoritative at rest.
            label(current)
                .offset(x: transitioning ? currentX : (liveDrag != 0 ? liveDrag : marqueeX))
        }
        // Measure the intrinsic width off-screen so we know when (and how far) to
        // scroll. A background never affects the ZStack's own size.
        .background(alignment: .leading) { measuringLabel }
        .onPreferenceChange(MarqueeWidthKey.self) { naturalW = $0 }
        // One driver, keyed on marqueeKey (text, bucketed width, measured width,
        // active). It restarts on a real width change (a collapse/expand morph
        // crosses width buckets) or a track/state change, and auto-cancels when the
        // view goes away. Every marqueeX transition here is ANIMATED (linear glide,
        // or `marqueeReturn` easing back to home) — the task never snaps the offset,
        // so an interrupted glide eases back in lockstep with the morph instead of
        // teleporting. During a morph the task keeps restarting: each run eases to
        // home and re-enters the dwell (the next restart cancels it before it can
        // glide), so the text rides the morph parked at home, then resumes once the
        // width settles.
        .task(id: marqueeKey) {
            // Not scrollable in this state (short title, mid-swipe, reduce motion):
            // ease home (never snap) and bail.
            guard marqueeActive, overflow > marqueeMinOverflow else {
                if marqueeX != 0 { withAnimation(marqueeReturn) { marqueeX = 0 } }
                return
            }
            let dist = overflow
            let dur = Double(dist / marqueeSpeed)
            // Coordinated return: if a previous glide (or a mid-scroll morph) left the
            // text off-home, ease it back to 0 before the fresh cycle.
            if marqueeX != 0 { withAnimation(marqueeReturn) { marqueeX = 0 } }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: marqueeStartDwell)
                    withAnimation(.linear(duration: dur)) { marqueeX = -dist }
                    try await Task.sleep(for: .seconds(dur))
                    try await Task.sleep(for: marqueeEndDwell)
                    withAnimation(.linear(duration: dur)) { marqueeX = 0 }
                    try await Task.sleep(for: .seconds(dur))
                    try await Task.sleep(for: marqueeLoopGap)
                } catch {
                    // Cancelled (view gone or restarting): a fresh run owns marqueeX
                    // now and will ease it home, so don't write shared state here.
                    return
                }
            }
        }
        .onChange(of: text) { _, new in
            guard new != current else { return }
            guard animate else {                 // instant swap for non-swipe changes
                transitioning = false
                outgoing = nil
                current = new
                // Reset the marquee offset to home WITHOUT animating, or the new
                // title would paint at the previous title's scroll offset and then
                // visibly slide in when the task eases it home. (Swipe/skip changes
                // are masked by `transitioning`→`currentX`, but auto-advance and
                // library selection take this instant path.)
                if marqueeX != 0 {
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { marqueeX = 0 }
                }
                return
            }
            let enter = dir > 0 ? zoneW * islandEnterOvershoot : -zoneW * islandEnterOvershoot  // incoming from the correct side, beyond the fade
            // Outgoing aims well past the edge so it's hidden early (fast part of
            // the ease), not only at the decelerating tail — no lingering tail on
            // long titles.
            let exit  = dir > 0 ? -zoneW * islandExitOvershoot : zoneW * islandExitOvershoot
            outgoing = current
            outgoingX = commitStart               // continue from the finger
            current = new
            currentX = enter
            transitioning = true
            gen += 1
            let token = gen
            // Defer one tick so the start offsets render, then slide to rest.
            // The incoming settles on `islandTextSpring`; the outgoing clears out
            // on the snappier `islandExitAnimation` so it leaves faster. State
            // cleanup rides the (slower) incoming so it fires after both settle.
            DispatchQueue.main.async {
                withAnimation(islandExitAnimation) {
                    outgoingX = exit
                }
                withAnimation(islandTextSpring) {
                    currentX = 0
                } completion: {
                    if gen == token { outgoing = nil; transitioning = false }
                }
            }
        }
    }

    /// ONE label used in every state. `fixedSize` gives it its full intrinsic width
    /// (never truncates), pinned to a stable `renderW` footprint so the overflow
    /// spills past the edges where the parent's fade mask dissolves it — and so the
    /// pill collapse never re-truncates (that recompute is what SwiftUI animated as
    /// a flying snapshot). The marquee scrolls this same view; the narrowing pill
    /// just clips more of it.
    private func label(_ s: String) -> some View {
        Text(s)
            .font(font)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .frame(width: renderW, alignment: .leading)
    }

    /// Off-screen twin used only to measure the intrinsic (untruncated) width.
    private var measuringLabel: some View {
        Text(current)
            .font(font)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .background(GeometryReader { g in
                Color.clear.preference(key: MarqueeWidthKey.self, value: g.size.width)
            })
            .hidden()
            .allowsHitTesting(false)
    }

    /// How far the text runs past the CURRENTLY VISIBLE width (`zoneW`, which shrinks
    /// as the island drops into the tab-bar pill) — so the collapsed pill scrolls
    /// its (larger) overflow too, not just the full-width resting island.
    private var overflow: CGFloat { max(0, naturalW - zoneW) }
    /// Scroll only at rest: never during a swipe or a finger drag, and never while
    /// the collapse morph is animating (`zoneW` is changing — see `marqueeKey`, which
    /// restarts the driver every frame of the morph and only settles once still).
    /// Honors Reduce Motion, and only runs when there's something to reveal.
    private var marqueeActive: Bool {
        marquees && !transitioning && liveDrag == 0 && !reduceMotion
            && overflow > marqueeMinOverflow && !current.isEmpty
    }
    /// Identity for the marquee driver: any change restarts it from the beginning.
    /// Uses a BUCKETED zoneW (see `widthBucket`) so sub-pixel jitter of the measured
    /// island frame doesn't churn the task; a real morph crosses buckets and restarts
    /// it (holding the text still), and once the width settles it runs, scrolled to
    /// that width's overflow.
    private var marqueeKey: String {
        "\(current)|\(Self.widthBucket(zoneW))|\(Int(naturalW.rounded()))|\(marqueeActive ? 1 : 0)"
    }

    /// Quantise a width to ~3pt buckets, so the imperceptible sub-pixel jitter of the
    /// measured native-accessory frame is ignored while genuine morph transitions
    /// (tens of points) still register.
    private static func widthBucket(_ w: CGFloat) -> Int { Int((w / 3).rounded()) }
}

// MARK: - Geometry

/// Applies the live drag-to-dismiss translation as a single `.offset`, reading
/// `dragY` through a binding. Because the parent passes `$dragY` (a binding, not
/// the value), the parent body registers NO dependency on `dragY`, so a drag
/// re-runs only this modifier and re-applies the offset to the already-built
/// drawer — it never re-executes the morph geometry or the heavy queue subtree.
/// This is the same re-render isolation the island glow/content already rely on.
private struct DragTranslate: ViewModifier {
    @Binding var dragY: CGFloat
    func body(content: Content) -> some View {
        content.offset(y: max(0, dragY))
    }
}

/// Fades a view OUT across a window `[start, end]` of an animated `progress`
/// (0 → 1): fully opaque before `start`, ramps 1 → 0 across the window, gone
/// after `end`. Back-loaded on purpose — the hero row uses it to climb (staying
/// visible) through the early part of the open, then dissolve as it hands off to
/// the card row + rising queue body. Implemented as an `Animatable` modifier so
/// SwiftUI samples the curve every frame: a plain `.opacity(...)` computed from
/// animated state only interpolates its start/end opacity along the spring, so
/// the window has no visible effect. Driving `animatableData` with `progress`
/// forces the windowed opacity to be evaluated per interpolated step.
private struct RangeFadeOut: ViewModifier, Animatable {
    var progress: CGFloat
    var start: CGFloat
    var end: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let span = max(0.0001, end - start)
        let t = min(1, max(0, (progress - start) / span))
        return content.opacity(Double(1 - t))
    }
}

/// Lifts the hero row UP by `distance`, completing the full climb by `end` (in
/// progress, 0 → 1) and holding there after — so the climb's duration is decoupled
/// from the whole transition. `Animatable` so SwiftUI samples the clamped ramp every
/// frame: a plain `.offset(y:)` from animated state would interpolate only the 0 and
/// -distance endpoints along the spring, linearizing the `end` clamp away.
private struct HeroLift: ViewModifier, Animatable {
    var progress: CGFloat
    var start: CGFloat
    var end: CGFloat
    var distance: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let span = max(0.0001, end - start)
        let t = min(1, max(0, (progress - start) / span))
        return content.offset(y: -distance * t)
    }
}

/// Holds a view pushed DOWN by `distance` until `progress` (0 → 1) passes `start`,
/// then rises it to rest by `progress = 1` — the delayed-entrance rise used by the
/// card row so its climb *and* fade (`LateFade`, same `start`) begin together, giving
/// a deliberate "comes in" rather than a slide that's already underway. `Animatable`
/// so the hold corner is sampled per frame: a plain `.offset(y:)` from animated state
/// would interpolate only the endpoints and linearize the hold away.
private struct GatedRise: ViewModifier, Animatable {
    var progress: CGFloat
    var start: CGFloat
    var distance: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let span = max(0.0001, 1 - start)
        let t = min(1, max(0, (progress - start) / span))
        return content.offset(y: (1 - t) * distance)
    }
}

/// Fades a view IN, but only after `progress` (0 → 1) passes `start`; before that
/// it stays fully transparent, then ramps 0 → 1 over the remaining `start…1` range.
/// The delayed-fade counterpart to `RangeFadeOut`, used for the queue card's title
/// + star so they "catch" the hero row after it has mostly lifted away. Must be
/// `Animatable` for the same reason as `RangeFadeOut`: a computed `.opacity` from
/// animated state would only interpolate its endpoints and skip the delay curve;
/// driving `animatableData` forces per-frame sampling of the delayed ramp.
private struct LateFade: ViewModifier, Animatable {
    var progress: CGFloat
    var start: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let span = max(0.0001, 1 - start)
        let o = min(1, max(0, (progress - start) / span))
        return content.opacity(Double(o))
    }
}

/// All frames and opacities are pure functions of `p` (and `queue`) and the
/// screen metrics, so the whole morph is deterministic and reversible. The live
/// finger translation (`dragY`) is applied OUTSIDE this geometry as a single
/// container offset (see `DragTranslate`) so a drag never re-derives the morph or
/// rebuilds the heavy queue subtree.
private struct Morph {
    let width: CGFloat
    let height: CGFloat
    let safeTop: CGFloat
    let safeBottom: CGFloat
    /// Raw spring value; may briefly leave [0,1]. Everything below uses the
    /// clamped `p`, so the spring's overshoot can't wobble the surface.
    let pRaw: CGFloat
    /// True during the collapse — enables the upward receive-bounce.
    let receiving: Bool
    /// Target state: `true` while expanded/opening, `false` while docked/collapsing.
    /// The mini controls are hidden whenever this is true, so the drawer opens
    /// OVER them (they never flash during an open).
    let isExpanded: Bool
    /// Tab-bar minimize progress (0…1). While docked, the island slides DOWN into
    /// the tab bar's centre pill as this →1. Unwound as the drawer expands.
    let minimize: CGFloat
    /// Queue-open progress (0 = hero cover big-center, 1 = cover docked into the
    /// queue's compact-header thumbnail slot). Only meaningful while fully expanded.
    let queue: CGFloat

    var p: CGFloat { min(max(pRaw, 0), 1) }
    var q: CGFloat { min(max(queue, 0), 1) }

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
    static let expandedArtRadius: CGFloat = 18
    static let bottomOverhang: CGFloat = 120    // surface runs off-screen at p=1
    static let receiveDepth: CGFloat = 4        // how far the island grows UP on the catch
    static let receiveZone: CGFloat = 0.18      // last fraction of collapse the bounce lives in
    static let miniFadeFull: CGFloat = 0.10     // p at/below which mini controls are fully shown
    static let miniFadeEnd: CGFloat = 0.34      // p at/above which mini controls are hidden
    static let expArtTopGap: CGFloat = 39       // grabber + gap above big artwork

    // Island touch-target slop: the tappable area extends beyond the 56pt visual
    // pill so edge taps don't "fall through" to the page/tab-bar behind (Apple's
    // hit targets are likewise larger than their visual bounds). Bottom is kept
    // under `islandBottomGap` (8pt) so it can't steal tab-bar taps.
    static let islandTapSlopTop: CGFloat = 12
    static let islandTapSlopBottom: CGFloat = 6
    static let islandTapSlopH: CGFloat = 8

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

    // Enlarged island hit target (visual pill stays `islandDropH`; only the
    // tappable/press area grows). Centred on the pill but extends more upward.
    var islandTapW: CGFloat { islandDropW + 2 * Self.islandTapSlopH }
    var islandTapH: CGFloat { islandDropH + Self.islandTapSlopTop + Self.islandTapSlopBottom }
    var islandTapCenterY: CGFloat { miniCenterY + (Self.islandTapSlopBottom - Self.islandTapSlopTop) / 2 }

    // Expanded artwork --------------------------------------------------------
    // Matches the content width (scrubber / titles / buttons use 32pt side
    // padding), so the cover lines up flush with the controls below it.
    var expArtSide: CGFloat { width - 64 }
    var expArtCenterY: CGFloat { safeTop + Self.expArtTopGap + expArtSide / 2 }

    // Morphing surface --------------------------------------------------------
    // The surface is anchored by its BOTTOM edge: it lands exactly on the
    // island's bottom and NEVER moves below it (Apple pins the bottom and grows
    // the island UPWARD to receive the drawer). `receiveGrow` extends the TOP up
    // for the catch bounce; the bottom stays put.
    //
    // On TOP of that island↔drawer morph, the scroll-minimize DROP slides the
    // docked island DOWN into the tab bar's centre pill (between the split blobs)
    // and shrinks it to `centerPillW`. `dropT` is the drop amount; it's full while
    // docked (p≈0) and unwinds as the drawer expands (×(1−p)), so opening the
    // player is unaffected.
    var mz: CGFloat { min(max(minimize, 0), 1) }
    var dropT: CGFloat { mz * (1 - p) }
    var barCenterY: CGFloat { BottomBar.barCenterY(inHeight: height) }
    var centerPillW: CGFloat { BottomBar.centerGap(inWidth: width).width }
    var centerPillCenterX: CGFloat { BottomBar.centerGap(inWidth: width).centerX }

    var surfaceHExpanded: CGFloat { height + Self.bottomOverhang }
    /// Upward receive-bounce: a half-sine that is 0 at rest (p=0) and 0 at the
    /// zone edge, peaking in between — so as the drawer lands the island grows
    /// taller UPWARD by up to `receiveDepth`pt, then settles with no rebound and
    /// without ever moving the bottom edge. Active only during the collapse.
    var receiveGrow: CGFloat {
        guard receiving, p < Self.receiveZone else { return 0 }
        let u = Double(p / Self.receiveZone)   // 1 at zone edge → 0 at rest
        return Self.receiveDepth * CGFloat(sin(.pi * u))
    }

    // p-only ("natural") surface frame, before the scroll-minimize drop.
    private var baseH_p: CGFloat { lerp(Self.islandHeight, surfaceHExpanded, p) }
    private var surfaceH_p: CGFloat { baseH_p + receiveGrow }
    private var bottomEdge_p: CGFloat { lerp(islandTop, 0, p) + baseH_p }
    private var centerY_p: CGFloat { bottomEdge_p - surfaceH_p / 2 }

    var surfaceW: CGFloat { lerp(lerp(islandW, width, p), centerPillW, dropT) }
    var surfaceH: CGFloat { lerp(surfaceH_p, BottomBar.minElementH, dropT) }
    var surfaceCenterX: CGFloat { lerp(width / 2, centerPillCenterX, dropT) }
    var surfaceCenterY: CGFloat { lerp(centerY_p, barCenterY, dropT) }
    var bottomEdge: CGFloat { surfaceCenterY + surfaceH / 2 }
    var radius: CGFloat { lerp(lerp(islandRadius, Self.expandedRadius, p), BottomBar.minElementH / 2, dropT) }
    /// The surface's top edge WITHOUT the receive-grow. The mini controls ride
    /// this down into the island, so the grow can raise the glass above them
    /// without carrying them up.
    var baseTop: CGFloat { lerp(islandTop, 0, p) }
    /// Center of the mini-control row: rides the top edge down (resting centered
    /// in the island at p=0), and drops to the bar centre when minimized.
    var miniCenterY: CGFloat { lerp(baseTop + Self.islandHeight / 2, barCenterY, dropT) }
    /// Island content frame — shrinks into the centre pill as it drops.
    var islandDropW: CGFloat { lerp(islandW, centerPillW, dropT) }
    var islandDropH: CGFloat { lerp(Self.islandHeight, BottomBar.minElementH, dropT) }

    // Traveling artwork -------------------------------------------------------
    // Queue-card slot — the now-playing card's artwork position the cover travels
    // INTO when the queue opens. Constants MIRROR the `queueTop` + `nowPlayingCard`
    // layout so the traveling cover lands exactly on the card's (reserved) slot at
    // Detent A: down by grabber pad (safeTop + 8) + capsule (5) + card top pad (8);
    // in by the scroll content leading pad (24); 72pt square, 11pt radius. Keep in
    // sync with `nowPlayingCard`.
    static let queueArtSide: CGFloat = 72
    static let queueArtRadius: CGFloat = 11
    static let queueArtLeading: CGFloat = 24
    static let queueArtTopGap: CGFloat = 8 + 5 + 8
    var queueArtCenterX: CGFloat { Self.queueArtLeading + Self.queueArtSide / 2 }
    var queueArtCenterY: CGFloat { safeTop + Self.queueArtTopGap + Self.queueArtSide / 2 }

    // The p-blend runs island⇄big-center; the q-blend then docks big-center⇄queue
    // slot. Because q is only ≠0 at p≈1 (and unwinds with p on collapse), the two
    // stages compose cleanly without a jump.
    var artSide: CGFloat { lerp(lerp(Self.islandArtSide, expArtSide, p), Self.queueArtSide, q) }
    var artRadius: CGFloat { lerp(lerp(Self.islandArtRadius, Self.expandedArtRadius, p), Self.queueArtRadius, q) }
    /// Artwork is left-aligned in the pill; when dropped it follows the centre
    /// pill's left edge.
    private var dropArtCenterX: CGFloat {
        (centerPillCenterX - centerPillW / 2) + Self.islandArtLeading + Self.islandArtSide / 2
    }
    var artCenterX: CGFloat { lerp(lerp(lerp(islandArtCenterX, width / 2, p), dropArtCenterX, dropT), queueArtCenterX, q) }
    var artCenterY: CGFloat { lerp(lerp(lerp(islandCenterY, expArtCenterY, p), barCenterY, dropT), queueArtCenterY, q) }

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
    /// When `enabled` is false, a plain opaque `fallbackFill` is used instead —
    /// cheap to resize during the morph (no backdrop blur) — so the expensive
    /// glass is only paid at rest / outside Low Power Mode.
    @ViewBuilder
    func liquidGlass(radius: CGFloat, enabled: Bool = true, fallbackFill: Color = .black) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if !enabled {
            self.background(shape.fill(fallbackFill))
        } else if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(shape.fill(.ultraThinMaterial))
        }
    }
}

// MARK: - Instant touch-down reporting (UIKit)

extension View {
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
struct TouchDownReader: UIViewRepresentable {
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
/// image never flashes its placeholder mid-flight. On a track change it keeps
/// showing the previous cover until the new one is ready (`retainWhileLoading`),
/// so — combined with up-next prefetching — skipping never reveals a placeholder.
private struct MorphArtwork: View {
    let track: Track?
    let side: CGFloat
    var cornerRadius: CGFloat = 10

    @EnvironmentObject private var env: AppEnvironment
    private let base: CGFloat = 340

    var body: some View {
        Group {
            if let url = resolvedURL {
                CachedArtworkImage(url: url, retainWhileLoading: true) { placeholder }
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

    private var placeholder: some View { ArtworkPlaceholder() }
}
