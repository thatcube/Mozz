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
        /// How strongly each cell is pulled toward the artwork's overall color.
        /// 0 = raw regional colors (harsh bands / center "lane"); 1 = a single
        /// flat color. ~0.5 keeps hue variety but dissolves regional seams for a
        /// broad, Apple-Music-like field.
        static let cohesion: CGFloat = 0.5
        static let minBrightness: CGFloat = 0.14
        static let maxBrightness: CGFloat = 0.52
        static let saturationBoost: CGFloat = 1.12
        /// Mesh point drift amplitude (fraction of the frame).
        static let driftAmplitude: Float = 0.05
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
    /// Downsample the image to `dim × dim` pixels, pull each cell toward the
    /// overall average (cohesion) so there are no harsh regional seams / center
    /// "lane", then adjust into rich-but-legible backdrop tones.
    func mozzColorGrid(dim: Int) -> [Color]? {
        guard let cg = cgImage else { return nil }
        let count = dim * dim
        var px = [UInt8](repeating: 0, count: count * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &px, width: dim, height: dim, bitsPerComponent: 8,
            bytesPerRow: dim * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: dim, height: dim))

        // Raw cell RGB + running mean.
        var rs = [CGFloat](repeating: 0, count: count)
        var gs = [CGFloat](repeating: 0, count: count)
        var bs = [CGFloat](repeating: 0, count: count)
        var mr: CGFloat = 0, mg: CGFloat = 0, mb: CGFloat = 0
        for i in 0..<count {
            let r = CGFloat(px[i * 4]) / 255
            let g = CGFloat(px[i * 4 + 1]) / 255
            let b = CGFloat(px[i * 4 + 2]) / 255
            rs[i] = r; gs[i] = g; bs[i] = b
            mr += r; mg += g; mb += b
        }
        let n = CGFloat(count)
        mr /= n; mg /= n; mb /= n

        // Blend each cell toward the mean (cohesion), then adjust for legibility.
        let k = ArtworkPalette.Tuning.cohesion
        var out: [Color] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let r = rs[i] + (mr - rs[i]) * k
            let g = gs[i] + (mg - gs[i]) * k
            let b = bs[i] + (mb - bs[i]) * k
            out.append(Color(UIColor(red: r, green: g, blue: b, alpha: 1).mozzBackdropAdjusted()))
        }
        return out
    }
}

extension UIColor {
    /// Adjust a sampled color into a backdrop tone: keep vivid mids vivid, darken
    /// light covers so white text stays legible, lift pure blacks slightly, and
    /// nudge saturation up for richness.
    func mozzBackdropAdjusted() -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        let nb = min(max(b, ArtworkPalette.Tuning.minBrightness), ArtworkPalette.Tuning.maxBrightness)
        let ns = min(s * ArtworkPalette.Tuning.saturationBoost, 1)
        return UIColor(hue: h, saturation: ns, brightness: nb, alpha: 1)
    }
}
#endif
