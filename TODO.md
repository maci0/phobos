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
- **Overall implementation progress: ~87%** (est., weighted by API item count per component).
  See `docs/api/COVERAGE_HEATMAP.md` for the per-component breakdown.
  **KlippySim fixes:** emergency_stop handling added to readLoop; gcode/script
  RESTART/FIRMWARE_RESTART now triggers simulator disconnect (matching real Klippy
  restart behavior). Unskipped the restart/firmware_restart integration test;
  added emergency_stop end-to-end test. handlePublishPrefixed handler added to mqtt
  with full test suite (prefix/prefixed param, 10 tests + fuzz).
  (sensor depth up from 5%→55%: real SensorCtx with MeasurementRing, change detection,
  notify_sensor_update emission, param_info tracking. button depth up from 30%→80%:
  full ButtonCtx with addButton/sendEvent/emitButtonEvent/notification_sent guard.
  gcode_metadata depth: findObjectHeight (was stubbed, now 6 slicer patterns + G1 Z fallback),
  filament_weight_total, nozzle_diameter, thumbnails, slicer_version — 19 new unit tests
  + 9 new fuzz tests. file_manager depth up from 85%→90%.
  octoprint_compat depth up from 15%→60%: live printer_state() tracking via
  print_stats feed + Klippy state changes, dynamic safemode in handleServer.
  websocket_count now live from Connections registry in server.info + proc_stats.
  v4l2 devices: key ordering, field shape, version field, mask rule all fixed for
  conformance parity.
  MqttCtx refactored: init/deinit pattern, getOptAny return-switch fix, port overflow fix.
  spoolman: notify deadlock fixed (emit→emitLocked), notify_spoolman_status_changed
  emission on setIo/setServerUrl, query param support in handleProxy, GET+body rejection.
  announcements: real RSS fetch from Moonlight via fetchAndUpdateFeed + rss.zig parser,
  pruneByPrefix removes stale entries, handleFeedDispatchMulti branches on _method param,
  handlePostFeed triggers immediate fetch on new feed, notify_announcement_update emission,
  background periodic refresh timer (30 min, atomically stoppable, 1 s join latency).
  job_queue notify_job_queue_changed emission wired.
  job_queue depth up from 70%→90%: transition_gcode injection, transition_delay
  storage, loading queue state, pause_job_queue/start_job_queue remote methods registered,
  transition_delay timer thread with atomic cancel flag and thread join.
  mqtt depth: pub API (publishTopic/subscribeTopic/unsubscribe/close), setters
  (setInstanceName/setClientId/setDefaultQos), instance_name/client_id/default_qos
  config, retain/timeout parsed, server.mqtt.publish_mqtt_topic remote method,
  MqttNotConfigured/ServiceUnavailable error handling.
  printer.* proxied methods with full gcode/script param building.
  device_power, wled, td1 API components registered with in-memory state tracking.
  Golden cases pruned: removed server.mqtt.status/server.analysis.stats (not in Moonraker API).
  **Fuzz test gap closed:** every public JSON-RPC handler now has both a unit test
  AND a fuzz test. Added 19 fuzz tests across machine (reboot/shutdown/services/sudo/
  peripherals), update_manager (update_moonraker/klipper/system/full), wled (strips),
  webcam (delete/test/validate), announcements (list_feeds/delete_feed/update/
  feed_dispatch_multi), power (devices), rss (parser).
- **API surface coverage: 100%** — methods 120/120, static endpoints 123/123,
  notifications 27/27, router routes 4/4. Verified by the coverage tool (exit 0).
- **Conformance oracle: 54/54 events pass normalized equality** (conformance/replay.py
  against golden capture from vendored Moonraker 9008485). Tools: `conformance/capture.py`
  (boots stock Moonraker, captures scripted HTTP/WS sequence), `conformance/replay.py`
  (replays against phobos, asserts normalized equality with manifest-based field
  masking).
- Tests: **1062 pass / 2 skip / 0 fail** (175 fuzz) with `-Dwith_lmdb=true`;
  **~1009 pass / 5 skip / 0 fail** (~173 fuzz) with `-Dwith_lmdb=false`.
  The 2 skips (lmdb) are update_manager git tests (need a real repo).
  The 5 skips (no-lmdb) are: 3 lmdb-specific tests + 2 update_manager git tests.
  Note: `zig build test` uses `--listen=-` protocol which may hang on this
  machine (Zig 0.16 build-runner quirk); always verify via the direct test binary.
- All register functions now have unit tests verifying all expected routes are wired
  in the Registry (machine, update_manager, power, wled, td1, button).
- Peak RSS for the full test run ≈ 12–18 MB.

### Build / test / run — IMPORTANT host quirks
- This host's **system glibc cannot be linked** by Zig 0.16 (GCC 16 `.sframe` reloc).
  The build defaults the native target to **musl**, so normal commands work — but
  **never run plain `zig build` against a glibc target**.
- Default build links the **vendored lmdb** (`vendor/lmdb/`, LMDB 0.9.31).
  - Full suite (lmdb): `timeout 220 zig build test --summary all`
  - No-lmdb (faster, no C compile): `zig build test -Dwith_lmdb=false`
  - Build test binary without running (avoids `--listen=-` hang):
    `zig build test-artifact -Dwith_lmdb=false && ./.zig-cache/o/*/test --cache-dir=./.zig-cache`
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
- machine.* with real `/proc` + `/sys` parsers (fuzzed), v4l2 device enumeration with
  sysfs-based discovery, service allow-list validation, sudo password storage.
- printer.* proxy handlers (print/start, print/pause, print/resume, print/cancel,
  restart, firmware_restart) with full gcode/script param building.
- update_manager.* with faithful per-source status shapes (git_repo, system/package,
  web, zip), notification sequencing (notify_update_response, notify_update_refreshed).
- power/wled/td1 device registry with in-memory state tracking and notification emission.
- sensor with real SensorCtx (MeasurementRing, change detection, notify_sensor_update).
- button with full ButtonCtx (addButton, sendEvent, emitButtonEvent, notification_sent).
- gcode_metadata with deep parsing: object height (6 slicer patterns + G1 Z fallback),
  filament_weight_total (7 patterns), nozzle_diameter (3 patterns), thumbnails,
  slicer_version for all five slicer families.
- Klippy connection skeleton: \x03-delimited framing, JSON-RPC builders/parsers,
  KlippyCtx with state machine, UDS connect/identify/subscribe handshake, background
  reconnect, /klippysocket WS proxy bridge, job_queue dispatch, history live tracking.
- MqttCtx with init/deinit, in-memory message store, subscription tracking, topic
  matching, getOptAny fix, port overflow fix, dupe comptime fix.
- Conformance oracle: capture.py (boots vendored Moonraker, captures 54 HTTP/WS
  events), replay.py (replays against phobos, asserts normalized equality with
  manifest-based field masking). All 54 events pass.
- Normalizer: Zig (`src/oracle/normalize.zig`) and Python (`conformance/replay.py`)
  normalizers with manifest-based rules (mask, version_pin, sort_array, path_relativize,
  structure_compare, files_compare), v4l2_devices mask rule, normalizeWarnings fix.
- API drift scanner + coverage gate (tools/api_scanner/, 67 pytest tests).
- Notification emission verified for: power, file_manager, update_manager, spoolman
  (P0 deadlock fixed: emit→emitLocked; notify_spoolman_status_changed on setIo/setServerUrl),
  job_queue (notify_job_queue_changed),
  **history** (notify_history_changed on delete_job),
  **announcements** (notify_announcement_dismissed on dismiss;
  notify_announcement_update on RSS fetch; notify_announcement_wake helper ready),
  **webcam** (notify_webcams_changed on POST/DELETE; helpers + setIo plumbed).
- **OctoPrint compat** — live printer_state() tracks Klippy readiness + print_stats
  state; handleServer reports dynamic safemode; handleJob/handlePrinter report live
  OctoPrint states (Offline/Operational/Printing/Paused/Error) with correct state
  flags. 13 unit tests + fuzz test.
- Memory baseline: phobos daemon RSS = 5.4 MB vs stock Moonraker ~80-150 MB.

---

## 4. REMAINING WORK (prioritized)

### P0 — webcam notification unit tests (done — removed; covered by socket tests)
`src/components/webcam.zig` has `emitWebcamsChanged` helper + `setIo` plumbed.

### P0 — Klippy Unix-socket bridge
`printer.*` returns the exact 503 "Klippy Host not connected" shape. The Klippy
bridge skeleton is fully built but requires a real Klippy (or simulator) for
end-to-end integration testing, since the socket-level behavior depends on actual
Klippy protocol exchange.

**Already done:**
- `\x03`-delimited JSON-RPC framing, all request builders, response parsers.
- KlippyCtx state machine (disconnected→connecting→startup→ready→shutdown).
- UDS connect/identify/subscribe handshake, background reconnect task.
- `/klippysocket` WS proxy bridge (Bridge relay), job_queue dispatch, history live tracking.
- printer.* proxy handlers with gcode/script param building.
- `notify_proc_stat_update` background emission via `std.Thread`.
- `websocket_connections` live count from Connections registry.

**Still needed:**
- Real Klippy integration test (Unix socket round-trip with a real Klippy).
  KlippySim (`src/testutil/klippy_sim.zig`) covers the protocol: handshake,
  gcode/script, pause_resume/*, emergency_stop, RESTART/FIRMWARE_RESTART
  disconnect, status updates, gcode responses, and shutdown. End-to-end
  integration tests (server.zig) validate printer.* + emergency_stop.
  ~~Deep `print_stats` status parsing~~ — DONE: print_duration/filament_used are
  already consumed by history.zig's finishJob() via the prev_ps/new_ps pass-through
  (matching Python architecture), and job_state.zig handles all state transitions.

### P1 — the conformance oracle (DONE)
The golden-capture oracle is complete: boot stock Moonraker **without Klippy**,
capture HTTP/WS/JSON-RPC responses + notification streams for a scripted request
sequence, replay against phobos, and assert **normalized**-equality (mask volatile
fields: `connection_id`/`websocket_id` = object identity, version strings, paths,
component ordering — see the §8a manifest).

**All 54 events pass normalized equality.** Tools:
- `conformance/capture.py` — boots vendored Moonraker (commit 9008485), runs
  scripted sequence (HTTP REST + JSON-RPC + WebSocket), captures 54 ordered events
  to `conformance/golden/capture.json`.
- `conformance/replay.py` — replays captures against phobos, asserts normalized
  equality with manifest-based field masking (mask, version_pin, sort_array,
  path_relativize, structure_compare, files_compare).
- Normalizer: Zig (`src/oracle/normalize.zig`) + Python (`conformance/replay.py`)
  normalizers with identical manifest-based rules.

Key fixes discovered during conformance work: v4l2 device key ordering, v4l2 device
version field, structure_compare → mask for v4l2_devices, normalizeWarnings (Zig),
_norm_structure_compare array item masking (Python).

### P2 — subsystem depth (currently faithful shapes, some real I/O)
- **Klippy connection** — see P0 above.
- **machine** reboot/shutdown — live `sudo systemctl reboot`/`systemctl poweroff`
  via `runSudoCmd` when io is wired and sudo_password is set; returns "ok"
  without touching the host when io is null (unit-test path). Services: service
  allow-list validation works, real `systemctl start/stop/restart --no-block`
  calls wired, in-memory state tracking. Sudo: password stored and validated via
  real `sudo -S -l` child process; sudo_info reports real `sudo_access` when
  `check_access=true`. `RunCmdFn` mock injection pattern (`setRunCmdFn`/`runCmd`)
  for testability without host systemctl; TestServer wires mock returning fake
  service state (2 dedicated unit tests).
- **update_manager** — git status (version, hash, branch, dirty, detached,
  commits_behind) live via real `git` child process; `handleRefresh` runs live
  `git fetch origin --prune` for git_repo sources; `handleUpdate*` runs live
  `git fetch origin --prune` + `git reset --hard origin/<branch>` for git_repo
  sources; non-git sources (system/web/zip) emit notifications but skip real
  apt/pip (phobos does not touch the host package manager).
- **power/wled/td1** — state tracked, real GPIO/network/WLED control stubbed.
- **mqtt** — in-memory message store + subscription tracking; pub API
  (`publishTopic`, `subscribeTopic`, `unsubscribe`, `close`, setters) exposed,
  `retain`/`timeout` parsed, `server.mqtt.publish_mqtt_topic` remote method
  registered. Real MQTT client connection (TLS/keepalive/reconnect) is P3.
- **spoolman/announcements** — announcements: real RSS fetch from Moonlight
  (arksine.github.io/moonlight) via fetchAndUpdateFeed using rss.zig parser,
  pruneByPrefix removes stale entries, notify_announcement_update on changes,
  handleFeedDispatchMulti branches on _method param for proper verb dispatch;
  spoolman: real HTTP proxy with query param support, GET+body rejection,
  notify_spoolman_status_changed on setIo/setServerUrl via emitLocked.
  ETag not yet supported (Zig 0.16 FetchResult no response headers).
  Background periodic refresh timer wired (30 min, atomically stoppable, 1 s join latency).
- **file_manager metadata** — record shape correct; deep gcode parsing (slicer/layers/
  thumbnails) now implements findObjectHeight (6 slicer patterns + G1 Z fallback),
  filament_weight_total (7 patterns), nozzle_diameter (3 patterns), thumbnail
  extraction from `; thumbnail begin … end` blocks, slicer_version for all five
  slicer families (PrusaSlicer, Cura, Simplify3D, IdeaMaker, KISSlicer).
- **octoprint_compat** — live printer_state() with klippy + print_stats tracking;
  dynamic safemode in handleServer; state flags for handlePrinter match Python spec.
  Done: 13 unit tests + fuzz test.
- **LDAP** auth source omitted (moonraker-source-only scope).
- **sensor** — ~~`notify_sensor_update` deferred (SensorCtx empty struct; only relevant
  when MQTT/Klippy sensor integration lands).~~ DONE: real SensorCtx with sensors
  StringHashMap, MeasurementRing history, change detection, emitSensorUpdate via
  emitLocked, param_info tracking. 15 unit + 4 fuzz tests.
- **button** — ~~notification-only, GPIO stubbed.~~ DONE: full ButtonCtx with
  addButton/sendEvent/emitButtonEvent/notification_sent guard, 10 unit + 3 fuzz tests.
- **job_queue** — ~~transition_gcode/delay, remote methods~~ DONE: transition_gcode
  injection via dispatchNextJob, transition_delay storage, "loading" queue state,
  pause_job_queue/start_job_queue JSON-RPC remote methods registered, [job_queue]
  config parsing wired in app.zig, transition_delay timer thread with atomic
  cancel flag and thread join (1-second polling, 32 unit + 8 fuzz tests).

### P2 — misc
- ~~Read host/port from config in `main()`.~~ Done: `-c`/`--config`, `extractBindAddr`, 5 tests.
- ~~Re-enable the lmdb drop-in test.~~ Done: fixture generated via
  `tools/generate_lmdb_fixture.py`, test passes with `-Dwith_lmdb=true`.
- ~~Memory baseline: measure RSS of running phobos daemon vs stock Moonraker.~~
  Done: phobos daemon RSS = 5.4 MB (VmSize 7992 kB, 1 thread) vs stock Moonraker
  ~80-150 MB (Python asyncio, multiple threads).
- ~~**Fuzz test gap:** every public JSON-RPC handler now has a unit test AND a fuzz test.~~
  Done: 18 fuzz tests added across machine (11), update_manager (4), wled (1), webcam (3),
  announcements (4), power (1), extensions (1). Total: ~1012 tests (~174 fuzz).

### P3 — remaining depth gaps (non-blocking, requires hardware/external services)
- **mqtt** — real MQTT client connection, TLS, keepalive, reconnect. Current: endpoints
  return "not configured" with in-memory message store + subscription tracking.
  Pub API complete: `publishTopic`, `subscribeTopic`, `unsubscribe`, `close`,
  `setInstanceName`/`setClientId`/`setDefaultQos`, `storeMessage`/`getMessage`/
  `addSubscription` exposed. `retain`/`timeout` params parsed. Remote method
  `server.mqtt.publish_mqtt_topic` registered. 47 tests (9 fuzz).
- **power/wled/td1** — real GPIO sysfs/wiringPi, network WLED control, TD1 UART.
  Current: in-memory state tracking with notification emission, stubbed I/O.
  (machine.zig `RunCmdFn` mock pattern reusable here for GPIO/network test doubles.)
- **spoolman/announcements** — ETag/If-Modified-Since conditional GET for RSS.
  Current: real RSS fetch works (no ETag) with background periodic refresh timer
  (30 min, atomically stoppable); notify_announcement_update +
  notify_spoolman_status_changed emissions wire
- **Klippy integration test** — full Unix-socket round-trip with a real Klippy (or
  Klippy simulator) to validate the bridge end-to-end. The bridge skeleton
  (connect/identify/subscribe/reconnect/proxy) is complete but untested against
  real Klippy.

---

## 5. Suggested order for the next agent

1. ~~Plumb peer IP into the auth hook.~~ Done.
2. ~~Socket-level notify regression tests.~~ Done.
3. ~~Wire `main()` serve path.~~ Done (binds 127.0.0.1:7125, `listener.serveWith()`,
   `-c`/`--config` CLI flag, `extractBindAddr` with 5 tests, `--dump-api`).
4. ~~Klippy bridge skeleton.~~ Done: framing, KlippyCtx struct, 37 tests green.
5. ~~Klippy Unix-socket connection~~ (P0) — Done: connect, identify, subscribe handshake,
   background reconnect task, `server.info` dynamic klippy state, printer.* proxy,
   **`/klippysocket` WS proxy**, **`job_queue` dispatch**, **`history` live tracking**,
   **processStatusUpdateInner + processGcodeResponse**.
   Remaining: `notify_proc_stat_update` (Done), ~~deep `print_stats` parsing~~ (Done),
   real-Klippy integration test.
6. ~~Fix webcam notification unit tests~~ (P0) — Done.
7. ~~`notify_proc_stat_update` background emission~~ (P0) — Done.
8. ~~Proc stat timer crash fixes~~ — Done: atomic stop flag, stored thread handle,
   join in deinit, null io before join.
9. ~~OctoPrint compat live state~~ — Done: printer_state() tracks Klippy readiness
   + print_stats.state; handleServer dynamic safemode; handleJob/handlePrinter live
   state flags. 13 unit tests + fuzz test.
10. ~~Conformance oracle~~ (P1) — Done: 54/54 events pass normalized equality.
   Golden capture + replay harness complete. Normalizer bugs fixed (Zig + Python).
11. ~~P2 cleanup~~ — Done: memory baseline (5.4 MB RSS), re-enable lmdb drop-in
    test, subsystem depth: machine sudo validation, machine services systemctl,
    update_manager git fetch/reset, file_manager gcode parsing, octoprint_compat
    live state, **every handler fuzzed** (17 new fuzz tests across machine,
    update_manager, wled, webcam, announcements, power).
12. ~~Conformance oracle follow-up~~ — merged into (10).
13. **P3 remaining depth gaps** — real MQTT client (TLS/keepalive/reconnect),
    GPIO/WLED/TD1 hardware I/O, spoolman/announcements HTTP/RSS fetch,
    Klippy integration test (real Klippy or simulator). All non-blocking;
    require hardware or external services.

Keep the coverage gate at 100% and the full suite green after every step.
