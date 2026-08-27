# ADR-0012 — The sync relay: store-and-forward for devices that are never awake together

Status: **Accepted** — the open risk was settled by evidence, not argument.

swift-crypto's HPKE was the one thing this rested on, and its availability
off Apple was unconfirmed. The Windows FFI spike answered it (CI run
32934126070, 2026-08-26): `Curve25519_SHA256_ChachaPoly`, seal/open round
trip true, **and a wrong key rejected** — so it cannot have passed against a
stub that returns its input. The macOS control job agrees. One pairing
implementation serves every platform.
Unblocked by ADR-0013 above; the relay carries no identity of its own.


Follows ADR-0011, which established that listening history travels device to
device rather than through the music server. This ADR covers the one case that
design does not reach on its own.

## Context

ADR-0011 concluded that history syncs over the authenticated pairing channel,
because no music server offers a universal place to keep it: Jellyfin has a real
per-user KV store, Subsonic has only a play queue, and Plex has nothing
client-writable at all.

That decision is sound, and it has a hole:

> **Most listening happens in the car, on cellular, on a phone.**

Device-to-device sync requires two devices awake on the same network at the same
moment. iOS tears down `NWListener` at suspension (ADR-0010 §8), so the realistic
sequence is: listen on the drive home, stop the music before walking in, phone
suspends, PC is busy being a games machine. **They never meet.** The phone
accumulates a year of taste; the PC's recommendations stay cold-start forever.

It half-works by accident today — arrive home *with music still playing* and
background audio keeps the phone reachable long enough to sync. "Works if you
don't turn the music off before parking" is not a design.

On Jellyfin this never happens, because the phone writes to the user's own server
over cellular and the PC reads whenever it likes. That asynchrony is the property
Plex and Subsonic users lack, and the only thing missing is **somewhere a phone
can write on cellular that a PC can read later.**

## Decision

**A minimal, zero-knowledge relay, with Backblaze B2 for storage and Cloudflare
in front of reads.**

It is a mailbox, not a service:

```
PUT  /c/{channelId}/{object}    store these bytes
GET  /c/{channelId}/{object}    give them back
```

No accounts, no user table, no database, no music, no identifiers. The relay
holds AEAD ciphertext under a random 128-bit id and cannot read any of it.

### 1. It stores ciphertext, and the keys come from pairing

The relay is **transport for the same payloads ADR-0011 already defined**, not a
new sync mechanism. Devices that have completed the pairing ceremony share an
encryption key; the relay never sees it. A channel is created by the first
device and joins are transferred device-to-device during pairing.

This keeps the trust story simple and true: *we cannot read your listening
history* is a property of the design, not a promise about our conduct.

### 2. Backblaze B2 + Cloudflare, because of the workload's shape

Verified against Backblaze's own transaction-pricing page:

| Class | Examples | Cost |
| --- | --- | --- |
| A | `PutObject`, uploads | **Free** |
| B | `GetObject`, `HeadObject` | **Free** |
| C | listing | **Free** |
| D | event notifications (unused) | 2,500/day free, then $0.004/10k |

Storage is $0.00695/GB-month after the first 10 GB. Uploads incur no bandwidth
charge. Egress is free "to or through partner CDNs… including Cloudflare".

That matters structurally rather than as a discount. **Our workload is
operation-heavy and storage-light** — thousands of tiny writes against a few GB
stored. Cloudflare R2 charges per operation, and at 50k users **$56 of its $72
monthly bill is Class A writes alone.** B2 charges nothing for operations at all.

| At 50k users | Monthly |
| --- | --- |
| **B2 + Cloudflare** | **~$0.14** |
| Cloudflare R2 | ~$72 |
| B2 *without* Cloudflare | ~$134 |

### 3. Writes go straight to B2; reads go through the CDN

The write path was the awkward part, and B2's key model resolves it. Application
keys can be **scoped to a file-name prefix**, can carry an **expiry**, and the
per-account ceiling is 100 million — far past any plausible need.

So:

- **Channel creation** (once per user, effectively): a Worker mints a B2
  application key scoped to `c/{channelId}/` with a bounded lifetime.
