import SwiftUI
import MozzCore
import MozzPlayback

/// Content for the native `tabViewBottomAccessory` (iOS 26+) — the compact
/// player that docks above the floating tab bar, exactly like Apple Music. On
/// iOS 26 the system supplies the Liquid Glass background, so this view draws no
/// background of its own. Tapping the artwork or the title area expands into the
/// full-screen player.
struct MiniPlayerAccessory: View {
    @ObservedObject var playback: PlaybackEngine
    @ObservedObject var ui: PlayerUIModel
    var onTap: () -> Void

    var body: some View {
        if let track = playback.currentTrack {
            HStack(spacing: 10) {
                ArtworkView(artwork: track.artwork, seed: track.albumTitle ?? track.title,
                            size: 30, cornerRadius: 8)
                    .opacity(ui.isFullPresented ? 0 : 1)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: MiniArtFrameKey.self,
                                                   value: geo.frame(in: .global))
                        }
                    )
                    .onTapGesture(perform: onTap)

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(track.artistName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)

                Button { playback.togglePlayPause() } label: {
                    Image(systemName: playback.snapshot.status == .playing ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { playback.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!playback.snapshot.hasNext)
                .opacity(playback.snapshot.hasNext ? 1 : 0.4)
            }
            .padding(.horizontal, 10)
            .onPreferenceChange(MiniArtFrameKey.self) { frame in
                // The system lays this content out in more than one context: the
                // real on-screen slot (near the bottom of the window) plus an
                // offscreen measurement pass near the origin. Keep only the
                // bottom-most frame so the traveling artwork lands on the real slot.
                if frame.midY >= ui.miniArtFrame.midY { ui.miniArtFrame = frame }
            }
        }
    }
}
