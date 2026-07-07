import SwiftUI
import MozzCore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Style

/// How the now-playing player paints its background. Persisted via `@AppStorage`
/// ("playerBackgroundStyle") so a future Settings picker can switch it with no
/// other changes. `adaptive` is the default — a lush mesh gradient sampled from
/// the artwork (Apple-Music style).
enum PlayerBackgroundStyle: String, CaseIterable, Sendable {
    /// Mesh gradient sampled from the current artwork's colors.
    case adaptive
    /// Pure black (AMOLED / OLED battery + aesthetic).
    case oled
    /// Follow the app's light/dark theme (a neutral system background).
    case theme

    var storageValue: String { rawValue }
    static let storageKey = "playerBackgroundStyle"
    static let `default`: PlayerBackgroundStyle = .adaptive
}

// MARK: - Sampled color grid

/// A `dim × dim` grid of colors sampled from the current artwork, used to build
/// the mesh-gradient backdrop. Nine colors (3×3) blend into a smooth, artwork-
/// accurate field. Colors are pre-adjusted for depth + legibility.
struct ArtworkColorGrid: Equatable {
    static let dim = 3
    var colors: [Color]           // count == dim*dim, row-major (top→bottom)

    var isValid: Bool { colors.count == Self.dim * Self.dim }
}

enum ArtworkPalette {
    /// How the sampled grid is shaped into a backdrop.
    enum Tuning {
        // --- Extraction (prominence + vibrancy, à la Plozz) ---
        /// Resolution the artwork is drawn to before histogramming. 48×48 ≈ 2.3k
        /// pixels — plenty to characterise a cover, cheap to run off-main.
        static let sampleDim = 48
        /// Most prominent colors to pull out; padded up to the 9 mesh slots.
        static let maxColors = 5
        /// Minimum RGB distance between chosen colors, so the palette spans the
        /// art (blue AND red) instead of five shades of one hue.
        static let minSeparation: Double = 0.22
        /// Vibrancy reward: score multiplier = base + saturation × gain. Higher
        /// gain = saturated colors dominate flat/greys more.
        static let vibrancyBase: Double = 0.35
        static let vibrancyGain: Double = 1.4
        /// Coverage weight is `count^exp` (sublinear) so a big flat area can't
        /// completely bury a smaller vivid one.
        static let coverageExponent: Double = 0.65
        /// How hard pure black / pure white are pushed down (their hue barely
        /// registers). Higher = stronger rejection of the luminance extremes.
        static let luminanceFalloff: Double = 1.5
        static let luminanceFloor: Double = 0.18

        // --- Backdrop tone (legibility over vividness) ---
        /// Light saturation lift on the final colors.
        static let saturationBoost: CGFloat = 1.1
        static let minBrightness: CGFloat = 0.14
        /// Cap brightness so white title/artist text stays legible over the mid
        /// of the screen (Mozz overlays text directly, unlike a TV).
        static let maxBrightness: CGFloat = 0.58

        // --- Motion ---
        /// Mesh point drift amplitude (fraction of the frame). Large enough to be
        /// visibly alive (Apple-Music "paint in water") without folding the mesh.
        static let driftAmplitude: Float = 0.16
        /// The center point roams a little further than the edges.
        static let driftCenterBoost: Float = 1.4
    }

    /// Sample the artwork into a color grid, or derive a pleasant deterministic
    /// grid from `seed` when there's no artwork (offline demo / art-less server).
    static func grid(for artwork: ArtworkRef?, backend: (any MusicBackend)?, seed: String) async -> ArtworkColorGrid {
        #if canImport(UIKit)
        if let artwork, let backend,
           let url = backend.artworkURL(for: artwork, size: 240),
           let image = await ArtworkImageLoader.shared.image(for: url),
           let colors = image.mozzColorGrid(dim: ArtworkColorGrid.dim) {
            return ArtworkColorGrid(colors: colors)
        }
        #endif
        return seedGrid(seed)
    }

    /// The grid IF the artwork is already decoded in-memory, so a preloaded cover
    /// resolves colors on the first frame (no fade-in). Nil ⇒ caller awaits.
    static func cachedGrid(for artwork: ArtworkRef?, backend: (any MusicBackend)?, seed: String) -> ArtworkColorGrid? {
        #if canImport(UIKit)
        if let artwork, let backend,
           let url = backend.artworkURL(for: artwork, size: 240),
           let image = ArtworkImageLoader.shared.cached(url),
           let colors = image.mozzColorGrid(dim: ArtworkColorGrid.dim) {
            return ArtworkColorGrid(colors: colors)
        }
        #endif
        return nil
    }

