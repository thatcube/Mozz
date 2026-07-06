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
            MainTabBar(selected: $selectedTab, leftTab: leftTab, minimize: $minimize)
                .padding(.horizontal, BottomBar.hMargin)
                .padding(.bottom, BottomBar.edgeMargin)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                // Ignore the bottom container inset AND the keyboard, so the
                // floating bar stays pinned to the screen's bottom edge and the
                // keyboard rises over it instead of shoving it up.
                .ignoresSafeArea(.container, edges: .bottom)
                .ignoresSafeArea(.keyboard, edges: .bottom)
            if hasTrack {
                NowPlayingMorphContainer(playback: playback, ui: ui)
                    .zIndex(100)
            }
            // TEMP debug: toggle the minimize morph so the blob split can be tuned
            // before it's wired to scroll. Removed once scroll drives it.
            Button {
                minimize = minimize < 0.5 ? 1 : 0
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.headline)
                    .padding(10)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.trailing, 16)
            .zIndex(200)
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
        case .home:    HomeView()
        case .library: LibraryHomeView()
        case .search:  SearchView()
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
    /// 0 = expanded (full bar), 1 = minimized (two blobs). Interpolated.
    @Binding var minimize: CGFloat

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
    /// Tab under the finger while dragging (drives the accent colour live).
    @State private var hoverTab: AppTab?
    private static let leadSpring = Animation.spring(response: 0.24, dampingFraction: 0.72)
    private static let trailSpring = Animation.spring(response: 0.46, dampingFraction: 0.70)

    // Minimized resting blob widths (points). In the EXPANDED state both shapes
    // span the full width and overlap exactly, so their union renders as one
    // clean capsule (no middle "waist"); as `minimize`→1 the left shape shrinks
    // toward the left and the search shape toward the right, and they pull apart
    // with the container's gooey split.
    private static let searchMinW: CGFloat = 74
    private static let leftMinW: CGFloat = 92

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let h = BottomBar.tabHeight
            let m = min(max(minimize, 0), 1)
            let leftW = lerpBar(W, Self.leftMinW, m)
            let searchW = lerpBar(W, Self.searchMinW, m)
            let searchX = W - searchW
            // Fixed per-tab width so the selection lozenge is the SAME size at
            // every tab (consistent as it slides between them).
            let itemW = max((W - 2 * Self.pad) / CGFloat(AppTab.allCases.count) - 8, 56)
            // The selection pill only lives while the full bar is (near) present;
            // it fades out over the first third of the minimize, before the split.
            let selShown = m < 0.35
            let selFade = Double(max(0, 1 - m / 0.35))
            let selX = iconCenterX(selected, W: W, leftW: leftW, searchW: searchW, m: m)
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
                // The bar's Liquid Glass split blob shapes.
                glassLayer(leftW: leftW, searchW: searchW, searchX: searchX, h: h)

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
                        .position(x: iconCenterX(tab, W: W, leftW: leftW,
                                                 searchW: searchW, m: m),
                                  y: h / 2)
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
            self.selected = tab
            minimize = 0            // any tap on a blob expands the bar back to full
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
            withAnimation(Self.leadSpring) { blobLead = c }
            withAnimation(Self.trailSpring) { blobTrail = c }
        } else {
            // Then follow: leading edge tracks the finger 1:1, trailing edge lags
            // on a softer spring → the capsule stretches (liquid) while moving.
            blobLead = c
            withAnimation(Self.trailSpring) { blobTrail = c }
        }
    }

    private func onBlobTouchEnded(x rawX: CGFloat, W: CGFloat, expanded: Bool) {
        let x = min(max(rawX, 0), W)
        let target = tab(at: x, W: W, expanded: expanded)
        let wasDragging = draggingBlob
        draggingBlob = false
        hoverTab = nil
        // Only commit if we actually engaged (grabbed). A stray end without a begin
        // shouldn't navigate.
        guard wasDragging || !expanded else { return }
        selected = target
        minimize = 0
        moveBlob(to: expandedCenterX(target, W: W))
    }

    // MARK: Icon geometry

    private static let pad: CGFloat = 6

    /// The bar's Liquid Glass split blob shapes (left + Search), in one container
    /// so the blob split renders the native gooey surface-tension bridge when the
    /// bar minimizes.
    @ViewBuilder
    private func glassLayer(leftW: CGFloat, searchW: CGFloat, searchX: CGFloat, h: CGFloat) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: 22) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: max(leftW, 1), height: h)
                        .glassEffect(.regular, in: Capsule())
                        .glassEffectID("bar.left", in: glassNS)
                    Color.clear.frame(width: max(searchW, 1), height: h)
                        .glassEffect(.regular, in: Capsule())
                        .glassEffectID("bar.search", in: glassNS)
                        .offset(x: searchX)
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

    /// Animated centre X: the left-blob tab → left blob centre, Search → right
    /// blob centre, others stay put (and fade).
    private func iconCenterX(_ tab: AppTab, W: CGFloat, leftW: CGFloat, searchW: CGFloat, m: CGFloat) -> CGFloat {
        let start = expandedCenterX(tab, W: W)
        if tab == .search {
            return lerpBar(start, W - Self.searchMinW / 2, m)
        } else if tab == leftTab {
            return lerpBar(start, Self.leftMinW / 2, m)
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
