#!/usr/bin/env bash
# Exercise measurement setup and teardown with command doubles, without profiling.
set -euo pipefail

COMMAND=$(basename -- "$0")
case "$COMMAND" in
    zig)
        [[ ${PERF_FAKE_BUILD_FAIL:-0} == 0 ]] || exit 42
        while [[ $# -gt 0 ]]; do
            if [[ $1 == --prefix ]]; then
                mkdir -p "$2/bin"
                ln -s "$PERF_FAKE_SCRIPT" "$2/bin/phobos"
                exit
            fi
            shift
        done
        exit 1
        ;;
    phobos)
        if [[ ${PERF_FAKE_IGNORE_TERM:-0} == 1 ]]; then
            trap '' TERM
        fi
        printf '%s\n' "$$" >> "$PERF_FAKE_PIDS"
        exec /usr/bin/sleep 60
        ;;
    uv)
        if [[ "$*" == *klippy_stub.py* || "$*" == *'-m moonraker'* ]]; then
            printf '%s\n' "$$" >> "$PERF_FAKE_PIDS"
            exec /usr/bin/sleep 60
        fi
        exec "$PERF_REAL_UV" "$@"
        ;;
    curl)
        [[ ${PERF_FAKE_BUSY:-0} == 0 ]] || exit 0
        [[ "$*" == */server/info* ]] || exit 1
        while [[ $# -gt 0 ]]; do
            if [[ $1 == -o ]]; then
                printf '{"result":{"klippy_state":"ready"}}\n' > "$2"
                break
            fi
            shift
        done
        exit 0
        ;;
    sleep)
        exec /usr/bin/sleep 0.01
        ;;
    sudo)
        [[ $1 == -n ]] || exit 1
        shift
        exec "$@"
        ;;
    vegeta)
        [[ ${PERF_FAKE_LOAD_FAIL:-0} == 0 ]] || exit 43
        if [[ $1 == attack ]]; then
            [[ "$*" == *-targets=* ]] || cat >/dev/null
            printf '{"throughput":12,"requests":12,"success":%s,"latencies":{"50th":1000000,"99th":2000000}}\n' "${PERF_FAKE_SUCCESS:-0.5}"
        elif [[ "$*" == *-type=json* ]]; then
            if [[ $# -gt 2 ]]; then cat "${@: -1}"; else cat; fi
        else
            [[ $# -ne 2 ]] || cat >/dev/null
            printf 'mock report\n'
        fi
        exit
        ;;
    perf)
        if [[ $1 == record ]]; then
            while [[ $# -gt 0 ]]; do
                if [[ $1 == -o ]]; then
                    : > "$2"
                    break
                fi
                shift
            done
        else
            printf 'mock profile\n'
        fi
        exit
        ;;
    bpftrace)
        while [[ $# -gt 0 ]]; do
            if [[ $1 == -o ]]; then
                printf 'mock profile\n' > "$2"
                break
            fi
            shift
        done
        exit
        ;;
    stackcollapse-bpftrace.pl)
        cat "$1"
        exit
        ;;
    stackcollapse-perf.pl|flamegraph.pl)
        cat
        exit
        ;;
esac

ROOT=$(cd -- "$(dirname -- "$0")" && pwd)
while [[ ! -f "$ROOT/build.zig.zon" ]]; do
    [[ "$ROOT" != / ]] || exit 1
    ROOT=$(dirname -- "$ROOT")
done
cd -- "$ROOT"
mkdir -p .scratch
TEST_DIR=$(mktemp -d .scratch/measurement-smoke-XXXXXX)
PERF_FAKE_SCRIPT="$ROOT/tools/perf_harness/tests/smoke.sh"
PERF_REAL_UV=$(command -v uv)
PERF_FAKE_PIDS="$ROOT/$TEST_DIR/pids"
export PERF_FAKE_SCRIPT PERF_REAL_UV PERF_FAKE_PIDS
mkdir "$TEST_DIR/bin"
for name in zig phobos uv curl sleep sudo vegeta perf bpftrace stackcollapse-bpftrace.pl stackcollapse-perf.pl flamegraph.pl; do
    ln -s "$PERF_FAKE_SCRIPT" "$TEST_DIR/bin/$name"
done
export PATH="$ROOT/$TEST_DIR/bin:$PATH"
export MOONRAKER_PYTHON="$ROOT/$TEST_DIR/bin/uv"
export FLAMEGRAPH_DIR="$ROOT/$TEST_DIR/bin"

check_cleanup() {
    local pid
    while read -r pid; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "leaked child: $pid" >&2
            return 1
        fi
    done < "$PERF_FAKE_PIDS"
}

bash tools/perf_harness/bench_local.sh > "$TEST_DIR/bench.log"
BENCH_DIR=$(awk '$1 == "captures:" {print $2}' "$TEST_DIR/bench.log")
[[ $BENCH_DIR == .scratch/bench-* && -s "$BENCH_DIR/report.txt" ]]
rg -q '^klippy_uds_address: .scratch/bench-.*/k.sock$' "$BENCH_DIR/phobos.conf"
[[ -f "$BENCH_DIR/moonraker/misc/usb.ids" ]]
rg -q 'thru=12 succ=50.0% p50=1.00ms p99=2.00ms' "$BENCH_DIR/report.txt"
check_cleanup

PERF_FAKE_SUCCESS=1 bash tools/perf_harness/profile.sh /server/info 1 1 > "$TEST_DIR/profile.log"
PROFILE_DIR=$(awk '$1 == "captures:" {print $2}' "$TEST_DIR/profile.log")
[[ -s "$PROFILE_DIR/flamegraph.svg" && -f "$PROFILE_DIR/phobos.perf" ]]
[[ -s "$PROFILE_DIR/report.txt" && -s "$PROFILE_DIR/folded.txt" && -s "$PROFILE_DIR/stacks.txt" ]]
jq -e '.success == 1 and .requests == 12' "$PROFILE_DIR/vegeta.json" >/dev/null
check_cleanup
PERF_SUDO=1 PERF_FAKE_SUCCESS=1 bash tools/perf_harness/profile.sh /server/info 1 1 > "$TEST_DIR/perf-sudo.log"
check_cleanup
USE_BPFTRACE=1 PERF_FAKE_SUCCESS=1 bash tools/perf_harness/profile.sh /server/info 1 1 > "$TEST_DIR/bpf.log"
check_cleanup
if PERF_FAKE_SUCCESS=0.5 bash tools/perf_harness/profile.sh /server/info 1 1 > "$TEST_DIR/profile-errors.log" 2>&1; then
    echo 'profile accepted failed requests' >&2
    exit 1
fi
check_cleanup
if PERF_FAKE_LOAD_FAIL=1 bash tools/perf_harness/profile.sh /server/info 1 1 > "$TEST_DIR/profile-load-fail.log" 2>&1; then
    echo 'profile ignored a failed load process' >&2
    exit 1
fi
check_cleanup

bash scripts/measure-memory.sh > "$TEST_DIR/memory.log"
rg -q 'Python .+ stdlib baseline VmRSS:' "$TEST_DIR/memory.log"
MEMORY_DIR=$(awk '$1 == "captures:" {print $2}' "$TEST_DIR/memory.log")
rg -q '^klippy_uds_address: .scratch/memory-.*/no-klippy.sock$' "$MEMORY_DIR/phobos.conf"
rg -q '^dev_mode: true$' "$MEMORY_DIR/phobos.conf"
check_cleanup
bash tools/perf_harness/loadtest.sh 127.0.0.1:7190 ../../label 1 1s > "$TEST_DIR/load.log"
LOAD_DIR=$(awk '$1 == "captures:" {print $2}' "$TEST_DIR/load.log")
[[ $LOAD_DIR == .scratch/load-* && -s "$LOAD_DIR/results.bin" ]]

if PERF_FAKE_BUILD_FAIL=1 bash scripts/measure-memory.sh > "$TEST_DIR/build-fail.log" 2>&1; then
    echo 'build failure was ignored' >&2
    exit 1
fi
if PERF_FAKE_LOAD_FAIL=1 bash tools/perf_harness/bench_local.sh > "$TEST_DIR/load-fail.log" 2>&1; then
    echo 'load failure was ignored' >&2
    exit 1
fi
check_cleanup
if bash tools/perf_harness/tests/cleanup_failure.sh > "$TEST_DIR/exit-cleanup.log" 2>&1; then
    echo 'cleanup fixture did not fail' >&2
    exit 1
fi
check_cleanup
if PERF_FAKE_BUSY=1 bash scripts/measure-memory.sh > "$TEST_DIR/busy.log" 2>&1; then
    echo 'existing HTTP listener was accepted' >&2
    exit 1
fi
if bash scripts/measure-memory.sh 7125 > "$TEST_DIR/production-port.log" 2>&1; then
    echo 'production port was accepted' >&2
    exit 1
fi
if bash scripts/measure-memory.sh 18446744073709558741 > "$TEST_DIR/overflow-port.log" 2>&1; then
    echo 'overflowing port was accepted' >&2
    exit 1
fi
if bash tools/perf_harness/loadtest.sh '127.0.0.1#bad' test > "$TEST_DIR/target.log" 2>&1; then
    echo 'invalid target was accepted' >&2
    exit 1
fi
# shellcheck source=tools/perf_harness/common.sh
source tools/perf_harness/common.sh
if stop_child 0 || stop_child "$$"; then
    echo 'an unowned PID was accepted' >&2
    exit 1
fi
start_child env PERF_FAKE_IGNORE_TERM=1 "$ROOT/$TEST_DIR/bin/phobos"
STUB_PID=$PERF_CHILD_PID
DEADLINE=$((SECONDS + 5))
while ! rg -q "^$STUB_PID$" "$PERF_FAKE_PIDS" && (( SECONDS < DEADLINE )); do
    /usr/bin/sleep 0.01
done
rg -q "^$STUB_PID$" "$PERF_FAKE_PIDS"
stop_child "$STUB_PID"
if kill -0 "$STUB_PID" 2>/dev/null; then
    echo 'TERM-resistant child survived cleanup' >&2
    exit 1
fi
printf 'measurement helper smoke tests passed\n'
