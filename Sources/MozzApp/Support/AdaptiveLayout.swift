import SwiftUI

// MARK: - Adaptive layout rules
//
// Where navigation, the dock and the player sit at a given width — as rules,
// not as `if wide` scattered through the views.
//
// The twin of Android's `PlayerLayout.kt`, and deliberately the same shape:
// arithmetic and enums, no view code, so what travels between the clients is the
// *reasoning* — which panel shows where, what the dock morphs from — rather than
// a screenful of one platform's UI framework. Anything a second client would
// have to guess at belongs here with a comment saying why.
//
// See ADR-0016.

/// How the expanded player arranges itself.
///
/// Note there is exactly one piece of *state* behind this — `PlayerPanel?` — and
/// width only decides how that state is drawn. That is the whole design: closing
/// the queue means the same thing on a phone and an iPad, so rotating (or, on a
/// folding phone, unfolding) mid-song rearranges the screen without ever
/// changing what you asked for.
enum PlayerPresentation: Equatable {
    /// No panel: artwork centred, given the whole width.
    case artwork

    /// Player on the left, queue or lyrics in a column of their own on the right.
    case panelBeside

    /// The panel takes the artwork's place, leaving the transport where it was.
    /// The only honest option when there is one column.
    case panelInstead
}

/// The rule. Two inputs, three outcomes, no hidden state.
func playerPresentation(wide: Bool, panel: PlayerPanel?) -> PlayerPresentation {
    guard panel != nil else { return .artwork }
    return wide ? .panelBeside : .panelInstead
}

/// The navigation rail: the bottom bar stood on its end, used instead of it once
/// there is width for two columns.
///
/// The dock does **not** move with it. It is the same floating pill at every
/// width — bottom of the content area, capped at `BottomBar.dockMaxWidth` — and
/// only what it clears changes: a tab bar's worth on a phone, nothing beside a
/// rail. That is what lets one morph serve both instead of a phone morph and a
/// tablet morph that drift apart.
enum SideNav {
    /// The rail's own width. Thicker than the bar is tall, because a vertical
    /// item stacks a 30pt glyph over its label with nothing either side to
    /// borrow room from, and "Library" has to fit without shrinking.
    static let barWidth: CGFloat = 76

    /// Inset from the window's leading edge — the same margin the tab bar keeps
    /// from the bottom, so the two read as one floating object rotated.
    static let edgeMargin: CGFloat = BottomBar.edgeMargin

    /// Gap between the rail and the content it sits beside.
    static let contentGap: CGFloat = 12

    /// What a page has to leave clear on its leading edge.
    static var contentInset: CGFloat { edgeMargin + barWidth + contentGap }

    /// One destination: a 30pt glyph over an 11pt label, with the same air
    /// around it that the bar's items get.
    static let itemHeight: CGFloat = 64
    static let itemSpacing: CGFloat = 2

    /// Padding above the first destination and below the last.
    static let vPadding: CGFloat = 8

    /// The rail's height, which is its contents' — it is a capsule floating
    /// beside the page, not a column ruled down the window.
    static var barHeight: CGFloat {
        let n = CGFloat(AppTab.allCases.count)
        return 2 * vPadding + n * itemHeight + (n - 1) * itemSpacing
    }

    /// Inset of the selection lozenge inside the rail capsule, shared on every
    /// edge so the lozenge stays concentric with it.
    static let selectionInset: CGFloat = 5
}

/// The one place that decides whether navigation chrome is glass or solid, so
/// the bar, the rail, the dock and the player can never disagree about it.
///
/// They did disagree once: the tab bar knew Black turns glass off and the dock
/// did not, so the two sat side by side in different materials. The rule lives
/// here now and each surface asks.
enum MozzChrome {
    /// Glass is a lit, frosted surface — a lighter shade of whatever is behind
    /// it by definition — which is the one thing Black does not allow. The solid
    /// path already existed for Low Power and Reduce Transparency; Black is a
    /// third reason to take it.
    static func useGlass(enabled: Bool,
                         lowPower: Bool,
                         reduceTransparency: Bool,
                         blackout: Bool) -> Bool {
        enabled && !lowPower && !reduceTransparency && !blackout
    }
}
