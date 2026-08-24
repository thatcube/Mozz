import Foundation
import MozzCore
import MozzJellyfin
import MozzSubsonic

/// One selectable music library, plus whether it is currently in use.
public struct MusicLibraryOption: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let isSelected: Bool
}

extension AppEnvironment {

    /// The active server's music libraries, with the current selection marked.
    ///
    /// Empty when the server exposes none, or when there is only one — a picker
    /// offering a single option is noise, and on Subsonic a lone folder is what
    /// every single-library install reports.
    @MainActor
    public func musicLibraries() async -> [MusicLibraryOption] {
        guard let active else { return [] }
        guard let libraries = try? await active.backend.fetchLibraries(),
              libraries.count > 1 else { return [] }
        let selected = SessionPersistence.load(credentials)?.selectedMusicSectionIDs
        return libraries.map { library in
            MusicLibraryOption(
                id: library.id,
                title: library.name,
                // No stored selection means "whatever the server picked", which
                // for Plex is every library and for the others is the first.
                isSelected: selected.map { $0.contains(library.id) }
                    ?? (active.connection.kind == .plex || library.id == libraries.first?.id)
            )
        }
    }

    /// Whether the active backend can sync several libraries at once.
    ///
    /// Only Plex can today. Jellyfin needs each library's pages concatenated
    /// into one offset stream before it can, and the sync's prune guard trusts
    /// the reported grand total — so a half-right implementation can authorize
    /// deleting the catalog. Subsonic's `musicFolderId` is a single value in the
    /// spec (Navidrome accepts repeats, but that is not portable).
    @MainActor
    public var supportsMultipleLibraries: Bool {
        active?.connection.kind == .plex
    }

    /// Apply a library selection and re-sync against it.
    @MainActor
    public func applyLibrarySelection(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        setSelectedMusicLibraries(ids)
    }
}