- **Pairing** carries the channel id, the B2 key and the encryption key to the
  new device over the HPKE channel.
- **Every write thereafter** goes **directly to B2**, with no Worker involved.
- **Every read** goes through Cloudflare's CDN to a public bucket — which is
  what makes egress free.

The consequence is that the Worker is out of the hot path entirely. Its traffic
is new channels plus periodic key renewal — on the order of a couple of thousand
requests a day at 50,000 users, against a free tier of 100,000 per day. Workers
paid ($5/month for 10M requests) exists as a fallback but is not expected to be
needed.

### 4. One manifest per device, so a check costs almost nothing without creating a shared writer

The naive pattern — every device fetches every peer's blob on every check —
costs ~337 MB per user per month, of which 270 MB is re-downloading blobs that
have not changed. That is absurd for syncing a play history.

Instead each device writes immutable generations of a small **manifest** in a
manifest-only prefix
(`manifests/{epoch}/{deviceId}/{generation}-{hash}`, ~1 KB) listing that
device's current objects and hashes. Readers list that prefix, choose the
greatest generation per device, compare hashes, and fetch only what actually
changed. Old manifest generations expire through bucket lifecycle.
Conditional `GET` (`If-None-Match`) covers the rest.

The per-device qualifier is load-bearing. An earlier draft said "the channel
holds a manifest", which created exactly the shared writable object
`spec/channel` forbids: two devices could read it, each update its own entry,
and the second write would erase the first. A device manifest has one writer,
like every other channel object. Keeping manifests together also avoids an S3
pagination trap: manifests nested below `d/{deviceId}/` cannot be selected with
one prefix, so years of immutable data objects would eventually bury them past
a 1,000-key page. The authenticated B2 key can list the manifest prefix (Class
C, free), while object bodies still read through Cloudflare.

Immutable generations also remove a provider assumption the first
implementation accidentally introduced. S3 offers conditional writes; B2's
native API does not. A read-then-write check is not compare-and-swap. With
content-addressed data and immutable manifests, concurrent processes may leave
two valid generations, and readers deterministically choose one; neither can
leave a manifest pointing at the other's body.

Roughly 3× fewer reads and ~6× less bandwidth, and it removes any dependence on
CDN cache-hit rates — which would be poor here anyway, since each object has only
two or three readers and is rewritten several times a day.

### 5. Payloads are typed and split by change rate

The relay carries whatever a device needs to hand to its peers — history batches,
yearly rollups, server credentials, warm-start catalog snapshots, and later
settings, EQ presets, and ratings. Each is a **separate object**, because they
change at wildly different rates: history moves whenever music plays, a catalog
snapshot only after a complete mirror, and EQ presets essentially never. One
combined blob would rewrite everything on every listen.

Catalog snapshots are chunked and content-addressed. An encrypted per-device
index becomes visible only after every bounded chunk is uploaded, so interruption
cannot publish a partial catalog. They are scoped to server, account/profile, and
selected music libraries; readers select one newest complete snapshot rather
than merging caches from different points in time. The originating media server
remains authoritative and every hydrated device reconciles in the background.

This is what makes "what else should sync?" a payload question rather than an
infrastructure question.

### 6. Guardrails, because usage-based billing has no ceiling

Neither B2 nor Cloudflare offers a hard spend cap. A client retry loop is
therefore a billing event, and the only real defences are ours:

- **A hard client-side floor between writes**, well above ADR-0011's current
  30-minute interval. History is latency-tolerant by design; syncing a few times
  a day is ample.
- **Never write an unchanged object.** Deterministic serialization already makes
  this a hash comparison, and a device that played nothing writes nothing. This
  is the primary cost control, not an optimization.
- **A maximum object size**, enforced client-side and by the key's scope.
- **Prefix-scoped keys with expiry**, so a compromised or looping device can be
  cut off without touching anyone else.
- **Lifecycle expiry** on the bucket, so storage cannot grow unbounded.
- **Rate limiting on the channel-creation Worker**, which is the only unauthenticated
  surface.

### 7. S3-compatible, so the provider is a config change

