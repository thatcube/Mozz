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
    /// Tabs visited at least once — mounted (and kept mounted) so their
    /// navigation/scroll state survives switching, but not built until first used.
    @State private var loadedTabs: Set<AppTab> = [.home]

    private var hasTrack: Bool { playback.currentTrack != nil }

    var body: some View {
        ZStack(alignment: .bottom) {
            pages
            // The floating tab bar sits a fixed distance from the true bottom
            // edge (not pinned to the safe area), so it ignores the bottom safe
            // area and pads up by `edgeMargin`.
            MainTabBar(selected: $selectedTab)
                .padding(.horizontal, BottomBar.hMargin)
                .padding(.bottom, BottomBar.edgeMargin)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(.container, edges: .bottom)
            if hasTrack {
                NowPlayingMorphContainer(playback: playback, ui: ui)
                    .zIndex(100)
            }
        }
        .onChange(of: selectedTab) { _, tab in loadedTabs.insert(tab) }
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
        case .library: "music.note.list"
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

/// The floating tab bar: a full-width Liquid Glass capsule with the three tabs
/// evenly distributed, matching Apple Music's wide bar. Bottom-aligned in the
/// safe area so it sits just above the home indicator.
struct MainTabBar: View {
    @Binding var selected: AppTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button {
                    selected = tab
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 17, weight: .semibold))
                        Text(tab.title)
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(tab == selected ? AnyShapeStyle(Color.accentColor)
                                                      : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: BottomBar.tabHeight)
        // Cap Dynamic Type so the labels don't blow up at large accessibility
        // sizes and overflow the pill (like Apple's tab bar). Standard sizes scale.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .tabBarGlass()
    }
}

private extension View {
    /// Liquid Glass capsule on iOS 26+, a material fallback below it.
    @ViewBuilder
    func tabBarGlass() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }
}
