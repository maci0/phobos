#!/usr/bin/env bash
# Shared setup for local measurement runs. Captures stay in the owned run directory.

PERF_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
while [[ ! -f "$PERF_ROOT/build.zig.zon" ]]; do
    [[ "$PERF_ROOT" != / ]] || { echo 'build.zig.zon not found' >&2; exit 1; }
    PERF_ROOT=$(dirname -- "$PERF_ROOT")
done
cd -- "$PERF_ROOT" || exit

PERF_CHILDREN=()
PERF_STOP_TIMEOUT_SECONDS=5
PERF_READY_TIMEOUT_SECONDS=30

start_child() {
    "$@" &
    PERF_CHILD_PID=$!
    PERF_CHILDREN+=("$PERF_CHILD_PID")
}

stop_child() {
    local pid=$1 index deadline
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    for index in "${!PERF_CHILDREN[@]}"; do
        if [[ "${PERF_CHILDREN[$index]}" == "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
            deadline=$((SECONDS + PERF_STOP_TIMEOUT_SECONDS))
            while kill -0 "$pid" 2>/dev/null; do
                if (( SECONDS >= deadline )); then
                    kill -KILL "$pid" 2>/dev/null || true
                    break
                fi
                sleep 0.1
            done
            wait "$pid" 2>/dev/null || true
            unset 'PERF_CHILDREN[index]'
            return
        fi
    done
    return 1
}

cleanup_children() {
    local pid
    for pid in "${PERF_CHILDREN[@]}"; do
        stop_child "$pid"
    done
}

new_run() {
    mkdir -p .scratch
    PERF_RUN=$(mktemp -d ".scratch/$1-XXXXXX")
    trap cleanup_children EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    printf 'captures: %s\n' "$PERF_RUN"
}

check_port() {
    [[ "$1" =~ ^[1-9][0-9]{0,4}$ && "$1" -le 65535 && "$1" -ne 7125 ]] || {
        echo 'use a non-production TCP port between 1 and 65535' >&2
        return 1
    }
    if curl -s --connect-timeout 1 --max-time 1 "http://127.0.0.1:$1/" -o /dev/null; then
        echo "port $1 already serves HTTP" >&2
        return 1
    fi
}

wait_ready() {
    local pid=$1 port=$2 deadline=$((SECONDS + PERF_READY_TIMEOUT_SECONDS))
    while (( SECONDS < deadline )); do
        kill -0 "$pid" 2>/dev/null || { echo 'server exited before readiness' >&2; return 1; }
        if curl -fsS --connect-timeout 1 --max-time 1 "http://127.0.0.1:$port/server/info" -o "$PERF_RUN/server-info.json" 2>/dev/null; then
            if [[ ${3:-http} == http ]] || jq -e '.result.klippy_state == "ready"' "$PERF_RUN/server-info.json" >/dev/null; then
                kill -0 "$pid" 2>/dev/null
                return
            fi
        fi
        sleep 0.1
    done
    echo 'server readiness timed out' >&2
    return 1
}
