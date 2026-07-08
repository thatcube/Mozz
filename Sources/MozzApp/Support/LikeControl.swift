import SwiftUI
import MozzCore
import MozzDatabase

/// The backend-aware "like" affordance:
/// - **Favorites backend** (Jellyfin) → a heart that fills when liked.
/// - **Ratings backend** (Plex) → a compact "★ N" chip; tapping opens a
///   transient half-star popover, so the granular rating lives on demand rather
///   than in a permanent full-width star row.
///
/// State is optimistic (the tap flips it instantly); the durable write goes
/// through ``AppEnvironment`` (local DB first, server sync queued). Reads stay
/// in sync if the underlying record changes (e.g. after a library sync).
struct LikeControl: View {
    @EnvironmentObject private var env: AppEnvironment
    let track: TrackRecord

    @State private var isFavorite: Bool
    @State private var rating: Double?
    @State private var showingPicker = false

    init(track: TrackRecord) {
        self.track = track
        _isFavorite = State(initialValue: track.isFavorite)
        _rating = State(initialValue: track.rating)
    }

    private var liked: Bool { LikePolicy.isLiked(isFavorite: isFavorite, rating: rating) }

    var body: some View {
        Group {
            if env.usesRatings {
                ratingChip
            } else {
                heart
            }
        }
        .onChange(of: track.isFavorite) { _, new in isFavorite = new }
        .onChange(of: track.rating) { _, new in rating = new }
    }

    private var heart: some View {
        Button {
            let snapshot = track
            isFavorite.toggle()
            Task { await env.setLiked(isFavorite, track: snapshot) }
        } label: {
            Image(mozz: liked ? "heart.fill" : "heart")
                .foregroundStyle(liked ? Color.pink : Color.secondary)
                .font(.body)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(liked ? "Unlike" : "Like")
    }

    private var ratingChip: some View {
        Button { showingPicker = true } label: {
            HStack(spacing: 3) {
                Image(mozz: (rating ?? 0) > 0 ? "star.fill" : "star")
                if let r = rating, r > 0 {
                    Text(Self.format(r)).font(.caption.monospacedDigit())
                }
            }
            .foregroundStyle((rating ?? 0) > 0 ? Color.yellow : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rating.map { "Rated \(Self.format($0)) stars" } ?? "Rate")
        .popover(isPresented: $showingPicker) {
            RatingStarsPicker(rating: rating) { newValue in
                let snapshot = track
                rating = newValue
                showingPicker = false
                Task { await env.setRating(newValue, track: snapshot) }
            }
            .padding(16)
            .presentationCompactAdaptation(.popover)
        }
    }

    static func format(_ r: Double) -> String {
        r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }
}

/// A compact, transient 5-star picker with half-star granularity (tap the left
/// half of a star for x.5, the right half for x.0) plus a Clear action. Lives in
/// a popover — never a permanent row.
struct RatingStarsPicker: View {
    let rating: Double?
    let onSelect: (Double?) -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { i in star(i) }
            }
            Button(role: .destructive) { onSelect(nil) } label: {
                Label("Clear rating", mozz: "star.slash")
            }
            .font(.subheadline)
            .disabled((rating ?? 0) == 0)
        }
    }

    private func star(_ i: Int) -> some View {
        let value = rating ?? 0
        let symbol = value >= Double(i) ? "star.fill"
            : value >= Double(i) - 0.5 ? "star.leadinghalf.filled" : "star"
        return Image(mozz: symbol)
            .resizable().scaledToFit().frame(width: 28, height: 28)
            .foregroundStyle(.yellow)
            .overlay {
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { onSelect(Double(i) - 0.5) }
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { onSelect(Double(i)) }
                }
            }
    }
}
