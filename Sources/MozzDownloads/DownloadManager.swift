import Foundation
import MozzCore
import MozzDatabase

/// Orchestrates offline downloads of original audio files using a **background**
/// `URLSession`, so transfers continue when the app is suspended and can finish
/// after relaunch (the whole point of offline downloads on iOS).
///
/// Design:
/// - The database (via ``DownloadStore``) is the durable record of what is
///   queued / in flight / done. The session's task carries a small encoded
///   `taskDescription` (`trackId::relativePath`) so a finished transfer can be
///   reconciled to a catalog row even across an app relaunch.
/// - When a transfer finishes, the temp file is moved into ``DownloadFileStore``
///   *synchronously inside the delegate callback* (the OS deletes it the moment
///   the callback returns), then the database is updated asynchronously.
/// - The move + record step is factored into ``handleCompletedFile(at:taskDescription:)``
///   so the offline path is unit-testable without spinning up a real network
///   session.
///
/// Auth: original-file URLs from both backends already carry the token as a
/// query parameter, so the background GET needs no extra headers.
@MainActor
public final class DownloadManager: NSObject, ObservableObject {
    /// In-flight progress fraction (0...1) keyed by internal track id.
    @Published public private(set) var progress: [Int64: Double] = [:]

    /// Set by the app delegate's background-session handler so we can tell the
    /// system we're done processing background events.
    public var backgroundCompletionHandler: (@Sendable () -> Void)?

    private let store: DownloadStore
    private let repository: LibraryRepository
    private let fileStore: DownloadFileStore
    private let sessionIdentifier: String

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    public init(
        database: MusicDatabase,
        fileStore: DownloadFileStore,
        sessionIdentifier: String = "com.thatcube.Mozz.downloads"
    ) {
        self.store = DownloadStore(database)
        self.repository = LibraryRepository(database)
        self.fileStore = fileStore
        self.sessionIdentifier = sessionIdentifier
        super.init()
    }

    // MARK: Public API

    /// Queue a track for offline download. Resolves the original-file URL from
    /// the backend and starts a background transfer.
    public func download(_ track: Track, serverId: ServerID, using backend: any MusicBackend) async throws {
        guard
            let record = try await repository.track(serverId: serverId, remoteId: track.id),
            let internalId = record.id
        else { throw MozzError.notFound }

        // The catalog sync may have stored this track without its audio format
        // (backfilled lazily for speed). We need the container to name the offline
        // file correctly, so hydrate on demand if it's still missing.
        var track = track
        if track.format.container == nil, track.format.codec == nil,
           let hydrated = try? await backend.fetchTrackDetails(ids: [track.id]).first {
            track = hydrated
        }

        let url = try backend.originalFileURL(for: track)
        try await store.enqueue(trackId: internalId)
        try await store.markDownloading(trackId: internalId, totalBytes: track.fileSizeBytes)

        let ext = Self.fileExtension(for: track)
        let relativePath = fileStore.relativePath(serverId: serverId, remoteId: track.id, fileExtension: ext)
        progress[internalId] = 0

        // Local-file sources (the demo backend, or an already-local server)
        // don't go through the background session — copy directly so offline
        // works even in the simulator.
        if url.isFileURL {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.copyItem(at: url, to: temp)
                handleCompletedFile(at: temp, taskDescription: TaskInfo(trackId: internalId, relativePath: relativePath).encoded)
            } catch {
                try await store.markFailed(trackId: internalId, error: error.localizedDescription)
            }
            return
        }

