# Moonraker API-surface scanner

Extracts Moonraker's externally observable API surface from its source tree into
a deterministic, diffable JSON artifact. phobos targets Moonraker's API; the
scanner records declared surface changes when the vendored source changes.
`api/api_surface.json` is the authoritative call list, alongside the hand-written
[`API_SURFACE.md`](../../docs/api/API_SURFACE.md) inventory.
Forge-X is tracked separately in [`api/forge_x_surface.json`](../../api/forge_x_surface.json).
Its source revisions, missing calls, behavior differences and proposed startup
profile are in [the Forge-X tracker](../../docs/api/FORGE_X.md).

Parsing uses tree-sitter (`tree-sitter-python`): no regexes, no importing
Moonraker. [`tools/client_api_scanner`](../client_api_scanner/README.md) uses the
same tree-sitter approach for client sources.

## What it extracts

From every `.py` under a Moonraker source root:

- **HTTP/RPC endpoints**: `register_endpoint(...)` calls. Captures the path, the
  `RequestType.GET|POST|DELETE` flags, `transports`, `wrap_result`, `content_type`,
  `auth_required`/`auth`, and `is_remote`. Non-literal arguments are recorded as
  the sentinel `"<dynamic>"` instead of failing.
  Legacy string lists such as `['GET', 'POST']` are supported, including
  case normalization and duplicate removal. Coverage mounts literal remote
  registrations such as `objects/list` under `/printer/`.
- **JSON-RPC methods**: derived from each endpoint's path by Moonraker's rule
  (`common.py::APIDefinition.create`): drop the leading `/`, replace `/` with `.`;
  for multi-verb endpoints the last segment is prefixed `get_`/`post_`/`delete_`
  per request type (`multi_verb: true`). HTTP-only endpoints expose no RPC method.
- **Remote methods**: `register_remote_method(...)`.
- **Static and upload handlers**: `register_static_file_handler`, `register_upload_handler`.
- **Debug endpoints**: `register_debug_endpoint(...)`, marked `debug_only: true`
  (Moonraker gates them behind its `--debug` flag at runtime).
- **Notifications**: server-push `notify_*` names from `register_notification(...)`,
  `send_notification(...)`, and bare `notify_*` string literals (e.g. the printer
  status push `notify_status_update`).

Each record carries its `source` (`file:lineno`) and owning `component`.

## Modes

Run from the repo root with `tools` on the path. The examples below use this
shell function:

```sh
api_scanner() { PYTHONPATH=tools uv run --with tree-sitter --with tree-sitter-python python -m api_scanner "$@"; }
api_scanner <mode> [--source DIR] [--baseline FILE]
```

Defaults: `--source vendor/moonraker/moonraker`, `--baseline api/api_surface.json`.

- **`scan`** prints the API-surface JSON to stdout. Lists are sorted (endpoints by
  path then method, methods and notifications alphabetically) and keys are stable,
  so two scans of the same tree are byte-identical and git diffs are meaningful.
  ```sh
  api_scanner scan --source vendor/moonraker/moonraker
  ```
- **`baseline`** writes that JSON to `api/api_surface.json` (the committed
  baseline). Run it once per Moonraker bump, after reconciling the drift.
  ```sh
  api_scanner baseline --source vendor/moonraker/moonraker
  ```
- **`diff`** scans the current source and compares it against the committed
  baseline, printing an ADDED / REMOVED / CHANGED report. Exit 0 if identical,
  1 on drift, 2 if the baseline file is missing, so it can gate CI.
  ```sh
  api_scanner diff --source vendor/moonraker/moonraker --baseline api/api_surface.json
  ```
- **`coverage`** compares phobos's `--dump-api` JSON against the Moonraker
  baseline and reports the counts and anything phobos is missing. Exit 0 when
  phobos covers the whole baseline, 1 otherwise.
  ```sh
  mkdir -p .scratch && zig-out/bin/phobos --data-path "$PWD/.scratch/api-dump-data" --dump-api > .scratch/api-dump.json
  api_scanner coverage --phobos .scratch/api-dump.json
  ```
