import Foundation
import MozzContinuity
import MozzCore
import MozzNetworking

// MARK: - DTOs

/// `getPlayQueue` payload.
///
/// The entries are full song children, so a queue read from the server arrives
/// already hydrated — there is no need to resolve tracks one at a time, which
/// would be an N+1 storm on a queue of any size.
struct SubsonicPlayQueueDTO: Decodable {
    let entry: [SubsonicChild]?
    let current: String?
    /// Milliseconds.
    let position: Int64?
    let username: String?
    let changed: String?
    /// The `c=` client name of whoever last saved. Note this is a *product*
    /// name, not a device — two installs of Mozz are indistinguishable, and LMS
    /// hardcodes it to the empty string.
    let changedBy: String?

    enum CodingKeys: String, CodingKey {
        case entry, current, position, username, changed, changedBy
    }
}

struct SubsonicPlayQueueEnvelope: Decodable {
    let playQueue: SubsonicPlayQueueDTO?
}

// MARK: - Store

/// Cross-device continuity backed by Subsonic's `savePlayQueue`/`getPlayQueue`
/// (ADR-0010).
///
/// This is the highest-fidelity durable path Mozz has, because the Subsonic
/// protocol has a purpose-built endpoint for exactly this feature — and because
/// other clients use it too, a queue saved here can be picked up by a desktop
/// Subsonic client with no Mozz-specific software involved.
///
/// Its limits are protocol limits, not implementation shortcuts:
/// - **One queue per user**, so it is inherently last-writer-wins. Safe only
///   because a stored checkpoint never decides who owns playback (ADR-0010 §0).
/// - **No free-form field**, so there is no room for a device id, a run id, or a
///   playback state. Attribution and presence are simply unavailable.
/// - **Sent as repeated `id=` parameters on a GET URL**, so a long queue must be
///   windowed to a byte budget.
public struct SubsonicContinuityStore: ContinuityStore {
    private let client: SubsonicClient
    private let fingerprint: ServerAccountFingerprint
    /// Whether the server advertises OpenSubsonic's `indexBasedQueue`, which
    /// resolves duplicate tracks correctly. Classic servers identify the current
    /// item by track id and therefore cannot.
    private let supportsIndexBasedQueue: Bool

    public init(
        client: SubsonicClient,
        fingerprint: ServerAccountFingerprint,
        supportsIndexBasedQueue: Bool
    ) {
        self.client = client
        self.fingerprint = fingerprint
        self.supportsIndexBasedQueue = supportsIndexBasedQueue
    }

    public var features: ContinuityFeatures {
        ContinuityFeatures(
            richCursor: false,
            storesQueue: true,
            deviceAttribution: false,
            truncatesQueue: true
        )
    }

    // MARK: Load

    public func load() async throws -> ContinuitySnapshot? {
        let body: SubsonicResponseBody<SubsonicPlayQueueEnvelope>
        do {
            body = try await client.send("getPlayQueue", as: SubsonicPlayQueueEnvelope.self)
        } catch MozzError.notFound {
            return nil          // server doesn't implement the endpoint
        } catch MozzError.unsupported {
            return nil
        }
        guard let dto = body.payload.playQueue,
              let entries = dto.entry, !entries.isEmpty else { return nil }

        let tracks = entries.map(SubsonicMapper.track)
        let currentIndex = resolveCurrentIndex(dto.current, in: tracks)

        let items = tracks.enumerated().map { index, track in
            ContinuityItem(
                locator: TrackLocator(server: fingerprint, remoteID: track.id),
                // The server stores only the realized order, so the base order
                // is taken to be the same. A handoff *from* Subsonic therefore
                // cannot un-shuffle — an honest consequence of the protocol
                // having nowhere to put the original ordering.
                baseOrdinal: index,
                title: track.title,
                artist: track.artistName,
                durationMS: Int64(track.duration * 1000),
                artwork: track.artwork
            )
        }
        let queue = ContinuityQueueBuilder.make(
            items: items,
            descriptor: .adHoc,
            repeatMode: .off,
            isShuffled: false,
            totalCount: items.count
        )
        let cursor = ContinuityCursor(
            playbackRunID: UUID(),
            // No device identity is recoverable; `changedBy` is a product name.
            deviceID: "",
            deviceName: dto.changedBy ?? "",
            cursorSequence: 0,
            capturedAtMS: Self.parseChanged(dto.changed),
            // Subsonic cannot store a transport state. `paused` is the honest
            // reading: something was queued, and we cannot claim it is playing.
            state: .paused,
            current: TrackLocator(
                server: fingerprint,
                remoteID: tracks.indices.contains(currentIndex) ? tracks[currentIndex].id : tracks[0].id
            ),
            currentAbsoluteIndex: currentIndex,
            positionMS: dto.position ?? 0,
            queueHash: queue.queueHash
        )
        var hydrated: [String: Track] = [:]
        for track in tracks { hydrated[track.id] = track }
        return ContinuitySnapshot(cursor: cursor, queue: queue, hydrated: hydrated)
    }

    /// `current` is a track **id** on classic servers, but an **index** under
    /// the `indexBasedQueue` extension. Handle both, and fall back to the first
    /// item rather than failing.
    private func resolveCurrentIndex(_ current: String?, in tracks: [Track]) -> Int {
        guard let current, !current.isEmpty else { return 0 }
        if supportsIndexBasedQueue, let index = Int(current),
           tracks.indices.contains(index) {
            return index
        }
        if let index = tracks.firstIndex(where: { $0.id == current }) { return index }
        // An id that also parses as an index — try that before giving up.
        if let index = Int(current), tracks.indices.contains(index) { return index }
        return 0
    }

    private static func parseChanged(_ raw: String?) -> Int64 {
        guard let raw, !raw.isEmpty else { return 0 }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return Int64(date.timeIntervalSince1970 * 1000) }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return Int64(date.timeIntervalSince1970 * 1000) }
        return 0
    }

    // MARK: Save

    public func save(_ cursor: ContinuityCursor, queue: ContinuityQueue?) async throws {
        guard let queue, !queue.items.isEmpty else {
            // "Clear" is deliberately not expressed as an empty save: gonic
            // rejects that with error 10. A stale queue is aged out by the
            // freshness cutoff in the UI instead.
            return
        }

        let localIndex = cursor.currentAbsoluteIndex - queue.startAbsoluteIndex
        let window = ContinuityQueueBuilder.window(
            itemCount: queue.items.count,
            currentIndex: localIndex,
            encodedLength: { Self.encodedLength(queue.items[$0].locator.remoteID) }
        )
        let windowed = Array(queue.items[window.range])
        guard !windowed.isEmpty else { return }

        let currentWithinWindow = min(max(localIndex - window.range.lowerBound, 0), windowed.count - 1)
        var query = windowed.map { URLQueryItem(name: "id", value: $0.locator.remoteID) }
        query.append(URLQueryItem(
            name: "current",
            value: supportsIndexBasedQueue
                ? String(currentWithinWindow)
                : windowed[currentWithinWindow].locator.remoteID
        ))
        query.append(URLQueryItem(name: "position", value: String(cursor.positionMS)))
        try await client.send("savePlayQueue", query: query, as: SubsonicEmpty.self)
    }

    /// Byte cost of one `&id=<value>` parameter, percent-encoding included.
    static func encodedLength(_ remoteID: String) -> Int {
        let encoded = remoteID.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        ) ?? remoteID
        return encoded.utf8.count + 4   // "&id="
    }
}
