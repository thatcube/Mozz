import Foundation
import MozzContinuity
import MozzCore
import MozzPlayback

/// A cross-device resume offer, ready to show the user.
public struct ContinuityOffer: Sendable, Identifiable {
    public var id: String { snapshot.cursor.current.remoteID + "@\(snapshot.cursor.capturedAtMS)" }
    public var snapshot: ContinuitySnapshot
    public var title: String
    public var artist: String
    /// Cover art for the track being offered, resolved against the active
    /// backend on this device — the stored queue carries only a reference, so
    /// the URL is minted locally and stays valid across token rotation.
    public var artwork: ArtworkRef?
    /// Device label, or nil where the backend cannot attribute a checkpoint —
    /// Subsonic's only signal is the client *product* name, which is identical
    /// for every Mozz install.
    public var deviceName: String?
    /// True when only the track and position survived: the queue could not be
    /// paired with the cursor, or the backend cannot store one.
    public var isTrackOnly: Bool
}

/// Drives cross-device playback continuity (ADR-0010).
///
/// Owns the two halves that must never be conflated:
/// - **Publishing** this device's checkpoint, debounced, so another device can
///   pick it up.
/// - **Offering** a remote checkpoint as "Continue here".
///
/// The governing rule is enforced here: nothing read from a store may stop
/// playback or make a playing device yield. A remote checkpoint only ever
/// becomes an *offer* the user can decline.
@MainActor
public final class ContinuityCoordinator: ObservableObject {
    @Published public private(set) var offer: ContinuityOffer?

    private var store: (any ContinuityStore)?
    private var deviceID: String = ""
    private var deviceName: String = ""

    /// Writes are suppressed until the first reconcile completes.
    ///
    /// Without this, cold launch restores the *local* session and would publish
    /// it immediately — overwriting a newer checkpoint another device wrote
    /// while this one was asleep. That is exactly the blind flush the ADR
    /// forbids.
    private var hasReconciled = false
    private var pending: (cursor: ContinuityCursor, queue: ContinuityQueue?)?
    private var flushTask: Task<Void, Never>?
    private var lastWrittenQueueHash: String?

    /// Checkpoints older than this are not offered. Subsonic can store neither a
    /// playback state nor a presence lease, so age is the only signal there.
    private let maxOfferAge: TimeInterval = 60 * 60 * 24 * 14

    public init() {}

    // MARK: Lifecycle

    /// Point the coordinator at a signed-in server, or clear it on sign-out.
    public func activate(store: (any ContinuityStore)?, deviceID: String, deviceName: String) {
        self.store = store
        self.deviceID = deviceID
        self.deviceName = deviceName
        hasReconciled = false
        offer = nil
        lastWrittenQueueHash = nil
    }

    /// Fetch the remote checkpoint and decide whether to offer it.
    ///
    /// Runs on activation and whenever the app returns to the foreground: an
    /// idle device has to refresh its view, otherwise a phone paused in a pocket
    /// while another device took over comes back showing stale state and
    /// clobbers the newer session on its next write.
    public func reconcile(isPlayingLocally: Bool) async {
        guard let store else {
            hasReconciled = true
            return
        }
        let loaded = try? await store.load()
        hasReconciled = true
        guard let snapshot = loaded else { return }
        let cursor = snapshot.cursor

        // Never offer to continue what this device itself last wrote.
        if !cursor.deviceID.isEmpty, cursor.deviceID == deviceID { return }
        if cursor.capturedAtMS > 0,
           Date().timeIntervalSince(cursor.capturedAt) > maxOfferAge { return }
        // A device that is actively playing is never interrupted — an offer
        // there would be inviting the user to stop what they are listening to.
        if isPlayingLocally { return }

        let item = snapshot.queue?.items.first {
            $0.locator.remoteID == cursor.current.remoteID
        }
        offer = ContinuityOffer(
            snapshot: snapshot,
            title: item?.title ?? "",
            artist: item?.artist ?? "",
            artwork: item?.artwork,
            deviceName: store.features.deviceAttribution && !cursor.deviceName.isEmpty
                ? cursor.deviceName
                : nil,
            isTrackOnly: snapshot.queue == nil
        )
    }

    public func dismissOffer() { offer = nil }

    // MARK: Publishing

    /// Record a checkpoint from the engine. Debounced; safe to call often.
    public func record(_ checkpoint: PlaybackCheckpoint, fingerprint: ServerAccountFingerprint) {
        guard let store, hasReconciled else { return }
        guard let current = checkpoint.queue.current else { return }

        let items = ContinuityMapper.items(from: checkpoint.queue, fingerprint: fingerprint)
        guard !items.isEmpty else { return }

        let queue = ContinuityQueueBuilder.make(
            items: items,
            descriptor: .adHoc,
            repeatMode: ContinuityMapper.repeatMode(checkpoint.queue.repeatMode),
            isShuffled: checkpoint.queue.isShuffled,
            totalCount: items.count
        )
        let cursor = ContinuityCursor(
            playbackRunID: checkpoint.runID,
            deviceID: deviceID,
            deviceName: deviceName,
            cursorSequence: checkpoint.sequence,
            capturedAtMS: Int64(Date().timeIntervalSince1970 * 1000),
            state: ContinuityMapper.state(checkpoint.status),
            current: TrackLocator(server: fingerprint, remoteID: current.id),
            currentAbsoluteIndex: max(checkpoint.queue.position, 0),
            positionMS: Int64(max(checkpoint.elapsed, 0) * 1000),
            queueHash: store.features.storesQueue ? queue.queueHash : nil
        )

        // Only resend the queue when it actually changed. Subsonic sends both in
        // one call regardless, but on Jellyfin this is what stops a 20-second
        // cursor write from dragging the whole queue across the network.
        let queueChanged = queue.queueHash != lastWrittenQueueHash
        pending = (cursor, queueChanged || store.features.truncatesQueue ? queue : nil)
        scheduleFlush(immediate: checkpoint.reason != .periodic)
    }

    private func scheduleFlush(immediate: Bool) {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
            }
            await self?.flush()
        }
    }

    private func flush() async {
        guard let store, let pending else { return }
        self.pending = nil
        do {
            try await store.save(pending.cursor, queue: pending.queue)
            if let queue = pending.queue { lastWrittenQueueHash = queue.queueHash }
        } catch {
            // Not worth surfacing or retrying: the next checkpoint carries
            // strictly newer state.
        }
    }

    /// Force any pending write out — used when backgrounding, which may be the
    /// last chance to run.
    public func flushNow() async {
        flushTask?.cancel()
        await flush()
    }
}
