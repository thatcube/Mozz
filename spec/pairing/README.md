# `spec/pairing` — the cross-platform pairing contract

Pairing is how a device joins someone's circle. It is the only moment secrets
move between devices, and every later feature — history sync, the relay, library
snapshots, playback handoff — inherits whatever trust it establishes. It is
therefore the one place in Mozz where being *approximately* right is the same as
being wrong.

This document is the contract. It exists so a second implementation can be
checked against the Swift one **before either is trusted**, using the fixtures in
this directory rather than a side-by-side run and a hopeful eye.

ADR-0013 owns the reasoning; this owns the bytes.

## The shape

A **circle** is a set of devices that trust each other. It has one `channelId`
and one `channelKey`. Any member can admit a new device, and any member can
remove one; there is no per-pair relationship and no centre.

The words matter and an earlier draft of this document got them wrong. What a
user does is *join* a circle, or *add a device* to one — a circle is however
many devices someone owns, and calling that "pairing" imports an assumption of
two that is false everywhere it counts. The two-party protocol below is
genuinely a *pairing ceremony*, because it runs between the joiner and exactly
one member; it is the only place the word belongs.

That is the iCloud Keychain / Tailscale model, chosen for a reason about people
rather than cryptography: mesh pairing costs *N(N−1)/2* ceremonies, so a fourth
device means three separate scans against three separate devices. One scan per
device, ever, is the difference between a feature people use and a feature people
give up on.

