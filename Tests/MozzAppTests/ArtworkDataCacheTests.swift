import Foundation
import XCTest
@testable import MozzApp

final class ArtworkDataCacheTests: XCTestCase {
    func testKeyStripsCredentialsButKeepsVariantAndAccountIdentity() throws {
        let old = try XCTUnwrap(URL(string:
            "https://Music.local/rest/getCoverArt.view?id=album&size=240&u=alice&t=old&s=salt"
        ))
        let rotated = try XCTUnwrap(URL(string:
            "https://music.local/rest/getCoverArt.view?s=new&t=new&u=alice&size=240&id=album"
        ))
        let otherSize = try XCTUnwrap(URL(string:
            "https://music.local/rest/getCoverArt.view?id=album&size=600&u=alice&t=new&s=new"
        ))
        let otherUser = try XCTUnwrap(URL(string:
            "https://music.local/rest/getCoverArt.view?id=album&size=240&u=bob&t=new&s=new"
        ))

        XCTAssertEqual(ArtworkCacheKey.disk(for: old), ArtworkCacheKey.disk(for: rotated))
        XCTAssertNotEqual(ArtworkCacheKey.disk(for: old), ArtworkCacheKey.disk(for: otherSize))
        XCTAssertNotEqual(ArtworkCacheKey.disk(for: old), ArtworkCacheKey.disk(for: otherUser))
        XCTAssertEqual(ArtworkCacheKey.offline(for: old), ArtworkCacheKey.offline(for: otherSize))
    }

    func testDiskStoreEvictsLeastRecentlyUsedEntry() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ArtworkDiskStore(directory: directory, byteLimit: 8)
        let a = key("a")
        let b = key("b")
        let c = key("c")

        await store.store(Data(repeating: 1, count: 4), for: a)
        try await Task.sleep(nanoseconds: 20_000_000)
        await store.store(Data(repeating: 2, count: 4), for: b)
        try await Task.sleep(nanoseconds: 20_000_000)
        _ = await store.data(for: a)
        try await Task.sleep(nanoseconds: 20_000_000)
        await store.store(Data(repeating: 3, count: 4), for: c)

        let storedA = await store.data(for: a)
        let storedB = await store.data(for: b)
        let storedC = await store.data(for: c)
        XCTAssertEqual(storedA, Data(repeating: 1, count: 4))
        XCTAssertNil(storedB)
        XCTAssertEqual(storedC, Data(repeating: 3, count: 4))
    }

    func testLookupOrderIsMemoryOfflineDiskNetwork() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ArtworkDiskStore(
            directory: root.appendingPathComponent("cache"), byteLimit: 1_024
        )
        let offline = ArtworkDiskStore(
            directory: root.appendingPathComponent("offline"), byteLimit: nil
        )
        let memory = ArtworkDataMemoryCache()
        let loader = ArtworkDataLoader(
            memory: memory,
            disk: disk,
            offline: offline,
            fetch: { _ in Data([4]) }
        )
        let memoryURL = try url("memory")
        let offlineURL = try url("offline")
        let diskURL = try url("disk")
        let networkURL = try url("network")

        memory.insert(Data([1]), for: ArtworkCacheKey.disk(for: memoryURL))
        await offline.store(Data([2]), for: ArtworkCacheKey.offline(for: memoryURL))
        await disk.store(Data([3]), for: ArtworkCacheKey.disk(for: memoryURL))
        await offline.store(Data([2]), for: ArtworkCacheKey.offline(for: offlineURL))
        await disk.store(Data([3]), for: ArtworkCacheKey.disk(for: offlineURL))
        await disk.store(Data([3]), for: ArtworkCacheKey.disk(for: diskURL))

        let memoryData = await loader.data(for: memoryURL)
        let offlineData = await loader.data(for: offlineURL)
        let diskData = await loader.data(for: diskURL)
        let networkData = await loader.data(for: networkURL)
        let persistedNetworkData = await disk.data(for: ArtworkCacheKey.disk(for: networkURL))
        XCTAssertEqual(memoryData, Data([1]))
        XCTAssertEqual(offlineData, Data([2]))
        XCTAssertEqual(diskData, Data([3]))
        XCTAssertEqual(networkData, Data([4]))
        XCTAssertEqual(persistedNetworkData, Data([4]))
    }

    func testOfflineCaptureDeduplicatesArtworkAcrossSizes() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ArtworkDiskStore(
            directory: root.appendingPathComponent("cache"), byteLimit: 1_024
        )
        let offline = ArtworkDiskStore(
            directory: root.appendingPathComponent("offline"), byteLimit: nil
        )
        let loader = ArtworkDataLoader(
            memory: ArtworkDataMemoryCache(),
            disk: disk,
            offline: offline,
            fetch: { _ in Data([9]) }
        )
        let large = try url("album", size: 1_200)
        let small = try url("album", size: 120)

        let captured = await loader.captureForOffline(large)
        let smallData = await loader.data(for: small)
        let persisted = await offline.data(for: ArtworkCacheKey.offline(for: small))
        XCTAssertEqual(captured, Data([9]))
        XCTAssertEqual(smallData, Data([9]))
        XCTAssertEqual(persisted, Data([9]))
    }

    private func makeDirectory() throws -> URL {
        let root = try XCTUnwrap(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        )
        let directory = root.appendingPathComponent("MozzTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func key(_ id: String) -> ArtworkCacheKey {
        ArtworkCacheKey.disk(for: URL(string: "https://example.com/\(id)")!)
    }

    private func url(_ id: String, size: Int = 240) throws -> URL {
        try XCTUnwrap(URL(string:
            "https://example.com/art?id=\(id)&size=\(size)&api_key=secret"
        ))
    }
}