    /// Deterministic grid from a seed hue (mirrors `ArtworkView`'s placeholder),
    /// varied across the grid so the art-less fallback still looks intentional.
    static func seedGrid(_ seed: String) -> ArtworkColorGrid {
        let hue = Double(abs(seed.hashValue) % 360) / 360.0
        var colors: [Color] = []
        for row in 0..<ArtworkColorGrid.dim {
            for col in 0..<ArtworkColorGrid.dim {
                let h = (hue + Double(col) * 0.03).truncatingRemainder(dividingBy: 1)
                let b = 0.42 - Double(row) * 0.10
                colors.append(Color(hue: h, saturation: 0.5, brightness: max(0.16, b)))
            }
        }
        return ArtworkColorGrid(colors: colors)
    }
}

// MARK: - Backdrop view

/// The player's background. `adaptive` draws a mesh gradient from the sampled
/// grid (with a gentle drift + legibility scrim); `oled` is pure black; `theme`
/// follows the system background. Self-contained so its per-frame drift redraws
/// this view only, not the morph container.
struct PlayerBackdrop: View {
    let style: PlayerBackgroundStyle
    let grid: ArtworkColorGrid?
    /// Only drift while the drawer is open (saves power when collapsed).
    var animated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch style {
        case .oled:
            Color.black
        case .theme:
            Color.mozzBackground
        case .adaptive:
            adaptive
        }
    }

    private var drift: Bool { animated && !reduceMotion }

    @ViewBuilder private var adaptive: some View {
        let colors = (grid?.isValid == true ? grid!.colors : ArtworkPalette.seedGrid("mozz").colors)
        ZStack {
            // Base fill (also the <iOS18 fallback): the darkest sampled color, so
            // there's never a gap behind the mesh.
            (colors.min(by: { $0.mozzLuminance < $1.mozzLuminance }) ?? .black)
                .ignoresSafeArea()

            if #available(iOS 18.0, *), colors.count == 9 {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !drift)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    MeshGradient(width: 3, height: 3, points: meshPoints(t), colors: colors)
                }
            } else {
                LinearGradient(colors: [colors.first ?? .black, colors.last ?? .black],
                               startPoint: .top, endPoint: .bottom)
            }

            // Legibility scrim: gently darken the very top (status bar / titles)
            // and the bottom (transport + tab controls) without crushing the mid.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.30), location: 0.0),
                    .init(color: .clear, location: 0.18),
                    .init(color: .clear, location: 0.62),
                    .init(color: .black.opacity(0.38), location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom)
        }
    }

    /// 3×3 mesh points. Corners are pinned to the frame; edge-midpoints drift only
    /// ALONG their edge; the center drifts in both axes (a little further) — so the
    /// field churns like paint in water without ever opening a gap.
    private func meshPoints(_ t: TimeInterval) -> [SIMD2<Float>] {
        let a: Float = drift ? ArtworkPalette.Tuning.driftAmplitude : 0
        let c = a * ArtworkPalette.Tuning.driftCenterBoost
        func s(_ speed: Double, _ phase: Double) -> Float { Float(sin(t * speed + phase)) }
        return [
            SIMD2(0, 0),
            SIMD2(0.5 + a * s(0.13, 0.0), 0),
            SIMD2(1, 0),
            SIMD2(0, 0.5 + a * s(0.11, 1.3)),
            SIMD2(0.5 + c * s(0.15, 2.0), 0.5 + c * s(0.09, 0.5)),
            SIMD2(1, 0.5 + a * s(0.12, 3.1)),
            SIMD2(0, 1),
            SIMD2(0.5 + a * s(0.10, 4.2), 1),
            SIMD2(1, 1),
        ]
    }
}

// MARK: - Sampling helpers

extension Color {
    /// Rough perceived luminance for picking the darkest sampled color.
    var mozzLuminance: Double {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return Double(0.299 * r + 0.587 * g + 0.114 * b)
        #else
        return 0
        #endif
    }
}

