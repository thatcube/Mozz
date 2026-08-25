import Foundation
import Testing
@testable import MozzHistory

// Conformance against `spec/history/event-uid-fixtures.json`.
//
// Same reasoning as the continuity spec tests: every other test in this target
// compares our output to our own output, so all of them would still pass if the
// uid encoding changed underneath. These pin the absolute bytes and uids.
//
// The stakes here are subtler than continuity's. A changed uid does not throw —
// it makes every already-synced event look brand new, so the next sync
// re-imports the user's entire history as duplicates and every play is counted
// twice in their taste profile.

@Suite("History spec conformance")
struct HistorySpecConformanceTests {

    private struct Spec: Decodable {
        var version: Int
        var cases: [Case]
    }

    private struct Case: Decodable {
        var name: String
        var uid: String
        var canonicalBytesHex: String
        var canonicalByteCount: Int
        var input: Input
    }

    private struct Input: Decodable {
        var deviceID: String
        var trackRef: String
        var kind: String
        var createdAtMS: Int64
        var positionMS: Int64?
        var durationMS: Int64?
    }

    /// Read from `spec/` rather than a test-bundle resource, so this and any
    /// other implementation verify against the same file and it cannot drift.
    private static func loadSpec() throws -> Spec {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("spec/history/event-uid-fixtures.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try JSONDecoder().decode(Spec.self, from: Data(contentsOf: candidate))
            }
            directory = directory.deletingLastPathComponent()
        }
        throw SpecError.notFound
    }

    private enum SpecError: Error { case notFound }

    @Test("Canonical uid bytes match the spec fixtures exactly")
    func canonicalBytesMatchSpec() throws {
        let spec = try Self.loadSpec()
        #expect(spec.version == 1)
        #expect(!spec.cases.isEmpty)

        for fixture in spec.cases {
            let bytes = HistoryEvent.canonicalUIDBytes(
                deviceID: fixture.input.deviceID,
                trackRef: fixture.input.trackRef,
                kind: fixture.input.kind,
                createdAtMS: fixture.input.createdAtMS,
                positionMS: fixture.input.positionMS,
                durationMS: fixture.input.durationMS
            )
            let hex = bytes.map { String(format: "%02x", $0) }.joined()

            #expect(bytes.count == fixture.canonicalByteCount, "\(fixture.name): byte count drifted")
            #expect(
                hex == fixture.canonicalBytesHex,
                """
                \(fixture.name): uid encoding no longer matches spec/history.
                  expected: \(fixture.canonicalBytesHex)
                  actual:   \(hex)
                Changing this makes every already-synced event look new, so the
                next sync re-imports the user's whole history as duplicates and
                double-counts every play. If intentional, bump the "h1" prefix
                and add fixtures rather than editing these.
                """
            )
        }
    }

    @Test("Event uids match the spec fixtures exactly")
    func uidsMatchSpec() throws {
        for fixture in try Self.loadSpec().cases {
            let uid = HistoryEvent.makeUID(
                deviceID: fixture.input.deviceID,
                trackRef: fixture.input.trackRef,
                kind: fixture.input.kind,
                createdAtMS: fixture.input.createdAtMS,
                positionMS: fixture.input.positionMS,
                durationMS: fixture.input.durationMS
            )
            #expect(uid == fixture.uid, "\(fixture.name): expected \(fixture.uid), got \(uid)")
        }
    }

    @Test("Every uid is 32 lowercase hex characters")
    func uidShape() throws {
        for fixture in try Self.loadSpec().cases {
            #expect(fixture.uid.count == 32, "\(fixture.name): uid is not 128 bits of hex")
            #expect(
                fixture.uid.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                "\(fixture.name): uid must be lowercase hex"
            )
        }
    }

    @Test("Fixture uids are all distinct")
    func fixturesAreDistinct() throws {
        // Includes the position-0-vs-nil pair, so this fails if a reimplementation
        // ever conflates "no position recorded" with "position zero".
        let uids = try Self.loadSpec().cases.map(\.uid)
        #expect(Set(uids).count == uids.count, "two fixtures collide on the same uid")
    }
}
