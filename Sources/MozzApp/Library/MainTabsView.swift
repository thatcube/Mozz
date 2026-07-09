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
    @Environment(PlaybackEngine.self) private var playback
    @StateObject private var ui = PlayerUIModel()

    @State private var selectedTab: AppTab = .home
    /// Appearance override (System/Light/Dark) and dark flavor (Dim/Black-OLED).
    /// Observed here so changes drive `preferredColorScheme` + a token rebuild.
    @AppStorage(Color.MozzAppearance.storageKey) private var appearanceRaw = Color.MozzAppearance.default.rawValue
    @AppStorage(Color.MozzDarkStyle.storageKey) private var darkStyleRaw = Color.MozzDarkStyle.default.rawValue
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
    /// Per-tab navigation paths (value-based routing). Each tab's `NavigationStack`
    /// binds to its path, so pop-to-root is an animated `path.removeAll()` and the
    /// path is programmatic (future deep links / state restoration). Switching tabs
    /// preserves each tab's depth because its path persists here.
    @State private var paths: [AppTab: [AppRoute]] = [:]

    /// Bumped whenever the active tab is re-tapped; the visible tab's root scroll
    /// view watches `\.scrollToTopSignal` and scrolls to the top.
    @State private var scrollToTopToken = 0

    /// Bumped only when the Search tab is re-tapped while already active; the
    /// Search view watches `\.searchReselectSignal` and focuses the field.
    @State private var searchReselectToken = 0

    /// Bumped when the user leaves the Search tab; the Search view watches
    /// `\.searchBlurSignal` and drops focus so the keyboard doesn't linger over
    /// another tab.
    @State private var searchBlurToken = 0

    /// Generation guard so that when several deep links arrive in quick
    /// succession, only the most-recent one applies (older, slower DB lookups
    /// can't win a race — see `consumePendingDeepLinkIfNeeded`).
    @State private var deepLinkGeneration = 0

    /// A binding to one tab's path (dictionary subscript with an empty default).
    private func pathBinding(_ tab: AppTab) -> Binding<[AppRoute]> {
        Binding(get: { paths[tab] ?? [] }, set: { paths[tab] = $0 })
    }

    /// While `Date.now < expandLockUntil`, scroll-driven minimize writes are dropped
    /// (see `scrollMinimizeBinding`) so a tab-tap's expand animation isn't interrupted.
    @State private var expandLockUntil: Date = .distantPast

    /// Handle a tab-bar press. Switching tabs preserves each tab's navigation depth;
    /// re-tapping the tab you're already on pops it to root (standard iOS behavior).
    private func pressTab(_ tab: AppTab) {
        if tab == selectedTab {
            // Re-tap → animated pop to root (no-op if already at root)…
            if !(paths[tab] ?? []).isEmpty {
                withAnimation { paths[tab] = [] }
            }
            // …and scroll the (now root) page to the top.
            scrollToTopToken &+= 1
            // Re-tapping Search when already there also focuses its field.
            if tab == .search {
                searchReselectToken &+= 1
            }
        }
        selectedTab = tab
        // Tapping a tab ALWAYS expands the bar — and must always finish expanding.
        // Start a cooldown so scroll-driven minimize (from momentum, or the content
        // inset shifting as the bar grows / the page transitions) can't re-collapse
        // it mid-animation. See `scrollMinimizeBinding`. Wrap the change in the shared
        // bar spring so the ISLAND animates its un-drop too: the tab bar has its own
        // `.animation(_, value: minimize)`, but the now-playing island container reads
        // `minimize` directly, so without this transaction it would snap to full size
        // while the bar springs. (The scroll path already animates via `setMinimize`.)
        expandLockUntil = Date.now + Self.expandCooldown
        withAnimation(Self.expandSpring) { minimize = 0 }
        loadedTabs.insert(tab)
    }

    /// How long after a tab press to ignore scroll-driven collapse, so the expand
    /// animation always plays out. Covers the spring settle + any page-transition
    /// layout that shifts the scroll geometry.
    private static let expandCooldown: TimeInterval = 0.7
    /// Matches `MainTabBar.barSpring` and the scroll-minimize spring so the bar,
    /// the island drop, and a tap-driven expand all move on the same curve.
    private static let expandSpring = Animation.spring(response: 0.5, dampingFraction: 0.8)

    /// The binding handed to page scroll views to drive the bar's minimize. Unlike a
    /// plain `$minimize`, its setter DROPS writes while the expand cooldown is active,
    /// so a tab tap's expand-to-full always completes even if the page is mid-scroll
    /// or its height is changing during a transition.
    private var scrollMinimizeBinding: Binding<CGFloat> {
        Binding(
            get: { minimize },
            set: { newValue in
                if Date.now < expandLockUntil { return }
                minimize = newValue
            }
        )
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
            ToastOverlayView(hasTrack: hasTrack)
                .zIndex(110)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SyncStatusBar()
                .animation(.spring(response: 0.4, dampingFraction: 0.9), value: env.isSyncing)
        }
        .onChange(of: selectedTab) { old, tab in
            loadedTabs.insert(tab)
            if tab != .search {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    lastNonSearchTab = tab
                }
                // Leaving Search: blur its field so the keyboard doesn't stay open
                // over the new tab (all tabs remain mounted, so nothing else
                // dismisses it).
                if old == .search {
                    searchBlurToken &+= 1
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
        .task { consumePendingDeepLinkIfNeeded() }
        .onChange(of: env.pendingDeepLink) { _, _ in consumePendingDeepLinkIfNeeded() }
        .onChange(of: env.pendingNav) { _, _ in consumePendingNavIfNeeded() }
        // Force light/dark (or follow system) per the appearance setting.
        .preferredColorScheme((Color.MozzAppearance(rawValue: appearanceRaw) ?? .system).colorScheme)
        // NOTE: `darkStyleRaw` is observed (above) so this view re-renders when the
        // dark flavor toggles, refreshing the tab-bar chrome token. We deliberately
        // do NOT `.id()` the tree on it — that resets navigation state and dismisses
        // the open Settings sheet. Screen backgrounds refresh via the observing
        // `mozzScreenBackground()` modifier instead.
    }

    /// Apply any queued deep-link / Handoff destination now that the tab UI is on
    /// screen: switch to its tab and set that tab's navigation path (resolving the
    /// record payload from the local catalog). Clears the queue when handled.
    private func consumePendingDeepLinkIfNeeded() {
        guard let target = env.pendingDeepLink else { return }
        // Clear synchronously and take a generation token BEFORE the async
        // resolve, so a second link that arrives while this one's DB lookup is in
        // flight supersedes it (latest intent wins; no out-of-order apply).
        env.pendingDeepLink = nil
        deepLinkGeneration &+= 1
        let generation = deepLinkGeneration
        Task {
            guard let (tab, routes) = await env.resolveDeepLink(target),
                  generation == deepLinkGeneration else { return }
            loadedTabs.insert(tab)
            expandLockUntil = Date.now + Self.expandCooldown
            withAnimation(Self.expandSpring) {
                selectedTab = tab
                paths[tab] = routes
                minimize = 0
            }
        }
    }

    /// Apply a queued in-app navigation (Go to Artist / Album from a track menu).
    /// Unlike a deep link this route is already resolved, so we push it directly.
    /// A row-issued command pushes onto the CURRENT tab; a player-issued one
    /// targets a canonical tab (Library, captured here — `selectedTab` may be
    /// Search), pushes FIRST behind the still-presented player, then collapses the
    /// player to reveal it. Bumps the shared deep-link generation so any in-flight
    /// deep-link resolve is superseded (latest intent wins).
    private func consumePendingNavIfNeeded() {
        guard let cmd = env.pendingNav else { return }
        env.pendingNav = nil
        deepLinkGeneration &+= 1
        let targetTab: AppTab = cmd.origin == .player ? .library : selectedTab
        loadedTabs.insert(targetTab)
        expandLockUntil = Date.now + Self.expandCooldown
        withAnimation(Self.expandSpring) {
            if cmd.origin == .player { selectedTab = targetTab }
            paths[targetTab, default: []].append(cmd.route)
            minimize = 0
        }
        if cmd.origin == .player { ui.isFullPresented = false }
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
                        // nil binding and stay inert. The gated binding also drops
                        // scroll writes during a tab-tap's expand cooldown.
                        .environment(\.bottomBarMinimize, tab == selectedTab ? scrollMinimizeBinding : nil)
                        .environment(\.scrollToTopSignal, scrollToTopToken)
                        .environment(\.searchReselectSignal, searchReselectToken)
                        .environment(\.searchBlurSignal, searchBlurToken)
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
        case .home:    HomeView(path: pathBinding(.home))
        case .library: LibraryHomeView(path: pathBinding(.library))
        case .search:  SearchView(path: pathBinding(.search))
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

    /// Same navigation-chrome look as the player: real Liquid Glass by default,
    /// a solid `mozzChrome` surface when the user turns Liquid Glass off, in Low
    /// Power Mode, or with Reduce Transparency — so the bar, island, and player
    /// always match (they read as one continuous navigation surface).
    @AppStorage("mozz.liquidGlass") private var liquidGlassEnabled = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @StateObject private var power = LowPowerModeObserver()
    private var useGlass: Bool {
        liquidGlassEnabled && !power.isLowPower && !reduceTransparency
    }

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
                Image(mozz: tab.icon)
                    .resizable().scaledToFit()
                    .frame(width: 30, height: 30)
                    .offset(y: -8 * labelShown)
                Text(tab.title)
                    .font(.system(size: 11, weight: .medium))
                    .fixedSize()
                    .opacity(Double(labelShown))
                    .offset(y: 14)
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
        if useGlass, #available(iOS 26.0, macOS 26.0, *) {
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
        } else if useGlass {
            // Pre-26 fallback: a single material capsule (no blob morph).
            Capsule().fill(.ultraThinMaterial).frame(height: h)
        } else {
            // Solid chrome (Liquid Glass off / Low Power / Reduce Transparency):
            // two opaque capsules matching the player + island surface.
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.mozzChrome)
                    .frame(width: max(blobW, 1), height: blobH)
                    .position(x: leftCX, y: h / 2)
                Capsule().fill(Color.mozzChrome)
                    .frame(width: max(blobW, 1), height: blobH)
                    .position(x: rightCX, y: h / 2)
            }
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

