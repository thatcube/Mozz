import SwiftUI

/// Small shared state that bridges the native tab-bar accessory (which the
/// system hosts in its own context) and the custom full-screen player overlay.
///
/// The accessory publishes the on-screen (global) frame of its artwork so the
/// full player can fly its own artwork exactly into that slot on dismiss, and a
/// flag so the accessory can hide its artwork while the full player owns it.
final class PlayerUIModel: ObservableObject {
    /// The mini-player artwork's frame in global (screen) coordinates.
    ///
    /// Deliberately **not** `@Published`: the accessory writes this on every
    /// layout pass, and if it were observed it would re-render `MainTabsView`,
    /// relayout the accessory, and re-emit the frame — an infinite loop that
    /// pegs the CPU. The full player only reads it at present/dismiss time, so a
    /// plain stored property (updated silently) is exactly what we want.
    var miniArtFrame: CGRect = .zero
    /// True while the full-screen player is presented; the accessory hides its
    /// own artwork so the full player's traveling artwork is the only one shown.
    @Published var isFullPresented: Bool = false
}

/// Reports the mini artwork's global frame up to the accessory, which copies it
/// into `PlayerUIModel`. Global coordinates are absolute screen space, so they
/// remain valid across the system's accessory-hosting boundary.
struct MiniArtFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
