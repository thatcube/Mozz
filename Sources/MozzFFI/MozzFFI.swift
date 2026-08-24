#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import GRDB
import MozzContinuity
import MozzCore
import MozzDatabase

// MARK: - Mozz FFI spike facade
//
// PURPOSE: prove (or disprove) that the platform-free Swift core can be built as
// a C-ABI shared library on Windows and driven from a non-Swift host process.
// This is a SPIKE, not the production facade — see "Known compromises" below.
//
// What it is designed to answer, in order of importance:
//
//   1. Does MozzCore + MozzDatabase (+ GRDB) compile and link on Windows at all?
//   2. **Does the SQLite that GRDB links actually have FTS5 compiled in?**
//      Apple's system SQLite always does; other platforms' may not, and Mozz's
//      entire search story depends on it. `MusicDatabase.open()` runs migrations
//      that CREATE VIRTUAL TABLE ... USING fts5, so a missing FTS5 fails loudly
//      rather than silently degrading. `mozz_ffi_probe` also reports it directly.
//   3. Does `@_cdecl` + `DllImport` hold across the boundary?
//   4. What does marshalling actually cost at Mozz's scale?
//
// THE BOUNDARY RULES (these are why the API looks like this):
//
//   * Swift structs, classes, payload enums, and `async`/`await` DO NOT cross a
//     C ABI. Only C primitives and pointers do. So every entry point here takes
//     and returns C strings, and complex values are serialized.
//   * Serialization is JSON, deliberately: Mozz already requires RFC 8785
//     canonical JSON for continuity manifests (ADR-0010), so reusing JSON here
//     means ONE serialization strategy for the whole project, and every payload
//     stays inspectable and diffable in tests.
//   * Calls are COARSE-GRAINED. One call does a whole unit of work and returns a
//     whole result. Never one call per row — a per-row boundary crossing while
//     scrolling a 100k-row list is the failure mode this design exists to avoid.
//   * Ownership is explicit: every returned string is caller-owned and MUST be
//     released with `mozz_ffi_free_string`. Allocation and release are symmetric
//     (allocate/deallocate), so this is portable across platforms.
//
// KNOWN COMPROMISES (fine for a spike, NOT for production):
//
//   * `runBlocking` bridges async→sync by parking a thread on a semaphore. That
//     is exactly the anti-pattern a real facade must avoid; production should use
//     a callback or a polled event queue so the host's UI thread is never blocked.
//     It is used here only to keep the spike's surface tiny and measurable.
//   * Errors collapse to a message string rather than preserving typed errors.
//   * No cancellation.

// MARK: - Envelope

/// Every entry point returns this shape, so the host has exactly one thing to
/// parse and errors are never confused with results.
private struct Envelope<Payload: Encodable>: Encodable {
    var ok: Bool
    var payload: Payload?
    var error: String?
}

private func encodeEnvelope<Payload: Encodable>(_ envelope: Envelope<Payload>) -> UnsafeMutablePointer<CChar>? {
    let encoder = JSONEncoder()
    // Sorted keys so output is stable and diffable — the same discipline the
    // continuity manifests need, rehearsed here.
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(envelope),
          let json = String(data: data, encoding: .utf8) else {
        return copyToC(#"{"ok":false,"error":"failed to encode response"}"#)
    }
    return copyToC(json)
}

private func success<Payload: Encodable>(_ payload: Payload) -> UnsafeMutablePointer<CChar>? {
    encodeEnvelope(Envelope(ok: true, payload: payload, error: nil))
}

private func failure(_ message: String) -> UnsafeMutablePointer<CChar>? {
    encodeEnvelope(Envelope<String>(ok: false, payload: nil, error: message))
}

// MARK: - C string helpers

/// Copy a Swift string into a caller-owned C buffer. Released by
/// `mozz_ffi_free_string`; allocate/deallocate are symmetric and portable
/// (`strdup`/`free` would work too but differ subtly across platforms).
private func copyToC(_ string: String) -> UnsafeMutablePointer<CChar>? {
    let bytes = Array(string.utf8CString)
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
    buffer.update(from: bytes, count: bytes.count)
    return buffer
}

private func swiftString(_ pointer: UnsafePointer<CChar>?) -> String? {
    pointer.map { String(cString: $0) }
}

// MARK: - async → sync bridge (spike only)

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, any Error>?
}

