# Sonic analysis fixtures

`mozz-dsp-v1.json` pins the on-device audio analyzer: **the same PCM in, the
same vector out, on every platform.**

That contract is not a nicety. A track's vector is stored once, synced between
that person's devices, and searched as a single nearest-neighbour index. If an
iPhone and a Pixel disagree in the fourth decimal, the two are holding different
opinions about what a song sounds like, and a station built on the index depends
on which device happened to analyze the track.

## What is pinned

Four generated signals — two tones, seeded white noise, and a 120 BPM pulse —
and, for each, the analyzer's output: the 53-component vector, the loudness in
dBFS, and the tempo estimate.

The inputs are synthetic and reproducible from the generators in
`Tests/MozzAnalysisTests/SonicAnalyzerTests.swift` (the noise uses a fixed-seed
LCG, given there in full), so an implementation in another language can produce
the same input samples without shipping audio files.

## What is deliberately *not* pinned

A particular **track's** vector. Analysis input comes from a server transcode,
and two transcoder versions produce different PCM for the same song. That is
outside this project's control. What is pinned is the part that is ours: PCM in,
vector out.

## Changing the analyzer

Any change that moves a vector — a new feature, a reordered one, a different
window, a different scaling — is a new engine. Bump `SonicAnalyzer.engine`
(`name@version`), then:

```
MOZZ_WRITE_SONIC_SPEC=1 swift test --filter SonicSpecConformanceTests
```

and re-run without the variable to verify. Stored rows record their engine in
`track_features.feature_source`; rows on an older engine are not comparable with
newer ones and are re-analyzed rather than mixed.
