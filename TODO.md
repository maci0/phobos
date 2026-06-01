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
- Tests: **582 pass / 1 skip** (with lmdb), **568 pass / 3 skip** (no-lmdb). The skips
  are lmdb-only drop-in tests that need a real Moonraker `data.mdb` asset.
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
  (P0 deadlock fixed), job_queue.

---

## 4. REMAINING WORK (prioritized)

### P0 / correctness — finish notification emission (and its hard lesson)
The audit found that handlers run **under the Core lock**, so emitting a notification
must use **`NotifyBus.emitLocked`**, never `emit` (which re-locks the non-reentrant
mutex → deadlock). spoolman's was fixed (`emit`→`emitLocked`); job_queue now emits.

**Still NOT emitting (silent parity gaps) — re-add emission via `emitLocked`:**
- `src/components/webcam.zig` — `notify_webcams_changed` on POST/DELETE of a webcam
  (`vendor/.../webcam.py` `_notify_webcams`, payload `{webcams:[...]}`).
- `src/components/history.zig` — `notify_history_changed` (`{action, job}`) on
  delete_job (job start/finish needs Klippy → documented no-op).
- `src/components/announcements.zig` — `notify_announcement_update` (`{entries:[...]}`),
  `notify_announcement_dismissed` (`{entry_id}`), `notify_announcement_wake`.
- `src/components/sensor.zig` — `notify_sensor_update` (when sensors exist).

Pattern: copy `src/components/power.zig` (an `io: ?std.Io` field + `setIo`, emit via
`const io = ctx.io orelse return; bus.emitLocked(io, notify.names.X, .{.array = arr})`),
and add the `setIo` call in `src/app.zig::httpServer()`.

**WARNING (this caused a hang that was reverted):** a previous attempt added unit tests
that did `core.lock(io); ctx.emit...(); core.unlock(io);` — these **deadlock** because
the emit path's `Connections.add`/`nextId` (and other paths) take the Core lock. Do NOT
hold the Core lock in a unit test while calling code that re-enters it. Test the emit
helpers either (a) without holding the Core lock, or (b) via the real socket path below.
The reverted work (with the buggy tests) is recoverable from reflog if useful, but
re-implement the tests correctly rather than restoring them verbatim.

### P0 — socket-level notification regression tests
There is currently **no test that drives a real emitting handler over a socket** and
asserts the notification arrives. This is exactly the gap that hid the spoolman
deadlock. Add tests (TestServer + `src/testutil/ws_client.zig`): connect a WS client,
issue a real request to an emitting handler (POST spool_id, a power on, a webcam POST,
a job_queue mutation), and assert the `notify_*` frame arrives with the correct shape —
with a bounded wait so a regression fails fast instead of hanging.

### P1 — trusted-client peer IP
`authorization.zig` implements trusted-client IP/CIDR matching, but the accept path
(`src/io.zig` / `http_transport.zig`) does not yet surface the socket **peer IP** to the
auth hook (it uses a `trust_unknown_ip` fallback). Plumb `getpeername` from the accepted
`std.Io.net` stream through to `authenticateRequest`.

### P1 — the conformance oracle (the real parity proof)
100% *surface* coverage ≠ byte-identical *behavior*. Build the golden-capture oracle
(spec §8/§8a): boot stock Moonraker **without Klippy**, capture HTTP/WS/JSON-RPC
responses + notification streams for a scripted request sequence, replay against phobos,
and assert **normalized**-equality (mask volatile fields: `connection_id`/`websocket_id`
= object identity, version strings, paths, component ordering — see the §8a manifest).
This is the capstone that turns "shapes look right" into "provably identical." It will
surface real per-endpoint shape diffs to fix.

### P2 — subsystem depth (currently faithful shapes, stubbed internals)
These return Moonraker-correct shapes but stub the underlying subsystem (documented in
each file). Real behavior needs the subsystem:
- **Klippy connection**: `printer.*` return the exact 503 "Klippy Host not connected".
  No Unix-socket bridge to a real Klippy yet (`/klippysocket` accepts then closes 1001).
  Implementing the Klippy bridge unlocks `printer.*`, live `notify_status_update`,
  temperature/gcode stores with real data, history job tracking, job_queue dispatch.
- **machine** reboot/shutdown/services/sudo — acks only (no real systemctl/reboot).
- **update_manager** — acks + faithful `notify_update_response`; no real git/pip/apt.
- **power/wled/td1** — state tracked, real GPIO/network/WLED control stubbed.
- **mqtt** — endpoints return "not configured"; no MQTT client.
- **spoolman/announcements** — operate on stored data; no real spoolman HTTP / RSS fetch.
- **file_manager metadata** — record shape correct; deep gcode parsing (slicer/layers/
  thumbnails) partial.
- **LDAP** auth source omitted (moonraker-source-only scope).

### P2 — misc
- Re-enable the lmdb drop-in test by shipping/locating a real Moonraker `data.mdb`
  fixture (currently `SkipZigTest`).
- `main()` is `--dump-api` + version only; wire a real `serve` path (bind from config,
  run the App listener) for an actual running daemon, then measure real RSS vs stock
  Moonraker (`docs/MEMORY_BASELINE.md`, not yet written — plan Task 12).

---

## 5. Suggested order for the next agent
1. Re-add webcam/history/announcements/sensor notification emission via `emitLocked`
   (NOT under Core lock in tests). Green both build modes.
2. Add socket-level notify regression tests (bounded wait).
3. Plumb peer IP into the auth hook.
4. Wire `main()` serve path; record the memory baseline.
5. Build the conformance oracle; fix whatever shape diffs it surfaces.
6. (Large) Implement the Klippy Unix-socket bridge → unlocks `printer.*` and live status.

Keep the coverage gate at 100% and the full suite green after every step.
