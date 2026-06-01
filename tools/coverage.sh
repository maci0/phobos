#!/usr/bin/env bash
# One-command API-coverage check: build phobos, dump its API, report coverage.
#
# Usage (from repo root):
#   tools/coverage.sh
#
# The script:
#   1. Builds phobos (musl / no-lmdb, same as the test suite).
#   2. Runs phobos --dump-api and saves the output to a temp file.
#   3. Runs the api_scanner coverage subcommand against api/api_surface.json.
#   4. Exits 0 if 100% covered, 1 if not.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE="${REPO_ROOT}/api/api_surface.json"
PHOBOS_BIN="${REPO_ROOT}/zig-out/bin/phobos"
DUMP_TMP="$(mktemp /tmp/phobos-dump-XXXXXX.json)"

cleanup() { rm -f "${DUMP_TMP}"; }
trap cleanup EXIT

echo "==> Building phobos (no LMDB)..."
(cd "${REPO_ROOT}" && zig build -Dwith_lmdb=false)

echo "==> Running phobos --dump-api..."
"${PHOBOS_BIN}" --dump-api > "${DUMP_TMP}"

echo "==> Computing API coverage..."
PYTHONPATH="${REPO_ROOT}/tools" python3 -m api_scanner coverage \
    --baseline "${BASELINE}" \
    --phobos "${DUMP_TMP}"
