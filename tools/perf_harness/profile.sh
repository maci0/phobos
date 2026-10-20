#!/usr/bin/env bash
# Profile an owned loopback server against the local Klippy stub.
set -euo pipefail
# shellcheck source=tools/perf_harness/common.sh
source "$(dirname -- "$0")/common.sh"

ENDPOINT=${1:-/printer/objects/query?heater_bed&toolhead&print_stats}
RATE=${2:-4000}
SECONDS_TO_SAMPLE=${3:-10}
PORT=${PHOBOS_PERF_PORT:-7141}
FLAMEGRAPH=${FLAMEGRAPH_DIR:-$HOME/FlameGraph}
[[ "$ENDPOINT" == /* && "$ENDPOINT" != *$'\n'* && "$ENDPOINT" != *$'\r'* ]] || { echo 'endpoint must be a single absolute URL path' >&2; exit 1; }
[[ "$SECONDS_TO_SAMPLE" =~ ^[1-9][0-9]*$ ]] || { echo 'seconds must be a positive integer' >&2; exit 1; }
[[ -x "$FLAMEGRAPH/flamegraph.pl" ]] || { echo "FlameGraph not found at $FLAMEGRAPH" >&2; exit 1; }
check_port "$PORT"
new_run profile
OUTPUT=${4:-$PERF_RUN/flamegraph.svg}
SOCK="$PERF_RUN/k.sock"

"${ZIG:-zig}" build -Doptimize=ReleaseFast -Dprofile --prefix "$PERF_RUN/build"
mkdir -p "$PERF_RUN/data" "$(dirname -- "$OUTPUT")"
printf '[server]\nhost: 127.0.0.1\nport: %s\nklippy_uds_address: %s\n[machine]\nprovider: none\n[authorization]\ntrusted_clients:\n 127.0.0.1\n[announcements]\ndev_mode: true\n[update_manager]\nenable_auto_refresh: false\nenable_system_updates: false\n' "$PORT" "$SOCK" > "$PERF_RUN/phobos.conf"
start_child uv run --offline python tools/perf_harness/klippy_stub.py "$SOCK" > "$PERF_RUN/stub.log" 2>&1
start_child "$PERF_RUN/build/bin/phobos" -c "$PERF_RUN/phobos.conf" -d "$PERF_ROOT/$PERF_RUN/data" > "$PERF_RUN/phobos.log" 2>&1
SERVER_PID=$PERF_CHILD_PID
wait_ready "$SERVER_PID" "$PORT" klippy

printf 'GET http://127.0.0.1:%s%s\n' "$PORT" "$ENDPOINT" > "$PERF_RUN/targets.txt"
start_child vegeta attack -targets="$PERF_RUN/targets.txt" -rate="$RATE" -duration="$((SECONDS_TO_SAMPLE + 4))s" -keepalive=true > "$PERF_RUN/vegeta.bin" 2> "$PERF_RUN/vegeta.log"

if [[ ${USE_BPFTRACE:-0} == 1 ]]; then
    if timeout --signal=INT "$SECONDS_TO_SAMPLE" bpftrace -e "profile:hz:99 /pid == $SERVER_PID/ { @[ustack] = count(); }" -o "$PERF_RUN/bpf.out"; then
        :
    else
        result=$?
        [[ $result == 124 ]] || exit "$result"
    fi
    "$FLAMEGRAPH/stackcollapse-bpftrace.pl" "$PERF_RUN/bpf.out" |
        "$FLAMEGRAPH/flamegraph.pl" --title "phobos $ENDPOINT" --colors java > "$OUTPUT"
else
    perf record -g --call-graph=fp -F 1999 -o "$PERF_RUN/phobos.perf" -p "$SERVER_PID" -- sleep "$SECONDS_TO_SAMPLE"
    perf script -i "$PERF_RUN/phobos.perf" |
        "$FLAMEGRAPH/stackcollapse-perf.pl" |
        "$FLAMEGRAPH/flamegraph.pl" --title "phobos $ENDPOINT" --width 1500 --colors java > "$OUTPUT"
fi
printf 'flamegraph: %s\n' "$OUTPUT"
