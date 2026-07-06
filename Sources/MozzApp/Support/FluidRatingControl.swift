import SwiftUI
import MozzCore

// MARK: - Tunables
//
// Everything about the fluid rating control's feel lives here so it's cheap to
// iterate on-device. Sizes are points; durations are seconds.
private enum RatingTuning {
    static let starCount = 5
    /// Size of a star glyph in the expanded strip (popover + hold-drag reveal).
    static let stripStarSize: CGFloat = 30
    /// Gap between stars in the expanded strip.
    static let stripStarSpacing: CGFloat = 10
    /// Movement (points) past which a press is treated as a drag-to-rate instead
    /// of a tap.
    static let moveSlop: CGFloat = 10
    /// How long the finger must rest on the player star before the strip reveals
    /// and drag-to-rate begins. Short so it feels immediate but still lets a
    /// quick tap open the sticky popover instead.
    static let longPressDuration: Double = 0.18
    /// Vertical offset of the revealed strip above the player star so the finger
    /// doesn't cover it.
    static let revealYOffset: CGFloat = -68
    static let tint: Color = .yellow
    static let inactiveTint: Color = .secondary
}

// MARK: - Rating math
//
// Pure geometry → rating mapping shared by tap and drag so both feel identical.
enum RatingMath {
    /// Total width the star strip occupies (stars are laid out in fixed-width
    /// cells so the visual layout exactly matches the hit math below).
    static func stripWidth(starSize: CGFloat = RatingTuning.stripStarSize,
                           spacing: CGFloat = RatingTuning.stripStarSpacing) -> CGFloat {
        CGFloat(RatingTuning.starCount) * starSize
            + CGFloat(RatingTuning.starCount - 1) * spacing
    }

    /// Map a horizontal position measured from the FIRST star's leading edge to a
    /// snapped rating. The left half of star `i` yields `i - 0.5`, the right half
    /// `i`; a position left of the first star (x < 0, e.g. dragging past the strip)
    /// yields `nil` (clear). Result is clamped to `0.5...5.0`.
    static func rating(atX x: CGFloat,
                       starSize: CGFloat = RatingTuning.stripStarSize,
                       spacing: CGFloat = RatingTuning.stripStarSpacing) -> Double? {
        if x < 0 { return nil }
        let pitch = starSize + spacing
        let index = Int(x / pitch)
        if index >= RatingTuning.starCount { return 5.0 }
        let within = x - CGFloat(index) * pitch
        let value = within < starSize / 2 ? Double(index) + 0.5 : Double(index) + 1.0
        return min(value, 5.0)
    }
}

// MARK: - Selection haptics
//
// Fires a light "tick" whenever the previewed rating crosses a half-step, so the
// drag feels detented and premium. No-op off iOS.
final class RatingHaptic {
#if canImport(UIKit)
    private let generator = UISelectionFeedbackGenerator()
    func prepare() { generator.prepare() }
    func tick() {
        generator.selectionChanged()
        generator.prepare()
    }
#else
    func prepare() {}
    func tick() {}
#endif
}

// MARK: - Star strip
//
// Renders the 5-star strip from a preview value in fixed-width cells (so the
// visual centres line up exactly with the drag/tap math). When interactive
// (`onCommit` supplied) a single drag gesture handles BOTH a tap and a slide:
// `onPreview` fires live as the finger tracks across (half-star snapping +
// selection haptics), and `onCommit` fires the final value on release. Dragging
// left off the first star yields nil (clear). Used by the popover (interactive)
// and the player's hold-drag reveal (display only).
struct RatingStripView: View {
    let value: Double?
    var starSize: CGFloat = RatingTuning.stripStarSize
    var spacing: CGFloat = RatingTuning.stripStarSpacing
    var onPreview: ((Double?) -> Void)? = nil
    var onCommit: ((Double?) -> Void)? = nil

    @State private var tracking = false
    @State private var lastReported: Double?
    private let haptic = RatingHaptic()

    private var isInteractive: Bool { onCommit != nil }

    var body: some View {
        let strip = HStack(spacing: spacing) {
            ForEach(0..<RatingTuning.starCount, id: \.self) { i in
                Image(systemName: symbol(for: i))
                    .font(.system(size: starSize * 0.9))
                    .foregroundStyle(RatingTuning.tint)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: starSize, height: starSize)
            }
        }
        .contentShape(Rectangle())

