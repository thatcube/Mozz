# ADR-0010 — Cross-device playback continuity (session handoff)

Status: **Accepted** (fourth draft; source-verified against all three backends and
revised through four independent design reviews).

## Context

From a r/selfhosted thread on what self-hosted music is missing versus Spotify:

> if you're playing a track on one device and open Spotify on a second device, it
> will usually ask if you want to listen on the new device. If you say yes, it
> seamlessly ends the playback on the first device and starts it on the second
> one. […] you can only have a single playback session going on in Spotify, and
> you can very easily move that session between devices.

| # | Capability | Needs | Latency tolerance |
| --- | --- | --- | --- |
| C1 | "Continue here" — open on device B, resume where A was | durable state | seconds |
| C2 | Live progress mirroring | live channel | none |
| C3 | Device picker — push playback to another device | live channel + target awake | none |
| C4 | Single-session — A stops when B takes over | atomic ownership | seconds |

The target scenario is explicitly **off-network**: listening on cellular away from
home, then coming home and booting a **PC**, which should know what was playing.
Pure-offline listening is out of scope until reconnect.

That rules out iCloud (CloudKit / KV / synced Keychain) for durable state — Apple
devices only, so a PC can never read it, and the entitlement cannot be provisioned
headlessly, which would break the per-branch headless deploy exactly as App Groups
did. **Durable state lives on the user's own server.**

## Findings that constrain the design

Verified against upstream source, not documentation.

### No supported server persists a resume position for music

| Server | Evidence | Position? |
| --- | --- | --- |
| **Jellyfin** | `Audio` never overrides `SupportsPositionTicksResume` (inherits `=> false`); `UserDataManager.UpdatePlayState` runs `if (!item.SupportsPositionTicksResume) { positionTicks = 0; }` before writing | **No — always 0** |
| **Plex** | `viewOffset` absent from `Track` records in `/status/sessions/history/all`; live sessions only. "Store Track Progress" reported broken for audio (`plexinc/plex-media-player#738`) | **No** |
| **Subsonic** | `scrobble` has no position parameter | **No** |

An earlier draft proposed recovering position from play history. It is dead — and
"most recently played" means most recently *scrobbled/completed*, not what was
playing when playback stopped, and the account is shared with every other client
the user runs. **Mozz must write its own checkpoint.**

### Other decisive negatives

- **Jellyfin `NowPlayingQueue` is in-memory only**, lost on disconnect.
- **Plex play queues are ephemeral and client-scoped**; `own=1` *transfers
  ownership* rather than reading. Plex cannot be a durable store.
- **Jellyfin `DisplayPreferences` has no list endpoint** — only `GET/POST /{id}`.
  Anything requiring enumeration (sweeping orphans, discovering other devices'
  records) is impossible.
- **A suspended iOS app cannot be a cast target.** iOS tears down `NWListener` and
  its Bonjour advertisement at suspension; there is no socket-wake for third-party
  apps. Spotify's own iOS app behaves identically. Waking a cold device needs APNs
  — a provider server the user must run and pay for. Cut.
- **Shuffle cannot be reconstructed from a seed.** `PlayQueue.balancedOrder` is a
  balanced shuffle keyed on artist then album, biased per track by device-local
  **recency and taste scores**. The realized order must be sent verbatim.
- **No substrate offers compare-and-swap.** Strict single-session is impossible
  without extra infrastructure the user would have to host.

## Decision

### 0. Governing rules

1. **Durable state carries resume information only — never ownership.** No device
   is ever stopped, and never yields playback, because of something read from a
   store. Stopping happens only over a live authenticated channel.
2. **A device that is actively playing never yields.** A device that is *idle or
   paused* reconciles its view on foreground — otherwise a paused phone resurfacing
   from a pocket shows stale state and, on play, clobbers the device that took over.
3. **C4 is not guaranteed anywhere** and is never presented as "single session".

### 1. Storage model: fixed keys, graceful degradation

Earlier drafts used content-addressed manifests with a GC sweep. That is withdrawn:
it races (device B's sweeper can delete a manifest between device A's manifest and
cursor writes, leaving a dangling pointer) and on Jellyfin it is unimplementable
anyway, since orphans cannot be enumerated.

Instead, **fixed keys, one shared slot, last-writer-wins**, with the linkage made
safe by degradation rather than atomicity:

| Record | Key | Written | Size |
| --- | --- | --- | --- |
| Cursor | `mozz.continuity.cursor` | often | small |
| Queue | `mozz.continuity.queue` | on queue change only | large |

