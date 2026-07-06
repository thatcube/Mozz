import SwiftUI

/// A standalone Play + Shuffle bar for browse lists that have no hero (Songs,
/// Albums). It mirrors the detail pages' actions but is styled for the plain app
/// background instead of a colored hero: two equal-weight capsules filled with a
/// material and labelled in the app accent color, so it adapts to light/dark and
/// matches the rest of the chrome.
struct LibraryPlayShuffleBar: View {
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            button("Play", systemImage: "play.fill", action: play)
            button("Shuffle", systemImage: "shuffle", action: shuffle)
        }
    }

    private func button(_ title: String, systemImage: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
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