        let info = TaskInfo(trackId: internalId, relativePath: relativePath)
        let task = session.downloadTask(with: url)
        task.taskDescription = info.encoded
        task.resume()
    }

    /// Queue every track of an album for offline download.
    public func downloadAlbum(albumGroupKey: String, serverId: ServerID, using backend: any MusicBackend) async throws {
        let records = try await repository.tracks(forAlbumGroupKey: albumGroupKey, serverId: serverId)
        for record in records {
            try await download(record.toDomain(), serverId: serverId, using: backend)
        }
    }

    /// Delete a downloaded track: remove the file and its record.
    public func deleteDownload(trackInternalId: Int64) async throws {
        if let record = try await repository.download(trackId: trackInternalId),
           let relativePath = record.localPath {
            try? fileStore.delete(relativePath: relativePath)
        }
        try await store.remove(trackId: trackInternalId)
        progress[trackInternalId] = nil
    }

    /// Cancel an in-flight download.
    public func cancel(trackInternalId: Int64) async {
        let tasks = await session.allTasks
        for task in tasks where TaskInfo(task.taskDescription)?.trackId == trackInternalId {
            task.cancel()
        }
        try? await store.markFailed(trackId: trackInternalId, error: "Cancelled")
        progress[trackInternalId] = nil
    }

    /// Current storage usage (delegates to the DB accounting).
    public func storageUsage() async throws -> StorageUsage {
        try await repository.storageUsage()
    }

    // MARK: Completion handling (shared by the delegate and by tests)

    /// Move a finished temp file into the store and mark the download complete.
    /// The move happens synchronously (the caller's temp file is ephemeral); the
    /// database update is async.
    public func handleCompletedFile(at location: URL, taskDescription: String?) {
        guard let info = TaskInfo(taskDescription) else { return }
        do {
            let size = try fileStore.moveIntoPlace(from: location, relativePath: info.relativePath)
            Task { await self.recordDownloaded(trackId: info.trackId, relativePath: info.relativePath, size: size) }
        } catch {
            Task { await self.recordFailed(trackId: info.trackId, error: error.localizedDescription) }
        }
    }

    private func recordDownloaded(trackId: Int64, relativePath: String, size: Int64) async {
        try? await store.markDownloaded(trackId: trackId, localPath: relativePath, sizeBytes: size)
        progress[trackId] = 1
    }

    private func recordFailed(trackId: Int64, error: String) async {
        try? await store.markFailed(trackId: trackId, error: error)
        progress[trackId] = nil
    }

    private func updateProgress(trackId: Int64, fraction: Double, received: Int64, total: Int64?) async {
        progress[trackId] = fraction
        try? await store.updateProgress(trackId: trackId, receivedBytes: received, totalBytes: total)
    }

    private static func fileExtension(for track: Track) -> String {
        if let container = track.format.container, !container.isEmpty { return container }
        if let codec = track.format.codec, !codec.isEmpty { return codec }
        return "audio"
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Move synchronously *now* — `location` is deleted when this returns.
        // We can't hop to the main actor first, so do the file move on this
        // thread using a temp copy, then hand off to the main actor.
        let description = downloadTask.taskDescription
        let fileManager = FileManager.default
        let holding = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try fileManager.moveItem(at: location, to: holding)
        } catch {
            return
        }
        Task { @MainActor in
            self.handleCompletedFile(at: holding, taskDescription: description)
        }
    }

    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let info = TaskInfo(downloadTask.taskDescription) else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        let fraction = total.map { Double(totalBytesWritten) / Double($0) } ?? 0
        Task { @MainActor in
            await self.updateProgress(
                trackId: info.trackId, fraction: fraction,
                received: totalBytesWritten, total: total
            )
        }
    }

    public nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error, let info = TaskInfo(task.taskDescription) else { return }
        if (error as? URLError)?.code == .cancelled { return }
        Task { @MainActor in
            await self.recordFailed(trackId: info.trackId, error: error.localizedDescription)
        }
    }

    public nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}

// MARK: - Task description encoding

/// The minimal state carried on a background task so a finished transfer can be
/// reconciled to a catalog row (even after an app relaunch).
private struct TaskInfo {
    let trackId: Int64
    let relativePath: String

    init(trackId: Int64, relativePath: String) {
        self.trackId = trackId
        self.relativePath = relativePath
    }

    init?(_ encoded: String?) {
        guard let encoded else { return nil }
        let parts = encoded.components(separatedBy: "::")
        guard parts.count == 2, let id = Int64(parts[0]) else { return nil }
        self.trackId = id
        self.relativePath = parts[1]
    }

    var encoded: String { "\(trackId)::\(relativePath)" }
}
