import Foundation
@testable import MozzApp
import MozzCore
import MozzRelay
import XCTest

final class ServerSyncJournalTests: XCTestCase {
    private func session(
        token: String = "token-a",
        sections: [String]? = ["music"]
    ) -> StoredSession {
        StoredSession(
            kind: .plex,
            baseURL: URL(string: "https://plex.example.test")!,
            token: token,
            userID: "managed-user",
            serverName: "Home Plex",
            clientIdentifier: "must-not-sync",
            serverMachineIdentifier: "machine-id",
            musicSectionID: sections?.first,
            accountToken: "switched-profile-token",
            selectedMusicSectionIDs: sections)
    }

    func testRelaunchDoesNotPretendAnUnchangedServerWasModified() {
        let store = InMemoryCredentialStore()
        ServerSyncJournal.upsert(
            session(),
            serverID: "plex:machine-id",
            in: store,
            now: Date(timeIntervalSince1970: 100))
        ServerSyncJournal.upsert(
            session(),
            serverID: "plex:machine-id",
            in: store,
            now: Date(timeIntervalSince1970: 200))

        let records = ServerSyncJournal.records(in: store)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].updatedAtMS, 100_000)
    }

    func testARealCredentialChangeGetsANewTimestamp() {
        let store = InMemoryCredentialStore()
        ServerSyncJournal.upsert(
            session(),
            serverID: "plex:machine-id",
            in: store,
            now: Date(timeIntervalSince1970: 100))
        ServerSyncJournal.upsert(
            session(token: "token-b"),
            serverID: "plex:machine-id",
            in: store,
            now: Date(timeIntervalSince1970: 200))

        let record = ServerSyncJournal.records(in: store)[0]
        XCTAssertEqual(record.token, "token-b")
        XCTAssertEqual(record.updatedAtMS, 200_000)
    }

    func testClientIdentifierNeverEntersTheSyncedRecord() {
        let store = InMemoryCredentialStore()
        ServerSyncJournal.upsert(
            session(),
            serverID: "plex:machine-id",
            in: store)

        let encoded = try! JSONEncoder().encode(
            ServerSyncJournal.records(in: store))
        XCTAssertNil(encoded.range(of: Data("must-not-sync".utf8)))
    }

    func testDefaultAllLibrariesKeepsItsMeaningAndResolvedIDs() {
        let store = InMemoryCredentialStore()
        ServerSyncJournal.upsert(
            session(sections: nil),
            serverID: "plex:machine-id",
            in: store,
            resolvedMusicSectionIDs: ["music-2", "music-1"])

        let record = ServerSyncJournal.records(in: store)[0]
        XCTAssertEqual(record.musicSectionIDs, ["music-1", "music-2"])
        XCTAssertEqual(record.allMusicLibraries, true)
    }

    func testSignOutWritesATombstoneThatBeatsAStaleDevice() {
        let store = InMemoryCredentialStore()
        ServerSyncJournal.upsert(
            session(),
            serverID: "plex:machine-id",
            in: store,
            now: Date(timeIntervalSince1970: 100))
        ServerSyncJournal.tombstone(
            serverID: "plex:machine-id",
            kind: .plex,
            in: store,
            now: Date(timeIntervalSince1970: 200))
        let stale = RelayServerRecord(
            id: "plex:machine-id",
            kind: "plex",
            name: "Home Plex",
            baseURL: "https://plex.example.test",
            token: "stale",
            updatedAtMS: 100_000)

        ServerSyncJournal.merge([stale], into: store)

        let record = ServerSyncJournal.records(in: store)[0]
        XCTAssertTrue(record.isRemoved)
        XCTAssertEqual(record.removedAtMS, 200_000)
    }

    func testRemoteTimestampIsPreservedInsteadOfBecomingLocalNow() {
        let store = InMemoryCredentialStore()
        let remote = RelayServerRecord(
            id: "jellyfin:user",
            kind: "jellyfin",
            name: "Home Music",
            baseURL: "https://music.example.test",
            token: "remote-token",
            updatedAtMS: 123)

        ServerSyncJournal.merge([remote], into: store)

        XCTAssertEqual(
            ServerSyncJournal.records(in: store)[0].updatedAtMS,
            123)
    }
}
