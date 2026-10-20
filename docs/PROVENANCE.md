# Change and verification ledger

Append dated entries. Record the request, change, source evidence, verification
and unperformed checks. Corrections are new entries; do not rewrite an earlier
result as if it had been measured differently.

## 2026-10-20: source review and documentation reconciliation

Requested by the user: finish the whole-codebase review and the unfinished
implementation and documentation work. The source at `2ab11b8` contains 69
commits after released `db010e3` (`git rev-list --count db010e3..2ab11b8`).
That range includes native I/O and ownership changes; its commit log records
the individual changes. This entry does not retrospectively certify every
earlier verification claim.

The documentation now separates API-name registration from behavior, removes
unmeasured implementation-completeness grades and stale server-spine plans,
keeps the newer per-call deltas, and identifies historical measurements and
their limits. Source evidence: `src/main.zig`, `src/oracle/replay.zig`,
`conformance/replay.py`, `tools/api_scanner/table.py`,
`src/components/{analysis,extensions,file_manager,mqtt}.zig`, and Moonraker
`900848584374`. The deleted Zig normalizer stays deleted; the Python replay
manifest remains the normalization implementation. Client scanner prose no
longer claims to have tested missing-plugin fallback behavior.

Verification on the `2ab11b8` source with the documentation candidate:

- `zig build test-artifact -Doptimize=Debug`, then the newly built standalone
  artifact with `--cache-dir=./.zig-cache`: 1283 passed, 1 skipped, 0 failed;
  226 fuzz tests. The skipped case requires a real Klippy socket.
- `zig build -Doptimize=Debug`: native daemon built.
- `phobos --dump-api`, followed by `api_scanner coverage` against
  `api/api_surface.json`: endpoints 123/123, methods 130/130 and notifications
  27/27. Reviewed prose changes in the API table generator were regenerated;
  no delta classifications changed.
- Both scanner test directories, run with pytest, tree-sitter and the Python,
  TypeScript and C++ grammars: 78 passed. Regenerating the client matrix from
  checked-in inputs reports 9 known unregistered method names and exits 1 as
  designed. The matrix rows did not change.
- `git diff --check`: clean.

No physical printer, live database, service deployment, privileged profiling,
fresh memory measurement or external update source was used for this entry.
Further implementation commits need their own verification entries.

## 2026-10-20: isolate measurement helpers

Requested by the user as part of finishing the source review. The local
comparison, profiling, load and memory helpers previously reused `/tmp` paths;
profiling rebound a shared Klippy socket, and memory cleanup could signal PID 0
if startup failed. They now keep configurations, fresh databases, sockets,
captures and build prefixes in unique project-local scratch directories. Only
recorded child PIDs can be stopped; teardown bounds its TERM wait before KILL.
Port checks reject invalid values, production port 7125 and an existing HTTP
listener. Python formatting and interpreter sampling live in Python files run
through `uv`, with absent measurements reported as errors.

Source evidence: `scripts/measure-memory.sh`, `scripts/python-memory.py`,
`tools/perf_harness/{common,bench_local,profile,loadtest}.sh`, `report.py` and
`klippy_stub.py`. The stub advertises proxy endpoints for stock Moonraker,
requires an unused explicit socket path and preserves existing files. Local
server fixtures disable announcement fetches and update refresh; the Moonraker
fixture carries an empty USB-ID file to prevent its automatic download.

Verification:

- `timeout 90 bash tools/perf_harness/tests/smoke.sh`: command-double checks
  passed for capture locations, both profiler branches, metric formatting,
  failed builds and loads, invalid/busy/production ports, unowned PID refusal
  and TERM-resistant child cleanup.
- Python helper tests: 10 passed, including malformed-frame recovery over a
  socket pair and refusal to replace an existing Unix path. Scanner tests
  remain 78 passed. Test temporary files were directed below `.scratch/`.
- `bash -n` and ShellCheck passed for the changed shell helpers; Ruff lint and
  formatting passed for the changed Python helpers. Strict mypy passed for
  `klippy_stub.py`, `report.py` and `scripts/python-memory.py`.
