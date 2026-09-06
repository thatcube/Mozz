#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT/tools/lib/apple_build_lease.py"
SHELL_LIB="$ROOT/tools/lib/apple-build-lease.sh"
RUBY_LIB="$ROOT/tools/lib"
WRAPPER="$ROOT/tools/with-apple-build-lease.sh"
TMP="$(mktemp -d -t mozz-build-interlock-tests)"
FIXTURE_PIDS=()

cleanup() {
  local pid
  for pid in "${FIXTURE_PIDS[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  grep -F "$2" "$1" >/dev/null || fail "expected '$2' in $1"
}

assert_source_contains() {
  grep -F "$2" "$ROOT/$1" >/dev/null ||
    fail "expected writer lease '$2' in $1"
}

lease_root() {
  printf '%s/.config/smart-disk-maintenance/apple-build-interlock-v1\n' "$1"
}

new_home() {
  local name="$1" home root
  home="$TMP/$name/home"
  mkdir -p "$home"
  chmod 700 "$home"
  root="$(lease_root "$home")"
  mkdir -p "$(dirname "$root")"
  : > "$(dirname "$root")/.apple-build-interlock-test-root"
  chmod 600 "$(dirname "$root")/.apple-build-interlock-test-root"
  printf '%s\n' "$home"
}

test_env() {
  local home="$1"
  shift
  env \
    HOME="$home" \
    APPLE_BUILD_INTERLOCK_TESTING=1 \
    APPLE_BUILD_INTERLOCK_TEST_ROOT="$(lease_root "$home")" \
    "$@"
}

record_count() {
  local leases
  leases="$(lease_root "$1")/leases"
  [[ -d "$leases" ]] || { echo 0; return; }
  find "$leases" -mindepth 1 -maxdepth 1 -type f -name '*.json' |
    wc -l | tr -d ' '
}

wait_for_file() {
  local path="$1" i
  for ((i = 0; i < 100; i++)); do
    [[ -e "$path" ]] && return 0
    sleep 0.05
  done
  fail "timed out waiting for $path"
}

wait_for_no_records() {
  local home="$1" i
  for ((i = 0; i < 100; i++)); do
    [[ "$(record_count "$home")" == "0" ]] && return 0
    sleep 0.05
  done
  test_env "$home" /usr/bin/python3 "$HELPER" inspect >&2 || true
  fail "lease records did not clear under $home"
}

write_rollout() {
  local home="$1" root
  root="$(lease_root "$home")"
  test_env "$home" /usr/bin/python3 "$HELPER" prepare
  test_env "$home" /usr/bin/python3 "$HELPER" required-rollout \
    > "$root/rollout-policy-v1"
  chmod 600 "$root/rollout-policy-v1"
}

exclusive_probe() {
  local home="$1"
  test_env "$home" "$WRAPPER" --exclusive test/exclusive-probe -- /usr/bin/true \
    >/dev/null 2>&1
}

start_shared() {
  local home="$1" owner="$2" ready="$3" release="$4"
  test_env "$home" "$WRAPPER" "$owner" -- /bin/sh -c '
    touch "$1"
    while [ ! -e "$2" ]; do sleep 0.05; done
  ' _ "$ready" "$release" >/dev/null 2>&1 &
  LAST_PID=$!
  FIXTURE_PIDS+=("$LAST_PID")
}

assert_sha256() {
  local path="$1" expected="$2" actual
  actual="$(shasum -a 256 "$ROOT/$path" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] ||
    fail "$path differs from the frozen Plozz protocol copy"
}

assert_sha256 \
  tools/lib/apple-build-lease.sh \
  bcb0a687d32ffa740953a687c812515d2516bd0ba90ea824c01c21fc6303c705
assert_sha256 \
  tools/lib/apple_build_lease.py \
  56a54b71f9a642ddd5e10a51128bc59610cbe6e3f9600cc7f6799c3b196bdca2
assert_sha256 \
  tools/lib/apple_build_lease.rb \
  c7726eaf3470da9dacbacbdf65d86ce353770f47da15882624be4455b7008372
assert_sha256 \
  tools/with-apple-build-lease.sh \
  dc3d932b08b8056704bd37920694952effca451abb155cce1cf8e356752f1b99

declare -a SHELL_WRITERS=(
  "tools/generate-project.sh|mozz/generate-project"
  "tools/build-ios.sh|mozz/build-ios"
  "tools/deploy-device.sh|mozz/deploy-device"
  "tools/run-tests.sh|mozz/run-tests"
  "tools/run-ios.sh|mozz/run-ios"
  "tools/run-carplay-sim.sh|mozz/run-carplay-sim"
  "tools/screenshots.sh|mozz/screenshots"
  "tools/bootstrap-sim.sh|mozz/bootstrap-sim"
  "tools/install-verified.sh|mozz/install-verified"
  "tools/build-audio-xcframework.sh|mozz/build-audio-xcframework"
  "tools/build-audio-cdylib.sh|mozz/build-audio-cdylib"
  "tools/run-audio-abi-test.sh|mozz/run-audio-abi-test"
  "tools/build-macos-app.sh|mozz/build-macos-app"
)
for entry in "${SHELL_WRITERS[@]}"; do
  assert_source_contains "${entry%%|*}" \
    "enter_mozz_apple_build_entrypoint"
  assert_source_contains "${entry%%|*}" "${entry#*|}"
