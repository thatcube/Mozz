import Foundation
#if canImport(UIKit)
import UIKit
import CoreImage
#endif

/// Derives a muted, dark background colour from artwork bytes for the widgets —
/// the Apple-Music look where the tile takes on a desaturated shade of the cover.
/// Runs in the app process (the widget extension just applies the resulting hex).
enum WidgetTint {
    #if canImport(UIKit)
    /// Shared context — allocating a `CIContext` per call is comparatively costly.
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])
    #endif

    /// Returns "#RRGGBB" of a darkened, slightly-desaturated average of the image,
    /// suitable as a background behind white text. `nil` if it can't be computed.
    static func mutedHex(from data: Data) -> String? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data), let cg = image.cgImage else { return nil }
        let ciImage = CIImage(cgImage: cg)
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0,
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                kCIInputImageKey: ciImage,
                kCIInputExtentKey: CIVector(cgRect: extent),
              ]),
              let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)

        let r = CGFloat(pixel[0]) / 255, g = CGFloat(pixel[1]) / 255, b = CGFloat(pixel[2]) / 255
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)

        // Keep the hue, tame the saturation, and force a dark brightness so white
        // text stays legible regardless of the source cover.
        let muted = UIColor(hue: h, saturation: min(s, 0.55), brightness: 0.30, alpha: 1)
        var mr: CGFloat = 0, mg: CGFloat = 0, mb: CGFloat = 0, ma: CGFloat = 0
        muted.getRed(&mr, green: &mg, blue: &mb, alpha: &ma)
        return String(format: "#%02X%02X%02X", Int(mr * 255), Int(mg * 255), Int(mb * 255))
        #else
        return nil
        #endif
    }
}