- Native Debug phobos connected to the isolated stub. Stock Moonraker
  `900848584374` then reached Klippy-ready and its HTTP objects query returned
  the stub heater temperature 24.31. Both used new scratch datadirs and were
  stopped; no owned process remained. Earlier stock smoke attempts failed on
  an overlong absolute Unix socket path; one also downloaded `usb.ids` into
  its scratch datadir before the fixture was corrected.
- Full standalone Zig suite on the unchanged `2ab11b8` source: 1283 passed,
  1 skipped, 0 failed; 226 fuzz tests. `git diff --check` passed.

No real load run, privileged profiler, printer or live database was used. The
historical performance and memory numbers were not remeasured. Black could not
run because it was absent from the offline package cache; Ruff formatting was
checked without fetching packages.

## 2026-10-20: shared request conversion and source-backed status

Requested by the user: finish the codebase review and use Zig's standard
facilities where they fit. Commit `69cf20c` replaces duplicated handler getters
with `src/json/params.zig`, using `std.fmt` numeric parsers, `std.ascii` and
`std.mem`. The vendor references are Moonraker `900848584374`
`common.py:WebRequest._get_converted_arg` and `_parse_list`. Defaults apply to
absent keys, while a present invalid typed value returns a 400 handler error.

The observable input changes are:

| Handler families and arguments | Before | Current conversion |
| --- | --- | --- |
| Boolean flags: file `extended`/`force`, history `all`, queue `reset`/`all`, webcam flags, update `refresh`/`hard`, MQTT `retain`/`use_prefix`, temperature `include_monitors`, announcements `include_dismissed`, Spoolman `use_v2_response`, server-info `raw` | Several getters accepted integer truthiness or `"1"`, treated other strings as false, or used the default for null. | JSON booleans and case-insensitive `"true"`/`"false"` only, as vendor `get_boolean`; invalid present values fail. |
| Numeric arguments: history pagination/timestamps, gcode count, announcement wake time, webcam FPS/rotation, WLED controls/colors, MQTT QoS/timeout, HTTP spool ID | Invalid strings and null could silently become defaults, zero, or a cleared spool; conversions varied by component. | Decimal conversion with standard parsers; booleans become 0/1 and floats truncate for integer arguments. Signed strings allow surrounding ASCII whitespace and underscores between digits. Invalid values and integers outside i64 fail. Handler bounds still apply; MQTT rejects invalid/non-finite timeouts before I/O. |
| Text arguments: auth credentials/source, database namespace/key, file paths, device/sensor/strip names, update source and proxy/webcam strings | Optional getters sometimes treated wrong types or null as absent; required getters usually rejected them. | Present text arguments must be strings, including optional arguments. phobos deliberately does not reproduce Python `str()` representations such as `None`, `True`, lists or objects. |
| Queue `filenames`/`job_ids` and announcement `subscriptions` | Queue arguments were array-only; missing filenames could act as an empty request and mixed array items were ignored. | Arrays must contain strings. Comma-separated strings are split, trimmed and stripped of empty items; array strings stay unchanged, as vendor `get_list`. Queue `filenames` is required. |
| Raw database `value` and optional read `key` | Null carried data or selected the namespace. | Raw readers preserve that behavior. A stored null is valid; a null read key still selects the namespace. |
| Active spool HTTP and Klipper remote method | Invalid HTTP values could clear the active spool; malformed remote values could do the same. | HTTP POST with no `spool_id` clears it; explicit null or malformed typed input returns 400 without changing it. The remote method explicitly accepts integer/null and rejects other types. HTTP boolean/numeric conversion follows vendor `get_int`; the remote method does not use that conversion. |

Source checks: `core/methods.zig:serverInfoHandler`, the affected component
handlers, `spoolman.zig:handleSpoolId` and `handleSetActiveSpool`, plus the old
getter implementations at `69cf20c^`. The standalone parameter module passed
18 tests with 4 fuzz tests. Integrated handler verification is recorded in the
final gate entry rather than inferred from the helper tests.

User creation also has an explicit storage limit:
`authorization.zig:validateUsername` rejects an empty or dotted username.
`POST /access/user` therefore returns 400 for a dotted name that Moonraker's
SQL user table can store. DataStore dots denote nested paths; names are neither
rewritten nor accepted as nested user records. Loading an invalid persisted
user fails rather than silently omitting it.

