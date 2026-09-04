#!/usr/bin/env bash
#
# Stop the iOS app reaching further into the core than it already does.
#
# Every other shell talks to the core through the Facade: one command surface,
# one place where a capability either exists for everyone or exists for nobody.
# The Apple app has a private door - it imports core modules directly, 122 times
# across 13 of them - and that door is why a feature can ship on iOS and be
# invisible everywhere else without anyone noticing. Downloads, lyrics, similar
# tracks and artwork were all in exactly that state.
#
# Closing it is phased work. The point of this check is that the door cannot get
# wider while that happens: adding an import of a module the app does not
# already reach into fails the build, and adding more imports of one it does is
# reported so the number only moves down.
#
#   tools/check-shell-imports.sh            report the current surface
#   tools/check-shell-imports.sh --check     fail if it grew
#   tools/check-shell-imports.sh --record    accept the current surface as the baseline
#
# --record exists so that removing imports is easy to bank. It should only ever
# be run when the numbers went down.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE="$ROOT/spec/shell-imports.txt"
SHELL_DIR="$ROOT/Sources/MozzApp"

# Modules the app is allowed to keep importing forever.
#
# MozzAudioEngine is not on this list on purpose: audio is meant to arrive
# through the Facade too (ADR-0016), so it should never appear here at all.
ALWAYS_ALLOWED="MozzCommands|MozzSchema"

current_surface() {
  grep -rhoE "^import Mozz[A-Za-z]+" "$SHELL_DIR" --include=*.swift 2>/dev/null \
    | sed 's/^import //' \
    | grep -vE "^($ALWAYS_ALLOWED)$" \
    | sort | uniq -c | awk '{ printf "%s %s\n", $2, $1 }' | sort
}

SURFACE="$(current_surface)"

case "${1:-}" in
  --record)
    mkdir -p "$(dirname "$BASELINE")"
    printf '%s\n' "$SURFACE" > "$BASELINE"
    echo "✓ Recorded $(wc -l <<<"$SURFACE" | tr -d ' ') modules as the baseline."
    printf '%s\n' "$SURFACE" | sed 's/^/  /'
    ;;

  --check)
    if [ ! -f "$BASELINE" ]; then
      echo "✗ No baseline at $BASELINE. Run tools/check-shell-imports.sh --record." >&2
      exit 1
    fi

    failed=0
    while read -r module count; do
      [ -z "$module" ] && continue
      was="$(awk -v m="$module" '$1 == m { print $2 }' "$BASELINE")"
      if [ -z "$was" ]; then
        echo "✗ MozzApp now imports $module, which it did not before." >&2
        echo "  The Apple app is meant to reach the core through the Facade, not" >&2
        echo "  around it. Add a command instead — that is what makes the same" >&2
        echo "  capability exist on every platform rather than only this one." >&2
        failed=1
      elif [ "$count" -gt "$was" ]; then
        echo "✗ MozzApp imports $module $count times, up from $was." >&2
        echo "  This number is only allowed to go down." >&2
        failed=1
      fi
    done <<<"$SURFACE"

    [ "$failed" = "1" ] && exit 1
    echo "✓ The Apple app has not reached further into the core."
    ;;

  *)
    echo "Direct core imports in MozzApp (lower is better):"
    printf '%s\n' "$SURFACE" | awk '{ printf "  %-20s %s\n", $1, $2 }'
    printf '%s\n' "$SURFACE" | awk '{ total += $2 } END { printf "  %-20s %s\n", "TOTAL", total }'
    ;;
esac
