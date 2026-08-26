import Foundation
import MozzCore
import MozzDatabase

/// The one surface every shell reaches the core through.
///
/// This exists to remove an asymmetry, not to add a layer. Today the iOS shell
/// calls the core's modules directly while every other shell goes through
/// hand-written JSON commands, so a capability can be added, used on the phone,
/// and be invisible everywhere else because nobody widened the facade. Four of
/// seven parity defects in one recent week were exactly that.
///
/// With one protocol there is nowhere else to go. Swift shells call it in
/// process — no serialisation, no C, Swift calling Swift. Everything else goes
/// through `CommandDispatcher`, which speaks the same protocol over the wire
/// format in `schema/`. Neither path can reach a capability the other cannot,
/// because there is only the one set of methods.
///
/// The compile-time chain that keeps it honest runs backwards from the schema:
/// adding a command to `library.proto` adds a case to the generated `oneof`,
/// which breaks `CommandDispatcher`'s exhaustive switch, which forces a method
/// here, which forces the core to implement it. A capability with no command
/// stops the build rather than quietly shipping on one platform.
///
/// Note the deliberate coupling: the return types are the database's record
/// types rather than a third parallel set of models. Introducing one would mean
/// hand-writing and maintaining a mapping in both directions for no behaviour
/// change. If the record types later need to stop being the wire vocabulary,
/// that is a change to make on purpose rather than a layer to add in advance.
public protocol CommandService: Sendable {

    /// Every server the user has attached.
    func libraries() async throws -> [ServerConnection]

    /// One page of albums, in the library's own sort order.
    ///
    /// `after` is the cursor from the previous page, or `nil` to start. It is
    /// opaque: callers hand back what they were given and never construct one.
    func albums(
        serverId: ServerID,
        after: LibraryRepository.PageCursor?,
        limit: Int
    ) async throws -> LibraryRepository.Page<AlbumRecord>

    /// One artist, or `nil` when the server has no such artist.
    ///
    /// Both arguments are required, which the schema now enforces at every call
    /// site. The hand-written facade checked at runtime and answered with a
    /// string — `guard let remoteId = request.remoteId, let serverId else …` —
    /// so a caller that forgot one learned about it from a failed response.
    func artist(serverId: ServerID, remoteId: String) async throws -> ArtistRecord?
}

/// The core's implementation, over the source-of-truth database.
///
/// Thin on purpose. Anything that looks like a decision — a default page size, a
/// sort order, a fallback — belongs below this, in the repository, so that a
/// shell cannot get a different answer by asking differently.
public struct LibraryCommandService: CommandService {
    private let repository: LibraryRepository

    public init(repository: LibraryRepository) {
        self.repository = repository
    }

    public func libraries() async throws -> [ServerConnection] {
        try await repository.servers()
    }

    public func albums(
        serverId: ServerID,
        after: LibraryRepository.PageCursor?,
        limit: Int
    ) async throws -> LibraryRepository.Page<AlbumRecord> {
        try await repository.albumsPage(serverId: serverId, after: after, limit: limit)
    }

    public func artist(serverId: ServerID, remoteId: String) async throws -> ArtistRecord? {
        try await repository.artist(serverId: serverId, remoteId: remoteId)
    }
}
