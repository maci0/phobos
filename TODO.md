# phobos — Status & Handoff TODO

phobos is a memory-efficient **Zig 0.16** reimplementation of **Moonraker** (Klipper's
API server) intended to behave 100% identically. Target: ARM **Cortex-A7** (32-bit),
static musl binary.

This file is the single source of truth for "what's done / what's left." Read it,
then `docs/superpowers/specs/2026-06-01-phobos-server-spine-design.md` (design) and
`docs/superpowers/plans/2026-06-01-phobos-server-spine.md` (plan).

---

## 1. Snapshot (current state)

- Branch: **`spine`**. Tree is clean and green at HEAD.
- **API surface coverage: 100%** — methods 120/120, static endpoints 123/123,
  notifications 27/27, router routes 4/4. Verified by the coverage tool (exit 0).
- Tests: **619 pass / 5 skip / 0 fail** (92 fuzz). Verified by running test binary
  directly: `./.zig-cache/o/*/test --cache-dir=./.zig-cache`. Note: `zig build test`
  uses `--listen=-` protocol which may hang on this machine (Zig 0.16 build-runner
  quirk); always verify via the direct test binary.
  The 5 skips are: 2 webcam notification unit tests (known deadlock, see §4),
  1 lmdb drop-in test (missing `data.mdb` fixture), 2 unused.
- Peak RSS for the full test run ≈ 12–18 MB.

### Build / test / run — IMPORTANT host quirks
- This host's **system glibc cannot be linked** by Zig 0.16 (GCC 16 `.sframe` reloc).
  The build defaults the native target to **musl**, so normal commands work — but
  **never run plain `zig build` against a glibc target**.
- Default build links the **vendored lmdb** (`third_party/lmdb/`, LMDB 0.9.31).
  - Full suite (lmdb): `timeout 220 zig build test --summary all`
  - No-lmdb (faster, no C compile): `zig build test -Dwith_lmdb=false`
  - Single non-`../`-importing file: `zig test -target x86_64-linux-musl src/<f>.zig`
    (files under `src/components`, `src/testutil` use `../` imports and only build via
    `zig build test`).
- Cross-compile (deploy): `zig build -Dtarget=arm-linux-musleabihf -Dcpu=cortex_a7 -Doptimize=ReleaseSmall`
  → static ARM binary.
- Dump the API phobos actually registers: `zig build -Dwith_lmdb=false && zig-out/bin/phobos --dump-api`
- **Coverage gate** (the "are we at 100%?" check):
  ```
  zig build -Dwith_lmdb=false && zig-out/bin/phobos --dump-api > /tmp/d.json
  PYTHONPATH=tools python3 -m api_scanner coverage --baseline api/api_surface.json --phobos /tmp/d.json
  ```
  Exit 0 = 100%. Or just `tools/coverage.sh`.

### Conventions (do not violate)
- **No AI attribution anywhere** (commits, comments, docs). Commit as
  `git -c user.name='maci' -c user.email='maci.stgn@gmail.com' commit`.
- **Every function gets a unit test AND a fuzz test**, in-file (`test {}` blocks).
- TDD: failing test → minimal impl → green → commit.
- Networking = `std.Io.net` over `std.Io.Threaded` (NEVER raw socket syscalls).
  HTTP + WebSocket = `std.http` over those streams. No hand-rolled HTTP/RFC6455.

---

## 2. Architecture (how it fits together)

- **Runtime**: `std.Io.Threaded` thread-pool backend (the only std Io backend on
  32-bit ARM). One `std.Io` handle threaded through `App`.
- **Serialized core** (`src/server/core.zig`): a single `Io.Mutex` + monotonic seq.
  All JSON-RPC handler execution and notification fan-out run **under this lock** so the
  observable order matches Moonraker's single asyncio loop. `core.run(io, fn, args)`
  runs a handler with the lock held.
- **Transports** converge on one JSON-RPC dispatcher:
  - `src/http_transport.zig` — HTTP/1.1 over `std.http.Server`; REST + `/server/jsonrpc`
    + upload/download + router routes (`/`, `/server/redirect`, `/server/jsonrpc`).
  - `src/transport/ws.zig` — WebSocket over `std.http`'s WS; `/websocket`, `/klippysocket`;
    WS-only methods (`server.connection.identify`, `server.websocket.id`).
- **Dispatcher** (`src/jsonrpc.zig`): runtime method table, error codes
  -32700/-32600/-32601/-32602 (+ -32603, +503 for Klippy-disconnected).
- **Registry** (`src/server/registry.zig`): `ApiDef` → registers an HTTP route AND the
  derived JSON-RPC method (path `/`→`.`, multi-verb → `get_/post_/delete_` prefix,
  GET,POST,DELETE order). Mirrors `common.py::APIDefinition.create`.
- **App** (`src/app.zig`): owns Core, Dispatcher, Registry, Connections, NotifyBus,
  config, DataStore, and all component contexts. `registerAll()` is the single place
  every endpoint registers. `httpServer()` wires live `io` into components via `setIo`.
