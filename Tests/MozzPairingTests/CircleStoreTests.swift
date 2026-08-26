import Foundation
import XCTest
@testable import MozzPairing

final class CircleStoreTests: XCTestCase {
    private let circle = CircleSecrets(
        channelId: "ch_store",
        channelKey: Data(repeating: 0xA0, count: 32),
        credentialsKey: Data(repeating: 0xB0, count: 32),
        epoch: 4,
        relayKey: Data("relaykey".utf8))

    func testACircleSurvivesASaveAndLoad() throws {
        let store = CircleStore(secure: InMemoryStore(), plain: InMemoryStore())
        try store.save(circle)
        XCTAssertEqual(try store.load(), circle)
    }

    func testNothingIsStoredBeforePairing() throws {
        XCTAssertNil(try CircleStore(secure: InMemoryStore(), plain: InMemoryStore()).load())
    }

    /// The test the whole credential design rests on.
    ///
    /// If a refactor ever collapsed the two tiers into one blob, every other
    /// test here would still pass while the separation quietly disappeared.
    func testTheCredentialsKeyNeverTouchesPlainStorage() throws {
        let secure = InMemoryStore()
        let plain = InMemoryStore()
        try CircleStore(secure: secure, plain: plain).save(circle)

        for stored in plain.everythingStored {
            XCTAssertFalse(stored.range(of: circle.credentialsKey) != nil,
                           "the credentials key was found in plain storage")
            // Also as base64, since it is written through JSON.
            let encoded = Data(circle.credentialsKey.base64EncodedString().utf8)
            XCTAssertFalse(stored.range(of: encoded) != nil,
                           "the credentials key was found base64-encoded in plain storage")
        }
        XCTAssertFalse(secure.everythingStored.isEmpty, "and it must actually be somewhere")
    }

    func testTheChannelKeyIsInPlainStorageOnPurpose() throws {
        let plain = InMemoryStore()
        try CircleStore(secure: InMemoryStore(), plain: plain).save(circle)
        let encoded = Data(circle.channelKey.base64EncodedString().utf8)
        XCTAssertTrue(plain.everythingStored.contains { $0.range(of: encoded) != nil },
                      "the channel key belongs in ordinary storage; the tiers differ deliberately")
    }

    func testHalfACircleIsNoCircle() throws {
        let secure = InMemoryStore()
        let plain = InMemoryStore()
        let store = CircleStore(secure: secure, plain: plain)
        try store.save(circle)

        // A restore onto a new device can bring app data without the keychain.
        try secure.setSecret(nil, forKey: CircleStore.Key.credentials)
        XCTAssertNil(try store.load(),
                     "a partial circle would sync history while unable to read any server")
    }

    func testTheOtherHalfIsAlsoNoCircle() throws {
        let secure = InMemoryStore()
        let plain = InMemoryStore()
        let store = CircleStore(secure: secure, plain: plain)
        try store.save(circle)
        try plain.setValue(nil, forKey: CircleStore.Key.rest)
        XCTAssertNil(try store.load())
    }

    func testLeavingACircleRemovesBothHalves() throws {
        let secure = InMemoryStore()
        let plain = InMemoryStore()
        let store = CircleStore(secure: secure, plain: plain)
        try store.save(circle)
        try store.clear()

        XCTAssertNil(try store.load())
        XCTAssertNil(try secure.secret(forKey: CircleStore.Key.credentials))
        XCTAssertNil(try plain.value(forKey: CircleStore.Key.rest))
    }

    func testALoneDeviceFormsACircleWhenItNeedsOne() throws {
        let store = CircleStore(secure: InMemoryStore(), plain: InMemoryStore())
        XCTAssertNil(try store.load(), "nothing yet")

        let formed = try store.loadOrCreate()
        XCTAssertEqual(formed.epoch, 1)
        XCTAssertEqual(formed.channelKey.count, 32)
        XCTAssertEqual(formed.credentialsKey.count, 32)
        XCTAssertNotEqual(formed.channelKey, formed.credentialsKey)
        XCTAssertFalse(formed.channelId.isEmpty)
        // The relay key cannot exist before the relay is provisioned, and an
        // invented placeholder would be worse than an obviously absent one.
        XCTAssertTrue(formed.relayKey.isEmpty)

        XCTAssertEqual(try store.load(), formed, "and it was persisted, not just returned")
    }

    func testFormingACircleTwiceReturnsTheSameOne() throws {
        let store = CircleStore(secure: InMemoryStore(), plain: InMemoryStore())
        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()
        XCTAssertEqual(first, second, "a device must not silently replace the circle it is already in")
    }

    func testTwoCirclesDoNotCollide() throws {
        let one = try CircleStore(secure: InMemoryStore(), plain: InMemoryStore()).loadOrCreate()
        let two = try CircleStore(secure: InMemoryStore(), plain: InMemoryStore()).loadOrCreate()
        XCTAssertNotEqual(one.channelId, two.channelId)
        XCTAssertNotEqual(one.channelKey, two.channelKey)
    }

    func testRejoiningReplacesRatherThanAccumulates() throws {
        let store = CircleStore(secure: InMemoryStore(), plain: InMemoryStore())
        try store.save(circle)

        let second = CircleSecrets(channelId: "ch_other",
                                   channelKey: Data(repeating: 0x11, count: 32),
                                   credentialsKey: Data(repeating: 0x22, count: 32),
                                   epoch: 9,
                                   relayKey: Data("other".utf8))
        try store.save(second)
        XCTAssertEqual(try store.load(), second)
    }
}
