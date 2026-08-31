#!/usr/bin/env python3
"""Convert a Mozz pixel-art SVG logo into an Android VectorDrawable.

The brand marks are 32x32 pixel art: a silhouette path, a few hundred one-pixel
rects, and translucent shading groups. Every one of those maps onto a
VectorDrawable path, so this is a transcription rather than a trace — the result
is the same artwork, crisp at any size, with no raster step.

Three things the naive version of this gets wrong, all of them present in the
real files:

  * `transform="rotate(180 cx cy)"` on a rect. VectorDrawable has <group> with a
    rotation, but wrapping every rect in its own group is absurd when a 180 turn
    about a point is just arithmetic on the rect's corner.
  * `<g opacity="...">`. VectorDrawable groups have no opacity, so the value has
    to be pushed down onto each child as android:fillAlpha.
  * SVG colour *names*. `fill="white"` is valid SVG and is a resource-linking
    error in an Android drawable.

Usage:
    tools/svg-to-vector-drawable.py IN.svg OUT.xml [--size 32] [--scale 1.0]
"""

import argparse
import html
import re
import sys
import xml.etree.ElementTree as ElementTree

SVG_NS = "{http://www.w3.org/2000/svg}"

# The only colour names the brand files use. Kept deliberately short: an
# unrecognised name should fail loudly rather than be guessed at.
NAMED_COLOURS = {"white": "#FFFFFFFF", "black": "#FF000000", "none": None}


def colour(value):
    if value is None:
        return None
    value = value.strip()
    if value.startswith("#"):
        return value
    if value in NAMED_COLOURS:
        return NAMED_COLOURS[value]
    raise SystemExit(f"unrecognised colour {value!r} — add it to NAMED_COLOURS")


def number(text, default=0.0):
    return float(text) if text not in (None, "") else default


def trim(value):
    return f"{value:g}"


def rect_to_path(element):
    """A rect, as path data, with any 180-degree rotation already applied."""
    x = number(element.get("x"))
    y = number(element.get("y"))
    width = number(element.get("width"))
    height = number(element.get("height"))

    transform = element.get("transform")
    if transform:
        match = re.fullmatch(
            r"\s*rotate\(\s*180\s+([-\d.]+)\s+([-\d.]+)\s*\)\s*", transform
        )
        if not match:
            raise SystemExit(
                f"unsupported transform {transform!r}; only rotate(180 cx cy) is handled"
            )
        centre_x, centre_y = float(match.group(1)), float(match.group(2))
        # Rotating a rectangle half a turn about a point maps its top-left corner
        # to the opposite corner of the rotated rectangle.
        x, y = 2 * centre_x - x - width, 2 * centre_y - y - height

    return f"M{trim(x)},{trim(y)} h{trim(width)} v{trim(height)} h-{trim(width)} z"


def walk(element, inherited_alpha, out):
    for child in element:
        tag = child.tag.replace(SVG_NS, "")
        alpha = inherited_alpha * number(child.get("opacity"), 1.0)

        if tag == "g":
            walk(child, alpha, out)
            continue

        if tag == "path":
            data = child.get("d")
            if not data:
                continue
        elif tag == "rect":
            data = rect_to_path(child)
        else:
            continue

        fill = colour(child.get("fill"))
        if fill is None:
            continue

        attributes = [f'android:fillColor="{fill}"']
        if alpha < 1.0:
            attributes.append(f'android:fillAlpha="{alpha:g}"')
        attributes.append(f'android:pathData="{html.escape(data, quote=True)}"')
        out.append("    <path\n        " + "\n        ".join(attributes) + " />")


def convert(source, size, scale):
    root = ElementTree.parse(source).getroot()
    viewbox = (root.get("viewBox") or "0 0 32 32").split()
    viewport_width, viewport_height = float(viewbox[2]), float(viewbox[3])

    paths = []
    walk(root, 1.0, paths)

    body = "\n".join(paths)
    if scale != 1.0:
        # Centre the artwork at the requested scale — what an adaptive launcher
        # icon needs, where the art must sit inside a safe zone rather than fill
        # the canvas.
        offset_x = viewport_width * (1 - scale) / 2
        offset_y = viewport_height * (1 - scale) / 2
        body = (
            f'    <group\n'
            f'        android:scaleX="{scale:g}"\n'
            f'        android:scaleY="{scale:g}"\n'
            f'        android:translateX="{offset_x:g}"\n'
            f'        android:translateY="{offset_y:g}">\n'
            + "\n".join("    " + line for line in body.split("\n"))
            + "\n    </group>"
        )

    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        f'<!-- Generated from {source} by tools/svg-to-vector-drawable.py.\n'
        '     Do not edit by hand; regenerate when the brand mark changes. -->\n'
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
        f'    android:width="{size}dp"\n'
        f'    android:height="{size}dp"\n'
        f'    android:viewportWidth="{trim(viewport_width)}"\n'
        f'    android:viewportHeight="{trim(viewport_height)}">\n'
        f"{body}\n</vector>\n"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source")
    parser.add_argument("destination")
    parser.add_argument("--size", type=int, default=32, help="intrinsic dp size")
    parser.add_argument("--scale", type=float, default=1.0, help="scale the art within the viewport")
    arguments = parser.parse_args()

    xml = convert(arguments.source, arguments.size, arguments.scale)
    with open(arguments.destination, "w") as handle:
        handle.write(xml)
    print(f"{arguments.destination}: {xml.count('<path')} paths", file=sys.stderr)


if __name__ == "__main__":
    main()