The cursor carries `queueHash`. **If a reader finds a cursor whose `queueHash` does
not match the stored queue, it degrades to track + position** — still a useful
resume — rather than failing or following a dangling pointer. No GC, no
enumeration, no sweeping, no unbounded growth.

Last-writer-wins on a single shared slot is safe *because of rule 0.1*: the slot is
a resume hint, never an authority. Per-device records and competing candidates
("iPhone, 2 min ago · Mac, yesterday") are **deferred** — they require enumeration
Jellyfin cannot do, and Subsonic's single per-user queue cannot express them at all,
so they would produce divergent UX across backends.

### 2. Types

All wire types live in a new **`MozzContinuity`** module. Times and positions are
**integer milliseconds** — never floating point — so a future PC peer can compute
identical hashes.

```swift
public struct ServerAccountFingerprint: Codable, Sendable, Hashable {
    public var backend: BackendKind
    public var serverID: String    // Jellyfin System/Info/Public .Id; Plex machineIdentifier
    public var accountID: String   // Jellyfin userId; Plex account id; Subsonic username
}

public struct TrackLocator: Codable, Sendable, Hashable {
    public var server: ServerAccountFingerprint
    public var remoteID: String    // the provider id; == Track.id within that server
}

public struct ContinuityCursor: Codable, Sendable {
    public var playbackRunID: UUID     // NOT PlaybackReport.sessionID (that is the stream id)
    public var deviceID: String        // domain-separated hash of clientIdentifier
    public var deviceName: String
    public var cursorSequence: UInt64  // monotonic within one playbackRunID
    public var capturedAtMS: Int64     // freshness only, never authority
    public var state: ContinuityPlaybackState
    public var current: TrackLocator
    public var currentAbsoluteIndex: Int   // resolves duplicate occurrences
    public var positionMS: Int64
    public var queueHash: String?      // links to the queue record; nil = track-only
}

public struct ContinuityQueue: Codable, Sendable {
    public var queueHash: String
    public var descriptor: QueueDescriptor      // source kind + id + source revision
    public var items: [ContinuityItem]          // realized playback order, verbatim
    public var startAbsoluteIndex: Int
    public var totalCount: Int
    public var isTruncated: Bool
    public var repeatMode: ContinuityRepeatMode // local enum; MozzContinuity can't see MozzPlayback
    public var isShuffled: Bool
}

public struct ContinuityItem: Codable, Sendable {
    public var locator: TrackLocator
    public var baseOrdinal: Int          // index in the pre-shuffle order — lets shuffle be turned OFF
    public var title: String             // compact metadata so an unsynced device can render
    public var artist: String
    public var durationMS: Int64         // also caps position extrapolation
    public var artwork: ArtworkRef?
}

public protocol ContinuityStore: Sendable {
    var features: ContinuityFeatures { get }   // richCursor, separateQueue, deviceAttribution
    func load() async throws -> ContinuitySnapshot?   // cursor + queue + hydrated tracks when free
    func save(_ cursor: ContinuityCursor, queue: ContinuityQueue?) async throws
}
```

`PlaybackObservation` (read-only hints) and `RemoteControl` (live commands) remain
separate protocols — folding them in behind capability flags is what made an
earlier draft dishonest.

### 3. Queue completeness

The queue is stored **in full** wherever the store allows it. Only Subsonic
truncates, because `savePlayQueue` sends repeated `id=` parameters in a GET URL and
is bounded by request-line limits (`SubsonicClient` has no POST-form path).

- **Jellyfin** — `CustomPrefs.Value` has no `MaxLength` (verified: unlimited TEXT),
  so the entire realized order is stored. No windowing.
- **Subsonic** — window by **encoded request size** (target < ~6 KiB), centred on
  the current item, biased toward up-next. `isTruncated` is set.

**Window exhaustion must be defined or playback silently stops.** When a truncated
queue reaches its final item: if `descriptor` identifies a source (album, playlist,
station), rebuild the remainder locally and continue — re-shuffled, since the
original order is unreconstructable; if it was an ad-hoc queue, stop and say the
queue was truncated. Playback never just ends without explanation.

### 4. Identity, and when *not* to check it

`TrackLocator` is qualified by `ServerAccountFingerprint` because `Track.id` is only
meaningful within one server. Today `AppEnvironment.serverId` is
`"\(kind)-\(baseURL)"`, so the same server reached at `http://192.168.1.5:8096` and
`https://music.example.com` yields two different ids.