done

for owner in \
  mozz/fastlane/generate-project \
  mozz/fastlane/build \
  mozz/fastlane/beta \
  mozz/fastlane/release; do
  assert_source_contains fastlane/Fastfile \
    "AppleBuildLease.with_shared(\"$owner\")"
done
assert_source_contains .github/workflows/core-and-ios.yml \
  "mozz/ci-swift-test"
assert_source_contains .github/workflows/core-and-ios.yml \
  "mozz/ci-swift-release"
assert_source_contains .github/workflows/desktop-app.yml \
  "mozz/ci-macos-swift-release"
assert_source_contains .github/workflows/windows-ffi-spike.yml \
  "mozz/ci-windows-control-swift"
assert_source_contains .github/workflows/android-ffi-spike.yml \
  "mozz/ci-android-control-swift"
assert_source_contains .github/workflows/android-ffi-spike.yml \
  "mozz/ci-android-control-clang"
assert_source_contains .github/workflows/core-and-ios.yml \
  "tools/tests/test-apple-build-interlock.sh"

# Two readers coexist, while exclusive maintenance refuses immediately.
HOME_READERS="$(new_home readers)"
R1_READY="$TMP/r1.ready"; R1_RELEASE="$TMP/r1.release"
R2_READY="$TMP/r2.ready"; R2_RELEASE="$TMP/r2.release"
start_shared "$HOME_READERS" test/reader-one "$R1_READY" "$R1_RELEASE"
R1_PID="$LAST_PID"
start_shared "$HOME_READERS" test/reader-two "$R2_READY" "$R2_RELEASE"
R2_PID="$LAST_PID"
wait_for_file "$R1_READY"
wait_for_file "$R2_READY"
[[ "$(record_count "$HOME_READERS")" == "2" ]] ||
  fail "concurrent readers did not both acquire"
write_rollout "$HOME_READERS"
if exclusive_probe "$HOME_READERS"; then
  fail "exclusive maintenance acquired while readers were active"
fi
touch "$R1_RELEASE" "$R2_RELEASE"
wait "$R1_PID"
wait "$R2_PID"
wait_for_no_records "$HOME_READERS"

# The outer release lane remains leased across a deliberate no-build gap.
HOME_GAP="$(new_home release-gap)"
write_rollout "$HOME_GAP"
GAP_READY="$TMP/gap.ready"; GAP_CONTINUE="$TMP/gap.continue"
test_env "$HOME_GAP" "$WRAPPER" test/release-lane -- /bin/sh -c '
  touch "$1"
  while [ ! -e "$2" ]; do sleep 0.05; done
' _ "$GAP_READY" "$GAP_CONTINUE" >/dev/null 2>&1 &
GAP_PID=$!
FIXTURE_PIDS+=("$GAP_PID")
wait_for_file "$GAP_READY"
if exclusive_probe "$HOME_GAP"; then
  fail "exclusive maintenance acquired during a release-lane gap"
fi
touch "$GAP_CONTINUE"
wait "$GAP_PID"
wait_for_no_records "$HOME_GAP"

# Exercise a real nested Mozz entrypoint chain without invoking Xcode, Swift,
# Cargo, a simulator, or a device. Ruby owns the outer lease as Fastlane does;
# copied build-ios/generate-project entrypoints and command stubs must validate
# and reuse the same authenticated descriptor record.
FIXTURE="$TMP/entrypoint-chain"
mkdir -p "$FIXTURE/tools/lib" "$FIXTURE/bin"
cp "$ROOT/tools/build-ios.sh" "$FIXTURE/tools/"
cp "$ROOT/tools/generate-project.sh" "$FIXTURE/tools/"
cp "$ROOT/tools/with-apple-build-lease.sh" "$FIXTURE/tools/"
cp "$ROOT/tools/lib/apple-build-entrypoint.sh" "$FIXTURE/tools/lib/"
cp "$ROOT/tools/lib/apple-build-lease.sh" "$FIXTURE/tools/lib/"
cp "$ROOT/tools/lib/apple_build_lease.py" "$FIXTURE/tools/lib/"
chmod +x "$FIXTURE/tools/"*.sh
cat > "$FIXTURE/tools/version-info.py" <<'SH'
#!/usr/bin/env bash
printf '%s\n' \
  "MOZZ_RESOLVED_BUILD_NUMBER='1'" \
  "MOZZ_RESOLVED_MARKETING_VERSION='2026.9.6'"
