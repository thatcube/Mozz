import SwiftUI
import Combine

/// A generic, main-actor paginated list backing store. Loads fixed-size pages
/// on demand (as the user scrolls near the end) so a 100k-track library never
/// materializes in memory — the core of the smooth-scroll / low-memory story.
@MainActor
final class PagedList<Element>: ObservableObject {
    @Published private(set) var items: [Element] = []
    @Published private(set) var isLoading = false
    @Published private(set) var reachedEnd = false

    private let pageSize: Int
    private var fetch: (_ offset: Int, _ limit: Int) async throws -> [Element]

    init(pageSize: Int = 100, fetch: @escaping (_ offset: Int, _ limit: Int) async throws -> [Element]) {
        self.pageSize = pageSize
        self.fetch = fetch
    }

    /// Point the list at a new data source (used to inject the live repository
    /// once the SwiftUI environment is available) and clear any loaded rows.
    func rebind(_ fetch: @escaping (_ offset: Int, _ limit: Int) async throws -> [Element]) {
        self.fetch = fetch
        reset()
    }

    func loadInitial() async {
        guard items.isEmpty, !isLoading else { return }
        await loadMore()
    }

    func loadMore() async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await fetch(items.count, pageSize)
            if page.count < pageSize { reachedEnd = true }
            items.append(contentsOf: page)
        } catch {
            reachedEnd = true
        }
    }

    /// Trigger a load when a row near the end appears.
    func loadMoreIfNeeded(currentIndex index: Int) {
        guard index >= items.count - 10 else { return }
        Task { await loadMore() }
    }

    func reset() {
        items = []
        reachedEnd = false
    }
}
