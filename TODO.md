# phobos — Status & Handoff TODO

phobos is a memory-efficient **Zig 0.17** reimplementation of **Moonraker** (Klipper's
API server) intended to behave 100% identically. Target: ARM **Cortex-A7** (32-bit),
static musl binary.

This file is the single source of truth for "what's done / what's left." Read it,
then `docs/superpowers/specs/2026-06-01-phobos-server-spine-design.md` (design) and
`docs/superpowers/plans/2026-06-01-phobos-server-spine.md` (plan).

---

## 1. Snapshot (current state)

- Branch: **`main`**. Tree is clean and green at HEAD.
- **Overall implementation progress: ~99%** (est., weighted by API item count per component).
  See `docs/api/COVERAGE_HEATMAP.md` for the per-component breakdown and
  `docs/api/API_COVERAGE.md` for the authoritative per-call status + Moonraker
  deltas. Memory footprint: `docs/MEMORY.md` (~3.7 MB idle RSS, 1.2 MB binary).
  > NOTE: the "Recent depth improvements" log below is **historical** — many
  > components have advanced well past the percentages quoted in it (e.g. power,
  > sensor, mqtt, machine are all done now; MQTT TLS+reconnect, Spoolman WS, TD-1
  > discovery, the sensor Jinja engine, and machine init-system providers all
  > landed). Trust `API_COVERAGE.md` / the heatmap for current status, not this log.
  **Recent depth improvements (historical log):**
  wled depth up from 70%→80%: real HTTP POST to WLED JSON API for address-based
  strips via std.http.Client; sendWledBody, wledOn/wledOff/wledControl/setWled
  fully implemented with chain_data color management.
  mqtt depth up from 75%→80%: status_cache with sub-field merge, timed
  status-flush background thread, moonraker_status publication on klippy state
  changes, connection state tracking (disconnected→connecting→connected→disconnecting),
  handlePublishPrefixed handler.
  machine depth up from 70%→75%: moonraker_stats 30-sample rolling ring buffer with
  thread-safe push/build functions.
  power: HTTP device URLs (on_url/off_url/status_url) parsed from config and stored
  in Device struct; real HTTP client not yet wired (stays at 50%).
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
  announcements: real RSS fetch from Moonlight (bounded, with Core released) + rss.zig parser,
  prefix pruning of stale entries, handleFeedDispatchMulti branches on _method param,
  handlePostFeed triggers immediate fetch on new feed, notify_announcement_update emission,
  background periodic refresh timer (30 min, atomically stoppable, 1 s join latency).
  job_queue notify_job_queue_changed emission wired.
  job_queue depth up from 70%→90%: transition_gcode injection, transition_delay
  storage, loading queue state, pause_job_queue/start_job_queue remote methods registered,
  transition_delay timer thread with atomic cancel flag and thread join.
  mqtt depth: pub API (publishTopic/subscribeTopic/unsubscribe/close), setters
  (setInstanceName/setClientId/setDefaultQos), instance_name/client_id/default_qos
  config, retain/timeout parsed, server.mqtt.publish_mqtt_topic remote method,
  MqttNotConfigured/ServiceUnavailable error handling, status caching with
  sub-field merge (sendStatus), status_objects filtering, timed status-flush
  background thread, moonraker_status publication on state change.
  printer.* proxied methods with full gcode/script param building.
  device_power, wled, td1 API components registered with in-memory state tracking.
  Golden cases pruned: removed server.mqtt.status/server.analysis.stats (not in Moonraker API).
  **Fuzz test gap closed:** every public JSON-RPC handler now has both a unit test
  AND a fuzz test. Added 19 fuzz tests across machine (reboot/shutdown/services/sudo/
  peripherals), update_manager (update_moonraker/klipper/system/full), wled (strips),
  webcam (delete/test/validate), announcements (list_feeds/delete_feed/update/
  feed_dispatch_multi), power (devices), rss (parser).
