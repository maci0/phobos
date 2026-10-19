<p align="center">
  <img src="assets/logo.svg" alt="phobos" width="520">
</p>

# phobos

A memory-efficient reimplementation of [Moonraker](https://github.com/Arksine/moonraker)
— the API server for the [Klipper](https://www.klipper3d.org/) 3D-printer firmware —
written in **Zig 0.17**, designed to behave 100% identically to upstream while running
lean on small ARM hardware.

> phobos — the smaller, faster of Mars' two moons. A lean reimplementation orbiting the
> same API.

## Why

Moonraker is a ~36k-LOC Python/asyncio + Tornado server. On a Raspberry-Pi-class host it
carries the Python runtime, an event loop, and a heap that grows with load. phobos targets
the same external contract — every HTTP/WebSocket/JSON-RPC endpoint and notification — with
a static native binary, bounded buffers, and a thread-pool runtime, so it fits comfortably
on a **32-bit ARM Cortex-A7** printer host.

## Memory footprint

Measured on this host (`ReleaseSmall` + LTO + stripped), reproducible with
[`scripts/measure-memory.sh`](scripts/measure-memory.sh):

| | phobos | bare Python 3 (stdlib only) | Moonraker (typical) |
|---|---|---|---|
| On-disk | **2.1 MB** static binary | interpreter + site-packages | + interpreter + deps |
| Idle RSS | **~3.7 MB** | ~25 MB | ~50–80 MB |
| Runtime deps | **none** | CPython | CPython + tornado + sqlite + jinja2 + … |

phobos idles in **less RAM than an empty Python interpreter that has only imported
`json`/`asyncio`/`sqlite3`** — i.e. below the floor Moonraker starts from, before
its ~30 components load. That is a **~15–20× reduction** versus a full Moonraker,
in a single dependency-free binary. (The binary grew ~0.9 MB when the store
uses a vendored SQLite for moonraker-sql.db compatibility.) Details:
[`docs/MEMORY.md`](docs/MEMORY.md).

## Status

- **~99% overall implementation progress** (API surface 100%, implementation depth weighted
  by component — see [coverage heatmap](docs/api/COVERAGE_HEATMAP.md) and the per-call
  [API coverage table](docs/api/API_COVERAGE.md)).
- **100% of Moonraker's API surface is covered**: 130/130 JSON-RPC methods, 123/123 static
  endpoints, 27/27 server notifications, 4/4 transport routes (measured automatically — see
  below).
- 1435 in-tree tests pass, with one gated real-Klippy test skipped.
- [v0.1.4 release notes](docs/releases/v0.1.4.md) cover standard streams, bounded containers and root-contained file operations. [v0.1.3](docs/releases/v0.1.3.md) covers native I/O, owned state and client transports. [v0.1.2](docs/releases/v0.1.2.md) covers the ARM Fluidd crash fix.
- This is **surface + shape parity**, plus a live Klippy path validated by a gated real-Klippy
  integration test. Byte-identical *behavioral* parity (verified against a running stock
  Moonraker) is still being hardened — see [`TODO.md`](TODO.md).

## What works today

Full request/response and notification plumbing across all components: server info/config,
database, file manager, history, job queue, announcements, authorization (JWT + password
hashing compatible with Moonraker's formats), machine info / proc stats / services /
peripherals, update manager, power / WLED / device control, spoolman, sensors, webcams,
notifiers, analysis, extensions, OctoPrint-compat, and the `printer.*` proxy surface.

Many formerly-stubbed subsystems now do real I/O: a real MQTT 3.1.1 client with TLS and
automatic reconnect/backoff, a Spoolman WebSocket, sysfs GPIO power, WLED/TD-1 serial with
USB auto-discovery, MQTT sensors with `state_response_template` (an in-tree Jinja subset),
`git fetch/reset` update paths, RSS fetch with ETag conditional GET, and a live Klippy bridge.
The remaining gaps need external tools (klipper_estimator binary, apprise) or are host-mutating
actions (reboot/shutdown/apt/pip) kept as deliberate no-ops; see the "subsystem depth" section
of [`TODO.md`](TODO.md).

## Architecture (one paragraph)

Networking is `std.Io.net` over the `std.Io.Threaded` backend (the only standard Io backend
available on 32-bit ARM). A listener accepts connections and spawns a per-connection task;
HTTP and WebSocket are handled by `std.http` over those streams. All transports converge on
one JSON-RPC dispatcher backed by a runtime method table. A **serialized core** (a single
mutex + monotonic sequence) runs every handler and notification fan-out so the observable
ordering matches Moonraker's single asyncio loop. Persistence uses a vendored SQLite database (Moonraker moonraker-sql.db-compatible) with
Moonraker's exact on-disk format. See [`DEVELOPMENT.md`](DEVELOPMENT.md) and
[`docs/superpowers/specs/2026-06-01-phobos-server-spine-design.md`](docs/superpowers/specs/2026-06-01-phobos-server-spine-design.md)
for detail.

## Repository layout

```
build.zig                 build graph (musl default; cross-target options)
src/
  main.zig                entry point + --dump-api
  app.zig                 App: wires everything; registerAll() is the registration point
  io.zig                  std.Io.Threaded listener / accept loop
  jsonrpc.zig             JSON-RPC 2.0 dispatcher + error codes
  http_transport.zig      HTTP/REST + /server/jsonrpc over std.http
  transport/ws.zig        WebSocket transport over std.http
  server/                 core (serialized mutex), connections, notify bus, registry
  config/                 confighelper-compatible parser
  store/                  DataStore interface + SQLite + atomic-rename file backends
  core/methods.zig        server.info / server.config
  components/*.zig        one module per Moonraker component
  testutil/               TestServer + HTTP/WS test clients
vendor/sqlite/       vendored SQLite 3.47.0 amalgamation
tools/api_scanner/        Moonraker API extractor + drift + coverage tooling
tools/client_api_scanner/ multi-language client-call scanner (Mainsail/Fluidd/KlipperScreen/GuppyScreen/HelixScreen)
tools/perf_harness/       phobos-vs-Moonraker load tests + perf/eBPF profiling
api/api_surface.json      authoritative API baseline (generated)
docs/                     specs, plans, API surface, test findings, coverage map
TODO.md                   status + remaining work (read this for what's next)
```

## Quick start

Requires **Zig 0.17.0** and (for the tooling) Python 3 + `uv`.

```sh
# Run the test suite (musl-static by default)
zig build test --summary all

# See the API surface phobos registers
zig build && zig-out/bin/phobos --dump-api | less
zig build && zig-out/bin/phobos schema

# Check API coverage against Moonraker (exit 0 == 100%)
tools/coverage.sh

# Cross-compile a static binary for the Cortex-A7 deploy target
zig build -Dtarget=arm-linux-musleabihf -Dcpu=cortex_a7 -Doptimize=ReleaseSmall
```

> Note: this project builds against **musl** by default because some hosts (and the deploy
> target) can't link the system glibc with Zig 0.17. Don't run a plain glibc `zig build`.

## Keeping in sync with Moonraker

phobos tracks a pinned Moonraker checkout (`vendor/moonraker`, gitignored). The
`api_scanner` tool extracts Moonraker's full API surface so drift is caught automatically
when upstream is bumped:

```sh
# after updating vendor/moonraker, see what changed in the API (exit 1 on drift):
PYTHONPATH=tools python3 -m api_scanner diff --source vendor/moonraker/moonraker \
  --baseline api/api_surface.json
```

## Documentation

- [`TODO.md`](TODO.md) — current status and prioritized remaining work.
- [`DEVELOPMENT.md`](DEVELOPMENT.md) — how to build, test, and add a component.
- [`docs/superpowers/specs/`](docs/superpowers/specs) — design spec.
- [`docs/api/API_SURFACE.md`](docs/api/API_SURFACE.md) — the API contract.
- [`docs/api/COVERAGE_HEATMAP.md`](docs/api/COVERAGE_HEATMAP.md) — per-component coverage heatmap and depth scores.
- [`docs/TEST_RUN_FINDINGS.md`](docs/TEST_RUN_FINDINGS.md) — why upstream's own test suite
  can't be used as the parity oracle.

## License

The phobos source follows the upstream project's license intent (GPL-3.0-only, matching
Moonraker). Vendored SQLite under `vendor/sqlite/` is public domain.
