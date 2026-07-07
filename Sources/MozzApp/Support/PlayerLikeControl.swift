import SwiftUI
import MozzCore

/// The now-playing screen's **favorites** (heart) affordance for backends that
/// use favorites (Jellyfin). The ratings (Plex) path is handled directly by the
/// morph container so its sticky picker can be hosted at the player root; see
/// `FluidRatingControl` + `PlayerRatingAnchorKey`.
struct PlayerLikeControl: View {
    @EnvironmentObject private var env: AppEnvironment
    let track: Track

    @State private var isFavorite: Bool

    init(track: Track) {
        self.track = track
        _isFavorite = State(initialValue: track.isFavorite)
    }

    var body: some View {
        heart
            // Reused across track changes (same drawer slot) — reseed the favorite
            // when the song changes or its value updates in place.
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
