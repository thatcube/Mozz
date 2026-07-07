import SwiftUI
import MozzCore
import MozzPlayback
#if canImport(UIKit)
import AVKit
import UIKit
#endif

// MARK: - AirPlay route picker

#if canImport(UIKit)
/// A SwiftUI wrapper around `AVRoutePickerView` — the real system AirPlay /
/// output-route picker. Tapping it presents the OS route sheet (headphones,
/// AirPlay speakers, etc.). Tinted to match the player's monochrome controls;
/// pass a clear tint to hide its built-in glyph and overlay a custom device icon.
struct AirPlayRoutePicker: UIViewRepresentable {
    var tint: UIColor = .label

    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = tint
        v.activeTintColor = tint
        v.prioritizesVideoDevices = false
        v.backgroundColor = .clear
        v.setContentHuggingPriority(.required, for: .horizontal)
        v.setContentHuggingPriority(.required, for: .vertical)
        return v
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = tint
        view.activeTintColor = tint
    }
}

/// Observes the current audio output route (`AVAudioSession`) so the player can
/// show the *actual* output device — its name ("Brandon's Room") and a matching
/// icon — like Apple Music. Updates live on route changes (plugging headphones,
/// picking an AirPlay speaker, etc.).
@MainActor
final class AudioRouteMonitor: ObservableObject {
    struct Output: Equatable {
        var name: String
        var icon: String
        /// Show a route label at all (false only for the built-in speaker).
        var showsLabel: Bool
        /// Prepend "iPhone →" — Apple does this only for external speakers /
        /// rooms (AirPlay, CarPlay, TV), NOT personal audio (AirPods/headphones).
        var showsSourcePrefix: Bool
    }

    @Published private(set) var output: Output

    private var observer: NSObjectProtocol?