- **2026-10-19 live printer:** See [v0.1.1 release notes](docs/releases/v0.1.1.md) for verified fixes and retained identity/runtime differences. Public database access honors persisted namespace policies and hides auth records. Empty registered namespaces stay visible. OctoPrint uses live connection state and heater readings.
- **2026-10-19 Fluidd:** [v0.1.2](docs/releases/v0.1.2.md) fixes the ARM directory crash, extended listings, large-file metadata reads, and OrcaSlicer durations/layer counts. Verified with Fluidd on the real printer and deployed to 7125 after a database backup and explicit approval.
- **2026-10-19 temperature store:** The daemon samples cached Klippy readings at 1 Hz, rounds to two decimals, and preserves partial updates. Tests sample synchronously. `[data_store] temperature_store_size` caps each field at 1200 by default.
- **2026-10-19 announcements and gcode store:** `[announcements] subscriptions` are added to the feed list (built-ins stay). `dev_mode` skips the Moonlight fetch. `[data_store] gcode_store_size` caps the gcode ring and keeps the newest entries.
- **2026-10-19 qemu parity:** A missing database namespace is 404. Thumbnails without `filename` and a webcam get without `name` or `uid` are 400. HTTP on a websocket-only route is 404. WLED batch ignores the injected `_method` key. After the Klippy handshake, phobos queries `heaters` and subscribes `available_sensors` and `available_monitors`, then seeds `server.temperature_store`. Monitors stay hidden unless `include_monitors` is set. `server.info` `registered_directories` follows the live file roots. `machine.reboot` and `machine.shutdown` stay no-ops; the tests say not to implement them.
- **2026-10-19 remaining behavior:** Analysis status, process, and dump_config run through the injected estimator shell. A missing binary stays `EstimatorNotAvailable`. `[analysis]` records the platform binary under the datadir and does not download it. `[notifier <name>]` fills `server.notifiers.list`; the test endpoint still returns `AppriseNotAvailable`. `hidden_objects` are dropped from `objects/query` and `objects/subscribe` as well as `objects/list`. Recover and rollback run git only when `io` and `repo_path` are set: soft recover is checkout plus `reset --hard origin/<branch>`, hard recover is `reset --hard HEAD` plus `clean -fd`, and an empty rollback ref does not run git. There is no reclone and no service restart. `machine.reboot` and `machine.shutdown` stay no-ops. PanelDue `feedBytes` splits serial chunks on newlines and does not open a device. `klipper_path` registers read-only `config_examples` and `docs` roots when those directories exist.
- **2026-10-19 parity flags:** `enable_auto_refresh` false does not refresh. A due tick uses a hook in tests and does not spawn git. `file_system_observer: none` does not watch; `inotify` watches the roots. `excludes` drop `root/relative` paths from file listings. `hidden_objects` are removed from `objects/list`.
- **2026-10-19 machine provider:** Forge-X `[machine] provider: simple` runs `<script_path>/<service> <action>` through the command runner. `reboot` and `shutdown` stay no-ops. An empty `script_path` does not spawn. `systemctl` is not used for this provider.
- **2026-10-19 webcams:** `[webcam <name>]` sections load as `source: config` cameras (`stream_url` required). A second load of the same name does not overwrite. The uid is Moonraker's `uuid5(instance_uuid, "moonraker.webcam.<name>")`, and the instance uuid is `<datadir>/.moonraker.uuid`. The list keeps config order.
- **2026-10-19 printer gaps:** `[authorization] trusted_clients` (including `0.0.0.0/0`) is loaded into the auth table. `[update_manager]` `enable_system_updates: False` omits the system source. `[update_manager <name>]` git/web/zip clients show up in `machine.update.status`. `server.info` lists `update_manager` and `octoprint_compat`, and `feather_updates` when that section is present. Feather status/update/reset refuse unless Klippy is idle. They do not reboot the host. `register_remote_method` sends `response_template`, and an id-less Klippy frame reaches the handler. The daemon runner executes `git -C <repo>` for reset and `machine.update.client` through `handleUpdateClient`. Tests install a recorder and do not spawn git. `[server] klippy_uds_address` is applied.
- **2026-10-19 parity:** Update status restores the persisted cache without fetching; git status omits `repo_detected`. `[server] use_xheaders` (default on) is read in `setConfig` and copied by `httpServer`. When it is on, `X-Forwarded-For` / `X-Real-Ip` rewrite the client and the socket peer must be trusted; when it is off, the socket peer stays the client. `[paneldue]` lines enter through `App.processPanelDueLine`: the checksummed script is stripped, and file commands (`M23`/`M30`/`M32`/`M36`/`M37`/`M98`) keep one filename only when it is non-empty. Package commands are built for an injected shell; the default daemon runner rejects apt and pip. Web/zip installation remains unimplemented. `server.analysis.estimate` runs `klipper_estimator --config_file … estimate -f json` and returns `sequences[0]`; no binary is `EstimatorNotAvailable`. A configured notifier test is `AppriseNotAvailable` (apprise is not linked); an unknown name is 404.
- **API surface coverage: 100%** — methods 130/130, static endpoints 123/123,
  notifications 27/27, router routes 4/4. Verified by the coverage tool (exit 0).
