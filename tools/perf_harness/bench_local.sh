#!/usr/bin/env bash
# Raw-perf head-to-head: phobos vs stock Moonraker on the SAME host, both pointed
# at the klippy stub (tools/perf_harness/klippy_stub.py) so klippy latency is out
# of the loop and only each server's own request handling is measured.
#
# Must run as a SINGLE invocation (sandboxed background procs don't survive across
# calls). Writes /tmp/perf-report.txt. Run from the repo root.
set +e
cd "$(dirname "$0")/../.."
R=/tmp/perf-report.txt; : > "$R"
SOCK=/tmp/klippy_uds
MV=vendor/moonraker/.venv/bin/python
log(){ echo "$@" | tee -a "$R"; }

pidkill(){ [ -n "$1" ] && kill -9 "$1" 2>/dev/null; }

# vegeta one endpoint -> "thru=.. p50=.. p99=.. succ=.."
bench(){ # url rate
  echo "GET $1" | vegeta attack -rate="$2" -duration=8s -timeout=5s -keepalive=true 2>/dev/null \
   | vegeta report -type=json 2>/dev/null \
   | python3 -c "import json,sys
d=json.load(sys.stdin); l=d['latencies']
print('thru=%.0f succ=%.1f%% p50=%.2fms p99=%.2fms'%(d['throughput'], d['success']*100, l['50']/1e6, l['99']/1e6))"
}

run_server(){ # name port
  local name="$1" port="$2"
  log ""; log "######## $name (:$port) ########"
  local rss; rss=$(grep VmRSS /proc/$SRV/status 2>/dev/null|awk '{print $2}')
  log "idle RSS: ${rss} kB | threads: $(ls /proc/$SRV/task 2>/dev/null|wc -l)"
  # warm
  curl -s --max-time 5 "http://127.0.0.1:$port/server/database/item?namespace=mainsail" >/dev/null 2>&1
  for r in 500 2000 5000; do
    log "  /server/info        @ ${r}: $(bench http://127.0.0.1:$port/server/info $r)"
  done
  for r in 500 2000; do
    log "  objects/query(stub) @ ${r}: $(bench "http://127.0.0.1:$port/printer/objects/query?heater_bed&toolhead&print_stats" $r)"
  done
  log "  /server/config      @ 2000: $(bench http://127.0.0.1:$port/server/config 2000)"
  log "  machine/system_info @ 2000: $(bench http://127.0.0.1:$port/machine/system_info 2000)"
  local rss2; rss2=$(grep VmRSS /proc/$SRV/status 2>/dev/null|awk '{print $2}')
  log "loaded RSS: ${rss2} kB | threads: $(ls /proc/$SRV/task 2>/dev/null|wc -l)"
}

# ---- klippy stub ----
rm -f "$SOCK"
python3 tools/perf_harness/klippy_stub.py "$SOCK" >/tmp/stub.log 2>&1 & STUB=$!
sleep 1.5

# ---- phobos ----
rm -f /tmp/perf-phobos.db*
printf '[server]\nhost: 127.0.0.1\nport: 7140\n[database]\nbackend: sqlite\npath: /tmp/perf-phobos.db\n[authorization]\ntrusted_clients:\n 127.0.0.1\n' > /tmp/perf-phobos.cfg
./zig-out/bin/phobos -c /tmp/perf-phobos.cfg >/tmp/perf-phobos.log 2>&1 & SRV=$!
sleep 4
run_server "phobos (ReleaseFast)" 7140
pidkill $SRV; sleep 1

# ---- moonraker ----
$MV -m moonraker -d /tmp/mr-data >/tmp/mr.log 2>&1 & SRV=$!
sleep 8
run_server "Moonraker (Python/asyncio)" 7125
pidkill $SRV

pidkill $STUB
log ""; log "=== DONE ==="
