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
 body{font:15px/1.5 -apple-system,system-ui,sans-serif;max-width:780px;margin:32px auto;padding:0 20px;
      background:#111;color:#eee}
 h1{font-size:20px;margin-bottom:4px}
 .seed{background:#1c1c1e;border-radius:12px;padding:16px;margin:20px 0 12px;
       border:1px solid #2c2c2e}
 .pair{display:grid;grid-template-columns:1fr 1fr;gap:12px}
 .card{background:#1c1c1e;border-radius:12px;padding:14px}
 button{border:0;border-radius:8px;background:#2c2c2e;color:#eee;font:inherit;cursor:pointer;
        padding:10px}
 button:hover{background:#3a3a3c}
 .card button{width:100%;margin-top:8px}
 .both{width:100%;margin-top:12px;background:#1f3a2e}
 .both:hover{background:#2a5040}
 audio{width:100%;margin-top:8px}
 .muted{color:#8e8e93;font-size:13px}
 .bar{height:4px;background:#2c2c2e;border-radius:2px;margin:10px 0 18px;overflow:hidden}
 .bar div{height:100%;background:#0a84ff;transition:width .2s}
 .row{display:flex;gap:10px;align-items:center;margin-top:14px}
 .row .link{background:none;color:#8e8e93;text-decoration:underline;padding:6px 0}
 textarea{width:100%;height:120px;background:#1c1c1e;color:#eee;border:1px solid #333;
          border-radius:8px;padding:10px;font-family:ui-monospace,monospace;font-size:12px}
 .saved{color:#30d158;font-size:12px}
</style>
<h1>Which one sounds more like the seed?</h1>
<p class="muted">Both candidates were picked by an engine — you can't tell which from the page.
Judge on sound, not on whether you like the song. Progress saves automatically, so you can
close this and come back.</p>
<div class="bar"><div id="bar"></div></div>
<div class="muted" id="count"></div>
<div class="seed" id="seed"></div>
<div class="pair" id="pair"></div>
<button class="both" id="both">Both are about equally close</button>
<div class="row">
  <button class="link" id="skip">can't tell / neither works</button>
  <button class="link" id="back">undo last</button>
  <button class="link" id="show">show results so far</button>
  <span class="saved" id="saved"></span>
</div>
<div id="done" hidden><h2>Results</h2>
 <p class="muted">Paste this back into the conversation. Partial is fine.</p>
 <textarea id="out"></textarea>
 <div class="row"><button id="copy">copy</button><button class="link" id="resume">keep going</button></div>
</div>
<script>
const TRIALS = __TRIALS__;
const KEY = 'mozz.listening.' + TRIALS.length + '.' + (TRIALS[0] ? TRIALS[0].seed.key : '0');
const el = id => document.getElementById(id);
let picks = [];
try { picks = JSON.parse(localStorage.getItem(KEY) || '[]'); } catch (e) { picks = []; }

function save(){
  try {
    localStorage.setItem(KEY, JSON.stringify(picks));
    el('saved').textContent = 'saved ' + picks.length + '/' + TRIALS.length;
  } catch (e) {
    el('saved').textContent = 'could not save — copy your results before closing';
  }
}
function card(side, track){
  return `<div class="card"><b>${side}</b><div class="muted">${track.title}</div>
   <audio controls preload="none" src="file://${encodeURI(track.clip)}"></audio>
   <button data-side="${side.toLowerCase()}">${side} sounds closer</button></div>`;
}
function render(){
  const i = picks.length;
  el('bar').style.width = (i / TRIALS.length * 100) + '%';
  if (i >= TRIALS.length){ finish(); return; }
  const t = TRIALS[i];
  el('done').hidden = true;
  el('seed').hidden = el('pair').hidden = false;
  el('both').hidden = false;
  el('count').textContent = `Trial ${i+1} of ${TRIALS.length}`;
  el('seed').innerHTML = `<b>SEED</b><div class="muted">${t.seed.artist} — ${t.seed.title}</div>
    <audio controls preload="none" src="file://${encodeURI(t.seed.clip)}"></audio>`;
  el('pair').innerHTML = card('A', t.left) + card('B', t.right);
  el('pair').querySelectorAll('button').forEach(b => b.onclick = () => choose(b.dataset.side));
}
function record(value){
  const t = TRIALS[picks.length];
  picks.push({seed: t.seed.artist + ' — ' + t.seed.title, chose: value});
  save(); render();
}
function choose(side){
  const t = TRIALS[picks.length];
  record(side === 'a' ? t.leftEngine : t.rightEngine);
}
el('both').onclick = () => record('both');
el('skip').onclick = () => record('skip');
el('back').onclick = () => { picks.pop(); save(); render(); };
el('show').onclick = () => finish(true);
el('resume').onclick = () => render();
el('copy').onclick = () => { el('out').select(); document.execCommand('copy'); };
function finish(partial){
  el('seed').hidden = el('pair').hidden = el('both').hidden = true;
  el('count').textContent = partial ? 'Partial results — you can keep going.' : 'Done.';
  el('done').hidden = false;
  const tally = picks.reduce((m,p) => (m[p.chose] = (m[p.chose]||0)+1, m), {});
  el('out').value = JSON.stringify({completed: picks.length, of: TRIALS.length, tally, picks}, null, 1);
}
save(); render();
</script>"""
out = OUT
out.write_text(html.replace("__TRIALS__", json.dumps(trials)))
print(f"{len(trials)} trials -> {out}")
