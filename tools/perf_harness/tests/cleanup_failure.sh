#!/usr/bin/env bash
# A failed measurement must still stop every owned child in its EXIT trap.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")" && pwd)
while [[ ! -f "$ROOT/build.zig.zon" ]]; do
    [[ $ROOT != / ]] || exit 1
    ROOT=$(dirname -- "$ROOT")
done
# shellcheck source=tools/perf_harness/common.sh
source "$ROOT/tools/perf_harness/common.sh"
: "${PERF_FAKE_PIDS:?}"
new_run cleanup-failure
for _ in 1 2; do
    start_child /usr/bin/sleep 60
    printf '%s\n' "$PERF_CHILD_PID" >> "$PERF_FAKE_PIDS"
done
false
