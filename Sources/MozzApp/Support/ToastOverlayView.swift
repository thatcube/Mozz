import SwiftUI

/// Renders the current toast as a floating card near the bottom of the screen,
/// above the tab bar (and the now-playing island, when a track is loaded).
///
/// Hosted in ``MainTabsView``'s bottom `ZStack`. It stays clear of the floating
/// bar/island by offsetting up by their measured heights (Material's "anchor
/// above the bottom nav" rule) and sits below the full-player morph in z-order.
struct ToastOverlayView: View {
    @EnvironmentObject private var toasts: ToastCenter
    /// Whether the now-playing island is showing, so we clear it too.
    var hasTrack: Bool

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let toast = toasts.current {
                card(toast)
                    .padding(.horizontal, 14)
                    .padding(.bottom, bottomInset)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(.container, edges: .bottom)
        .allowsHitTesting(toasts.current?.action != nil)
    }

    /// Sit just above the tab bar, or above the island when playing, with a small
    /// gap. Uses the same `BottomBar` geometry the bar/island are laid out from.
    private var bottomInset: CGFloat {
        let base = hasTrack ? BottomBar.islandTopFromEdge : BottomBar.edgeMargin + BottomBar.tabHeight
        return base + 10
    }

    private func card(_ toast: Toast) -> some View {
        HStack(spacing: 11) {
            if let icon = toast.icon {
                Image(mozz: icon)
                    .resizable().scaledToFit()
                    .frame(width: 17, height: 17)
                    .foregroundStyle(.secondary)
            }
            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action = toast.action {
                Button {
                    toasts.performAction(toast)
                } label: {
                    Text(action.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(action.title): \(toast.message)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.06)))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .contain)
    }
}
