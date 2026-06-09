#!/usr/bin/env sh
# Comparative HTTP load test (vegeta). Usage: loadtest.sh <host:port> <label> [rate] [dur]
set -e
TARGET="$1"; LABEL="$2"; RATE="${3:-200}"; DUR="${4:-15s}"
DIR="$(dirname "$0")"
sed "s#TARGET#${TARGET}#g" "$DIR/targets.txt" \
  | vegeta attack -rate="$RATE" -duration="$DUR" -timeout=10s -keepalive=true \
  | tee "/tmp/perf-${LABEL}.bin" \
  | vegeta report -type=text
echo "--- latency histogram (${LABEL}) ---"
vegeta report -type='hist[0,1ms,2ms,5ms,10ms,25ms,50ms,100ms]' "/tmp/perf-${LABEL}.bin"
