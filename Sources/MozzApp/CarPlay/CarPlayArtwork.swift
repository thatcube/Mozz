#if os(iOS)
import CarPlay
import MozzCore
import UIKit

/// Loads artwork for CarPlay rows.
///
/// CarPlay list rows take a concrete `UIImage`, not a SwiftUI view, so the app's
/// `ArtworkView` is no use here — but the underlying loader and its cache are, so
/// a cover already fetched for the phone is reused rather than downloaded again.
///
/// Rows are handed to CarPlay before their artwork exists. `CPListItem.setImage`
/// updates a row that is already on screen, so each row is filled in as its image
/// arrives; anything still in flight when the user leaves is cancelled with the
/// template.
@MainActor
enum CarPlayArtwork {
    /// The size CarPlay wants, in pixels, for the current head unit.
    ///
    /// Taken from `CPListItem.maximumImageSize` and the car's own display scale
    /// rather than a guess: screens vary a lot between head units, and asking the
    /// server for the right size keeps both the download and the decode small.
    static func pixelSize(for traits: UITraitCollection?) -> Int {
        let points = CPListItem.maximumImageSize
        let scale = traits.map { $0.displayScale > 0 ? $0.displayScale : 2 } ?? 2
        let longest = max(points.width, points.height) * scale
        // Guard against a head unit reporting something daft.
        return Int(max(64, min(512, longest.rounded())))
    }

    /// An SF Symbol at the size every row icon shares.
    ///
    /// Size comes from a symbol configuration rather than scaling the glyph to
    /// fill the image box. Symbols have very different proportions — a heart is
    /// nearly square, a music note tall and narrow — so filling the box makes
    /// them wildly inconsistent, the heart looking enormous beside the note.
    /// Configuring by point size is what SF Symbols is built for, and makes them
    /// read as one set.
    private static func glyph(_ name: String) -> UIImage? {
        let side = min(CPListItem.maximumImageSize.width, CPListItem.maximumImageSize.height)
        let configuration = UIImage.SymbolConfiguration(pointSize: side * 0.55, weight: .regular)
        return UIImage(systemName: name, withConfiguration: configuration)
    }

    /// A tab bar icon, left for CarPlay to colour.
    ///
    /// `.alwaysTemplate` matters: `UIImage(systemName:)` returns `.automatic`,
    /// and the car's screen is drawn out of process, so an automatic image
    /// crosses that boundary already flattened in whatever colour it resolved
    /// against — black, on a screen whose chrome is nearly black. A template
    /// image goes over as a mask the car tints itself, which is what makes the
    /// selected tab pick up its accent and the others stay grey. Tabs are the one
    /// place that tinting tracks selection; rows are not (see `rowSymbol`).
    static func tabSymbol(_ name: String) -> UIImage? {
        glyph(name)?.withRenderingMode(.alwaysTemplate)
    }