| Backend | `serverID` | Note |
| --- | --- | --- |
| Jellyfin | `System/Info/Public` → `.Id` | Already fetched in `detectCapabilities`, currently discarded (only `.Version` is read). Needs a `ServerConnection` field. |
| Plex | `machineIdentifier` | |
| Subsonic | *none exists* | No protocol-level server UUID |

**Critically: fingerprints are not validated on a native store read.**
`getPlayQueue` returns the queue belonging to the server you are authenticated
against, so provenance is guaranteed by the transport. Comparing URL-derived
fingerprints there would reject the user's own queue purely because they came home
and switched from the public URL to the LAN IP. Fingerprints exist for **peer
transfer** and **mixed-server detection**, not for native reads.

**Hydration is free on Subsonic** — `getPlayQueue` returns full `Entry` children
(Navidrome maps them via `childFromMediaFile`), which go straight through
`SubsonicMapper.track`. No per-track resolution, no N+1 storm. Jellyfin hydrates in
one batched `Items?ids=` call. `ContinuityItem`'s compact metadata lets the UI
render before hydration completes. Missing or unauthorized tracks are skipped, not
fatal. Mixed-server queues are unsupported: if the receiving device lacks
credentials for the source it offers "connect to server", not a broken restore.

### 5. Engine seam

`PlaybackEngine`'s existing `onReport` is scrobble-shaped — it fires only on
play/pause/stop transitions. `seek(...)` does not report (it emits `onPlayEvent`),
and `tick()` never reports, so during one long track nothing fires at all. It is the
wrong seam for checkpointing.

Add a dedicated `onCheckpoint` hook, fired from `tick()` on a throttle, from
`seek`, and on transport transitions; the app additionally drives it on
`scenePhase` change. Cadence: on track change, seek, pause, stop and backgrounding;
every 15–30 s while playing; coalesced with backoff. The queue record is written
only on queue mutation.

`playbackRunID` is minted by the engine on explicit new playback or takeover — it is
the continuity run identity and is **deliberately not** `PlaybackReport.sessionID`,
which is the Jellyfin `PlaySessionId` stream/transcode id. The engine already tracks
a related concept in `transportEpoch`.

**`PlayQueue` needs a verbatim-order constructor now, not in phase 2.**
`order`/`position` are `private(set)` with no public initializer, so a shuffled
order can only be restored by baking it into `setItems` — which loses `isShuffled`
and `baseOrdinal`, and would have to be re-plumbed when the richer Jellyfin model
lands. Add `init(tracks:order:position:repeatMode:isShuffled:)` and
`restore(fromContinuity:)` up front so both phases restore through one seam.

### 6. Reconciling with the existing local restore

Mozz already restores the last session on cold launch, paused, from a full on-disk
`PlayQueue` (`AppEnvironment.restoreLastPlaybackSession()` → `PlaybackStatePersistence`).
Two consequences the design must handle:

- The local file is **higher fidelity** than any remote record for the *same*
  device. Precedence: local file wins for same-device resume; the continuity record
  is for *cross-device*, and is offered only when its `deviceID` differs and it is
  fresher.
- `PlaybackEngine.restore(_:)` guards on `currentTrack == nil, queue.isEmpty`, so
  after the local restore has run a continuity restore is a **silent no-op**. A
  "Continue here" action must explicitly clear before restoring.

### 7. Per-backend adapters

| Backend | Mechanism | Tier |
| --- | --- | --- |
| **Subsonic** | `savePlayQueue` / `getPlayQueue` — per-user, atomic replace, no expiry, no storage cap. `position` in ms; `current` is a track-id string | Exact resume |
| **Jellyfin** | Two `CustomPrefs` keys under a stable `displayPreferencesId` (non-GUID ids are deterministically MD5-hashed) | Exact resume + rich |
| **Plex** | Live observation (`/status/sessions`) + history hint | Exact while live, hint after |

**Subsonic specifics, all verified.** `changedBy` is the `c=` parameter — the client
*product name*, not a device (LMS hardcodes `""`), so **device attribution is
impossible on Subsonic**; the UI shows a single unattributed candidate with a
timestamp. There is no free-form field, so no rich cursor and no presence lease:
freshness is a UI cutoff on `changed`. gonic returns error 10 for an empty-`id`
save, so "clear" is expressed by leaving the last queue and relying on the
freshness cutoff, never by an empty save. Navidrome ≥ 0.57.0 prefers the
`indexBasedQueue` extension, which resolves duplicate tracks; classic servers
identify `current` by id and therefore cannot, so queue-occurrence fidelity is
downgraded there (track and position stay exact). Support for `savePlayQueue` and
for `indexBasedQueue` must be probed and cached — `ServerCapabilities` has fields
for neither today.

