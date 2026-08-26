#!/usr/bin/env bash
# Regenerate the command clients from schema/.
#
# Generated code is COMMITTED, not built on demand. The desktop builds on four
# targets (Windows, macOS, Linux x64, Linux arm64) and making protoc a
# prerequisite on all four buys fragility for no benefit. Committing the output
# also means an agent can read the generated client to learn what commands
# exist, and that schema changes are visible in a diff.
#
#   tools/generate-schema.sh          regenerate in place
#   tools/generate-schema.sh --check  fail if the committed output is stale (CI)
#
# See ADR-0016.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

SCHEMA_DIR="schema"
SWIFT_OUT="Sources/MozzSchema/Generated"
CSHARP_OUT="clients/desktop/Generated"

check_mode=false
[[ "${1:-}" == "--check" ]] && check_mode=true

missing=()
command -v protoc >/dev/null 2>&1 || missing+=("protoc  (brew install protobuf)")
command -v protoc-gen-swift >/dev/null 2>&1 || missing+=("protoc-gen-swift  (brew install swift-protobuf)")
if (( ${#missing[@]} )); then
  echo "Missing tools:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  exit 1
fi

protos=()
while IFS= read -r p; do protos+=("$p"); done < <(find "$SCHEMA_DIR" -name '*.proto' | sort)
if (( ${#protos[@]} == 0 )); then
  echo "No .proto files under $SCHEMA_DIR" >&2
  exit 1
fi

# Which tools produced the committed output.
#
# Generated code is committed, so it is a function of the schema AND of the
# generator that ran. Two different protoc-gen-swift versions can emit different
# but equally correct code, and --check would then fail on a machine whose brew
# is a week newer — reporting "stale" for something that is not stale at all.
# Record the versions so that failure can name itself.
STAMP="$SWIFT_OUT/.toolchain"

tool_versions() {
  printf 'protoc %s\n' "$(protoc --version | awk '{print $2}')"
  printf 'protoc-gen-swift %s\n' "$(protoc-gen-swift --version 2>&1 | awk '{print $NF}')"
}

generate_into() {
  local swift_dir="$1" csharp_dir="$2"
  mkdir -p "$swift_dir" "$csharp_dir"
  protoc --proto_path="$SCHEMA_DIR" \
         --swift_out="$swift_dir" \
         --csharp_out="$csharp_dir" \
         "${protos[@]}"
}

if $check_mode; then
  # Compare toolchains before comparing output, so a version difference reports
  # itself as a version difference rather than as phantom drift.
  if [[ -f "$STAMP" ]] && ! diff <(tool_versions) "$STAMP" >/dev/null 2>&1; then
    echo "Schema toolchain differs from the one that generated the committed output." >&2
    echo "This is a toolchain mismatch, NOT a stale schema. Committed with:" >&2
    sed 's/^/  /' "$STAMP" >&2
    echo "Running here:" >&2
    tool_versions | sed 's/^/  /' >&2
    echo "Install the recorded versions, or regenerate and commit with the newer ones." >&2
    exit 1
  fi

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  generate_into "$tmp/swift" "$tmp/csharp"
  tool_versions > "$tmp/swift/.toolchain"

  stale=false
  diff -ru "$ROOT/$SWIFT_OUT" "$tmp/swift" >/dev/null 2>&1 || stale=true
  diff -ru "$ROOT/$CSHARP_OUT" "$tmp/csharp" >/dev/null 2>&1 || stale=true

  if $stale; then
    echo "Generated clients are stale — schema/ changed but the output was not regenerated." >&2
    echo "Run tools/generate-schema.sh and commit the result." >&2
    diff -ru "$ROOT/$SWIFT_OUT" "$tmp/swift" || true
    diff -ru "$ROOT/$CSHARP_OUT" "$tmp/csharp" || true
    exit 1
  fi
  echo "Generated clients are up to date."
  exit 0
fi

rm -rf "$SWIFT_OUT" "$CSHARP_OUT"
generate_into "$SWIFT_OUT" "$CSHARP_OUT"
tool_versions > "$STAMP"

echo "Regenerated from ${#protos[@]} schema file(s):"
echo "  $SWIFT_OUT"
echo "  $CSHARP_OUT"
echo "Toolchain recorded in $STAMP:"
sed 's/^/  /' "$STAMP"
