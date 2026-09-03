"""Score models against human judgments of what sounds alike.

MagnaTagATune's TagATune game showed people three clips and asked which one did
not belong. 533 of those triplets survive with vote counts; 378 have a decisive
answer. That makes the two clips nobody voted for the pair humans call similar —
which is the actual question radio asks, and the one genre labels only gesture
at.

A model is right on a triplet when the closest of the three pairs, by its own
similarity, is the pair the humans picked. Chance is 1 in 3.
"""
import csv, sys, pathlib, subprocess, time, numpy as np

SP = pathlib.Path(__file__).parent
MTAT = SP / "mtat"
AUDIO = MTAT / "audio"

def votes(row):
    return [int(row[k]) for k in ("clip1_numvotes", "clip2_numvotes", "clip3_numvotes")]

triplets = []
for row in csv.DictReader(open(MTAT / "comparisons_final.csv"), delimiter="\t"):
    v = votes(row)
    order = sorted(v, reverse=True)
    if order[0] < 2 or order[0] == order[1]:
        continue                                   # no clear odd one out
    odd = v.index(order[0])
    paths = [row[f"clip{i}_mp3_path"] for i in (1, 2, 3)]
    pair = [p for i, p in enumerate(paths) if i != odd]
    triplets.append((paths, pair, paths[odd]))
print(f"{len(triplets)} decisive triplets", flush=True)

clips = sorted({p for paths, _, _ in triplets for p in paths})
present = [c for c in clips if (AUDIO / c).exists() and (AUDIO / c).stat().st_size > 1000]
print(f"{len(present)}/{len(clips)} clips present", flush=True)
index = {c: i for i, c in enumerate(present)}

def decode(path, rate):
    out = subprocess.run(["ffmpeg", "-v", "quiet", "-i", str(path), "-f", "f32le",
                          "-ac", "1", "-ar", str(rate), "-"], capture_output=True)
    if out.returncode != 0 or not out.stdout:
        return None
    return np.frombuffer(out.stdout, dtype=np.float32).copy()

def standardize(X):
    X = np.asarray(X, dtype=np.float64)
    sd = X.std(0); sd[sd < 1e-9] = 1.0
    Z = (X - X.mean(0)) / sd
    n = np.linalg.norm(Z, axis=1, keepdims=True); n[n < 1e-12] = 1.0
    return Z / n

def agreement(vectors):
    """Per-triplet outcomes: did the model's closest pair match the humans'?"""
    Z = standardize(vectors)
    outcomes = []
    for paths, pair, odd in triplets:
        if not all(p in index for p in paths):
            continue
        a, b = (Z[index[p]] for p in pair)
        c = Z[index[odd]]
        same = float(a @ b)
        other = max(float(a @ c), float(b @ c))
        outcomes.append(same > other)
    return np.array(outcomes)

results = {}

# --- ours, read back from the Swift benchmark's dump ---
dump = SP / "mtat_v1_vectors.tsv"
if dump.exists():
    lookup = {}
    for line in dump.read_text().splitlines():
        name, values = line.split("\t")
        lookup[name] = np.array([float(v) for v in values.split(",")])
    X, missing = [], 0
    for c in present:
        key = pathlib.Path(c).stem
        if key in lookup:
            X.append(lookup[key])
        else:
            X.append(np.zeros(len(next(iter(lookup.values())))))
            missing += 1
    if missing:
        print(f"  (mozz-dsp: {missing} clips missing from the dump)", flush=True)
    results["mozz-dsp@1 (shipping)"] = agreement(np.array(X))

# --- VGGish conv trunk, max-pooled ---
try:
    import torch
    from torchvggish import vggish, vggish_input
    model = vggish(); model.eval()
    trunk = model.features
    X, t0 = [], time.time()
    for i, c in enumerate(present):
        try:
            examples = vggish_input.wavfile_to_examples(str(AUDIO / c))
            with torch.no_grad():
                feats = trunk(examples)
            X.append(feats.amax(dim=(2, 3)).mean(0).numpy())
        except Exception:
            X.append(np.zeros(512))
        if (i + 1) % 200 == 0:
            print(f"  vggish {i+1}/{len(present)}  {time.time()-t0:.0f}s", flush=True)
    results["VGGish trunk (512d)"] = agreement(np.array(X))
except Exception as e:
    print("vggish failed:", e, flush=True)

# --- MERT: trained on music rather than general audio ---
try:
    import torch
    from transformers import AutoModel, Wav2Vec2FeatureExtractor
    name = "m-a-p/MERT-v1-95M"
    mert = AutoModel.from_pretrained(name, trust_remote_code=True)
    mert.config.output_hidden_states = True
    mert = mert.eval()
    proc = Wav2Vec2FeatureExtractor.from_pretrained(name, trust_remote_code=True)
    X, t0 = [], time.time()
    for i, c in enumerate(present):
        audio = decode(AUDIO / c, proc.sampling_rate)
        if audio is None or audio.size < proc.sampling_rate:
            X.append(np.zeros(768)); continue
        inputs = proc(audio, sampling_rate=proc.sampling_rate, return_tensors="pt")
        with torch.no_grad():
            out = mert(**inputs, output_hidden_states=True)
        # Middle layers carry the most musical structure in MERT's own ablations.
        states = out.hidden_states if out.hidden_states is not None else (out.last_hidden_state,)
        stack = torch.stack(list(states))               # (layers, 1, frames, 768)
        lo = min(6, stack.shape[0] - 1)
        X.append(stack[lo:lo+4].mean(0)[0].mean(0).numpy())
        if (i + 1) % 200 == 0:
            print(f"  mert {i+1}/{len(present)}  {time.time()-t0:.0f}s", flush=True)
    results["MERT-95M (768d)"] = agreement(np.array(X))
except Exception as e:
    print("mert failed:", e, flush=True)

print("\n== agreement with human 'which two sound alike' ==")
print(f"{'model':<26} {'agrees':>8}  {'95% CI':>14}")
print(f"{'chance':<26} {33.3:>7.1f}%")
for name, out in results.items():
    p = out.mean(); n = len(out)
    se = (p * (1 - p) / n) ** 0.5
    print(f"{name:<26} {p*100:>7.1f}%  {(p-1.96*se)*100:>5.1f}-{(p+1.96*se)*100:<5.1f}%  (n={n})")

# Paired comparison: on the same triplets, how often does one win where the
# other loses? A rate difference alone cannot tell you whether that is real.
names = list(results)
print()
for i in range(len(names)):
    for j in range(i + 1, len(names)):
        a, b = results[names[i]], results[names[j]]
        only_a = int((a & ~b).sum()); only_b = int((b & ~a).sum())
        n = only_a + only_b
        if n == 0:
            continue
        # McNemar, normal approximation.
        z = (abs(only_a - only_b) - 1) / (n ** 0.5) if n else 0
        from math import erfc, sqrt
        pval = erfc(z / sqrt(2))
        print(f"{names[i]} vs {names[j]}: {only_a} / {only_b} disagreements, p = {pval:.3f}"
              + ("  ← significant" if pval < 0.05 else "  ← not significant"))
