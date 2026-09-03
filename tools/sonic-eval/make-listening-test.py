"""Build a blind A/B page: same seed, one neighbour from each engine.

Same-artist matches are excluded from the candidates. They are usually right,
but they are also the easy case, and a test made of easy cases tells you
nothing about which engine to ship.
"""
import json, pathlib, random, numpy as np
# Usage: make-listening-test.py <clips dir> <v1 vectors tsv> <out html> [trials]
import sys
SP = pathlib.Path(sys.argv[1])
VECTORS = pathlib.Path(sys.argv[2])
OUT = pathlib.Path(sys.argv[3])
WANTED = int(sys.argv[4]) if len(sys.argv) > 4 else 30
manifest = {m["key"]: m for m in json.loads((SP / "manifest.json").read_text())}
keys = json.loads((SP / "keys.json").read_text())

lookup = {}
for line in VECTORS.read_text().splitlines():
    name, values = line.split("\t")
    lookup[name] = np.array([float(v) for v in values.split(",")])
X_ours = np.array([lookup[k] for k in keys])
X_vgg = np.load(SP / "vggish.npy")

def standardize(X):
    sd = X.std(0); sd = np.where(sd < 1e-9, 1.0, sd)
    Z = (X - X.mean(0)) / sd
    n = np.linalg.norm(Z, axis=1, keepdims=True); n[n < 1e-12] = 1.0
    return Z / n

Zo, Zv = standardize(X_ours), standardize(X_vgg)
artists = np.array([manifest[k]["artist"] for k in keys])

def nearest(Z, i):
    sims = Z @ Z[i]
    order = np.argsort(-sims)
    for j in order:
        if j != i and artists[j] != artists[i]:
            return int(j)
    return None

random.seed(11)
trials = []
for i in random.sample(range(len(keys)), len(keys)):
    a, b = nearest(Zo, i), nearest(Zv, i)
    if a is None or b is None or a == b:
        continue          # no disagreement, nothing to judge
    flip = random.random() < 0.5
    trials.append(dict(
        seed=manifest[keys[i]], left=manifest[keys[b if flip else a]],
        right=manifest[keys[a if flip else b]],
        leftEngine="vggish" if flip else "ours",
        rightEngine="ours" if flip else "vggish"))
    if len(trials) == WANTED:
        break

html = """<!doctype html><meta charset="utf-8"><title>Mozz blind similarity test</title>
<style>
 body{font:15px/1.5 -apple-system,system-ui,sans-serif;max-width:760px;margin:40px auto;padding:0 20px;
      background:#111;color:#eee}
 h1{font-size:20px} .seed{background:#1c1c1e;border-radius:12px;padding:16px;margin:24px 0 12px}
 .pair{display:grid;grid-template-columns:1fr 1fr;gap:12px}
 .card{background:#1c1c1e;border-radius:12px;padding:14px}
 .card button{width:100%;padding:10px;border:0;border-radius:8px;background:#2c2c2e;color:#eee;
      font:inherit;cursor:pointer;margin-top:8px}
 .card button:hover{background:#3a3a3c} audio{width:100%;margin-top:8px}
 .muted{color:#8e8e93;font-size:13px} .count{margin:18px 0}
 textarea{width:100%;height:120px;background:#1c1c1e;color:#eee;border:1px solid #333;border-radius:8px;padding:10px}
 .skip{background:none;border:0;color:#8e8e93;text-decoration:underline;cursor:pointer;font:inherit}
</style>
<h1>Which one sounds more like the seed?</h1>
<p class="muted">Both are picked by an engine; you can't tell which from the page.
Judge on sound, not on whether you like the song. 30 trials, skip any you can't call.</p>
<div class="count" id="count"></div>
<div class="seed" id="seed"></div>
<div class="pair" id="pair"></div>
<p><button class="skip" id="skip">can't tell / skip</button></p>
<div id="done" hidden><h2>Done — paste this back</h2><textarea id="out"></textarea></div>
<script>
const TRIALS = __TRIALS__;
let i = 0; const picks = [];
const el = id => document.getElementById(id);
function card(side, track){
  return `<div class="card"><b>${side}</b><div class="muted">${track.title}</div>
   <audio controls preload="none" src="file://${encodeURI(track.clip)}"></audio>
   <button data-side="${side.toLowerCase()}">${side} sounds closer</button></div>`;
}
function render(){
  if (i >= TRIALS.length){ finish(); return; }
  const t = TRIALS[i];
  el('count').textContent = `Trial ${i+1} of ${TRIALS.length}`;
  el('seed').innerHTML = `<b>SEED</b><div class="muted">${t.seed.artist} — ${t.seed.title}</div>
    <audio controls preload="none" src="file://${encodeURI(t.seed.clip)}"></audio>`;
  el('pair').innerHTML = card('A', t.left) + card('B', t.right);
  el('pair').querySelectorAll('button').forEach(b =>
    b.onclick = () => choose(b.dataset.side));
}
function choose(side){
  const t = TRIALS[i];
  picks.push({seed: t.seed.title, chose: side === 'a' ? t.leftEngine : t.rightEngine});
  i++; render();
}
el('skip').onclick = () => { picks.push({seed: TRIALS[i].seed.title, chose: 'skip'}); i++; render(); };
function finish(){
  el('seed').hidden = el('pair').hidden = el('skip').hidden = true;
  el('count').textContent = '';
  el('done').hidden = false;
  const tally = picks.reduce((m,p) => (m[p.chose] = (m[p.chose]||0)+1, m), {});
  el('out').value = JSON.stringify({tally, picks}, null, 1);
}
render();
</script>"""
out = OUT
out.write_text(html.replace("__TRIALS__", json.dumps(trials)))
print(f"{len(trials)} trials -> {out}")
