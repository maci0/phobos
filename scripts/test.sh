#!/usr/bin/env bash
# Run the installed standalone artifact, avoiding the build-runner listen mode.
set -euo pipefail
BUILD_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
while [[ ! -f "$BUILD_ROOT/build.zig.zon" ]]; do
    [[ $BUILD_ROOT != / ]] || { echo 'build.zig.zon not found' >&2; exit 1; }
    BUILD_ROOT=$(dirname -- "$BUILD_ROOT")
done
cd -- "$BUILD_ROOT"
mode=${1:-Debug}
case "$mode" in Debug|ReleaseSafe|ReleaseFast) ;; *) echo 'expected Debug, ReleaseSafe or ReleaseFast' >&2; exit 1 ;; esac
prefix=".scratch/tests-$mode"
timeout 600 "${ZIG:-zig}" build test-artifact -Doptimize="$mode" -j2 --prefix "$prefix"
timeout 600 "$prefix/bin/phobos-tests" --cache-dir=./.zig-cache