        if isInteractive {
            strip.gesture(dragGesture).animation(.snappy(duration: 0.12), value: value)
        } else {
            strip.animation(.snappy(duration: 0.12), value: value)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { event in
                if !tracking { haptic.prepare(); tracking = true; lastReported = value }
                let v = RatingMath.rating(atX: event.location.x, starSize: starSize, spacing: spacing)
                if v != lastReported {
                    haptic.tick()
                    lastReported = v
                }
                onPreview?(v)
            }
            .onEnded { event in
                let v = RatingMath.rating(atX: event.location.x, starSize: starSize, spacing: spacing)
                onCommit?(v)
                tracking = false
            }
    }

    private func symbol(for index: Int) -> String {
        let v = value ?? 0
        let starValue = Double(index + 1)
        if v >= starValue { return "star.fill" }
        if v >= starValue - 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }
}

// MARK: - Sticky popover content
//
// The tap/slide variant used by the player's quick-tap and the row "…" menu's
// "Rate…". Tap a star OR slide across to set the rating (live), written through
// the supplied closure — but it does NOT dismiss; the user confirms by tapping
// outside. Sliding left off the first star clears; a "Clear" link is also shown
// when a rating exists.
struct RatingPopoverContent: View {
    let initialRating: Double?
    let onSet: (Double?) -> Void

    @State private var current: Double?

    init(rating: Double?, onSet: @escaping (Double?) -> Void) {
        self.initialRating = rating
        self.onSet = onSet
        _current = State(initialValue: rating)
    }

