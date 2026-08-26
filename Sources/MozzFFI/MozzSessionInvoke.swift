import Foundation
import MozzCommands
import MozzDatabase
import MozzEnrichment

// The schema-generated command surface, over the C ABI.
//
// This sits beside `mozz_session_call` rather than replacing it. That one takes
// and returns a null-terminated C string, which is fine for JSON and impossible
// for protobuf: encoded messages contain 0x00 bytes freely, and a C string ends
// at the first one. So a binary command needs its own entry point that carries a
// length in both directions.
//
// Both doors reach the same core. The JSON one is what every shipping client
// still uses; commands move across as they are described in `schema/`, and the
// JSON door closes when the last one has. See ADR-0016.

/// Execute one schema-described command.
///
/// `request` is an encoded `mozz.v1.Request` of `requestLength` bytes. On return
/// the response length is written to `responseLength` and the buffer is
/// caller-owned — release it with `mozz_session_free_bytes`, NOT with
/// `mozz_ffi_free_string`, which would free a different allocation shape.
///
/// Never returns null for a failure that has anything to say: a failure is an
/// encoded `Response` carrying `Failure`, because a null here would leave the
/// caller guessing across a boundary where there is no exception to catch. Null
/// is reserved for "could not even allocate a reply".
@_cdecl("mozz_session_invoke")
public func mozz_session_invoke(
    _ handle: Int64,
    _ request: UnsafePointer<UInt8>?,
    _ requestLength: Int32,
    _ responseLength: UnsafeMutablePointer<Int32>?
) -> UnsafeMutablePointer<UInt8>? {
    guard let responseLength else { return nil }
    responseLength.pointee = 0

    guard let request, requestLength > 0 else {
        return copyInvokeBytes(CommandDispatcher.malformed("no request"), into: responseLength)
    }
    guard let session = SessionRegistry.shared.session(handle) else {
        return copyInvokeBytes(
            CommandDispatcher.malformed("unknown session handle"), into: responseLength)
    }

    let bytes = Data(UnsafeBufferPointer(start: request, count: Int(requestLength)))
    // Capture the enrichment seams as locals so the backend resolver is a small,
    // Sendable closure over the backend table rather than the whole session.
    let backends = session.backends
    let dispatcher = CommandDispatcher(
        service: LibraryCommandService(
            repository: session.repository,
            playbackSettings: PlaybackSettingsStore(session.database),
            downloads: DownloadStore(session.database),
            artwork: session.artworkStore,
            lyricsService: session.lyrics,
            enrichmentStore: EnrichmentStore(session.database),
            backendResolver: { backends.backend($0) },
            similarityAlgorithm: EnrichmentConfig.defaultListenBrainzAlgorithm,
            playback: session.playback))

    // `handle` is synchronous by design — see the note on `mozz_session_call`.
    // A host calling across a C ABI has no async to await into, so the bridge
    // blocks here rather than making every caller invent one.
    let response: Data
    do {
        response = try runBlockingSession { await dispatcher.handle(bytes) }
    } catch {
        response = CommandDispatcher.malformed(String(describing: error))
    }
    return copyInvokeBytes(response, into: responseLength)
}

/// Release a buffer from `mozz_session_invoke`.
///
/// Separate from `mozz_ffi_free_string` because the two allocate differently: a
/// string buffer is `CChar` and null-terminated, this one is raw `UInt8` with an
/// out-of-band length. Freeing either through the other's function is undefined,
/// so they are kept visibly distinct rather than conveniently merged.
@_cdecl("mozz_session_free_bytes")
public func mozz_session_free_bytes(_ pointer: UnsafeMutablePointer<UInt8>?) {
    pointer?.deallocate()
}

private func copyInvokeBytes(
    _ data: Data,
    into length: UnsafeMutablePointer<Int32>
) -> UnsafeMutablePointer<UInt8>? {
    // An empty response would otherwise allocate zero bytes and hand back a
    // pointer the caller must still free; report it as nothing instead.
    guard !data.isEmpty else {
        length.pointee = 0
        return nil
    }
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
    data.copyBytes(to: buffer, count: data.count)
    length.pointee = Int32(data.count)
    return buffer
}
