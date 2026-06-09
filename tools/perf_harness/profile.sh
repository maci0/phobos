#!/usr/bin/env sh
# On-CPU flamegraph of phobos under load. Builds an unstripped, frame-pointer
# release binary (`-Dprofile`), drives a vegeta load through the Klippy stub, and
# renders an SVG flamegraph via perf + Brendan Gregg's FlameGraph.
#
# perf (perf_events) profiles your own process at kernel.perf_event_paranoid<=2,
# no root needed. For a true eBPF capture set USE_BPFTRACE=1 (needs root /
# CAP_BPF + CAP_DAC_READ_SEARCH); the perf path produces an equivalent on-CPU
# flamegraph everywhere.
#
# Usage: tools/perf_harness/profile.sh [endpoint] [rate] [seconds] [out.svg]
#   endpoint default: /printer/objects/query?heater_bed&toolhead&print_stats
set +e
EP="${1:-/printer/objects/query?heater_bed&toolhead&print_stats}"
RATE="${2:-4000}"; SECS="${3:-10}"; OUT="${4:-docs/perf/flamegraph.svg}"
PORT=7141; SOCK=/tmp/klippy_stub.sock
FG="${FLAMEGRAPH_DIR:-$HOME/FlameGraph}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT"

[ -x "$FG/flamegraph.pl" ] || { echo "FlameGraph not at $FG (git clone https://github.com/brendangregg/FlameGraph)"; exit 1; }

echo ">> building -Dprofile (unstripped + frame pointers)"
zig build -Doptimize=ReleaseFast -Dprofile >/dev/null 2>&1

CFG="$(mktemp)"; DB="$(mktemp -u)"
printf '[server]\nhost: 127.0.0.1\nport: %s\n[database]\nbackend: sqlite\npath: %s\n[authorization]\ntrusted_clients:\n 127.0.0.1\n' "$PORT" "$DB" > "$CFG"
rm -f "$SOCK"; ln -sf "$SOCK" /tmp/klippy_uds
python3 tools/perf_harness/klippy_stub.py /tmp/klippy_uds >/tmp/stub.log 2>&1 & STUB=$!
sleep 1.5
./zig-out/bin/phobos -c "$CFG" >/tmp/phobos-profile.log 2>&1 & PH=$!
sleep 4

( echo "GET http://127.0.0.1:$PORT$EP" | vegeta attack -rate="$RATE" -duration="$((SECS+4))s" -keepalive=true >/dev/null 2>&1 ) &
sleep 1

mkdir -p "$(dirname "$OUT")"
if [ "${USE_BPFTRACE:-0}" = "1" ]; then
  echo ">> eBPF capture (bpftrace, 99 Hz)"
  bpftrace -e "profile:hz:99 /pid == $PH/ { @[ustack] = count(); }" -o /tmp/bpf.out 2>/dev/null
  "$FG"/stackcollapse-bpftrace.pl /tmp/bpf.out | "$FG"/flamegraph.pl --title "phobos $EP" --colors java > "$OUT"
else
  echo ">> perf capture (frame-pointer call graph, 1999 Hz)"
  perf record -g --call-graph=fp -F 1999 -o /tmp/phobos.perf -p "$PH" -- sleep "$SECS" 2>/dev/null
  perf script -i /tmp/phobos.perf 2>/dev/null | "$FG"/stackcollapse-perf.pl 2>/dev/null \
    | "$FG"/flamegraph.pl --title "phobos $EP" --width 1500 --colors java > "$OUT"
fi

kill -9 "$PH" "$STUB" 2>/dev/null; rm -f "$CFG"
echo ">> wrote $OUT"
