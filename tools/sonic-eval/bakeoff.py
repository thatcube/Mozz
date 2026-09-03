"""Score pretrained audio embeddings on the same benchmark the Swift analyzer uses.

Same 1,200 FMA clips, same corpus standardization, same two numbers:
label-in-top-3 and 1-NN accuracy. Whatever wins here is worth porting; whatever
does not is not.
"""
import os, subprocess, sys, pathlib, numpy as np, time

ROOT = pathlib.Path(sys.argv[1])
LIMIT = int(sys.argv[2]) if len(sys.argv) > 2 else 0

def decode(path, rate):
    out = subprocess.run(
        ["ffmpeg", "-v", "quiet", "-i", str(path), "-f", "f32le", "-ac", "1", "-ar", str(rate), "-"],
        capture_output=True)
    if out.returncode != 0 or not out.stdout:
        return None
    return np.frombuffer(out.stdout, dtype=np.float32).copy()

files, labels = [], []
for d in sorted(p for p in ROOT.iterdir() if p.is_dir()):
    picked = sorted(d.glob("*.mp3"))
    if LIMIT:
        picked = picked[:LIMIT]
    for f in picked:
        files.append(f); labels.append(d.name)
print(f"{len(files)} tracks, {len(set(labels))} labels", flush=True)

def standardize(X):
    X = np.asarray(X, dtype=np.float64)
    mu, sd = X.mean(0), X.std(0)
    sd[sd < 1e-9] = 1.0
    Z = (X - mu) / sd
    n = np.linalg.norm(Z, axis=1, keepdims=True)
    n[n < 1e-12] = 1.0
    return Z / n

def score(X, labels):
    Z = standardize(X)
    S = Z @ Z.T
    np.fill_diagonal(S, -np.inf)
    lab = np.array(labels)
    order = np.argsort(-S, axis=1)
    top3 = lab[order[:, :3]]
    hit3 = (top3 == lab[:, None]).any(1).mean()
    hit1 = (lab[order[:, 0]] == lab).mean()
    per = {}
    for g in sorted(set(labels)):
        m = lab == g
        per[g] = (top3[m] == lab[m, None]).any(1).mean()
    return hit3, hit1, per

results = {}

# ---- PANNs CNN14 (MIT). 2048-d, trained on AudioSet. Wants 32 kHz. ----
try:
    raise RuntimeError("skip")
    from panns_inference import AudioTagging
    t0 = time.time()
    tagger = AudioTagging(checkpoint_path=None, device="cpu")
    embeddings = []
    keep = []
    for i, f in enumerate(files):
        audio = decode(f, 32000)
        if audio is None or audio.size < 32000:
            continue
        _, emb = tagger.inference(audio[None, :])
        embeddings.append(emb[0]); keep.append(i)
        if (i + 1) % 100 == 0:
            print(f"  panns {i+1}/{len(files)}  {time.time()-t0:.0f}s", flush=True)
    results["PANNs CNN14 (2048d)"] = score(np.array(embeddings), [labels[i] for i in keep])
    print("panns done", flush=True)
except Exception as e:
    print("panns failed:", e, flush=True)

# ---- VGGish (Apache 2.0). 128-d per 0.96s frame, averaged. Wants 16 kHz. ----
try:
    raise RuntimeError("skip")
    import torch
    from torchvggish import vggish, vggish_input
    t0 = time.time()
    model = vggish()
    model.eval()
    embeddings, keep = [], []
    for i, f in enumerate(files):
        try:
            examples = vggish_input.wavfile_to_examples(str(f))
        except Exception:
            continue
        with torch.no_grad():
            emb = model.forward(examples)
        embeddings.append(emb.mean(0).cpu().numpy()); keep.append(i)
        if (i + 1) % 100 == 0:
            print(f"  vggish {i+1}/{len(files)}  {time.time()-t0:.0f}s", flush=True)
    results["VGGish (128d)"] = score(np.array(embeddings), [labels[i] for i in keep])
    print("vggish done", flush=True)
except Exception as e:
    print("vggish failed:", e, flush=True)

# ---- CLAP (LAION, Apache 2.0). 512-d, trained on audio-text pairs; the
# music-specific checkpoint is the strongest thing here. Wants 48 kHz.
try:
    import laion_clap, torch
    t0 = time.time()
    clap = laion_clap.CLAP_Module(enable_fusion=False)  # HTSAT-tiny matches the default checkpoint
    clap.load_ckpt()  # downloads the default music+speech checkpoint
    embeddings, keep = [], []
    for i, f in enumerate(files):
        audio = decode(f, 48000)
        if audio is None or audio.size < 48000:
            continue
        with torch.no_grad():
            emb = clap.get_audio_embedding_from_data(x=audio[None, :], use_tensor=False)
        embeddings.append(emb[0]); keep.append(i)
        if (i + 1) % 100 == 0:
            print(f"  clap {i+1}/{len(files)}  {time.time()-t0:.0f}s", flush=True)
    results["CLAP HTSAT (512d)"] = score(np.array(embeddings), [labels[i] for i in keep])
    print("clap done", flush=True)
except Exception as e:
    print("clap failed:", e, flush=True)

print("\n== bake-off ==")
print(f"{'model':<26} {'top-3':>7} {'1-NN':>7}")
print(f"{'mozz-dsp@1 (shipping)':<26} {69.6:>6.1f}% {47.2:>6.1f}%")
for name, (hit3, hit1, per) in results.items():
    print(f"{name:<26} {hit3*100:>6.1f}% {hit1*100:>6.1f}%")
for name, (_, _, per) in results.items():
    print(f"\n{name} by label:")
    for g, v in per.items():
        print(f"  {g:<16} {v*100:5.0f}%")
