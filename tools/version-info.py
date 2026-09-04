#!/usr/bin/env python3
"""Resolve Mozz's build-time version once for every platform."""

from __future__ import annotations

import argparse
import datetime as dt
import os
import pathlib
import re
import shlex
import subprocess
import sys


REPO = pathlib.Path(__file__).resolve().parents[1]
COUNTER_FILE = REPO / ".mozz-dev-build"


def run_git(*args: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=REPO,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    value = result.stdout.strip()
    return value or None


def calver(today: dt.date) -> str:
    return f"{today.year}.{today.month}.{today.day}"


def dirty_build_number(base: str) -> str:
    status = run_git("status", "--porcelain")
    if not status:
        return base

    dev_n = 1
    if COUNTER_FILE.exists():
        parts = COUNTER_FILE.read_text(encoding="utf-8").split()
        if len(parts) >= 2 and parts[0] == base:
            try:
                dev_n = int(parts[1]) + 1
            except ValueError:
                dev_n = 1

    COUNTER_FILE.write_text(f"{base} {dev_n}\n", encoding="utf-8")
    return f"{base}.{dev_n}"


def numeric_version(marketing: str, build: str) -> str:
    pieces: list[int] = []
    for raw in re.split(r"[.-]", marketing):
        if raw.isdigit():
            pieces.append(int(raw, 10))
        if len(pieces) == 3:
            break

    while len(pieces) < 3:
        pieces.append(0)

    build_base = build.split(".", 1)[0]
    pieces.append(int(build_base, 10) if build_base.isdigit() else 0)
    return ".".join(str(min(max(piece, 0), 65535)) for piece in pieces[:4])


def resolve() -> dict[str, str]:
    marketing = os.environ.get("MOZZ_MARKETING_VERSION", "").strip()
    if not marketing:
        marketing = calver(dt.datetime.now().date())

    build = os.environ.get("MOZZ_BUILD_NUMBER", "").strip()
    if not build:
        build = run_git("rev-list", "--count", "HEAD") or "1"
        build = dirty_build_number(build)

    display = f"{marketing} ({build})" if build else marketing
    assembly = numeric_version(marketing, build)
    return {
        "marketing": marketing,
        "build": build,
        "display": display,
        "assembly": assembly,
        "file": assembly,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--format", choices=["shell", "msbuild-lines"], default="shell")
    parser.add_argument("--field", choices=["marketing", "build", "display", "assembly", "file"])
    args = parser.parse_args()

    values = resolve()
    if args.field:
        print(values[args.field])
        return 0

    if args.format == "shell":
        names = {
            "marketing": "MOZZ_RESOLVED_MARKETING_VERSION",
            "build": "MOZZ_RESOLVED_BUILD_NUMBER",
            "display": "MOZZ_RESOLVED_DISPLAY_VERSION",
            "assembly": "MOZZ_RESOLVED_ASSEMBLY_VERSION",
            "file": "MOZZ_RESOLVED_FILE_VERSION",
        }
        for key, name in names.items():
            print(f"{name}={shlex.quote(values[key])}")
    else:
        print(f"MozzMarketingVersion={values['marketing']}")
        print(f"MozzBuildNumber={values['build']}")
        print(f"MozzDisplayVersion={values['display']}")
        print(f"MozzAssemblyVersion={values['assembly']}")
        print(f"MozzFileVersion={values['file']}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
