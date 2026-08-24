#!/usr/bin/env python3
"""Rebuild the app icons from the pixel-art logo.

WHY THIS EXISTS

The logo is a 32x32 pixel-art SVG. Every platform wants it at a different size,
and getting there by hand invites two mistakes that are easy to make and hard to
notice: resampling that blurs the pixel grid, and padding that drifts so the
disc sits at a different size on each platform.

So the rules are enforced here rather than remembered:

  * The SVG is rendered by a real browser engine, not ImageMagick. MSVG does not
    handle the layered/opacity structure this file uses and silently produces a
    muddier, differently-shaded disc — it looks plausible until you compare it
    side by side with the source.

  * Rendering happens at an exact integer multiple of 32 (832 = 26x), so every
    logo pixel lands on a whole number of device pixels and the art stays crisp.
    Anything else soft-edges the whole thing.

  * Downscales use a box filter at exact integer divisors where possible, and
    Lanczos otherwise, because a nearest-neighbour downscale of pixel art drops
    entire rows of pixels — including, at small sizes, parts of the face.

  * The disc lands on exactly the pixels the previous icon's disc occupied, so
    the background gradient underneath is reused rather than reconstructed. That
    is why the source icons are read rather than regenerated: matching a subtle
    radial gradient by eye is a fool's errand when the real thing is right there.

USAGE

    tools/make-icons.py path/to/logo.svg

Writes the iOS light/dark app icons, the desktop window icon, and the .ico for
Windows. Requires Pillow and Google Chrome (headless).
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parent.parent
IOS_ICONSET = REPO / "App/Mozz/Assets.xcassets/AppIcon.appiconset"
DESKTOP_ASSETS = REPO / "clients/desktop/Assets"

# The logo grid. Rendering at a multiple of this keeps pixels square.
GRID = 32
# 26x the grid. Chosen so the disc lands exactly where the previous icon's disc
# was: the art occupies 28 of 32 units, 28 * 26 = 728px, centred in 1024.
RENDER = 832
CANVAS = 1024

CHROME_CANDIDATES = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    shutil.which("google-chrome") or "",
    shutil.which("chromium") or "",
]


def find_chrome() -> str:
    for candidate in CHROME_CANDIDATES:
        if candidate and os.path.exists(candidate):
            return candidate
    sys.exit(
        "Could not find Chrome or Chromium.\n"
        "It is used to rasterise the SVG because ImageMagick's SVG renderer "
        "mishandles the logo's layered opacity groups."
    )


def render_svg(svg: Path, size: int) -> Image.Image:
    """Rasterise the SVG at `size` with the pixel grid preserved."""
    chrome = find_chrome()
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        shutil.copy(svg, tmp / "logo.svg")
        (tmp / "page.html").write_text(
            "<!doctype html><html><head><style>"
            "html,body{margin:0;padding:0;background:transparent}"
            f"img{{width:{size}px;height:{size}px;"
            "image-rendering:pixelated;display:block}"
            "</style></head><body><img src='logo.svg'></body></html>"
        )
        out = tmp / "out.png"
        subprocess.run(
            [
                chrome, "--headless", "--disable-gpu", "--hide-scrollbars",
                "--default-background-color=00000000",
                f"--screenshot={out}", f"--window-size={size},{size}",
                f"file://{tmp / 'page.html'}",
            ],
            check=True, capture_output=True,
        )
        return Image.open(out).convert("RGBA").copy()


def downscale(image: Image.Image, size: int) -> Image.Image:
    """Shrink without dropping rows of pixel art.

    An exact integer divisor uses a box filter, which averages each source block
    and therefore keeps every pixel represented. Otherwise Lanczos, which is
    softer but still preserves the shapes — nearest-neighbour at these ratios
    deletes whole rows, and at small sizes that eats part of the face.
    """
    if image.width == size:
        return image
    if image.width % size == 0:
        return image.resize((size, size), Image.BOX)
    return image.resize((size, size), Image.LANCZOS)


def compose_on_existing(art: Image.Image, base_path: Path) -> Image.Image:
    """Place the disc onto the previous icon's background.

    The disc occupies exactly the pixels the old one did, so the gradient behind
    it survives untouched and the new icon sits on the same background as the
    old — no attempt to re-derive a radial gradient by sampling.
    """
    base = Image.open(base_path).convert("RGBA")
    if base.size != (CANVAS, CANVAS):
        base = base.resize((CANVAS, CANVAS), Image.LANCZOS)
    canvas = base.copy()
    offset = (CANVAS - art.width) // 2
    canvas.alpha_composite(art, (offset, offset))
    return canvas


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} <logo.svg>")
    svg = Path(sys.argv[1]).resolve()
    if not svg.exists():
        sys.exit(f"no such file: {svg}")

    art = render_svg(svg, RENDER)
    print(f"rendered {svg.name} at {RENDER}px ({RENDER // GRID}x the {GRID}px grid)")

    # iOS: light and dark, disc over each existing background.
    for name in ("icon-1024.png", "icon-1024-dark.png"):
        target = IOS_ICONSET / name
        if not target.exists():
            sys.exit(f"missing base icon {target} — the background comes from it")
        compose_on_existing(art, target).convert("RGB").save(target)
        print(f"  wrote {target.relative_to(REPO)}")

    # Desktop: the window/taskbar icon, transparent rather than on a plate,
    # because every desktop draws its own frame around it.
    DESKTOP_ASSETS.mkdir(parents=True, exist_ok=True)
    png = DESKTOP_ASSETS / "mozz.png"
    downscale(art, 512).save(png)
    print(f"  wrote {png.relative_to(REPO)}")

    # Windows wants a multi-resolution .ico; small sizes are what appear in the
    # taskbar and title bar, so they are worth getting right rather than letting
    # the OS shrink 512px art on the fly.
    ico = DESKTOP_ASSETS / "mozz.ico"
    sizes = [256, 128, 64, 48, 32, 16]
    downscale(art, 256).save(ico, format="ICO", sizes=[(s, s) for s in sizes])
    print(f"  wrote {ico.relative_to(REPO)} ({', '.join(map(str, sizes))})")

    # A canonical copy of the source, so the next regeneration does not depend on
    # finding the original attachment again.
    stored = REPO / "tools/icons/mozz-logo.svg"
    stored.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(svg, stored)
    print(f"  wrote {stored.relative_to(REPO)}")


if __name__ == "__main__":
    main()