#if canImport(UIKit)
extension UIImage {
    /// Extract the artwork's most *prominent, vibrant, distinct* colors and lay
    /// them out as a 9-slot mesh (Apple-Music / Plozz style) — NOT a spatial map.
    /// The image is histogrammed; buckets are scored by coverage × vibrancy ×
    /// mid-luminance (so muddy greys and the black/white extremes lose), then a
    /// greedy diverse pick spans the cover instead of clustering on one hue. The
    /// most prominent color anchors the mesh center with the rest spread around.
    func mozzColorGrid(dim: Int) -> [Color]? {
        let palette = mozzProminentColors(maxColors: ArtworkPalette.Tuning.maxColors)
        guard !palette.isEmpty else { return nil }

        // Pad to 5 by cycling so the mesh always has variety to morph between.
        var c = palette
        var i = 0
        while c.count < 5 { c.append(palette[i % palette.count]); i += 1 }

        // Prominent color [0] in the center; others spread to the ring.
        let arranged = [c[1], c[2], c[3],
                        c[4], c[0], c[1],
                        c[2], c[3], c[4]]
        return arranged.map { Color($0.mozzBackdropAdjusted()) }
    }

    /// Histogram-based prominent-color extraction (see `mozzColorGrid`). Returns
    /// up to `maxColors` UIColors, most prominent first, or empty if unreadable.
    func mozzProminentColors(maxColors: Int) -> [UIColor] {
        guard maxColors > 0, let cg = cgImage else { return [] }
        let dim = ArtworkPalette.Tuning.sampleDim
        let bytesPerRow = dim * 4
        var px = [UInt8](repeating: 0, count: dim * bytesPerRow)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &px, width: dim, height: dim, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: dim, height: dim))

        struct Bucket { var count = 0; var r = 0.0; var g = 0.0; var b = 0.0 }
        var buckets: [Int: Bucket] = [:]
        buckets.reserveCapacity(512)

        var idx = 0
        let total = px.count
        while idx < total {
            if px[idx + 3] > 24 {   // skip transparent
                let r = px[idx], g = px[idx + 1], b = px[idx + 2]
                // Quantize to 5 bits/channel (32 levels) so similar colors merge.
                let key = (Int(r) >> 3) << 10 | (Int(g) >> 3) << 5 | (Int(b) >> 3)
                var bk = buckets[key] ?? Bucket()
                bk.count += 1
                bk.r += Double(r) / 255; bk.g += Double(g) / 255; bk.b += Double(b) / 255
                buckets[key] = bk
            }
            idx += 4
        }
        guard !buckets.isEmpty else { return [] }

        // Score each averaged bucket by coverage × vibrancy × mid-luminance.
        typealias RGB = (r: Double, g: Double, b: Double)
        let scored: [(color: RGB, score: Double)] = buckets.values.map { bk in
            let n = Double(bk.count)
            let color: RGB = (bk.r / n, bk.g / n, bk.b / n)
            let maxC = max(color.r, color.g, color.b), minC = min(color.r, color.g, color.b)
            let sat = maxC <= 0 ? 0 : (maxC - minC) / maxC
            let lum = 0.299 * color.r + 0.587 * color.g + 0.114 * color.b
            let lumWeight = 1.0 - pow(abs(lum - 0.5) * 2.0, ArtworkPalette.Tuning.luminanceFalloff)
            let vibrancy = ArtworkPalette.Tuning.vibrancyBase + sat * ArtworkPalette.Tuning.vibrancyGain
            let coverage = pow(n, ArtworkPalette.Tuning.coverageExponent)
            return (color, coverage * vibrancy * max(lumWeight, ArtworkPalette.Tuning.luminanceFloor))
        }
        .sorted { $0.score > $1.score }

        // Greedily accept colors far enough apart to span the artwork.
        func dist(_ a: RGB, _ b: RGB) -> Double {
            let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
            return (dr * dr + dg * dg + db * db).squareRoot()
        }
        var chosen: [RGB] = []
        let minSep = ArtworkPalette.Tuning.minSeparation
        for cand in scored where chosen.allSatisfy({ dist($0, cand.color) >= minSep }) {
            chosen.append(cand.color)
            if chosen.count >= maxColors { break }
        }
        if chosen.isEmpty { chosen = scored.prefix(maxColors).map(\.color) }

        return chosen.map { UIColor(red: $0.r, green: $0.g, blue: $0.b, alpha: 1) }
    }
}

extension UIColor {
    /// Turn a prominent color into a backdrop tone: keep its hue, lift saturation
    /// slightly for richness, and clamp brightness so it's neither crushed to
    /// black nor bright enough to fight the overlaid white text.
    func mozzBackdropAdjusted() -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        let ns = min(s * ArtworkPalette.Tuning.saturationBoost, 1)
        let nb = min(max(b, ArtworkPalette.Tuning.minBrightness), ArtworkPalette.Tuning.maxBrightness)
        return UIColor(hue: h, saturation: ns, brightness: nb, alpha: 1)
    }
}
#endif