The status documentation was checked against integrated source `8d32c78` and
the completed revocation change `84a5609`. Fixed subscription replacement,
Spoolman proxy errors/deadlines and update locking are no longer listed as open
gaps. Full updates execute Git work; web/zip installation and service restarts
remain absent. Analysis reports configured paths but has no executable runner.
Persisted logout/deletion invalidates matching named WebSocket sessions through
`App.onUserLogout` and `Connections.invalidateUser`; protected methods and
notifications remain blocked until reauthentication.

Only reviewed rows in the API generator changed: user creation, zip creation,
announcement refresh/timing, analysis, service actions, full updates, sensor
sampling, MQTT acknowledgments, webcam URL resolution and Spoolman reports and
proxy behavior. Remaining missing features are documented as partial behavior;
they are not claimed as implemented or as new regressions. API registration
coverage remains a separate name check. Printer behavior and historical
performance measurements were not rechecked for this documentation entry.

Documentation verification: native Debug built from `8d32c78`; its API dump
passed the registration gate (123/123 endpoints, 130/130 methods, 27/27
notification names). The per-call table was regenerated after reviewing the
changed deltas, and `api_scanner table --check` passed. The fresh dump also
includes the registered `notify` remote method; both the per-call table and
client method-set artifacts now record it. The Moonraker client-matrix input was
also stale: it used collapsed multi-verb names such as `access.user` and
`server.database.item`. It now uses the pinned baseline's 130 derived method
names, including `get_`/`post_`/`delete_` variants. The client matrix still reports its
9 known unregistered plugin/client methods and exits 1 as designed. The two
scanner suites and measurement helper tests passed together: 88 tests.
No unchanged full Zig suite was repeated for this documentation-only change;
the integrated source gate is recorded separately.

## 2026-10-20: queue locking before notifications and stable start responses

Requested by the user: finish the codebase review and fix the confirmed bugs.
`src/components/job_queue.zig:lockJobs` and `unlockJobs` now use constructor
`clock_io`, matching the dispatch worker's lifetime. Optional notification I/O
no longer disables synchronization. The existing concurrent queue stress test
now runs with notification I/O unset and joins its thread on error paths too.

`handleStart` allocates its accepted response before changing the paused state
or launching a worker. The response remains `loading` when the worker has
already entered `starting`; a failed worker launch returns `paused` and retains
the queued job. This follows the response-before-delayed-callback ordering in
Moonraker `900848584374`, `job_queue.py:start_queue` and `_handle_start_queue`.

The dispatch regression blocks the real owned worker with `std.Io.Event` until
the loading response is checked, then releases and joins it. Separate handler
tests cover every response allocation failure and a zero concurrency limit.
Actual asynchronous queue fixtures use the thread-safe allocator and stateless
store; request arenas remain caller-owned. Cancellation fixtures join before
reading dispatch results.

Verification: the filtered queue run passed 55 tests, including 9 fuzz
harnesses. The broader focused start/timer run passed 15 tests with 2 fuzz
harnesses. `zig fmt --check src/components/job_queue.zig` and `git diff --check`
passed. The Debug standalone suite built with `zig build test-artifact
-Doptimize=Debug` passed in 120.9 seconds: 1424 passed, 1 skipped, 0 failed,
with 262 fuzz harnesses. Printer access and deployment were outside this change.

## 2026-10-20: completed source review and aggregate verification

Requested by the user: take over the interrupted whole-codebase Zig review,
including its parallel work, and finish the fixes. The final source checkpoint
is `6687e3bf999201d66347057d25160e4823de2ad6`. The integrated range
`2ab11b8..6687e3b` contains 41 commits; the earlier 69-commit range is recorded
above. Changes and their evidence include:

- `src/json/params.zig` uses standard numeric, ASCII and slice helpers across
  handlers. The input changes are listed above. Native JSON parsing already
  preserves overflowing exponents as `number_string`; round-trip tests
  disproved the proposed overflow defect, so no extra JSON validator was added.
- `src/util/{process,socket_deadline,deadline_writer}.zig`,
  `components/{klippy_connection,http_get,ws_client}.zig` and `transport/ws.zig`
  use native cancellation, clocks and vectored writes. Process deadlines cover
  final child completion, a WebSocket frame shares one absolute write deadline,
  Klippy releases Core before blocking writes, and shutdown joins owned work.
  Incomplete HTTP response cancellation no longer reaches the standard
  client's `bodyErr().?` failure path. `docs/STDLIB.md` records checked native
  APIs and the remaining platform adapters.
