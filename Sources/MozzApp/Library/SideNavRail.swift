import SwiftUI

/// The app's three places, in a column of their own.
///
/// Used instead of the bottom bar once the window has room for two columns — an
/// iPad, a Max phone in landscape, a folding phone opened out. Navigation
/// *moves* rather than duplicating: there is never a rail and a bar at the same
/// time, so there is never a question about which one owns the selection.
///
/// It is a column, not a floating capsule. The page starts where this ends and
/// nothing runs underneath it: a navigation surface laid over the content it
/// navigates reads as something in the way. That is also what both references
/// do — Apple Music's iPad sidebar pushes its content aside, and Android's rail
/// is a sibling in a `Row` — so the three clients agree on where the content
/// begins even where they disagree on paint.
///
/// The dock is the exception, and deliberately: it stays a floating pill over
/// the content area, because it is the player collapsed and has to be able to
/// grow into the player.
struct SideNavRail: View {
    @Binding var selected: AppTab
    /// Called when a destination is pressed — including a re-press of the one you
    /// are already on, which pops it to root. Same contract as the bar's.
    var onPressTab: (AppTab) -> Void

    @Environment(\.colorScheme) private var scheme
    // Observed so the tokens below re-resolve live when the dark flavour
    // (Dim ↔ Black) toggles; the flavour is not a trait, so nothing else would
    // invalidate this view.
    @AppStorage(Color.MozzDarkStyle.storageKey) private var darkStyleRaw = Color.MozzDarkStyle.default.rawValue

    private var blackout: Bool { Color.mozzIsBlackout(scheme) }

    private static let railSpring = Animation.spring(response: 0.5, dampingFraction: 0.8)

    var body: some View {
        VStack(spacing: SideNav.itemSpacing) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                item(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, SideNav.topPadding)
        .frame(width: SideNav.columnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        // The page floor, run to the window's own edges: the column is part of
        // the page's ground, not a card sitting on it.
        .background(Color.mozzBackground.ignoresSafeArea())
        // One hairline where the two columns meet. In Black it is the only thing
        // separating them; in Dim and Light it is what a sidebar has anyway.
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.mozzHairline)
                .frame(width: 1)
                .ignoresSafeArea()
        }
        .animation(Self.railSpring, value: selected)
        // Cap Dynamic Type so the labels can't overflow the column at large
        // accessibility sizes, exactly as the bar does. Standard sizes scale.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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
            .frame(maxWidth: .infinity)
            .frame(height: SideNav.itemHeight)
            .background { if accent { selectionLozenge } }
            .contentShape(Rectangle())
        }
        .buttonStyle(TabPressStyle())
        .padding(.horizontal, SideNav.selectionInset)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(accent ? [.isButton, .isSelected] : .isButton)
    }

    /// A wash in Dim and Light; in Black an outline, because a lifted capsule is
    /// exactly the lighter-shade-of-the-page that mode does without. The same
    /// choice the bottom bar's selection makes, so the two read as one control
    /// stood on its end.
    @ViewBuilder private var selectionLozenge: some View {
        if blackout {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.mozzHairline, lineWidth: 1)
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.10))
        }
    }
}