/// Park the calling thread until an async body completes. See "Known
/// compromises" — production must not do this on a UI thread.
private func runBlocking<T: Sendable>(
    _ body: @escaping @Sendable () async throws -> T
) throws -> T {
    let box = ResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await body()) }
        catch { box.result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    switch box.result {
    case .success(let value): return value
    case .failure(let error): throw error
    case nil: throw MozzFFIError.noResult
    }
}

private enum MozzFFIError: LocalizedError {
    case noResult
    case missingArgument(String)

    var errorDescription: String? {
        switch self {
        case .noResult: return "async body produced no result"
        case .missingArgument(let name): return "missing required argument: \(name)"
        }
    }
}

// MARK: - 1. Liveness + environment probe

private struct Probe: Encodable {
    var swiftVersion: String
    var platform: String
    var sqliteVersion: String
    var hasFTS5: Bool
    var fts5CreateSucceeded: Bool
    var fts5Error: String?
}

/// Report what the linked SQLite can actually do. **This is the single most
/// important result of the spike**: `hasFTS5 == false` means Mozz's search layer
/// cannot work on this platform as built, and the SQLite dependency has to be
/// replaced or rebuilt before anything else matters.
@_cdecl("mozz_ffi_probe")
public func mozz_ffi_probe() -> UnsafeMutablePointer<CChar>? {
    #if os(Windows)
    let platform = "Windows"
    #elseif os(macOS)
    let platform = "macOS"
    #elseif os(Linux)
    let platform = "Linux"
    #elseif os(Android)
    let platform = "Android"
    #else
    let platform = "unknown"
    #endif

    #if swift(>=6.3)
    let swiftVersion = ">=6.3"
    #elseif swift(>=6.0)
    let swiftVersion = ">=6.0"
    #else
    let swiftVersion = "<6.0"
    #endif

    var sqliteVersion = "unknown"
    var compiledWithFTS5 = false
    var createSucceeded = false
    var fts5Error: String?

    do {
        // An in-memory database is enough to interrogate the SQLite build, and
        // avoids touching the filesystem.
        let queue = try DatabaseQueue()
        try queue.read { db in
            sqliteVersion = try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "unknown"
            // Compile-option reporting is advisory: some builds enable FTS5
            // without exposing the option, so the real test is creating a table.
            compiledWithFTS5 = (try Int.fetchOne(
                db, sql: "SELECT sqlite_compileoption_used('ENABLE_FTS5')"
            ) ?? 0) == 1
        }
        // The definitive check.
        try queue.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE fts5_probe USING fts5(content)")
            try db.execute(sql: "DROP TABLE fts5_probe")
        }
        createSucceeded = true
    } catch {
        fts5Error = String(describing: error)
    }

    return success(Probe(
        swiftVersion: swiftVersion,
        platform: platform,
        sqliteVersion: sqliteVersion,
        hasFTS5: compiledWithFTS5 || createSucceeded,
        fts5CreateSucceeded: createSucceeded,
        fts5Error: fts5Error
    ))
}

// MARK: - 2. Full benchmark

private struct BenchmarkResult: Encodable {
    var metrics: PerformanceHarness.Metrics
    var summary: String
    var openMs: Double
    var coldReopenMs: Double
}

