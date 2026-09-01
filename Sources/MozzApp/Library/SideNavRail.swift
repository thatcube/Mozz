import SwiftUI

/// The tab bar, stood on its end.
///
/// Used instead of the bar once the window has room for two columns — an iPad,
/// a Max phone in landscape, a folding phone opened out. Navigation *moves*
/// rather than duplicating: there is never a rail and a bar at the same time, so
/// there is never a question about which one owns the selection.
///
/// It is the same floating capsule the bar is, in the same material, the same
/// distance from its edge — not a full-height column ruled down the window.
/// That is the iOS half of the parity: Android's rail is flat because that is
/// what a Material rail is, and this one floats because that is what this app's
/// navigation has been since it was a bar. What both agree on is where the
/// content starts and where the dock sits, which is the part the morph depends
/// on.
struct SideNavRail: View {
    @Binding var selected: AppTab
    /// Called when a destination is pressed — including a re-press of the one you
    /// are already on, which pops it to root. Same contract as the bar's.
    var onPressTab: (AppTab) -> Void

    @AppStorage("mozz.liquidGlass") private var liquidGlassEnabled = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @StateObject private var power = LowPowerModeObserver()
    @Environment(\.colorScheme) private var scheme
    // Observed so the chrome token re-resolves live when the dark flavour
    // (Dim ↔ Black) toggles; the flavour is not a trait, so nothing else would
    // invalidate this view.
    @AppStorage(Color.MozzDarkStyle.storageKey) private var darkStyleRaw = Color.MozzDarkStyle.default.rawValue

    private var blackout: Bool { Color.mozzIsBlackout(scheme) }

    private var useGlass: Bool {
        MozzChrome.useGlass(enabled: liquidGlassEnabled,
                            lowPower: power.isLowPower,
                            reduceTransparency: reduceTransparency,
                            blackout: blackout)
    }

    private static let railSpring = Animation.spring(response: 0.5, dampingFraction: 0.8)

    var body: some View {
        ZStack(alignment: .top) {
            railCapsule

            // The selection lozenge, slid to the destination you are on. The
            // bar's version can be dragged and stretches as it travels; this one
            // cannot, because there is no rail gesture to drag it with — a
            // stretch nobody can cause is decoration, not feedback.
            selectionLozenge

            VStack(spacing: SideNav.itemSpacing) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    item(tab)
                }
            }
            .padding(.vertical, SideNav.vPadding)
        }
        .frame(width: SideNav.barWidth, height: SideNav.barHeight)
        .animation(Self.railSpring, value: selected)
        // Cap Dynamic Type so the labels can't overflow the capsule at large
        // accessibility sizes, exactly as the bar does. Standard sizes scale.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    // MARK: Chrome

    @ViewBuilder private var railCapsule: some View {
        if useGlass, #available(iOS 26.0, macOS 26.0, *) {
            Capsule().fill(.clear)
                .glassEffect(.regular, in: Capsule())
        } else if useGlass {
            Capsule().fill(.ultraThinMaterial)
        } else if blackout {
            // In Black the chrome surface *is* the page's black, so the rail
            // needs an edge or there is nothing to say where it starts.
            Capsule()
                .fill(Color.black)
                .overlay(Capsule().strokeBorder(Color.mozzHairline, lineWidth: 1))
        } else {
            Capsule().fill(Color.mozzChrome)
        }
    }

    private var selectionLozenge: some View {
        let index = CGFloat(AppTab.allCases.firstIndex(of: selected) ?? 0)
        let h = SideNav.itemHeight
        let y = SideNav.vPadding + index * (h + SideNav.itemSpacing) + h / 2
        return Capsule()
            .fill(blackout ? Color.clear : Color.primary.opacity(0.14))
            .overlay {
                if blackout {
                    Capsule().strokeBorder(Color.mozzHairline, lineWidth: 1)
                }
            }
            .frame(width: SideNav.barWidth - 2 * SideNav.selectionInset, height: h)
            .position(x: SideNav.barWidth / 2, y: y)
            .allowsHitTesting(false)
    }

    // MARK: Destination

    private func item(_ tab: AppTab) -> some View {
        let accent = tab == selected
        return Button {
            onPressTab(tab)
        } label: {
            VStack(spacing: 3) {
                Image(accent ? tab.selectedIcon : tab.icon, bundle: .module)
                    .resizable().scaledToFit()
                    .frame(width: 30, height: 30)
                Text(tab.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(accent ? AnyShapeStyle(Color.accentColor)
                                    : AnyShapeStyle(.secondary))
            .frame(width: SideNav.barWidth, height: SideNav.itemHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(TabPressStyle())
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(accent ? [.isButton, .isSelected] : .isButton)
    }
}
