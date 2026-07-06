import SwiftUI
import MozzCore
import MozzPlayback

/// The main app shell once a server is active.
///
/// **Candidate B — fully custom navigation.** The native `TabView` bar (and its
/// `tabViewBottomAccessory`) are gone entirely. We own the whole bottom: a custom
/// Liquid Glass tab bar (`MainTabBar`) plus the now-playing island/drawer
/// (`NowPlayingMorphContainer`) live in one hierarchy, so the drawer→island
/// collapse is seamless AND we can (next stage) minimise the bar into the island
/// on scroll — the signature iOS 26 look — which the native accessory would never
/// let us do without an un-hideable system glass pill fighting the morph.
///
/// Pages are switched by `selectedTab` and kept mounted once visited, so each
/// tab's `NavigationStack` preserves its state (like a real tab bar) while still
/// loading lazily on first visit.
struct MainTabsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var playback: PlaybackEngine
    @StateObject private var ui = PlayerUIModel()

    @State private var selectedTab: AppTab = .home
    /// The last active tab that ISN'T Search. When Search is selected, the left
    /// blob keeps showing this (Search always owns the right blob), so the left
    /// icon stays put instead of Search sliding across the bar.
    @State private var lastNonSearchTab: AppTab = .home
    /// Tabs visited at least once — mounted (and kept mounted) so their
    /// navigation/scroll state survives switching, but not built until first used.
    @State private var loadedTabs: Set<AppTab> = [.home]
    /// 0 = expanded tab bar, 1 = minimized (blob split). TEMP: toggled by a
    /// long-press on the bar for visual iteration; wired to scroll next.
    @State private var minimize: CGFloat = 0
    /// Per-tab "pop to root" tokens. Pressing a tab bumps its token; each tab's
    /// `NavigationStack` is `.id()`-ed on the token, so the bump rebuilds the stack
    /// at root (the view's data `@State` lives outside the stack, so it's preserved —
    /// no reload flash). This gives the standard "tap a tab → root of that tab".
    @State private var navResetTokens: [AppTab: Int] = [:]

    private func token(_ tab: AppTab) -> Int { navResetTokens[tab, default: 0] }

    /// Handle a tab-bar press. Switching tabs preserves each tab's navigation depth;
    /// re-tapping the tab you're already on pops it to root (standard iOS behavior).
    private func pressTab(_ tab: AppTab) {
        if tab == selectedTab {
            navResetTokens[tab, default: 0] += 1   // re-tap → pop to root
        }
        selectedTab = tab
        minimize = 0
        loadedTabs.insert(tab)
    }

    private var hasTrack: Bool { playback.currentTrack != nil }

    /// Tab shown in the LEFT blob when minimized: the selected tab normally, or
    /// the last active non-Search tab while Search is selected.
    private var leftTab: AppTab { selectedTab == .search ? lastNonSearchTab : selectedTab }

    var body: some View {
        ZStack(alignment: .bottom) {
            pages
            // The floating tab bar sits a fixed distance from the true bottom
            // edge (not pinned to the safe area), so it ignores the bottom safe
            // area and pads up by `edgeMargin`.
            MainTabBar(selected: $selectedTab, leftTab: leftTab,
                       hasIsland: hasTrack, minimize: $minimize,
                       onPressTab: pressTab)
                .padding(.horizontal, BottomBar.hMargin)
                .padding(.bottom, BottomBar.edgeMargin)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                // Ignore the bottom container inset AND the keyboard, so the
                // floating bar stays pinned to the screen's bottom edge and the
                // keyboard rises over it instead of shoving it up.
                .ignoresSafeArea(.container, edges: .bottom)
                .ignoresSafeArea(.keyboard, edges: .bottom)
            if hasTrack {
                NowPlayingMorphContainer(playback: playback, ui: ui, minimize: minimize)
                    .zIndex(100)
            }
        }
        .onChange(of: selectedTab) { _, tab in
            loadedTabs.insert(tab)
            if tab != .search {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    lastNonSearchTab = tab
                }
            }
        }
        .onChange(of: hasTrack) { _, has in
            // Test hook: auto-open the full player so its layout/transition can be
            // inspected in the Simulator, where no gesture injection is available.
            if has, ProcessInfo.processInfo.environment["MOZZ_AUTOEXPAND"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { ui.isFullPresented = true }
            }
        }
    }

    /// All visited pages stay mounted (state preserved); only the selected one is
    /// visible and interactive. Each reserves bottom space for the floating bar
    /// (and island) so scrolled content clears them.
    private var pages: some View {
        ZStack {
            ForEach(AppTab.allCases, id: \.self) { tab in
                if loadedTabs.contains(tab) {
                    page(for: tab)
                        .reserveBottomBar(hasTrack: hasTrack)
                        // Inject the minimize binding ONLY into the selected tab's
                        // subtree (incl. its pushed subpages), so only the visible
                        // tab's scroll views drive the bar — background tabs get a
                        // nil binding and stay inert.
                        .environment(\.bottomBarMinimize, tab == selectedTab ? $minimize : nil)
                        .opacity(tab == selectedTab ? 1 : 0)
                        .allowsHitTesting(tab == selectedTab)
                        .zIndex(tab == selectedTab ? 1 : 0)
                }
            }
        }
    }

    @ViewBuilder
    private func page(for tab: AppTab) -> some View {
        switch tab {
        case .home:    HomeView(popToken: token(.home))
        case .library: LibraryHomeView(popToken: token(.library))
        case .search:  SearchView(popToken: token(.search))
        }
    }
}

