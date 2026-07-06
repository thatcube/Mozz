import WidgetKit
import SwiftUI
import MozzCore

// MARK: - Shared helpers

private func widgetArtwork(_ file: String?) -> Image? {
    guard let url = WidgetSnapshotStore.artworkURL(file),
          let image = UIImage(contentsOfFile: url.path) else { return nil }
    return Image(uiImage: image)
}

private func deepLinkURL(_ string: String) -> URL {
    URL(string: string) ?? URL(string: "mozz://tab/home")!
}

extension Color {
    /// Parse a "#RRGGBB" hex string (from the app's WidgetTint), or `nil`.
    init?(hex: String?) {
        guard var hex, !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

// MARK: - Now Playing widget

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: NowPlayingWidgetSnapshot?
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, snapshot: NowPlayingWidgetSnapshot(
            title: "Song Title", artist: "Artist", isPlaying: true,
            artworkFile: nil, deepLink: "mozz://tab/library"))
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(NowPlayingEntry(date: .now, snapshot: WidgetSnapshotStore.readNowPlaying()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        // The app pushes reloads on every playback change, so a single entry that
        // never expires on its own is correct.
        let entry = NowPlayingEntry(date: .now, snapshot: WidgetSnapshotStore.readNowPlaying())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: NowPlayingEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                content(snapshot).widgetURL(deepLinkURL(snapshot.deepLink))
            } else {
                emptyState
            }
        }
    }

    @ViewBuilder private func content(_ s: NowPlayingWidgetSnapshot) -> some View {
        if family == .systemSmall {
            smallLayout(s)
        } else {
            mediumLayout(s)
        }
    }

    // MARK: Layouts

    private func smallLayout(_ s: NowPlayingWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                crispArtwork(s).frame(width: 64, height: 64)
                Spacer(minLength: 0)
                playPauseButton(s, compact: true)
            }
            Spacer(minLength: 8)
            Text(s.title).font(.subheadline).fontWeight(.semibold)
                .lineLimit(2).minimumScaleFactor(0.8)
            Text(s.artist).font(.caption).lineLimit(1).opacity(0.8)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { background(s) }
    }

    private func mediumLayout(_ s: NowPlayingWidgetSnapshot) -> some View {
        HStack(spacing: 16) {
            // Big square cover that fills the widget height, like Apple Music.
            crispArtwork(s)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                Text(s.isPlaying ? "NOW PLAYING" : "PAUSED")
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundStyle(.white.opacity(0.7))
                    .tracking(0.5)
                Text(s.title).font(.headline).fontWeight(.semibold)
                    .lineLimit(2).minimumScaleFactor(0.8)
                Text(s.artist).font(.subheadline).lineLimit(1).opacity(0.85)
                Spacer(minLength: 6)
                playPauseButton(s, compact: false)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { background(s) }
    }

    // MARK: Pieces

    /// Functional play/pause. On iOS 17+ it's a real interactive `Button(intent:)`
    /// that toggles playback in the app process without opening the app; on older
    /// systems it degrades to a static indicator.
    @ViewBuilder private func playPauseButton(_ s: NowPlayingWidgetSnapshot, compact: Bool) -> some View {
        if #available(iOS 17.0, *) {
            Button(intent: TogglePlayPauseIntent()) {
                playPauseLabel(s, compact: compact)
            }
            .buttonStyle(.plain)
        } else {
            playPauseLabel(s, compact: compact)
        }
    }

    @ViewBuilder private func playPauseLabel(_ s: NowPlayingWidgetSnapshot, compact: Bool) -> some View {
        let icon = s.isPlaying ? "pause.fill" : "play.fill"
        if compact {
            Image(systemName: icon)
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.22), in: Circle())
        } else {
            Label(s.isPlaying ? "Pause" : "Play", systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(.white.opacity(0.22), in: Capsule())
        }
    }

    /// Sharp, rounded cover thumbnail with a subtle edge + lift.
    @ViewBuilder private func crispArtwork(_ s: NowPlayingWidgetSnapshot) -> some View {
        Group {
            if let image = widgetArtwork(s.artworkFile) {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.white.opacity(0.18))
                    Image(systemName: "music.note").foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
    }

    /// Blurred cover art as a rich full-bleed background with a legibility scrim;
    /// a warm gradient fallback when there's no artwork yet.
    @ViewBuilder private func background(_ s: NowPlayingWidgetSnapshot) -> some View {
        if let tint = Color(hex: s.tintHex) {
            // Apple-Music style: a muted shade of the cover as a solid tint, with
            // a subtle top-down gradient for depth.
            LinearGradient(colors: [tint.opacity(0.92), tint],
                           startPoint: .top, endPoint: .bottom)
        } else if let image = widgetArtwork(s.artworkFile) {
            ZStack {
                image.resizable().aspectRatio(contentMode: .fill)
                    .blur(radius: 30).scaleEffect(1.4)
                LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.6)],
                               startPoint: .top, endPoint: .bottom)
            }
        } else {
            LinearGradient(colors: [Color(red: 0.36, green: 0.20, blue: 0.52),
                                    Color(red: 0.15, green: 0.11, blue: 0.28)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note").font(.title2)
            Text("Nothing Playing").font(.caption)
        }
        .foregroundStyle(.white.opacity(0.9))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 0.22, green: 0.24, blue: 0.30),
                                    Color(red: 0.11, green: 0.12, blue: 0.16)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: MozzWidget.nowPlayingKind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("Shows the track currently playing in Mozz.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Recently Played widget

struct RecentlyPlayedEntry: TimelineEntry {
    let date: Date
    let items: [RecentlyPlayedItem]
}

struct RecentlyPlayedProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentlyPlayedEntry {
        RecentlyPlayedEntry(date: .now, items: (0..<4).map {
            RecentlyPlayedItem(id: "\($0)", title: "Song \($0 + 1)", subtitle: "Artist",
                               artworkFile: nil, deepLink: "mozz://tab/library")
        })
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentlyPlayedEntry) -> Void) {
        completion(RecentlyPlayedEntry(date: .now, items: WidgetSnapshotStore.readRecentlyPlayed()?.items ?? []))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentlyPlayedEntry>) -> Void) {
        let entry = RecentlyPlayedEntry(date: .now, items: WidgetSnapshotStore.readRecentlyPlayed()?.items ?? [])
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct RecentlyPlayedWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: RecentlyPlayedEntry

    private var count: Int { family == .systemLarge ? 6 : 4 }

    var body: some View {
        Group {
            if entry.items.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recently Played").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(entry.items.prefix(count)) { item in
                        Link(destination: deepLinkURL(item.deepLink)) {
                            row(item)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func row(_ item: RecentlyPlayedItem) -> some View {
        HStack(spacing: 10) {
            artwork(item)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.caption).lineLimit(1)
                Text(item.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func artwork(_ item: RecentlyPlayedItem) -> some View {
        if let image = widgetArtwork(item.artworkFile) {
            image.resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "music.note").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath").font(.title3).foregroundStyle(.secondary)
            Text("No recent plays").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RecentlyPlayedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: MozzWidget.recentlyPlayedKind, provider: RecentlyPlayedProvider()) { entry in
            RecentlyPlayedWidgetView(entry: entry)
        }
        .configurationDisplayName("Recently Played")
        .description("Jump back into songs you played recently in Mozz.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: - Bundle

@main
struct MozzWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        RecentlyPlayedWidget()
    }
}
