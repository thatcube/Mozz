# Windows FFI spike

**Question this answers:** can Mozz's platform-free Swift core be built as a
C-ABI shared library and driven from a non-Swift host — and if so, is it *fast*?

This is the cheapest way to de-risk the whole cross-platform plan. It runs the
real `PerformanceHarness` the iOS app uses, so the numbers are directly
comparable to the published iOS results, and it fails loudly on the one thing
most likely to sink the effort: a SQLite build without FTS5.

## What it checks, in order

| # | Gate | Why it matters |
|---|---|---|
| 1 | `MozzCore` + `MozzDatabase` compile | Is the core genuinely portable, or accidentally Apple-only? |
| 2 | `MozzFFI` links as a DLL/dylib/so | Does `@_cdecl` produce something a host can load? |
| 3 | **SQLite has FTS5** | Apple's system SQLite always does. Others may not — and Mozz's entire search story dies without it |
| 4 | Search p95 < 100 ms at 100k tracks | The hard product requirement |
| 5 | JSON encode time vs query time | Is a JSON boundary cheap enough to keep? |
| 6 | **HPKE (RFC 9180) works** | ADR-0013 puts the pairing crypto in the shared core. swift-crypto *contains* HPKE but gates parts of its surface on platform primitives — if it doesn't work here, pairing needs a separate implementation per platform |
| 7 | Continuity hashes match `spec/` | A non-Apple peer must derive byte-identical queue hashes, or cross-device resume fails silently |

Gate 3 is the important one. `MusicDatabase.open()` runs migrations that
`CREATE VIRTUAL TABLE ... USING fts5`, so a missing FTS5 fails immediately
rather than degrading quietly — and `mozz_ffi_probe` reports it explicitly.

## Baselines to beat

Measured on iPhone 17 Pro Max, 100k tracks (`ARCHITECTURE.md` §8):

| Metric | iOS |
|---|---|
| search p50 / p95 | 7.9 / **15.7 ms** |
| cold DB open + first count | 66.4 ms |
| page fetch (100 rows) | 3.8 ms |
| catalog generation (100k) | 3.9 s |

Different hardware won't match these exactly, and that's fine. What matters is
staying inside the 100 ms search budget and not regressing by an order of
magnitude — that would mean the boundary design is wrong, not just the hardware.

## Running it

### GitHub Actions (x64, zero local setup)

Actions → **Windows FFI spike** → *Run workflow*. Optionally set the track
count (defaults to 100,000; try 20,000 for a faster first pass).

The `macos-control` job runs the identical harness on macOS. If Windows fails
and macOS passes, the fault is platform-specific rather than a bug in the
facade — which is exactly the discrimination you want from a first run.

### Locally on Windows

```powershell
# Swift toolchain: https://www.swift.org/install/windows/
winget install --id Swift.Toolchain -e

swift build -c release --product MozzFFI
dotnet build spike/windows-ffi/Harness/Harness.csproj -c Release -o harness-out

# MozzFFI.dll must sit next to the harness (or be on PATH)
Copy-Item .build\release\MozzFFI.dll harness-out
.\harness-out\MozzSpikeHarness.exe 100000
```

### Locally on macOS

```bash
swift build -c release --product MozzFFI
dotnet build spike/windows-ffi/Harness/Harness.csproj -c Release -o harness-out
cp .build/release/libMozzFFI.dylib harness-out/
./harness-out/MozzSpikeHarness 100000
```

No .NET installed? The C ABI can be exercised straight from Python:

```python
import ctypes, json
lib = ctypes.CDLL(".build/release/libMozzFFI.dylib")
lib.mozz_ffi_probe.restype = ctypes.c_void_p
lib.mozz_ffi_free_string.argtypes = [ctypes.c_void_p]

ptr = lib.mozz_ffi_probe()
print(json.loads(ctypes.cast(ptr, ctypes.c_char_p).value.decode()))
lib.mozz_ffi_free_string(ptr)
```

## ⚠️ On testing in a VM on Apple Silicon

A Windows VM on an M-series Mac is **Windows on ARM64**. Your gaming PC — and
essentially every user — is **x64**.

| Result | Transfers from an ARM64 VM? |
|---|---|
| Core compiles | ✅ |
| FTS5 present | ✅ (build config, not architecture) |
| C ABI holds | ✅ |
| **Performance numbers** | ❌ **no** |
| x64 packaging / installer | ❌ no |

The perf trap runs the wrong way: an M4 Max ARM64 VM will likely produce numbers
that *flatter* you versus a mid-range x64 desktop, so you'd conclude the boundary
is fine without having tested what you ship. Use the VM for the fast iterate loop;
take the numbers on x64 (GitHub Actions is x64 and free).

Install the **native ARM64** Swift toolchain in the VM — don't run the x64
toolchain under Prism emulation.

## Design notes

The facade shape is the actual deliverable here — see the header comment in
`Sources/MozzFFI/MozzFFI.swift`. In short:

- Swift structs, classes, payload enums and `async`/`await` **do not cross a C
  ABI**. Only primitives and pointers. Everything else is serialized.
- **JSON at the boundary**, because ADR-0010 already requires RFC 8785 canonical
  JSON for continuity manifests. One serialization strategy for the project, and
  every payload stays inspectable in tests.
- **Coarse-grained calls.** One call, one unit of work, one result. Never one
  call per row — a per-row crossing while scrolling 100k rows is precisely the
  failure this design avoids.
- **Explicit ownership.** Every returned string is caller-owned and freed exactly
  once via `mozz_ffi_free_string`.

### What this spike deliberately does *not* do

`runBlocking` parks a thread on a semaphore to bridge async→sync. That is the
anti-pattern a production facade must avoid — a real one uses callbacks or a
polled event queue so the host's UI thread never blocks. It's here only to keep
the spike small and measurable. Errors also collapse to strings, and there's no
cancellation.

## Interpreting a failure

| Symptom | Likely cause |
|---|---|
| Stage 1 fails | Something in the core isn't as portable as believed — read the diagnostic; it names the file |
| Stage 2 fails | `@_cdecl`/linking problem, or a dynamic-product issue on the platform |
| `DllNotFoundException` | The DLL or the Swift runtime DLLs aren't beside the harness / on PATH |
| `fts5CreateSucceeded: false` | **The big one.** The linked SQLite lacks FTS5 — GRDB's SQLite dependency has to be rebuilt or replaced before anything else matters |
| HPKE `available: false` | swift-crypto's HPKE doesn't function on this platform. ADR-0013's "one pairing implementation everywhere" is off; each platform needs its own (hpke-rs, hpke-js, or pure Swift) |
| A continuity hash mismatch | Compare the reported bytes, not the digests — the encoding is where the difference is |
| search p95 way over iOS | Investigate before writing any UI — likely index or configuration drift, not the boundary |
| encode ≥ 25% of query time | Reconsider a binary boundary format (FlatBuffers/CBOR) instead of JSON |
