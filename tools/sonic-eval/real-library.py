"""Both engines over a real library: same-artist and same-album retrieval.

Not the arbiter — one person's 375 tracks is a validation sample, not the world.
But it is real production audio at the bitrate the app actually analyzes, and
album/artist agreement is a sharper probe than eight coarse genres.
"""
import json, pathlib, sys, time, numpy as np, torch
# Usage: real-library.py <clips dir with manifest.json> <v1 vectors tsv>
SP = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).parent / "local"
VECTORS = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else SP.parent / "local_v1_vectors.tsv"
manifest = json.loads((SP / "manifest.json").read_text())
by_key = {m["key"]: m for m in manifest}

def standardize(X):
    X = np.asarray(X, dtype=np.float64)
    sd = X.std(0); sd[sd < 1e-9] = 1.0
    Z = (X - X.mean(0)) / sd
    n = np.linalg.norm(Z, axis=1, keepdims=True); n[n < 1e-12] = 1.0
    return Z / n

def retrieval(X, keys, field, k=3):
    Z = standardize(X)
    S = Z @ Z.T
    np.fill_diagonal(S, -np.inf)
    vals = np.array([by_key[key][field] for key in keys])
    peers = np.array([(vals == v).sum() - 1 for v in vals])
    order = np.argsort(-S, axis=1)
    usable = peers > 0
    top = vals[order[:, :k]]
    hit = (top == vals[:, None]).any(1)
    near = vals[order[:, 0]] == vals
    return hit[usable].mean(), near[usable].mean(), int(usable.sum()), hit

results, hits = {}, {}

# ours, from the Swift dump
dump = VECTORS
lookup = {}
for line in dump.read_text().splitlines():
    name, values = line.split("\t")
    lookup[name] = np.array([float(v) for v in values.split(",")])
keys = [k for k in sorted(by_key) if k in lookup]
print(f"{len(keys)} clips analyzed by both", flush=True)
X_ours = np.array([lookup[k] for k in keys])

# VGGish trunk over the same clips
cache = SP / "vggish.npy"
if cache.exists():
    X_vgg = np.load(cache)
    print(f"loaded {len(X_vgg)} cached vggish vectors", flush=True)
else:
  from torchvggish import vggish, vggish_input
  model = vggish(); model.eval(); trunk = model.features
  X_vgg, t0 = [], time.time()
  for i, k in enumerate(keys):
      try:
          examples = vggish_input.wavfile_to_examples(by_key[k]["clip"])
          with torch.no_grad():
              feats = trunk(examples)
          X_vgg.append(feats.amax(dim=(2, 3)).mean(0).numpy())
      except Exception:
          X_vgg.append(np.zeros(512))
      if (i + 1) % 100 == 0:
          print(f"  vggish {i+1}/{len(keys)}  {time.time()-t0:.0f}s", flush=True)
  X_vgg = np.array(X_vgg)
  np.save(SP / "vggish.npy", X_vgg)
(SP / "keys.json").write_text(json.dumps(keys))

print("\n== a real library: does the neighbour come from the same artist / album? ==")
print(f"{'engine':<24} {'artist top-3':>13} {'artist 1-NN':>12} {'album top-3':>12} {'album 1-NN':>11}")
for name, X in (("mozz-dsp@1 (shipping)", X_ours), ("VGGish trunk (512d)", X_vgg)):
    a3, a1, na, hit_a = retrieval(X, keys, "artist")
    b3, b1, nb, hit_b = retrieval(X, keys, "album")
    hits[name] = (hit_a, hit_b)
    print(f"{name:<24} {a3*100:>12.1f}% {a1*100:>11.1f}% {b3*100:>11.1f}% {b1*100:>10.1f}%")
print(f"{'(tracks with a peer)':<24} {na:>12} {na:>11} {nb:>11} {nb:>10}")

from math import erfc, sqrt
for label, idx in (("artist", 0), ("album", 1)):
    a = hits["mozz-dsp@1 (shipping)"][idx]; b = hits["VGGish trunk (512d)"][idx]
    only_a = int((a & ~b).sum()); only_b = int((b & ~a).sum()); n = only_a + only_b
    if n:
        z = (abs(only_a - only_b) - 1) / sqrt(n)
        p = erfc(z / sqrt(2))
        print(f"{label}: ours wins {only_a}, VGGish wins {only_b}, p = {p:.4f}"
              + ("  ← significant" if p < 0.05 else "  ← not significant"))