/// Generate a synthetic catalog at `trackCount` scale and measure the read path
/// — the same `PerformanceHarness` the iOS app and the host XCTests use, so the
/// numbers are directly comparable to the published iOS results.
///
/// Coarse-grained on purpose: one call performs seconds of work and returns one
/// JSON document, so the boundary cost is irrelevant here by construction.
@_cdecl("mozz_ffi_benchmark")
public func mozz_ffi_benchmark(
    _ dbPath: UnsafePointer<CChar>?,
    _ trackCount: Int32
) -> UnsafeMutablePointer<CChar>? {
    guard let path = swiftString(dbPath), !path.isEmpty else {
        return failure(MozzFFIError.missingArgument("dbPath").localizedDescription)
    }

    // Scale artists/albums with tracks, holding the iOS benchmark's ratios
    // (2,000 artists / 10,000 albums / 100,000 tracks).
    let tracks = max(100, Int(trackCount))
    let size = SyntheticCatalog.Size(
        artists: max(10, tracks / 50),
        albums: max(20, tracks / 10),
        tracks: tracks
    )

    do {
        let result = try runBlocking { () async throws -> BenchmarkResult in
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.removeItem(at: url)

            // Time the initial open — this also runs the migrations, which is
            // where a missing FTS5 will blow up.
            let openStart = Date()
            let database = try MusicDatabase.open(at: url)
            let openMs = Date().timeIntervalSince(openStart) * 1000

            let harness = PerformanceHarness(database)
            let serverId = SyntheticCatalog.defaultServerID
            let generationSeconds = try await harness.generate(serverId: serverId, size: size)

            // Cold reopen on the now-populated file, matching how the iOS
            // numbers measure cold-open cost.
            let coldStart = Date()
            let reopened = try MusicDatabase.open(at: url)
            _ = try await reopened.trackCount()
            let coldReopenMs = Date().timeIntervalSince(coldStart) * 1000

            let metrics = try await PerformanceHarness(reopened).measureReads(
                serverId: serverId,
                generationSeconds: generationSeconds,
                coldOpenMs: coldReopenMs
            )
            return BenchmarkResult(
                metrics: metrics,
                summary: metrics.summary,
                openMs: openMs,
                coldReopenMs: coldReopenMs
            )
        }
        return success(result)
    } catch {
        return failure(String(describing: error))
    }
}

// MARK: - 3. Marshalling cost

private struct SearchResult: Encodable {
    var queryPlan: [String]
    var query: String
    var artists: Int
    var albums: Int
    var tracks: Int
    var openMs: Double
    var queryMs: Double
    var encodeMs: Double
    var payloadBytes: Int
    var titles: [String]
}

/// Run one FTS search and report open, query and encode times *separately*.
///
/// The split is the point: it isolates what the FFI boundary actually adds on
/// top of the database work. If `encodeMs` is a small fraction of `queryMs`,
/// JSON at the boundary is free in practice and the design holds.
///
/// `openMs` is reported on its own because this entry point is deliberately
/// stateless — it opens the database on every call. Folding that into `queryMs`
/// would inflate the denominator and flatter the encode ratio, so the host
/// compares encode against *pure query* time. (A production facade would open
/// once and hold a handle, making this cost vanish entirely.)
@_cdecl("mozz_ffi_search")
public func mozz_ffi_search(
    _ dbPath: UnsafePointer<CChar>?,
    _ query: UnsafePointer<CChar>?,
    _ limit: Int32
) -> UnsafeMutablePointer<CChar>? {
    guard let path = swiftString(dbPath), !path.isEmpty else {
        return failure(MozzFFIError.missingArgument("dbPath").localizedDescription)
    }
    guard let term = swiftString(query), !term.isEmpty else {
        return failure(MozzFFIError.missingArgument("query").localizedDescription)
    }

    do {
        let result = try runBlocking { () async throws -> SearchResult in
            let openStart = Date()
            let database = try MusicDatabase.open(at: URL(fileURLWithPath: path))
            let repository = LibraryRepository(database)
            let openMs = Date().timeIntervalSince(openStart) * 1000

            let queryStart = Date()
            let results = try await repository.search(
                term,
                serverId: SyntheticCatalog.defaultServerID,
                limitPerType: max(1, Int(limit))
            )
            let queryMs = Date().timeIntervalSince(queryStart) * 1000

            let encodeStart = Date()
            let titles = results.tracks.map(\.title)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let payload = (try? encoder.encode(titles)) ?? Data()
            let encodeMs = Date().timeIntervalSince(encodeStart) * 1000

            // The plan is the diagnostic that matters when a search is fast on
            // one platform and pathological on another: a stopwatch says "slow",
            // the plan says *why*.
            let plan = (try? await repository.searchQueryPlan(
                term, serverId: SyntheticCatalog.defaultServerID
            )) ?? []

            return SearchResult(
                queryPlan: plan,
                query: term,
                artists: results.artists.count,
                albums: results.albums.count,
                tracks: results.tracks.count,
                openMs: openMs,
                queryMs: queryMs,
                encodeMs: encodeMs,
                payloadBytes: payload.count,
                titles: Array(titles.prefix(5))
            )
        }
        return success(result)
    } catch {
        return failure(String(describing: error))
    }
}