- **`table`** writes `docs/api/API_COVERAGE.md`: a Markdown table of every
  endpoint, JSON-RPC method, notification, and remote method with phobos's status
  (✅ no recorded delta / ⚠️ known differences / 🚫 no-op / ❌ missing) and its
  recorded behavioural difference from Moonraker, plus a section listing phobos
  calls beyond the static baseline (classified as Klipper remote method,
  is_remote-proxied, or phobos shim).
  Per-call notes come from the curated `DELTAS` map in `table.py`. An unlisted
  implemented call defaults to no recorded delta; that is not a conformance
  test. `--output` picks another path; `--check` exits 1 when the file is stale
  instead of rewriting it.
  ```sh
  api_scanner table --phobos .scratch/api-dump.json
  api_scanner table --phobos .scratch/api-dump.json --check
  ```

## Re-syncing when Moonraker updates

1. Update `vendor/moonraker`.
2. Run `api_scanner diff` to see what changed.
3. For each ADDED / REMOVED / CHANGED item, update phobos to match.
4. Once phobos matches, refresh and commit the baseline:
   ```sh
   api_scanner baseline
   git add api/api_surface.json
   ```

## Coverage check (`tools/coverage.sh`)

```sh
tools/coverage.sh
```

The script builds phobos with `zig build`, writes `phobos --dump-api` to
`.scratch/api-dump.json`, and runs `api_scanner coverage` against
`api/api_surface.json` through `uv run`.
It prints a summary line plus the MISSING list and exits 1 below 100%. Output at
the current baseline:

```
Coverage: endpoints 123/123 (100.0%), methods 130/130, notifications 27/27, OVERALL 100%
```

`coverage` exit codes: 0 when fully covered, 1 when partial, 2 when the baseline
or phobos dump file is not found.

The script rebuilds the default native target. Name coverage does not establish
target ABI correctness, runtime behavior or benchmark results. See the
[build matrix](../../docs/BUILDS.md) for target-specific evidence and the
[coverage limits](../../docs/api/COVERAGE_HEATMAP.md) for what this gate proves.

[CI](../../.github/workflows/ci.yml) runs scanner tests, upstream coverage and
`table --check`. Forge-X coverage is a separate incomplete target; its missing
timelapse calls are recorded rather than added to the upstream pass requirement.

## Tests

```sh
PYTHONPATH=tools uv run --with pytest --with tree-sitter --with tree-sitter-python \
  pytest tools/api_scanner/tests -q --basetemp=.scratch/api-scanner-tests
```

They cover every extractor function (endpoint, method, remote, static, and
notification derivation), the diff logic and exit codes, an end-to-end CLI run
over a synthetic tree, and fuzz tests that feed malformed or unusual Python and
assert the scanner never crashes and degrades to `<dynamic>` or skips the input.

## Counts at the pinned baseline

Scanned `vendor/moonraker` (`0.10.1.dev20+g9008485`, commit `900848584374`):

| Surface | Count |
| --- | --- |
| Endpoint registration records | 125 |
| Distinct literal endpoint paths, across transports | 123 |
| HTTP-enabled registration records | 117, including 116 literal paths |
| Endpoint-derived JSON-RPC names | 130 |
| Remote-method registration records | 14 |
| Notifications | 27 |
| Static/upload handlers | 6 |

Two endpoint records have `<dynamic>` paths: the debug-registration wrapper in
`application.py` and runtime Klippy-proxied registration in `klippy_connection.py`.
The name gate excludes them and checks the 123 literal paths. Runtime Klippy
registration needs a separate connection test.

JSON-RPC names are flattened and deduplicated from endpoints. Remote-method
records stay separate; adding their count does not measure distinct JSON-RPC
names. Upload paths `/server/files/upload` and `/api/files/local` are captured
under `static_handlers`, rather than as endpoint registrations. The
[manual inventory](../../docs/api/API_SURFACE.md) groups these APIs for readers;
the scanner follows their registration calls.

## Known limitations

- Only `register_*` call sites and `notify_*` string literals are analysed; a
  registration built entirely from runtime data resolves to `"<dynamic>"`. The
  pinned baseline contains the debug wrapper and Klipper-proxied registrations.
- Module-level `NAME = "string"` constants are resolved (e.g.
  `SENSOR_EVENT_NAME`), but constants imported from another module are not; none
  affect the current result.
- `transports`/`request_types` are read as the leaf attribute names of an
  `X.NAME` OR-chain without checking `X`, so an aliased import of `RequestType`
  is still captured.
