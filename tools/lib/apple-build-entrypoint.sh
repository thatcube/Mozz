#!/usr/bin/env bash
#
# Mozz entrypoint adapter for the machine-wide Apple build/cleanup interlock.
#
# Direct invocations are re-executed under the frozen protocol wrapper. Nested
# invocations validate and reuse the inherited descriptor capability. Any
# partial or forged environment fails closed instead of starting a new lease.

MOZZ_APPLE_BUILD_ENTRYPOINT_SOURCE="${BASH_SOURCE[0]:-$0}"
MOZZ_APPLE_BUILD_ENTRYPOINT_DIR="$(
  cd "${MOZZ_APPLE_BUILD_ENTRYPOINT_SOURCE%/*}" >/dev/null 2>&1 && pwd -P
)"
MOZZ_APPLE_BUILD_REPO_ROOT="$(
  cd "$MOZZ_APPLE_BUILD_ENTRYPOINT_DIR/../.." >/dev/null 2>&1 && pwd -P
)"

source "$MOZZ_APPLE_BUILD_ENTRYPOINT_DIR/apple-build-lease.sh"

enter_mozz_apple_build_entrypoint() {
  local owner="$1" script="$2"
  shift 2

  case "$script" in
    /*) ;;
    *)
      script="$(
        cd "$(dirname "$script")" >/dev/null 2>&1 && pwd -P
      )/$(basename "$script")"
      ;;
  esac

  if _apple_build_lease_has_environment; then
    verify_apple_build_lease shared
    return
  fi

  exec "$MOZZ_APPLE_BUILD_REPO_ROOT/tools/with-apple-build-lease.sh" \
    "$owner" -- "$script" "$@"
}