// MARK: - Tabs

enum AppTab: CaseIterable, Hashable {
    case home, library, search

    var title: String {
        switch self {
        case .home: "Home"
        case .library: "Library"
        case .search: "Search"
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .library: "square.stack.fill"
        case .search: "magnifyingglass"
        }
    }
}

/// Shared bottom-bar metrics so the tab bar, the island (in `Morph`) and the
/// page bottom-inset all agree on the same geometry. Values are in points,
/// converted from measurements taken on the device (a @3x screen): the floating
/// bar sits `edgeMargin` from the screen's bottom AND side edges (equidistant),
/// and is `tabHeight` tall.
enum BottomBar {
    static let edgeMargin: CGFloat = 22      // ~62px @3x — from bottom + side edges
    static let hMargin: CGFloat = 22         // side inset (== edgeMargin, equidistant)
    static let tabHeight: CGFloat = 63       // 188px @3x — tab bar height
    static let islandHeight: CGFloat = 56
    static let islandGap: CGFloat = 8        // gap between island and tab bar
    // Minimized "blob split" state, matching Apple Music (Figma @3x ÷3 of the
    // measured 144 / 84 / 40 px values): the side tabs become 48pt CIRCLES sitting
    // 28pt from the screen edges, with a 13pt gap to the centre now-playing island
    // (all three elements 48pt tall).
    static let minCircleD: CGFloat = 48      // side-circle diameter (Library / Search)
    static let minInset: CGFloat = 28        // circle from the screen's L/R edge
    static let minGap: CGFloat = 13          // gap between a side circle and the island
    static let minElementH: CGFloat = 48     // height of all three minimized elements
    /// Distance from a side circle's CENTRE to the tab bar's own left/right edge
    /// (the bar is already inset by `hMargin`), so the circle lands `minInset` from
    /// the screen edge.
    static var circleCenterInset: CGFloat { minInset - hMargin + minCircleD / 2 }
    /// Vertical centre (from the top) of the bar row, given the screen height.
    static func barCenterY(inHeight h: CGFloat) -> CGFloat { h - edgeMargin - tabHeight / 2 }
    /// The centre island's frame (screen-space centre X + width) in the minimized
    /// state — it sits between the two side circles.
    static func centerGap(inWidth w: CGFloat) -> (centerX: CGFloat, width: CGFloat) {
        let islandW = w - 2 * (minInset + minCircleD + minGap)
        return (w / 2, max(islandW, 90))
    }
    /// Distance from the screen's bottom edge up to the island's top edge.
    static let islandTopFromEdge: CGFloat = edgeMargin + tabHeight + islandGap + islandHeight
    /// Height reserved above the safe-area bottom so scrolled content clears the
    /// floating tab bar (and, when playing, the island above it). Approximate
    /// (assumes a ~34pt home-indicator inset); extra clearance is harmless.
    static func reserved(hasTrack: Bool) -> CGFloat {
        hasTrack ? islandTopFromEdge - 26 : edgeMargin + tabHeight - 26
    }
}

