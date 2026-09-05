#!/usr/bin/env bash
#
# Every command the Android shell sends must be one the core answers.
#
# The two halves are joined by a string in a JSON envelope, which no compiler
# on either side checks. When a command is renamed in the core, Kotlin keeps
# compiling, the app keeps launching, and the feature is simply dead: the core
# returns "unknown command" and the shell's runCatching swallows it.
#
# Three had drifted before anyone looked - `setLiked` (renamed to
# `setFavorite`), `plexResolve` and `capabilities` (both sent by Android and
# never implemented in the envelope at all). Between them that was the like
# button, re-resolving a Plex server that changed address, and knowing whether
# to draw a heart or a star.
#
#   tools/check-ffi-commands.sh          list the commands and any drift
#   tools/check-ffi-commands.sh --check  exit non-zero if any command is unanswered
#
# Only the Android shell is checked here, because only Android speaks this
# envelope: iOS links the core directly and the desktop goes through protobuf,
# and both of those the compiler already keeps honest.
#
# The "answered" set is every `case "…"` in Sources/MozzFFI, which is broader
# than the command switches alone - a `case "plex"` matching a backend kind
# counts too. That errs toward silence rather than false alarms; it still
# catches a command with no handler anywhere, which is the failure that
# actually happened.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_DIR="$ROOT/clients/android/core/src/main/java/com/thatcube/mozz/core"
CORE_DIR="$ROOT/Sources/MozzFFI"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

sent="$(grep -rhoE 'cmd = "[a-zA-Z]+"' "$SHELL_DIR" | sed 's/cmd = //' | tr -d '"' | sort -u)"
answered="$(grep -rhoE 'case "[a-zA-Z]+"' "$CORE_DIR" | sed 's/case //' | tr -d '"' | sort -u)"

missing="$(comm -23 <(printf '%s\n' "$sent") <(printf '%s\n' "$answered"))"

printf 'Android sends %s commands; the core has %s handlers.\n' \
    "$(printf '%s\n' "$sent" | grep -c .)" \
    "$(printf '%s\n' "$answered" | grep -c .)"

if [ -z "$missing" ]; then
    echo "Every command Android sends has a handler."
    exit 0
fi

echo
echo "Sent by Android, answered by nobody:"
printf '%s\n' "$missing" | sed 's/^/  /'
echo
echo "Each of these fails at runtime and nowhere else. Either the core needs the"
echo "command or the shell is calling it by a name the core has stopped using."

[ "$CHECK" -eq 1 ] && exit 1
exit 0
