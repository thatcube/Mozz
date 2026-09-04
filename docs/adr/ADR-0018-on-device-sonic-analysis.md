# ADR-0018 — On-device sonic analysis

Status: **Accepted** — `mozz-vggish@1` ships on iOS, Android and desktop.

The measurements here are real; the conclusions drawn from them are a best
reading at the time of writing, and several changed during the day that
produced them. Where something is a guess it should say so, and where it does
not say so it is still worth re-checking before betting much on it.

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

## What it costs to run

Numbers measured on 2026-09-03, a Pixel 9 Pro Fold analysing a real 9,486-track
Plex library over Wi-Fi, and an M-series laptop for the per-track figures. They
will not transfer exactly to other hardware, but the ratios probably will.

| | tracks/min on the Pixel | a 9,486-track library |
| --- | --- | --- |
| `mozz-dsp@1` | 17 | ~9 hours |
| `mozz-vggish@1`, first attempt | 2.4 | 66 hours |
| `mozz-vggish@1`, after the two fixes below | 9.8 | ~16 hours |

Two things bought that 8×, and neither cost measurable quality:

**Six patches instead of twelve.** Twelve was a guess. The FMA sweep
(`MOZZ_PATCH_SWEEP` in `SonicBenchmarkTests`) put the flattening point at six —
76.9% top-3 against twelve's 77.0%, which is inside the noise for 1,200 tracks.
Four is where it starts to thin; two loses about five points.

**Convolving patches across cores.** A phone was using one of eight. The
reduction is deliberately sequential — each patch writes its own slot, the sum
is taken afterwards in fixed order — so the result stays bit-identical to the
single-threaded one. That matters more than it sounds: vectors from an iPhone
and a Pixel land in the same index, and "equal after floating-point
reassociation" is not equal.

The convolutions dominate everything else; fetch, decode, resample and the
tempo pass together are noise beside roughly 4.8 billion multiply-accumulates a
track. If more speed is wanted, the untried lever is the convolution's memory
access — it currently makes nine passes over the output plane per input
channel, which is cache-hostile, and im2col or register tiling would be the
standard answer. Guessing, that might be worth another 2–3×. int8 would be more
again, at the cost of having to re-verify accuracy.

Perceived time is not the same as total time. The queue is deliberately
breadth-first (two tracks per artist, artists ordered by what has been played),
so on that library the 154 tracks covering every artist with listening history
took about fifteen minutes. Radio is useful long before analysis finishes.

## Things that cost an afternoon to find

Recorded because none of them are visible from the code, and each one failed in
a way that looked like something else.

- **Plex refuses an analysis transcode without a client identity.** The
  `X-Plex-*` headers do not travel on media URLs — whoever fetches them
  (AVPlayer, the download session, the analyzer) shares none of the API
  client's defaults. Without product/platform/device in the query the universal
  transcoder answers 400. `directPlay=0&directStream=0` matter too, or it may
  hand back the original FLAC under a `.mp3` path.
- **Android compresses assets, and `openFd` only works on uncompressed ones.**
  The weights extraction failed with `FileNotFoundException: ... probably
  compressed` and fell back to the DSP engine silently. `noCompress += "bin"`
  in `build.gradle.kts` fixes it.
- **WorkManager kills a job at ~10 minutes and counts the kills.** A worker
  holding its slot until a library finished put the app at 17 timeouts against
  a quota of 3, which lands the whole app in a restricted bucket where
  background work schedules poorly. Short shifts, clean exits.
- **`UIDevice.batteryState` read in the same turn that enables battery
  monitoring answers `.unknown`.** The notification only fires on a *change*,
  so a phone already on a charger never corrects it, and analysis sits at
  "waiting for a charger" forever.
- **Switching engines throws away every vector.** Two engines are unrelated
  coordinate spaces and `feature_source` is what keeps them apart. Cheap early,
  expensive later — worth doing engine changes before a library finishes.
