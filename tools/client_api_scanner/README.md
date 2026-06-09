# Client API scanner

Extracts every Moonraker JSON-RPC method each reference **client** calls, straight
from its source, and cross-references them against phobos and upstream Moonraker.

phobos is a drop-in Moonraker backend, so the clients are extra sources of truth
for the API surface (alongside vendored Moonraker via
[`tools/api_scanner`](../api_scanner/README.md)): a method a client calls that
phobos does not register breaks that client on connect. This makes such a gap
impossible to miss, and turns a client version bump into a reviewable diff.

## Clients & call idioms (parsed with tree-sitter — no regex)

| Client | Language | Grammar | Call idiom |
|---|---|---|---|
| Mainsail, Fluidd | TypeScript / Vue | `tree-sitter-typescript` | `Vue.$socket.emit('m', …)`, `baseEmit('m', …)` |
| KlipperScreen | Python (GTK) | `tree-sitter-python` | `self._ws.send_method('m', …)`, `self._send_action(w, 'm', …)` |
| GuppyScreen, HelixScreen | C++ (LVGL) | `tree-sitter-cpp` | `ws.send_jsonrpc("m", …)` |

The Moonraker scanner uses the same grammar family (`tree-sitter-python`). For
each language the scanner finds calls whose callee is a known "send" method and
takes the method-name string literal at that callee's argument index
(KlipperScreen's `_send_action` takes a widget first, so its method is arg 1).
Vue `<script>` blocks are sliced out and parsed as TypeScript.

## Artifacts (checked in, regenerated, diffable) — `docs/api/client/`

`fluidd.json`, `mainsail.json`, `klipperscreen.json`, `guppyscreen.json`,
`helixscreen.json` (per-client method lists, version-pinned), `phobos_methods.json`
(`phobos --dump-api`), `moonraker_methods.json` (from `tools/api_scanner`), and
`coverage.json`. The human matrix is
[`docs/api/CLIENT_API_COVERAGE.md`](../../docs/api/CLIENT_API_COVERAGE.md) —
method × {Moonraker, phobos, every client}, with the "client calls it / phobos
lacks it" gap list called out.

## Regenerate / track changes

```sh
# deps (one-time)
python3 -m venv .venv
.venv/bin/pip install tree-sitter tree-sitter-typescript tree-sitter-python tree-sitter-cpp

# clone each client at the version you support (pin the tags), then scan its source:
python tools/client_api_scanner/scan.py <fluidd>/src       --ui fluidd        --version vX -o docs/api/client/fluidd.json
python tools/client_api_scanner/scan.py <mainsail>/src      --ui mainsail      --version vX -o docs/api/client/mainsail.json
python tools/client_api_scanner/scan.py <KlipperScreen>     --ui klipperscreen --version vX -o docs/api/client/klipperscreen.json
python tools/client_api_scanner/scan.py <guppyscreen>/src   --ui guppyscreen   --version vX -o docs/api/client/guppyscreen.json
python tools/client_api_scanner/scan.py <helixscreen>/src   --ui helixscreen   --version vX -o docs/api/client/helixscreen.json

# refresh phobos + moonraker method sets
zig build && ./zig-out/bin/phobos --dump-api | jq '{jsonrpc_methods:(.jsonrpc_methods|sort)}' > docs/api/client/phobos_methods.json
python -m api_scanner scan --source vendor/moonraker/moonraker | jq '{jsonrpc_methods:([.jsonrpc_methods[].method]|sort)}' > docs/api/client/moonraker_methods.json

# rebuild the matrix (exit 1 if any client calls a method phobos lacks)
python tools/client_api_scanner/coverage.py --dir docs/api/client \
  --md docs/api/CLIENT_API_COVERAGE.md --json docs/api/client/coverage.json
```

Commit the regenerated artifacts; the diff is the changelog of what the clients
started/stopped calling. Adding another client = clone it + one `scan.py` line
(`--ui <name>`) + regenerate.

## Known non-gaps

The remaining gaps are all **third-party plugins or client-specific extensions**
(absent from core Moonraker too): `machine.timelapse.*` (the `moonraker-timelapse`
plugin), `server.helix.*` (HelixScreen ships its own Moonraker plugin), and
HelixScreen's non-standard `server.files.get_file`. phobos returns `-32601` for
these and the clients hide the feature — same as against stock Moonraker without
the plugin.
