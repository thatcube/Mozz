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