// MARK: - 4. Continuity hash conformance

private struct HashCase: Encodable {
    var name: String
    var expectedHash: String
    var actualHash: String
    var expectedBytesHex: String
    var actualBytesHex: String
    var matches: Bool
}

/// Recompute the `spec/continuity` fixtures on *this* platform.
///
/// This is the point of the whole exercise. ADR-0010 requires a non-Apple peer
/// to derive byte-identical queue hashes, otherwise a device reads a queue,
/// disagrees with its own cursor, and continuity fails silently. Running the
/// shared fixtures here proves the property on the platform that actually has to
/// hold it — rather than on a Mac, where it was never in doubt.
///
/// Takes the fixture JSON as a string so the host owns file IO and this stays a
/// pure function of its input.
@_cdecl("mozz_ffi_verify_continuity_hashes")
public func mozz_ffi_verify_continuity_hashes(
    _ fixturesJSON: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let json = swiftString(fixturesJSON), !json.isEmpty else {
        return failure(MozzFFIError.missingArgument("fixturesJSON").localizedDescription)
    }

    struct Spec: Decodable {
        var version: Int
        var cases: [Fixture]
    }
    struct Fixture: Decodable {
        var name: String
        var queueHash: String
        var canonicalBytesHex: String
        var input: Input
    }
    struct Input: Decodable {
        var descriptor: Descriptor
        var items: [Item]
        var repeatMode: String
        var isShuffled: Bool
        var totalCount: Int
        var windowStartAbsoluteIndex: Int
    }
    struct Descriptor: Decodable {
        var kind: String
        var sourceID: String?
        var sourceRevision: String?
    }
    struct Item: Decodable {
        var backend: String
        var serverID: String
        var accountID: String
        var remoteID: String
        var baseOrdinal: Int
        var title: String
        var artist: String
        var durationMS: Int64
    }

    do {
        let spec = try JSONDecoder().decode(Spec.self, from: Data(json.utf8))
        var results: [HashCase] = []

        for fixture in spec.cases {
            guard let kind = QueueDescriptor.Kind(rawValue: fixture.input.descriptor.kind),
                  let mode = ContinuityRepeatMode(rawValue: fixture.input.repeatMode) else {
                return failure("unknown descriptor kind or repeat mode in '\(fixture.name)'")
            }
            let descriptor = QueueDescriptor(
                kind: kind,
                sourceID: fixture.input.descriptor.sourceID,
                sourceRevision: fixture.input.descriptor.sourceRevision
            )
            var items: [ContinuityItem] = []
            for raw in fixture.input.items {
                guard let backend = BackendKind(rawValue: raw.backend) else {
                    return failure("unknown backend '\(raw.backend)' in '\(fixture.name)'")
                }
                items.append(ContinuityItem(
                    locator: TrackLocator(
                        server: ServerAccountFingerprint(
                            backend: backend,
                            serverID: raw.serverID,
                            accountID: raw.accountID
                        ),
                        remoteID: raw.remoteID
                    ),
                    baseOrdinal: raw.baseOrdinal,
                    title: raw.title,
                    artist: raw.artist,
                    durationMS: raw.durationMS
                ))
            }

            let bytes = ContinuityQueueBuilder.canonicalBytes(
                items: items,
                descriptor: descriptor,
                repeatMode: mode,
                isShuffled: fixture.input.isShuffled,
                totalCount: fixture.input.totalCount,
                startAbsoluteIndex: fixture.input.windowStartAbsoluteIndex
            )
            let hash = ContinuityQueueBuilder.hash(
                items: items,
                descriptor: descriptor,
                repeatMode: mode,
                isShuffled: fixture.input.isShuffled,
                totalCount: fixture.input.totalCount,
                startAbsoluteIndex: fixture.input.windowStartAbsoluteIndex
            )
            let hex = bytes.map { String(format: "%02x", $0) }.joined()

            results.append(HashCase(
                name: fixture.name,
                expectedHash: fixture.queueHash,
                actualHash: hash,
                expectedBytesHex: fixture.canonicalBytesHex,
                actualBytesHex: hex,
                matches: hash == fixture.queueHash && hex == fixture.canonicalBytesHex
            ))
        }
        return success(results)
    } catch {
        return failure(String(describing: error))
    }
}