- `src/{http_transport,jsonrpc}.zig` and `server/{connections,notify}.zig`
  serialize borrowed results under Core, screen each batch item, preserve
  upstream errors, replace subscriptions and filter requested fields.
  Pending-auth clients cannot receive protected notifications.
  `components/authorization.zig` rejects untrusted proxy identity, validates
  persisted records, preserves credentials on failed persistence and revokes
  named WebSocket sessions after logout or deletion. The earlier reference
  `84a5609` was integrated as `b1cf22d`; regression tests exercise real local
  WebSocket connections, revocation and reauthentication.
- `src/app.zig`, `config/confighelper.zig`, `store/sqlite_store.zig` and
  `components/{data_store,history,job_queue}.zig` reject invalid startup input,
  keep backend defaults in one place, check SQLite bindings and preserve
  migrated records during nested mutations. History failures propagate;
  queue snapshots own their strings, saves serialize, and queue locks do not
  depend on notification setup. Allocation and scheduling failures preserve
  accepted queue state. Configuration globs use a bounded iterative matcher.
- `components/file_manager.zig` follows safe directory links with recursion
  bounds, keeps linked files read-only and unlocks files after Klippy shutdown.
  Its metadata parser frees per-file scratch before returning owned results.
  The eight-file fixture retained 3,355,620 bytes before the fix and less than
  128 KiB afterward; this measures retained host allocations, not printer RSS.
- `components/{mqtt,mqtt_proto,spoolman,notifier}.zig` bound transport shutdown
  and request waits, validate wire topics, UTF-8 and persisted input, preserve
  scalar payloads and report upstream errors. MQTT echo screening retains
  bounded fingerprints instead of payload copies. Native big integers preserve
  numeric equality without the direct wide-integer cast that failed ARM code
  generation. Spoolman cancellation joins its request worker.
- `components/{machine,update_manager,feather_updates}.zig` serialize Git work
  outside Core, reject competing or printing-time mutations, isolate inherited
  repository overrides and validate Git output. Service failures now reach
  callers without changing reported state. Before-fix probes reproduced both
  a successful response after a failed service command and timestamp overflow
  from an enormous finite timeout; regressions cover both paths.
- `components/{sensor_template,power,webcam,td1,announcements,rss}.zig` bound
  template work, replacement sizes and scan time; honor worker stop requests;
  retain batch results; escape URL credentials; stream UUID name hashing; and
  validate external text before JSON serialization.
- Fresh checkouts now contain the pinned SQLite amalgamation. The version,
  source ID, checksums and absence of local patches are recorded in
  `vendor/sqlite/README.md`; `sha256sum` matches both tracked sources. No binary
  build artifact is tracked. Documentation distinguishes API registration
  from behavior, and `TODO.md` lists remaining feature-sized gaps.

Verification at the final source checkpoint:

- Native Debug built with `zig build -Doptimize=Debug`; `zig-out/bin/phobos`
  is again a static x86-64 Debug binary.
- `zig build -Dtarget=arm-linux-musleabihf -Dcpu=cortex_a7
  -Doptimize=ReleaseSafe --prefix .scratch/takeover/arm-final` passed. `file`
  reports a stripped, statically linked ARM EABI5 executable.
- A fresh local clone of `6687e3b` built native Debug with its tracked SQLite
  sources, without a vendor symlink or the Moonraker reference checkout. Its
  working tree stayed clean.
- The native `--dump-api` passed `api_scanner coverage`: endpoints 123/123,
  methods 130/130 and notifications 27/27. `api_scanner table --check` passed.
  These are registered-name checks, not a claim of complete behavior parity.
- The two scanner test directories and measurement-helper tests passed
  together: 88 tests. The shell helper smoke test passed. ShellCheck, Ruff lint
  and formatting, and strict mypy passed for the changed helpers. Python tests
  used a project-local scratch base directory.
- `zig fmt --check build.zig build.zig.zon src` and `git diff --check` passed.
  Commit messages in the unpublished range passed the attribution-text check.