- **Conformance oracle: 49/54 events pass normalized equality** (2026-10-20 run of conformance/replay.py
  against golden capture from vendored Moonraker 9008485). Failing: `server.info` x3 lists `update_manager` and `octoprint_compat`, which phobos always loads (`src/core/methods.zig:48`) and the capture config lacks; `machine.peripherals.usb` x2 compares host hardware (32 devices captured, 26 on this host). Tools: `conformance/capture.py`
  (boots stock Moonraker, captures scripted HTTP/WS sequence), `conformance/replay.py`
  (replays against phobos, asserts normalized equality with manifest-based field
  masking).
- Tests: **1435 pass / 1 skip / 0 fail**, with 246 fuzz tests discovered. The skip
  is the gated real-Klippy proxy test. Build with `zig build test-artifact` and run
  the newest standalone test binary to avoid the build runner's `--listen=-` hang.
- All register functions now have unit tests verifying all expected routes are wired
  in the Registry (machine, update_manager, power, wled, td1, button).

### Build / test / run — IMPORTANT host quirks
- This host's **system glibc cannot be linked** by Zig 0.16 (GCC 16 `.sframe` reloc).
  The build defaults the native target to **musl**, so normal commands work — but
  **never run plain `zig build` against a glibc target**.
- DataStore backend is selectable (`[database] backend`): vendored **SQLite** (default,
  `vendor/sqlite/`, moonraker-sql.db-compatible) or the pure-Zig atomic-rename file backend.
  - Full suite: `timeout 220 zig build test --summary all`
  - Build test binary without running (avoids `--listen=-` hang):
    `zig build test-artifact && ./.zig-cache/o/*/test --cache-dir=./.zig-cache`
  - Single non-`../`-importing file: `zig test -target x86_64-linux-musl src/<f>.zig`
    (files under `src/components`, `src/testutil` use `../` imports and only build via
    `zig build test`).
- Cross-compile (deploy): `zig build -Dtarget=arm-linux-musleabihf -Dcpu=cortex_a7 -Doptimize=ReleaseSmall`
  → static ARM binary.
