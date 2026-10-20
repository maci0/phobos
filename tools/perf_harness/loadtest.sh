#!/usr/bin/env bash
# Load an explicitly selected backend. Captures stay under the project scratch directory.
set -euo pipefail
# shellcheck source=tools/perf_harness/common.sh
source "$(dirname -- "$0")/common.sh"

TARGET=${1:?usage: loadtest.sh host:port label [rate] [duration]}
LABEL=${2:?provide a label}
RATE=${3:-200}
DURATION=${4:-15s}
[[ "$TARGET" =~ ^[a-zA-Z0-9.:-]+$ ]] || { echo 'invalid host:port' >&2; exit 1; }
new_run load
sed "s#TARGET#$TARGET#g" tools/perf_harness/targets.txt |
    vegeta attack -rate="$RATE" -duration="$DURATION" -timeout=10s -keepalive=true |
    tee "$PERF_RUN/results.bin" |
    vegeta report -type=text
printf 'latency histogram (%s)\n' "$LABEL"
vegeta report '-type=hist[0,1ms,2ms,5ms,10ms,25ms,50ms,100ms]' "$PERF_RUN/results.bin"