// MARK: - Scroll-to-top on active-tab re-tap

private struct ScrollToTopSignalKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

extension EnvironmentValues {
    /// A monotonically-increasing token bumped by `MainTabsView` when the user
    /// re-taps the tab they're already on. A tab's root scroll view watches it and
    /// scrolls to the top (standard iOS behavior), complementing the pop-to-root.
    var scrollToTopSignal: Int {
        get { self[ScrollToTopSignalKey.self] }
        set { self[ScrollToTopSignalKey.self] = newValue }
    }
}

private struct SearchReselectSignalKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

extension EnvironmentValues {
    /// A monotonically-increasing token bumped by `MainTabsView` ONLY when the
    /// user re-taps the Search tab while already on it. `SearchView` watches it to
    /// focus the field + open the keyboard. Dedicated to Search (unlike
    /// `scrollToTopSignal`, which fires for every tab's re-tap) so re-tapping
    /// another tab can't focus the (background) search field.
    var searchReselectSignal: Int {
        get { self[SearchReselectSignalKey.self] }
        set { self[SearchReselectSignalKey.self] = newValue }
    }
}

private struct SearchBlurSignalKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

extension EnvironmentValues {
    /// A monotonically-increasing token bumped by `MainTabsView` when the user
    /// leaves the Search tab. `SearchView` watches it to drop focus so the
    /// keyboard doesn't stay open over another tab (all tabs stay mounted).
    var searchBlurSignal: Int {
        get { self[SearchBlurSignalKey.self] }
        set { self[SearchBlurSignalKey.self] = newValue }
    }
}

extension View {
    /// Scrolls THIS scroll view to the top whenever the `scrollToTopSignal`
    /// environment token changes (i.e. the active tab was re-tapped). Apply to a
    /// tab's root `ScrollView`/`List`. No-op before iOS 18.
    func scrollsToTopOnSignal() -> some View {
        modifier(ScrollToTopOnSignal())
    }
}

private struct ScrollToTopOnSignal: ViewModifier {
    @Environment(\.scrollToTopSignal) private var signal

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            ScrollToTopOnSignalModern(signal: signal, content: content)
        } else {
            content
        }
    }
}

@available(iOS 18.0, macOS 15.0, *)
private struct ScrollToTopOnSignalModern<Content: View>: View {
    let signal: Int
    let content: Content
    @State private var position = ScrollPosition(edge: .top)

    var body: some View {
        content
            .scrollPosition($position)
            .onChange(of: signal) { _, _ in
                withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
                    position.scrollTo(edge: .top)
                }
            }
    }
}
