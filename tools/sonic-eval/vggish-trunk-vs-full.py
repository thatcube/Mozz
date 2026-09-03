"""Is the small half of VGGish enough?

VGGish is 288 MB, and 96% of that is two 4096-wide dense layers bolted on for
AudioSet classification. The convolutional trunk — the part that actually looks
at the spectrogram — is 4.7M parameters, about 19 MB, and small enough to bundle
in an app and hand-port to Swift. This asks whether the trunk on its own ranks
music as well as the whole thing does.
"""
import sys, pathlib, time, numpy as np, torch
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from bakeoff import decode, score  # noqa  (reuses the same metric)

ROOT = pathlib.Path(sys.argv[1])
from torchvggish import vggish, vggish_input

files, labels = [], []
for d in sorted(p for p in ROOT.iterdir() if p.is_dir()):
    for f in sorted(d.glob("*.mp3")):
        files.append(f); labels.append(d.name)
print(f"{len(files)} tracks", flush=True)

model = vggish()
model.eval()
trunk = model.features           # conv stack only
params = sum(p.numel() for p in trunk.parameters())
print(f"trunk parameters: {params/1e6:.1f}M  ({params*4/1e6:.0f} MB fp32, {params/1e6:.0f} MB int8)", flush=True)

full, mean_pool, max_pool, keep = [], [], [], []
t0 = time.time()
for i, f in enumerate(files):
    try:
        examples = vggish_input.wavfile_to_examples(str(f))
    except Exception:
        continue
    with torch.no_grad():
        feats = trunk(examples)                    # (N, 512, 6, 4)
        pooled_mean = feats.mean(dim=(2, 3))       # (N, 512)
        pooled_max = feats.amax(dim=(2, 3))
        flat = torch.flatten(torch.permute(feats, (0, 2, 3, 1)).contiguous(), 1)
        embedded = model.embeddings(flat)          # the 128-d head
    full.append(embedded.mean(0).numpy())
    mean_pool.append(pooled_mean.mean(0).numpy())
    max_pool.append(pooled_max.mean(0).numpy())
    keep.append(i)
    if (i + 1) % 200 == 0:
        print(f"  {i+1}/{len(files)}  {time.time()-t0:.0f}s", flush=True)

kept = [labels[i] for i in keep]
print("\n== VGGish, whole vs trunk ==")
print(f"{'variant':<34} {'top-3':>7} {'1-NN':>7}")
print(f"{'mozz-dsp@1 (shipping)':<34} {69.6:>6.1f}% {47.2:>6.1f}%")
for name, X in (("full VGGish, 128d (288 MB)", full),
                ("trunk + mean pool, 512d (19 MB)", mean_pool),
                ("trunk + max pool, 512d (19 MB)", max_pool),
                ("trunk mean+max, 1024d (19 MB)",
                 [np.concatenate([a, b]) for a, b in zip(mean_pool, max_pool)])):
    hit3, hit1, _ = score(np.array(X), kept)
    print(f"{name:<34} {hit3*100:>6.1f}% {hit1*100:>6.1f}%")
