import XCTest
@testable import MozzCore

/// An in-memory ``CredentialStore``, with a switch for "this store cannot answer
/// right now" — which is the state the iCloud keychain is actually in from time
/// to time, and the one the routing store used to read as a sign-out.
private final class FakeStore: CredentialStore, @unchecked Sendable {
    var values: [String: String] = [:]
    var unavailable = false

    func string(forKey key: String) throws -> String? {
        unavailable ? nil : values[key]
    }

    func setString(_ value: String?, forKey key: String) throws {
        if unavailable { return }
        if let value { values[key] = value } else { values.removeValue(forKey: key) }
    }
}

final class RoutingCredentialStoreTests: XCTestCase {
    private let key = "session.active"

    private func make() -> (RoutingCredentialStore, FakeStore, FakeStore) {
        let local = FakeStore()
        let synced = FakeStore()
        let store = RoutingCredentialStore(local: local, synced: synced, syncedKeys: [key])
        return (store, local, synced)
    }

    func testASyncedWriteIsMirroredLocally() throws {
        let (store, local, synced) = make()
        try store.setString("session", forKey: key)
        XCTAssertEqual(synced.values[key], "session")
        XCTAssertEqual(local.values[key], "session", "the device needs its own copy to fall back on")
    }

    /// The regression this exists for: the session lived only in the iCloud
    /// keychain, so any moment that item could not be read presented as a
    /// sign-out and sent the user back to linking their account.
    func testTheSessionSurvivesICloudBeingUnreadable() throws {
        let (store, _, synced) = make()
        try store.setString("session", forKey: key)

        synced.unavailable = true
        XCTAssertEqual(try store.string(forKey: key), "session")
    }

    func testAPreSyncSessionIsPromotedAndKept() throws {
        let (store, local, synced) = make()
        local.values[key] = "legacy"

        XCTAssertEqual(try store.string(forKey: key), "legacy")
        XCTAssertEqual(synced.values[key], "legacy", "promoted, so the user's other devices get it")
        XCTAssertEqual(local.values[key], "legacy", "and kept, so this device can answer alone")
    }

    /// Signing out has to be final. The fallback must not resurrect it.
    func testSigningOutClearsBothCopies() throws {
        let (store, local, synced) = make()
        try store.setString("session", forKey: key)

        try store.setString(nil, forKey: key)

        XCTAssertNil(synced.values[key])
        XCTAssertNil(local.values[key])
        XCTAssertNil(try store.string(forKey: key))
    }

    func testUnsyncedKeysNeverTouchTheSyncedStore() throws {
        let (store, local, synced) = make()
        try store.setString("device-only", forKey: "client.identifier")

        XCTAssertEqual(local.values["client.identifier"], "device-only")
        XCTAssertTrue(synced.values.isEmpty)
    }
}