- **`tools/build-audio-xcframework.sh` defaults to macOS only.** Without
  `--all` the iOS build fails late with "no library for this platform", which
  reads like a merge error.

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

These were the questions as of the afternoon; the section below is where they
ended up. Engine selection resolved in favour of `mozz-vggish@1`, and it now
ships on all three platforms with the DSP tempo estimator running beside it for
the BPM the network has no opinion about.

- **What a station plays when nothing fits.** In 33 blind trials, 12% of seeds
  had no answer worth playing. Partly addressed — the corpus filter drops
  one-sided matches, so the acoustic tier now goes quiet rather than confident
  — but nobody has re-run the listening test to see whether that reads better
  or merely emptier.
- **A blind test with enough trials.** Thirty decisive trials cannot separate
  engines 3.7 points apart; about 196 can.
- **Wider and more mainstream evaluation audio.** FMA and MagnaTagATune are both
  CC-licensed catalogues that skew obscure. The strongest signal so far came
  from a real library of mainstream music, which is also the smallest sample.
- **Cross-device vector sync.** Every device analyses independently. This was
  blocked on the relay in ADR-0012 and the pairing in ADR-0013; both now exist
  on main, so it may be much closer than it was.
- **What a station does with an outlier seed.** See above: detecting "nothing
  here is like this" needs something other than the similarity score, which is
  relative by construction. Candidates: comparing a seed's best match against
  the distribution of ITS OWN neighbours rather than the library's, or
  cross-checking the acoustic neighbour against tags and refusing to lead with
  a match both tiers disagree about.

## Where this stands, and how sure I am of it

Written 2026-09-04, at the end of the session that built it. Treat the numbers
as measurements and the conclusions as current best guesses — several of them
moved during the day as better evidence arrived, and they could move again.

**Shipping:** `mozz-vggish@1` runs on iOS, Android and desktop, gated on mains
power and an unmetered network, scheduled by WorkManager and BGProcessingTask.
Vectors feed radio, Mozz Weekly and Supermix. The corpus filter drops matches
that are one-sided.

**Reasonably confident about:**

- The learned engine beats the DSP one. Four measurements agree, three of them
  significant, and the one blind listening test that reached significance
  (19–7, p = 0.029) agreed with the retrieval metrics rather than contradicting
  them.
- Genre agreement is a poor proxy for what this feature is for. It was the
  metric that made the learned engine look like an obvious win (+8.7 points);
  against human judgment the same gap was +3.7 and not significant.
- The engine is not the remaining bottleneck. Four different feature-set
  variations landed inside the noise floor, and three pretrained models
  (PANNs, CLAP, MERT) scored within a couple of points of each other.

**Much less sure about:**

- **The −2.0 mutual-proximity threshold.** Calibrated on one library of 753
  tracks, where it dropped about a tenth of them and matched the share a
  listener judged unplayable. It is expressed in standard deviations so it
  ought to travel, but that is an argument rather than evidence. Worth checking
  against a second library before trusting it.
- **How good this actually is.** 47% of nearest neighbours share a genre
  against 12.5% chance; ~63% agreement with human "which two sound alike"
  against 33% chance. Those say it works. They do not say it is *good enough*
  to enjoy, and the only test that would — a blind listening test with ~200
  decisive trials — has never been run at that size. Thirty-three trials is
  what exists.
- **Whether the mixes improved.** The acoustic tier now feeds Mozz Weekly and
  Supermix, blended rather than substituted. Nobody has listened to the result
  and compared it against the old shelves. That is a claim, not a finding.
- **Whether six patches is right for full-length songs.** It was measured on
  FMA's 30-second clips, where six patches cover most of the audio. On a
  four-minute track six patches sample a much smaller share, and the sweep
  cannot speak to that.

**Known missing, in rough priority order:**

1. **Android has no radio UI at all.** The engine and the FFI command exist;
   the surface does not. The device that does the most analysing cannot hear
   the result.