private extension View {
    /// Reserves bottom safe-area space for the floating tab bar (+ island) so a
    /// tab's scrolled content isn't hidden behind them.
    @ViewBuilder
    func reserveBottomBar(hasTrack: Bool) -> some View {
        self.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: BottomBar.reserved(hasTrack: hasTrack))
        }
    }
}

// MARK: - Custom Liquid Glass tab bar

/// The floating tab bar. Two states driven by `minimize` (0 = expanded,
/// 1 = minimized on scroll):
/// - **Expanded:** one wide Liquid Glass capsule with the three tabs evenly
///   spaced.
/// - **Minimized:** the bar splits — the *selected* tab flows into a small blob
///   on the LEFT and **Search** flows into a blob on the RIGHT, the middle tabs
///   fading out. The split uses iOS 26 `GlassEffectContainer`, so the two glass
///   shapes separate with the native gooey "surface tension" bridge (and merge
///   back seamlessly when expanding) — exactly Apple Music's behavior.
struct MainTabBar: View {
    @Binding var selected: AppTab
    /// Which tab occupies the LEFT blob when minimized — the selected tab, or (if
    /// Search is selected) the last active non-Search tab. Search always owns the
    /// right blob.
    var leftTab: AppTab
    /// Whether the now-playing island is present. Without it the bar never splits
    /// (there's no centre pill to make room for).
    var hasIsland: Bool
    /// 0 = expanded (full bar), 1 = minimized (two blobs). Interpolated.
    @Binding var minimize: CGFloat
    /// Called when a tab is pressed (tapped, or committed via the blob drag). The
    /// parent switches to it AND pops it to root — so it fires even on a re-tap of
    /// the already-selected tab (which wouldn't change `selected`).
    var onPressTab: (AppTab) -> Void

    @Namespace private var glassNS

    /// Blobby spring shared by the minimize morph and the selection-blob slide.
    private static let barSpring = Animation.spring(response: 0.5, dampingFraction: 0.8)

    // Liquid selection blob. Two endpoints (lead + trail) chase the target with
    // different springs; the gap between them stretches the capsule while it
    // travels (metaball-ish) and closes when it settles. While dragging, the lead
    // edge follows the finger and the trail lags, so the blob stretches toward it.
    @State private var blobLead: CGFloat = .nan
    @State private var blobTrail: CGFloat = .nan
    @State private var draggingBlob = false
    /// Finger x at touch-down, and whether it has since moved beyond `blobDragSlop`.
    /// Used to distinguish a genuine drag (the touch reader commits it) from a
    /// stationary tap (the tab Button commits it) — so a tap doesn't fire BOTH
    /// paths, which would double-invoke `onPressTab` and bump the pop-to-root token
    /// on every tab switch.
    @State private var blobDownX: CGFloat = 0
    @State private var blobMoved = false
    private static let blobDragSlop: CGFloat = 10
    /// Tab under the finger while dragging (drives the accent colour live).
    @State private var hoverTab: AppTab?
    private static let leadSpring = Animation.spring(response: 0.24, dampingFraction: 0.72)
    private static let trailSpring = Animation.spring(response: 0.46, dampingFraction: 0.70)

