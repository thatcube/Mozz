# ADR-0015 — Android networking: the core keeps its own HTTP

Status: **Accepted** (measured on device; gate 7 of the Android FFI spike)

ADR-0014 closed with one genuinely open design question and asked for this ADR
by name. The answer is that there is nothing to decide: Foundation's networking
works on Android, so the Swift core keeps doing its own HTTP and the Kotlin layer
never sees a socket.

## Context

The core is not a compute library that a client feeds data to. It signs in,
mirrors catalogs and resolves stream URLs itself — `connect`, `plexPin`,
`plexPinCheck`, `attach`, `libraries`, `sync`, `syncStatus`, `streamURL` and
`artworkURL` all make HTTPS calls from inside Swift, through
`MozzNetworking.HTTPTransport` → `URLSessionTransport` → `URLSession`. On Apple
and on Windows that is settled. On Android it was not, and the Android spike
could not see it: its six gates exercise SQLite, crypto and hashing, none of
which open a socket.

What ADR-0014 actually found was narrower than it read. The **static**
`lib_CFURLSessionInterface.a` wants ~26 libcurl symbols that the Swift Android
SDK does not ship. The final `.so` binds the **dynamic**
`libFoundationNetworking.so` instead, which links clean. From that, ADR-0014
correctly declined to conclude anything about runtime behaviour, and listed three
candidate designs: rely on Foundation, vendor a libcurl, or inject an OkHttp
transport from Kotlin.

Three designs and no evidence is not a decision. So the spike grew a seventh
gate.

## What was measured

`mozz_ffi_probe_https` drives `URLSessionTransport` — the production type the
backends use, not `URLSession` directly, so a pass means the real path works and
not merely that some socket somewhere opened. The harness runs it as gate 7.

On an arm64 Android 36 device, against four real hosts:

| URL | result |
|---|---|
| `https://www.google.com/generate_204` | 204, TLS, 124 ms |
| `https://example.com` | 200, 559 bytes, TLS, 152 ms |
| `https://plex.tv` | 200, 1,987,646 bytes, TLS, 903 ms |
| `https://api.jellyfin.org` | 200, 1188 bytes, TLS, 515 ms |
| `http://www.google.com/generate_204` | 204, no TLS, 80 ms |

DNS, TCP, TLS, certificate validation and a nearly 2 MB response body all work.

### Why it works: libcurl is inside the dynamic library

The thing ADR-0014 could not see from the link is visible in the shipped object:

- `libFoundationNetworking.so` **defines 89 `curl_*` symbols and leaves zero
  undefined.** curl is statically linked into it. The SDK not shipping a
  standalone libcurl was never the same thing as Foundation not having one.
- Its `DT_NEEDED` list is Foundation, ICU, dispatch, the Swift runtime, `libz`,
  `libm`, `libdl`, `libc` — no curl, no TLS library.
- The TLS backend is **BoringSSL**, also linked in (`BoringSSL SSL_connect: %s in
  connection to %s:%d` and friends are in the binary).
- It reads Android's own trust store: `/apex/com.android.conscrypt/cacerts` and
  `/system/etc/security/cacerts` are both baked in as paths.

So the runtime dependency ADR-0014 flagged as a risk does not exist. Nothing has
to be vendored.

### The near-miss, recorded on purpose

The **first** run of gate 7, on a freshly booted emulator, failed:
`transport("Failed to connect to www.google.com port 443 after 6700 ms: Could not
connect to server")`. Read at face value that is "Android cannot do HTTPS", and
it would have bought an OkHttp transport that was never needed.

It was an emulator artefact — the first HTTPS attempt after boot, on a NAT with a
1030 ms ICMP round trip. Three things separated the artefact from a real finding,
and they are worth repeating the next time a gate fails:

1. **The error was curl's wording**, which already said Foundation had a curl and
   had got as far as connecting — not "could not resolve host".
2. **Independent connectivity checks**: `ping` resolved and answered, and
   `nc` opened TCP to port 443 from the same device shell.
3. **Decomposition**: plain HTTP on port 80 worked, and HTTPS to an IP literal
   (`https://1.1.1.1`, 200, 56 KB) worked — isolating DNS, TCP and TLS from each
   other. Re-running the original URL then passed too.

## Decision

**The Swift core keeps its own networking on Android. No OkHttp transport, no
vendored libcurl, no Kotlin HTTP code.**

The `HTTPTransport` seam stays exactly where it is — it earns its keep in tests,
which inject recorded fixtures — but Android does not need a production
implementation of it, and the FFI boundary does not grow a callback for one.

## Consequences

- The Android client is a UI, a queue and an audio engine, and nothing else. This
  is what ADR-0011 through ADR-0014 were betting on, now true of the network
  layer too.
- Gate 7 keeps it true: any change that breaks the core's networking on Android
  fails in CI rather than on someone's phone.
- The `.so` payload is unchanged; nothing was added to carry curl or a TLS stack.

### The one thing this opens, which is a real user-facing gap

Foundation's curl trusts **Android's system CA store**. It does not consult the
app's `network_security_config.xml`, and it does not see user-installed CAs.
Mozz's users are self-hosters, and a self-signed or private-CA certificate on a
Navidrome or Jellyfin box is ordinary rather than exotic. Those servers will fail
to connect with a certificate error, and no Android-side trust configuration will
change that, because the Kotlin layer is not in the request path.

That is a known limitation, not a blocker for v1 against Plex — but it needs its
own answer before Jellyfin and Subsonic sign-in ship, and the honest options are
narrow: teach the core about a user-pinned certificate, or accept that
self-signed servers need a proper certificate first. It is deliberately left
open here rather than guessed at.

## Alternatives considered

- **An OkHttp transport injected through the FFI boundary.** ADR-0014's preferred
  fallback, and the right design had gate 7 failed. Rejected because it solves a
  problem that does not exist, and it would have put an async callback across a
  synchronous C ABI to do it. Worth revisiting only for the self-signed
  certificate gap above, where OkHttp's trust configuration would genuinely help
  — and even then, teaching the core is the smaller change.
- **Vendoring libcurl and BoringSSL for both ABIs.** Rejected: they are already
  inside `libFoundationNetworking.so`, and a second copy would be two more native
  dependencies to build, patch and CVE-track for no gain.
- **Reimplementing the server clients in Kotlin.** Rejected in ADR-0014 and again
  here. It discards the single source of truth the last five ADRs are built on.
