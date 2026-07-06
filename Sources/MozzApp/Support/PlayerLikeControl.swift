import SwiftUI
import MozzCore

/// The now-playing screen's like/rate affordance, working from the engine's
/// domain ``Track``. Backend-aware like ``LikeControl`` (heart for favorites
/// backends, a star + half-star popover for ratings backends), but sized for the
/// full player and reseeded whenever the current track changes.
struct PlayerLikeControl: View {
    @EnvironmentObject private var env: AppEnvironment
    let track: Track

    @State private var isFavorite: Bool
    @State private var rating: Double?
    @State private var showingPicker = false

    init(track: Track) {
        self.track = track
        _isFavorite = State(initialValue: track.isFavorite)
        _rating = State(initialValue: track.rating)
    }

    private var liked: Bool { LikePolicy.isLiked(isFavorite: isFavorite, rating: rating) }

    var body: some View {
        Group {
            if env.usesRatings {
                ratingButton
            } else {
                heart
            }
        }
        // The view is reused across track changes (same position in the drawer),
        // so seed from the new track when the current song changes.
        .onChange(of: track.id) { _, _ in
            isFavorite = track.isFavorite
            rating = track.rating
        }
    }

    private var heart: some View {
        Button {
            isFavorite.toggle()
            let snapshot = track
            let liked = isFavorite
            Task { await env.setLiked(liked, track: snapshot) }
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .foregroundStyle(liked ? Color.pink : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(liked ? "Unlike" : "Like")
    }

    private var ratingButton: some View {
        Button { showingPicker = true } label: {
            Image(systemName: (rating ?? 0) > 0 ? "star.fill" : "star")
                .foregroundStyle((rating ?? 0) > 0 ? Color.yellow : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rating.map { "Rated \(LikeControl.format($0)) stars" } ?? "Rate")
        .popover(isPresented: $showingPicker) {
            RatingStarsPicker(rating: rating) { newValue in
                rating = newValue
                showingPicker = false
                let snapshot = track
                Task { await env.setRating(newValue, track: snapshot) }
            }
            .padding(16)
            .presentationCompactAdaptation(.popover)
        }
    }
}
