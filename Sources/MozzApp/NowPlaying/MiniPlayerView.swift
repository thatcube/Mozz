import SwiftUI
import MozzPlayback

/// A compact player docked above the tab bar. Shows current artwork/title and a
/// play/pause + next control; tapping the body opens the full Now Playing sheet.
struct MiniPlayerView: View {
    @EnvironmentObject private var playback: PlaybackEngine
    @Binding var showNowPlaying: Bool

    var body: some View {
        if let track = playback.currentTrack {
            VStack(spacing: 0) {
                ProgressView(value: playback.snapshot.progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .scaleEffect(x: 1, y: 0.5, anchor: .center)

                HStack(spacing: 12) {
                    ArtworkView(artwork: track.artwork, seed: track.albumTitle ?? track.title, size: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title).font(.subheadline).lineLimit(1)
                        Text(track.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { playback.togglePlayPause() } label: {
                        Image(systemName: playback.snapshot.status == .playing ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }
                    Button { playback.next() } label: {
                        Image(systemName: "forward.fill").font(.title3)
                    }
                    .disabled(!playback.snapshot.hasNext)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.ultraThinMaterial)
            .contentShape(Rectangle())
            .onTapGesture { showNowPlaying = true }
        }
    }
}
