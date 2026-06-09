#!/usr/bin/env sh
# On-CPU hotpath profile of phobos under load (Linux perf or eBPF).
#
# ReleaseSmall/ReleaseFast omit frame pointers and strip symbols, so stacks are
# unreadable. This builds a profiling variant WITH frame pointers + symbols, runs
# it under a vegeta load against the no-auth /access/info endpoint, captures a
# perf profile, and folds it for a flamegraph.
#
# perf needs kernel.perf_event_paranoid <= 1 for call-graphs (sudo sysctl to set),
# or run the whole script under sudo. On hosts without perf, set USE_BPFTRACE=1 to
# fall back to an eBPF on-CPU sampler (bpftrace, needs root).
#
# Usage: tools/perf_harness/profile.sh [port] [rate] [seconds]
set -e
PORT="${1:-7140}"; RATE="${2:-4000}"; SECS="${3:-12}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

echo ">> building profiling binary (ReleaseFast + frame pointers + unstripped)"
zig build -Doptimize=ReleaseFast -Dstrip=false 2>/dev/null || \
  zig build -Doptimize=ReleaseFast 2>/dev/null
BIN=./zig-out/bin/phobos

CFG="$(mktemp)"
printf '[server]\nhost: 127.0.0.1\nport: %s\n[database]\nbackend: file\npath: %s\n[authorization]\ntrusted_clients:\n 127.0.0.1\n' \
  "$PORT" "$(mktemp -d)" > "$CFG"

"$BIN" -c "$CFG" >/tmp/phobos-profile.log 2>&1 &
PID=$!
sleep 3
echo ">> phobos pid=$PID on :$PORT"

# drive load in the background
( yes "GET http://127.0.0.1:$PORT/access/info" | head -1000000 \
    | vegeta attack -rate="$RATE" -duration="${SECS}s" -keepalive=true >/dev/null 2>&1 ) &
LOAD=$!

if [ "${USE_BPFTRACE:-0}" = "1" ]; then
  echo ">> eBPF on-CPU sampler (bpftrace, 99 Hz)"
  bpftrace -e "profile:hz:99 /pid == $PID/ { @[ustack] = count(); } interval:s:$SECS { exit(); }" \
    > /tmp/phobos-bpf-stacks.txt 2>/dev/null || echo "bpftrace failed (needs root)"
  echo ">> top stacks -> /tmp/phobos-bpf-stacks.txt"
  tail -40 /tmp/phobos-bpf-stacks.txt
else
  echo ">> perf record (call-graph, dwarf)"
  perf record -g --call-graph=dwarf -F 999 -o /tmp/phobos.perf -p "$PID" -- sleep "$SECS" 2>/dev/null \
    || perf record -g -o /tmp/phobos.perf -p "$PID" -- sleep "$SECS"
  echo ">> top self-time functions:"
  perf report -i /tmp/phobos.perf --stdio --no-children 2>/dev/null | grep -vE '^#|^$' | head -25
  # folded stacks for a flamegraph (github.com/brendangregg/FlameGraph)
  perf script -i /tmp/phobos.perf 2>/dev/null \
    | stackcollapse-perf.pl > /tmp/phobos.folded 2>/dev/null \
    && echo ">> folded stacks -> /tmp/phobos.folded (pipe to flamegraph.pl)" || true
fi

kill "$LOAD" "$PID" 2>/dev/null || true
rm -f "$CFG"