- **NotifyBus** (`src/server/notify.zig`): 27 notification names; `emit` (takes Core
  lock) vs **`emitLocked`** (no lock — for handlers already under Core). Per-connection
  write mutex so notifications never interleave with responses.
- **Connections** (`src/server/connections.zig`): active WS connection registry,
  monotonic ids, subscription gating for `notify_status_update`.
- **Config** (`src/config/`): confighelper-compatible parser (sections, `:`/`=`,
  comments, includes, type coercion).
- **DataStore** (`src/store/`): `DataStore` interface + vendored-lmdb backend with
  Moonraker's exact dotted-key + record-encoding semantics. `NullStore` when
  `-Dwith_lmdb=false`.
- **Components** (`src/components/*.zig`): one per Moonraker component; each reads its
  `vendor/moonraker/moonraker/components/*.py` for exact shapes.

### Tooling
- `tools/api_scanner/` — ast-based scanner of the vendored Moonraker source. Modes:
  `scan`, `baseline` (writes `api/api_surface.json`), `diff` (drift gate, exit 1 on
  change when `vendor/moonraker` is bumped), `coverage` (phobos vs baseline). 67 pytest
  tests (`uv run --with pytest python -m pytest tools/api_scanner/tests -q`).
- `vendor/moonraker` is gitignored (reproduce: `git clone --depth 50
  https://github.com/Arksine/moonraker vendor/moonraker`, commit pinned `9008485`).

---

## 3. What is DONE

- Full spine: io/listener, serialized core, JSON-RPC dispatcher, HTTP + WS transports,
  config parser, lmdb datastore, notification bus.
- All ~24 components registered, **100% method/endpoint/notification surface coverage**.
- Authorization with **byte-exact PBKDF2-HMAC-SHA256 + EdDSA JWT parity** (tokens/hashes
  interchangeable with Moonraker).
- file_manager with lexical path-escape safety (fuzzed).
- machine.* with real `/proc` + `/sys` parsers (fuzzed).
- API drift scanner + coverage gate.
- Notification emission verified for: power, file_manager, update_manager, spoolman
  (P0 deadlock fixed), job_queue, **history** (notify_history_changed on delete_job),
  **announcements** (notify_announcement_dismissed on dismiss; update+wake helpers
  ready), **webcam** (notify_webcams_changed on POST/DELETE; helpers + setIo plumbed).

---

## 4. REMAINING WORK (prioritized)

### P0 — webcam notification unit tests (known deadlock, deferred)
`src/components/webcam.zig` has `emitWebcamsChanged` helper + `setIo` plumbed, and
socket-level tests (`testutil/ws_client.zig`) verify notification delivery over real
sockets. Two unit tests doing `core.run(io, handler, ...)` → handler → `emitLocked`
→ `fanout` → `connections.mutex.lockUncancelable(io)` are skipped (`SkipZigTest`).
Root cause: nested `Io.Mutex.lockUncancelable` calls from the main test thread (not a
`Threaded` pool thread) deadlock. Production is unaffected — handlers run on pool
threads. Fixing this requires either a pool-thread test harness or removing the unit
tests. The socket-level tests in `ws_client.zig` already cover notification emission
end-to-end, so these two unit tests are intentionally skipped.

### P0 — Klippy Unix-socket bridge
`printer.*` returns the exact 503 "Klippy Host not connected" shape. No Unix-socket
bridge to a real Klippy yet (`/klippysocket` accepts then closes 1001). Implementing
the Klippy bridge unlocks `printer.*`, live `notify_status_update`, temperature/gcode
stores with real data, history job tracking, job_queue dispatch. This is the largest
remaining subsystem gap.

**Skeleton in place** (`src/components/klippy_connection.zig`, ~1200 lines, 37 tests):
`\x03`-delimited JSON-RPC framing (`frameEncode`/`frameDecode`), JSON-RPC request builders
(`buildJsonRpcRequest`, `buildIdentifyRequest`, `buildSubscribeRequest`,
`buildRegisterMethodRequest`, `buildSubscribeGcodeRequest`), response parsers
(`parseKlippyInfoResponse`, `getJsonRpcError`, `isNotification`), `ReadBuf` struct
(heap-allocated 20 MiB buffer with `append`/`consume`/`reset`), `KlippyCtx` struct with
`State` enum (disconnected→connecting→startup→ready→shutdown), `init`/`deinit`/`setIo`/
`isConnected`/`nextReqId`/`setState`, `request()` method (sends JSON-RPC over UDS,
reads response, dispatches inline notifications), `readLoop`/`dispatchFrame`/
`dispatchNotification`/`processStatusUpdate`/`processGcodeResponse` (full notification
pipeline with emitLocked for handler paths), `readFrame`/`writeFrame` (\x03 framing I/O).
Tests: 7 framing + 7 builders + 9 parsing + 6 ReadBuf + 3 setState + 3 lifecycle + 2 fuzz = 37 tests, all green.

