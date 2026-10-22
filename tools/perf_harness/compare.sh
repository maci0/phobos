#!/usr/bin/env sh
# Side-by-side load comparison of two Moonraker-compatible backends (e.g. stock
# Moonraker vs phobos) on the SAME hardware, so the numbers are apples-to-apples.
#
# Run each backend on the same host (swap them onto one port, or run on two
# ports), then:
#   tools/perf_harness/compare.sh <hostA:portA> <labelA> <hostB:portB> <labelB> [rate] [dur]
#
# Reports requests/s, success ratio, and latency percentiles for each, plus
# samples RSS if the backend pid is discoverable locally.
set -e
A="$1"; LA="$2"; B="$3"; LB="$4"; RATE="${5:-200}"; DUR="${6:-15s}"
DIR="$(dirname "$0")"

run() {
  target="$1"; label="$2"
  echo "================ $label  ($target, $RATE req/s, $DUR) ================"
  sed "s#TARGET#${target}#g" "$DIR/targets.txt" \
    | vegeta attack -rate="$RATE" -duration="$DUR" -max-body=0 -timeout=10s -keepalive=true 2>/dev/null \
    | vegeta report -type=text 2>/dev/null \
    | grep -iE 'Requests|Latencies|Success|Throughput'
  echo
}

run "$A" "$LA"
run "$B" "$LB"
