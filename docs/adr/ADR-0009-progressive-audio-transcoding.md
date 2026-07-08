# ADR-0009 — Progressive (HTTP) audio transcoding for EQ-able transcodes

Status: **Accepted** (Jellyfin + Subsonic progressive; Plex progressive deferred).

## Context

Mozz's equalizer and ReplayGain normalization run through an
`MTAudioProcessingTap` attached to the per-item `AVMutableAudioMix`. That tap can
only process audio that exposes an `AVAssetTrack`. In practice that means:

- **Direct play** (original file streamed as-is) — has a track, EQ-able.
- **Downloaded** tracks (local file) — has a track, EQ-able.
- **Progressive** HTTP transcodes (a single continuous `.mp3`/`.aac` response) —
  has a track, EQ-able.
- **HLS** transcodes (segmented `.m3u8` + `.ts`) — **no** `AVAssetTrack`, so the
  tap never attaches and neither EQ nor normalization can run.

Historically the Jellyfin and Plex backends requested **HLS** transcodes, so any
transcoded stream was neither EQ-able nor ReplayGain-able. Subsonic already used a
progressive request (`format=aac`/`raw`). Note that nothing in the app forces a
transcode today — the resolver is built with `.bestAvailable` (no bitrate cap, no
`forceTranscode`) — so this change future-proofs the transcode path rather than
altering current playback, which is overwhelmingly direct play.

## Decision

### Jellyfin — switch to progressive (done)

In `JellyfinBackend.streamSource(for:options:)`, change the transcode parameters:

| Param                  | Before | After  |
| ---------------------- | ------ | ------ |
| `TranscodingContainer` | `ts`   | `mp3`  |
| `TranscodingProtocol`  | `hls`  | `http` |
| `AudioCodec`           | `aac`  | `mp3`  |

`Container` (direct-play allow-list), `UserId`, `DeviceId`, `PlaySessionId`,
`api_key`, and `MaxStreamingBitrate` are unchanged. This restores Jellyfin's own
`GetDeviceProfile` default (Container=mp3, AudioCodec=mp3, Protocol=http). Seeking
on a progressive stream uses `StartTimeTicks` (the server restarts ffmpeg from the
seek point), which for music is the same ~1–3s cost as HLS. Verified against
`jellyfin/jellyfin` `UniversalAudioController.cs` + `AudioHelper.cs`; the
production iOS client `eslutz/A-Playa-Named-Gus` uses exactly
`transcodingContainer: "mp3"`, `transcodingProtocol: .http`.

### Subsonic — already progressive (no change)

`SubsonicBackend.streamSource` requests `format=aac` (transcode) or `format=raw`
(direct). Both are progressive; no HLS involved. Left as-is.

### Plex — keep HLS, defer progressive (documented, not implemented)

Plex's progressive endpoint (`music/:/transcode/universal/.../start.mp3`) cannot
be streamed by AVPlayer: PMS returns `Transfer-Encoding: chunked` with **no**
`Content-Length`, `Accept-Ranges: none`, and `Connection: close`. AVPlayer's
CoreMedia HTTP stack rejects that response with CFHTTP error **-16845**, which
surfaces as `NSURLErrorDomain` **-1008**. Making Plex EQ-able on transcode would
therefore require one of:

1. **Download-to-temp-file**: pull the whole transcode via `URLSession`, inject a
   XING VBR header (so AVPlayer doesn't overestimate duration), then hand AVPlayer
   a `file://` URL. A 320 kbps 4-minute track is ~6 MB — ~4s on wifi, ~15s on slow
   cellular before playback can start.
2. **Localhost proxy**: a small in-app HTTP server that re-serves the transcode
   with a synthetic `Content-Length`.

Both add latency and non-trivial complexity, and the current `StreamSource`
contract hands AVPlayer a URL directly with no download/proxy seam. Given that
(1) Plex transcodes are rare — most Plex playback is direct play, which already
exposes an `AVAssetTrack` and is EQ-able — and (2) nothing forces a transcode
today, shipping a download-first path now would be a real UX regression for
little benefit and risks the working direct-play path.

**Decision:** leave Plex transcodes on HLS for now. Plex EQ-on-transcode is
deferred pending the download-to-file (with XING injection) or localhost-proxy
work above. A code comment in `PlexBackend.streamSource` records the constraint.

## Consequences

- Jellyfin transcoded streams (when a transcode is eventually triggered) are now
  EQ-able and ReplayGain-able.
- Plex transcoded streams remain non-EQ-able; Plex direct play (the common case)
  is unaffected and already EQ-able.
- No behavior change for today's direct-play-only usage on any backend.
- AVQueuePlayer-side buffering tuning for progressive streams is owned by the
  playback engine (EQ branch) and is out of scope for this ADR.

## Follow-up: transcode-path hardening (seek + drop recovery)

Verifying the progressive transcode against primary sources surfaced two real
gaps beyond "does it play", now addressed in the playback engine and backends:

### Seeking a progressive transcode (StartTimeTicks)

A Jellyfin progressive transcode is served `Accept-Ranges: none` from a live
ffmpeg-fed `ProgressiveFileStream` (unknown length, chunked), so `AVPlayer` can't
byte-range seek it. Jellyfin's seek model is to re-request the stream with a
server-side `StartTimeTicks` offset that restarts ffmpeg from that point.

- `MusicBackend` gained `streamSource(for:options:startSeconds:)` (default ignores
  the offset — correct for range-seekable content) and `supportsTranscodeSeek`
  (default `false`). `JellyfinBackend` overrides both, appending `StartTimeTicks`
  (`seconds × 10_000_000`) **only when actually transcoding** (a direct-play
  request stays range-seekable and would be needlessly forced to transcode).
- `ResolvedTrackURL.requiresServerSeek` (= `isTranscoded && supportsTranscodeSeek`)
  tells the engine which items can't seek natively.
- `PlaybackEngine` seeks such items by re-resolving at the offset and rebuilding
  the current item; it tracks a per-item `startOffset` so the reported position
  (and duration) stays absolute. Direct play still seeks natively (unchanged).

### Network-drop recovery

A progressive stream that drops mid-play ends in a **terminal**
`AVPlayerItem.status == .failed` (per Apple docs; `AVPlayer` does not auto-retry a
progressive HTTP download). Transient buffer dips still self-heal via
`automaticallyWaitsToMinimizeStalling = true`, so recovery deliberately triggers
only on a terminal failure — it does not fight the OS's own stall waiting.

- `PlaybackEngine` observes the current (streamed-only) item's `status` and the
  `AVPlayerItemFailedToPlayToEndTime` notification. On a **transient** `NSURLError`
  it rebuilds the item at the last position with exponential backoff (1/2/4/8/16s,
  cap 30s, max 5 tries), resetting the budget once an item reaches `.readyToPlay`.
  A non-transient error or exhausted retries advances to the next track rather
  than dead-ending. Local/downloaded files are excluded (not worth retrying).
- This benefits direct-play streaming too, not just transcodes.

`preferredForwardBufferDuration` / `preferredPeakBitRate` were intentionally not
set: both are HLS-only and no-ops for progressive audio.