SH
chmod +x "$FIXTURE/tools/version-info.py"
cat > "$FIXTURE/project.yml" <<'YML'
settings:
  base:
    CURRENT_PROJECT_VERSION: "1"
    MARKETING_VERSION: "0.1"
YML
cat > "$FIXTURE/bin/xcodegen" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/tools/lib/apple-build-lease.sh"
verify_apple_build_lease shared
count="$(find "$HOME/.config/smart-disk-maintenance/apple-build-interlock-v1/leases" \
  -mindepth 1 -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
printf '%s %s\n' "$APPLE_BUILD_LEASE_VALIDATED_ROLE" "$count" \
  > "$FIXTURE_ROOT/xcodegen.result"
SH
cat > "$FIXTURE/bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/tools/lib/apple-build-lease.sh"
verify_apple_build_lease shared
count="$(find "$HOME/.config/smart-disk-maintenance/apple-build-interlock-v1/leases" \
  -mindepth 1 -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
printf '%s %s\n' "$APPLE_BUILD_LEASE_VALIDATED_ROLE" "$count" \
  > "$FIXTURE_ROOT/xcodebuild.result"
SH
chmod +x "$FIXTURE/bin/xcodegen" "$FIXTURE/bin/xcodebuild"

HOME_CHAIN="$(new_home entrypoint-chain)"
test_env "$HOME_CHAIN" \
  FIXTURE_ROOT="$FIXTURE" \
  PATH="$FIXTURE/bin:/usr/bin:/bin" \
  "$FIXTURE/tools/build-ios.sh" >/dev/null
assert_contains "$FIXTURE/xcodegen.result" "inherited 1"
assert_contains "$FIXTURE/xcodebuild.result" "inherited 1"
wait_for_no_records "$HOME_CHAIN"

rm -f "$FIXTURE/xcodegen.result" "$FIXTURE/xcodebuild.result"
test_env "$HOME_CHAIN" \
  FIXTURE_ROOT="$FIXTURE" \
  PATH="$FIXTURE/bin:/usr/bin:/bin" \
  /usr/bin/ruby -I"$RUBY_LIB" -rapple_build_lease -e '
    AppleBuildLease.with_shared("test/fastlane-entrypoint-chain") do
      ok = system(ARGV.fetch(0))
      raise "fixture entrypoint failed" unless ok
    end
  ' "$FIXTURE/tools/build-ios.sh" >/dev/null
assert_contains "$FIXTURE/xcodegen.result" "inherited 1"
assert_contains "$FIXTURE/xcodebuild.result" "inherited 1"
wait_for_no_records "$HOME_CHAIN"

# A partial inherited environment cannot use the entrypoint adapter as a bypass.
HOME_FORGED="$(new_home forged-entrypoint)"
set +e
test_env "$HOME_FORGED" \
  FIXTURE_ROOT="$FIXTURE" \
  PATH="$FIXTURE/bin:/usr/bin:/bin" \
  APPLE_BUILD_LEASE_PROTOCOL=1 \
  "$FIXTURE/tools/build-ios.sh" >"$TMP/forged-entrypoint.log" 2>&1
FORGED_STATUS=$?
set -e
[[ "$FORGED_STATUS" -ne 0 ]] ||
  fail "partial inherited environment started a replacement lease"
assert_contains "$TMP/forged-entrypoint.log" \
  "incomplete inherited lease environment"
[[ "$(record_count "$HOME_FORGED")" == "0" ]] ||
  fail "partial inherited environment published a lease record"

# Cancellation and ordinary failure retain durable evidence rather than
# creating a success-shaped release.
HOME_CANCEL="$(new_home cancellation)"
CANCEL_READY="$TMP/cancel.ready"
test_env "$HOME_CANCEL" /bin/bash -c '
  source "$1"
  acquire_apple_build_shared_lease test/cancelled
  install_apple_build_lease_traps
  touch "$2"
  while :; do sleep 0.05; done
' _ "$SHELL_LIB" "$CANCEL_READY" >/dev/null 2>&1 &
CANCEL_PID=$!
FIXTURE_PIDS+=("$CANCEL_PID")
wait_for_file "$CANCEL_READY"
kill -TERM "$CANCEL_PID"
wait "$CANCEL_PID" 2>/dev/null || true
[[ "$(record_count "$HOME_CANCEL")" == "1" ]] ||
  fail "cancelled lane did not retain durable evidence"

HOME_FAILURE="$(new_home failure)"
set +e
test_env "$HOME_FAILURE" "$WRAPPER" test/failed-lane -- /usr/bin/false \
  >/dev/null 2>&1
FAILURE_STATUS=$?
set -e
[[ "$FAILURE_STATUS" -ne 0 ]] || fail "failed lane reported success"
[[ "$(record_count "$HOME_FAILURE")" == "1" ]] ||
  fail "failed lane did not retain durable evidence"

echo "Mozz Apple build interlock tests passed"
