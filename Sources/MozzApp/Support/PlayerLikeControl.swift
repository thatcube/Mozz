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

    init(track: Track) {
        self.track = track
        _isFavorite = State(initialValue: track.isFavorite)
    }

    var body: some View {
        Group {
            if env.usesRatings {
                FluidRatingControl(track: track)
            } else {
                heart
            }
        }
        // The view is reused across track changes (same position in the drawer),
        // so reseed the favorite when the current song changes or updates in place.
        // (The ratings path is self-contained in `FluidRatingControl`.)
        .onChange(of: track.id) { _, _ in isFavorite = track.isFavorite }
        .onChange(of: track.isFavorite) { _, new in isFavorite = new }
    }

    private var heart: some View {
        Button {
            isFavorite.toggle()
            let snapshot = track
            let liked = isFavorite
            Task { await env.setLiked(liked, track: snapshot) }
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .foregroundStyle(isFavorite ? Color.pink : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorite ? "Unlike" : "Like")
    }
}
