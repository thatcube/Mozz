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
    /// A media-detail page's two-tone background. `hero` is the rich color the
    /// artwork fades into at the top; `deep` is a near-black, same-hue tone the
    /// page darkens into a few rows down so the white song text stays legible.
    /// Sharing the artwork's hue is what makes the image → list fade seamless.
    struct Palette: Equatable {
        var hero: Color
        var deep: Color
    }

    /// Resolve + decode the artwork (decode is off the main thread in
    /// `ArtworkImageLoader`) and derive the palette, or fall back to a
    /// deterministic seed palette when there's no artwork.
    static func palette(for artwork: ArtworkRef?, seed: String,
                        backend: (any MusicBackend)?, pixelSize: CGFloat = 240) async -> Palette {
        #if canImport(UIKit)
        if let artwork, let backend, let url = backend.artworkURL(for: artwork, size: Int(pixelSize)),
           let image = await ArtworkImageLoader.shared.image(for: url),
           let average = image.mozzAverageColor() {
            return palette(from: average)
        }
        #endif
        return seedPalette(seed)
    }

    /// The palette IF the artwork is already decoded in the in-memory cache, so a
    /// preloaded hero resolves its colors on the very first frame (no fade-in).
    /// Returns nil when nothing is cached so the caller can await the async path.
    /// The average-color step is a cheap 1x1 draw, fine to run on the main thread.
    static func cachedPalette(for artwork: ArtworkRef?, seed: String,
                              backend: (any MusicBackend)?, pixelSize: CGFloat = 240) -> Palette? {
        #if canImport(UIKit)
        if let artwork, let backend, let url = backend.artworkURL(for: artwork, size: Int(pixelSize)),
           let image = ArtworkImageLoader.shared.cached(url),
           let average = image.mozzAverageColor() {
            return palette(from: average)
        }
        #endif
        return nil
    }

    /// Deterministic fallback palette from a seed string (mirrors `ArtworkView`'s
    /// placeholder hue) for the offline demo / art-less servers.
    static func seedPalette(_ seed: String) -> Palette {
        let hue = Double(abs(seed.hashValue) % 360) / 360.0
        return Palette(hero: Color(hue: hue, saturation: 0.5, brightness: 0.42),
                       deep: Color(hue: hue, saturation: 0.45, brightness: 0.08))
    }

    #if canImport(UIKit)
    private static func palette(from average: UIColor) -> Palette {
        Palette(hero: Color(average.mozzHeroAdjusted()), deep: Color(average.mozzDeepAdjusted()))
    }
    #endif
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
        return UIColor(hue: h, saturation: min(1, s * 1.15), brightness: min(b, 0.46), alpha: 1)
    }

    /// Adjust an extracted color into the page's deep base tone: the same hue,
    /// pushed to a near-black brightness so the song list is high-contrast while
    /// staying tinted by — and seamless with — the hero color above it.
    func mozzDeepAdjusted() -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return UIColor(hue: h, saturation: min(s, 0.5), brightness: 0.08, alpha: 1)
    }
}
#endif
