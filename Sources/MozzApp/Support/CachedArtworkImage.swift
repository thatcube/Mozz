import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

/// A thread-safe in-memory image cache keyed by resolved URL. Backends produce
/// deterministic artwork URLs (stable token, no nonce), so the URL string is a
/// safe cache key across token rotation within a session. `NSCache` is itself
/// thread-safe, so this is safe to read from any isolation context.
final class ArtworkMemoryCache: @unchecked Sendable {
    private let cache = NSCache<NSURL, PlatformImage>()
    init() { cache.countLimit = 512 }
    func image(for url: URL) -> PlatformImage? { cache.object(forKey: url as NSURL) }
    func insert(_ image: PlatformImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}

/// Process-wide cache instance, reachable from both isolated and nonisolated
/// contexts (a plain `Sendable` value, not actor state).
private let artworkMemoryCache = ArtworkMemoryCache()

/// Loads artwork off the main thread and coalesces concurrent requests for the
/// same URL, so many cells asking for the same art trigger a single fetch +
/// decode. Decoding a JPEG on the main thread (as a naive `AsyncImage`
/// replacement would) causes scroll hitching with real server artwork.
actor ArtworkImageLoader {
    static let shared = ArtworkImageLoader()

    private var inFlight: [URL: Task<PlatformImage?, Never>] = [:]

    /// Synchronous cache peek — safe from any thread.
    nonisolated func cached(_ url: URL) -> PlatformImage? {
        artworkMemoryCache.image(for: url)
    }

    /// Fetch + decode off the main thread, coalescing concurrent requests for
    /// the same URL. Returns the decoded image (or nil on failure).
    func image(for url: URL) async -> PlatformImage? {
        if let hit = artworkMemoryCache.image(for: url) { return hit }
        if let existing = inFlight[url] { return await existing.value }

        let task = Task<PlatformImage?, Never>.detached(priority: .utility) {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let decoded = PlatformImage(data: data) else { return nil }
            return decoded
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        if let result { artworkMemoryCache.insert(result, for: url) }
        return result
    }

    /// Warm the cache for a URL ahead of time (fire-and-forget), so a view that
    /// appears later renders the artwork on its first frame instead of popping it
    /// in. Deduped by the same cache check + in-flight coalescing as `image(for:)`.
    nonisolated func prefetch(_ url: URL) {
        if artworkMemoryCache.image(for: url) != nil { return }
        Task.detached(priority: .utility) { _ = await ArtworkImageLoader.shared.image(for: url) }
    }
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
        _image = State(initialValue: ArtworkImageLoader.shared.cached(url))
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
        if let cached = ArtworkImageLoader.shared.cached(url) {
            image = cached
            return
        }
        // Clear any stale image from a previous URL so we never show the wrong
        // artwork while the new one loads.
        image = nil
        // Fetch + decode happen off the main thread inside the loader actor;
        // duplicate requests for the same URL are coalesced.
        let loaded = await ArtworkImageLoader.shared.image(for: url)
        guard !Task.isCancelled else { return }
        image = loaded
    }
}
