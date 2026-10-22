#!/usr/bin/env bash
# Compare local servers with the same Klippy stub and fresh independent databases.
set -euo pipefail
# shellcheck source=tools/perf_harness/common.sh
source "$(dirname -- "$0")/common.sh"

PORT=${PHOBOS_PERF_PORT:-7140}
MOONRAKER_UNIX_PATH_BYTES=107
MOONRAKER_PYTHON=${MOONRAKER_PYTHON:-vendor/moonraker/.venv/bin/python}
[[ -x "$MOONRAKER_PYTHON" ]] || { echo 'set MOONRAKER_PYTHON to an existing Moonraker environment' >&2; exit 1; }
check_port "$PORT"
new_run bench
REPORT="$PERF_RUN/report.txt"
SOCK="$PERF_RUN/k.sock"
if ! (export LC_ALL=C; (( ${#PERF_ROOT} + ${#SOCK} + 1 <= MOONRAKER_UNIX_PATH_BYTES ))); then
    echo 'checkout path is too long for Moonraker Unix sockets' >&2
    exit 1
fi

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }

bench() {
    printf 'GET %s\n' "$1" |
        vegeta attack -rate="$2" -duration=8s -max-body=0 -timeout=5s -keepalive=true |
        vegeta report -type=json |
        uv run --offline python tools/perf_harness/report.py
}

run_server() {
    local name=$1 rate result
    wait_ready "$SERVER_PID" "$PORT" klippy
    log "######## $name (:$PORT) ########"
    log "idle $(awk '/^(VmRSS|Threads):/ {printf "%s %s %s ", $1, $2, $3}' "/proc/$SERVER_PID/status")"
    for rate in 500 2000 5000; do
        result=$(bench "http://127.0.0.1:$PORT/server/info" "$rate")
        log "server.info @ $rate: $result"
    done
    for rate in 500 2000; do
        result=$(bench "http://127.0.0.1:$PORT/printer/objects/query?heater_bed&toolhead&print_stats" "$rate")
        log "objects.query @ $rate: $result"
    done
    result=$(bench "http://127.0.0.1:$PORT/server/config" 2000)
    log "server.config @ 2000: $result"
    result=$(bench "http://127.0.0.1:$PORT/machine/system_info" 2000)
    log "machine.system_info @ 2000: $result"
    log "loaded $(awk '/^(VmRSS|Threads):/ {printf "%s %s %s ", $1, $2, $3}' "/proc/$SERVER_PID/status")"
}

mkdir -p "$PERF_RUN/phobos" "$PERF_RUN/moonraker/config" "$PERF_RUN/moonraker/logs" "$PERF_RUN/moonraker/misc"
: > "$PERF_RUN/moonraker/misc/usb.ids"
printf '[server]\nhost: 127.0.0.1\nport: %s\nklippy_uds_address: %s\n[machine]\nprovider: none\n[authorization]\ntrusted_clients:\n 127.0.0.1\n[announcements]\ndev_mode: true\n' "$PORT" "$SOCK" > "$PERF_RUN/moonraker/config/moonraker.conf"
cp "$PERF_RUN/moonraker/config/moonraker.conf" "$PERF_RUN/phobos.conf"
printf '[update_manager]\nenable_auto_refresh: false\nenable_system_updates: false\n' >> "$PERF_RUN/phobos.conf"

"${ZIG:-zig}" build -Doptimize=ReleaseFast --prefix "$PERF_RUN/build"
start_child uv run --offline python tools/perf_harness/klippy_stub.py "$SOCK" > "$PERF_RUN/stub.log" 2>&1
start_child "$PERF_RUN/build/bin/phobos" -c "$PERF_RUN/phobos.conf" -d "$PERF_ROOT/$PERF_RUN/phobos" > "$PERF_RUN/phobos.log" 2>&1
SERVER_PID=$PERF_CHILD_PID
run_server 'phobos (ReleaseFast)'
stop_child "$SERVER_PID"

start_child env PYTHONPATH=vendor/moonraker uv run --offline --python "$MOONRAKER_PYTHON" python -m moonraker -d "$PERF_ROOT/$PERF_RUN/moonraker" -u "$PERF_RUN/m.sock" > "$PERF_RUN/moonraker.log" 2>&1
SERVER_PID=$PERF_CHILD_PID
run_server 'Moonraker'
stop_child "$SERVER_PID"
log "report: $REPORT"
