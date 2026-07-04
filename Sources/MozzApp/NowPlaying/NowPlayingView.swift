import SwiftUI
import MozzCore
import MozzPlayback

/// The full-screen player: large artwork, a scrubber, transport controls,
/// shuffle/repeat toggles, and the up-next queue.
struct NowPlayingView: View {
    @EnvironmentObject private var playback: PlaybackEngine
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing = false
    @State private var scrubValue = 0.0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if let track = playback.currentTrack {
                        ArtworkView(artwork: track.artwork, seed: track.albumTitle ?? track.title, size: 280, cornerRadius: 16)
                            .shadow(radius: 12, y: 6)
                            .padding(.top)

                        VStack(spacing: 4) {
                            Text(track.title).font(.title2.bold()).multilineTextAlignment(.center)
                            Text(track.artistName).font(.title3).foregroundStyle(.secondary)
                            if let album = track.albumTitle {
                                Text(album).font(.subheadline).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal)

                        scrubber(playback: playback)
                        transport(playback: playback)
                        secondaryControls(playback: playback)
                        formatBadge(track: track)
                        upNext(playback: playback)
                    } else {
                        ContentUnavailableView("Nothing Playing", systemImage: "music.note")
                            .padding(.top, 80)
                    }
                }
                .padding()
            }
            .navigationTitle("Now Playing")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func scrubber(playback: PlaybackEngine) -> some View {
        let snapshot = playback.snapshot
        return VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { scrubbing ? scrubValue : snapshot.elapsed },
                    set: { scrubValue = $0 }
                ),
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
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func transport(playback: PlaybackEngine) -> some View {
        HStack(spacing: 44) {
            Button { playback.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            .disabled(!playback.snapshot.hasPrevious)

            Button { playback.togglePlayPause() } label: {
                Image(systemName: playback.snapshot.status == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }

            Button { playback.next() } label: {
                Image(systemName: "forward.fill").font(.title)
            }
            .disabled(!playback.snapshot.hasNext)
        }
    }

    private func secondaryControls(playback: PlaybackEngine) -> some View {
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
        return Text(parts.joined(separator: " · "))
            .font(.caption2).foregroundStyle(.tertiary)
    }

    @ViewBuilder private func upNext(playback: PlaybackEngine) -> some View {
        if !playback.upNext.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Up Next").font(.headline)
                ForEach(Array(playback.upNext.prefix(50).enumerated()), id: \.offset) { _, track in
                    HStack {
                        Text(track.title).lineLimit(1)
                        Spacer()
                        Text(track.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.subheadline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top)
        }
    }

    private func repeatIcon(_ mode: MozzPlayback.RepeatMode) -> String {
        switch mode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}