**printer.* handlers wired** (`src/components/printer.zig`): all 6 handlers
(print/start, print/pause, print/resume, print/cancel, restart, firmware_restart)
now accept a `KlippyCtx` pointer, check `isConnected()`, and proxy to Klippy via
`k.request()` when connected. They build the exact gcode/script params (e.g.,
`SDCARD_PRINT_FILE FILENAME="..."`, `RESTART`, `FIRMWARE_RESTART`) matching Moonraker's
`klippy_apis.py`. When disconnected, they return `error.KlippyDisconnected` (503).

**Still needed:**
- ~~Unix socket connection~~ Done: `net.UnixAddress.init(path).connect(io)`.
- ~~JSON-RPC handshake: `server.connection.identify` → wait for `identify_response`,
  then `server.info` → poll until `state != "startup"`~~ Done: `connectAndHandshake`,
  `pollServerInfo` with 250ms polling up to 100×.
- ~~`printer.objects.subscribe`~~ Done: subscribes in connectAndHandshake.
- ~~`notify_klippy_ready` / `notify_klippy_disconnected` / `notify_klippy_shutdown`~~
  Done: emitReady/emitDisconnected/emitShutdown helpers call `bus.emit()`.
- ~~`server.info` dynamic updates: `klippy_connected`/`klippy_state`~~
  Done: ServerInfo fields updated by KlippyCtx.setState(); buildServerInfo reads them.
- ~~Background task spawns from `main()` (not `httpServer()`) so tests don't crash.~~
  Done: `server_app.klippy_ctx.start()` called in main.zig after httpServer.
- `_process_status_update`: parse status dict, emit `notify_status_update`, update
  `job_queue` live state, record history job entries (skeleton emits, deep parsing TBD)
- `_process_gcode_response`: relay gcode responses to pending request futures
- `/klippysocket` WebSocket proxy: accept WS, relay frames to/from Klippy UDS
- `job_queue` print dispatch (start/pause/resume/cancel gcodes)
- `history` live job tracking from status updates

### P1 — the conformance oracle (the real parity proof)
100% *surface* coverage ≠ byte-identical *behavior*. Build the golden-capture oracle
(spec §8/§8a): boot stock Moonraker **without Klippy**, capture HTTP/WS/JSON-RPC
responses + notification streams for a scripted request sequence, replay against phobos,
and assert **normalized**-equality (mask volatile fields: `connection_id`/`websocket_id`
= object identity, version strings, paths, component ordering — see the §8a manifest).
This is the capstone that turns "shapes look right" into "provably identical." It will
surface real per-endpoint shape diffs to fix.

### P2 — subsystem depth (currently faithful shapes, stubbed internals)
- **Klippy connection** — see P0 above.
- **machine** reboot/shutdown/services/sudo — acks only (no real systemctl/reboot).
- **update_manager** — acks + faithful `notify_update_response`; no real git/pip/apt.
- **power/wled/td1** — state tracked, real GPIO/network/WLED control stubbed.
- **mqtt** — endpoints return "not configured"; no MQTT client.
- **spoolman/announcements** — operate on stored data; no real spoolman HTTP / RSS fetch.
- **file_manager metadata** — record shape correct; deep gcode parsing (slicer/layers/
  thumbnails) partial.
- **LDAP** auth source omitted (moonraker-source-only scope).
- **sensor** — `notify_sensor_update` deferred (SensorCtx empty struct; only relevant
  when MQTT/Klippy sensor integration lands).

### P2 — misc
- ~~Read host/port from config in `main()`.~~ Done: `-c`/`--config`, `extractBindAddr`, 5 tests.
- Re-enable the lmdb drop-in test by shipping/locating a real Moonraker `data.mdb`
  fixture (currently `SkipZigTest`).
- Memory baseline: measure RSS of running phobos daemon vs stock Moonraker.

---

## 5. Suggested order for the next agent

1. ~~Plumb peer IP into the auth hook.~~ Done.
2. ~~Socket-level notify regression tests.~~ Done.
3. ~~Wire `main()` serve path.~~ Done (binds 127.0.0.1:7125, `listener.serveWith()`,
   `-c`/`--config` CLI flag, `extractBindAddr` with 5 tests, `--dump-api`).
4. ~~Klippy bridge skeleton.~~ Done: framing, KlippyCtx struct, 12 tests green.
5. ~~Klippy Unix-socket connection~~ (P0) — Done: connect, identify, subscribe handshake,
   background reconnect task, `server.info` dynamic klippy state, printer.* proxy.
   Remaining: `/klippysocket` WS proxy, deep `_process_status_update`, `_process_gcode_response`,
   `job_queue` dispatch, `history` live tracking.
6. **Fix webcam notification unit tests** (P0) — rewrite to avoid Core-lock
   re-entrancy, or remove (socket-level tests already cover this path).
7. **Conformance oracle** (P1) — golden-capture boot, replay, normalized-equality
   asserts. Capstone parity proof.
8. **P2 cleanup** — memory baseline (RSS vs stock Moonraker), re-enable lmdb drop-in
   test, subsystem depth (machine reboot/shutdown, update_manager git/pip/apt,
   power/wled/td1 GPIO, mqtt, spoolman HTTP, file_manager gcode parsing).

Keep the coverage gate at 100% and the full suite green after every step.