    // Minimized: both side tabs become `minCircleD`-wide CIRCLES (width == the
    // minimized height, so a Capsule renders as a circle). Shared with `Morph`
    // (the island fills the centre gap between them) via `BottomBar`.
    private static let searchMinW: CGFloat = BottomBar.minCircleD
    private static let leftMinW: CGFloat = BottomBar.minCircleD

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let h = BottomBar.tabHeight
            // Without a now-playing island there's nothing to sit in the centre, so
            // the split makes no sense — keep the bar as one full pill (m = 0).
            let m = hasIsland ? min(max(minimize, 0), 1) : 0
            // Minimized side-circle geometry (screen-consistent via BottomBar): the
            // two glass shapes morph from one full-width bar (m=0) into 48pt circles
            // sitting `circleCenterInset` from the bar's edges (m=1); their height
            // shrinks 63→48 too, so a Capsule renders as a circle.
            let ci = BottomBar.circleCenterInset
            let blobSideW = lerpBar(W, Self.leftMinW, m)          // W → 48
            let blobSideH = lerpBar(h, BottomBar.minElementH, m)  // 63 → 48
            let leftCX = lerpBar(W / 2, ci, m)
            let rightCX = lerpBar(W / 2, W - ci, m)
            // Fixed per-tab width so the selection lozenge is the SAME size at
            // every tab (consistent as it slides between them).
            let itemW = max((W - 2 * Self.pad) / CGFloat(AppTab.allCases.count) - 8, 56)
            // The selection pill only lives while the full bar is (near) present;
            // it fades out over the first third of the minimize, before the split.
            let selShown = m < 0.35
            let selFade = Double(max(0, 1 - m / 0.35))
            let selX = iconCenterX(selected, W: W, m: m)
            let pillW = itemW
            let pillH = h - 10
            // The tab shown as "active" (accent) — the finger's hovered tab while
            // dragging, otherwise the committed selection.
            let activeTab = hoverTab ?? selected
            // Liquid blob geometry: centre is the midpoint of the two endpoints and
            // width grows with their gap (stretch). Only used while expanded; when
            // minimizing the (fading) blob just tracks the selected slot.
            let hasBlob = !blobLead.isNaN && !blobTrail.isNaN
            let liquidCenter = hasBlob ? (blobLead + blobTrail) / 2 : selX
            let stretch = hasBlob ? abs(blobLead - blobTrail) : 0
            let useLiquid = draggingBlob || m < 0.02
            let blobCenter = useLiquid ? liquidCenter : selX
            let blobW = pillW + min(stretch, pillW * 1.3)
            let blobH = pillH - min(stretch * 0.12, 7)

