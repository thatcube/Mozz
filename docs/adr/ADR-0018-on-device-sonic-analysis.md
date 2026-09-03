# ADR-0018 — On-device sonic analysis

Status: **Accepted** (`mozz-vggish@1` selected; not yet switched on — see Open questions)

## Context

Radio, "Discover Weekly" and Smart Shuffle all need one thing the catalogue
cannot give: some notion of what a track *sounds like*. Three tiers were
possible and only one of them survived contact with reality.

**A server's own analysis.** Plex Pass has sonic analysis; Navidrome and
Jellyfin can get it through an AudioMuse plugin; OpenSubsonic standardised the
interface as the `sonicSimilarity` extension. We implement that extension
(`getSonicSimilarTracks`) and it remains the first tier when a server answers.
Most do not: Plex's is paid, the plugins are a separate install, and a user who
has neither gets nothing. Depending on it makes the headline feature of the app
conditional on somebody else's subscription.

**AcousticBrainz.** Dead — stopped accepting submissions in 2022, coverage
frozen and thin for anything outside the well-known.

**Analysing the audio ourselves, on the device.** Every backend can transcode to
MP3 on demand, so the audio is reachable everywhere. This is the tier that works
for everyone, and this ADR is about it.

## Decision

### 1. One analyzer, in the shared Swift core

Not Core ML (Apple only), not TFLite (Android first), not ONNX Runtime (a native
binary per platform, three integrations). Vectors from an iPhone and a Pixel
land in the *same* nearest-neighbour index; "numerically close" is not good
enough, and three implementations that must agree is a bug factory. The analyzer
is pure Swift, and `spec/sonic/` plus the fixture tests pin its output.

### 2. MP3 as the analysis wire format

The one format Plex, Jellyfin and Subsonic all transcode to on demand, at 64
kbps because this is never played. `analysisAudioSource(forTrackID:)` carries a
`startsAtLeadIn` flag because Plex and Jellyfin take a start offset and Subsonic
does not — without it the two paths quietly describe different parts of a song.
The decoder is vendored (minimp3, CC0) rather than the host's, for the same
reason as (1).

### 3. Standardize vectors against the library, at query time

The raw vector is engine-defined and comparable across devices, which is right
for storage and wrong for cosine similarity: a handful of components every
recording shares dominate the dot product. `SonicCorpus` subtracts each
dimension's mean across the analyzed library and divides by its standard
deviation before comparing. Measured on 135 real tracks, same-artist separation
moved from +0.45 to +1.14 standard deviations. It is a query-time transform, so
it needs no re-analysis and the statistics belong to one library at one moment.

### 4. Breadth before depth, on terms the device sets

An unanalyzed library takes a wide first pass — two tracks per artist, artists
ordered by when they were last played — before working through the rest. On a
9,486-track library across 3,004 artists, covering every artist twice is about
four hours, but covering the 86 artists with listening history is 154 tracks and
about nine minutes.

Analysis runs only on mains power and an unmetered network, expressed as
constraints the platform understands: `WorkManager` on Android, a
`BGProcessingTask` on iOS. The core cannot see a charger, so it takes a closure
and asks before every track.

## What the engine is

Two engines exist. `mozz-dsp@1` is hand-designed descriptors: MFCCs, chroma,
spectral shape, dynamics, tempo — 53 dimensions, no weights, no dependencies.
`mozz-vggish@1` is the convolutional trunk of Google's VGGish (Apache 2.0), 4.5M
parameters at half precision, ported to Swift and checked against PyTorch
(cosine 0.9999).

Only the trunk: VGGish's two 4096-wide dense layers are 96% of its 288 MB, are
trained to classify AudioSet events, and *hurt* the ranking (76.5% vs 78.3%).

### Measurements

Retrieval quality, four ways. "top-3" is: does any of the three nearest
neighbours share the seed's label.

| test | mozz-dsp@1 | mozz-vggish@1 | verdict |
| --- | --- | --- | --- |
| FMA genre, top-3 (n=1200) | 69.6% | 77.0% | significant |
| FMA genre, 1-NN | 47.2% | 61.8% | significant |
| MagnaTagATune human "which two sound alike" (n=378) | 59.0% | 62.7% | p = 0.20, underpowered |
| Blind A/B on a real library, one listener (n=26 decisive) | 27% | 73% | p = 0.029 |
| A real 753-track library, same-artist 1-NN | 49.9% | 70.2% | p < 0.0001 |
| A real 753-track library, same-artist top-3 | 64.6% | 83.2% | p < 0.0001 |
| A real 753-track library, same-album top-3 | 30.0% | 45.2% | p < 0.0001 |

The real-library rows were first measured on 375 tracks across 40 artists
(68.9% vs 82.3% artist 1-NN) and repeated on 753 across 132. Doubling it made
the gap *wider* — 150 head-to-head wins for the learned engine against 25 — which
is the opposite of what a result overfitted to a small sample does. Absolute
numbers fell for both engines because 132 artists is a harder retrieval problem
than 40, not because either got worse.

