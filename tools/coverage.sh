#!/usr/bin/env bash
# One-command API-coverage check: build phobos, dump its API, report coverage.
#
# Usage (from repo root):
#   tools/coverage.sh
#
# The script:
#   1. Builds phobos (musl-static, same as the test suite).
#   2. Runs phobos --dump-api and saves the output to .scratch/api-dump.json.
#   3. Runs the api_scanner coverage subcommand against api/api_surface.json.
#   4. Exits 0 if 100% covered, 1 if not.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE="${REPO_ROOT}/api/api_surface.json"
PHOBOS_BIN="${REPO_ROOT}/zig-out/bin/phobos"
DUMP="${REPO_ROOT}/.scratch/api-dump.json"

echo "==> Building phobos..."
(cd "${REPO_ROOT}" && zig build)

echo "==> Running phobos --dump-api..."
mkdir -p "${REPO_ROOT}/.scratch"
"${PHOBOS_BIN}" --data-path "${REPO_ROOT}/.scratch/api-dump-data" --dump-api > "${DUMP}"

echo "==> Computing API coverage..."
PYTHONPATH="${REPO_ROOT}/tools" uv run --with tree-sitter --with tree-sitter-python \
    python -m api_scanner coverage --baseline "${BASELINE}" --phobos "${DUMP}"
