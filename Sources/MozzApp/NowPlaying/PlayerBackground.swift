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
        /// How strongly each cell's HUE + SATURATION is pulled toward the
        /// artwork's *vibrant* accent color (not its flat average). 0 = raw
        /// regional colors (harsh bands / center "lane"); 1 = every cell shares
        /// the accent hue. ~0.6 unifies the field around the accent (surfacing a
        /// small vivid area like a bright dress) while keeping per-region
        /// brightness for depth. Blending in HSB — not RGB — avoids muddy
        /// mixes when a region's hue clashes with the accent.
        static let cohesion: CGFloat = 0.62
        static let minBrightness: CGFloat = 0.14
        static let maxBrightness: CGFloat = 0.56
        /// Extra saturation on the final cells so the accent reads as vivid.
        static let saturationBoost: CGFloat = 1.3
        /// Floor the accent's saturation so a mostly-muted cover still shows some
        /// color, without forcing color onto a genuinely grayscale cover.
        static let accentSaturationFloor: CGFloat = 0.35
        /// Resolution the artwork is downsampled to before extraction. Higher =
        /// small vivid regions (accents) survive averaging. Divisible by the
        /// 3×3 grid so regional aggregation is even.
        static let sampleDim = 12
        /// Emphasis on saturation when weighting the vibrant accent. Higher =
        /// a small saturated area outvotes a large flat one more strongly.
        static let vibrancyExponent: CGFloat = 1.7
        /// Mesh point drift amplitude (fraction of the frame). A touch of travel
        /// so the color field drifts around the page (Apple-style) unnoticeably.
        static let driftAmplitude: Float = 0.07
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
    /// ALONG their edge; the center drifts in both axes — so the field breathes
    /// without ever opening a gap.
    private func meshPoints(_ t: TimeInterval) -> [SIMD2<Float>] {
        let a: Float = drift ? ArtworkPalette.Tuning.driftAmplitude : 0
        func s(_ speed: Double, _ phase: Double) -> Float { Float(sin(t * speed + phase)) }
        return [
            SIMD2(0, 0),
            SIMD2(0.5 + a * s(0.23, 0.0), 0),
            SIMD2(1, 0),
            SIMD2(0, 0.5 + a * s(0.19, 1.3)),
            SIMD2(0.5 + a * s(0.21, 2.0), 0.5 + a * s(0.17, 0.5)),
            SIMD2(1, 0.5 + a * s(0.20, 3.1)),
            SIMD2(0, 1),
            SIMD2(0.5 + a * s(0.18, 4.2), 1),
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
    /// Sample the artwork into a `dim × dim` backdrop grid that surfaces the
    /// cover's *vivid accent* color (Apple-Music style) rather than its muddy
    /// average. Steps:
    ///  1. Downsample to a higher-res `sampleDim × sampleDim` buffer so small
    ///     saturated regions (a bright dress, a neon sign) survive.
    ///  2. Compute a vibrancy-weighted dominant color — pixels count in
    ///     proportion to `saturation^exp × brightness`, so a small vivid area
    ///     outvotes a large flat one.
    ///  3. For each of the `dim × dim` regions, take the regional average but
    ///     pull its HUE + SATURATION toward that accent (cohesion), keeping the
    ///     region's own brightness for vertical depth. Blending in HSB avoids
    ///     the gray "mud" that RGB-averaging complementary hues produces, and
    ///     unifying hue removes the old center "lane".
    func mozzColorGrid(dim: Int) -> [Color]? {
        guard let cg = cgImage else { return nil }
        let sampleDim = max(dim, ArtworkPalette.Tuning.sampleDim)
        let sCount = sampleDim * sampleDim
        var px = [UInt8](repeating: 0, count: sCount * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &px, width: sampleDim, height: sampleDim, bitsPerComponent: 8,
            bytesPerRow: sampleDim * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: sampleDim, height: sampleDim))

        @inline(__always) func rgb(_ i: Int) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat(px[i * 4]) / 255, CGFloat(px[i * 4 + 1]) / 255, CGFloat(px[i * 4 + 2]) / 255)
        }

        // Vibrancy-weighted accent: saturated pixels dominate, so a small vivid
        // region drives the field's hue instead of being averaged away.
        var vr: CGFloat = 0, vg: CGFloat = 0, vb: CGFloat = 0, vw: CGFloat = 0
        let exp = ArtworkPalette.Tuning.vibrancyExponent
        for i in 0..<sCount {
            let (r, g, b) = rgb(i)
            let maxC = max(r, max(g, b)), minC = min(r, min(g, b))
            let sat = maxC <= 0 ? 0 : (maxC - minC) / maxC
            let w = pow(sat, exp) * maxC + 0.0002   // epsilon keeps grayscale art safe
            vr += r * w; vg += g * w; vb += b * w; vw += w
        }
        let accent = UIColor(red: vr / vw, green: vg / vw, blue: vb / vw, alpha: 1)
        var accentH: CGFloat = 0, accentS: CGFloat = 0, accentB: CGFloat = 0, accentA: CGFloat = 0
        accent.getHue(&accentH, saturation: &accentS, brightness: &accentB, alpha: &accentA)
        // Only floor saturation if the accent already has real color, so a truly
        // grayscale cover stays grayscale.
        if accentS > 0.08 { accentS = max(accentS, ArtworkPalette.Tuning.accentSaturationFloor) }

        // Regional cells, each pulled toward the accent in HSB space.
        let k = ArtworkPalette.Tuning.cohesion
        var out: [Color] = []
        out.reserveCapacity(dim * dim)
        for gr in 0..<dim {
            let y0 = gr * sampleDim / dim, y1 = (gr + 1) * sampleDim / dim
            for gc in 0..<dim {
                let x0 = gc * sampleDim / dim, x1 = (gc + 1) * sampleDim / dim
                var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, cnt: CGFloat = 0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let (r, g, b) = rgb(y * sampleDim + x)
                        ar += r; ag += g; ab += b; cnt += 1
                    }
                }
                let cell = UIColor(red: ar / cnt, green: ag / cnt, blue: ab / cnt, alpha: 1)
                out.append(Color(cell.mozzBackdropBlended(towardHue: accentH,
                                                           saturation: accentS,
                                                           cohesion: k)))
            }
        }
        return out
    }
}

extension UIColor {
    /// Blend this regional color toward the accent's hue + saturation (in HSB,
    /// via the shortest angular path so hues never pass through gray), keep the
    /// region's own brightness for depth, boost saturation for vividness, and
    /// clamp brightness so overlaid white text stays legible.
    func mozzBackdropBlended(towardHue targetH: CGFloat, saturation targetS: CGFloat,
                             cohesion k: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }

        // Shortest-path hue rotation toward the accent.
        var dh = targetH - h
        if dh > 0.5 { dh -= 1 } else if dh < -0.5 { dh += 1 }
        var nh = (h + dh * k).truncatingRemainder(dividingBy: 1)
        if nh < 0 { nh += 1 }

        let blendedS = s + (targetS - s) * k
        let ns = min(blendedS * ArtworkPalette.Tuning.saturationBoost, 1)
        let nb = min(max(b, ArtworkPalette.Tuning.minBrightness), ArtworkPalette.Tuning.maxBrightness)
        return UIColor(hue: nh, saturation: ns, brightness: nb, alpha: 1)
    }
}
#endif
