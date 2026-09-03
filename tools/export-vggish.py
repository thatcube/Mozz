#!/usr/bin/env python3
"""Export VGGish's convolutional trunk for `VGGishTrunk.swift`.

Writes three things:
  vggish-trunk.bin   the weights, fp16 kernels + fp32 biases (9 MB)
  conv-fixture.json  one input patch and the embedding PyTorch computes for it
  mel-fixture.json   a known waveform and the log-mel patch it produces

The fixtures are the point. Porting a model is only defensible if the port is
shown to compute the same thing, and an iPhone's vectors have to be comparable
with a Pixel's — so `Tests/MozzAnalysisTests/VGGishTrunkTests.swift` checks the
Swift output against these rather than trusting that six convolutions are hard
to get wrong.

Weights are Google's VGGish (Apache 2.0), via the `torchvggish` port. Only the
convolutional trunk is exported: the two 4096-wide dense layers above it are
96% of the file, are trained to classify AudioSet events rather than to place
music, and measurably HURT the ranking (76.5% vs 78.3% genre top-3).

    pip install torch torchvggish
    python3 tools/export-vggish.py --out <dir>
"""
import argparse
import json
import pathlib
import struct

import numpy as np
import torch
from torchvggish import vggish
import torchvggish.vggish_input as vggish_input


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True, help="directory to write into")
    args = parser.parse_args()
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    model = vggish()
    model.eval()
    trunk = model.features

    # --- weights -----------------------------------------------------------
    convs = [layer for layer in trunk if isinstance(layer, torch.nn.Conv2d)]
    blob = bytearray(b"MZVG")
    blob += struct.pack("<II", 1, len(convs))
    for layer in convs:
        weight = layer.weight.detach().numpy()          # (out, in, 3, 3)
        bias = layer.bias.detach().numpy()
        blob += struct.pack("<IIII", *weight.shape)
        blob += weight.astype(np.float16).tobytes()     # half: 9 MB, not 18
        blob += bias.astype(np.float32).tobytes()       # tiny; keep full range
    (out / "vggish-trunk.bin").write_bytes(blob)
    print(f"vggish-trunk.bin  {len(blob)/1e6:.1f} MB")

    # --- mel fixture: a waveform whose spectrum is known by construction ----
    rate = 16000
    t = np.arange(rate * 2) / rate
    wave = (0.4 * np.sin(2 * np.pi * 220 * t)
            + 0.25 * np.sin(2 * np.pi * 1310 * t)
            + 0.1 * np.sin(2 * np.pi * 5000 * t))
    examples = vggish_input.waveform_to_examples(wave, rate, return_tensor=False)
    patch = np.asarray(examples[0], dtype=np.float32)
    json.dump({"sampleRate": rate, "waveformSeconds": 2,
               "patch": patch.reshape(-1).tolist(),
               "patchShape": list(patch.shape)},
              open(out / "mel-fixture.json", "w"))
    print(f"mel-fixture.json  {patch.shape}")

    # --- conv fixture: that same patch, and what the trunk makes of it ------
    tensor = torch.from_numpy(patch.reshape(1, 1, *patch.shape))
    with torch.no_grad():
        feats = trunk(tensor)
        embedding = feats.amax(dim=(2, 3))[0].numpy()
    json.dump({"input": patch.reshape(-1).tolist(),
               "inputShape": list(patch.shape),
               "embedding": embedding.tolist()},
              open(out / "conv-fixture.json", "w"))
    print(f"conv-fixture.json {int((embedding != 0).sum())}/{embedding.size} non-zero")


if __name__ == "__main__":
    main()
