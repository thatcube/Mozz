# ADR-0017 — A server's address is not its identity

Status: **Accepted** — implemented on iOS, Android and desktop.

## Context

Plex does not have *an* address for a server. `api/v2/resources` returns several
candidate connections for the same machine — a LAN address, a remote address, and
a relay address that tunnels through Plex's own infrastructure — and which of
them works depends on the network the device happens to be on.

Mozz picked one at sign-in and never asked again. `mozzServerId(kind:baseURL:)`
then derived the account's identity by hashing that address, and the catalogue,
the likes and the entire play history were keyed on the result.

Two consequences, both observed:

**The pinned address can die.** On 2026-09-01 the Android app was pinned to
`172-104-29-70.…plex.direct:8443` — a relay endpoint, Linode-hosted, chosen at
sign-in months earlier. TCP connected in 120ms and TLS failed instantly, five
times out of five, from the phone *and* from a laptop on the same network:

```
javax.net.ssl.SSLHandshakeException: connection closed
curl: (35) … exit 35, tls=0.000000s
```

Every cover in the app went grey and playback failed. The failure is
intermittent: it recovered on its own twenty minutes later, which is exactly what
makes it hard to recognise as an address problem rather than a flaky app.

**Re-resolving would orphan the library.** Because identity was derived from the
address, pointing the account at a working address made it, as far as the
database was concerned, a different server: a new empty catalogue, no likes, no
history. That is why the app could not simply re-resolve, and it is the deeper
half of the bug.

### A correction

An earlier revision of this ADR said Mozz never stores the Plex **account**
token, and treated storing it as the price of re-resolution. That was wrong, and
the error mattered: it made the safe fix look expensive.

Every client already stores it, and has for as long as the server picker has
existed — iOS in the Keychain (`StoredSession.accountToken`, routed through
iCloud Keychain), Android under `plex.account.<serverId>` in the Keystore-backed
store, the desktop under the same key in its secret store. `discoverConnections`
is what the "switch server" picker is built on.

So re-resolution asks for **no new privilege**. It reads a credential the app is
already holding, for a purpose it is already used for.

## Decision

Identity belongs to the *account*, established once, and travels with it. The
address is a property that may change.

**1. Freeze the id.** `attach` accepts a `serverId` and uses it when given,
deriving one only for an account being met for the first time. All three clients
pass the id they already hold. On iOS the id is frozen into `StoredSession` on
first activation — for existing installs the value written back is exactly the
one they were already using, so nothing moves.

**2. Record the machine.** `AuthenticatedSession`, `WireSession` and each
client's saved account gained `machineIdentifier` — Plex's identifier for the
*server*, which is the thing that does not change when the address does.

**3. Re-resolve on failure.** `PlexAuthenticator.resolveConnection` discovers the
account's connections, narrows them to that machine (by identifier, or by name
for accounts linked before identifiers were recorded), and returns the first that
answers. Exposed over the FFI as `plexResolve`, which echoes the caller's
`serverId` back unchanged.

Re-resolution **never returns an address that did not answer**. A device with no
network at all looks identical to a dead address — every candidate is silent —
and repointing to a guess made offline would take a working configuration and
break it. `firstReachableConnection` keeps its "best guess" fallback for sign-in,
where a guess beats refusing to sign in; repair uses a strict probe that can
return nothing.

Each client repairs in two places, one for each way the symptom appears:

| | at launch | during a sync |
|---|---|---|
| iOS | `activate` — capability detection came back nil | between the existing retry attempts |
| Android | `verifyReachable`, after the library is on screen | one retry through `repointAccount` |
| Desktop | `VerifyReachableAsync`, not awaited | `SyncWithRepointAsync` |

The launch check is deliberately off the critical path on Android and desktop:
the catalogue is local and should be on screen immediately, so a healthy address
costs the user nothing.

## Consequences

An account whose address dies now moves to a working one on its own, keeping its
catalogue, its likes and its history. A user who has never noticed any of this is
the intended outcome.

What is still true: this is Plex-only. Jellyfin and Subsonic have one address by
definition, and if that address changes the user has to say so. Local discovery
(GDM — Plex servers answer a UDP broadcast on 32410–32414 with no token at all)
remains unbuilt; it would fix the common case of being at home while pinned to a
relay without any credential, and is worth having if the account path ever proves
unreliable.
