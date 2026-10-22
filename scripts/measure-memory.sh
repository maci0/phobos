#!/usr/bin/env bash
# Measure an isolated idle ReleaseFast server and a bare Python interpreter.
set -euo pipefail
# shellcheck source=tools/perf_harness/common.sh
source "$(dirname -- "$0")/../tools/perf_harness/common.sh"

PORT=${1:-7188}
check_port "$PORT"
new_run memory
mkdir -p "$PERF_RUN/data"
printf '[server]\nhost: 127.0.0.1\nport: %s\nklippy_uds_address: %s/no-klippy.sock\n[machine]\nprovider: none\n[authorization]\ntrusted_clients:\n 127.0.0.1\n[announcements]\ndev_mode: true\n[update_manager]\nenable_auto_refresh: false\nenable_system_updates: false\n' "$PORT" "$PERF_RUN" > "$PERF_RUN/phobos.conf"
"${ZIG:-zig}" build -Doptimize=ReleaseFast --prefix "$PERF_RUN/build"
BINARY="$PERF_RUN/build/bin/phobos"
start_child "$BINARY" -c "$PERF_RUN/phobos.conf" -d "$PERF_ROOT/$PERF_RUN/data" > "$PERF_RUN/phobos.log" 2>&1
SERVER_PID=$PERF_CHILD_PID
wait_ready "$SERVER_PID" "$PORT"
sleep 6
kill -0 "$SERVER_PID"

printf 'commit: %s\n' "$(git rev-parse HEAD)"
printf 'binary bytes: %s\n' "$(stat -c%s "$BINARY")"
awk '/^(VmRSS|VmHWM|VmData|Threads):/' "/proc/$SERVER_PID/status"
uv run --offline python scripts/python-memory.py