Black was unavailable in the offline package cache. `graphify-out/graph.json`
exists, but `graphify` is absent from PATH, so its update was skipped. No real
load run, privileged profiler, new target memory measurement or physical
printer validation was performed. The final gates use owned local fixtures;
the earlier automatic USB-ID download is recorded above. The printer, its
services, live database, configuration and golden images were untouched during
this takeover. No QEMU, printer restart, deployment, release tag or push was
performed. Hardware transport behavior remains unverified by these host tests;
the remaining feature limitations are documented in `TODO.md`.

Final host gate: `zig build test-artifact -Doptimize=Debug`, then only the newly
built standalone artifact with `--cache-dir=./.zig-cache` under a 600-second
timeout, passed at `6687e3b`: 1428 passed, 1 skipped, 0 failed; 262 bounded fuzz
harnesses. The skip requires a real Klippy socket. This ran without a runtime
test filter. Fuzz harness registration and deterministic execution are not a
sustained fuzzing campaign. No source changed after this gate; the final commit
only appends this verification record.

## 2026-10-20: queue startup and shared Klippy events

Requested by the user: finish the remaining TODOs. `JobQueueCtx.onKlippyReady`
loads a queued job after the vendor's one-second startup delay when
`load_on_startup` is enabled. `onKlippyShutdown` pauses and joins dispatch without
changing `pause_requested`. App configuration now reads and validates the flag.
Evidence: Moonraker `900848584374`, `job_queue.py:_handle_ready` and
`_handle_shutdown`; `src/components/job_queue.zig` and `src/app.zig:onKlippyState`.

`KlippyCtx` now exposes borrowed state, status and gcode callbacks under Core.
Initial subscribed snapshots also reach the status callback. Component callbacks
must queue blocking work. `refreshSubscriptions` refreshes the aggregate after
internal objects are added, outside Core and under the subscription mutex.
The App currently connects the queue lifecycle; subsequent component changes
will add their own consumers.

Verification: new feature tests first failed to compile because the lifecycle
API and event fields were absent. After implementation, the complete standalone
Debug suite passed: 1431 passed, 1 skipped, 0 failed; 262 bounded fuzz harnesses.
Tests cover delayed startup dispatch, shutdown cancellation with both pause
states, seeded/pushed status and gcode callbacks, and a real local third
subscription refresh retaining the client's current objects. `zig fmt` and
`git diff --check` passed. The skipped test requires real Klippy. ARM and physical
runtime verification were not performed for this slice; no printer was contacted.

## 2026-10-21: transport limits, serial deadlines and provider polling

Requested by the user: finish all remaining TODOs. The first integrated group
ends at `bb4d666`, after the queue lifecycle change. It includes:

- `7da97d4`: `util/ws_message.zig` grows the native WebSocket reader lazily to
  10 MiB, rejects larger announced lengths before allocation and restores the
  small buffer afterward. Both regular and raw Klippy bridge sockets use it.
- `c5f257d`: HTTP heads, including partial and keepalive requests, share an
  absolute receive deadline. The deadline is removed before bodies and upgrades.
  Configured CORS domains also allow trusted Origin IPv4 addresses, matching
  the pin's fallback without accepting userinfo or hostname lookalikes.
- `e8aba80`: serial read/write deadlines use native selection, cancellation and
  joining. The PTY fixture verifies silent reads, stalled writes and subsequent
  byte-exact reads without touching physical serial devices.
- `da28b4b`: the existing bounded template evaluator renders text and supports
  injected native positional/keyword callbacks. Full Jinja2 remains excluded.
- `dd67e84`: provider service queries and actions release Core for I/O and
  provider-lock waits. Supervisord substates match the lowercased vendor state;
  periodic polling publishes only changes. `docs/MACHINE.md` records the API.
- `bb4d666`: MQTT owns the startup HOME value before credential rendering,
  preserves the old value on allocation failure and releases replacements.

Evidence: the integrated commits and their regression tests; Moonraker
`900848584374`, authorization, machine/provider and component implementations;
the installed Zig 0.17 HTTP codec and `std.Io` cancellation APIs.

