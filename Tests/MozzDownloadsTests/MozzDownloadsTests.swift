import XCTest
import Foundation
import MozzCore
import MozzDatabase
@testable import MozzDownloads

/// A fallback resolver that fails if it is ever called — used to *prove* the
/// offline resolver never touches the network for a downloaded track.
private struct FailingResolver: TrackURLResolver {
    func resolve(_ track: Track) async throws -> ResolvedTrackURL {
        XCTFail("Fallback (network) resolver must not be called for a downloaded track")
        throw MozzError.serverUnreachable
    }
}

private func makeStore() throws -> (MusicDatabase, URL) {
    let db = try MusicDatabase.inMemory()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mozz-dl-test-\(UUID().uuidString)")
    return (db, root)
}

/// Seed a single track and return its internal id.
private func seedTrack(_ db: MusicDatabase, serverId: String = "srv", remoteId: String = "t1") async throws -> Int64 {
    let writer = CatalogWriter(db)
    try await writer.saveServer(ServerConnection(
        id: serverId, kind: .jellyfin, name: "S",
        baseURL: URL(string: "https://s.example.com")!, clientIdentifier: "c"
    ))
    let track = Track(id: remoteId, title: "Song", albumID: "al1", artistName: "Artist",
                      format: AudioFormat(container: "flac"))
    try await writer.upsertTracks([track], serverId: serverId)
    let repository = LibraryRepository(db)
    let record = try await repository.track(serverId: serverId, remoteId: remoteId)
    return try XCTUnwrap(record?.id)
}

final class DownloadFileStoreTests: XCTestCase {
    func testRelativePathSanitizesComponents() throws {
        let store = try DownloadFileStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("mozz-fs-\(UUID().uuidString)"))
        let path = store.relativePath(serverId: "srv/1", remoteId: "a b|c", fileExtension: "flac")
        XCTAssertFalse(path.contains(" "))
        XCTAssertFalse(path.contains("|"))
        XCTAssertTrue(path.hasSuffix(".flac"))
        try? store.removeAll()
    }

    func testMoveIntoPlaceReturnsSizeAndExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mozz-fs-\(UUID().uuidString)")
        let store = try DownloadFileStore(root: root)
        defer { try? store.removeAll() }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data(repeating: 7, count: 2048)
        try bytes.write(to: temp)

        let rel = store.relativePath(serverId: "srv", remoteId: "t1", fileExtension: "mp3")
        let size = try store.moveIntoPlace(from: temp, relativePath: rel)

        XCTAssertEqual(size, 2048)
        XCTAssertTrue(store.fileExists(relativePath: rel))
        XCTAssertEqual(try store.totalBytesOnDisk(), 2048)
    }

    func testDeleteRemovesFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mozz-fs-\(UUID().uuidString)")
        let store = try DownloadFileStore(root: root)
        defer { try? store.removeAll() }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 1, count: 10).write(to: temp)
        let rel = store.relativePath(serverId: "s", remoteId: "r", fileExtension: "m4a")
        _ = try store.moveIntoPlace(from: temp, relativePath: rel)
        XCTAssertTrue(store.fileExists(relativePath: rel))

        try store.delete(relativePath: rel)
        XCTAssertFalse(store.fileExists(relativePath: rel))
    }
}

@MainActor
final class DownloadManagerTests: XCTestCase {
    func testHandleCompletedFileMarksDownloadedAndAccountsStorage() async throws {
        let (db, root) = try makeStore()
        let fileStore = try DownloadFileStore(root: root)
        defer { try? fileStore.removeAll() }
        let trackId = try await seedTrack(db)

        let manager = DownloadManager(database: db, fileStore: fileStore)

        // Simulate a finished background transfer.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 9, count: 4096).write(to: temp)
        let rel = fileStore.relativePath(serverId: "srv", remoteId: "t1", fileExtension: "flac")
        manager.handleCompletedFile(at: temp, taskDescription: "\(trackId)::\(rel)")

        // The DB update is async; wait for it.
        let repository = LibraryRepository(db)
        try await eventually {
            try await repository.download(trackId: trackId)?.downloadState == .downloaded
        }

        let record = try await repository.download(trackId: trackId)
        XCTAssertEqual(record?.localPath, rel)
        XCTAssertEqual(record?.sizeBytes, 4096)

        let usage = try await repository.storageUsage()
        XCTAssertEqual(usage.downloadedTrackCount, 1)
        XCTAssertEqual(usage.totalBytes, 4096)
    }

    func testDeleteDownloadRemovesFileAndRecord() async throws {
        let (db, root) = try makeStore()
        let fileStore = try DownloadFileStore(root: root)
        defer { try? fileStore.removeAll() }
        let trackId = try await seedTrack(db)
        let manager = DownloadManager(database: db, fileStore: fileStore)

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 3, count: 512).write(to: temp)
        let rel = fileStore.relativePath(serverId: "srv", remoteId: "t1", fileExtension: "flac")
        manager.handleCompletedFile(at: temp, taskDescription: "\(trackId)::\(rel)")

        let repository = LibraryRepository(db)
        try await eventually { try await repository.download(trackId: trackId)?.downloadState == .downloaded }

        try await manager.deleteDownload(trackInternalId: trackId)
        let afterDelete = try await repository.download(trackId: trackId)
        XCTAssertNil(afterDelete)
        XCTAssertFalse(fileStore.fileExists(relativePath: rel))
    }
}

