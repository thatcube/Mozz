import SwiftUI
import MozzPlayback

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
///
/// `isActive` marks a toggle whose surface is currently showing (lyrics, queue),
/// drawing a quiet wash behind the glyph.
struct PlayerIconButton: View {
    let glyph: AppIcon
    var glyphSize: CGFloat = PlayerControlMetrics.utilityGlyph
    var hitSize: CGFloat = PlayerControlMetrics.minHit
    var tint: Color = .primary
    var isEnabled: Bool = true
    var haptics: Bool = true
    /// Whether this control's surface is open. Draws the selected backdrop so the
    /// state is legible at a glance rather than only from a tint shift.
    var isActive: Bool = false
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            glyph.styled(size: glyphSize)
                .playerHitTarget(hitSize)
                .background { activeBackdrop }
        }
        .buttonStyle(PlayerButtonStyle(haptic: haptics, washDiameter: glyphSize + 20))
        .foregroundStyle(tint)
        .opacity(isEnabled ? 1 : 0.35)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    /// The selected-state wash: the same fixed light fill + hairline the audio
    /// format badge uses, as a circle around the glyph.
    ///
    /// A fixed `.primary` wash rather than a material, for the same reason as that
    /// badge — the player's backdrop is sampled from the artwork, and a material
    /// blurs it into something muddy on dark covers.
    private var activeBackdrop: some View {
        Circle()
            .fill(.primary.opacity(0.16))
            .overlay { Circle().stroke(.primary.opacity(0.12), lineWidth: 0.5) }
            .frame(width: backdropSize, height: backdropSize)
            // Grown into place rather than simply faded, so the toggle feels like
            // it is switching on.
            .scaleEffect(isActive ? 1 : 0.72)
            .opacity(isActive ? 1 : 0)
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isActive)
    }

    /// Sized off the glyph so it stays concentric at any icon size, with enough
    /// margin that the wash reads as a surface the icon sits on rather than a
    /// tight outline around it.
    ///
    /// Not clamped to the hit target: this is a `background`, so it takes no part
    /// in layout and is free to be a little larger than the 44pt square the touch
    /// area needs.
    private var backdropSize: CGFloat { glyphSize + 23 }
}

/// A tactile press style shared by every player button: a firm scale-down, a
/// soft wash behind the glyph, and a haptic tap on press-down, springing back
/// on release.
///
/// The press deliberately does **not** follow `isPressed` directly. A real tap
/// lasts 60–100ms, which is shorter than the spring takes to travel — so a
/// button driven straight off `isPressed` gets yanked back before it has
/// visibly moved, and only looks animated if you hold it down. Here the down
/// state is latched for a minimum beat, so the quickest tap still plays the
/// whole compress → release.
///
/// `haptic` can be turned off per-button (e.g. the queue toggle, whose big morph
/// animation is feedback enough) without losing the press animation.
struct PlayerButtonStyle: ButtonStyle {
    var haptic: Bool = true
    /// Diameter of the wash drawn behind the glyph while the finger is down.
    /// `nil` lets it fill the button's own hit target.
    var washDiameter: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, haptic: haptic, washDiameter: washDiameter)
    }

    /// A real `View` rather than a modifier chain, so it can own the latch state.
    private struct PressBody: View {
        let configuration: ButtonStyleConfiguration
        let haptic: Bool
        let washDiameter: CGFloat?

        /// What the animation follows — deliberately not `isPressed` (see above).
        @State private var down = false
        @State private var pressedAt = Date.now
        @State private var pendingLift: DispatchWorkItem?

        /// How long the pressed state stays on screen even once the finger has
        /// lifted. Short enough to never feel laggy, long enough to be seen.
        private static let minimumHold: TimeInterval = 0.13

        var body: some View {
            configuration.label
                .scaleEffect(down ? 0.82 : 1)
                .opacity(down ? 0.6 : 1)
                .background { wash }
                // Asymmetric on purpose: the press is immediate and firm, the
                // return is a looser spring that overshoots slightly, so letting
                // go reads as a pop rather than a slow deflate.
                .animation(down ? .spring(response: 0.15, dampingFraction: 0.9)
                                : .spring(response: 0.4, dampingFraction: 0.5),
                           value: down)
                .onChange(of: configuration.isPressed) { _, pressed in
                    if pressed { press() } else { lift() }
                }
                // Fire only on press-down (nil on release), so the tap lands the
                // instant the finger makes contact.
                .sensoryFeedback(trigger: configuration.isPressed) { _, pressed in
                    (haptic && pressed) ? .impact(weight: .medium, intensity: 0.9) : nil
                }
        }

        /// A quiet circular wash — the same vocabulary as the toggle's selected
        /// backdrop, so a press reads as the control lighting up rather than as
        /// a new kind of decoration.
        private var wash: some View {
            Circle()
                .fill(.primary.opacity(0.13))
                .frame(width: washDiameter, height: washDiameter)
                .scaleEffect(down ? 1 : 0.6)
                .opacity(down ? 1 : 0)
                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: down)
                .allowsHitTesting(false)
        }

        private func press() {
            pendingLift?.cancel()
            pendingLift = nil
            pressedAt = .now
            down = true
        }

        /// Let go — but not before the press has been on screen long enough to see.
        private func lift() {
            let remaining = Self.minimumHold - Date.now.timeIntervalSince(pressedAt)
            guard remaining > 0 else { down = false; return }
            let work = DispatchWorkItem { down = false }
            pendingLift = work
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
        }
    }
}