The complete merged Debug suite at `bb4d666` passed: 1450 passed, 1 skipped,
0 failed; 268 bounded fuzz harnesses. The individual transport and serial slices
also built static ARM. No physical printer or external broker was used. Native
WebSocket framing retains its existing fragmented-message limitation; hardware
runtime validation is still outstanding.

During later button development, one lifecycle test omitted its temporary GPIO
root and briefly requested line 2 on host `/dev/gpiochip0` as an input. Closing
the request released it; no output value was sent. The fixture now assigns its
temporary root before startup. The remaining GPIO tests were checked: adapter
opens use temporary roots, and fake event, allocation-failure and fuzz tests do
not open physical GPIO devices. This exception was reported to the user; it is
not included in a claim that all host hardware was untouched.

## 2026-10-21: startup, peripheral queries, thumbnails and update services

Requested by the user: finish the TODO list. Integrated sources through
`205bf4b` add the following behavior:

- `edc92a6`: startup loads one ConfigParser before opening storage, derives
  bind/backend/path from it, then transfers ownership to App. HOME is copied
  before MQTT configuration. Parse and allocation failures retain one owner.
- `1326399`: webcam URLs resolve against native local network state; UDP
  connect obtains the selected source address without sending a packet.
  Wildcard local listeners and bounded DNS support `convert_local`, preserving
  URI credentials, query and fragment. No route-text parser was added.
- `f89beb9`: update refresh windows use local civil time, including future DST.
  The installed `std.Tz` cannot evaluate POSIX footer rules, so C owns the
  `localtime_r` ABI. Isolated child environments test timezone behavior without
  changing the test process environment.
- `500efde` and `b0b6013`: typed V4L2 format/resolution enumeration and bounded
  CAN unassigned-node queries. Transfers, ioctl operations, cancellation and
  close use native I/O; only CAN socket creation/binding lacks a native address
  API. Missing CAN remains an empty result. Service discovery now retries a
  failed initial provider query.
- `65b6b4b`: decoded thumbnail files are replaced atomically under checked
  `.thumbs` paths. Metadata and listings advertise image paths; the HTTP route
  serves exact image bytes with the image MIME type. Base64 payloads no longer
  remain in metadata cache entries.
- `205bf4b`: changed Git sources and successful recovery/rollback restart their
  configured managed services through the validated machine API. Unchanged
  clean sources do not restart. Package runners remain uninjected in the daemon.

Daemon startup enables service polling. A Core-held Klippy startup callback now
precedes initial subscription snapshots, while final readiness remains after
handshake completion. The callback regression checks this startup event too.
The TODO entries above were removed or narrowed to their remaining work.
Owning documents are linked from README. The existing GPL-3.0-only choice now
has its license text copied verbatim from the pinned Moonraker LICENSE.

Verification: the combined standalone Debug suite passed with the daemon/hook
wiring: 1473 passed, 1 skipped, 0 failed; 274 bounded fuzz harnesses. Individual
slices passed static ARM builds and local HTTP, temporary-repository, injected
device-I/O or child-process fixtures. Startup bounded LLVM fuzzing completed
523 runs (29 unique inputs), webcam fuzzing 138 runs (19 unique inputs), both
with `--fuzz=100`; separately compiled uninstrumented C objects avoided the
installed native fuzz backend's sanitizer-link failure. No physical printer,
real update, service restart, camera or CAN interface was used in these checks.

## 2026-10-21: retain published configuration on application errors

Requested by the user while finishing TODOs. New strict component options
exposed an ownership defect: `App.setConfig` published its parser, but a later
error still ran the caller's parser cleanup. App retained a dangling pointer
and could free it again during teardown. Clearing that pointer alone would
leave borrowed component strings dangling too.

`setParsedConfig` now consumes its parser on every call. Errors before
publication free it immediately; errors afterward retain the parser until App
teardown. A failed component application requires discarding App. `setConfig`
limits parse cleanup to its lexical parse block, and `StartupConfig.createApp`
clears its owner before transfer. This supersedes the success-only ownership
contract recorded for `edc92a6`.

Evidence: `src/app.zig:setConfig`, `setParsedConfig`, the late-invalid-option
regression and path-allocation failure regression; `src/main.zig:createApp`.
The before-fix regression failed on the stale published parser. After the fix,
98 config-focused tests passed with 10 bounded fuzz harnesses. The full Debug
standalone suite passed: 1474 passed, 1 skipped, 0 failed; 274 bounded fuzz
harnesses. `zig fmt` and `git diff --check` passed. No printer was contacted.

