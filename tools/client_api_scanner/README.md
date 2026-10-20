# Client API scanner

Extracts every Moonraker JSON-RPC method each reference client calls, straight
from the client's source, and cross-references them against phobos and upstream
Moonraker.

The clients show which method names matter alongside vendored Moonraker (scanned
by [`tools/api_scanner`](../api_scanner/README.md)). The matrix lists client calls
that phobos does not register. It does not test method behavior or whether a
client handles a missing plugin. Version-pinned inputs make changes reviewable.

## Clients and call idioms (parsed with tree-sitter, no regex)

| Client | Language | Grammar | Call idiom |
|---|---|---|---|
| Mainsail, Fluidd | TypeScript / Vue | `tree-sitter-typescript` | `Vue.$socket.emit('m', …)`, `baseEmit('m', …)` |
| KlipperScreen | Python (GTK) | `tree-sitter-python` | `self._ws.send_method('m', …)`, `self._send_action(w, 'm', …)` |
| GuppyScreen, HelixScreen | C++ (LVGL) | `tree-sitter-cpp` | `ws.send_jsonrpc("m", …)` |

For each language the scanner finds calls whose callee is a known send method and
takes the method-name string literal at that callee's argument index
(KlipperScreen's `_send_action` takes a widget first, so its method is argument 1).
Vue `<script>` blocks are sliced out and parsed as TypeScript.

## Artifacts in `docs/api/client/` (checked in, regenerated, diffable)

`fluidd.json`, `mainsail.json`, `klipperscreen.json`, `guppyscreen.json`, and
`helixscreen.json` (per-client method lists, version-pinned), `phobos_methods.json`
(`phobos --dump-api`), `moonraker_methods.json` (from `tools/api_scanner`), and
`coverage.json`. The readable matrix is
[`docs/api/CLIENT_API_COVERAGE.md`](../../docs/api/CLIENT_API_COVERAGE.md):
method × {Moonraker, phobos, every client}, with the list of methods a client
calls that phobos lacks.

## Regenerate

```sh
ts() { uv run --with tree-sitter --with tree-sitter-typescript --with tree-sitter-python --with tree-sitter-cpp "$@"; }

# clone each client at the version you support (pin the tags), then scan its source:
ts python tools/client_api_scanner/scan.py <fluidd>/src       --ui fluidd        --version vX -o docs/api/client/fluidd.json
ts python tools/client_api_scanner/scan.py <mainsail>/src     --ui mainsail      --version vX -o docs/api/client/mainsail.json
ts python tools/client_api_scanner/scan.py <KlipperScreen>    --ui klipperscreen --version vX -o docs/api/client/klipperscreen.json
ts python tools/client_api_scanner/scan.py <guppyscreen>/src  --ui guppyscreen   --version vX -o docs/api/client/guppyscreen.json
ts python tools/client_api_scanner/scan.py <helixscreen>/src  --ui helixscreen   --version vX -o docs/api/client/helixscreen.json

# refresh the phobos and Moonraker method sets
zig build && ./zig-out/bin/phobos --dump-api | jq '{jsonrpc_methods:(.jsonrpc_methods|sort)}' > docs/api/client/phobos_methods.json
PYTHONPATH=tools ts python -m api_scanner scan --source vendor/moonraker/moonraker | jq '{jsonrpc_methods:([.jsonrpc_methods[].method]|sort)}' > docs/api/client/moonraker_methods.json

# rebuild the matrix (exit 1 if any client calls a method phobos lacks)
uv run python tools/client_api_scanner/coverage.py --dir docs/api/client \
  --md docs/api/CLIENT_API_COVERAGE.md --json docs/api/client/coverage.json
```

Commit the regenerated artifacts; the diff records which methods the clients
started or stopped calling. Adding a client takes a clone, one `scan.py` line
(`--ui <name>`), and a regenerate.

Tests:

```sh
uv run --with pytest --with tree-sitter --with tree-sitter-typescript --with tree-sitter-python \
  --with tree-sitter-cpp pytest tools/client_api_scanner/tests -q
```

## Known non-gaps

The remaining gaps are third-party plugins or client-specific extensions, also
absent from core Moonraker: `machine.timelapse.*` (the `moonraker-timelapse`
plugin), `server.helix.*` (HelixScreen ships its own Moonraker plugin), and
HelixScreen's non-standard `server.files.get_file`. phobos returns `-32601` for
unregistered methods. The scanner does not test how clients handle that error.
