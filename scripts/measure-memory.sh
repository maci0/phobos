#!/usr/bin/env bash
# Measure phobos's idle memory footprint and compare to a Python baseline.
#
# Reproduces the numbers quoted in docs/MEMORY.md: builds the release binary,
# starts an idle server, lets it settle, and samples VmRSS from /proc. Also
# samples a bare Python interpreter (Moonraker's runtime floor — Moonraker itself
# needs tornado/sqlite/jinja2 + ~30 components on top, which weigh far more).
#
# Read-only / non-destructive: binds a local port, samples /proc, kills its own
# child. Does not touch the host beyond a temp config + temp db file.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${1:-7188}"
CFG="$(mktemp /tmp/phobos-mem-XXXX.cfg)"
printf '[server]\nhost: 127.0.0.1\nport: %s\n' "$PORT" > "$CFG"
cleanup() { kill -9 "${PHOBOS_PID:-0}" 2>/dev/null || true; rm -f "$CFG"; }
trap cleanup EXIT

echo "Building release (ReleaseSmall + LTO + stripped)…"
zig build -Doptimize=ReleaseSmall >/dev/null 2>&1
BIN=zig-out/bin/phobos
BIN_BYTES=$(stat -c%s "$BIN")

echo "Starting idle phobos on 127.0.0.1:$PORT…"
"$BIN" -c "$CFG" >/dev/null 2>&1 &
PHOBOS_PID=$!
sleep 6  # let startup scratch free + background workers settle

read_kib() { awk -v k="$1" '$1==k":"{print $2}' "/proc/$2/status"; }
PH_RSS=$(read_kib VmRSS "$PHOBOS_PID")
PH_HWM=$(read_kib VmHWM "$PHOBOS_PID")
PH_THREADS=$(read_kib Threads "$PHOBOS_PID")

# Bare Python interpreter floor (stdlib only — Moonraker imports far more).
PY_RSS=$(python3 -c '
import os,json,asyncio,logging,pathlib,sqlite3
with open(f"/proc/{os.getpid()}/status") as f:
    print(next(l.split()[1] for l in f if l.startswith("VmRSS")))
' 2>/dev/null || echo "n/a")

printf '\n%-28s %12s %12s\n' "" "phobos" "python3 floor"
printf '%-28s %12s %12s\n'   "binary / interpreter" "$(awk "BEGIN{printf \"%.2f MB\", $BIN_BYTES/1048576}")" "system"
printf '%-28s %12s %12s\n'   "idle RSS (settled)"   "$(awk "BEGIN{printf \"%.1f MB\", $PH_RSS/1024}")" "$(awk "BEGIN{printf \"%.1f MB\", ${PY_RSS:-0}/1024}")"
printf '%-28s %12s\n'        "peak RSS (VmHWM)"      "$(awk "BEGIN{printf \"%.1f MB\", $PH_HWM/1024}")"
printf '%-28s %12s\n'        "threads"               "$PH_THREADS"
echo
echo "Note: phobos VmData is mostly reserved thread-stack address space, not"
echo "resident RAM. The Python figure is the interpreter floor; a full Moonraker"
echo "install (tornado + sqlite + jinja2 + ~30 components) is typically 50-80 MB RSS."
