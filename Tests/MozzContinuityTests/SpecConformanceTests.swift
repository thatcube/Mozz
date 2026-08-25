import Foundation
import MozzCore
import Testing
@testable import MozzContinuity

// Conformance against `spec/continuity/queue-hash-fixtures.json` — the
// language-neutral contract a non-Apple client must also satisfy.
//
// The other tests in this target are *relative*: same queue hashes the same,
// reordering changes it, and so on. Every one of them would still pass if the
// encoding changed wholesale, because they only ever compare our output to our
// own output. These tests pin the ABSOLUTE bytes and digests, so an accidental
// change to the encoding — a reordered field, a normalized string, a duration
// that became a Double — fails here instead of silently breaking continuity for
// everyone who already has a checkpoint stored on their server.

@Suite("Continuity spec conformance")
struct SpecConformanceTests {

    // MARK: Fixture model

    private struct Spec: Decodable {
        var version: Int
        var cases: [Case]
    }

    private struct Case: Decodable {
        var name: String
        var queueHash: String
        var canonicalBytesHex: String
        var canonicalByteCount: Int
        var input: Input
    }

    private struct Input: Decodable {
        var descriptor: Descriptor
        var items: [Item]
        var repeatMode: String
        var isShuffled: Bool
        var totalCount: Int
        var windowStartAbsoluteIndex: Int
    }

    private struct Descriptor: Decodable {
        var kind: String
        var sourceID: String?
        var sourceRevision: String?
    }

    private struct Item: Decodable {
        var backend: String
        var serverID: String
        var accountID: String
        var remoteID: String
        var baseOrdinal: Int
        var title: String
        var artist: String
        var durationMS: Int64
    }

    // MARK: Loading

    /// Walk up from this source file to the repository root. The fixtures are
    /// deliberately NOT a test-bundle resource: they belong to `spec/`, shared
    /// with every other implementation, and copying them into the bundle would
    /// create a second copy that could drift from the one other languages read.
    private static func specURL() -> URL {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory
                .appendingPathComponent("spec/continuity/queue-hash-fixtures.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: "spec/continuity/queue-hash-fixtures.json")
    }

    private static func loadSpec() throws -> Spec {
        let url = specURL()
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Spec.self, from: data)
    }

    // MARK: Rebuilding domain values from the fixture

    private func rebuild(_ input: Input) throws -> (
        items: [ContinuityItem],
        descriptor: QueueDescriptor,
        repeatMode: ContinuityRepeatMode,
        isShuffled: Bool,
        totalCount: Int,
        startAbsoluteIndex: Int
    ) {
        let kind = try #require(QueueDescriptor.Kind(rawValue: input.descriptor.kind))
        let mode = try #require(ContinuityRepeatMode(rawValue: input.repeatMode))
        let descriptor = QueueDescriptor(
            kind: kind,
            sourceID: input.descriptor.sourceID,
            sourceRevision: input.descriptor.sourceRevision
        )
        let items = try input.items.map { item in
            let backend = try #require(BackendKind(rawValue: item.backend))
            return ContinuityItem(
                locator: TrackLocator(
                    server: ServerAccountFingerprint(
                        backend: backend,
                        serverID: item.serverID,
                        accountID: item.accountID
                    ),
                    remoteID: item.remoteID
                ),
                baseOrdinal: item.baseOrdinal,
                title: item.title,
                artist: item.artist,
                durationMS: item.durationMS
            )
        }
        return (items, descriptor, mode, input.isShuffled,
                input.totalCount, input.windowStartAbsoluteIndex)
    }

    // MARK: Tests

    @Test("Canonical bytes match the spec fixtures exactly")
    func canonicalBytesMatchSpec() throws {
        let spec = try Self.loadSpec()
        #expect(spec.version == 1)
        #expect(!spec.cases.isEmpty)

        for fixture in spec.cases {
            let parts = try rebuild(fixture.input)
            let bytes = ContinuityQueueBuilder.canonicalBytes(
                items: parts.items,
                descriptor: parts.descriptor,
                repeatMode: parts.repeatMode,
                isShuffled: parts.isShuffled,
                totalCount: parts.totalCount,
                startAbsoluteIndex: parts.startAbsoluteIndex
            )
            let hex = bytes.map { String(format: "%02x", $0) }.joined()

            #expect(
                bytes.count == fixture.canonicalByteCount,
                "\(fixture.name): byte count drifted from the spec"
            )
            #expect(
                hex == fixture.canonicalBytesHex,
                """
                \(fixture.name): canonical encoding no longer matches spec/continuity.
                  expected: \(fixture.canonicalBytesHex)
                  actual:   \(hex)
                Changing the encoding invalidates every checkpoint already stored
                on users' servers. If this is intentional, bump the version prefix
                and add fixtures rather than editing the existing ones.
                """
            )
        }
    }

    @Test("Queue hashes match the spec fixtures exactly")
    func hashesMatchSpec() throws {
        let spec = try Self.loadSpec()

        for fixture in spec.cases {
            let parts = try rebuild(fixture.input)
            let hash = ContinuityQueueBuilder.hash(
                items: parts.items,
                descriptor: parts.descriptor,
                repeatMode: parts.repeatMode,
                isShuffled: parts.isShuffled,
                totalCount: parts.totalCount,
                startAbsoluteIndex: parts.startAbsoluteIndex
            )
            #expect(
                hash == fixture.queueHash,
                "\(fixture.name): expected \(fixture.queueHash), got \(hash)"
            )
        }
    }

    @Test("Every hash is a lowercase 64-character hex digest")
    func hashShape() throws {
        // A second implementation reading these has to know the shape is exact:
        // no uppercase, no 0x prefix, no truncation.
        for fixture in try Self.loadSpec().cases {
            #expect(fixture.queueHash.count == 64, "\(fixture.name): not a SHA-256 digest")
            #expect(
                fixture.queueHash.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                "\(fixture.name): digest must be lowercase hex"
            )
        }
    }

    @Test("Display metadata is absent from the canonical bytes")
    func displayMetadataExcluded() throws {
        // The spec promises re-fetching richer metadata cannot invalidate a
        // queue. Assert it against the fixtures' own titles rather than trusting
        // the prose: if a title ever leaked into the encoding, a metadata
        // backfill would silently break resume for every affected user.
        for fixture in try Self.loadSpec().cases {
            let bytes = Data(fixture.canonicalBytesHex.chunkedPairs.compactMap { UInt8($0, radix: 16) })
            let text = String(decoding: bytes, as: UTF8.self)
            for item in fixture.input.items where !item.title.isEmpty {
                #expect(
                    !text.contains(item.title),
                    "\(fixture.name): title '\(item.title)' leaked into the canonical bytes"
                )
            }
        }
    }
}

private extension String {
    /// Split a hex string into byte-sized pairs.
    var chunkedPairs: [String] {
        var pairs: [String] = []
        var index = startIndex
        while index < endIndex, let next = self.index(index, offsetBy: 2, limitedBy: endIndex) {
            pairs.append(String(self[index..<next]))
            index = next
        }
        return pairs
    }
}