## 2026-10-21: remaining component and file workflows

Requested by the user: finish the TODO list. The integrated source through
`a62f570` adds these component behaviors and their regression tests:

- Extension agents register connections, exchange correlated requests and
  events, and forward dynamically registered Klippy methods. Requests use
  connection IDs, deadlines and disconnect cleanup. Remote Klippy calls now
  have 16 active tasks and a separate 16-entry pending queue; shutdown cancels,
  joins and frees both. WebSocket fragment assembly now accepts bounded
  fragmented messages, including interleaved control frames. This supersedes
  the fragmented-message limitation recorded above.
- MQTT supports 3.1, 3.1.1 and 5, selected Klippy status topics, credential
  templates and password files, acknowledged QoS publication, unsubscribe on
  the final waiter, reconnect subscription windows and bounded offline writes.
  Sensors replace message readings, expose configured parameter/history
  metadata and sample at 1 Hz. Announcements read local development feeds and
  schedule notifications after 50 ms. Their workers have explicit ownership.
- Spoolman tracks extrusion high-water marks and tool changes, validates the
  active spool on connection and reports bounded pending usage with retries.
  Pending reports remain memory-only; a lost response can cause a retry after
  the remote service accepted a report, matching the vendor's limitation.
- Power options, bounded HTTP templates, GPIO buttons, service binding
  validation and timer APIs are implemented. WLED queries state before
  initialization, retries failed initialization and retains serial readers.
  TD1 performs the errors-file handshake and retains one reader per device,
  with device reboot handshakes and UTC timestamps. PanelDue has a serial
  command queue, responses, file listings, macros and status updates.
- File ZIP creation streams CRC-checked stored or DEFLATE ZIP32 entries into
  an atomic destination. Native directory observation reports external changes
  and invalidates metadata. Requested uploads and OctoPrint selections can
  queue busy jobs, and uploads recheck the loaded-file guard before replacement.
  ZIP size/entry limits, shallow directory selection and fail-closed observer
  exhaustion are documented in `docs/FILE_MANAGEMENT.md` and `docs/STDLIB.md`.
- Web update archives download into private bounded staging, validate paths,
  types and CRCs, then replace or roll back source directories. Persistent files
  survive replacement, and dotted updater names have distinct encoded cache
  keys. Rollback failures complete progress notifications. The two-rename
  replacement gap is documented; it is not a power-loss transaction.
- USB names resolve from a bounded, conditional `usb.ids` cache, including
  Latin-1 input and class names. Cache metadata fingerprints prevent a partial
  write from authorizing an incorrect 304 response. Downloads start only from
  daemon startup. Service bindings reject unavailable and self-owned services.

Evidence: commits `74e9c4d` through `a62f570`, the pinned component sources,
and native HTTP/WebSocket, temporary filesystem/repository, PTY, injected
service/GPIO and allocation-failure fixtures. The merged suite first exposed
one stale PanelDue test expecting the earlier configuration ownership rule;
the assertion now checks that the rejected parser and borrowed values remain
readable until teardown. Two stale source comments were corrected too.

The corrected full Debug suite passed: 1686 passed, 1 skipped, 0 failed;
318 bounded fuzz harnesses. Python scanner/client/helper tests passed 88/88;
measurement helper smoke tests, ShellCheck, helper Ruff and mypy passed.
`zig fmt --check` and `git diff --check` passed. Each component also passed
its isolated host suite and static ARM build; final daemon integration and
the independent clean-checkout gate are recorded separately below.

GPIO exception clarification: the earlier host line-2 request configured
input with both-edge detection and read its value before closing the handle.
No output-value write was issued; physical effects were not measured. Later
GPIO tests use temporary roots or injected events. No printer, external broker,
real update, board restart, deployment or live printer database was used.

## 2026-10-21: complete daemon integration and final verification

