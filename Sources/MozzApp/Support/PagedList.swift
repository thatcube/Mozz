import SwiftUI
import Combine
import MozzDatabase

/// A generic, main-actor paginated list backing store. Loads fixed-size pages
/// on demand (as the user scrolls near the end) so a 100k-track library never
/// materializes in memory — the core of the smooth-scroll / low-memory story.
///
/// Pages are fetched by **cursor**, not offset. `LIMIT/OFFSET` counts the rows it
/// skips, which makes it O(offset) — on a 100,000-track catalog a page costs
/// 10 ms at the top of the list and 197 ms near the bottom — and, worse, makes it
/// wrong whenever the table changes underneath the walk. Mozz syncs in the
/// background *while you browse*, so that is not a hypothetical: inserting 40
/// rows during a paged walk of 100,000 made 40 tracks appear twice and 40 others
/// never appear at all. A cursor names the last row seen instead of counting
/// rows skipped, so rows arriving elsewhere in the order cannot shift it.
@MainActor
final class PagedList<Element>: ObservableObject {
    @Published private(set) var items: [Element] = []
    @Published private(set) var isLoading = false
    @Published private(set) var reachedEnd = false

    typealias Fetch = (_ after: LibraryRepository.PageCursor?, _ limit: Int) async throws
        -> LibraryRepository.Page<Element>

    private let pageSize: Int
    private var fetch: Fetch
    /// Where the next page resumes. `nil` before the first load and again once
    /// the end is reached — `reachedEnd` is what distinguishes the two.
    private var cursor: LibraryRepository.PageCursor?

    init(pageSize: Int = 100, fetch: @escaping Fetch) {
        self.pageSize = pageSize
        self.fetch = fetch
    }

    /// Point the list at a new data source (used to inject the live repository
    /// once the SwiftUI environment is available) and clear any loaded rows.
    func rebind(_ fetch: @escaping Fetch) {
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
            let page = try await fetch(cursor, pageSize)
            items.append(contentsOf: page.rows)
            cursor = page.next
            // The absence of a cursor is the end signal, not a short page: a
            // page can legitimately come back short without being the last.
            if page.next == nil { reachedEnd = true }
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
        cursor = nil
        reachedEnd = false
    }
}
