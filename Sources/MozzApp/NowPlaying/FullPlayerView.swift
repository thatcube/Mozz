import SwiftUI
import MozzCore
import MozzPlayback

/// The full-screen player, presented as a custom overlay above the tab bar so we
/// fully control the transition. A single artwork view "travels": on present it
/// grows from the mini-accessory slot to the large center; while a finger drags
/// the header down it rides the page 1:1 (staying large); on release it springs
/// straight into the mini-accessory artwork slot while the chrome fades. Because
/// the artwork is rendered at a fixed pixel size and only *scaled*, it never
/// reloads mid-flight.
struct FullPlayerView: View {
    @ObservedObject var playback: PlaybackEngine
    @ObservedObject var ui: PlayerUIModel
    var onClose: () -> Void

    /// `true` while the player is docked as the mini accessory (start + end of
    /// life). Flipping it drives the whole grow/shrink transition.
    @State private var collapsed = true
    @State private var dragY: CGFloat = 0
    @State private var scrubbing = false
    @State private var scrubValue = 0.0

    var body: some View {
        GeometryReader { safeGeo in
            let safeTop = safeGeo.safeAreaInsets.top
            GeometryReader { geo in
                let originGlobal = geo.frame(in: .global).origin
                let artSide = min(geo.size.width - 90, 340)

                // Rest center of the big artwork, computed deterministically from
                // the header layout (grabber height + fixed gap) so the chrome's
                // slide-offset can never corrupt it. The live drag is added on top.
                let artTop = safeTop + 39
                let expCenter = CGPoint(x: geo.size.width / 2, y: artTop + artSide / 2)

                // Mini slot, converted from the accessory's global frame into this
                // view's local space (fallback to a bottom-left estimate).
                let miniGlobal = ui.miniArtFrame == .zero
                    ? CGRect(x: originGlobal.x + 28,
                             y: originGlobal.y + geo.size.height - 40,
                             width: 40, height: 40)
                    : ui.miniArtFrame
                let miniCenter = CGPoint(x: miniGlobal.midX - originGlobal.x,
                                         y: miniGlobal.midY - originGlobal.y)
                let miniSide = miniGlobal.width

                let artCenter = collapsed
                    ? miniCenter
                    : CGPoint(x: expCenter.x, y: expCenter.y + dragY)
                let side = collapsed ? miniSide : artSide
                // Land at the mini artwork's exact corner radius (8) so the swap
                // to the real accessory is seamless; grow to 10 when expanded.
                let artRadius: CGFloat = collapsed ? 8 : 10

                ZStack(alignment: .top) {
                    background
                        .offset(y: collapsed ? geo.size.height : dragY)
                    chrome(geo: geo, artSide: artSide, safeTop: safeTop)
                    PlayerArtwork(track: playback.currentTrack, side: side, cornerRadius: artRadius)
                        .shadow(color: .black.opacity(collapsed ? 0 : 0.35),
                                radius: collapsed ? 0 : 18, y: collapsed ? 0 : 10)
                        .position(artCenter)
                        .allowsHitTesting(false)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .onAppear {
                    DispatchQueue.main.async {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { collapsed = false }
                    }
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Background (dims + fades)

    private var background: some View {
        Rectangle()
            .fill(.regularMaterial)
            .overlay(LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.28)],
                                    startPoint: .top, endPoint: .bottom))
            .ignoresSafeArea()
    }

    // MARK: Chrome (everything but the traveling artwork)

    private func chrome(geo: GeometryProxy, artSide: CGFloat, safeTop: CGFloat) -> some View {
        VStack(spacing: 0) {
            header(geo: geo, artSide: artSide, safeTop: safeTop)

            scrubber
                .padding(.horizontal, 32)
                .padding(.top, 22)
            transport
                .padding(.top, 14)
            secondaryControls
                .padding(.top, 20)
            if let track = playback.currentTrack {
                formatBadge(track: track).padding(.top, 12)
            }
            upNext.padding(.top, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .offset(y: collapsed ? geo.size.height : dragY)
    }

    /// The draggable top region: grabber, a spacer that reserves the artwork's
    /// rest space, and the titles. The traveling artwork is drawn as a separate
    /// overlay positioned deterministically at this reserved slot's center — no
    /// measuring, so the chrome's slide-offset can never corrupt the anchor.
    private func header(geo: GeometryProxy, artSide: CGFloat, safeTop: CGFloat) -> some View {
        VStack(spacing: 0) {
            Capsule().fill(.white.opacity(0.5)).frame(width: 40, height: 5)
                .padding(.top, safeTop + 8)

            Color.clear
                .frame(width: artSide, height: artSide)
                .padding(.top, 26)

            VStack(spacing: 5) {
                Text(playback.currentTrack?.title ?? "").font(.title2.bold())
                    .multilineTextAlignment(.center).lineLimit(2)
                Text(playback.currentTrack?.artistName ?? "").font(.title3)
                    .foregroundStyle(.secondary).lineLimit(1)
                if let album = playback.currentTrack?.albumTitle {
                    Text(album).font(.subheadline).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .padding(.top, 26)
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { dragY = max(0, $0.translation.height) }
            .onEnded { value in
                let far = value.translation.height > 140
                let flung = value.predictedEndTranslation.height > 340
                if far || flung {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { dragY = 0 }
                }
            }
    }

    private func dismiss() {
        // `.removed` (not the default `.logicallyComplete`) so `onClose` fires
        // only once the spring has fully settled to the mini size. Otherwise the
        // overlay is torn down mid-settle (slightly under 30pt) and the real
        // 30pt accessory snaps in — a visible "lands too small, then corrects".
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86), completionCriteria: .removed) {
            collapsed = true
            dragY = 0
        } completion: {
            onClose()
        }
    }

    // MARK: Controls

    private var scrubber: some View {
        let snapshot = playback.snapshot
        return VStack(spacing: 4) {
            Slider(
                value: Binding(get: { scrubbing ? scrubValue : snapshot.elapsed },
                               set: { scrubValue = $0 }),
                in: 0...max(snapshot.duration, 1),
                onEditingChanged: { editing in
                    scrubbing = editing
                    if !editing { playback.seek(to: scrubValue) }
                }
            )
            HStack {
                Text(Format.duration(scrubbing ? scrubValue : snapshot.elapsed))
                Spacer()
                Text(Format.duration(snapshot.duration))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 44) {
            Button { playback.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                .disabled(!playback.snapshot.hasPrevious)
            Button { playback.togglePlayPause() } label: {
                Image(systemName: playback.snapshot.status == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            Button { playback.next() } label: { Image(systemName: "forward.fill").font(.title) }
                .disabled(!playback.snapshot.hasNext)
        }
        .tint(.primary)
    }

    private var secondaryControls: some View {
        HStack(spacing: 60) {
            Button { playback.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(playback.snapshot.isShuffled ? Color.accentColor : .secondary)
            }
            Button { playback.cycleRepeatMode() } label: {
                Image(systemName: repeatIcon(playback.snapshot.repeatMode))
                    .foregroundStyle(playback.snapshot.repeatMode == .off ? .secondary : Color.accentColor)
            }
        }
        .font(.title3)
    }

    private func formatBadge(track: Track) -> some View {
        let parts = [track.format.codec?.uppercased(), track.format.sampleRateHz.map { "\($0 / 1000) kHz" }]
            .compactMap { $0 }
        return Text(parts.joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary)
    }

    @ViewBuilder private var upNext: some View {
        if !playback.upNext.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Up Next").font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(playback.upNext.prefix(100).enumerated()), id: \.offset) { _, track in
                            HStack {
                                Text(track.title).lineLimit(1)
                                Spacer()
                                Text(track.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
        } else {
            Spacer(minLength: 0)
        }
    }

    private func repeatIcon(_ mode: MozzPlayback.RepeatMode) -> String {
        switch mode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

/// The single traveling artwork. Its display size (`side`) is animatable, but
/// the pixel size used to resolve the backend URL is fixed, so scaling never
/// triggers an `AsyncImage` reload; the corner radius is constant so it never
/// pops during the flight.
private struct PlayerArtwork: View {
    let track: Track?
    let side: CGFloat
    var cornerRadius: CGFloat = 10

    @EnvironmentObject private var env: AppEnvironment
    private let base: CGFloat = 320

    var body: some View {
        Group {
            if let url = resolvedURL {
                CachedArtworkImage(url: url) { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var resolvedURL: URL? {
        guard let artwork = track?.artwork, let backend = env.active?.backend else { return nil }
        return backend.artworkURL(for: artwork, size: Int(base * 2))
    }

    private var placeholder: some View {
        let seed = track?.albumTitle ?? track?.title ?? ""
        let hash = abs(seed.hashValue)
        let hue = Double(hash % 360) / 360.0
        return LinearGradient(
            colors: [Color(hue: hue, saturation: 0.5, brightness: 0.7),
                     Color(hue: (hue + 0.1).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.45)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay(
            Image(systemName: "music.note")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: side * 0.4, height: side * 0.4)
                .foregroundStyle(.white.opacity(0.85))
        )
    }
}