// MARK: - 5. HPKE availability

private struct HPKEProbe: Encodable {
    var available: Bool
    var suite: String
    var roundTripped: Bool
    var rejectsWrongRecipient: Bool
    var error: String?
}

/// Determine whether HPKE (RFC 9180) actually works on this platform.
///
/// ADR-0013 puts the pairing crypto in the shared Swift core so there is one
/// implementation for iOS, macOS, Windows and Android. That rests on an
/// assumption: swift-crypto *contains* HPKE, but parts of its surface are gated
/// on platform primitives, and whether it functions off-Apple is not documented.
///
/// If this returns `available: false` on Windows, the pairing crypto cannot live
/// in the core and each platform needs its own implementation — which is a very
/// different project. Exactly the shape of the FTS5 question, and settled the
/// same way: by running it.
///
/// Two things are checked, because "it compiled" is not the question:
///   1. A seal/open round trip returns the original plaintext.
///   2. A *different* recipient key fails to open it — so the test cannot pass
///      by accident on a stub that returns its input.
@_cdecl("mozz_ffi_probe_hpke")
public func mozz_ffi_probe_hpke() -> UnsafeMutablePointer<CChar>? {
    let suiteName = "Curve25519_SHA256_ChachaPoly"
    let plaintext = Data("mozz-pairing-probe".utf8)
    let info = Data("mozz-pairing-probe-info-v1".utf8)
    let aad = Data("mozz-pairing-probe-aad-v1".utf8)

    do {
        let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

        let recipientKey = Curve25519.KeyAgreement.PrivateKey()
        var sender = try HPKE.Sender(
            recipientKey: recipientKey.publicKey,
            ciphersuite: suite,
            info: info
        )
        let ciphertext = try sender.seal(plaintext, authenticating: aad)
        let encapsulated = sender.encapsulatedKey

        var recipient = try HPKE.Recipient(
            privateKey: recipientKey,
            ciphersuite: suite,
            info: info,
            encapsulatedKey: encapsulated
        )
        let opened = try recipient.open(ciphertext, authenticating: aad)
        let roundTripped = opened == plaintext

        // A wrong key must fail. Without this the probe would pass against an
        // implementation that quietly did nothing.
        var rejected = false
        do {
            let wrongKey = Curve25519.KeyAgreement.PrivateKey()
            var wrong = try HPKE.Recipient(
                privateKey: wrongKey,
                ciphersuite: suite,
                info: info,
                encapsulatedKey: encapsulated
            )
            _ = try wrong.open(ciphertext, authenticating: aad)
        } catch {
            rejected = true
        }

        return success(HPKEProbe(
            available: roundTripped && rejected,
            suite: suiteName,
            roundTripped: roundTripped,
            rejectsWrongRecipient: rejected,
            error: nil
        ))
    } catch {
        return success(HPKEProbe(
            available: false,
            suite: suiteName,
            roundTripped: false,
            rejectsWrongRecipient: false,
            error: String(describing: error)
        ))
    }
}

// MARK: - 6. Lifetime

/// Release a string returned by any function above. Every returned pointer must
/// be passed here exactly once.
@_cdecl("mozz_ffi_free_string")
public func mozz_ffi_free_string(_ pointer: UnsafeMutablePointer<CChar>?) {
    pointer?.deallocate()
}
