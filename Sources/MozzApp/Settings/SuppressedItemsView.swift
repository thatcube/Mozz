import SwiftUI
import MozzCore
import MozzDatabase

/// Settings → "Not Recommended": the durable management surface for everything
/// the user has told Mozz not to recommend (via "Don't recommend this track /
/// artist"). Provides a non-timed way to reverse a suppression after the Undo
/// toast is gone — which is also what lets the transient toast satisfy WCAG
/// 2.2.1 (the toast is not the only recovery path).
struct SuppressedItemsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var items: [RecommendationStore.SuppressedItem] = []
    @State private var loaded = false

    private var tracks: [RecommendationStore.SuppressedItem] { items.filter { $0.scope == "track" } }
    private var artists: [RecommendationStore.SuppressedItem] { items.filter { $0.scope == "artist" } }

    var body: some View {
        List {
            if loaded && items.isEmpty {
                emptyState
            } else {
                if !artists.isEmpty {
                    Section("Artists") {
                        ForEach(artists) { row($0) }
                            .onDelete { remove(artists, at: $0) }
                    }
                }
                if !tracks.isEmpty {
                    Section("Tracks") {
                        ForEach(tracks) { row($0) }
                            .onDelete { remove(tracks, at: $0) }
                    }
                }
            }
        }
        .navigationTitle("Not Recommended")
        .inlineNavigationTitle()
        .task { await reload() }
    }

    private func row(_ item: RecommendationStore.SuppressedItem) -> some View {
        let isArtist = item.scope == "artist"
        return HStack(spacing: 12) {
            ArtworkView(artwork: item.artworkKey.map(ArtworkRef.init(key:)),
                        seed: item.title, size: 44,
                        cornerRadius: isArtist ? 22 : 6, circular: isArtist)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button("Restore") { restore(item) }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(mozz: "hand.thumbsdown")
                .resizable().scaledToFit().frame(width: 34, height: 34)
                .foregroundStyle(.tertiary)
            Text("Nothing hidden")
                .font(.headline)
            Text("Tracks and artists you tell Mozz not to recommend show up here, where you can restore them.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }

    private func reload() async {
        items = await env.suppressedItems()
        loaded = true
    }

    private func restore(_ item: RecommendationStore.SuppressedItem) {
        withAnimation { items.removeAll { $0.id == item.id } }
        Task { await env.unsuppress(item) }
    }

    private func remove(_ group: [RecommendationStore.SuppressedItem], at offsets: IndexSet) {
        let targets = offsets.map { group[$0] }
        withAnimation { items.removeAll { t in targets.contains(where: { $0.id == t.id }) } }
        Task { for item in targets { await env.unsuppress(item) } }
    }
}
