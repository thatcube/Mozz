#!/usr/bin/env bash
# Import curated Tabler (or any) SVGs into the app's asset catalog as vector
# TEMPLATE images. Rendered with `.resizable()`, they size EXACTLY to their
# SwiftUI `.frame(width:height:)` (no SF-Symbol cap-height shrinkage) and tint
# via `.foregroundStyle`, so icon sizing is predictable and WYSIWYG.
#
#   Source SVGs:  tools/icons/tabler-svg/*.svg   (curated subset we actually use)
#   Output:       Sources/MozzApp/Resources/Icons.xcassets/<name>.imageset/
#
# Reference from SwiftUI via the AppIcon enum (Sources/MozzApp/Support/AppIcon.swift),
# which renders custom icons as resizable template images and keeps SF Symbols for
# Apple-specific glyphs (AirPlay, AirPods…).
#
# Adding an icon: drop its SVG in tools/icons/tabler-svg/, run this script, add a
# case to AppIcon. No swiftdraw / SF Symbols app step required.
set -euo pipefail
cd "$(dirname "$0")/../.."

SVG_DIR="tools/icons/tabler-svg"
OUT="Sources/MozzApp/Resources/Icons.xcassets"

mkdir -p "$OUT"
cat > "$OUT/Contents.json" <<'JSON'
{
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

count=0
for f in "$SVG_DIR"/*.svg; do
  [ -e "$f" ] || continue
  name=$(basename "$f" .svg)
  setdir="$OUT/${name}.imageset"
  mkdir -p "$setdir"
  cp "$f" "$setdir/${name}.svg"
  cat > "$setdir/Contents.json" <<JSON
{
  "images" : [
    { "filename" : "${name}.svg", "idiom" : "universal" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : {
    "preserves-vector-representation" : true,
    "template-rendering-intent" : "template"
  }
}
JSON
  echo "✓ ${name}"
  count=$((count + 1))
done
echo "Imported ${count} icon(s) into ${OUT}"