Requested by the user: finish all listed TODOs. Source checkpoint `f5f2dd4`
includes injected estimator execution (`6234999`) and the final daemon wiring.
The estimator serializes native cancellable calls outside Core, snapshots
inputs into a private workspace and rechecks the source before atomic
replacement. No default runner, download, automatic metadata analysis or
ready-triggered config dump was added. `docs/ANALYSIS.md` states those limits.

Klippy state, status and gcode callbacks now reach MQTT, Spoolman, power,
PanelDue and analysis readiness. MQTT selectors join the aggregate Klippy
subscription; initial snapshots seed reporting before final readiness. Queue
commits notify power outside the queue mutex. Internal power calls preserve
`force`; button calls enforce internal transport and the handler's Core
requirements. Daemon startup validates service bindings before initial power
states, then starts the owned power/button, sampling, announcement, USB and
observer workers. Teardown joins callback producers and dispatchers before
freeing consumers, and closes storage after its users.

An independent regular-file CLI check exposed a separate stdout defect:
constructing a positional writer for each chunk overwrote earlier chunks.
The shared output helper now uses `std.Io.File.writerStreaming`. A real-file
unit/fuzz regression and compiled CLI checks cover the fix. API dumps also
honor an explicit `-d`, so development checks keep their files under `.scratch`.

`b9e1f46` reconciles TODO, owning documents and curated API deltas with the
implemented source. Only the per-call table and affected client method sets
were regenerated; the pinned API baseline was retained. The client set now
contains 147 methods, including the two internal helpers. Its nine existing
plugin/nonstandard gaps are unchanged. Name coverage is not a claim of full
behavioral conformance. Video/libcamera, rate-limit telemetry, partial power
backends, reverse-DNS authorization and the deliberate exclusions remain
explicit in TODO and the generated table.

Final evidence and checks:

- The working tree and an independent clean checkout of `f5f2dd4` each passed
  the full standalone Debug suite: 1714 passed, 1 skipped, 0 failed;
  324 bounded fuzz harnesses. The skipped test requires real Klippy.
- Native static Debug and Cortex-A7 static ARM ReleaseSmall builds passed
  from tracked SQLite sources. ARM was built into an isolated scratch prefix;
  `zig-out/bin/phobos` remains the native Debug binary. ARM execution was not
  performed. The independent ARM SHA-256 is
  `448279ff575048bc442b5eb1ef48a6c4bcb280ceb78ea3ca54b05e2dd85ba3eb`.
- Compiled CLI output was checked for exact text or parsed JSON, through both
  regular-file redirection and pipes: version, JSON version, CLI Spec, help
  and API dump with an explicit scratch datadir.
- API coverage passed: 123/123 endpoints, 130/130 baseline methods and 27/27
  notifications. The reviewed generated table passed `table --check`.
- Four bounded LLVM-guided WebSocket/MQTT targets passed 70,334 actual runs:
  WebSocket 20,201/135 unique inputs, MQTT parser 30,098/103, malformed
  fragments 10,031/4 and MQTT encoder 10,004/0. Their production source blobs
  are identical at the final source checkpoint.
- Python scanner/client/helper tests passed 88/88. Strict checking with the
  installed tree-sitter types exposed two scanner annotation gaps; `_text`
  now asserts its retained-source invariant, and tuple-router extraction
  reuses the checked function node. The extractor also uses built-in collection
  and optional annotations, as required by its lint rules. Tests and mypy
  passed afterward.
- Helper smoke tests, ShellCheck, Ruff, the table formatter check, mypy,
  `zig fmt --check` and `git diff --check` passed. Black was unavailable in the
  offline cache; Ruff checked the edited table's formatting. Graphify was
  unavailable, so its existing generated graph was not updated.

Commands: `zig build test-artifact -Doptimize=Debug`, the standalone artifact
with `--cache-dir=./.zig-cache`, `zig build -Doptimize=Debug`, and
`zig build -Dtarget=arm-linux-musleabihf -Dcpu=cortex_a7 -Doptimize=ReleaseSmall`.
Guided runs used the production modules, LLVM and `--fuzz=10K` with recorded
seeds. API generation and Python checks used the project scratch datadir and
cached dependencies. No physical printer was contacted, restarted or deployed
to; no real update, live database, golden image, QEMU, push or tag was used.
Hardware timing, ARM runtime and performance measurements remain unverified
for these changes. The earlier host GPIO input exception is recorded above.