The single most valuable constraint here. B2's economics depend on the Cloudflare
Bandwidth Alliance, and Cloudflare now sells R2 in direct competition with B2 — so
a future where that partnership is deprioritized is plausible rather than
paranoid. Without it, B2 egress alone is ~$134/month at 50k users, worse than R2.

Writing strictly against the S3 API means R2, Hetzner, Scaleway, or a self-hosted
bucket remain one endpoint change away. **The provider decision is deliberately
cheap to reverse; the protocol decision is not.**

### 8. Self-hosting is insurance, not a product

The relay endpoint is a settings field, and the Worker source is published. A
user who wants their own can deploy it to their own free Cloudflare account or
run the container behind the reverse proxy they already operate — and anyone who
needs the relay at all already exposes a server to the internet, or they could
not listen in the car in the first place.

But self-hosting is **not** what should earn trust. The encryption is. If the
relay only ever holds ciphertext under a random id, "run your own" answers a
question the design already answered. Self-hosting's real value is removing the
single point of failure when the maintainer stops paying a bill — which is worth
providing, and is not worth building a polished self-hosting product for.

### 9. On by default, with one honest switch

Off by default means the car case stays broken for exactly the users who would
never discover why. On by default means Mozz talks to a first-party server for
every user, which is a real change in posture for a self-hosted-audience app.

**On by default**, with a plainly-worded toggle: *"Sync between your devices —
encrypted; the server can't read it. Off: your devices sync only on the same
network."* Reversible, and the failure mode when off is degraded rather than
broken.

## What this costs

- **A first-party server exists.** Small, dumb and self-hostable, but it exists,
  and the project's posture is that users should not *need* one. Mitigated by:
  no account, ciphertext only, endpoint configurable, source published, and the
  app fully functional with it switched off.
- **A hosting bill that must outlive enthusiasm for paying it.** ~$0 to well past
  50,000 users, but not zero forever.
- **Metadata leaks a little.** Reads are public by id, so someone who learned a
  channel id could observe sync timing without reading content. Random 128-bit
  ids make that unfindable; it is a real if small exposure.
- **B2's economics depend on a partnership.** See §7.

## Alternatives rejected

| Rejected | Why |
| --- | --- |
| Device-to-device only (ADR-0011 as it stands) | Breaks for car/cellular listening, which is the primary use case, on Plex and Subsonic |
| Per-server storage | No universal store; Plex has none at all (ADR-0011) |
| Playlist description as a KV store | User-visible, user-deletable, ~1 KB on Subsonic, and Plex cannot create an empty playlist |
| iCloud / CloudKit | Private-database access from Windows demands an Apple ID sign-in and short-lived web tokens; storage counts against the user's own 5 GB iCloud quota, so sync silently stops for anyone who is full. It helps precisely where help is not needed and not at all where it is |
| Cloudflare R2 as primary | Per-operation billing is the wrong shape: ~$72/month at 50k users versus ~$0.14, and $56 of that is writes. Retained as the fallback if the Bandwidth Alliance ends |
| An account system | Nothing here needs identity; a channel id and a key from pairing are sufficient |
| A VPS running the relay | Viable and predictable, but it is one box to patch, monitor and defend, and it costs money at zero users where a free tier costs nothing. Remains available via the same S3 abstraction |

## Consequences

**Good.** Car and cellular listening reaches every other device, on every
backend, with no co-presence required. Plex and Subsonic users get exactly what
Jellyfin users get. The hotel-iPad case works. Off-LAN pairing becomes possible.
No account, no identity, nothing readable by the server, and the cost is
approximately zero at any scale the app is likely to reach.

**Bad.** A first-party server now exists in a project whose whole posture is that
one should not be needed. Usage-based billing has no hard ceiling, so the
guardrails in §6 are load-bearing rather than nice to have. And B2's cost
advantage rests on a partnership between two companies, one of which sells a
competing product.

## Status

Blocked on the pairing/security ADR (ADR-0010 §8), which owns the ceremony and
the encryption this relay assumes. Nothing here ships before that lands.

Unaffected by this decision: `MozzHistory`, `HistorySyncStore`,
`HistoryRollupBuilder`, `spec/history`, and the `HistoryStore` protocol — the
relay is one more implementation behind the seam that already exists.
