import SwiftUI

/// Shared sizing for the Now Playing controls so every button is visually
/// consistent and meets Apple's 44×44pt minimum hit target (HIG). Keeping the
/// numbers in one place means the utility icons (rating, overflow, AirPlay,
/// lyrics, queue) stay the same size, while the transport glyphs form a clear
/// hierarchy: skip < play/pause.
enum PlayerControlMetrics {
    /// One consistent glyph size for the "utility" controls — the rating star /
    /// like heart, the overflow menu, the AirPlay route, lyrics, and the queue
    /// toggle. Sized so they read clearly without competing with transport.
    static let utilityGlyph: CGFloat = 26
    /// The output-route (AirPlay / device) glyph is a real SF Symbol, not one of the
    /// thin-stroke Tabler template icons its neighbours use — at the same nominal
    /// point size its heavier, wider body reads noticeably larger. Size it a touch
    /// smaller so it sits visually level with the lyrics/queue icons beside it.
    static let routeGlyph: CGFloat = 22
    /// Skip-back / skip-forward: larger than the utility icons.
    static let skipGlyph: CGFloat = 40
    /// Play / pause: the largest control on the player.
    static let playGlyph: CGFloat = 60

    /// Apple's minimum recommended hit target. Every control is padded to at
    /// least this square so it's comfortable to tap.
    static let minHit: CGFloat = 44
    /// Roomier hit target for the skip buttons (they sit between big neighbours).
    static let skipHit: CGFloat = 56
    /// Play/pause hit target — the biggest, matching its prominence.
    static let playHit: CGFloat = 72
}

extension View {
    /// Centre the view in a square that's at least `size` on a side and make the
    /// whole square tappable — the visible glyph keeps its own size while the
    /// touch target grows to meet the accessibility minimum.
    func playerHitTarget(_ size: CGFloat = PlayerControlMetrics.minHit) -> some View {
        frame(minWidth: size, minHeight: size)
            .contentShape(Rectangle())
    }
}

/// A reusable icon button for the Now Playing player. Renders `glyph` at
/// `glyphSize`, centred in a `hitSize` square so it always meets the touch-target
/// minimum, with a consistent tint, disabled dimming, and an accessibility label.
struct PlayerIconButton: View {
    let glyph: AppIcon
    var glyphSize: CGFloat = PlayerControlMetrics.utilityGlyph
    var hitSize: CGFloat = PlayerControlMetrics.minHit
    var tint: Color = .primary
    var isEnabled: Bool = true
    var haptics: Bool = true
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            glyph.styled(size: glyphSize)
                .playerHitTarget(hitSize)
        }
        .buttonStyle(PlayerButtonStyle(haptic: haptics))
        .foregroundStyle(tint)
        .opacity(isEnabled ? 1 : 0.35)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}

/// A tactile press style shared by every player button: a firm scale-down and
/// fade while the finger is held, plus a haptic tap on press-down, springing
/// back on release. Deliberately crisp — enough to feel responsive, never bouncy.
/// `haptic` can be turned off per-button (e.g. the queue toggle, whose big morph
/// animation is feedback enough) without losing the press animation.
struct PlayerButtonStyle: ButtonStyle {
    var haptic: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.8 : 1)
            .opacity(configuration.isPressed ? 0.45 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.62),
                       value: configuration.isPressed)
            // Fire only on press-down (nil on release), so the tap lands the
            // instant the finger makes contact.
            .sensoryFeedback(trigger: configuration.isPressed) { _, pressed in
                (haptic && pressed) ? .impact(weight: .medium, intensity: 0.9) : nil
            }
    }
}

/// The primary play / pause button. The two glyphs cross-fade and scale into one
/// another on every toggle (a clean morph rather than an instant icon swap),
/// while `PlayerButtonStyle` adds the press-down feedback. Custom template glyphs
/// can't use `.symbolEffect(.replace)`, so the morph is built from a stacked pair.
struct PlayPauseButton: View {
    let playing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                AppIcon.play.styled(size: PlayerControlMetrics.playGlyph)
                    .opacity(playing ? 0 : 1)
                    .scaleEffect(playing ? 0.7 : 1)
                AppIcon.pause.styled(size: PlayerControlMetrics.playGlyph)
                    .opacity(playing ? 1 : 0)
                    .scaleEffect(playing ? 1 : 0.7)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.72), value: playing)
            .playerHitTarget(PlayerControlMetrics.playHit)
        }
        .buttonStyle(PlayerButtonStyle())
        .foregroundStyle(.primary)
        .accessibilityLabel(playing ? "Pause" : "Play")
    }
}
