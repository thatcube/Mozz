import Foundation
import MozzCore
import MozzDatabase

/// The offline-first ``TrackURLResolver``: if a track is fully downloaded and
/// its file is present on disk, it resolves to the **local file URL** and never
/// touches the network — which is exactly what makes airplane-mode playback
/// automatic. Otherwise it falls back to a streaming resolver.
///
/// It resolves against the single source of truth (the database): a domain
/// ``Track`` carries only its provider `remoteId`, so we look up the internal
/// track id for the active server, then its download record.
public struct OfflineTrackURLResolver: TrackURLResolver {
    private let serverId: ServerID
    private let repository: LibraryRepository
    private let fileStore: DownloadFileStore
    private let fallback: any TrackURLResolver

    public init(
        serverId: ServerID,
        repository: LibraryRepository,
        fileStore: DownloadFileStore,
        fallback: any TrackURLResolver
    ) {
        self.serverId = serverId
        self.repository = repository
        self.fileStore = fileStore
        self.fallback = fallback
    }

    public func resolve(_ track: Track) async throws -> ResolvedTrackURL {
        if let localURL = try await localFileURL(for: track) {
            return ResolvedTrackURL(url: localURL, isLocal: true)
        }
        return try await fallback.resolve(track)
    }

    /// The absolute file URL for a downloaded track, or `nil` if it isn't
    /// downloaded (or the file has gone missing).
    public func localFileURL(for track: Track) async throws -> URL? {
        guard
            let record = try await repository.track(serverId: serverId, remoteId: track.id),
            let internalId = record.id,
            let download = try await repository.download(trackId: internalId),
            download.downloadState == .downloaded,
            let relativePath = download.localPath,
            fileStore.fileExists(relativePath: relativePath)
        else { return nil }
        return fileStore.absoluteURL(forRelativePath: relativePath)
    }
}
