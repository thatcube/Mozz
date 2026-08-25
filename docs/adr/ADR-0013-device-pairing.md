# ADR-0013 — Device pairing: the channel everything else is waiting on

Status: **Proposed**

Required by ADR-0010 §8, ADR-0011 and ADR-0012, none of which can ship without
it. Also the mechanism by which a new Windows or Android install obtains the
user's server credentials.

## Context

Three separate pieces of work are blocked on the same missing thing:

| Blocked | Needs |
| --- | --- |
| Live handoff / device picker (ADR-0010 §8) | an authenticated nearby-device channel |
| Listening-history sync on every backend (ADR-0011) | a way to move batches between devices |
| The sync relay (ADR-0012) | a key the relay never sees |
| A new PC or phone getting the user's servers | credential transfer without retyping |

All four are the same primitive: **two devices establishing a shared secret,
with the user physically confirming it is the right pair.**

There is no account, so there is no server-side identity to lean on. The trust
has to come from the human.

### What already exists

A sibling app (Plozz, tvOS) ships this. Read at source, it is:

- **HPKE, RFC 9180**, `Curve25519_SHA256_ChachaPoly`, sealing a transfer bundle
  to the recipient's ephemeral public key.
- **A pairing context** — ceremony id, expiry, protocol version, payload kind —
  encoded with sorted keys and mixed into the HPKE `info`, so a captured blob
  cannot be replayed into a different ceremony or opened by another device.
- **A commit/reveal SAS ceremony** for the paths with no camera: the guest
  commits to a nonce *before* the host reveals its key and nonce, and reveals
  last. Because each side is bound to its contribution before learning the
  other's, a man-in-the-middle cannot grind a substituted key to make both codes
  agree.
- **Six digits**, derived by SHA-256 over the domain string and the
  length-prefixed host public key, both nonces and the ceremony id.

This is not a sketch. It is the design ADR-0010 §8 asks for, already shipped.

## What is different for Mozz

Four things, and they are what this ADR is actually about.

### 1. It has to work between platforms, not just between Apple devices

Plozz pairs Apple to Apple. Mozz must pair **iPhone ↔ Windows ↔ Android ↔ Mac**.
So the design carries over and two implementation choices cannot:

- **`CryptoKit` is Apple-only.** Same problem as `ContinuityQueueBuilder` before
  it moved to swift-crypto.
- **`NWConnection` and `NWListener` are Apple-only.** The transport must be
  ordinary mDNS plus framed TCP, specified in `spec/`, not in Swift.

### 2. The key now protects data at rest on someone else's disk

Plozz's HPKE seal is a **one-shot** transfer between two devices on a LAN. The
relay (ADR-0012) changes the threat model: a long-lived symmetric key now
protects blobs sitting on third-party storage, indefinitely.

These are two distinct constructions and the ADR must not blur them:

- **The ceremony** uses HPKE to move a bundle once, device to device.
- **The bundle contains** a long-lived `channelKey` used thereafter to seal relay
  objects.

Compromise of the channel key exposes relay content — which is listening
history, not credentials, and is the reason credentials ride the HPKE path only.

### 3. The payload is bigger, and part of it is genuinely sensitive

```
server connections + auth tokens      ← the reason a new PC needs no retyping
relay channel id + channel key        ← ADR-0012
relay write key (B2, prefix-scoped)   ← ADR-0012 §3
settings, EQ presets                  ← convenience
```

Server tokens are the crown jewels: they grant access to the user's whole media
library. That is what justifies a real ceremony rather than a shared short code.

### 4. There is no iCloud fast path

Plozz can lean on "same iCloud account, it just works". Cross-platform, that
cannot exist. **The ceremony is the only path**, so it has to be good enough to
be the default rather than a fallback — which argues strongly for QR-first.

## Decision

### Ceremony: QR first, digits only when there is no camera

**QR is the primary flow.** The new device displays a code; the existing device
scans it. The camera authenticates out-of-band — pointing a phone at a screen
physically proves which machine you are talking to — so **no digit comparison is
needed at all** on this path.

The direction falls out naturally: the phone has the camera *and* the secrets;
the PC has a screen and needs both.

**Digits are the fallback** for a TV, a headless box, or someone who would rather
type. That path runs the full commit/reveal SAS, because without the camera there
is no out-of-band proof and a same-LAN attacker could otherwise substitute a key.

### Six digits, and fix the modulo bias

Six, not four. Four digits is 13.3 bits — for a one-shot online ceremony where a
mismatch is immediately visible that is *arguably* survivable, but there is no
reason to accept it when six costs the user nothing.

Reading Plozz's derivation closely, it takes three bytes (24 bits, 16,777,216
values) and reduces `mod 1_000_000`. That is not uniform: 16 × 1,000,000 fits,
leaving 777,216 values that map to a slightly more likely first band. The bias is
tiny and does not meaningfully help an attacker, but it is free to remove —
either take more bytes before reducing, or use rejection sampling. **Mozz's
implementation should be uniform**, and the spec should say so, because a second
implementation will otherwise reproduce the quirk rather than the intent.