/// Which way a transport control sends the queue. Its glyph always travels the
/// way it points.
enum TransportTravel {
    case forward, backward

    /// Screen direction of travel: forward throws right, backward throws left.
    var sign: CGFloat { self == .forward ? 1 : -1 }

    var glyph: AppIcon { self == .forward ? .skipForward : .skipBack }

    /// Whether a transport move the engine reported belongs to this control.
    /// Tapping Next must never twitch the Previous button.
    func matches(_ direction: TransportDirection) -> Bool {
        switch (self, direction) {
        case (.forward, .forward), (.backward, .backward): return true
        default: return false
        }
    }
}

/// A skip glyph that hands itself over when the queue actually moves: the arrow
/// throws off the way it points, fading as it goes, while a fresh one rides in
/// behind it. The motion carries the direction, so a skip is legible from the
/// corner of your eye without reading the icon.
///
/// Driven by the engine's transport counter rather than by this button's own
/// tap, so a skip from the Lock Screen, CarPlay, a headphone remote, or a track
/// simply ending animates exactly like a press here.
struct TransportGlyph: View {
    let size: CGFloat
    let travel: TransportTravel
    /// The direction and counter of the engine's most recent transport move.
    let direction: TransportDirection
    let generation: Int

    /// 0 = at rest, 1 = fully handed over. Both ends draw one glyph centred, so
    /// snapping back to 0 after a run is invisible.
    @State private var handover: Double = 0
    /// Guards the completion of a run that a newer skip has already replaced.
    @State private var run = 0

    /// How far the arrow throws — a little under its own width, so the outgoing
    /// and incoming glyphs overlap for a beat instead of the control blinking empty.
    private var distance: CGFloat { size * 0.8 }

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            // An overlay so the glyphs can ride outside the control's bounds
            // without widening it and pushing the transport row apart.
            .overlay { conveyor }
            .onChange(of: generation) { _, _ in
                guard travel.matches(direction) else { return }
                throwGlyph()
            }
    }

    private var conveyor: some View {
        ZStack {
            copy(phase: handover)       // the arrow that was here: leaves
            copy(phase: handover - 1)   // its replacement: arrives
        }
        .frame(width: size * 2, height: size)
        // Soften the edges so the glyphs slide out of view rather than being
        // cut off at a hard boundary.
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.22),
                    .init(color: .black, location: 0.78),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
        }
    }

    /// One arrow at a point in its journey. `phase` is 0 dead centre, ±1 a full
    /// throw away — the outgoing and incoming copies are the same view a throw
    /// apart, which is what makes the hand-off read as one object replacing another.
    private func copy(phase: Double) -> some View {
        let travelled = min(1, abs(phase))
        return travel.glyph.styled(size: size)
            .offset(x: distance * travel.sign * phase)
            // Gone well before the full throw, so the two never look like a pair.
            .opacity(1 - min(1, travelled / 0.62))
            .scaleEffect(1 - 0.16 * travelled)
    }

    private func throwGlyph() {
        run &+= 1
        let token = run
        // Restart from rest so a rapid double-skip throws a second arrow rather
        // than continuing the first one's arc.
        handover = 0
        withAnimation(.spring(response: 0.38, dampingFraction: 0.72),
                      completionCriteria: .logicallyComplete) {
            handover = 1
        } completion: {
            // Invisible: phase 1 and phase 0 both draw a single centred glyph.
            guard run == token else { return }
            handover = 0
        }
    }
}

/// A transport skip button: the tactile press every player control shares, plus
/// a glyph that hands itself over in the direction the queue actually moved.
struct TransportSkipButton: View {
    let travel: TransportTravel
    let direction: TransportDirection
    let generation: Int
    var isEnabled: Bool = true
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TransportGlyph(size: PlayerControlMetrics.skipGlyph,
                           travel: travel,
                           direction: direction,
                           generation: generation)
                .playerHitTarget(PlayerControlMetrics.skipHit)
        }
        .buttonStyle(PlayerButtonStyle(washDiameter: PlayerControlMetrics.skipGlyph + 20))
        .foregroundStyle(.primary)
        .opacity(isEnabled ? 1 : 0.35)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}

/// The primary play / pause button. The two glyphs cross-fade, scale and tilt
/// into one another on every toggle (a clean morph rather than an instant icon
/// swap), while `PlayerButtonStyle` adds the press-down feedback. Custom
/// template glyphs can't use `.symbolEffect(.replace)`, so the morph is built
/// from a stacked pair.
struct PlayPauseButton: View {
    let playing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                AppIcon.play.styled(size: PlayerControlMetrics.playGlyph)
                    .opacity(playing ? 0 : 1)
                    .scaleEffect(playing ? 0.6 : 1)
                    .rotationEffect(.degrees(playing ? -12 : 0))
                AppIcon.pause.styled(size: PlayerControlMetrics.playGlyph)
                    .opacity(playing ? 1 : 0)
                    .scaleEffect(playing ? 1 : 0.6)
                    .rotationEffect(.degrees(playing ? 0 : 12))
            }
            // Enough bounce to feel alive; the incoming glyph settles just past
            // its mark and back, which is what sells it as a physical switch.
            .animation(.spring(response: 0.34, dampingFraction: 0.62), value: playing)
            .playerHitTarget(PlayerControlMetrics.playHit)
        }
        .buttonStyle(PlayerButtonStyle(washDiameter: PlayerControlMetrics.playGlyph + 22))
        .foregroundStyle(.primary)
        .accessibilityLabel(playing ? "Pause" : "Play")
    }
}
