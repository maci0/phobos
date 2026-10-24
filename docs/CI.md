# Build and release automation

[CI](https://github.com/maci0/phobos/actions/workflows/ci.yml) runs on main
pushes, pull requests, `v*` tags and manual dispatch. It uses GitHub-hosted
Ubuntu 24.04 runners, with native x86-64 and AArch64 execution. It has no
printer credentials and does not deploy to a printer.

## Checks and build artifacts

- Zig 0.17.0 is downloaded from the official archive and checked against the
  pinned SHA-256 for the runner architecture. Python 3.12 tooling uses `uv.lock`.
- Formatting, build-policy tests, SQLite source hashes, Python tests and API
  registration/table checks must pass. Python lint/format/type checks cover the
  maintained performance and release helpers; scanner behavior is tested.
- Upstream and Forge-X API baselines have separate coverage gates. The generated
  upstream table identifies Forge-X extensions without changing the vendor pin.
- The complete standalone daemon suite runs in Debug, ReleaseSafe and ReleaseFast
  on x86-64, and ReleaseSafe and ReleaseFast on native AArch64. The physical-Klippy
  fixture may skip. OpenSSL, socat and FFmpeg are installed for TLS and native
  timelapse encoding/decoding fixtures.
  Logs are retained as artifacts. No test uses a live printer database.
- All eight [Linux profiles](BUILDS.md) build independently. The build helper
  checks ELF class/machine, static linkage, ARM and MIPS ABI/FPU attributes and checksums.
- The exact x86-64 and AArch64 release assets execute natively, check their
  C/Zig floating-point ABI probes and dump the API for the coverage gate.
  ARM32 and MIPS execution remain separate hardware checks; CI does not use QEMU.
- Per-profile artifacts are assembled into one `release-bundle`, checked again
  for all required profiles and checksums. Missing, corrupt, duplicated or
  wrong-version assets fail preparation. Relative release-note links become
  versioned repository links.

After checks pass, daemon tests and profile builds run independently. Packaging
waits for every test, build and native smoke job; a failed suite blocks both the
bundle and publication.

The workflow actions are pinned to full commits. Ordinary jobs have read-only
repository permissions; checkout does not persist credentials. Only the final
tag publication job receives `contents: write`. New main/PR runs cancel older
runs for the same ref; tag runs are not canceled by this policy.

## Publish a release

1. Update `.version` in `build.zig.zon` and add `docs/releases/v<VERSION>.md`.
2. Commit verified changes to main and wait for CI to pass.
3. Create an annotated `v<VERSION>` tag and push it normally. Never move a
   published tag or overwrite its assets.

Tag checks require the package version to match, an annotated tag pointing to
the checked commit, that commit to be reachable from main, and nonempty release
notes. Only a tag push can publish. Main, pull-request and manual runs produce
the verified bundle without publishing anything.

After all tests, builds, native smoke checks and packaging pass, CI creates a
draft GitHub release containing the eight binaries, `SHA256SUMS` and
`profiles.tsv`. It downloads those uploaded files, repeats ELF/checksum checks
and compares both manifests before publishing the draft. An upload/verification
failure leaves the release unpublished. An existing release causes creation to
fail; the workflow has no clobber path. Inspect a failed draft before removing
it and rerunning the job. Stable `major.minor.patch` versions are supported.

Repository rules or branch protections are managed separately. A green workflow
does not itself prevent a maintainer from pushing an unverified main commit.

## Local checks

```sh
uv sync --locked --python 3.12
scripts/test.sh Debug
scripts/test.sh ReleaseSafe
scripts/test.sh ReleaseFast
uv run --locked python -m pytest tools/api_scanner/tests \
  tools/client_api_scanner/tests tools/perf_harness/tests tools/release/tests \
  --basetemp=.scratch/ci-pytest
scripts/build-release.sh
scripts/build-release.sh --verify-only
```

`test-artifact` now installs `bin/phobos-tests` under the selected Zig prefix.
`scripts/test.sh` builds it under `.scratch/tests-<mode>/` and runs that exact
artifact with separate build/run timeouts. It does not discover a test binary
by cache timestamp or use the build runner's listen protocol.

The HTTP fixture disables spare async workers and uses `Io.concurrent` for its
accept loop and WebSocket emitter. Blocking peers must make concurrent progress
even on a two-core runner. The measurement smoke suite also checks that an EXIT
trap triggered by a failure stops both owned children, including on Bash 5.2.

When dependencies change, run `uv lock --python 3.12`, review the dependency
and hash changes, and rerun the Python checks. Keep the Zig archive URL/hash,
package minimum compiler and build-profile assumptions in step.
