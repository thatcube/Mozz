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
        /// Resolution the artwork is downsampled to before extraction. Higher =
        /// small vivid regions survive averaging. Divisible by the 3×3 grid so
        /// regional aggregation is even.
        static let sampleDim = 12
        /// Edge-preserving smoothing: how strongly each cell blends with a
        /// SIMILAR neighbor. This dissolves soft banding / the center "lane"
        /// between near-identical regions, while leaving genuine color
        /// boundaries (blue sky vs gold sun) crisp — so we never average
        /// clashing hues into mud (the old blue+red→purple / blue+gold→green
        /// bug). 0 = raw regions; ~0.5 = smooth but faithful.
        static let smoothing: CGFloat = 0.5
        /// Color distance (0…~1.7 in RGB) beyond which two neighbors are treated
        /// as a real edge and NOT blended. Small = preserve more edges.
        static let smoothingEdge: CGFloat = 0.42
        /// Extra saturation on the final cells so real colors read vividly.
        static let saturationBoost: CGFloat = 1.28
        static let minBrightness: CGFloat = 0.12
        static let maxBrightness: CGFloat = 0.55
        /// Below this ORIGINAL brightness a region is treated as near-black and
        /// its saturation is damped toward neutral — so a black cover stays
        /// black (not brown) instead of amplifying tiny channel noise into color.
        static let neutralDarkFloor: CGFloat = 0.10
        static let neutralDarkRamp: CGFloat = 0.14
        /// Mesh point drift amplitude (fraction of the frame). A touch of travel
        /// so the color field drifts around the page (Apple-style) unnoticeably.
        static let driftAmplitude: Float = 0.06
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
    /// Sample the artwork into a `dim × dim` backdrop grid that FAITHFULLY keeps
    /// the cover's real colors and their spatial spread (Apple-Music style),
    /// instead of collapsing everything to one accent or a muddy average. Steps:
    ///  1. Downsample to a higher-res `sampleDim` buffer, then average into the
    ///     `dim × dim` regions — so each cell is the true color of that part of
    ///     the art (top→bottom colour travel is preserved).
    ///  2. Edge-preserving smoothing: blend each cell only with neighbours it's
    ///     already SIMILAR to. This softens banding / the center "lane" between
    ///     near-identical regions, but leaves real colour edges (blue vs gold)
    ///     crisp — so clashing hues are never averaged into green/purple mud.
    ///  3. Per-cell adjust for depth + legibility (see `mozzBackdropAdjusted`).
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

        // 1. Regional averages — the true color of each part of the artwork.
        typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)
        var cells = [RGB](repeating: (0, 0, 0), count: dim * dim)
        for gr in 0..<dim {
            let y0 = gr * sampleDim / dim, y1 = (gr + 1) * sampleDim / dim
            for gc in 0..<dim {
                let x0 = gc * sampleDim / dim, x1 = (gc + 1) * sampleDim / dim
                var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, cnt: CGFloat = 0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let i = (y * sampleDim + x) * 4
                        ar += CGFloat(px[i]) / 255
                        ag += CGFloat(px[i + 1]) / 255
                        ab += CGFloat(px[i + 2]) / 255
                        cnt += 1
                    }
                }
                cells[gr * dim + gc] = (ar / cnt, ag / cnt, ab / cnt)
            }
        }

        // 2. Edge-preserving smoothing (one pass): blend with SIMILAR neighbours
        //    only, so soft bands/lanes dissolve but real colour edges survive.
        let base = ArtworkPalette.Tuning.smoothing
        let edge = ArtworkPalette.Tuning.smoothingEdge
        let src = cells
        for gr in 0..<dim {
            for gc in 0..<dim {
                let c = src[gr * dim + gc]
                var ar = c.r, ag = c.g, ab = c.b, wsum: CGFloat = 1
                for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nr = gr + dr, nc = gc + dc
                    guard nr >= 0, nr < dim, nc >= 0, nc < dim else { continue }
                    let n = src[nr * dim + nc]
                    let dist = abs(c.r - n.r) + abs(c.g - n.g) + abs(c.b - n.b)
                    let sim = max(0, 1 - dist / (edge * 3))   // 1 identical → 0 at edge
                    let w = base * sim
                    ar += n.r * w; ag += n.g * w; ab += n.b * w; wsum += w
                }
                cells[gr * dim + gc] = (ar / wsum, ag / wsum, ab / wsum)
            }
        }

        // 3. Adjust each cell into a rich-but-legible backdrop tone.
        return cells.map { Color(UIColor(red: $0.r, green: $0.g, blue: $0.b, alpha: 1).mozzBackdropAdjusted()) }
    }
}

extension UIColor {
    /// Turn a faithful regional color into a backdrop tone: keep its real hue,
    /// clamp brightness so overlaid white text stays legible, boost saturation
    /// for richness — but DAMP saturation on near-black regions so a dark cover
    /// stays a dark neutral (not an amplified brown/green from channel noise).
    func mozzBackdropAdjusted() -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }

        let floor = ArtworkPalette.Tuning.neutralDarkFloor
        let ramp = ArtworkPalette.Tuning.neutralDarkRamp
        let neutralScale = min(max((b - floor) / ramp, 0), 1)   // 0 near-black → keep neutral

        let ns = min(s * neutralScale * ArtworkPalette.Tuning.saturationBoost, 1)
        let nb = min(max(b, ArtworkPalette.Tuning.minBrightness), ArtworkPalette.Tuning.maxBrightness)
        return UIColor(hue: h, saturation: ns, brightness: nb, alpha: 1)
    }
}
#endif
