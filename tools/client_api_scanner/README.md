# Client API scanner

Extracts every Moonraker JSON-RPC method the **Mainsail** and **Fluidd** web UIs
call, straight from their TypeScript/Vue source, into deterministic, diffable JSON
artifacts — then cross-references them against phobos and upstream Moonraker.

phobos is a drop-in Moonraker backend, so the two reference UIs are a *second
source of truth* for the API surface (alongside vendored Moonraker via
[`tools/api_scanner`](../api_scanner/README.md)): if a UI calls a method phobos
does not register, that UI breaks on connect. This tool makes such a gap
impossible to miss, and turns a UI version bump into a reviewable diff.

## Parsing: tree-sitter (no regex)

Source is parsed with **tree-sitter** (`tree-sitter-typescript`) — the same
no-regex approach the Moonraker scanner uses (`tree-sitter-python`). Both UIs
funnel their requests through a websocket `emit(method, params, {action})`:

```ts
Vue.$socket.emit('server.database.get_item', {...}, { action: 'gui/initStore' })   // Mainsail
baseEmit('machine.services.restart', {...})                                         // Fluidd
```

`scan.py` walks every `.ts`/`.js`/`.vue` (Vue `<script>` blocks are sliced out and
parsed as TypeScript), finds every call whose callee is `emit`/`baseEmit`, takes
the first string-literal argument as the RPC method, and records the trailing
`action:` property as the UI-side response handler (useful when a bad response
*shape* — not a missing method — breaks a UI store init).

## Artifacts (checked in, regenerated, diffable)

Under [`docs/api/client/`](../../docs/api/client/):

| File | What |
|---|---|
| `fluidd.json` | Methods Fluidd calls + method→action map, pinned to a UI version |
| `mainsail.json` | Methods Mainsail calls + method→action map |
| `phobos_methods.json` | What phobos registers (`phobos --dump-api`) |
| `moonraker_methods.json` | Upstream Moonraker surface (from `tools/api_scanner`) |
| `coverage.json` | The full cross-reference matrix + UI gap list |

The human-readable matrix is [`docs/api/CLIENT_API_COVERAGE.md`](../../docs/api/CLIENT_API_COVERAGE.md).

## Regenerate / track changes

```sh
# deps (one-time): tree-sitter + the two grammars
python3 -m venv .venv && .venv/bin/pip install tree-sitter tree-sitter-typescript tree-sitter-python

# 1. clone the UI source at the versions you run (pin the tags)
git clone --depth 1 -b v1.37.1 https://github.com/fluidd-core/fluidd
git clone --depth 1 -b v2.13.2 https://github.com/mainsail-crew/mainsail

# 2. extract each UI's calls
python tools/client_api_scanner/scan.py fluidd/src  --ui fluidd  --version v1.37.1 -o docs/api/client/fluidd.json
python tools/client_api_scanner/scan.py mainsail/src --ui mainsail --version v2.13.2 -o docs/api/client/mainsail.json

# 3. refresh phobos + moonraker method sets
zig build && ./zig-out/bin/phobos --dump-api | jq '{jsonrpc_methods: (.jsonrpc_methods|sort)}' > docs/api/client/phobos_methods.json
python -m api_scanner scan --source vendor/moonraker/moonraker | jq '{jsonrpc_methods: ([.jsonrpc_methods[].method]|sort)}' > docs/api/client/moonraker_methods.json

# 4. rebuild the matrix (exit code 1 if any UI calls a method phobos lacks)
python tools/client_api_scanner/coverage.py \
  --moonraker docs/api/client/moonraker_methods.json --phobos docs/api/client/phobos_methods.json \
  --fluidd docs/api/client/fluidd.json --mainsail docs/api/client/mainsail.json \
  --md docs/api/CLIENT_API_COVERAGE.md --json docs/api/client/coverage.json
```

Commit the regenerated artifacts; the diff is the changelog of what the UIs
started/stopped calling.

## Known non-gap

`machine.timelapse.*` shows as a UI gap. Timelapse is a **third-party Moonraker
plugin** (`moonraker-timelapse`), not part of core Moonraker — it is absent from
`moonraker_methods.json` too. Mainsail/Fluidd call it optionally and hide the
feature when the server returns `-32601`, exactly as against a stock Moonraker
without the plugin. Not a phobos bug.