    /// A row icon: a filled glyph with a halo of the opposite tone behind it.
    ///
    /// The plain version of this is one flat colour, and that cannot be made to
    /// work. CarPlay tints a template mask one colour for the whole list, but a
    /// highlighted row flips to a near-white background, and the list is
    /// translucent so the resting rows sit lighter than they look — measured off
    /// a car screen, backgrounds run from luminance 0.063 to 0.581. The best any
    /// single colour manages against both ends of that is
    /// `√(0.631 × 0.113) − 0.05`, about 2.36:1, under the floor for something
    /// read at a glance while driving. White is excellent at rest and invisible
    /// when highlighted, at 1.05:1; Mozz's red splits the difference and is
    /// mediocre everywhere, 1.87:1 at rest. Neither is worth shipping.
    ///
    /// Nothing in the framework offers a way out, either. `CPListItem` has no
    /// focus-time image — `CPMapButton` has `focusedImage`, so the absence is a
    /// decision rather than an oversight — and its header offers exactly one axis
    /// of variation, "two `UIImageAssets`, corresponding to night and day mode",
    /// which the car resolves once for the whole screen. Nor can the app decide
    /// the highlight doesn't matter: how long a row stays highlighted depends on
    /// whether the head unit is a touchscreen or a rotary controller, and
    /// `CPLimitableUserInterface` covers keyboards and list lengths and nothing
    /// that would say which is plugged in.
    ///
    /// So the contrast has to come from the icon itself rather than from its
    /// colour. A halo of the opposite tone gives every edge something to sit
    /// against: at rest the icon reads as plain white, matching the row's text
    /// and the car's own icons, and the halo does nothing visible; on the
    /// highlighted row the white fill washes out and the halo is what draws the
    /// shape. Day and night variants are registered as the header asks, so a car
    /// in light mode gets the inverse pair.
    ///
    /// The halo is tuned to the floor rather than eyeballed, because the two ways
    /// of getting it wrong pull in opposite directions: concentrated, it reads as
    /// a hard outline drawn around the glyph, and spread too dark it reads as a
    /// smudge. Width turns out not to be the problem — a wide radius at half the
    /// opacity falls off gently and still clears 3.4:1 on a highlighted row, and
    /// 3.9:1 against pure white, the worst a head unit could ask for. Darkness
    /// was: the first attempt here sat at 7.37:1, twice what it needed, and
    /// looked it. Widening past this starts to cost contrast, as the same ink
    /// spreads over more pixels — around a third of the box the glyph sits in,
    /// it drops under the floor and there is nothing left to trade.
    static func rowSymbol(_ name: String, traits: UITraitCollection?) -> UIImage? {
        guard let glyph = glyph(name) else { return nil }
        let side = min(CPListItem.maximumImageSize.width, CPListItem.maximumImageSize.height)
        let size = CGSize(width: side, height: side)
        let scale = traits.map { $0.displayScale > 0 ? $0.displayScale : 2 } ?? 2

        func rendered(fill: UIColor, halo: UIColor) -> UIImage {
            let format = UIGraphicsImageRendererFormat.preferred()
            format.opaque = false
            format.scale = scale
            let tinted = glyph.withTintColor(fill, renderingMode: .alwaysOriginal)
            // Centre at natural size rather than stretching to the box.
            let rect = CGRect(
                x: (size.width - tinted.size.width) / 2,
                y: (size.height - tinted.size.height) / 2,
                width: tinted.size.width, height: tinted.size.height
            )
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                context.cgContext.setShadow(offset: .zero, blur: side * 0.2, color: halo.cgColor)
                // Two passes, not one: a single pass at this opacity fades out
                // before it reaches the contrast a highlighted row needs, and
                // raising the opacity to compensate is what made it a smudge.
                for _ in 0..<2 { tinted.draw(in: rect) }
                context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
                tinted.draw(in: rect)
            }.withRenderingMode(.alwaysOriginal)
        }

        let asset = UIImageAsset()
        asset.register(
            rendered(fill: .black, halo: UIColor.white.withAlphaComponent(0.65)),
            with: UITraitCollection(userInterfaceStyle: .light)
        )
        asset.register(
            rendered(fill: .white, halo: UIColor.black.withAlphaComponent(0.65)),
            with: UITraitCollection(userInterfaceStyle: .dark)
        )
        return asset.image(with: traits ?? UITraitCollection(userInterfaceStyle: .dark))
    }

    /// Fetch the image for an artwork reference, or `nil` when there is none.
    static func image(
        for artworkKey: String?,
        backend: (any MusicBackend)?,
        pixelSize: Int
    ) async -> UIImage? {
        guard let artworkKey, !artworkKey.isEmpty, let backend else { return nil }
        guard let url = backend.artworkURL(for: ArtworkRef(key: artworkKey), size: pixelSize) else {
            return nil
        }
        if let cached = ArtworkImageLoader.shared.cached(url) { return cached }
        return await ArtworkImageLoader.shared.image(for: url)
    }

    /// Fill in each row's artwork as it loads.
    ///
    /// Bounded concurrency, so opening a long album list doesn't fire hundreds of
    /// simultaneous requests at a server the car is also streaming through.
    /// Cancellation is co-operative: the caller holds the task and drops it when
    /// the template goes away.
    static func fill(
        rows: [(item: CPListItem, artworkKey: String?)],
        backend: (any MusicBackend)?,
        pixelSize: Int,
        concurrency: Int = 4
    ) async {
        guard backend != nil, !rows.isEmpty else { return }
        var next = 0
        await withTaskGroup(of: Void.self) { group in
            func schedule() {
                guard next < rows.count else { return }
                let row = rows[next]
                next += 1
                group.addTask { @MainActor in
                    guard !Task.isCancelled else { return }
                    let image = await image(
                        for: row.artworkKey, backend: backend, pixelSize: pixelSize
                    )
                    guard !Task.isCancelled, let image else { return }
                    row.item.setImage(image)
                }
            }
            for _ in 0..<min(concurrency, rows.count) { schedule() }
            while await group.next() != nil {
                if Task.isCancelled {
                    group.cancelAll()
                    return
                }
                schedule()
            }
        }
    }
}
#endif
