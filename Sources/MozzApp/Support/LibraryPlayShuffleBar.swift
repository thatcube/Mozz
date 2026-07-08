import SwiftUI

/// A standalone Play + Shuffle bar for browse lists that have no hero (Songs,
/// Albums). It mirrors the detail pages' actions but is styled for the plain app
/// background instead of a colored hero: two equal-weight capsules filled with a
/// material and labelled in the app accent color, so it adapts to light/dark and
/// matches the rest of the chrome.
struct LibraryPlayShuffleBar: View {
    let play: () -> Void
    let shuffle: () -> Void
    /// Optional "Smart Shuffle" (taste-ranked) action. When provided, it's
    /// offered via a long-press context menu on the Shuffle button so a plain
    /// tap still shuffles immediately.
    var smartShuffle: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            button("Play", systemImage: "play.fill", action: play)
            button("Shuffle", systemImage: "shuffle", action: shuffle)
                .contextMenu { smartShuffleMenu }
        }
    }

    @ViewBuilder private var smartShuffleMenu: some View {
        if let smartShuffle {
            Button(action: smartShuffle) {
                Label("Smart Shuffle", mozz: "wand.and.stars")
            }
        }
    }

    private func button(_ title: String, systemImage: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, mozz: systemImage)
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
