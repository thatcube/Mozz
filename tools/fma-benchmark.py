#!/usr/bin/env python3
"""Lay out the Free Music Archive's `small` set the way the benchmark reads it.

The benchmark in `Tests/MozzAnalysisTests/SonicBenchmarkTests.swift` wants one
folder per label:

    <out>/Rock/000123.mp3
    <out>/Hip-Hop/000456.mp3

FMA ships its audio in numbered buckets and its labels in a separate CSV, so
this joins the two. Symlinks, not copies — the audio is several gigabytes and
nothing here modifies it.

FMA is CC-licensed music published for exactly this purpose, which is why it is
the set used here rather than a scrape of anybody's library.

    python3 tools/fma-benchmark.py --audio <dir>/fma_small \\
        --tracks <dir>/fma_metadata/tracks.csv --out <dir>/labelled [--per-label 150]

Then:

    MOZZ_BENCHMARK_DIR=<dir>/labelled swift test --filter SonicBenchmarkTests
"""
import argparse
import csv
import os
import pathlib

# Column positions in FMA's three-row header. Checked against the header rather
# than trusted, because a silently shifted column would relabel the whole set.
SUBSET_COLUMN = 32
GENRE_COLUMN = 40


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True, help="the unpacked fma_small directory")
    parser.add_argument("--tracks", required=True, help="fma_metadata/tracks.csv")
    parser.add_argument("--out", required=True, help="where to build the labelled tree")
    parser.add_argument("--per-label", type=int, default=150,
                        help="tracks per label; the set is balanced, so keep it that way")
    parser.add_argument("--subset", default="small")
    args = parser.parse_args()

    with open(args.tracks, newline="") as handle:
        reader = csv.reader(handle)
        first, second = next(reader), next(reader)
        next(reader)  # the units row, which is empty for these columns
        assert second[SUBSET_COLUMN] == "subset", f"unexpected column {second[SUBSET_COLUMN]}"
        assert second[GENRE_COLUMN] == "genre_top", f"unexpected column {second[GENRE_COLUMN]}"

        wanted: dict[str, list[str]] = {}
        for row in reader:
            if len(row) <= GENRE_COLUMN or row[SUBSET_COLUMN] != args.subset:
                continue
            genre = row[GENRE_COLUMN]
            if not genre:
                continue
            bucket = wanted.setdefault(genre, [])
            if len(bucket) < args.per_label:
                bucket.append(row[0])

    audio = pathlib.Path(args.audio)
    out = pathlib.Path(args.out)
    linked = missing = 0
    for genre, ids in sorted(wanted.items()):
        folder = out / genre
        folder.mkdir(parents=True, exist_ok=True)
        for track_id in ids:
            padded = f"{int(track_id):06d}"
            source = audio / padded[:3] / f"{padded}.mp3"
            if not source.exists():
                missing += 1
                continue
            link = folder / f"{padded}.mp3"
            if not link.exists():
                os.symlink(source.resolve(), link)
            linked += 1
        print(f"{genre:<16} {len(list(folder.iterdir()))}")
    print(f"\nlinked {linked} tracks into {out}" + (f" ({missing} missing from the archive)" if missing else ""))


if __name__ == "__main__":
    main()
