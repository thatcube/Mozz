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
    /// Dead-zone at the strip's leading edge that maps to "no rating" (nil).
    /// Dragging (or tapping) here clears — no 6th icon needed.
    static let zeroZoneWidth: CGFloat = 24
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
    /// Total width the expanded strip occupies for the given layout.
    static func stripWidth(starSize: CGFloat = RatingTuning.stripStarSize,
                           spacing: CGFloat = RatingTuning.stripStarSpacing,
                           zeroZone: CGFloat = RatingTuning.zeroZoneWidth) -> CGFloat {
        zeroZone + CGFloat(RatingTuning.starCount) * starSize
            + CGFloat(RatingTuning.starCount - 1) * spacing
    }

    /// Map a horizontal position (measured from the strip's leading edge, i.e.
    /// the start of the zero-zone) to a snapped rating. The left half of star `i`
    /// yields `i - 0.5`, the right half `i`; anything in the leading zero-zone
    /// (or before it) yields `nil` (clear). Result is clamped to `0.5...5.0`.
    static func rating(atX x: CGFloat,
                       starSize: CGFloat = RatingTuning.stripStarSize,
                       spacing: CGFloat = RatingTuning.stripStarSpacing,
                       zeroZone: CGFloat = RatingTuning.zeroZoneWidth) -> Double? {
        if x < zeroZone { return nil }
        let localX = x - zeroZone
        let pitch = starSize + spacing
        let index = Int(localX / pitch)
        if index >= RatingTuning.starCount { return 5.0 }
        let within = localX - CGFloat(index) * pitch
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
// Renders the 5-star strip (with a leading zero-zone) from a preview value, and,
// when `onTapValue` is supplied, hosts a spatial tap that maps x → rating using
// the same math as the drag. Used by both the popover (tap) and the hold-drag
// reveal (display only).
struct RatingStripView: View {
    let value: Double?
    var starSize: CGFloat = RatingTuning.stripStarSize
    var spacing: CGFloat = RatingTuning.stripStarSpacing
    var zeroZone: CGFloat = RatingTuning.zeroZoneWidth
    var onTapValue: ((Double?) -> Void)? = nil

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<RatingTuning.starCount, id: \.self) { i in
                Image(systemName: symbol(for: i))
                    .font(.system(size: starSize))
                    .foregroundStyle(RatingTuning.tint)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .padding(.leading, zeroZone)
        .contentShape(Rectangle())
        .modifier(TapMapper(zeroZone: zeroZone, starSize: starSize, spacing: spacing, onTapValue: onTapValue))
        .animation(.snappy(duration: 0.12), value: value)
    }

    private func symbol(for index: Int) -> String {
        let v = value ?? 0
        let starValue = Double(index + 1)
        if v >= starValue { return "star.fill" }
        if v >= starValue - 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }
}

/// Adds a location-aware tap to the strip only when a handler is provided.
private struct TapMapper: ViewModifier {
    let zeroZone: CGFloat
    let starSize: CGFloat
    let spacing: CGFloat
    let onTapValue: ((Double?) -> Void)?

    func body(content: Content) -> some View {
        if let onTapValue {
            content.gesture(
                SpatialTapGesture(coordinateSpace: .local).onEnded { event in
                    onTapValue(RatingMath.rating(atX: event.location.x,
                                                 starSize: starSize,
                                                 spacing: spacing,
                                                 zeroZone: zeroZone))
                }
            )
        } else {
            content
        }
    }
}

// MARK: - Sticky popover content
//
// The tap variant used by the player's quick-tap and the row "…" menu's "Rate…".
// Tapping a star sets the rating immediately (written through the supplied
// closure) but does NOT dismiss — the user confirms by tapping outside. A subtle
// "Clear" text link appears only when a rating exists.
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
        VStack(spacing: 10) {
            RatingStripView(value: current) { newValue in
                current = newValue
                onSet(newValue)
            }
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
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

    private let haptic = RatingHaptic()
    private let space = "fluidRating"

    init(track: Track) {
        self.track = track
        _rating = State(initialValue: track.rating)
    }

    var body: some View {
        collapsedStar
            .overlay(alignment: .center) {
                if isDragging { revealStrip.offset(y: RatingTuning.revealYOffset) }
            }
            .coordinateSpace(name: space)
            .contentShape(Rectangle())
            .highPriorityGesture(reduceMotion ? nil : holdDrag)
            .onTapGesture { showingPicker = true }
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

    private var holdDrag: some Gesture {
        LongPressGesture(minimumDuration: RatingTuning.longPressDuration)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(space)))
            .onChanged { value in
                switch value {
                case .first(true):
                    beginDragging()
                case .second(true, let drag?):
                    beginDragging()
                    updatePreview(forX: drag.location.x)
                default:
                    break
                }
            }
            .onEnded { value in
                if case .second(true, let drag?) = value {
                    updatePreview(forX: drag.location.x)
                    commit(preview)
                }
                endDragging()
            }
    }

    private func beginDragging() {
        guard !isDragging else { return }
        withAnimation(.snappy(duration: 0.18)) { isDragging = true }
        preview = rating
        lastHapticValue = rating
        haptic.prepare()
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
