# Apple build/cleanup interlock

Mozz participates in the same machine-wide shared/exclusive lease protocol as
Plozz. Cooperative Apple build, test, generation, archive, upload, simulator,
device-install, and macOS packaging entrypoints hold a shared lease. Future
authorized maintenance must obtain the conflicting exclusive lease.

This is an interlock only. It does not authorize cleanup, enable a schedule,
remove `~/.config/smart-disk-maintenance/SUSPENDED`, create rollout policy, or
make any cache eligible for deletion.

## Protocol provenance

The protocol clients below are byte-for-byte copies from Plozz commit
`b1d24c0def3e980a9487d9042420a149298db867` (interlock implementation commit
`5407b2508d3721be9db9bf8dab1ab90efd30e12d`):

| File | SHA-256 |
|---|---|
| `tools/lib/apple-build-lease.sh` | `bcb0a687d32ffa740953a687c812515d2516bd0ba90ea824c01c21fc6303c705` |
| `tools/lib/apple_build_lease.py` | `56a54b71f9a642ddd5e10a51128bc59610cbe6e3f9600cc7f6799c3b196bdca2` |
| `tools/lib/apple_build_lease.rb` | `c7726eaf3470da9dacbacbdf65d86ce353770f47da15882624be4455b7008372` |
| `tools/with-apple-build-lease.sh` | `dc3d932b08b8056704bd37920694952effca451abb155cce1cf8e356752f1b99` |

Do not make app-specific protocol changes in Mozz. Protocol changes require
coordination with the protocol owner and synchronized fixture coverage.

`tools/lib/apple-build-entrypoint.sh` is the Mozz-specific adapter. A direct
entrypoint re-executes under `tools/with-apple-build-lease.sh`; a nested
entrypoint validates and reuses the inherited lock and proof descriptors.
Incomplete, forged, closed, or mismatched inherited state fails closed.

## Covered current writers

- Xcode project generation: `tools/generate-project.sh`.
- iOS simulator/device builds and installs: `tools/build-ios.sh`,
  `tools/run-ios.sh`, `tools/run-carplay-sim.sh`, `tools/deploy-device.sh`,
  `tools/bootstrap-sim.sh`, and `tools/install-verified.sh`.
- Tests and screenshots: `tools/run-tests.sh` and `tools/screenshots.sh`.
- Apple audio artifacts: `tools/build-audio-xcframework.sh`, plus the Darwin
  paths through `tools/build-audio-cdylib.sh` and
  `tools/run-audio-abi-test.sh`.
- macOS packaging/signing/install: `tools/build-macos-app.sh`.
- Fastlane `generate_project`, `build`, `beta`, and `release`. The outer
  `beta`/`release` lease spans project generation, archive/export, upload,
  processing, and distribution. Mozz currently has no automated tagging step.
- Raw Swift/Clang compiler calls in the macOS Core/iOS, desktop, Windows-control,
  and Android-control CI jobs.

Nested shell entrypoints and Fastlane children retain the authenticated
descriptors. A subprocess that launches another Apple writer must validate the
lease and pass only the validated lease descriptors explicitly; never use
`close_fds=False` as a blanket inheritance workaround.

## Deliberately outside this coverage

These current tools do not write Apple build resources and therefore do not
claim a lease: schema/header/icon source generators, screenshot-fixture media
preparation, device-log retrieval, Linux/Windows/Android cross-compilation, and
standalone Cargo analysis/evaluation tools.

Manual Xcode use, raw local `xcodebuild`/`swift build`/`swift test` commands, old
worktrees, and other applications remain rollout blockers. Use the committed
entrypoints, or explicitly wrap a necessary raw command:

```bash
tools/with-apple-build-lease.sh mozz/manual-purpose -- command ...
```

The global rollout policy must continue to require both
`mozz-current-writers` and `mozz-legacy-writers`; this branch alone does not
make global cleanup safe.

## Fixture validation

The regression test uses private temporary HOME and interlock roots. It performs
no app build, archive, extraction, install, deployment, or cleanup:

```bash
tools/tests/test-apple-build-interlock.sh
```