    init() {
        output = Self.current()
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.output = Self.current() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private static func current() -> Output {
        let route = AVAudioSession.sharedInstance().currentRoute
        guard let out = route.outputs.first else {
            return Output(name: "iPhone", icon: "iphone", showsLabel: false, showsSourcePrefix: false)
        }
        return classify(port: out.portType, name: out.portName)
    }

    private static func classify(port: AVAudioSession.Port, name: String) -> Output {
        switch port {
        case .builtInSpeaker, .builtInReceiver:
            return Output(name: "iPhone", icon: "iphone", showsLabel: false, showsSourcePrefix: false)
        case .headphones, .headsetMic:
            return Output(name: name, icon: "headphones", showsLabel: true, showsSourcePrefix: false)
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
            // Personal Bluetooth audio (AirPods / Beats / headphones): show the
            // device icon + its name, no "iPhone →" prefix (matches Apple).
            return Output(name: name, icon: bluetoothIcon(name: name),
                          showsLabel: true, showsSourcePrefix: false)
        case .usbAudio:
            return Output(name: name, icon: "headphones", showsLabel: true, showsSourcePrefix: false)
        case .airPlay:
            // External room/speaker: "iPhone → Name". Public API can't identify
            // the AirPlay target (HomePod vs Apple TV vs 3rd-party) and usually
            // reports a generic "AirPlay" name, so we always show the generic
            // AirPlay glyph rather than risk a confidently-wrong specific icon.
            return Output(name: name, icon: airPlaySymbol,
                          showsLabel: true, showsSourcePrefix: true)
        case .carAudio:
            return Output(name: name, icon: "car.fill", showsLabel: true, showsSourcePrefix: true)
        case .HDMI, .displayPort:
            return Output(name: name, icon: "tv.fill", showsLabel: true, showsSourcePrefix: true)
        default:
            return Output(name: name, icon: airPlaySymbol, showsLabel: true, showsSourcePrefix: true)
        }
    }

    /// AirPods get their model-specific glyph via a name heuristic (the port type
    /// alone can't distinguish them); everything else on Bluetooth just shows a
    /// headphones icon (we can't reliably tell a BT speaker from headphones, and
    /// headphones is the common personal-audio case).
    private static func bluetoothIcon(name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpod") { return airPodsIcon(name: n) }
        return "headphones"
    }

    /// Pick the model-specific AirPods glyph. There's no public API for the model,
    /// but iOS's default naming (and user names) include it — "AirPods Pro",
    /// "AirPods (4th generation)", "…Gen 4 AirPods" — so we parse the name. Each
    /// choice validates against the runtime so an unknown/too-new symbol falls
    /// back to a known-good AirPods glyph rather than rendering blank. `name` is
    /// already lowercased.
    private static func airPodsIcon(name n: String) -> String {
        if n.contains("max") {
            return firstAvailableSymbol(["airpods.max", "airpodsmax", "airpods"])
        }
        if n.contains("pro") {
            return firstAvailableSymbol(["airpods.pro", "airpodspro", "airpods"])
        }
        if n.contains("gen 4") || n.contains("gen4") || n.contains("4th gen") || n.contains("generation 4") {
            return firstAvailableSymbol(["airpods.gen4", "airpods.gen3", "airpods"])
        }
        if n.contains("gen 3") || n.contains("gen3") || n.contains("3rd gen") || n.contains("generation 3") {
            return firstAvailableSymbol(["airpods.gen3", "airpods"])
        }
        return "airpods"
    }

    /// The first SF Symbol name in `candidates` that actually exists on this OS
    /// (guards against too-new symbol names), else the last as a final fallback.
    private static func firstAvailableSymbol(_ candidates: [String]) -> String {
        for name in candidates where UIImage(systemName: name) != nil { return name }
        return candidates.last ?? "airpods"
    }

    /// The generic AirPlay glyph — the honest icon for any AirPlay target, since
    /// public API can't identify the specific device.
    private static var airPlaySymbol: String {
        firstAvailableSymbol(["airplayaudio", "airplay.audio"])
    }
}
#endif

// MARK: - Queue panel

/// The full-player queue: the played "History" (scroll up), the current track,
/// and the "Continue Playing" up-next list. Tapping any row jumps to & plays it.
/// Drag-to-reorder is intentionally deferred — rows show a static handle glyph as
/// a placeholder for that future capability.
///
/// Order math: the queue's play order is `history + [current] + upNext`, so a
/// history row at index `i` maps to order position `i`, and an up-next row at
/// index `j` maps to `history.count + 1 + j` (current sits at `history.count`).
struct PlayerQueuePanel: View {
    @ObservedObject var playback: PlaybackEngine
    /// Jump to a specific order position and play it.
    var onSelect: (Int) -> Void
    /// Drop the played history.
    var onClearHistory: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    history
                    nowPlayingRow
                    continuePlaying
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                // Start anchored on the current track (history sits above, scroll
                // up to reveal it) — matches Apple's queue.
                proxy.scrollTo(nowPlayingID, anchor: .top)
            }
        }
    }

    private let nowPlayingID = "queue.nowPlaying"

    // MARK: History

    @ViewBuilder private var history: some View {
        let items = playback.history
        if !items.isEmpty {
            HStack {
                Text("History").font(.headline)
                Spacer()
                Button("Clear", action: onClearHistory)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)

            ForEach(Array(items.enumerated()), id: \.offset) { index, track in
                row(track: track, orderPosition: index, dimmed: true)
            }
            .padding(.bottom, 4)
        }
    }

    // MARK: Now playing (anchor)

    @ViewBuilder private var nowPlayingRow: some View {
        if let track = playback.currentTrack {
            row(track: track, orderPosition: playback.history.count, isCurrent: true)
                .id(nowPlayingID)
        }
    }

    // MARK: Continue Playing

    @ViewBuilder private var continuePlaying: some View {
        let items = playback.upNext
        if !items.isEmpty {
            Text("Continue Playing")
                .font(.headline)
                .padding(.top, 14)
                .padding(.bottom, 6)

            let base = playback.history.count + 1
            ForEach(Array(items.enumerated()), id: \.offset) { index, track in
                row(track: track, orderPosition: base + index, showsHandle: true)
            }
        }
    }

    // MARK: Row

    private func row(track: Track, orderPosition: Int,
                     dimmed: Bool = false, isCurrent: Bool = false,
                     showsHandle: Bool = false) -> some View {
        Button {
            onSelect(orderPosition)
        } label: {
            HStack(spacing: 12) {
                ArtworkView(artwork: track.artwork,
                            seed: track.albumTitle ?? track.title,
                            size: 44, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .lineLimit(1)
                    Text(track.artistName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if showsHandle {
                    // Static drag-handle placeholder (reorder deferred).
                    Image(systemName: "line.3.horizontal")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .opacity(dimmed ? 0.6 : 1)
        }
        .buttonStyle(.plain)
    }
}