            ZStack(alignment: .topLeading) {
                // The bar's Liquid Glass shapes: one full pill (m=0) that splits
                // into two 48pt side circles (m=1).
                glassLayer(leftCX: leftCX, rightCX: rightCX,
                           blobW: blobSideW, blobH: blobSideH, h: h)

                // A tasteful selection lozenge: a flat solid capsule that slides to
                // the active tab with a LIQUID stretch (dual-spring endpoints) and
                // can be dragged to follow the finger. It fades out as the bar
                // minimizes (before the blob split). No press/glass "bubbly"
                // refraction — that's a private effect exclusive to UITabBar /
                // UISegmentedControl, not reachable from public glass APIs.
                if selShown {
                    Capsule()
                        .fill(Color.primary.opacity(0.14))
                        .frame(width: blobW, height: blobH)
                        .position(x: blobCenter, y: h / 2)
                        .opacity(selFade)
                        .allowsHitTesting(false)
                }

                // The REAL three tab items, animated to their destinations (no
                // crossfade to a separate icon set). As `minimize`→1 the selected
                // tab slides left into the left blob, Search slides right into its
                // blob (barely moving), and the other tabs fade out in place.
                ForEach(AppTab.allCases, id: \.self) { tab in
                    tabItem(tab, m: m, itemW: itemW, accent: tab == activeTab)
                        .position(x: iconCenterX(tab, W: W, m: m), y: h / 2)
                        .opacity(Double(iconOpacity(tab, m: m)))
                        .allowsHitTesting(iconOpacity(tab, m: m) > 0.5)
                }
            }
            .frame(width: W, height: h, alignment: .topLeading)
            .contentShape(Rectangle())
            // Touch anywhere on the bar to GRAB the selection blob to your finger
            // (it springs over instantly — even a stationary press, no swipe), then
            // it follows 1:1 as you move and commits (switches page) on release.
            // Uses the UIKit 0-duration touch reader because SwiftUI's DragGesture
            // waits for movement before firing on a stationary finger. It observes
            // without stealing the touch, so the tab Buttons still work (a11y, taps).
            .onTouchChanged { down, pt in
                if down { onBlobTouchChanged(x: pt.x, W: W, expanded: selShown) }
                else    { onBlobTouchEnded(x: pt.x, W: W, expanded: selShown) }
            }
            // Initialise the endpoints once, then liquid-slide them on selection
            // changes (taps) when not actively dragging.
            .onChange(of: selX, initial: true) { _, newX in
                if blobLead.isNaN { blobLead = newX; blobTrail = newX }
            }
            .onChange(of: selected) { _, tab in
                if !draggingBlob { moveBlob(to: expandedCenterX(tab, W: W)) }
            }
            // Scope animation to the bar so tab changes slide the selection pill
            // (and colour the icon) and minimize springs the split — without
            // animating the page content behind it.
            .animation(Self.barSpring, value: minimize)
            .animation(Self.barSpring, value: selected)
        }
        .frame(height: BottomBar.tabHeight)
        // Cap Dynamic Type so the labels don't blow up at large accessibility
        // sizes and overflow the pill (like Apple's tab bar). Standard sizes scale.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    // MARK: Tab item (one real icon+label, label collapses on minimize)

    private func tabItem(_ tab: AppTab, m: CGFloat, itemW: CGFloat, accent: Bool) -> some View {
        let labelShown = max(0, 1 - m / 0.5)   // label gone by half-minimized
        // Icon rides slightly above centre when the label is shown (so the
        // icon+label group is centred), and recentres as the label fades — via
        // offsets, so nothing is clipped (the earlier frame-clamp cut descenders).
        return Button {
            onPressTab(tab)         // switch + pop to root (also expands the bar)
        } label: {
            ZStack {
                Image(systemName: tab.icon)
                    .font(.system(size: 23, weight: .medium))
                    .offset(y: -8 * labelShown)
                Text(tab.title)
                    .font(.system(size: 9.5, weight: .medium))
                    .fixedSize()
                    .opacity(Double(labelShown))
                    .offset(y: 12)
            }
            .foregroundStyle(accent ? AnyShapeStyle(Color.accentColor)
                                    : AnyShapeStyle(.secondary))
            .frame(width: itemW, height: BottomBar.tabHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(TabPressStyle())
    }

    // MARK: Liquid selection blob (drag-to-follow + stretch)

    /// Move both blob endpoints to a target centre; the leading edge springs there
    /// faster than the trailing edge, so the capsule stretches in transit and
    /// settles cleanly (no extra bounce).
    private func moveBlob(to target: CGFloat) {
        withAnimation(Self.leadSpring) { blobLead = target }
        withAnimation(Self.trailSpring) { blobTrail = target }
    }

    /// Tab under an x position for the current layout (expanded = even thirds;
    /// minimized = left half is the left blob's tab, right half is Search).
    private func tab(at x: CGFloat, W: CGFloat, expanded: Bool) -> AppTab {
        if !expanded { return x < W / 2 ? leftTab : .search }
        let count = CGFloat(AppTab.allCases.count)
        let i = min(max(Int(x / (W / count)), 0), AppTab.allCases.count - 1)
        return AppTab.allCases[i]
    }

    private func onBlobTouchChanged(x rawX: CGFloat, W: CGFloat, expanded: Bool) {
        let x = min(max(rawX, 0), W)
        // When minimized the now-playing island sits in the centre gap and owns
        // those touches — ignore them here, or an island swipe/tap reads as a tab
        // hit and undocks the bar. Only the two side circles react.
        if barTouchIgnored(x: x, W: W, expanded: expanded) { return }
        hoverTab = tab(at: x, W: W, expanded: expanded)
        guard expanded else { return }
        // Clamp the follow point to between the outer tab centres so the blob
        // stays on the bar.
        let lo = expandedCenterX(AppTab.allCases.first!, W: W)
        let hi = expandedCenterX(AppTab.allCases.last!, W: W)
        let c = min(max(x, lo), hi)
        if !draggingBlob {
            // First touch: GRAB — both endpoints spring over to the finger (so a
            // stationary press-and-hold pulls the blob to you, no swipe needed).
            draggingBlob = true
            blobDownX = x
            blobMoved = false
            withAnimation(Self.leadSpring) { blobLead = c }
            withAnimation(Self.trailSpring) { blobTrail = c }
        } else {
            // Then follow: leading edge tracks the finger 1:1, trailing edge lags
            // on a softer spring → the capsule stretches (liquid) while moving.
            if abs(x - blobDownX) > Self.blobDragSlop { blobMoved = true }
            blobLead = c
            withAnimation(Self.trailSpring) { blobTrail = c }
        }
    }

    private func onBlobTouchEnded(x rawX: CGFloat, W: CGFloat, expanded: Bool) {
        let x = min(max(rawX, 0), W)
        let moved = blobMoved
        let wasGrab = draggingBlob
        draggingBlob = false
        blobMoved = false
        hoverTab = nil
        // Centre-gap touches belong to the island (see onBlobTouchChanged) — never
        // let a release there undock/navigate.
        if barTouchIgnored(x: x, W: W, expanded: expanded) { return }
        let target = tab(at: x, W: W, expanded: expanded)
        if moved {
            // Genuine drag: the touch reader owns the commit. The Button the touch
            // began on won't fire (the touch ended elsewhere), so this is the only
            // commit — no double onPressTab.
            onPressTab(target)
            moveBlob(to: expandedCenterX(target, W: W))
        } else if wasGrab {
            // Stationary tap that grabbed the blob: the tab Button commits the
            // selection (so we DON'T call onPressTab here — that double-call is what
            // bumped the pop-to-root token on every switch). Just settle the grabbed
            // blob onto the target's centre so it doesn't rest at the finger offset.
            moveBlob(to: expandedCenterX(target, W: W))
        }
        // Minimized taps (no grab, no move) are handled entirely by the circle's
        // Button — nothing to commit here.
    }

    /// True when a touch at `x` should be IGNORED by the bar because it falls in the
    /// centre gap that the now-playing island occupies once minimized. With a full
    /// bar (`expanded`) the whole width is the bar, so nothing is ignored. Minimized,
    /// only the two side circles (and their outer margins) react; the gap between
    /// them is the island's — otherwise an island swipe/tap would undock the bar and
    /// switch tabs. Uses the settled circle centres (`circleCenterInset`), which is
    /// accurate whenever the bar is minimized enough for `expanded` to be false.
    private func barTouchIgnored(x: CGFloat, W: CGFloat, expanded: Bool) -> Bool {
        guard !expanded else { return false }
        let r = BottomBar.minCircleD / 2
        let leftCX = BottomBar.circleCenterInset
        let rightCX = W - BottomBar.circleCenterInset
        let onSideCircle = x <= leftCX + r || x >= rightCX - r
        return !onSideCircle
    }

    // MARK: Glass shapes

    private static let pad: CGFloat = 6

    /// The bar's Liquid Glass: two shapes in one `GlassEffectContainer` so the
    /// split renders the native gooey surface-tension bridge. Expanded (m=0) both
    /// are full-width and overlap into one clean bar; minimized (m=1) they're two
    /// 48pt circles at the edges with the now-playing island dropped between them.
    @ViewBuilder
    private func glassLayer(leftCX: CGFloat, rightCX: CGFloat,
                            blobW: CGFloat, blobH: CGFloat, h: CGFloat) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: 22) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: max(blobW, 1), height: blobH)
                        .glassEffect(.regular, in: Capsule())
                        .glassEffectID("bar.left", in: glassNS)
                        .position(x: leftCX, y: h / 2)
                    Color.clear.frame(width: max(blobW, 1), height: blobH)
                        .glassEffect(.regular, in: Capsule())
                        .glassEffectID("bar.search", in: glassNS)
                        .position(x: rightCX, y: h / 2)
                }
            }
        } else {
            // Pre-26 fallback: a single material capsule (no blob morph).
            Capsule().fill(.ultraThinMaterial).frame(height: h)
        }
    }

    // MARK: Icon geometry

    /// Each tab's centre X when expanded (evenly distributed across the bar).
    private func expandedCenterX(_ tab: AppTab, W: CGFloat) -> CGFloat {
        let i = CGFloat(AppTab.allCases.firstIndex(of: tab) ?? 0)
        let usable = W - 2 * Self.pad
        return Self.pad + usable / CGFloat(AppTab.allCases.count) * (i + 0.5)
    }

    /// Animated centre X: the left-blob tab → left circle centre, Search → right
    /// circle centre, others stay put (and fade).
    private func iconCenterX(_ tab: AppTab, W: CGFloat, m: CGFloat) -> CGFloat {
        let start = expandedCenterX(tab, W: W)
        let ci = BottomBar.circleCenterInset
        if tab == .search {
            return lerpBar(start, W - ci, m)
        } else if tab == leftTab {
            return lerpBar(start, ci, m)
        }
        return start
    }

    /// The left-blob tab and Search survive minimize; other tabs fade out in place.
    private func iconOpacity(_ tab: AppTab, m: CGFloat) -> CGFloat {
        if tab == .search || tab == leftTab { return 1 }
        return max(0, 1 - m / 0.5)
    }
}

