import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

/// A tiny process-wide image cache keyed by resolved URL. Backends produce
/// deterministic artwork URLs (stable token, no nonce), so the URL string is a
/// safe cache key across token rotation within a session.
final class ArtworkImageCache: @unchecked Sendable {
    static let shared = ArtworkImageCache()
    private let cache = NSCache<NSURL, PlatformImage>()

    private init() {
        cache.countLimit = 512
    }

    func image(for url: URL) -> PlatformImage? { cache.object(forKey: url as NSURL) }
    func insert(_ image: PlatformImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}

private extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #elseif canImport(AppKit)
        self.init(nsImage: platformImage)
        #else
        self.init(systemName: "music.note")
        #endif
    }
}

/// Loads and displays remote artwork with an in-memory cache.
///
/// This replaces `AsyncImage`, which has **no cache** and reloads (flashing its
/// placeholder) on every re-render of the view tree. The now-playing bar
/// re-renders constantly (playback progress), so `AsyncImage` there flickered
/// between the real art and the placeholder and the churn could even cancel
/// in-flight tap gestures. Here the decoded image lives in `@State` seeded from
/// the cache in `init`, so:
///
///   * A cached image renders on the very first frame — no flash.
///   * Re-renders with an unchanged URL never reload (`.task(id:)` is inert).
///   * Only a genuine URL change (new track / new size) triggers a fetch.
struct CachedArtworkImage<Placeholder: View>: View {
    private let url: URL
    private let placeholder: Placeholder
    @State private var image: PlatformImage?

    init(url: URL, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder()
        _image = State(initialValue: ArtworkImageCache.shared.image(for: url))
    }

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        if let cached = ArtworkImageCache.shared.image(for: url) {
            image = cached
            return
        }
        // Clear any stale image from a previous URL so we never show the wrong
        // artwork while the new one loads.
        image = nil
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              !Task.isCancelled,
              let decoded = PlatformImage(data: data) else { return }
        ArtworkImageCache.shared.insert(decoded, for: url)
        image = decoded
    }
}
