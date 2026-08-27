import Foundation
import MozzCore
import MozzRelay

/// Device-local record of server mutations waiting for the encrypted relay.
///
/// Separate from `SessionPersistence`: the app currently has one active
/// session, while sync must remember tombstones and servers learned on other
/// devices. The journal is local Keychain data (its key is not routed to iCloud)
/// and is itself published only under `credentialsKey`.
enum ServerSyncJournal {
    static let key = "server.syncJournal"

    static func records(
        in store: any CredentialStore
    ) -> [RelayServerRecord] {
        guard let text = try? store.string(forKey: key),
              let data = text.data(using: .utf8),
              let records = try? JSONDecoder().decode(
                  [RelayServerRecord].self, from: data) else {
            return []
        }
        return records
    }

    /// Record a successfully activated session. Identical content preserves its
    /// timestamp, so restoring at launch is not a new cross-device mutation.
    static func upsert(
        _ session: StoredSession,
        serverID: String,
        in store: any CredentialStore,
        resolvedMusicSectionIDs: [String]? = nil,
        now: Date = Date()
    ) {
        guard !session.isDemo else { return }
        var records = records(in: store)
        let sectionIDs = Array(Set(
            resolvedMusicSectionIDs
                ?? session.selectedMusicSectionIDs
                ?? session.musicSectionID.map { [$0] }
                ?? []
        )).sorted()
        let candidate = RelayServerRecord(
            id: serverID,
            kind: session.kind.rawValue,
            name: session.serverName,
            baseURL: session.baseURL.absoluteString,
            token: session.token,
            accountToken: session.accountToken,
            userID: session.userID,
            serverMachineIdentifier: session.serverMachineIdentifier,
            musicSectionIDs: sectionIDs,
            allMusicLibraries: session.kind == .plex
                ? session.selectedMusicSectionIDs == nil
                : nil,
            updatedAtMS: Int64(now.timeIntervalSince1970 * 1000))

        if let old = records.first(where: { $0.id == serverID }),
           sameContent(old, candidate) {
            return
        }
        records.removeAll { $0.id == serverID }
        records.append(candidate)
        save(records, in: store)
    }

    /// Removal is a permanent write, not absence. It retains only identity and
    /// kind, so a stale active snapshot cannot resurrect the server.
    static func tombstone(
        serverID: String,
        kind: BackendKind,
        in store: any CredentialStore,
        now: Date = Date()
    ) {
        var records = records(in: store)
        records.removeAll { $0.id == serverID }
        records.append(.tombstone(
            id: serverID,
            kind: kind.rawValue,
            removedAtMS: Int64(now.timeIntervalSince1970 * 1000)))
        save(records, in: store)
    }

    /// Merge remote state while preserving the remote mutation timestamp.
    static func merge(
        _ remote: [RelayServerRecord],
        into store: any CredentialStore
    ) {
        let local = RelayServerSnapshot(
            deviceID: "local",
            writtenAtMS: 0,
            servers: records(in: store))
        let incoming = RelayServerSnapshot(
            deviceID: "remote",
            writtenAtMS: 0,
            servers: remote)
        save(
            RelayHistoryStore.mergedServerRecords([local, incoming]),
            in: store)
    }

    private static func sameContent(
        _ lhs: RelayServerRecord,
        _ rhs: RelayServerRecord
    ) -> Bool {
        var lhs = lhs
        var rhs = rhs
        lhs.updatedAtMS = 0
        rhs.updatedAtMS = 0
        lhs.removedAtMS = nil
        rhs.removedAtMS = nil
        return lhs == rhs
    }

    private static func save(
        _ records: [RelayServerRecord],
        in store: any CredentialStore
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(records),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        try? store.setString(text, forKey: key)
    }
}