The VGGish column is the **Swift port's own score**, not the Python
prototype's. The prototype measured 78.3% / 62.9%; the port gives up about a
point to half-precision weights, our own resampler, and sampling twelve patches
per track where the prototype used every one. That gap is inside the noise floor
for this sample and is the price of the thing being portable.

Things measured and rejected along the way:

- **More features do not help.** MFCC deltas, twenty coefficients instead of
  thirteen, per-track gain normalization, and the combinations: all within the
  noise floor of `mozz-dsp@1` (see `SonicBenchmarkTests.variants`).
- **PANNs CNN14** scores like VGGish (77.3% / 57.2%) at 327 MB.
- **CLAP** likewise (76.7% / 59.0%) at about a gigabyte.
- **MERT-95M**, trained on music rather than general audio, scored *worst*
  (55.3% on human triplets) — though possibly held wrong; its CQT front end was
  unavailable.

### Why genre accuracy is not the target

Genre agreement is a proxy and a weak one: two tracks can share a label and
sound nothing alike. The human-judgment set is the honest metric and it is the
one where the two engines are hardest to tell apart. What separates them there
is the *tail* — how often the nearest neighbour is badly wrong — and that is
what a station is judged by. In a blind test on a real library, `mozz-dsp@1`
answered AC/DC's "Jailbreak" with *NSYNC.

## A seed with no neighbours

Blind testing turned up a failure no engine can fix. A library held exactly one
classical track — Katherine Jenkins singing the Flower Duet — and the analyzer
answered it with Kate Bush. That is defensible as sound (a high theatrical
soprano over lush arrangement is the nearest thing a pop library holds) and
useless as radio: the listener wanted more opera, and there is no more opera.

The dangerous part is the score. That match rated 0.746, **higher than 71% of
every other best-match in the same library**. The engine was confident, and its
confidence carried no information, because similarity is measured against the
library's own distribution and a library with one opera track has no yardstick
for opera. An absolute similarity floor would not have caught this.

Roughly 10% of that library (76 of 753 tracks) has the same shape: a nearest
neighbour that is nearest only by default.

This separates two questions the design had been treating as one — *does it
sound alike* (what the analyzer measures) and *would the listener want it next*
(what radio needs). They coincide for most seeds and come apart entirely for
outliers. The fix is not a better engine; it is a station that declines to be
confident, or says plainly that there is not much like this here.

## Open questions

- **Which engine ships.** Resolved in favour of `mozz-vggish@1`: it wins every
  axis, including — after 33 blind trials on a real library — the listener's own
  ears, 19 to 7 (p = 0.029). That was the measurement I had said would be the
  honest ceiling on confidence, and it agreed with the retrieval metrics rather
  than contradicting them. Still to do before it can be switched on: shipping
  9 MB of weights per platform, the engine bump that re-analyzes every library,
  and the missing BPM (the DSP tempo estimator can run alongside cheaply).
- **What a station plays when nothing fits.** In the same 33 trials, 12% had no
  answer worth playing — three flagged outright plus the one-of-a-kind classical
  seed. That is now the largest remaining defect, and it is not an analyzer
  problem.
- **A blind test with enough trials.** Thirty decisive trials cannot separate
  engines 3.7 points apart; about 196 can.
- **Wider and more mainstream evaluation audio.** FMA and MagnaTagATune are both
  CC-licensed catalogues that skew obscure. The strongest signal so far came
  from a real library of mainstream music, which is also the smallest sample.
- **Cross-device vector sync.** Every device analyses independently today.
  Sharing requires the relay in ADR-0012 and the pairing in ADR-0013.
- **What a station does with an outlier seed.** See above: detecting "nothing
  here is like this" needs something other than the similarity score, which is
  relative by construction. Candidates: comparing a seed's best match against
  the distribution of ITS OWN neighbours rather than the library's, or
  cross-checking the acoustic neighbour against tags and refusing to lead with
  a match both tiers disagree about.

## Reproducing any of this

`tools/export-vggish.py` writes the weights and the parity fixtures.
`tools/sonic-eval/` holds the evaluation harnesses: `bakeoff.py` (pretrained
models against FMA), `human-triplets.py` (MagnaTagATune's similarity
judgments), `real-library.py` (artist and album retrieval on a folder of real
music), `vggish-trunk-vs-full.py`, and `make-listening-test.py` (a blind A/B
page). `Tests/MozzAnalysisTests/SonicBenchmarkTests.swift` scores the Swift
engines; it skips unless `MOZZ_BENCHMARK_DIR` names a labelled folder.

Datasets: FMA small (7.7 GB, `os.unil.cloud.switch.ch/fma/fma_small.zip`) and
MagnaTagATune (3 GB, `mirg.city.ac.uk/datasets/magnatagatune/`). Exported
weights and the vectors behind the numbers above are kept outside the repository
in `~/Development/mozz-sonic-artifacts/`.