private func lerpBar(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

// MARK: - Tab press style

/// Plain tab button style: a subtle scale dip while pressed for tactile feedback.
private struct TabPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Scroll-driven bottom-bar minimize

private struct BottomBarMinimizeKey: EnvironmentKey {
    static let defaultValue: Binding<CGFloat>? = nil
}

extension EnvironmentValues {
    /// The floating tab bar's minimize progress (0 = full bar, 1 = blob split),
    /// injected by `MainTabsView` so a page's scroll view can drive it.
    var bottomBarMinimize: Binding<CGFloat>? {
        get { self[BottomBarMinimizeKey.self] }
        set { self[BottomBarMinimizeKey.self] = newValue }
    }
}

extension View {
    /// Drives the floating tab bar's minimize (blob split) from THIS scroll view:
    /// scrolling down past a threshold splits the bar into two glass blobs; coming
    /// back near the top re-docks it. Apply directly to a `ScrollView`/`List`
    /// (`onScrollGeometryChange` only observes the scroll view it's attached to).
    /// It's a no-op unless the `bottomBarMinimize` binding is in the environment —
    /// which `MainTabsView` injects ONLY into the selected tab, so background tabs
    /// can't drive it. No-op before iOS 18.
    func minimizesBottomBarOnScroll() -> some View {
        modifier(BottomBarScrollMinimize())
    }
}

private struct BottomBarScrollMinimize: ViewModifier {
    @Environment(\.bottomBarMinimize) private var minimize

    // `y` (contentOffset + top inset) is ~0 at rest and grows as you scroll DOWN,
    // so it IS the distance from the top. Scroll down past `enterZone` to minimize;
    // it re-docks only within `topZone` of the top (Apple doesn't re-dock on a
    // mid-list up-flick).
    private static let enterZone: CGFloat = 90
    private static let topZone: CGFloat = 44

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentOffset.y + geo.contentInsets.top
                } action: { _, y in
                    handle(y)
                }
        } else {
            content
        }
    }

    private func handle(_ y: CGFloat) {
        guard let minimize else { return }
        if y <= Self.topZone {
            setMinimize(0)                          // near the top → docked
        } else if y >= Self.enterZone {
            setMinimize(1)                          // scrolled well down → minimized
        }
        // Between the zones: hold the current state (hysteresis).
    }

    private func setMinimize(_ v: CGFloat) {
        guard minimize?.wrappedValue != v else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            minimize?.wrappedValue = v
        }
    }
}
