#!/usr/bin/env bash
#
# Which capabilities each shell can actually reach.
#
# Mozz's rule is that a platform lacking a capability is *behind*, never
# *exempt*. That is easy to agree with and hard to notice breaking, because a
# command can exist in the schema, be implemented in the core, be present in
# every generated client, and still be reachable from exactly one app. Nothing
# about the build objects. Downloads, lyrics, similar tracks and artwork were
# all in that state and none of them looked wrong from inside the iOS app.
#
# So: count the commands each shell's HAND-WRITTEN code actually calls. The
# generated clients are excluded deliberately - they mention every command by
# construction, which is what makes the naive version of this check report
# perfect parity while a shell cannot download a single track.
#
#   tools/check-parity.sh            report what each shell can reach
#   tools/check-parity.sh --check    fail if a shell lost access to something
#   tools/check-parity.sh --record   accept the current state as the baseline
#
# The baseline is a floor, not a target. It exists so that closing a gap is
# easy to bank and reopening one is not possible by accident.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE="$ROOT/spec/parity.txt"
PROTO="$ROOT/schema/mozz/v1/library.proto"

pascal() {
  python3 -c "import sys; print(''.join(w.capitalize() for w in sys.argv[1].split('_')))" "$1"
}

commands() {
  grep -oE "^[[:space:]]+[A-Za-z]+Request [a-z_]+ = [0-9]+;" "$PROTO" | awk '{print $2}' | sort
}

# A shell "reaches" a command when its own code names the command's message.
reaches() {
  local shell="$1" name="$2"
  case "$shell" in
    apple)
      grep -rqi "$name" "$ROOT/Sources/MozzApp" --include=*.swift 2>/dev/null
      ;;
    desktop)
      grep -rqi "$name" "$ROOT/clients/desktop" --include=*.cs --exclude-dir=Generated 2>/dev/null
      ;;
  esac
}

surface() {
  local shell
  for shell in apple desktop; do
    local reached=0 total=0
    for command in $(commands); do
      total=$((total + 1))
      if reaches "$shell" "$(pascal "$command")"; then
        reached=$((reached + 1))
      fi
    done
    echo "$shell $reached $total"
  done
}

missing_for() {
  local shell="$1"
  for command in $(commands); do
    reaches "$shell" "$(pascal "$command")" || echo "$command"
  done
}

SURFACE="$(surface)"

case "${1:-}" in
  --record)
    mkdir -p "$(dirname "$BASELINE")"
    printf '%s\n' "$SURFACE" > "$BASELINE"
    echo "✓ Recorded:"
    printf '%s\n' "$SURFACE" | awk '{ printf "  %-10s %s/%s\n", $1, $2, $3 }'
    ;;

  --check)
    if [ ! -f "$BASELINE" ]; then
      echo "✗ No baseline at $BASELINE. Run tools/check-parity.sh --record." >&2
      exit 1
    fi
    failed=0
    while read -r shell reached total; do
      [ -z "$shell" ] && continue
      was="$(awk -v s="$shell" '$1 == s { print $2 }' "$BASELINE")"
      [ -z "$was" ] && continue
      if [ "$reached" -lt "$was" ]; then
        echo "✗ The $shell shell reaches $reached commands, down from $was." >&2
        echo "  A capability that used to exist there does not any more." >&2
        failed=1
      fi
    done <<<"$SURFACE"
    [ "$failed" = "1" ] && exit 1
    echo "✓ No shell lost access to a capability."
    ;;

  *)
    echo "Commands each shell can reach (generated clients excluded):"
    printf '%s\n' "$SURFACE" | awk '{ printf "  %-10s %s of %s\n", $1, $2, $3 }'
    echo
    for shell in apple desktop; do
      gaps="$(missing_for "$shell")"
      if [ -n "$gaps" ]; then
        echo "  $shell cannot reach:"
        printf '%s\n' "$gaps" | sed 's/^/    /'
      fi
    done
    ;;
esac
