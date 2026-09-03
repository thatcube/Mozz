# External research: model landscape and abstention (September 2026)

Two AI research reports, same questions, commissioned because this work was
being decided from a knowledge cutoff and a bake-off I had run myself. Findings
below are cross-checked against our own measurements; where they disagree, the
disagreement is recorded rather than resolved by preference.

## Licensing kills most of the field

| model | weights licence | usable in a GPL-3 app? |
| --- | --- | --- |
| VGGish | Apache 2.0 | yes (shipping) |
| PANNs (CNN10 / CNN14) | code MIT, weights CC BY 4.0 | yes |
| LAION-CLAP | Apache 2.0 | yes, but a transformer |
| MusicFM | reported MIT by one, "unknown" by the other | **verify before use** |
| MERT-95M / 330M | **CC BY-NC 4.0** | **no** |
| MuQ / MuQ-MuLan | **CC BY-NC 4.0** | **no** |
| Discogs-EffNet, MAEST | **CC BY-NC-SA / NC-ND** | **no** |
| Discogs-VINet | MIT | yes, but built for cover-song ID |

Both reports agree on MERT and MuQ. That retires MERT as a candidate on legal
grounds independent of quality — it was already losing our benchmarks, but it
would have been unusable had it won. It is the same trap as Essentia's models,
which we avoided earlier for the same reason.

## One report invented benchmark numbers

Report 1 tabulates MagnaTagATune human-triplet agreement to one decimal for
models nobody has published triplet numbers for: MERT-95M at 71.2%, CLAP at
70.4%, MuQ-MuLan at 72.1%. Report 2, asked the same question, says plainly that
it "could not find post-2024 published numbers on MagnaTagATune similarity
triplets for CLAP, MuQ, MERT, MusicFM" and marks them unknown.

Our own measurement settles it: MERT-95M, swept across all twelve layers and
both poolings, peaks at **63.8%** on exactly that benchmark — against VGGish's
62.7%. Not 71.2%.

Report 1 is well-organised, mathematically fluent, and partly fabricated. Report
2 is scruffier and says "unknown" thirty times. The scruffier one was right.

## What both agree on, and what it means for us

- **VGGish is a legacy baseline.** Superseded in research contexts. Retained
  here for reasons the literature does not weigh: hand-portability, determinism
  across platforms, and a permissive licence.
- **PANNs CNN10** (5.2M params, ~10 MB fp16, pure conv, permissive) is the
  cheapest possible upgrade and untested by us. CNN14 measured 64.0% against
  VGGish's 62.7% — the right direction, not significant.
- **Distillation from a permissively licensed teacher** (CLAP, or MusicFM if the
  MIT claim holds) into a ~5M CNN is the strongest path that respects every
  constraint. Report 1 estimates 67–69% triplet agreement; report 2 says no
  published distillation reports similarity metrics at all, so that estimate is
  unsupported. Worth trying, not worth believing in advance.

## Abstention: the literature has a name and a formula for our bug

Our own finding — a match scoring higher than 71% of the library while being
useless, because similarity is relative to the library's own distribution — is
the **hubness** problem, and the sparse seeds are **anti-hubs** or **orphans**
(Aucouturier & Pachet 2004; Gasser, Flexer & Schnitzer 2010).

Flexer and Gasser's work on the FM4 Soundpark recommender found 33–35% of a
real catalogue were anti-hubs, never returned as anyone's neighbour, and that
simulated listening sessions on a k-NN graph died after fewer than three tracks.
Our 12% "nothing worth playing" sits inside the published band.

The fix both reports point to is **Mutual Proximity** (Schnitzer, Flexer, Schedl
& Widmer, 2011/2012), an unsupervised transform that makes distances comparable
across seeds:

    MP(x, y) = P(X_x > d(x,y)) · P(X_y > d(x,y))

Each track's distances to the rest of the library are modelled as a normal
distribution; the score is the product of both tracks' tail probabilities.
Applied to our case: the opera track's nearest pop neighbour is plausible from
the opera side and an extreme outlier from the pop side, so the product
collapses — which a one-sided score cannot express.

Reports disagree on whether commercial services abstain. Report 1 asserts
Plexamp truncates sonic radio below a distance cutoff and falls back to
metadata; report 2 finds no published evidence of abstention anywhere and says
Spotify's patents always rank rather than refuse. Treat the Plexamp claim as
unverified.

On UX both agree, and it matches what we already suspected: silent degradation
is the worst option, an honest short message plus a broadened fallback is the
best, and no one has published an A/B test of exactly this.
