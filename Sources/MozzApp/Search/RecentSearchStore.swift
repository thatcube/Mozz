import Foundation

/// A lightweight reference to something the user opened from search, persisted
/// so the Search screen can show a "Recently Searched" list (like Apple Music).
///
/// Stores only a durable reference (kind + serverId + remoteId), never a
/// snapshot — the row is re-resolved from the catalog at display time so titles
/// and artwork stay fresh and pruned items simply drop out. `serverId` can
/// contain colons (it's `ServerConnection.id`), so the id is composed with a
/// non-colon separator and treated as opaque.
struct RecentSearchItem: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, Hashable {
        case artist, album, track
    }

    var kind: Kind
    var serverId: String
    var remoteId: String

    var id: String { "\(kind.rawValue)\u{1F}\(serverId)\u{1F}\(remoteId)" }
}

/// Persists the user's recent search selections in `UserDefaults` (a small,
/// capped, most-recent-first list). Not a catalog concern, so it lives outside
/// the DB.
@MainActor
final class RecentSearchStore: ObservableObject {
    @Published private(set) var items: [RecentSearchItem] = []

    private let key = "mozz.recentSearches.v1"
    private let limit = 20

    init() { load() }

    /// Records a selection, moving it to the front and de-duplicating.
    func add(_ item: RecentSearchItem) {
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        if items.count > limit { items = Array(items.prefix(limit)) }
        save()
    }

    func clear() {
        items = []
        save()
    }

    /// Forget references filed under a server this install no longer has.
    ///
    /// Most often that is the same library once filed under an id derived from
    /// the address it answered at (ADR-0017): the row can never resolve, and
    /// left in place it occupies one of twenty slots and costs a catalogue read
    /// every time Search comes to rest.
    ///
    /// Deliberately narrower than "drop what did not resolve". Failure and
    /// deletion look identical from the call site — an unreachable server
    /// answers nothing for a row that is perfectly good — and forgetting
    /// someone's history because their server was down for a minute is not a
    /// trade worth making. This mismatch is decidable without the network.
    func forgetServersOtherThan(_ knownServerIDs: Set<String>) {
        guard !knownServerIDs.isEmpty else { return }
        let kept = items.filter { knownServerIDs.contains($0.serverId) }
        guard kept.count != items.count else { return }
        items = kept
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RecentSearchItem].self, from: data)
        else { return }
        items = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
