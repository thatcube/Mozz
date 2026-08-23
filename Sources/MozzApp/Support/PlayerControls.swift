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

/// Which way a transport control sends the queue. Its arrow always travels the
/// way it points.
enum TransportTravel {
    case forward, backward

    /// Screen direction of travel. The whole control is drawn facing forward and
    /// mirrored for the back button — the two glyphs are exact mirrors of each
    /// other, so one set of artwork and one set of motion covers both.
    var sign: CGFloat { self == .forward ? 1 : -1 }

    /// Whether a transport move the engine reported belongs to this control.
    /// Tapping Next must never twitch the Previous button.
    func matches(_ direction: TransportDirection) -> Bool {
        switch (self, direction) {
        case (.forward, .forward), (.backward, .backward): return true
        default: return false
        }
    }
}

/// The skip control, drawn as its two real parts rather than as one picture: an
/// arrow, and the end bar marking the end of the track.
///
/// The arrow slides forward and disappears *under* the bar — hard-clipped at the
/// bar's leading face, so it is progressively swallowed the way a card slides
/// under a door — fading out as it goes, and completely gone while it is still a
/// clear wedge. The bar flexes as it passes beneath. The replacement then sweeps
/// in from off the left, and the two arrows can never overlap: the outgoing one
/// has always travelled further than an arrow's width by the time the incoming
/// one is visible, so there is no cross-fade and no double image.
///
/// The details that matter are all about the last moments of the departing
/// arrow. The clip sits *flush* with the bar's face: cut a unit short of it, the
/// tall sliver of the arrow's flat back edge is stranded in the gap and reads as
/// a second line. And the fade is timed against the arrow's own width rather
/// than the clock, because a clip left to run pares it down to a two-unit,
/// full-height remnant sitting on the bar — which reads as the bar thickening
/// rather than as an arrow going under it.
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

    /// 0 = at rest, 1 = fully handed over. Both ends draw the arrow home and
    /// opaque, so snapping back to 0 after a run is invisible.
    @State private var handover: Double = 0
    /// Guards the completion of a run a newer skip has already replaced.
    @State private var run = 0

    // Distances are in the artwork's own 24pt grid (see `player-skip-arrow.svg`,
    // where the arrow occupies x 3–16.5 and the bar x 19–21), so the motion is
    // expressed in the glyph's geometry rather than in arbitrary points.
    private var unit: CGFloat { size / 24 }
    /// The bar's leading face — where the arrow is cut off, exactly flush.
    private static let barFace: CGFloat = 19
    private static let arrowBack: CGFloat = 3
    /// Far enough that the arrow's back edge finishes level with the bar's face,
    /// so it ends the run completely hidden beneath it.
    private static let exit: CGFloat = barFace - arrowBack
    /// Far enough back that the replacement starts entirely outside the glyph,
    /// so the slot hides it until it begins to sweep in. Comfortably more than
    /// an arrow's width, which is what guarantees the two never overlap.
    private static let entry: CGFloat = 17

    /// The exit is quick and finishes early — the arrow is gone under the bar
    /// long before the replacement is home — which is what stops the pair
    /// reading as a cross-fade.
    private static let exitEnds: Double = 0.5
    /// The entry starts while the exit is still finishing. They can safely run
    /// together because they are always more than an arrow's width apart.
    private static let entryBegins: Double = 0.3

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            // An overlay so the incoming arrow can start outside the glyph box
            // without widening it and pushing the transport row apart.
            .overlay { glyph }
            .onChange(of: generation) { _, _ in
                guard travel.matches(direction) else { return }
                skip()
            }
    }

    private var glyph: some View {
        ZStack {
            // Framed before masking: a bare stack sizes to its children, which
            // would scale every stop below into the wrong place.
            arrows
                .frame(width: size, height: size)
                .mask { slot }
            // Outside the mask, so the stop itself is never clipped.
            endBar
        }
        // Drawn facing forward; the back button is the same thing mirrored.
        .scaleEffect(x: travel.sign, y: 1)
    }

    /// The departing arrow and its replacement.
    ///
    /// The departing one fades as it goes under, and the fade is timed against
    /// its own geometry rather than the clock: it is fully gone by the time the
    /// slot has narrowed it to about five units, while it is still a clear
    /// wedge. Left to run, the clip pares it down to a two-unit, full-height
    /// remnant sitting flush on the bar — which stops reading as an arrow going
    /// under and starts reading as the bar thickening.
    ///
    /// The replacement never fades. It is revealed by the slot as it sweeps in,
    /// so an arriving arrow is always solid.
    private var arrows: some View {
        ZStack {
            AppIcon.skipArrow.styled(size: size)
                .offset(x: Self.exit * unit * exitProgress)
                .opacity(1 - ramp(exitProgress, from: Self.fadeFrom, to: Self.fadeTo))
            AppIcon.skipArrow.styled(size: size)
                .offset(x: -Self.entry * unit
                    * (1 - ramp(handover, from: Self.entryBegins, to: 1)))
        }
    }

    /// How far along its run the departing arrow is, 0→1.
    private var exitProgress: Double { ramp(handover, from: 0, to: Self.exitEnds) }

    /// The fade window, in fractions of the exit travel. Ends at 0.68 because
    /// that is where the slot has cut the arrow down to roughly five units —
    /// the point past which the remnant reads as part of the bar.
    private static let fadeFrom: Double = 0.25
    private static let fadeTo: Double = 0.68

    /// The slot the arrows run through: open across the glyph, and cut dead at
    /// the bar's leading face so an arrow reaching it slides underneath rather
    /// than across it.
    ///
    /// Flush with the bar, deliberately. An earlier version cut a unit short of
    /// it, and the tall sliver of the arrow's flat back edge stranded in that
    /// gap is what read as a second line; touching the bar, the same sliver
    /// reads as the bar. The near edge is softened so an arrival emerges rather
    /// than appearing at a hard line, and finishes at the arrow's resting back
    /// edge so a glyph standing still is never touched by it.
    private var slot: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: Double(Self.arrowBack / 24)),
                .init(color: .black, location: Double(Self.barFace / 24)),
                .init(color: .clear, location: Double(Self.barFace / 24)),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    /// The stop reacting as the arrow disappears beneath it: shoved a little,
    /// squashed against the impact and springing taller, then settling. It holds
    /// its position the rest of the time — a stop that wanders isn't a stop.
    private var endBar: some View {
        let hit = impact
        return AppIcon.skipBar.styled(size: size)
            .scaleEffect(x: 1 - 0.18 * hit, y: 1 + 0.14 * hit, anchor: .center)
            .offset(x: 1.1 * unit * hit)
    }

    /// How hard the bar is being struck. Rises as the arrow reaches it, peaks
    /// while it is being swallowed, then rings out.
    private var impact: Double {
        let window = ramp(handover, from: 0.05, to: 0.55)
        guard window > 0, window < 1 else { return 0 }
        return pow(sin(.pi * window), 1.5)
    }

    /// A 0→1 ramp across a window of the hand-over, clamped at both ends.
    private func ramp(_ value: Double, from start: Double, to end: Double) -> Double {
        min(1, max(0, (value - start) / (end - start)))
    }

    private func skip() {
        run &+= 1
        let token = run
        // Restart from rest so a rapid double-skip sends a second arrow rather
        // than continuing the first one's run.
        handover = 0
        withAnimation(.spring(response: 0.34, dampingFraction: 0.8),
                      completionCriteria: .logicallyComplete) {
            handover = 1
        } completion: {
            // Invisible: at 1 the replacement is home and the outgoing arrow is
            // entirely under the bar, which is exactly what 0 draws.
            guard run == token else { return }
            handover = 0
        }
    }
}

/// A transport skip button: the tactile press every player control shares, plus
/// an arrow that drives into the end bar when the queue actually moves.
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

/// The primary play / pause button. The two glyphs cross-fade and scale into one
/// another on every toggle (a clean morph rather than an instant icon swap),
/// while `PlayerButtonStyle` adds the press-down feedback. Custom template
/// glyphs can't use `.symbolEffect(.replace)`, so the morph is built from a
/// stacked pair.
///
/// Deliberately no rotation: spinning a play triangle says nothing about
/// becoming a pause, and reads as an effect running over the icon rather than
/// the icon changing. Scale and fade are the honest description of a swap.
struct PlayPauseButton: View {
    let playing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                AppIcon.play.styled(size: PlayerControlMetrics.playGlyph)
                    .opacity(playing ? 0 : 1)
                    .scaleEffect(playing ? 0.62 : 1)
                AppIcon.pause.styled(size: PlayerControlMetrics.playGlyph)
                    .opacity(playing ? 1 : 0)
                    .scaleEffect(playing ? 1 : 0.62)
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