    var body: some View {
        VStack(spacing: 12) {
            RatingStripView(
                value: current,
                onPreview: { current = $0 },
                onCommit: { current = $0; onSet($0) }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rating")
            .accessibilityValue(current.map { "\(LikeControl.format($0)) stars" } ?? "No rating")
            .accessibilityAdjustableAction { direction in
                adjust(direction)
            }

            Button {
                current = nil
                onSet(nil)
            } label: {
                Text("Clear")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity((current ?? 0) > 0 ? 1 : 0)
            .allowsHitTesting((current ?? 0) > 0)
            .animation(.easeInOut(duration: 0.15), value: (current ?? 0) > 0)
        }
        .padding(16)
        .presentationCompactAdaptation(.popover)
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        let step = 0.5
        let base = current ?? 0
        let next = direction == .increment ? min(base + step, 5) : max(base - step, 0)
        current = next == 0 ? nil : next
        onSet(current)
    }
}

// MARK: - Player fluid rating control
//
// Compact display for the now-playing player (ratings/Plex path only): a single
// star + numeric rating, shown ONLY when rated; a blank star otherwise.
//   • Quick tap  → sticky popover (tap to set, tap-outside dismisses).
//   • Press-hold → reveals the strip; drag to live-preview (half-star snapping +
//     selection haptics); release commits AND closes.
// Under Reduce Motion the hold-drag reveal is disabled and a tap simply opens the
// popover (a static tap picker).
struct FluidRatingControl: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let track: Track

    @State private var rating: Double?
    @State private var preview: Double?
    @State private var isDragging = false
    @State private var showingPicker = false
    @State private var stripFrame: CGRect = .zero
    @State private var lastHapticValue: Double?
    @State private var touchDownAt: Date?
    @State private var lastX: CGFloat = 0
    @State private var revealWork: DispatchWorkItem?

    private let haptic = RatingHaptic()
    private let space = "fluidRating"

    init(track: Track) {
        self.track = track
        _rating = State(initialValue: track.rating)
    }

    var body: some View {
        surface
            .popover(isPresented: $showingPicker) {
                RatingPopoverContent(rating: rating) { newValue in
                    rating = newValue
                    let snapshot = track
                    Task { await env.setRating(newValue, track: snapshot) }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rating")
            .accessibilityValue(rating.map { "\(LikeControl.format($0)) stars" } ?? "No rating")
            .accessibilityAdjustableAction { direction in accessibilityAdjust(direction) }
            .onChange(of: track.id) { _, _ in rating = track.rating }
            .onChange(of: track.rating) { _, new in rating = new }
    }

    // Reduce Motion: a plain tap opens the sticky picker (no hold-drag reveal).
    // Otherwise a single drag gesture handles both a quick tap (→ popover) and a
    // press-hold-drag (→ live preview + commit); it fully resolves on touch-up
    // BEFORE the popover is presented, so the popover reliably captures touches.
    @ViewBuilder private var surface: some View {
        if reduceMotion {
            collapsedStar
                .contentShape(Rectangle())
                .onTapGesture { showingPicker = true }
        } else {
            collapsedStar
                .overlay(alignment: .center) {
                    if isDragging { revealStrip.offset(y: RatingTuning.revealYOffset) }
                }
                .coordinateSpace(name: space)
                .contentShape(Rectangle())
                .gesture(rateGesture)
        }
    }

    // MARK: Collapsed display (single star + number when rated)

    private var collapsedStar: some View {
        let rated = (rating ?? 0) > 0
        return HStack(spacing: 4) {
            Image(systemName: rated ? "star.fill" : "star")
            if let r = rating, r > 0 {
                Text(LikeControl.format(r)).monospacedDigit()
            }
        }
        .foregroundStyle(rated ? RatingTuning.tint : RatingTuning.inactiveTint)
    }

    // MARK: Hold-drag reveal

    private var revealStrip: some View {
        VStack(spacing: 6) {
            RatingStripView(value: preview)
                .background {
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { stripFrame = geo.frame(in: .named(space)) }
                            .onChange(of: geo.frame(in: .named(space))) { _, new in stripFrame = new }
                    }
                }
            Text((preview ?? 0) > 0 ? LikeControl.format(preview!) + " stars" : "No rating")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 8, y: 2)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
        .allowsHitTesting(false)
    }

    private var rateGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { value in
                lastX = value.location.x
                if touchDownAt == nil {
                    touchDownAt = Date()
                    haptic.prepare()
                    scheduleReveal()
                }
                let moved = hypot(value.translation.width, value.translation.height) > RatingTuning.moveSlop
                if moved && !isDragging { engage() }
                if isDragging { updatePreview(forX: value.location.x) }
            }
            .onEnded { value in
                revealWork?.cancel(); revealWork = nil
                let elapsed = touchDownAt.map { Date().timeIntervalSince($0) } ?? 0
                let moved = hypot(value.translation.width, value.translation.height) > RatingTuning.moveSlop
                if isDragging {
                    updatePreview(forX: value.location.x)
                    commit(preview)
                    endDragging()
                } else if !moved && elapsed < RatingTuning.longPressDuration + 0.25 {
                    showingPicker = true
                }
                touchDownAt = nil
            }
    }

    /// After the hold threshold, reveal the strip even if the finger is stationary
    /// (a plain DragGesture emits no updates for a still finger).
    private func scheduleReveal() {
        let work = DispatchWorkItem {
            guard touchDownAt != nil, !isDragging else { return }
            engage()
            updatePreview(forX: lastX)
        }
        revealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + RatingTuning.longPressDuration, execute: work)
    }

    private func engage() {
        guard !isDragging else { return }
        preview = rating
        lastHapticValue = rating
        withAnimation(.snappy(duration: 0.18)) { isDragging = true }
    }

    private func updatePreview(forX x: CGFloat) {
        let localX = x - stripFrame.minX
        let newValue = RatingMath.rating(atX: localX)
        if newValue != preview {
            preview = newValue
            if newValue != lastHapticValue {
                haptic.tick()
                lastHapticValue = newValue
            }
        }
    }

    private func endDragging() {
        withAnimation(.snappy(duration: 0.18)) { isDragging = false }
    }

    private func commit(_ newValue: Double?) {
        rating = newValue
        let snapshot = track
        Task { await env.setRating(newValue, track: snapshot) }
    }

    private func accessibilityAdjust(_ direction: AccessibilityAdjustmentDirection) {
        let step = 0.5
        let base = rating ?? 0
        let next = direction == .increment ? min(base + step, 5) : max(base - step, 0)
        commit(next == 0 ? nil : next)
    }
}
