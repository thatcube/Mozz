import SwiftUI
import MozzCore
#if canImport(UIKit)
import UIKit
#endif

/// Derives the background color a media-detail hero fades into. The hero artwork
/// "blends into a color from the image" (Apple Music style), so we extract the
/// average color of the (already cached) artwork and adjust it into a rich,
/// legible, slightly-dark tone. When there's no artwork — the offline demo, or a
/// server that returns none — we fall back to a deterministic hue derived from a
/// seed string, matching `ArtworkView`'s placeholder so the page still feels
/// intentional rather than grey.
enum DominantColor {
    /// Resolve + load the artwork and extract a hero background color, or fall
    /// back to the seed color. Runs off the main thread (image decode is in
    /// `ArtworkImageLoader`).
    static func background(for artwork: ArtworkRef?, seed: String,
                           backend: (any MusicBackend)?, pixelSize: CGFloat = 240) async -> Color {
        #if canImport(UIKit)
        if let artwork, let backend, let url = backend.artworkURL(for: artwork, size: Int(pixelSize)),
           let image = await ArtworkImageLoader.shared.image(for: url),
           let average = image.mozzAverageColor() {
            return Color(average.mozzHeroAdjusted())
        }
        #endif
        return seedColor(seed)
    }

    /// Deterministic fallback color from a seed string (mirrors the hue used by
    /// `ArtworkView`'s gradient placeholder, darkened for a hero background).
    static func seedColor(_ seed: String) -> Color {
        let hue = Double(abs(seed.hashValue) % 360) / 360.0
        return Color(hue: hue, saturation: 0.5, brightness: 0.42)
    }
}

#if canImport(UIKit)
extension UIImage {
    /// The average color of the image (the whole image scaled into a single
    /// pixel — the GPU/CoreGraphics downsample averages it for us).
    func mozzAverageColor() -> UIColor? {
        guard let cg = cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                       blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }
}

extension UIColor {
    /// Adjust an extracted color into a hero-background tone: a touch richer, and
    /// capped in brightness so white overlaid text stays legible.
    func mozzHeroAdjusted() -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return UIColor(hue: h, saturation: min(1, s * 1.15), brightness: min(b, 0.5), alpha: 1)
    }
}
#endif
