import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The now-playing seek bar: a knob-less capsule that fills to the current
/// position. At rest — and while playing — it looks identical. While you
/// press-and-drag to seek, the bar grows taller and brightens, and both time
/// labels (elapsed on the left, remaining on the right) brighten and scale up.
/// Apple-Music style.
struct SeekBar: View {
    let elapsed: Double
    let duration: Double
    /// Called once, on release, with the target time to seek to.
    let onSeek: (Double) -> Void

    // MARK: Tunables
    private let restHeight: CGFloat = 12
    private let seekHeight: CGFloat = 20
    private let restFillOpacity: CGFloat = 0.65
    private let restTrackOpacity: CGFloat = 0.22
    private let seekTrackOpacity: CGFloat = 0.34
    private let restLabelOpacity: CGFloat = 0.5
    private let seekLabelScale: CGFloat = 1.14
    private let labelSpacing: CGFloat = 10
    private let anim: Animation = .spring(response: 0.30, dampingFraction: 0.82)

    @State private var scrubbing = false
    @State private var scrubValue = 0.0

    private var current: Double { scrubbing ? scrubValue : elapsed }
    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(current / duration, 0), 1)
    }
    private var remaining: Double { max(duration - current, 0) }

    var body: some View {
        VStack(spacing: labelSpacing) {
            bar
            labels
        }
    }

    // MARK: Bar

    private var bar: some View {
        GeometryReader { geo in
            let h = scrubbing ? seekHeight : restHeight
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(scrubbing ? seekTrackOpacity : restTrackOpacity))
                Capsule()
                    .fill(.white.opacity(scrubbing ? 1 : restFillOpacity))
                    .frame(width: min(w, max(h, w * progress)))
            }
            .frame(width: w, height: h)
            .frame(width: w, height: geo.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(seekGesture(width: w))
            .animation(anim, value: scrubbing)
        }
        // Reserve the taller (seeking) height so the labels below don't shift
        // when the bar grows.
        .frame(height: seekHeight)
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !scrubbing {
                    withAnimation(anim) { scrubbing = true }
                    impact()
                }
                scrubValue = time(atX: value.location.x, width: width)
            }
            .onEnded { value in
                let target = time(atX: value.location.x, width: width)
                scrubValue = target
                onSeek(target)
                withAnimation(anim) { scrubbing = false }
            }
    }

    private func time(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0, duration > 0 else { return 0 }
        return min(max(x / width, 0), 1) * duration
    }

    // MARK: Labels

    private var labels: some View {
        HStack(spacing: 0) {
            timeLabel(Format.duration(current))
                .scaleEffect(scrubbing ? seekLabelScale : 1, anchor: .leading)
            Spacer(minLength: 0)
            timeLabel("\u{2212}" + Format.duration(remaining))
                .scaleEffect(scrubbing ? seekLabelScale : 1, anchor: .trailing)
        }
        .foregroundStyle(.white.opacity(scrubbing ? 1 : restLabelOpacity))
        .animation(anim, value: scrubbing)
    }

    private func timeLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .fontWeight(scrubbing ? .semibold : .regular)
    }

    // MARK: Haptics

    private func impact() {
#if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.impactOccurred(intensity: 0.7)
#endif
    }
}
