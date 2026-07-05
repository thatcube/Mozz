import SwiftUI
import MozzCore

/// Renders artwork for a catalog item. Resolves a tokenized URL from the active
/// backend at the requested pixel size (the catalog stores only a reference, so
/// URLs stay valid across token rotation). Falls back to a deterministic
/// gradient tile keyed on the title, which is what shows in the offline demo
/// (no server = no artwork).
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

    private var placeholder: some View {
        let hash = abs(seed.hashValue)
        let hue = Double(hash % 360) / 360.0
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.5, brightness: 0.7),
                Color(hue: (hue + 0.1).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.45),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay(
            Image(systemName: "music.note")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size * 0.4, height: size * 0.4)
                .foregroundStyle(.white.opacity(0.85))
        )
    }
}