### Crypto: HPKE, via swift-crypto, in the shared core

Same construction Plozz uses — `Curve25519_SHA256_ChachaPoly`, ceremony context
in `info`, a domain-separated AAD — reimplemented in a `MozzPairing` module that
depends on `MozzCore` and swift-crypto rather than CryptoKit.

Putting it in the **Swift core** rather than per-platform means one
implementation of the crypto for iOS, macOS, Windows and Android, which is worth
a great deal for code nobody wants three versions of.

### ⚠️ The open risk, and how it gets settled

**swift-crypto contains HPKE, but its availability off-Apple is not confirmed.**
Some of its surface is gated on platform primitives. If HPKE does not work on
Windows, the crypto cannot live in the shared core and each platform needs its
own (hpke-rs, hpke-js, or a pure-Swift implementation).

This is exactly the shape of the FTS5 question, and it gets the same treatment:
**the existing FFI spike settles it.** Add an entry point that performs a seal
and an open against a fixed test vector, run it on the Windows CI job, and the
answer is a fact rather than a hope. That is a small addition to
`Sources/MozzFFI` and must happen **before** any of this is implemented.

### Transport: platform-neutral, specified in `spec/`

- **Discovery:** mDNS / DNS-SD, service `_mozz._tcp`. Must be declared in
  `NSBonjourServices` for *advertising* as well as browsing — omitting it fails
  specifically on TestFlight and App Store builds (ADR-0010 §8).
- **Transport:** length-prefixed framed messages over TCP. Not `NWConnection`.
- **Wire format:** the same canonical-JSON discipline as `spec/continuity` and
  `spec/history` — sorted keys, integer milliseconds, explicit version prefix —
  with golden fixtures so a Windows implementation can be verified against the
  Swift one before either is trusted.
- **Off-LAN pairing** rides the ADR-0012 relay once a channel exists; the first
  pairing is LAN-or-QR only.

### Rotation and revocation

A lost or sold device must not keep reading history forever.

- The `channelKey` is rotatable. Rotation mints a new channel id, re-seals to the
  remaining devices, and abandons the old prefix, which the bucket's lifecycle
  rule eventually collects.
- The relay's B2 write key is prefix-scoped and expiring (ADR-0012 §3), so a
  revoked device loses write access at expiry even if nothing else is done.
- Rotation is a **user-initiated** action ("forget this device"), not automatic:
  it requires the remaining devices to be paired again, and doing that silently
  would be worse than the problem.

Forward secrecy for already-written relay objects is **not** provided — an
attacker with the old key and a copy of old ciphertext can read old history.
Accepted: the content is listening history, the blobs expire, and the alternative
is per-object key agreement that no offline device could participate in.

## Alternatives rejected

| Rejected | Why |
| --- | --- |
| A short human-typed code alone (no PAKE, no SAS) | Offline-brute-forceable; ADR-0010 §8 rejects it explicitly |
| A PAKE (SPAKE2) instead of commit/reveal SAS | A legitimate option, but it is more novel cryptography to implement three times when a reviewed commit/reveal ceremony already ships in a sibling app |
| Reusing Plozz's code directly | CryptoKit and `NWConnection` are Apple-only. The *design* ports; the code cannot |
| An account or a first-party identity service | Nothing here needs identity, and it is the posture the project exists to avoid |
| iCloud Keychain to sync credentials | Apple-only; leaves Windows and Android with nothing |
| Trust-on-first-use with no confirmation | A same-LAN attacker gets the user's server tokens. Not acceptable for this payload |

## Consequences

**Good.** One ceremony unblocks four features. Credentials reach a new device
without retyping, which is the difference between "install Mozz on the PC and
everything is there" and a setup chore. The crypto is one implementation in the
shared core rather than three. Nothing touches an account, a server, or the
user's library.

**Bad.** This is the most security-sensitive code in the project and it guards
the user's server tokens. It needs review proportional to that, not merely tests.
The QR path requires a camera on one side. And the whole thing is gated on an
unverified assumption about swift-crypto that must be settled first.

## Order of work

1. **Verify HPKE off-Apple** via the existing FFI spike on Windows CI. Nothing
   else starts until this answers.
2. `MozzPairing`: context, HPKE seal/open, uniform SAS — pure, testable, with
   `spec/pairing` golden fixtures.
3. Transport: mDNS + framed TCP, behind a protocol so tests need no sockets.
4. The ceremony UX, QR first.
5. Payload: credentials, then the relay channel.

Steps 2 and 3 are independently testable and platform-free, which is deliberate:
the parts that must be right are the parts that can be tested without a second
device in the room.
