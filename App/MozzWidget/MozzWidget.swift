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
    var entry: NowPlayingEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            content(snapshot)
                .widgetURL(deepLinkURL(snapshot.deepLink))
        } else {
            emptyState
        }
    }

    private func content(_ snapshot: NowPlayingWidgetSnapshot) -> some View {
        HStack(spacing: 12) {
            artwork(snapshot)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.title).font(.headline).lineLimit(2)
                Text(snapshot.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Label(snapshot.isPlaying ? "Playing" : "Paused",
                      systemImage: snapshot.isPlaying ? "play.fill" : "pause.fill")
                    .font(.caption2).foregroundStyle(.tertiary).labelStyle(.titleAndIcon)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder private func artwork(_ snapshot: NowPlayingWidgetSnapshot) -> some View {
        if let image = widgetArtwork(snapshot.artworkFile) {
            image.resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary)
            Text("Nothing Playing").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.fill.tertiary, for: .widget)
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
