#!/usr/bin/env python3
"""Assemble the screenshot fixture: covers + audio + a manifest.

The app seeds its whole catalogue from this directory when it finds the fixture,
so screenshots come out of the real UI with the real artwork in place — which
matters because Mozz derives the Now Playing backdrop from the cover's own
colours, and that can't be composited in afterwards.

Input is an explicit spec rather than inferred filename matching: guessing which
audio file belongs to which cover is exactly the kind of silent mismatch that
stays invisible until a screenshot plays the wrong song.

    tools/make-screenshot-fixture.py SPEC.json [OUT_DIR]

Each spec entry:
    {"artist": …, "album": …, "genre": …, "year": …,
     "cover": "/abs/path.jpg",
     "tracks": [{"title": …, "file": "/abs/path.mp3",
                 "lyrics": "/abs/path.lrc"}]}   # lyrics optional
"""
import json
import pathlib
import shutil
import subprocess
import sys


def duration_of(path):
    """Seconds via ffprobe, recorded in the manifest so the app never has to
    measure a file at launch (AVAsset duration is async on iOS 16+)."""
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
            capture_output=True, text=True, timeout=30).stdout.strip()
        return round(float(out), 2) if out else None
    except Exception:  # noqa: BLE001
        return None


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    spec = json.loads(pathlib.Path(sys.argv[1]).read_text())
    out = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else "ScreenshotAssets")

    for sub in ("covers", "audio"):
        (out / sub).mkdir(parents=True, exist_ok=True)

    try:
        sys.path.insert(0, "/tmp")
        from PIL import Image
        from mozz_palette import backdrop_bands, spread
        can_score = True
    except Exception:  # noqa: BLE001
        can_score = False

    manifest, problems = [], []
    for entry in spec:
        cover = pathlib.Path(entry["cover"])
        if not cover.exists():
            problems.append(f"missing cover: {cover}")
            continue

        cover_rel = f"covers/{entry['artist']} - {entry['album']}.jpg"
        shutil.copy2(cover, out / cover_rel)

        tracks = []
        for track in entry["tracks"]:
            src = pathlib.Path(track["file"])
            if not src.exists():
                problems.append(f"missing audio: {src}")
                continue
            audio_rel = f"audio/{src.name}"
            if not (out / audio_rel).exists():
                shutil.copy2(src, out / audio_rel)
            row = {"title": track["title"], "file": audio_rel,
                   "duration": track.get("duration") or duration_of(out / audio_rel)}
            # Optional .lrc sidecar. The app's lyrics pane falls back to an online
            # provider, which has never heard of these tracks, so without a
            # sidecar the lyrics screenshot comes out blank.
            lrc = track.get("lyrics")
            if lrc:
                lrc = pathlib.Path(lrc)
                if lrc.exists():
                    (out / "lyrics").mkdir(parents=True, exist_ok=True)
                    lrc_rel = f"lyrics/{entry['artist']} - {track['title']}.lrc"
                    shutil.copy2(lrc, out / lrc_rel)
                    row["lyrics"] = lrc_rel
                else:
                    problems.append(f"missing lyrics: {lrc}")
            tracks.append(row)
        if not tracks:
            problems.append(f"no playable tracks for {entry['album']}, skipped")
            continue

        manifest.append({
            "artist": entry["artist"],
            "album": entry["album"],
            "year": entry.get("year", 2026),
            "genre": entry.get("genre", "Electronic"),
            "cover": cover_rel,
            "tracks": tracks,
        })

        if can_score:
            s = spread(backdrop_bands(Image.open(cover).convert("RGB")))
            flag = "" if s >= 0.30 else "  <-- flat backdrop"
            print(f"  {entry['album'][:26]:<28} {len(tracks)} track(s)  spread={s:.3f}{flag}")
        else:
            print(f"  {entry['album'][:26]:<28} {len(tracks)} track(s)")

    (out / "manifest.json").write_text(json.dumps(manifest, indent=1), encoding="utf-8")
    print(f"\n✓ {len(manifest)} albums -> {out}/manifest.json")
    for p in problems:
        print("  ! " + p)
    print(f"\nNow run:  tools/screenshots.sh {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