The cost is that removing a device re-keys the circle for everybody. That is
handled in [Rotation](#rotation), and it is the right trade: removal is rare,
adding is not.

## Two paths, and why there are two

**QR is primary.** The joining device displays a code; a device already in the
circle scans it. The camera *is* the authentication — pointing a phone at a
screen is physical proof of which machine you are talking to — so this path needs
no digit comparison at all.

The direction is not arbitrary. The joiner displays because it has nothing yet;
the member scans because it has secrets to give. A phone has a camera and
secrets, a desktop has a screen and needs both, and that falls out correctly
without a special case.

**Digits are the fallback**, for a TV, a headless box, or anyone who would rather
type. Without a camera there is no out-of-band channel, so this path runs a full
commit-and-reveal exchange. Skipping the commitment would let whichever side
speaks second choose its contribution after seeing the other's, and pick a
transcript whose digits match an attack it had already prepared.

## The encoding

Every byte string below is built the same way as `spec/continuity`: explicit
version prefix, fixed field order, no optional whitespace, integers big-endian.
Anything a parser could read two ways is a defect in this document.

### Labels, and why they are all different

Every hash and key derivation carries a distinct ASCII label. Reusing one across
two purposes lets output from one step be replayed as input to another, which is
the failure that makes otherwise-correct protocols come apart.

| Label | Used for |
|---|---|
| `mozz/pair/v1/qr` | the QR payload |
| `mozz/pair/v1/commit` | the digit path's commitment |
| `mozz/pair/v1/sas` | deriving the six digits |
| `mozz/pair/v1/channel` | sealing the circle secrets |

### QR payload

```
qrPayload := "MOZZ1:" || base64url( body )

body := version   (1 byte, = 0x01)
     || role      (1 byte, 0x02 = joiner; the only legal value in v1)
     || pubKey    (32 bytes, X25519 public key, raw)
     || nonce     (16 bytes, random)
```

`base64url` is RFC 4648 §5 **without padding**. Padding is omitted because a QR
encoder that helpfully strips `=` would otherwise produce a payload that parses
on one platform and not another.

The QR carries a **public** key and nothing else of value. A photograph of it is
not a credential: it lets someone offer to *receive* the circle secrets, and a
member still has to choose to send them. This is deliberate — a QR carrying the
channel key would make a screenshot equivalent to permanent full access.

### The six digits

Six, not four. Four is 13.3 bits, *arguably* survivable for a one-shot online
ceremony where a mismatch is immediately visible — but six costs the user nothing
and removes the argument.

The derivation must be **uniform**. Plozz takes three bytes (16,777,216 values)
and reduces `mod 1_000_000`; 16 × 1,000,000 fits, leaving 777,216 values that
land in a slightly more likely first band. The bias is far too small to help an
attacker and is free to remove — but a second implementation reading only the
code would reproduce the quirk rather than the intent, which is why this is a
requirement here rather than a detail there.

```
stream := HKDF-SHA256(
              ikm  = sharedSecret,
              salt = transcriptHash,
              info = "mozz/pair/v1/sas" )

repeat:
    v := next 4 bytes of stream, big-endian u32
    if v < 4_294_000_000:            # largest multiple of 1e6 below 2^32
        digits := v mod 1_000_000
        stop
    # else discard and draw again — rejection sampling, exactly uniform
```

`4_294_000_000` is not a magic number: 2³² is 4,294,967,296, and 967,296 values
sit above the last whole multiple of a million. Discarding those is what makes
the result exactly uniform rather than nearly so. A draw is rejected about once
in 4,400 times, so an implementation that never exercises the retry path has not
been tested — there is a fixture for it below.

Digits render zero-padded to six characters, displayed in two groups of three.
The grouping is presentation only and is **not** part of any hash.

### Commitment, for the digit path

```
commit := SHA-256( "mozz/pair/v1/commit" || 0x00 || nonceA )
```

The joiner sends `commit` first, the member replies with `nonceB`, the joiner
then reveals `nonceA`, and the member verifies the commitment before either side
computes digits. A member that computes digits before verifying has removed the
entire point of the exchange.

### Transcript

Both sides hash the same transcript, in this order, and compare digits derived
from it. Any disagreement about what was said produces different digits, which is
what makes a substituted key visible to a human.

```
transcriptHash := SHA-256(
    "mozz/pair/v1/sas" || 0x00
 || version            (1 byte)
 || joinerPubKey       (32 bytes)
 || memberPubKey       (32 bytes)
 || nonceA             (16 bytes)
 || nonceB             (16 bytes) )
```

Field order is fixed and every field is fixed-width, so no length prefixes are
needed and no field can be confused with its neighbour.

### Sealing the circle secrets

Once the ceremony succeeds, the member seals the circle's secrets to the joiner's
public key using HPKE, `Curve25519_SHA256_ChachaPoly` — the suite proven to work
on Windows as well as Apple platforms by the FFI spike (CI run 32934126070), and
the reason this can live in the shared core instead of being written three times.

```
info := "mozz/pair/v1/channel" || 0x00 || transcriptHash
aad  := version || joinerPubKey

plaintext := canonical JSON, sorted keys:
    { "channelId":      string,
      "channelKey":     base64,   # encrypts history, library, likes, settings
      "credentialsKey": base64,   # encrypts servers/ objects — nothing else
      "epoch":          integer,  # see Rotation
      "relayKey":       base64 }  # scoped B2 application key, per ADR-0012
```

### Two keys, and why servers are not in the seal

An earlier draft put the server list *in this seal and nowhere else*, so tokens
never touched the relay. The instinct was right — a scrobble and a media-library
token do not belong in one blast radius — but the conclusion was wrong, because
it meant a server added on your phone stayed invisible on your PC forever. That
is not a trade-off, it is a defect with a rationale attached.

So pairing hands over **two** symmetric keys, and servers sync continuously like
everything else:

| Key | Protects | Where it is stored |
|---|---|---|
| `channelKey` | history, library snapshots, likes, settings | ordinary app storage |
| `credentialsKey` | `servers/` objects only | the platform secure store |

The separation is only real because the *storage tiers* differ. Keychain on
Apple, Keystore on Android, DPAPI on Windows — reachable by the app, not by
someone who has merely copied its files or restored its backup. An attacker who
walks off with app data gets a listening history; the tokens need the secure
store as well.

Rotation is per-key. Removing a device rotates both. A user changing a server
password re-encrypts only `servers/`, and nothing else in the channel has to
move.

**A better version exists and is deliberately not v1:** Plex and Jellyfin can
both mint per-device tokens, so each device could hold only its own and removal
could revoke it at the server rather than merely locking it out of the channel.
That is strictly better and it needs per-backend work in three clients, so it is
recorded as future work rather than smuggled into the first release.

Binding `transcriptHash` into `info` means a sealed payload cannot be replayed
into a *different* ceremony: the recipient derives the same `info` only if it saw
the same transcript.

## Rotation

`epoch` is an integer that increments when the circle re-keys, which happens when
a device is removed. Every object the relay holds is written under its epoch, and
a device holding an older `channelKey` can no longer read anything written after.

Removal therefore costs one re-key for everybody, and remaining members pick up
the new epoch automatically because they are still trusted. A removed device
keeps whatever it already downloaded — nothing can be done about that, and
pretending otherwise would be dishonest.

**A circle of one cannot revoke.** If someone owns two devices and loses one, the
remaining device re-keys and the lost one is locked out. If they lose all of
them, there is nothing to re-key with and the data is gone. That is the same
trade Signal makes, and it is stated here so nobody has to discover it.

## Transport

- **Discovery:** mDNS / DNS-SD, service `_mozz._tcp`. `NSBonjourServices` must
  declare it for **advertising** as well as browsing. Omitting the advertising
  entry fails specifically on TestFlight and App Store builds while working
  perfectly in development, which is the worst possible time to find out.
- **Framing:** length-prefixed messages over TCP, 4-byte big-endian length,
   64 KiB maximum per message. Not `NWConnection` — this has to exist on Windows
  and Android too.
- **Off-LAN** pairing rides the ADR-0012 relay once a channel exists. The *first*
  pairing is LAN-or-QR only, because there is no channel yet to ride.

## `pairing-fixtures.json`

Every case fixes all inputs, so an implementation can be checked without a
network, a camera, or a second device. Where a real ceremony uses randomness, the
fixture supplies it.

### Cases, and what each one is defending

| Case | Defends against |
|---|---|
| `qr-payload-canonical` | encoder drift: field order, unpadded base64url, the `MOZZ1:` prefix |
| `sas-digits-basic` | the ordinary derivation, including zero-padding |
| `sas-digits-rejection` | a draw above the limit **must** be discarded — an implementation that reduces it anyway passes every other case and is quietly biased |
| `sas-digits-leading-zeros` | `000042` must not render as `42` |
| `commit-binding` | commitment computed over label *and* nonce, not the nonce alone |
| `transcript-order` | swapping joiner and member keys must change the digits |
| `channel-info-binding` | `info` binds the transcript, so a seal cannot be replayed into another ceremony |

## Verifying an implementation

Run every case and compare bytes, not behaviour. An implementation that reaches
the right digits by a different route is fine; one that gets six cases right and
`sas-digits-rejection` wrong is biased, and this fixture is the only thing that
will tell you.

## Changing the encoding

Don't, in v1. If a change is genuinely needed, the version byte increments and
both encodings ship simultaneously for at least one release — a device that
cannot pair with the phone it paired with yesterday is a worse failure than
whatever the change was meant to fix.

## Regenerating

`tools/generate-pairing-fixtures.swift` produces `pairing-fixtures.json`. It is
committed rather than generated at test time so a change to the encoding shows up
as a diff in review, which is the point.