- Dump the API phobos actually registers: `zig build && zig-out/bin/phobos --dump-api`
- **Coverage gate** (the "are we at 100%?" check):
  ```
  mkdir -p .scratch && zig build && zig-out/bin/phobos --dump-api > .scratch/api-dump.json
  PYTHONPATH=tools uv run --with tree-sitter --with tree-sitter-python python -m api_scanner coverage --baseline api/api_surface.json --phobos .scratch/api-dump.json
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

- **Runtime**: `std.Io.Threaded` thread-pool backend (the production default).
  One `std.Io` handle threaded through `App`; everything is coded against the
  abstract `std.Io` interface, so the backend is a single rebindable `aio` in
  `main()`.
  - **io_uring opt-in — BLOCKED on std (revisit on Zig bump).** Wired a `--io=uring`
    opt-in (≈20 lines in `main.zig`) but reverted: `std.Io.Evented`/`std.Io.Uring`
    is a **proof-of-concept in 0.16.0, lacking Networking + error handling + test
    coverage** (per the 0.16.0 release notes). It doesn't even compile —
    `Uring.openDir` returns `error.ReadOnlyFileSystem`, absent from `Dir.OpenError`
    (Uring.zig:2732); Zig's lazy analysis let it ship unchecked. Reproduces with a
    5-line standalone on musl+glibc. And it has no sockets, so it's a non-starter
    for a network server regardless. When the backend grows networking + compiles,
    re-add the opt-in (Threaded default, fall back if io_uring unavailable/disabled).
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
- **DataStore** (`src/store/`): `DataStore` interface + SQLite/atomic-rename-file backends with
  Moonraker's exact dotted-key + record-encoding semantics (always compiled).
- **Components** (`src/components/*.zig`): one per Moonraker component; each reads its
  `vendor/moonraker/moonraker/components/*.py` for exact shapes.

### Tooling
- `tools/api_scanner/` — tree-sitter-based scanner of the vendored Moonraker source. Modes:
  `scan`, `baseline` (writes `api/api_surface.json`), `diff` (drift gate, exit 1 on
  change when `vendor/moonraker` is bumped), `coverage` (phobos vs baseline). 72 pytest
  tests (`uv run --with pytest --with tree-sitter --with tree-sitter-python python -m pytest tools/api_scanner/tests -q`).
- `tools/client_api_scanner/` — multi-language (tree-sitter TS/Python/C++) scanner of every
  Moonraker RPC call Mainsail/Fluidd/KlipperScreen/GuppyScreen/HelixScreen make; builds the
  `docs/api/CLIENT_API_COVERAGE.md` matrix.
- `tools/perf_harness/` — vegeta load tests (phobos vs Moonraker) + perf/eBPF hotpath profiling.
- `vendor/moonraker` is gitignored (reproduce: `git clone --depth 50
  https://github.com/Arksine/moonraker vendor/moonraker`, commit pinned `9008485`).

---

## 3. What is DONE

- Full spine: io/listener, serialized core, JSON-RPC dispatcher, HTTP + WS transports,
  config parser, SQLite/file datastore, notification bus.
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
  matching, getOptAny fix, port overflow fix, dupe comptime fix, status caching with
  sub-field merge, status_objects filtering, timed flush thread, moonraker_status
  on state change.
- Conformance oracle: capture.py (boots vendored Moonraker, captures 54 HTTP/WS
  events), replay.py (replays against phobos, asserts normalized equality with
  manifest-based field masking). See the status line above for the current pass count.
- Normalizer: Python (`conformance/replay.py`) with manifest-based rules (mask,
  version_pin, sort_array, path_relativize, structure_compare, files_compare),
  v4l2_devices mask rule. `src/oracle/replay.zig` checks result keys and error codes in-process.
- API drift scanner + coverage gate (tools/api_scanner/, 67 pytest tests).
- Notification emission verified for: power, file_manager, update_manager, spoolman
  (P0 deadlock fixed: emit→emitLocked; notify_spoolman_status_changed on setIo/setServerUrl),
  job_queue (notify_job_queue_changed),
  **history** (notify_history_changed on delete_job),
  **announcements** (notify_announcement_dismissed on dismiss;
  notify_announcement_update on RSS fetch; notify_announcement_wake from the refresh worker),
  **webcam** (notify_webcams_changed on POST/DELETE; helpers + setIo plumbed).
- **OctoPrint compat** — live printer_state() tracks Klippy readiness + print_stats
  state; handleServer reports dynamic safemode; handleJob/handlePrinter report live
  OctoPrint states (Offline/Operational/Printing/Paused/Error) with correct state
  flags. 13 unit tests + fuzz test.
- Memory baseline: idle RSS ~1.2-2.2 MB by backend (file/SQLite), ReleaseSmall+LTO+
  stripped) vs stock Moonraker ~80-150 MB (~50-90x less). Binary ~1.2 MB.

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
- KlippyCtx state machine (Moonraker states: disconnected, startup, ready, error,
  shutdown); `shutdown`/`error` keep the connection.
- UDS connect/identify/subscribe handshake, background reconnect task.
- `/klippysocket` bridge on its own Klippy Unix connection per client, job_queue
  dispatch, history live tracking.
- printer.* proxy handlers with gcode/script param building.
- `notify_proc_stat_update` background emission via `std.Thread`.
- `websocket_connections` live count from Connections registry.

**Still needed:**
- ~~Real Klippy integration test (Unix socket round-trip with a real Klippy).~~
  DONE: a gated real-Klippy test (`.testenv/run-klippy.sh`) round-trips
  info/objects.list/objects.query against a live Klippy; it skips when
  `/tmp/klippy_uds` is absent.
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

**Pass count: see the conformance status line at the top of this file.** Tools:
- `conformance/capture.py` — boots vendored Moonraker (commit 9008485), runs
  scripted sequence (HTTP REST + JSON-RPC + WebSocket), captures 54 ordered events
  to `conformance/golden/capture.json`.
- `conformance/replay.py` — replays captures against phobos, asserts normalized
  equality with manifest-based field masking (mask, version_pin, sort_array,
  path_relativize, structure_compare, files_compare).
- Normalizer: manifest-based rules in `conformance/replay.py`. `src/oracle/replay.zig`
  checks Moonraker result keys and error codes through the App dispatcher.

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
  service state (2 dedicated unit tests). proc_stat: 30-sample rolling ring buffer
  for moonraker_stats with thread-safe push/build.
- **update_manager** — git status (version, hash, branch, dirty, detached,
  commits_behind) live via real `git` child process; `handleRefresh` runs live
  `git fetch origin --prune` for git_repo sources; `handleUpdate*` runs live
  `git fetch origin --prune` + `git reset --hard origin/<branch>` for git_repo
  sources; non-git sources (system/web/zip) emit notifications but skip real
  apt/pip (phobos does not touch the host package manager).
- **power/wled/td1** — power: state tracked, device URLs stored,
  real GPIO/network control stubbed. wled: real HTTP POST to WLED JSON API
  for address-based strips; serial-only strips stubbed. td1: UART stubbed.
- **mqtt** — in-memory message store + subscription tracking; pub API
  (`publishTopic`, `subscribeTopic`, `unsubscribe`, `close`, setters) exposed,
  `retain`/`timeout` parsed, `server.mqtt.publish_mqtt_topic` remote method
  registered. Status caching with sub-field merge, status_objects filtering,
  timed flush thread, moonraker_status publication on state change.
  Connection state tracking (disconnected→connecting→connected→disconnecting).
  handlePublishPrefixed handler with full test suite (prefix/prefixed param).
  Real MQTT 3.1.1 broker client is DONE (mqtt_client.zig: live TCP connect,
  publish/subscribe, background reader, LWT); only TLS + auto-reconnect/backoff +
  JSON-RPC-over-MQTT dispatch remain P3.
- **spoolman/announcements** — announcements: real RSS fetch from Moonlight
  (arksine.github.io/moonlight) via refreshFeeds using rss.zig parser,
  prefix pruning removes stale entries, notify_announcement_update on changes,
  handleFeedDispatchMulti branches on _method param for proper verb dispatch;
  spoolman: real HTTP proxy with query param support, GET+body rejection,
  notify_spoolman_status_changed on setIo/setServerUrl via emitLocked.
  ETag conditional GET is DONE (http_get.zig stores per-feed ETags, replays
  If-None-Match, 304 skips re-parse).
  Background periodic refresh timer wired (30 min, atomically stoppable, 1 s join latency).
- **file_manager metadata** — record shape correct; deep gcode parsing (slicer/layers/
  thumbnails) now implements findObjectHeight (6 slicer patterns + G1 Z fallback),
  filament_weight_total (7 patterns), nozzle_diameter (3 patterns), thumbnail
  extraction from `; thumbnail begin … end` blocks, slicer_version for all five
  slicer families (PrusaSlicer, Cura, Simplify3D, IdeaMaker, KISSlicer).
- **octoprint_compat** — live printer_state() with klippy + print_stats tracking;
  dynamic safemode in handleServer; state flags for handlePrinter match Python spec.
  Done: 13 unit tests + fuzz test.
- **LDAP** auth source — **NON-GOAL** (explicitly out of scope, will not be
  implemented). phobos supports only the `moonraker` auth source. Rationale:
  LDAP requires a hand-rolled LDAPv3 BER/ASN.1 client + TLS for a deployment
  scenario (corporate directory auth on a 3D-printer appliance) that the target
  does not need. The auth DB still carries the `source` field for shape parity,
  but `source: "ldap"` logins are unsupported. Do not add it back.
- **sensor** — DONE: real SensorCtx with sensors StringHashMap, MeasurementRing
  history, change detection, emitSensorUpdate via emitLocked, param_info tracking.
  The MQTT sensor source has landed (ingestMqttMessage ← MqttClient reader, socket-
  validated). 15 unit + 4 fuzz tests.
- **button** — ~~notification-only, GPIO stubbed.~~ DONE: full ButtonCtx with
  addButton/sendEvent/emitButtonEvent/notification_sent guard, 10 unit + 3 fuzz tests.
- **job_queue** — ~~transition_gcode/delay, remote methods~~ DONE: transition_gcode
  injection via dispatchNextJob, transition_delay storage, "loading" queue state,
  pause_job_queue/start_job_queue JSON-RPC remote methods registered, [job_queue]
  config parsing wired in app.zig, transition_delay timer thread with atomic
  cancel flag and thread join (1-second polling, 32 unit + 8 fuzz tests).

### P2 — misc
- ~~Read host/port from config in `main()`.~~ Done: `-c`/`--config`, `extractBindAddr`, 5 tests.
- ~~store drop-in test~~ — removed when the store moved to SQLite/file.
- ~~Memory baseline: measure RSS of running phobos daemon vs stock Moonraker.~~
  Done: phobos daemon idle RSS ≈ 1.4 MB (VmSize ~23 MB reserved-but-uncommitted,
  2 threads) vs stock Moonraker ~80-150 MB (Python asyncio, multiple threads).
- ~~**Fuzz test gap:** every public JSON-RPC handler now has a unit test AND a fuzz test.~~
  Done: 18 fuzz tests added across machine (11), update_manager (4), wled (1), webcam (3),
  announcements (4), power (1), extensions (1). Total: ~1012 tests (~174 fuzz).

### P3 — remaining depth gaps (non-blocking, requires hardware/external services)
- **mqtt** — DONE incl. P3: live TCP connect, publish/subscribe, background reader,
  LWT, **TLS** (connectTls over std.crypto.tls), **automatic reconnect/backoff**
  (supervisor), and JSON-RPC-over-MQTT request dispatch. The HTTP endpoints also
  keep an in-memory message store + subscription tracking for the no-broker case.
  Pub API complete: `publishTopic`, `subscribeTopic`, `unsubscribe`, `close`,
  `setInstanceName`/`setClientId`/`setDefaultQos`, `storeMessage`/`getMessage`/
  `addSubscription` exposed. `retain`/`timeout` params parsed. Remote method
  `server.mqtt.publish_mqtt_topic` registered. Status caching with sub-field merge
  (`sendStatus`), `status_objects` filtering, timed flush background thread,
  `moonraker_status` publication on klippy state change. Connection state tracking
  (disconnected→connecting→connected→disconnecting). handlePublishPrefixed handler
  with full test suite (prefix/prefixed param). 58 tests (9 fuzz).
- **power/wled/td1** — DONE: power HTTP-URL devices send real GET, `type: gpio`
  drives the sysfs line (gpio_sysfs.zig); td1 reads CSV over UART (serial.zig);
  wled drives serial strips and HTTP strips via `std.http.Client`. Remaining:
  other vendor power backends + on-hardware verification.
- **spoolman/announcements** — ETag/If-Modified-Since conditional GET is DONE
  (http_get.zig). Real RSS fetch + background periodic refresh timer (30 min,
  atomically stoppable); notify_announcement_update + notify_spoolman_status_changed
  emissions wired.
- **Klippy integration test** — DONE: a gated test round-trips info/objects.list/
  objects.query against a live Klippy (`.testenv/run-klippy.sh`), skipping when
  `/tmp/klippy_uds` is absent. Broader behavioral hardening continues.

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
   **status and gcode push dispatch**.
   Remaining: `notify_proc_stat_update` (Done), ~~deep `print_stats` parsing~~ (Done),
   real-Klippy integration test.
6. ~~Fix webcam notification unit tests~~ (P0) — Done.
7. ~~`notify_proc_stat_update` background emission~~ (P0) — Done.
8. ~~Proc stat timer crash fixes~~ — Done: atomic stop flag, stored thread handle,
   join in deinit, null io before join.
9. ~~OctoPrint compat live state~~ — Done: printer_state() tracks Klippy readiness
   + print_stats.state; handleServer dynamic safemode; handleJob/handlePrinter live
   state flags. 13 unit tests + fuzz test.
10. ~~Conformance oracle~~ (P1) — Done: golden capture + replay harness (pass count in
   the conformance status line at the top).
11. ~~P2 cleanup~~ — Done: memory baseline measured per backend
    test, subsystem depth: machine sudo validation, machine services systemctl,
    update_manager git fetch/reset, file_manager gcode parsing, octoprint_compat
    live state, **every handler fuzzed** (17 new fuzz tests across machine,
    update_manager, wled, webcam, announcements, power).
12. ~~Conformance oracle follow-up~~ — merged into (10).
13. ~~**P3 remaining depth gaps**~~ — DONE: MQTT client (TLS/keepalive/reconnect),
    GPIO/WLED/TD1 hardware I/O, spoolman/announcements HTTP/RSS fetch, Klippy
    integration test (gated, against the sim). Remaining only need external tools
    (klipper_estimator, apprise) or are forbidden host mutations (apt/pip/reboot);
    require hardware or external services.

Keep the coverage gate at 100% and the full suite green after every step.

## Known Moonraker gaps (2026-10-20 audit)

- `printer.objects.subscribe` over WebSocket adds to one aggregate set and returns the unpruned aggregate status; Moonraker replaces the connection's subscription and prunes the response (`klippy_connection.py:619-702`). Needs `transport/ws.zig` to pass the requested objects and connection to `KlippyCtx` (`src/components/klippy_connection.zig` `subscribeAggregate`).
- Connectionless `printer.objects.subscribe` (HTTP, `/server/jsonrpc`) is refused with `error.NoSubscriptionConnection`, which the transports report as 500 instead of Moonraker's 400 "No connection associated with subscription request" (`src/components/printer.zig` `ProxyEndpoint.handle`).
