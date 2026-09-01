import SwiftUI
import MozzCore

/// The now-playing screen's **favorites** (heart) affordance for backends that
/// use favorites (Jellyfin). The ratings (Plex) path is handled directly by the
/// morph container so its sticky picker can be hosted at the player root; see
/// `FluidRatingControl` + `PlayerRatingAnchorKey`.
struct PlayerLikeControl: View {
    @EnvironmentObject private var env: AppEnvironment
    let track: Track
    /// Glyph size, shared with the other player controls for a consistent look.
    var glyphSize: CGFloat = PlayerControlMetrics.utilityGlyph

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
            Image(mozz: isFavorite ? "heart.fill" : "heart")
                .resizable().scaledToFit()
                .frame(width: glyphSize, height: glyphSize)
                // The same neutral the star uses, in both states: this app spends
                // its one saturated colour on the action, and a like is not that.
                // The fill carries the state, exactly as it does for a rating.
                .foregroundStyle(Color.primary)
                .playerHitTarget()
        }
        .buttonStyle(PlayerButtonStyle(washDiameter: glyphSize + 20))
        .accessibilityLabel(isFavorite ? "Unlike" : "Like")
    }
}
