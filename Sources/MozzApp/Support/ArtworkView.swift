import SwiftUI
import MozzCore

/// A subtle, theme-aware artwork placeholder: a quiet neutral gray box with a
/// faint music-note glyph, sized to whatever frame it's given. Shared by every
/// artwork surface (rows, grids, the player) so a missing/loading cover always
/// reads as a calm empty frame — never a colorful tile that flashes during
/// scrolling or track changes. The caller clips it to the artwork's shape.
struct ArtworkPlaceholder: View {
    /// Music-note glyph size as a fraction of the box's shorter side.
    var iconScale: CGFloat = 0.32

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            Color.mozzArtworkPlaceholder
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: side * iconScale, weight: .regular))
                        .foregroundStyle(.secondary)
                        .opacity(0.35)
                )
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// Renders artwork for a catalog item. Resolves a tokenized URL from the active
/// backend at the requested pixel size (the catalog stores only a reference, so
/// URLs stay valid across token rotation). Falls back to a subtle neutral
/// placeholder (matching the artwork's shape) while loading or when there's no
/// artwork — e.g. the offline demo, or a server that returns none.
struct ArtworkView: View {
    let artwork: ArtworkRef?
    let seed: String
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 6

    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        Group {
            if let url = resolvedURL {
                CachedArtworkImage(url: url) { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var resolvedURL: URL? {
        guard let artwork, let backend = env.active?.backend else { return nil }
        return backend.artworkURL(for: artwork, size: Int(size * 2))
    }

    private var placeholder: some View { ArtworkPlaceholder() }
}
