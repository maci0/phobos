# Moonraker API-surface scanner

Extracts Moonraker's complete externally-observable API surface from its source
tree into a deterministic, diffable JSON artifact. phobos is a behaviour-identical
Zig reimplementation of Moonraker; this tool lets us detect exactly what changed
in the API whenever the vendored Moonraker is bumped, replacing the hand-written
(and easily stale) `docs/api/API_SURFACE.md`.

Parsing is done with tree-sitter (`tree-sitter-python`) — no regexes, no
importing Moonraker. The same grammar backs the sibling TypeScript scanner, so
both share one parsing approach. Requires `tree_sitter` and `tree_sitter_python`
(e.g. `pip install tree-sitter tree-sitter-python`).

## What it extracts

By walking every `.py` under a Moonraker source root:

- **HTTP/RPC endpoints** — `register_endpoint(...)` calls. Captures the path, the
  `RequestType.GET|POST|DELETE` flags, `transports`, `wrap_result`, `content_type`,
  `auth_required`/`auth`, and `is_remote`. Non-literal arguments are recorded as
  the sentinel `"<dynamic>"` instead of failing.
- **JSON-RPC methods** — derived from each endpoint's path using Moonraker's rule
  (`common.py::APIDefinition.create`): drop the leading `/`, replace `/` with `.`;
  for multi-verb endpoints the last segment is prefixed `get_`/`post_`/`delete_`
  per request type (`multi_verb: true`). HTTP-only endpoints expose no RPC method.
