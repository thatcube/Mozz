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
/// arrow, and the end bar it runs into.
///
/// That split is the whole point. The bar is a stop — the end of the track — so
/// it must never travel; sliding it away with the arrow is what made an earlier
/// version feel like an animation playing *over* the icon instead of the icon
/// itself moving. Here the arrow drives forward and is swallowed by the bar,
/// which takes the hit and rings; a fresh arrow then rides in behind it. Nothing
/// moves that shouldn't, and the motion is the glyph's own geometry.
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

    /// 0 = at rest, 1 = fully handed over. Both ends draw the glyph whole, so
    /// snapping back to 0 after a run is invisible.
    @State private var handover: Double = 0
    /// Guards the completion of a run a newer skip has already replaced.
    @State private var run = 0

    // The artwork's own 24pt grid (see `player-skip-arrow.svg`): the arrow
    // occupies x 3–16.5, the end bar x 19–21.
    //
    // The arrow layer is twice the glyph wide so a departing or arriving arrow
    // has somewhere to be, which puts the glyph's 24-unit grid centred in a
    // 48-unit lane starting at 12. Every mask stop below is derived from those
    // real coordinates rather than eyeballed as a fraction — getting that wrong
    // is precisely what clipped the triangle's back edge and tip once already.
    private static let laneUnits: CGFloat = 48
    private static let glyphOrigin: CGFloat = 12
    /// A position on the glyph's own grid, as a fraction of the arrow lane.
    private static func lane(_ glyphX: CGFloat) -> Double {
        Double((glyphOrigin + glyphX) / laneUnits)
    }

    private var unit: CGFloat { size / 24 }
    /// The arrow's flat back edge, at rest.
    private static let arrowBack: CGFloat = 3
    /// Where the arrow is cut off — the gap between arrow tip and bar.
    private static let barEdge: CGFloat = 18
    /// Exactly far enough that the arrow's trailing edge reaches the bar, so it
    /// ends the run perfectly consumed rather than merely faded out.
    private static let exit: CGFloat = barEdge - arrowBack
    /// How far back the replacement arrow starts. Shorter than the exit — it has
    /// less ground to cover because nothing is eating it on the way in.
    private static let entry: CGFloat = 11

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            // An overlay so the arrow can ride outside the control's bounds
            // without widening it and pushing the transport row apart.
            .overlay { glyph }
            .onChange(of: generation) { _, _ in
                guard travel.matches(direction) else { return }
                skip()
            }
    }

    private var glyph: some View {
        ZStack {
            // The frame has to be pinned BEFORE the mask: a bare ZStack sizes to
            // its children (one glyph wide), which would squeeze the whole lane's
            // worth of mask stops into half the space.
            arrows
                .frame(width: size * 2, height: size)
                .mask { arrowMask }
            endBar
        }
        .frame(width: size * 2, height: size)
        // Drawn facing forward; the back button is the same thing mirrored.
        .scaleEffect(x: travel.sign, y: 1)
    }

    /// The outgoing arrow and its replacement. The outgoing one isn't faded — it
    /// is *eaten* by the mask as it reaches the bar, which is what makes it read
    /// as going behind a solid object rather than dissolving in mid-air.
    private var arrows: some View {
        ZStack {
            AppIcon.skipArrow.styled(size: size)
                .offset(x: Self.exit * unit * handover)
            AppIcon.skipArrow.styled(size: size)
                .offset(x: -Self.entry * unit * (1 - handover))
                .opacity(min(1, max(0, handover * 1.9 - 0.25)))
        }
    }

    /// The end bar. It holds its ground — all it does is take the impact and
    /// ring, like a stop that's just been struck.
    private var endBar: some View {
        let hit = impact
        return AppIcon.skipBar.styled(size: size)
            .offset(x: 1.4 * unit * hit)
            .scaleEffect(x: 1 - 0.1 * hit, y: 1 + 0.09 * hit)
    }

    /// How hard the bar is being struck right now. Peaks early — the arrow meets
    /// it almost immediately — then settles.
    private var impact: Double {
        guard handover > 0, handover < 0.6 else { return 0 }
        return sin(.pi * (handover / 0.6))
    }

    /// Cut dead at the bar so the arrow vanishes *into* it, and softened on the
    /// approach so a replacement emerges rather than popping into being. The
    /// soft edge finishes exactly at the arrow's resting back edge, so a glyph
    /// sitting still is never touched by it.
    private var arrowMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: Self.lane(-7)),
                .init(color: .black, location: Self.lane(Self.arrowBack)),
                .init(color: .black, location: Self.lane(Self.barEdge)),
                .init(color: .clear, location: Self.lane(Self.barEdge)),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    private func skip() {
        run &+= 1
        let token = run
        // Restart from rest so a rapid double-skip throws a second arrow rather
        // than continuing the first one's run.
        handover = 0
        withAnimation(.spring(response: 0.36, dampingFraction: 0.7),
                      completionCriteria: .logicallyComplete) {
            handover = 1
        } completion: {
            // Invisible: at 1 the outgoing arrow is fully consumed and its
            // replacement is home, which is exactly what 0 draws.
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