2. **Radio's orchestration is duplicated.** The tier blending lives in the
   core, but candidate gathering, the seen-set and the refill loop live in
   `AppEnvironment`, and the FFI has its own partial copy. That divergence has
   already produced one shipped bug (the collaborative tier missing from every
   non-Apple client). Worth pushing a `RadioStation` down into the core before
   writing the Kotlin, or the same thing happens a third time.
3. **Three Android call sites** still speak this branch's pre-merge command
   names (`setLiked`, `plexResolve`, `capabilities`) rather than main's.
4. **Cross-device vector sync.** Every device analyses independently. Main now
   has `MozzRelay` and `MozzPairing`, which is what this was blocked on, so it
   may now be straightforward — that is a guess, not an assessment.
5. **Tempo has octave errors.** Measured 54 BPM for a track that is ~108.
   One dimension of fifty-three, so it barely moves the ranking, but it is
   wrong and cheap to fold into a 60–160 band.

**If I were picking up this work cold**, I would not re-run the model bake-off
— that ground is covered in `docs/research/sonic-model-landscape.md`, including
which of two AI research reports turned out to be inventing numbers. I would
start by running a proper listening test at a size that can actually separate
things, because every remaining question about quality is bottlenecked on not
having one.

## Reproducing any of this

The weights ship in the repository — `App/Mozz/Resources/vggish-trunk.bin` and
`clients/android/app/src/main/assets/` — so nothing below is needed to *run*
the app. It is needed to re-measure anything.

`tools/export-vggish.py --out <dir>` regenerates the weights and the two parity
fixtures from the `torchvggish` checkpoint. The fixtures are what
`VGGishTrunkTests` checks the Swift port against; if the export changes, they
have to be regenerated together or the port will look broken.

Scoring the Swift engines, which is the measurement that matters most because
it is what ships:

```
MOZZ_BENCHMARK_DIR=<labelled audio>  \
MOZZ_VGGISH_WEIGHTS=<vggish-trunk.bin> \
MOZZ_PATCH_SWEEP=2,4,6,12 \
swift test -c release --filter SonicBenchmarkTests
```

The labelled folder is one directory per label containing `.mp3`s. Release mode
matters — debug is roughly ten times slower and the run takes long enough
already. `MOZZ_BENCHMARK_OUT=<file.tsv>` additionally dumps the vectors, which
is how they get scored against metadata the Swift harness does not have.

The Python harnesses in `tools/sonic-eval/` need `torch`, `torchvggish`,
`numpy` and `ffmpeg`; `panns-inference`, `laion_clap` and `transformers` only
for the models they name.

```
bakeoff.py <labelled dir>                    # pretrained models, FMA genres
human-triplets.py                            # MagnaTagATune's human judgments
real-library.py <clips dir> <v1 vectors.tsv> # artist/album retrieval, real music
vggish-trunk-vs-full.py <labelled dir>       # why only the trunk ships
make-listening-test.py <clips> <vectors.tsv> <out.html> [trials]
```

`real-library.py` and the listening test expect a `manifest.json` beside the
clips, mapping each file to artist/album/title — produced by transcoding a real
library to the format the app actually analyses (64 kbps MP3, 90 seconds from
0:20, one folder per artist). That transcode step is a dozen lines of ffmpeg
and is not currently checked in, which is a small gap.

Datasets used: FMA small (7.7 GB, `os.unil.cloud.switch.ch/fma/fma_small.zip`,
with `fma_metadata.zip` for labels — note its `tracks.csv` needs Python's
`zipfile` rather than `unzip`, which cannot read its compression), and
MagnaTagATune (3 GB in three parts, `mirg.city.ac.uk/datasets/magnatagatune/`,
plus `comparisons_final.csv` for the human triplets — 533 of them, 378 with a
decisive answer).

Working copies of the exported weights and the computed vectors from this
session are in `~/Development/mozz-sonic-artifacts/`, outside the repository.