**Plex.** No durable store; the opt-in "Continue Listening" playlist is **not
planned** — it is non-atomic, user-visible bookkeeping in a music library that other
clients can edit or delete. `/status/sessions` covers live and recently-paused
sessions, which is the arrival-home case; history gives a track-level hint after
that. Revisit only if users ask. `/status/sessions` visibility must be
capability-probed: shared/home-user tokens may be restricted.

### 8. Live layer (later phase)

Scoped to **devices currently running Mozz**. iOS advertises only while alive;
macOS does not suspend and is a reliable always-on peer. `_mozz._tcp` must be added
to `NSBonjourServices` for **advertising** as well as browsing — omitting it fails
specifically on TestFlight/App Store builds.

"A code/QR-derived key" is a requirement, not a design: a short code with an
ordinary KDF is offline-brute-forceable. **The LAN phase is gated on a separate
security ADR** specifying a high-entropy QR-transported secret *or* a reviewed PAKE
(e.g. SPAKE2), plus authenticated key confirmation, AEAD with replay counters,
anonymous presence until paired, and a platform-neutral framed wire protocol
(`NWConnection` is Apple-only; a PC peer must speak it).

### 9. Module layout

```
MozzContinuity → MozzCore                    (wire types + protocols; no other deps)
MozzSubsonic   → MozzCore, MozzNetworking, MozzContinuity   (adapter)
MozzJellyfin   → MozzCore, MozzNetworking, MozzContinuity   (adapter)
MozzPlayback   → MozzCore                    (unchanged — gains onCheckpoint emitting native types)
MozzApp        → maps engine types ⇄ wire types
```

`MozzPlayback` deliberately gains **no** dependency on `MozzContinuity`: the engine
emits its own native payload and `MozzApp` — the only module importing both — does
the mapping. This keeps `ARCHITECTURE.md`'s strict downward rule intact and is why
`ContinuityRepeatMode` exists: `MozzContinuity` cannot see `MozzPlayback.RepeatMode`.

## What is actually promised

| Guarantee | Where |
| --- | --- |
| **Exact C1** — track, position and queue | Subsonic, Jellyfin |
| **Exact live handoff** | Any backend, when a peer or live session is reachable |
| **Hint only** — last track, no position | Plex once the source is gone; unknown servers |
| **Device attribution** | Jellyfin only (Subsonic cannot express it) |
| **C4 single-session** | **Not guaranteed anywhere** — best-effort live transfer |

## Rejected alternatives

| Rejected | Why |
| --- | --- |
| CloudKit / iCloud KV / synced Keychain | Apple-only — a PC can never read it; entitlement breaks headless deploy |
| Plex `/playQueues` as durable store | Verified ephemeral and client-scoped |
| Play history as a correctness primitive | No server stores a music position |
| APNs to wake a cold device | Needs a provider server the user must pay for |
| Coordinator service with CAS/leases | Only route to strict C4, but it is one more thing to self-host |
| Event log / CRDT | No substrate offers atomic append or merge |
| Content-addressed manifests + GC sweep | Races without a distributed lock; unenumerable on Jellyfin |
| Per-device records / competing candidates | Needs enumeration Jellyfin lacks; Subsonic cannot express it |
| Incrementing epoch counter for ownership | Still a claim to authority; "newer" is undefined without CAS |
| Seed-based shuffle reconstruction | Balanced shuffle uses device-local recency/taste scores |
| Plex "Continue Listening" playlist | Non-atomic, user-visible bookkeeping others can edit |
| Generic playlist writes in `MusicBackend` | Nothing needs them once the Plex playlist is dropped |

## Phasing

| Phase | Delivers |
| --- | --- |
| 1 | `MozzContinuity` types + `ContinuityStore` + `PlayQueue` verbatim constructor + engine `onCheckpoint` + Subsonic adapter + "Continue here" UI |
| 2 | Jellyfin adapter (full queue, rich cursor, device attribution) + server `Id` capture |
| 3 | Plex live observation + history hint |
| 4 | Authenticated nearby-device layer — **gated on the security ADR** |
| 5 | Jellyfin `/Sessions` + WebSocket for off-LAN live control |

Phases 1 and 2 ship together: the contract is frozen in phase 1 and must serve
Jellyfin's richer model, so both are built before release. Plex observation precedes
the LAN layer because it is far smaller and lower-risk than a secure peer protocol.