@MainActor
final class OfflineResolverTests: XCTestCase {
    /// The core airplane-mode proof: a downloaded track resolves to a local
    /// file URL with no network fallback.
    func testDownloadedTrackResolvesToLocalFileWithoutNetwork() async throws {
        let (db, root) = try makeStore()
        let fileStore = try DownloadFileStore(root: root)
        defer { try? fileStore.removeAll() }
        let trackId = try await seedTrack(db)
        let manager = DownloadManager(database: db, fileStore: fileStore)

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 5, count: 1024).write(to: temp)
        let rel = fileStore.relativePath(serverId: "srv", remoteId: "t1", fileExtension: "flac")
        manager.handleCompletedFile(at: temp, taskDescription: "\(trackId)::\(rel)")

        let repository = LibraryRepository(db)
        try await eventually { try await repository.download(trackId: trackId)?.downloadState == .downloaded }

        let resolver = OfflineTrackURLResolver(
            serverId: "srv", repository: repository, fileStore: fileStore,
            fallback: FailingResolver()
        )
        let track = Track(id: "t1", title: "Song", artistName: "Artist")
        let resolved = try await resolver.resolve(track)

        XCTAssertTrue(resolved.isLocal)
        XCTAssertTrue(resolved.url.isFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.url.path))
    }

    func testNotDownloadedTrackFallsBackToStreaming() async throws {
        let (db, root) = try makeStore()
        let fileStore = try DownloadFileStore(root: root)
        defer { try? fileStore.removeAll() }
        _ = try await seedTrack(db)
        let repository = LibraryRepository(db)

        let streamURL = URL(string: "https://s.example.com/stream/t1")!
        let resolver = OfflineTrackURLResolver(
            serverId: "srv", repository: repository, fileStore: fileStore,
            fallback: ConstantResolver(url: streamURL)
        )
        let resolved = try await resolver.resolve(Track(id: "t1", title: "Song", artistName: "Artist"))
        XCTAssertFalse(resolved.isLocal)
        XCTAssertEqual(resolved.url, streamURL)
    }
}

private struct ConstantResolver: TrackURLResolver {
    let url: URL
    func resolve(_ track: Track) async throws -> ResolvedTrackURL {
        ResolvedTrackURL(url: url, isLocal: false)
    }
}

// MARK: - Test helper

extension XCTestCase {
    /// Poll an async condition until true or a timeout elapses.
    func eventually(
        timeout: TimeInterval = 2.0,
        _ condition: @escaping () async throws -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Condition not met within \(timeout)s", file: file, line: line)
    }
}

/// Verifies the cross-backend guard that stops an HTTP error body (which
/// Subsonic servers return over HTTP 200, and which any 4xx/5xx delivers as the
/// "downloaded file") from being saved into the offline store as audio.
final class DownloadResponseValidationTests: XCTestCase {
    private func response(status: Int, contentType: String?) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }
        return HTTPURLResponse(
            url: URL(string: "https://s.example.com/rest/download.view")!,
            statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
    }

    func testRejectsSubsonicErrorBodyOverHTTP200() {
        // The exact corruption case: a Subsonic error is HTTP 200 + a JSON/XML
        // `subsonic-response` body. Both shapes must be rejected.
        XCTAssertNotNil(DownloadManager.downloadRejectionReason(
            for: response(status: 200, contentType: "application/json")))
        XCTAssertNotNil(DownloadManager.downloadRejectionReason(
            for: response(status: 200, contentType: "text/xml; charset=utf-8")))
        XCTAssertNotNil(DownloadManager.downloadRejectionReason(
            for: response(status: 200, contentType: "application/xml")))
        XCTAssertNotNil(DownloadManager.downloadRejectionReason(
            for: response(status: 200, contentType: "text/html")))
    }

    func testRejectsErrorStatusRegardlessOfContentType() {
        XCTAssertNotNil(DownloadManager.downloadRejectionReason(
            for: response(status: 404, contentType: "audio/mpeg")))
        XCTAssertNotNil(DownloadManager.downloadRejectionReason(
            for: response(status: 401, contentType: nil)))
        XCTAssertNotNil(DownloadManager.downloadRejectionReason(
            for: response(status: 500, contentType: "application/octet-stream")))
    }

    func testAcceptsRealMedia() {
        // audio/*, octet-stream, and an unknown/absent content-type must pass so
        // a genuine download is never wrongly discarded.
        XCTAssertNil(DownloadManager.downloadRejectionReason(
            for: response(status: 200, contentType: "audio/mpeg")))
        XCTAssertNil(DownloadManager.downloadRejectionReason(
            for: response(status: 200, contentType: "audio/flac")))
        XCTAssertNil(DownloadManager.downloadRejectionReason(
            for: response(status: 206, contentType: "application/octet-stream")))
        XCTAssertNil(DownloadManager.downloadRejectionReason(
            for: response(status: 200, contentType: nil)))
    }

    func testNonHTTPResponseIsNotRejected() {
        XCTAssertNil(DownloadManager.downloadRejectionReason(for: nil))
        XCTAssertNil(DownloadManager.downloadRejectionReason(
            for: URLResponse(url: URL(string: "https://s.example.com")!,
                             mimeType: nil, expectedContentLength: 0, textEncodingName: nil)))
    }
}
