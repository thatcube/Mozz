import Foundation
import Testing
import MozzCore
import MozzDatabase
import MozzSchema
import SwiftProtobuf
@testable import MozzCommands

/// The core's artwork store, exercised without a server or a network: the fetch
/// seam is injected, so every rule below — what is remembered, what is retried,
/// what is evicted and when — is checked against real bytes on a real (temp)
/// disk and nothing else.
///
/// These are the behaviours the two shells implemented separately and disagreed
/// on. Pinning them here is the point of moving the logic into the core.
@Suite struct ArtworkStoreTests {

    // MARK: Fixtures

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("artwork-\(UUID().uuidString)", isDirectory: true)
    }

    private static func query(_ key: String, size: Int = 512) -> ArtworkQuery {
        ArtworkQuery(serverId: "server-1", artworkKey: key, size: size)
    }

    private static func blob(_ count: Int, fill: UInt8 = 0xAB) -> Data {
        Data(repeating: fill, count: count)
    }

    private static func exists(_ directory: URL, _ query: ArtworkQuery) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(query.fileName).path)
    }

    /// Force a file's recency to an exact value, so eviction order does not
    /// depend on filesystem timestamp granularity between two fast writes.
    private static func stamp(_ directory: URL, _ query: ArtworkQuery, _ date: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: directory.appendingPathComponent(query.fileName).path)
    }

    /// A fetch that returns scripted outcomes and records every call, so a test
    /// can prove an answer came from the cache rather than a second fetch.
    private actor Fetcher {
        private var outcomes: [String: ArtworkOutcome]
        private(set) var calls: [String] = []

        init(_ outcomes: [String: ArtworkOutcome]) { self.outcomes = outcomes }

        func set(_ key: String, _ outcome: ArtworkOutcome) { outcomes[key] = outcome }

        func callCount(_ key: String) -> Int { calls.filter { $0 == key }.count }

        func fetch(_ query: ArtworkQuery) -> ArtworkOutcome {
            calls.append(query.artworkKey)
            return outcomes[query.artworkKey] ?? .absent
        }
    }

    // MARK: Absence vs transient failure

    /// The distinction the whole store turns on: an absence is remembered and
    /// not asked again; a transient failure is retried. Getting this wrong is
    /// what made every cover vanish for a session on the desktop before
    /// `ArtworkUnavailableException` existed.
    @Test func absenceIsRememberedButTransientFailureIsRetried() async throws {
        let fetcher = Fetcher(["absent": .absent, "flaky": .unavailable])
        let store = ArtworkStore(directory: Self.tempDirectory(), byteLimit: 1_000_000) {
            await fetcher.fetch($0)
        }

        // Absent, twice: the second answer must come from memory, not a fetch.
        #expect(await store.artwork(Self.query("absent")) == .absent)
        #expect(await store.artwork(Self.query("absent")) == .absent)
        #expect(await fetcher.callCount("absent") == 1)

        // Unavailable, twice: each ask must re-fetch, because "not right now" is
        // not evidence the cover is missing.
        #expect(await store.artwork(Self.query("flaky")) == .unavailable)
        #expect(await store.artwork(Self.query("flaky")) == .unavailable)
        #expect(await fetcher.callCount("flaky") == 2)

        // Because it was never remembered as absent, the moment it succeeds the
        // store returns the bytes.
        await fetcher.set("flaky", .bytes(Self.blob(64)))
        #expect(await store.artwork(Self.query("flaky")) == .bytes(Self.blob(64)))
    }

    /// An empty body is treated as absence, not cached as zero bytes that would
    /// later read back as a hit for nothing.
    @Test func anEmptyBodyIsAbsenceRatherThanACachedNothing() async throws {
        let directory = Self.tempDirectory()
        let fetcher = Fetcher(["empty": .bytes(Data())])
        let store = ArtworkStore(directory: directory, byteLimit: 1_000_000) {
            await fetcher.fetch($0)
        }

        #expect(await store.artwork(Self.query("empty")) == .absent)
        #expect(!Self.exists(directory, Self.query("empty")))
        // Remembered, so not asked again.
        #expect(await store.artwork(Self.query("empty")) == .absent)
        #expect(await fetcher.callCount("empty") == 1)
    }

    /// Attaching a server forgets earlier absences so each gets a fresh ask —
    /// the parallel to the desktop clearing its negative set on attach.
    @Test func forgetAbsentGivesEveryRememberedAbsenceAnotherChance() async throws {
        let fetcher = Fetcher(["cover": .absent])
        let store = ArtworkStore(directory: Self.tempDirectory(), byteLimit: 1_000_000) {
            await fetcher.fetch($0)
        }

        #expect(await store.artwork(Self.query("cover")) == .absent)
        #expect(await store.artwork(Self.query("cover")) == .absent)
        #expect(await fetcher.callCount("cover") == 1)

        // The server now has the cover; without forgetting, the store would keep
        // answering absent from memory forever.
        await fetcher.set("cover", .bytes(Self.blob(32)))
        await store.forgetAbsent()
        #expect(await store.artwork(Self.query("cover")) == .bytes(Self.blob(32)))
        #expect(await fetcher.callCount("cover") == 2)
    }

    // MARK: Disk hits

    /// A fetched cover is written to disk and served from there next time,
    /// without a second fetch.
    @Test func aWrittenCoverIsServedFromDiskWithoutRefetching() async throws {
        let directory = Self.tempDirectory()
        let fetcher = Fetcher(["cover": .bytes(Self.blob(128))])
        let store = ArtworkStore(directory: directory, byteLimit: 1_000_000) {
            await fetcher.fetch($0)
        }

        #expect(await store.artwork(Self.query("cover")) == .bytes(Self.blob(128)))
        #expect(Self.exists(directory, Self.query("cover")))
        #expect(await store.artwork(Self.query("cover")) == .bytes(Self.blob(128)))
        #expect(await fetcher.callCount("cover") == 1)
    }

    // MARK: Eviction

    /// Populate a directory through a store whose budget is large enough that no
    /// write triggers eviction, so the test controls exactly when eviction runs.
    private static func populate(_ directory: URL, _ keys: [String], size: Int) async throws {
        let store = ArtworkStore(directory: directory, byteLimit: 100_000_000) {
            .bytes(Self.blob(size, fill: UInt8(truncatingIfNeeded: $0.artworkKey.hashValue)))
        }
        for key in keys {
            _ = await store.artwork(Self.query(key))
        }
    }

    /// Over budget, the least-recently-used file goes first.
    @Test func evictionRemovesTheLeastRecentlyUsedFirst() async throws {
        let directory = Self.tempDirectory()
        try await Self.populate(directory, ["A", "B", "C", "D"], size: 100)
        try Self.stamp(directory, Self.query("A"), Date(timeIntervalSince1970: 1000))
        try Self.stamp(directory, Self.query("B"), Date(timeIntervalSince1970: 2000))
        try Self.stamp(directory, Self.query("C"), Date(timeIntervalSince1970: 3000))
        try Self.stamp(directory, Self.query("D"), Date(timeIntervalSince1970: 4000))

        // 400 bytes present, budget 350 → remove exactly the oldest, A.
        let store = ArtworkStore(directory: directory, byteLimit: 350) { _ in .absent }
        let removed = await store.enforceBudget()

        #expect(removed == 100)
        #expect(!Self.exists(directory, Self.query("A")))
        #expect(Self.exists(directory, Self.query("B")))
        #expect(Self.exists(directory, Self.query("C")))
        #expect(Self.exists(directory, Self.query("D")))
    }

    /// Eviction stops the instant the budget is met — no cover that survives the
    /// cut is thrown away, because each one cost a round trip to fetch.
    @Test func evictionStopsAsSoonAsTheBudgetIsMet() async throws {
        let directory = Self.tempDirectory()
        try await Self.populate(directory, ["A", "B", "C", "D", "E"], size: 100)
        try Self.stamp(directory, Self.query("A"), Date(timeIntervalSince1970: 1000))
        try Self.stamp(directory, Self.query("B"), Date(timeIntervalSince1970: 2000))
        try Self.stamp(directory, Self.query("C"), Date(timeIntervalSince1970: 3000))
        try Self.stamp(directory, Self.query("D"), Date(timeIntervalSince1970: 4000))
        try Self.stamp(directory, Self.query("E"), Date(timeIntervalSince1970: 5000))

        // 500 bytes present, budget 250 → remove A, B, C (down to 200) and stop;
        // D and E are within budget and must survive.
        let store = ArtworkStore(directory: directory, byteLimit: 250) { _ in .absent }
        let removed = await store.enforceBudget()

        #expect(removed == 300)
        #expect(!Self.exists(directory, Self.query("A")))
        #expect(!Self.exists(directory, Self.query("B")))
        #expect(!Self.exists(directory, Self.query("C")))
        #expect(Self.exists(directory, Self.query("D")))
        #expect(Self.exists(directory, Self.query("E")))
    }

    /// A cache hit refreshes recency, so a frequently-read cover outlives an
    /// older-written but untouched one under pressure.
    @Test func aCacheHitRefreshesRecencySoItSurvivesEviction() async throws {
        let directory = Self.tempDirectory()
        let big = ArtworkStore(directory: directory, byteLimit: 100_000_000) {
            .bytes(Self.blob(100, fill: UInt8(truncatingIfNeeded: $0.artworkKey.hashValue)))
        }
        for key in ["A", "B", "C"] { _ = await big.artwork(Self.query(key)) }
        try Self.stamp(directory, Self.query("A"), Date(timeIntervalSince1970: 1000))
        try Self.stamp(directory, Self.query("B"), Date(timeIntervalSince1970: 2000))
        try Self.stamp(directory, Self.query("C"), Date(timeIntervalSince1970: 3000))

        // Read A: it becomes the most recently used despite being written first.
        #expect(await big.artwork(Self.query("A")) != .absent)

        // 300 bytes present, budget 250 → the oldest is now B, not A.
        let store = ArtworkStore(directory: directory, byteLimit: 250) { _ in .absent }
        let removed = await store.enforceBudget()

        #expect(removed == 100)
        #expect(Self.exists(directory, Self.query("A")))
        #expect(!Self.exists(directory, Self.query("B")))
        #expect(Self.exists(directory, Self.query("C")))
    }

    /// Eviction touches only the store's own files. A neighbour's file in the
    /// same directory is never swept, matching the desktop's own-extension rule.
    @Test func evictionLeavesForeignFilesAlone() async throws {
        let directory = Self.tempDirectory()
        try await Self.populate(directory, ["A", "B"], size: 100)
        try Self.stamp(directory, Self.query("A"), Date(timeIntervalSince1970: 1000))
        try Self.stamp(directory, Self.query("B"), Date(timeIntervalSince1970: 2000))
        // A large foreign file, older than everything, that a naive sweep would
        // delete first.
        let foreign = directory.appendingPathComponent("other.dat")
        try Self.blob(10_000).write(to: foreign)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 500)], ofItemAtPath: foreign.path)

        let store = ArtworkStore(directory: directory, byteLimit: 150) { _ in .absent }
        _ = await store.enforceBudget()

        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    // MARK: Through the Facade

    private static func facadeDispatcher(_ store: ArtworkStore?) throws -> CommandDispatcher {
        let service = try LibraryCommandService(
            repository: LibraryRepository(MusicDatabase.inMemory()),
            playbackSettings: PlaybackSettingsStore(MusicDatabase.inMemory()),
            downloads: DownloadStore(MusicDatabase.inMemory()),
            artwork: store)
        return CommandDispatcher(service: service)
    }

    private static func requestArtwork(
        _ dispatcher: CommandDispatcher, key: String
    ) async throws -> Mozz_V1_ArtworkResponse {
        var artwork = Mozz_V1_ArtworkRequest()
        artwork.serverID = "server-1"
        artwork.artworkKey = key
        artwork.size = 512
        var request = Mozz_V1_Request()
        request.id = 42
        request.artwork = artwork
        let bytes = await dispatcher.handle(try request.serializedData())
        let response = try Mozz_V1_Response(serializedBytes: bytes)
        #expect(response.id == 42)
        guard case .artwork(let payload) = response.result else {
            Issue.record("expected artwork, got \(String(describing: response.result))")
            return Mozz_V1_ArtworkResponse()
        }
        return payload
    }

    /// The bug class the whole binary-invoke path exists for: bytes with an
    /// embedded 0x00 must cross the Facade byte-for-byte, where the old C-string
    /// door would have truncated them at the first zero.
    @Test func bytesWithAnEmbeddedNulSurviveTheFacadeUnchanged() async throws {
        let payload = Data([0x00, 0x01, 0x00, 0xFF, 0x42, 0x00])
        let store = ArtworkStore(directory: Self.tempDirectory(), byteLimit: 1_000_000) { _ in
            .bytes(payload)
        }
        let response = try await Self.requestArtwork(try Self.facadeDispatcher(store), key: "cover")

        #expect(response.status == .present)
        #expect(response.data == payload)
        #expect(response.data.contains(0), "this test is pointless without a zero byte")
    }

    @Test func absenceCrossesTheFacadeAsAbsentWithNoBytes() async throws {
        let store = ArtworkStore(directory: Self.tempDirectory(), byteLimit: 1_000_000) { _ in .absent }
        let response = try await Self.requestArtwork(try Self.facadeDispatcher(store), key: "missing")

        #expect(response.status == .absent)
        #expect(response.data.isEmpty)
    }

    @Test func aTransientFailureCrossesTheFacadeAsUnavailable() async throws {
        let store = ArtworkStore(directory: Self.tempDirectory(), byteLimit: 1_000_000) { _ in
            .unavailable
        }
        let response = try await Self.requestArtwork(try Self.facadeDispatcher(store), key: "later")

        #expect(response.status == .unavailable)
        #expect(response.data.isEmpty)
    }

    /// With no store wired in, the Facade reports the honest transient answer
    /// rather than inventing an absence the caller would remember.
    @Test func aServiceWithNoStoreReportsUnavailable() async throws {
        let response = try await Self.requestArtwork(try Self.facadeDispatcher(nil), key: "cover")
        #expect(response.status == .unavailable)
    }
}