- **Remote methods** — `register_remote_method(...)`.
- **Static / upload handlers** — `register_static_file_handler`, `register_upload_handler`.
- **Debug endpoints** — `register_debug_endpoint(...)`, marked `debug_only: true`
  (these are gated behind Moonraker's `--debug` flag at runtime).
- **Notifications** — server-push `notify_*` names from `register_notification(...)`,
  `send_notification(...)`, and bare `notify_*` string literals (e.g. the printer
  status push `notify_status_update`).

Each record carries its `source` (`file:lineno`) and owning `component`.

## Modes

Run from the repo root with `tools` on the path:

```sh
PYTHONPATH=tools python3 -m api_scanner <mode> [--source DIR] [--baseline FILE]
```

- **`scan`** — prints the deterministic API-surface JSON to stdout. Lists are
  sorted (endpoints by path then method, methods/notifications alphabetically)
  and keys are stable, so two scans of the same tree are byte-identical and git
  diffs are meaningful.
  ```sh
  PYTHONPATH=tools python3 -m api_scanner scan --source vendor/moonraker/moonraker
  ```
- **`baseline`** — writes that JSON to `api/api_surface.json` (the committed
  baseline). Run this once per Moonraker bump after you've reconciled the drift.
  ```sh
  PYTHONPATH=tools python3 -m api_scanner baseline --source vendor/moonraker/moonraker
  ```
- **`diff`** — scans the current source and compares it against the committed
  baseline, printing a human-readable ADDED / REMOVED / CHANGED report.
  **Exit code 0 if identical, 1 if there is drift** (and 2 if the baseline file
  is missing) — so it works as a CI gate.
  ```sh
  PYTHONPATH=tools python3 -m api_scanner diff --source vendor/moonraker/moonraker \
      --baseline api/api_surface.json
  ```

- **`coverage`** — compares phobos's own API (its `--dump-api` JSON) against the
  Moonraker baseline and reports the counts + anything phobos is missing.
  **Exit 0 when phobos covers the whole baseline, 1 otherwise** — the CI coverage
  gate.
  ```sh
  zig-out/bin/phobos --dump-api > /tmp/phobos.json
  PYTHONPATH=tools python3 -m api_scanner coverage --phobos /tmp/phobos.json
  ```
- **`table`** — the full per-call comparison of phobos *against our own API*:
  emits `docs/api/API_COVERAGE.md`, a Markdown table of every endpoint / JSON-RPC
  method / notification / remote method with phobos's implementation status
  (✅ full / ⚠️ partial / 🚫 no-op / ❌ missing) and the behavioural difference
  from Moonraker, plus a reverse section listing phobos calls beyond the static
  baseline (classified: Klipper remote method, is_remote-proxied, or genuine
  phobos shim). Per-call notes come from the curated `DELTAS` map in `table.py`.
  Writes `docs/api/API_COVERAGE.md` by default; pass `--check` to instead exit 1
  when that file is stale (CI gate against doc rot).
  ```sh
  zig-out/bin/phobos --dump-api > /tmp/phobos.json
  PYTHONPATH=tools python3 -m api_scanner table --phobos /tmp/phobos.json
  PYTHONPATH=tools python3 -m api_scanner table --phobos /tmp/phobos.json --check
  ```

Defaults: `--source vendor/moonraker/moonraker`, `--baseline api/api_surface.json`.

## Re-syncing when Moonraker updates

1. Bump the vendored Moonraker (update `vendor/moonraker`).
2. Run `diff` to see what changed:
   ```sh
   PYTHONPATH=tools python3 -m api_scanner diff
   ```
3. For each ADDED / REMOVED / CHANGED item, update the phobos implementation so it
   stays behaviour-identical.
4. Once phobos matches, refresh the baseline and commit it:
   ```sh
   PYTHONPATH=tools python3 -m api_scanner baseline
   git add api/api_surface.json
   ```

## Coverage tracking (`tools/coverage.sh`)

The `coverage` subcommand compares a phobos `--dump-api` dump against the
Moonraker baseline and reports how much of the full API phobos currently
implements.

### One-command check

```sh
# From the repo root:
tools/coverage.sh
```

This script:
1. Builds phobos with `zig build`.
2. Runs `phobos --dump-api` and saves the output to a temp file.
3. Runs `python3 -m api_scanner coverage` against `api/api_surface.json`.
4. Prints a summary line and the MISSING list; exits 1 if not 100% covered.

Example output:
```
Coverage: endpoints 2/125 (1.6%), methods 4/120, notifications 27/27, OVERALL 16%

MISSING endpoints (123):
  - /access/api_key
  ...
```

### Manual invocation

```sh
# Build phobos and dump its API surface:
zig build
zig-out/bin/phobos --dump-api > /tmp/phobos-dump.json

# Run coverage:
PYTHONPATH=tools python3 -m api_scanner coverage \
    --baseline api/api_surface.json \
    --phobos /tmp/phobos-dump.json
```

- Exit code **0** — 100% covered (goal gate).
- Exit code **1** — partial coverage (current state during development).
- Exit code **2** — baseline or phobos dump file not found.

## Wiring `diff` into CI

`diff` is a ready-made gate — it exits non-zero on drift:

```yaml
# .github/workflows/api-drift.yml
name: API drift
on: [push, pull_request]
jobs:
  api-drift:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive   # vendored Moonraker
      - run: |
          PYTHONPATH=tools python3 -m api_scanner diff \
            --source vendor/moonraker/moonraker \
            --baseline api/api_surface.json
```

If the vendored Moonraker is bumped without refreshing the baseline, the job fails
and prints exactly which endpoints/methods/notifications moved.

## Tests

```sh
python3 -m pytest tools/api_scanner/tests -q
# or, if pytest isn't installed system-wide:
uv run --with pytest python3 -m pytest tools/api_scanner/tests -q
```

Covers every extractor function (endpoint/method/remote/static/notification
derivation), the diff logic and exit codes, an end-to-end CLI run over a synthetic
tree, and fuzz-style tests that feed malformed/odd-but-valid Python and assert the
scanner never crashes and degrades to `<dynamic>` or skips gracefully.

## Reconciliation against the manual inventory

Scanned `vendor/moonraker` (`0.10.1.dev20`, commit `9008485`):

| Surface             | Scanner | Manual `API_SURFACE.md` |
|---------------------|---------|-------------------------|
| Endpoints           | 125     | 125 (section-2 table)   |
| HTTP endpoints      | 117     | ~110                    |
| JSON-RPC methods    | 120     | ~130                    |
| Remote methods      | 14      | (listed separately)     |
| Notifications       | 27      | 27                      |
| Static/upload       | 6       | folded into endpoints   |

The endpoint count (125) and the notification set (27) match the manual doc
exactly. The differences are accounting, not missed surface:

- **JSON-RPC methods**: the scanner reports 120 endpoint-derived methods; adding
  the 14 remote methods (also JSON-RPC-callable) gives 134, matching the manual's
  "~130". They are kept in separate sections because they are registered through
  different code paths.
- **HTTP endpoints**: the two paths the manual lists but the scanner does not have
  as *endpoints* — `/server/files/upload` and `/api/files/local` — are **upload
  handlers** (`register_upload_handler`), captured under `static_handlers`. The
  scanner classifies by registration mechanism, which is more precise.
- The single `<dynamic>` endpoint is the runtime Klipper-proxied registration in
  `klippy_connection.py` (`is_remote=True` with a variable path); the manual
  documents these dynamic `printer.*` endpoints in a dedicated subsection.

Where they differ, the **scanner is more correct**: it reflects the actual
registration calls in the source rather than an editorial grouping.

## Known limitations

- Only the `register_*` call sites and `notify_*` string literals are analysed; a
  hypothetical registration built entirely from runtime data resolves to
  `"<dynamic>"`. The one such case today is the Klipper-proxied endpoint.
- Module-level `NAME = "string"` constants are resolved (e.g.
  `SENSOR_EVENT_NAME`), but constants imported from another module are not; none
  currently affect the result.
- `transports`/`request_types` are read as the leaf attribute names of an `X.NAME`
  OR-chain without verifying `X`, so an aliased import of `RequestType` would still
  be captured correctly.
