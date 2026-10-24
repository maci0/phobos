# Change and verification ledger

Append dated entries. Record the request, change, source evidence, verification
and unperformed checks. Corrections are new entries; do not rewrite an earlier
result as if it had been measured differently.

## 2026-10-22: private security reporting contact

Requested by the user for security scanner enrollment. Added `SECURITY.md`
with the maintainer mailbox and linked it from `README.md`. Verified the
mailbox against the existing enrollment contact and checked the documentation
diff. Runtime code is unchanged; live printer checks do not apply to this edit.

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

## 2026-10-21: real printer USB cache compatibility

Requested by the user: check the completed work on the printer. Production
phobos v0.1.2 remained on 7125, PID 6532. Its last print was complete, Klippy
ready and both heater targets zero. The new static ARM binary ran separately
inside the Forge-X 1.4.2 chroot, bound only to `127.0.0.1:7126`. Writable data,
database/WAL copies, metadata fixtures and archives stayed under the owned
`/data/.phobos-check-b7ab325-20261021` directory. The database/WAL source
hashes were stable across copying. The live database was not opened through
SQLite. Announcement feeds used local development mode, update refresh was
disabled and the existing USB cache was copied, avoiding external downloads.
The board's `/tmp` had only 3.3 MiB free, so probe files used the data partition.

The first hardware pass found `/machine/peripherals/usb` returning 500 with
the printer's 730590-byte `usb.ids` cache, version 2026.06.10. The parser
mistook `BIAS` for a vendor because it checked only the first character of a
four-character token. Classification now reuses the complete four-digit hex
validator. A minimal file-backed lookup regression failed with `InvalidUsbIds`
before the fix and passed afterward; the selected-record fuzz case now includes
the auxiliary section too. All 19 USB-focused tests passed, including two
bounded fuzz harnesses. The full host suite passed: 1715 passed, 1 skipped,
0 failed; 324 bounded fuzz harnesses. Static ARM ReleaseSmall and restored
native Debug builds passed. Corrected ARM SHA-256:
`644a1d5cd6a0922730cfd6479ce8546e8a65f4124f61e300cce0ebf78f0e8b6f`.

The corrected binary passed the steady-state hardware checks: matching
26-component sets, real ARM/Forge-X identity, canonical roots, config/gcodes
directory capacity, seven USB devices, camera formats/resolutions, three UARTs,
100 HTTP reads at concurrency two, status subscription pushes, a fragmented
64 KiB WebSocket request, raw Klippy object listing, extension-agent RPC/events
and disconnect cleanup, owned thumbnail/ZIP operations and expected error codes.
All four temperature stores gained four samples over 4.2 seconds. A 3376096-byte
G-code download matched production's length and SHA-256. This compared the new
binary with deployed phobos, not a running vendor Moonraker.

An isolated observer fixture exited with `ObserverUnavailable`. The real kernel
reports `# CONFIG_INOTIFY_USER is not set`; the actual Forge-X configuration
already selects `none`. This is an environment limitation, now documented in
`docs/FILE_MANAGEMENT.md`, rather than a code parsing or ABI failure. A separate
startup readiness race was observed and is verified in the next entry. No
motion, heating, print start, printer restart, firmware restart, power/service
action, real update or production replacement was performed. Probe stops so
far preserved boot ID `6213a6c1-a3b6-4b38-b637-5aa9a116a117`.

## 2026-10-21: Klippy readiness and final printer checks

Requested by the user: check the new code on the real printer. A fresh probe
reported `server.info` ready before the handshake opened the proxy request
gate, so its first object query returned 503. `KlippyCtx.setState` now publishes
startup while its internal ready state seeds subscriptions. Handshake completion
republishes ready after the existing atomic proxy gate opens. State-change return
values and startup/shutdown connection semantics are retained. The behavior is
documented in `DEVELOPMENT.md`.

A deterministic Unix-peer regression pauses the gcode-output subscription. It
failed before the fix because HTTP reported ready during the pause; afterward
it verifies startup with a gated proxy, then ready with a successful object
query. Unit assertions cover republishing an unchanged internal state, and a
bounded fuzz test checks state publication across gate changes. The combined
USB/readiness source passed the full standalone Debug suite in an isolated
checkout: 1717 passed, 1 skipped, 0 failed; 325 bounded fuzz harnesses. The skip
requires the separately gated real-Klippy fixture. Source and build files were
compared with the integration tree before building its hardware artifact.

Native Debug and static Cortex-A7 ARM ReleaseSmall builds passed. The independent
and integration ARM artifacts have the same SHA-256:
`98ee29e4a7f044924e1eb2f3b7a30c633393f896c23c14893029084adb70d67b`.
The integration artifact ran inside the Forge-X chroot on loopback port 7126,
using the copied database and owned data described above. A cold-start poll
observed startup at 1.535 seconds and ready at 2.346 seconds; the first object
query after ready succeeded without retrying a 503. Times include probe launch
and polling and are not a performance comparison.

All 11 final hardware check groups passed: readiness/component sets, system
identity and directory capacity, USB/video/serial/CAN enumeration, 100 concurrent
reads at concurrency two, four temperature stores, normal/fragmented/raw
WebSockets, extension-agent RPC/events/cleanup, owned thumbnail/ZIP fixtures,
error responses, a real G-code download and final readiness. The download again
matched production's 3376096 bytes and SHA-256. The probe log contained startup
messages only. An end-of-run process snapshot showed 3436 KiB RSS, 18928 KiB
virtual size and 12 threads; this is one snapshot, not a memory benchmark.

API 1.5.0, the phobos identity and the non-Python version string remain intentional.
Missing CAN still returns an empty list. The kernel's missing inotify support is
an environment limit; its actual configuration selects observer `none`. Optional
hardware integrations absent from the real 26-component configuration were not
physically exercised. No vendor Moonraker comparison or update refresh was run.
API name coverage passed at 123/123 endpoints, 130/130 methods and 27/27
notifications. Native Debug was restored, formatting and diff checks passed,
and unavailable Graphify was skipped without changing its generated graph.

The owned probe was stopped, its three live-root symlinks were explicitly
unlinked before removing its private directory, and the SSH tunnel was closed.
Port 7126 had no listener. Production PID 6532 remained ready on 7125, with
26 components, no warnings or failures, last print complete and heater targets
zero (extruder 30.55 C, bed 29.44 C). Boot ID remained
`6213a6c1-a3b6-4b38-b637-5aa9a116a117`. The already-running executable and the
installed executable both report package 0.1.2 but have different hashes; neither
was changed here and restart behavior was not tested. `/tmp` still had 3.3 MiB
free. No production replacement, restart, motion, heating, print start, power
action, real update, live database write, push or tag was performed.

## 2026-10-21: package v0.1.5

Requested by the user: cut a new release after the printer checks. Version
`0.1.5` follows the existing annotated `v0.1.x` tags and the repository's existing
GitHub release convention. `build.zig.zon`, README and TODO point to the new
version; `docs/releases/v0.1.5.md` describes the review and integration changes
through `df89cf4`, their checks and retained limits. Packaging changed no source
under `src/` or the build graph. The package version changes generated CLI
metadata; the reported API and implementation identity remain unchanged.

The bumped version passed the complete standalone Debug suite: 1717 passed,
1 skipped, 0 failed; 325 bounded fuzz harnesses. The artifact was built with
`zig build test-artifact -Doptimize=Debug` and run with
`--cache-dir=./.zig-cache`, without a runtime filter. The existing skip requires
the separate host real-Klippy fixture. The preceding 11-group real-printer pass
and cold-start regression are recorded above; the version-bumped artifact was
not redeployed or rerun on the printer.

Zig 0.17.0 built stripped static musl ReleaseSmall binaries for
`arm-linux-musleabihf` with `cortex_a7` and `x86_64-linux-musl` with `baseline`.
The ARM ELF reports Cortex-A7, ARMv7 and hard-float EABI. The native release
binary reports JSON package version `0.1.5`; its compiled API dump passes
123/123 endpoints, 130/130 methods and 27/27 notifications. Native Debug was
rebuilt and restored in `zig-out/bin/phobos`, also reporting `0.1.5`. Formatting
and diff checks passed. No API documents or unavailable Graphify output were
regenerated.

Release assets are held in the ignored `.scratch/releases/v0.1.5/assets/`
directory, with a verified `SHA256SUMS` file:

- `phobos-v0.1.5-arm-linux-musleabihf`, 2583596 bytes:
  `809436f960a25ba5f2d35e9a5cd15b57901b4a46426eb37e8875d22eb279cd8a`.
- `phobos-v0.1.5-x86_64-linux-musl`, 2708392 bytes:
  `c511eab7a693785340b4a46266281e922f6d872ba1833bdcd7b634cce83202e2`.

Remote main was fetched and confirmed to be an ancestor before publication.
Release publication uses an annotated tag and a normal fast-forward push. No
printer deployment, restart, control action, live database access or image
mutation was part of packaging. Optional hardware, current performance and
production restart behavior retain the verification limits recorded above.

## 2026-10-21: integration audit and minor release v0.2.0

Requested by the user: integrate local branches and clones, preserve drafts,
clean obsolete workspaces, and cut a minor release. The current published
checkpoint was v0.1.5 (`861c6af`); its push and release assets were already
complete. This release changes package metadata and documentation only.
The reviewed daemon source remains unchanged from that checkpoint.

Forty scratch repositories were inventoried. Their intended changes were already
incorporated or superseded by the reviewed source and ledger entries above.
All repository refs were preserved in verified Git bundles; non-cache working
files were also archived with SHA-256 manifests before 38 inactive clones were
removed. The intentionally dirty `deadline-before` negative fixture and the
small Git probe fixture remain in place. Vendored sources and active/shared
workspaces were retained. Preservation records live outside the repository at
`../.integration-archive/20261021/preservation.json`.

Verification: the version-matched standalone Debug artifact passed 1717 tests,
with one hardware-gated skip, zero failures and 325 discovered bounded fuzz
harnesses. The ordinary build runner timed out at its documented 220-second
limit. A separate run of the prior v0.1.5 test artifact had one simulated-Klippy
connection failure; the version-matched full run passed. The scanner and
measurement suites passed 88 Python tests with all three language grammars.
Formatting and diff checks passed. The release API dump registers 123/123
endpoints, 130/130 methods and 27/27 notifications.

The external 54-event golden replay reports seven mismatches on both v0.2.0
and the published v0.1.5 binary. Detailed comparison identifies two intentionally
registered optional components (`octoprint_compat`, `update_manager`), the
harness's checkout-prefix path normalization, and a USB device count of 26
instead of the captured 32 with identical key schemas. The strict oracle and
original capture were retained; this replay is not reported as passing.
Graphify is unavailable. No fresh performance measurement or physical optional
device test is claimed.

Static ReleaseSmall binaries built for x86-64 Linux musl and Cortex-A7
ARM hard-float. JSON package identity is `0.2.0`. Checksums:

- ARM: `5bb67a878c91f5fe16676460785ddafe61e42ab7b7e3bc75d0d587e75c58d370`.
- x86-64: `003602f417a90d8146267f5e95d6c6aad7e9e2c10bed21bdf53adf07971ac626`.

The exact ARM release binary passed a read-only probe in the existing printer
chroot on loopback port 7126, using a consistent SQLite backup and private
writable data. Klippy reached ready; twenty read requests succeeded; no
components failed; the last print was complete and both heater targets were
zero. The private probe was stopped before production installation.

## Production installation

v0.2.0 now serves `http://192.168.0.150:7125` through the existing
`/data/phobos-run.sh` launcher. Before replacement, the exact running v0.1.2
executable, previously installed binary, launcher and stopped database including
WAL/SHM files were preserved at `/data/phobos-backups/v0.2.0-20261021/`.
The launcher was replaced atomically; printer configuration and init scripts
were unchanged. Production PID 10891 maps the ARM asset checksum above.

Twenty read requests plus HTTP and WebSocket readiness/object queries passed.
No components failed; the last print remained complete and both heater targets
remained zero. The board boot ID is unchanged. Only the Phobos daemon was
restarted. The private probe and its copied data were removed. Reboot
persistence was not tested; no board reboot or printer control command was sent.
## 2026-10-21: SQLite 3.54.1 and version-matched test setup

Requested by the user: update SQLite to the latest stable version while adding
ARM variants and refreshing performance evidence. The official download and
release-history pages list 3.54.1, released 2026-10-16. The unpatched amalgamation
replaces 3.47.0. Its source ID, archive URL, archive/source SHA3-256 and file
SHA-256 values are recorded in `vendor/sqlite/README.md`. Both official SHA3
values were checked before copying the source and header into the vendor tree.
The upstream C file retains its original trailing whitespace at line 23 so its
published hash remains verifiable; first-party diff checks exclude that file.

The package version advances to 0.2.1 for these new runtime assets rather than
replacing the published 0.2.0 binaries. A regression queries the linked library's
`sqlite_version()` and `sqlite_source_id()` through the existing C bindings.
All store, migration, rollback, malformed-record and persistence tests pass.

The first complete run exposed an existing simulator setup race: the peer's
handshake signal could precede the bridge's proxy gate, causing the immediate
internal PanelDue/power test to fail with `KlippyDisconnected`. The shared test
constructor now waits for that existing gate after the simulator signal, using
its bounded connection helper. No production handshake behavior was changed.
The repeated complete standalone Debug suite passed 1718 tests, with one gated
real-Klippy skip, zero failures and 325 bounded fuzz harnesses. Commands were
`zig build test-artifact -Doptimize=Debug` and the selected standalone artifact
with `--cache-dir=./.zig-cache`, under a timeout and without a runtime filter.

Static ReleaseSmall builds passed for Cortex-A7 ARM hard-float and baseline
AArch64. The Cortex-A7 candidate SHA-256 is
`5f878845076f575756b0ba2239a82ba5e00b30ff22d6ec7634790836673957cf`.
Native Debug was rebuilt after the cross-builds. Architecture-matrix checks,
fresh host/printer performance measurements and final release evidence follow
in later entries. No deployment, live database write, printer control action,
board reboot, image mutation or QEMU execution was used for this change.

## 2026-10-21: release profiles, measured performance and v0.2.1

Requested by the user: build common ARM floating-point variants and AArch64,
refresh owned documentation/API coverage, run independent host load tests and
real-printer benchmarks, then publish a new release. The SQLite runtime update
is recorded above. Existing v0.2.0 release assets and the production installation
are preserved.

`scripts/build-release.sh` builds seven static musl ReleaseSmall profiles in
isolated scratch prefixes: ARMv6/VFPv2 hardfp, ARMv7 pure software float,
ARMv7 mixed C softfp, generic ARMv7/VFPv3-D16 hardfp, Cortex-A7 hardfp,
baseline AArch64 and baseline x86-64. ELF class, endian/machine, static linkage,
ARM argument ABI and FPU/SIMD attributes are validated, then checksums checked.
Negative checks rejected incompatible build options, wrong ELF/ABI/dynamic
artifacts, damaged checksums and output outside the scratch root. The helper
does not deploy or execute foreign targets. Native Debug was restored afterward.

The pinned compiler lowers Zig `musleabi` math through software helpers.
`-Dsoftfp=true` applies `-mfloat-abi=softfp` to all C sources, including the C
test fixture, and requires VFPv3-D32. During physical history comparisons the
initial mixed build returned zero for SQLite REAL columns. A five-case C/Zig
probe reproduced a full-LTO calling-convention mismatch: C used VFP registers
while Zig still used the base integer-register ABI. The LTO probe failed all
five bit-pattern comparisons; the no-LTO probe passed all five on the printer.
Only the mixed softfp release profile now disables LTO. The opt-in
`float-abi-probe` build step preserves that executable regression check without
building it during ordinary application builds. Its corrected probe passed
on Cortex-A7 and native x86-64. Four build-policy tests pass, including two
bounded fuzz harnesses. Six existing matrix hashes stayed byte-identical.
The corrected softfp asset is 2,803,364 bytes, SHA-256
`cec0c671958159744d421705c4afdf92cd267b52e5fa26fb02b285c4e914ce99`.

The exact Cortex-A7 and portable x86-64 asset hashes are respectively
`5f878845076f575756b0ba2239a82ba5e00b30ff22d6ec7634790836673957cf`
and `ce21f105069d049e42ce5d40b8bc12b4fb6d9ba1ebb75e27588ced86165c1a93`.
The latter matches an independent build from the SQLite candidate source.
All seven final assets passed the helper's verify-only mode and SHA-256 checks.
The five ARM32 assets also passed startup, real object queries, 20 actual
copied history rows and floating-point totals/field equality, directory
capacity and JSON package-version checks inside the Forge-X chroot. ARMv6
execution on ARMv7 is not a native ARMv6 certification. AArch64 was not run.
Exact profile hashes and hardware scope are in `docs/perf/arm32-smoke-v0.2.1.json`.

Fresh native API registration coverage remains 123/123 literal paths,
130/130 JSON-RPC methods and 27/27 notifications. The source contains 125
endpoint registration records, including two dynamic callsites; 117 records
enable HTTP, with 116 literal HTTP paths. Documentation now distinguishes
those counts from target/runtime support. Table generation/check passed;
generated API and client artifacts are byte-identical, so none was rewritten.
The client matrix retains its nine plugin/nonstandard gaps rather than
claiming behavioral completeness. Moonraker pin `900848584374` is unchanged.
The complete daemon suite is 1718 passed, one gated real-Klippy skip, zero
failed and 325 bounded fuzz harnesses, as recorded in the preceding entry.
All 100 Python scanner/measurement tests pass with the documented language
grammars installed. An initial combined invocation omitted the TypeScript/C++
grammars; that was a test-command dependency error, not a scanner code failure.
Ruff, Black, explicit-package-base type checks and the complete shell-helper
smoke checks pass. Zig formatting and first-party whitespace checks pass.

Fresh host benchmarks used the exact portable x86-64 ReleaseSmall asset and
full pinned Moonraker on Python 3.12.12/Tornado 6.5.5/SQLite 3.50.4, sharing
one Klippy stub and equivalent seeded independent SQLite fixtures. The host
was Ryzen 9 9950X, 16 cores/32 logical CPUs, CachyOS Linux 7.2.10-1-cachyos.
No cross-compile or printer load generator ran during this quiet window.
Thirty ten-second measured trials all returned successful HTTP status,
3,796,280 requests total. Unlimited eight-worker server-info throughput had
trial medians 109,645.7/s for phobos and 11,065.6/s for Moonraker. At matched
5,000/s the median trial p99 was 0.178 ms and 0.833 ms. Those are complete
loopback workloads with different response sizes, not server-only ceilings.
The independent mix excludes Klippy; a separate query workload exercises the
stub round trip. Idle RSS was 6,112 KiB for SQLite phobos, 5,448 KiB for its
file backend and 59,468 KiB for full Moonraker. Samples and limitations are
in the current PERFORMANCE/MEMORY reports and checked-in JSON summaries.

The first host attempt exposed a report-format bug: actual Vegeta 12.13 uses
`50th`/`99th` percentile keys, while the formatter and fake fixture expected
`50`/`99`. The formatter and fixtures now use the real schema, with a regression
test. The incomplete attempt was discarded from comparison, and all 30 trials
were restarted. The plotter now accepts measured JSON, validates matched
workloads/repetitions, shows trial ranges and writes portable input hashes.
Old hardcoded graphs and unresolved-symbol flamegraphs were removed from the
current report; Git history retains them. Five new figures were visually checked.

The physical comparison ran published v0.2.0 and the exact v0.2.1 Cortex-A7
asset sequentially on loopback 7126 inside Forge-X 1.4.2/Linux 5.4.61, two
Cortex-A7 cores and 110,404 KiB RAM. Production v0.2.0 stayed on port 7125.
Independent database/WAL copies were made from a stable snapshot without
opening the live database for write. Automatic queue loading/transition and
update refresh were disabled. Forty-two eight-second read trials completed
with 100% HTTP success. The controller used SSH/WiFi, so timings include that
transport; the bounded eight-worker mix at requested 100/s reached about 83/s.
No speedup/regression claim is made from these short networked trials.
Candidate idle RSS was 3,100 KiB, sampled peak load RSS 5,056 KiB; board
MemAvailable remained at least 49,540 KiB. Production readiness, print state,
heater targets and a 16 MiB available-memory floor were checked throughout.
No second full Moonraker was started on this small board.

The private printer directory, copied databases and owned binaries were removed
after stopping all probe/sampler processes; the SSH tunnel was closed. No 7126
listener remains. Production PID 10891 still maps `/data/phobos-v0.2.0`.
Final HTTP checks report Klippy ready, no failed components or warnings, last
print complete, extruder 31.27 C/target 0 and bed 30.23 C/target 0. Boot ID
`6213a6c1-a3b6-4b38-b637-5aa9a116a117` is unchanged. No motion, heating,
print start, update, Klipper restart, firmware restart, host power action,
board reboot, live configuration change, golden-image mutation or QEMU was used.

Remaining differences are documented as identity (API 1.5.0, phobos software
version and Python stub), deliberate behavior (empty CAN discovery, optional
registered components and no-op power actions), or environment (host CPU,
kernel, device set and filesystem). The mixed-softfp ABI mismatch and Vegeta
formatter failure were code/build bugs and are fixed. Feature limits remain
listed in TODO and the release notes. Long soaks, large transfers and optional
peripheral hardware were not benchmarked anew. `graphify-out/graph.json` exists,
but `graphify` is absent from PATH, so its update was skipped; that directory
is not a release deliverable. v0.2.1 contains these verified changes and seven
binary profiles; it is not installed on the printer.

The user additionally requested explicit better-direction labels. Every new
figure now says higher is better for throughput, lower is better for latency
and RSS, or lower at matched throughput is better for CPU. Tables repeat those
directions and identify measured host winners. Printer results explicitly state
that the short transport-sensitive comparison has no clear overall winner.
The 22 measurement-tool tests pass after the label update.

## 2026-10-21: production v0.2.1 and hosted build/release checks

Requested by the user: deploy v0.2.1 and provide CI for builds and releases.
The printer was ready, the last print complete and both heater targets zero
immediately before installation. The exact downloaded Cortex-A7 release asset
was checked against SHA-256
`5f878845076f575756b0ba2239a82ba5e00b30ff22d6ec7634790836673957cf`.
The previous running executable and launcher were copied to
`/data/phobos-backups/v0.2.1-20261021T040155Z/`. After the old daemon stopped,
the database and any remaining WAL/SHM files were copied through the chroot
paths. The new executable and launcher were installed by rename. No printer
configuration or init script was changed, and no board/firmware/Klipper restart
was sent. PID 2243 now serves port 7125 from `/data/phobos-v0.2.1`; its hash
matches the published asset. Twenty read-only HTTP checks and three WebSocket
checks passed, including live objects and directory capacity. Klippy is ready,
there are no failed components or warnings, the last print remains complete,
heater targets are zero and boot ID `6213a6c1-a3b6-4b38-b637-5aa9a116a117`
is unchanged. Boot persistence was not tested.

The repository had no hosted workflows. `.github/workflows/ci.yml` now checks
main pushes, pull requests, annotated version tags and manual dispatches.
Compiler archives are pinned to Zig 0.17.0 and official SHA-256 values for
x86-64/AArch64 Linux. Python 3.12 development dependencies and transitive
hashes are locked by `uv.lock`. Workflow actions use full commit references;
ordinary jobs have read-only repository access and checkout does not retain
credentials. Only the final tag publisher can write repository contents.

CI runs formatting, build-policy tests, vendored SQLite source hashes, all
Python tool tests, API registration and generated-table checks. It runs the
complete daemon suite in x86-64 Debug/ReleaseSafe and native AArch64
ReleaseSafe. Each of the seven release profiles builds and validates separately.
Exact x86-64/AArch64 assets and C/Zig floating-point probes execute natively.
All profile artifacts are combined into a checked release bundle. Tag
publication requires matching package/versioned notes, an annotated tag at
the checked commit and reachability from main. Only a tag-push event publishes.
The publisher first uploads a draft, downloads its assets, checks ELF/checksums
and both manifests, then publishes. Existing releases are never clobbered.
CI has no printer credentials and performs no physical deployment or QEMU work.

The test-artifact build step now installs `bin/phobos-tests` under its chosen
prefix. `scripts/test.sh` runs that exact artifact under a timeout instead of
selecting a cached file by modification time or using the build-listen runner.
Local Debug verification passed 1718 tests, one gated skip, zero failures and
325 bounded fuzz harnesses. Four build-policy tests pass, including two fuzz
harnesses. All 109 Python tests pass, including nine new release preparation
checks for complete assembly, corrupt/missing data, profile/version/name
validation, output containment and release-note targets. The tests caught an
asset-name regex that omitted the x86-64 underscore and an invalid dotted
repository owner; both were fixed before CI publication.

Local release preparation assembled the seven exact published artifacts and
passed the existing ELF/ABI/checksum verifier. Zig formatting, Bash syntax,
ShellCheck/actionlint, Ruff, Black and the changed Python tools' type checks
passed. The CI installer downloaded and verified the official x86-64 compiler
archive successfully. Hosted workflow results are verified after pushing these
workflow files; these local checks do not claim hosted execution in advance.

The first hosted check passed all 109 Python tests and lint/type gates, then
failed the shell smoke step because the Ubuntu image lacked `rg`. The checks
job now installs ripgrep and ShellCheck explicitly and lints the shell helpers;
the smoke requirement was preserved.

## 2026-10-21: hosted fixture progress and failure cleanup

Continuing the requested build/release CI verification, hosted run 39544079023
exposed two fixture bugs. Bash 5.2 inherited the failed measurement's exit status
through a bare `return` in `stop_child`, so errexit stopped cleanup after the
first child. Returning explicit success preserves cleanup of the remaining
owned children. A focused two-child EXIT-failure fixture now runs in the smoke
suite. The full smoke suite passes with Ubuntu's Bash 5.2.21 as well as the host
shell; ShellCheck and actionlint pass. Expensive CI tests now depend on the fast
checks job, and every shell fixture is included in ShellCheck.

All three hosted daemon suites timed out at the MQTT HTTP integration test.
`Io.async` can run inline after the CPU-based async worker budget is exhausted;
the fixture's blocking accept loop therefore prevented initialization from
returning on two-core runners with MQTT workers already active. The HTTP fixture
now requests `Io.concurrent`, closes its listener if scheduling fails, and sets
its async budget to zero so this mistake cannot be hidden by a larger host.
Its WebSocket emitter also requests concurrent progress. The existing MQTT HTTP
test reproduced the old hang under `taskset -c 0,1` with an eight-second timeout;
the fixed fixture passed the same compiler-filtered test under two CPUs.

Full-suite execution also exposed nondeterministic allocation counts in the
MQTT status failure fixture. An outer `FailingAllocator` rejects resizing and
remapping so arena growth must allocate consistently. The test still injects
each allocation failure and checks all releases through the testing allocator;
the ReleaseSafe compiler-filtered regression passes. No production MQTT logic
or CI gate was disabled.

## 2026-10-21: bounded temperature-store allocations

Requested by the user: reduce memory further and assess the local MISRA-Zig
rules. `DataStoreCtx.ensureSensor` now allocates target, power and speed rings
only when those fields are reported or already tracked. `putRing` reserves the
exact JSON array length and reads chronological deque entries directly. The
handler's full-capacity floating-point scratch allocation and repeated array
growth are removed. Sampling cadence, configured capacity, rounding, late-field
history and optional response fields are preserved.

Two allocation regressions were run before the fix and failed, along with the
new unused-buffer assertion in the existing bounded fuzzer. Identical x86-64
inputs under `std.testing.FailingAllocator` requested 39,909 bytes before and
11,109 after for a plain sensor. A wrapped full 1,200-value response retained
135,816 bytes before and 100,872 after in its request arena. The regression
budget is architecture-aware and also checks first/last samples and late fields.
The Forge-X field layout removes eight unused 1,200-element f64 rings, a
calculated 76,800 bytes of payload. These allocation figures are not RSS claims.

The static Cortex-A7 ReleaseSmall candidate SHA-256 is
`999bcbe75d4bd73f01009f3d76af537e47fb59918267dbe35160b4af2eb51503`.
It and the published v0.2.1 asset ran separately inside the Forge-X 1.4.2 chroot
on loopback 7126, using separate copies of the existing probe database, equal
settings and disabled automatic updates/queue actions. Each matched 20-second
read probe returned all four expected sensor field sets, about 20 new samples
and valid directory capacity. Median RSS over the final ten of 21 samples was
2,984 KiB baseline and 2,712 KiB candidate. This is one short pair, not a general
RSS guarantee or a full-window hardware soak. Exact sample/field counts and
hashes are in `docs/perf/temperature-memory-20261021.json`.

Both private probes stopped and their owned data directory was removed after
capturing logs. Production v0.2.1 PID 2243 stayed on 7125 with its published hash,
Klippy ready, no failed components or warnings, the last print complete and
both heater targets zero. The board boot ID remained
`6213a6c1-a3b6-4b38-b637-5aa9a116a117`. No printer controls, board restart,
live-database connection or production configuration changes were used.

The local MISRA-Zig handbook's rules 21.3/22.1/22.2 support explicit allocator
ownership and balanced resource release. Its checker failed to compile with
Zig 0.17 at `tools/misra_lint.zig:480` (`asterisk_asterisk` token), so the review
was manual and claims no compliance. No files in that project were changed.
History's load-all-before-pagination path remains a measured-next candidate;
its backend semantics were not changed without a matching fixture.

Final local Debug and ReleaseSafe standalone suites each passed 1,720 tests,
one existing real-Klippy skip, zero failures and 325 bounded fuzz harnesses.
Four build-policy tests and all 109 Python tests pass. The host Debug executable
was rebuilt after the isolated ARM build. Formatting, ShellCheck, actionlint,
the Ubuntu Bash 5.2 smoke suite and the fresh API/table checks pass: 123/123
endpoints, 130/130 methods and 27/27 notifications. Generated coverage docs
needed no edits. `graphify-out/graph.json` exists but `graphify` is unavailable,
so no graph update was run or treated as a deliverable. Hosted CI is rerun on
the pushed fixes; publication remains restricted to a future annotated tag.

The next hosted run (39546487029) passed checks and both x86-64 suites, but its
ReleaseSafe log showed 1,718 passed and three skipped: the real-Klippy fixture
plus the two TLS fixtures because socat was absent. The daemon jobs now install
OpenSSL and socat explicitly, preserving execution of certificate/hostname and
MQTT TLS checks. Local suites already had these peers and passed those tests.
This dependency correction changes no daemon code or skip conditions.

The AArch64 daemon suite also passed 1,718 tests with the same three skips;
the job failed afterward because setup-uv tried to save a dependency cache
that a Zig-only job had never created. Dependency caching is disabled in the
shared setup action so Zig-only jobs have no Python cache post-step dependency.
Actionlint passes after both workflow corrections. Native AArch64 execution
found no daemon failures in that run.

Hosted run 39547485348 executed both TLS fixtures successfully on x86-64 and
AArch64. ReleaseSafe on both architectures exposed a file-listing fixture that
assumed the real directory was visited before its in-root alias. `RootWalker`
deliberately keeps the first canonical directory it encounters, as the adjacent
linked-directory test already permits. The fixture now accepts either complete
representative path set while still asserting exact count, sorted paths,
deduplication, every file size and linked-file permissions. Escaping/dangling
link checks and copy-content checks are preserved. The ReleaseSafe
compiler-filtered regression passes locally. Production traversal is unchanged.

Profile builds now run independently of daemon suites after checks pass, so
cross-compilation does not wait on unrelated test compilation. Packaging has an
explicit dependency on all suites as well as builds and native smoke checks;
any failure still blocks both the combined bundle and tag publication.
Actionlint validates the revised dependency graph.

## 2026-10-21: history-page and encoded-record allocation reduction

Continuing the user's memory/performance goal, the copied printer database has
266 legacy history rows. An exploratory optimized, symbolized host CPU profile
of the independent read mix found allocation, resizing and copying dominating
the populated-history path. Unfiltered SQLite history pages now order scalar
IDs first and decode only selected records. KV shadows preserve migrated-row
precedence. Noncanonical/non-object KV data, time filters and other backends
retain the namespace path. SQLite record reads decode the column before
finalization rather than retaining a duplicate encoded blob; the returned JSON
owns its strings. No database schema or wire format changed.

Both allocation regressions failed before the fixes. The 20-job page from 200
KV jobs with 4 KiB payloads retained 1,396,192 bytes before and 235,698 after;
one 64 KiB JSON read retained 393,638 before and 149,834 after. These are native
request-arena bytes, not RSS. The SQLite read fixture verifies owned payloads
after replacing the database record. Real-handler differential tests exercise
legacy/KV precedence, filters, both orders, negative/large offsets, unlimited
queries, noncanonical keys, non-object values and corrupt JSON. The new store
operation also passes allocation-failure injection and bounded differential
fuzzing. Debug and ReleaseSafe each pass 1,725 tests, one real-Klippy skip and
zero failures, with 326 fuzz harnesses. API registration remains 123/123
endpoints, 130/130 methods and 27/27 notifications.

The profiling build flag previously suppressed LTO with symbols. It now retains
the selected release LTO policy, including the existing mixed softfp exception;
Debug still disables LTO. Four build-policy tests, including two fuzz harnesses,
pass across all optimization modes. The profile helper now uses ReleaseSmall,
user-space cycle sampling, a load warmup, load-process completion and a nonempty
100%-success gate. It retains load reports, flat CPU reports, raw/folded stacks
and the SVG. Smoke tests cover both profiler branches and rejection of failed
loads/requests; ShellCheck and the full smoke suite pass.

A private Forge-X Moonraker smoke probe reached Klippy-ready on loopback 7126
and returned 20 history records using a copy of the existing probe database.
Its RSS was about 35 MiB and board available memory remained above 16 MiB.
The probe used owned config/log/gcode directories, no update components and
disabled queue transitions. Its chroot Python symlink initially prevented the
owned-process stop check; resolving that symlink inside the chroot corrected
cleanup and the probe stopped. Production phobos stayed ready on 7125 and the
boot ID was unchanged. `/proc/config.gz` reports `CONFIG_PERF_EVENTS` disabled,
so hardware comparisons use process CPU/RSS counters; resolved CPU sampling is
performed on the host. Final matched load measurements follow these fixes.

The host permits self-launched user-cycle counters but restricts attachment to
another process. `PERF_SUDO=1` therefore elevates only perf collection/decoding;
the owned server and generator keep the caller's identity. No host profiling
sysctl or capability was changed. The helper documents this mode and its smoke
fixture uses a sudo command double to check argument forwarding and cleanup.
ShellCheck and the complete helper smoke suite pass with the new mode.

## 2026-10-21: avoid preparing JSON validation for empty history

The controlled memory/performance study exposed avoidable SQL preparation in
the page path even without KV history. The query now selects key/value only;
`std.json.validate` checks actual KV bytes before selecting the fast path.
The malformed-record differential test remains, and the allocation-failure
fixture now includes a nested KV record as well as migrated rows. Debug and
ReleaseSafe each pass 1,725 tests, one real-Klippy skip and zero failures,
including 326 bounded fuzz harnesses. The 200-KV-job allocation fixture retains
235,146 bytes in Debug and 235,578 in ReleaseSafe; the 64 KiB read retains
149,834 in both. Formatting and diff checks pass.

Following the user's MISRA-Zig suggestion, the current local checker compiled
with Zig 0.17 and scanned all 80 source files. Its 2,339 syntax findings include
tests and arena-owned allocations. The handbook's explicit ownership, bounded
input and matching-free rules informed this review; syntax findings were not
treated as confirmed bugs or a compliance score. Memory documentation records
the checker update, allocation measurements and the remaining full-history
fallback costs. No unrelated rule rewrites were made.

## 2026-10-21: preserve nullable migrated history end times

The real-printer comparison found two records in the first 20 whose SQL NULL
end times became zero. The shared SQLite row mapper now checks the column's
storage class before reading a double. The existing minimal SQLite binding
adds `SQLITE_NULL` and `sqlite3_column_type`, matching the vendored header at
lines 5408 and 5638. No schema or stored value changed.

The new regression failed with `0` instead of `null` before the fix. It checks
NULL, real zero and a fractional timestamp through single reads, namespace
reads, pages and the public history filter handler. The bounded differential
fuzzer now includes nullable times and `before` filters. Debug and ReleaseSafe
each pass 1,726 tests, one real-Klippy skip and zero failures, with 326 fuzz
harnesses. Formatting and API coverage pass (123/123 endpoints, 130/130 methods,
27/27 notifications). The host Debug executable was restored after the isolated
Cortex-A7 ReleaseSmall build.

The final static ARM binary has SHA256
`c3afd1bcdb905ccb2661689d2e1762550c4dc67fa3670ecfd61bf0c5388cb755`.
Private chroot probes on loopback 7126 match the actual Forge-X Moonraker in
seven semantic response comparisons: default and ascending pages, a huge
offset, `since`, `before`, all 266 jobs and one unfinished job. All seven null
end times survive; `before` returns 259 completed rows. The portable parity
record stores counts and response hashes, not private job payloads. Both
probes stopped, production remained ready with zero heater targets, and the
board boot ID stayed unchanged. A final load comparison follows this fix;
the earlier optimized host CPU profile remains tied to commit a6a3aef.

## 2026-10-21: final memory, load and profiling report

The user's memory/performance goal now has a final-build Cortex-A7 comparison
with actual Forge-X Moonraker, and separate versioned host/profile captures.
The final f34d601 printer study contains 45 eight-second trials, 12,240
successful requests and three fresh-process repetitions per backend. The
75/s independent mix uses 4.883 ms CPU/request versus 10.783 in 39386ca and
12.050 in Moonraker, reductions of 54.7% and 59.5%. Maximum sampled load RSS
is 3,532 KiB versus 4,792 and 37,080. Each process starts from the same private
266-job seed and 64 KiB record, common core config and disabled queue actions.
Minimal-config component/default differences, the stronger credential-list
policy, Python/API identity and private-path warnings are explicitly classified.
The final candidate matches Moonraker's history responses in every repetition;
the baseline retains its documented nullable-time bug.

The a6a3aef host study retains all 57 trials and 803,711 successful requests,
including three under-rate trials and unfavorable empty-store CPU results.
External desktop contention prevents an isolated-host performance verdict.
The earlier adaptive same-binary control is recorded as a different protocol,
not used as an uncertainty bound. Both matched ReleaseSmall/LTO CPU profiles
use the same populated fixture at 1,200/s, frame pointers, 1,999 Hz user-cycle
sampling and a 30-second window. There are zero lost samples; unknown leaf
cycle weights remain 2.08% and 1.98%. Flat reports, SVGs, hashes and load
reports accompany the summaries. The real maintained profile helper also
completed its five-second capture with 10,800 successful requests and cleanup.
The embedded FlameGraph plotting code retains its CDDL notice/license.

Memory/performance docs now identify source commits, units, better-direction
labels, repetition ranges, actual rates, CPU/request, sampler resolution,
smaller probe configuration and retained limitations. README links to those
versioned results; TODO names the exact test-artifact runner. The harness
documents owned private Moonraker setup and its initial-refresh behavior.
Portable JSON, figures and mismatch classifications are published without
database files, private job bodies, raw load binaries or perf.data. JSON,
success/count/parity checks, plot-input hashes, PNG signatures, Markdown links,
formatting and diff checks pass. Plots and flamegraphs were visually inspected.
The final local MISRA checker scan covers 80 files with 2,342 syntax findings;
it is a memory-review input, not a compliance or defect-count claim.

The code CI run https://github.com/maci0/phobos/actions/runs/39571925685 passed
all suites, seven build profiles, native x86-64/AArch64 smoke and packaging.
Debug and ReleaseSafe each pass 1,726 tests, one real-Klippy skip and zero
failures, with 326 bounded fuzz harnesses; API coverage remains complete.
No further source edits followed those gates. The host Debug binary is restored.

All private probes, samplers and tunnels stopped. The owned printer work
directory was removed after verifying its marker, absent PIDs, closed 7126
listener and unchanged boot ID. Eight production reads passed at final verification.
The final counter snapshot records 62,040 KiB available board memory and
production VmRSS/VmSwap of 2,712/1,192 KiB; board free swap reached zero during
the final study. Probe-only RSS is not a claim that the board or production
stayed fully resident. No swap settings changed. Production remains the
published v0.2.1 executable as PID 2243, with matching SHA256, Klippy ready,
print complete and zero heater targets. No printer-control action, live
database mutation, configuration change or experimental deployment occurred.

`graphify-out/graph.json` exists, but `graphify` is not on PATH, so its update
step was skipped. The graph output is not part of the deliverable.

## 2026-10-21: tuning round 1, reuse the page's legacy-row lookup

First of the user's three additional tuning rounds. The profile's remaining
SQL preparation work corresponds to repeated KV misses, table-existence checks
and legacy-row statement preparation for every selected table job. The page
reader already knows each selected job's source under its store lock. It now
reuses one lazily prepared table lookup for the page and uses the mapped row's
existing key. The statement is reset between rows and finalized on every exit;
KV reads retain their existing path. No persistent cache or schema change was
added. `sqlite3_reset` matches the vendored header at line 5705.

A mixed KV/table regression verifies all response payloads after statement
resets and subsequent database replacement. The differential fuzzer includes
several legacy rows, KV shadows and nullable times; allocation-failure coverage
now crosses two legacy rows. Debug and ReleaseSafe each pass 1,727 tests,
one real-Klippy skip and zero failures, with 326 fuzz harnesses. Formatting and
diff checks pass. Portable x86-64 and Cortex-A7 ReleaseSmall builds complete in
isolated prefixes. Baseline runtime is 0ec73fa; matched measurements follow this
verified code change and will retain the build hashes and actual source commits.

## 2026-10-21: tuning round 2, retain scalar history keys

The user requested three further rounds after the interrupted tuning session.
This first resumed round replaces duplicated canonical KV key strings in the
history index with numeric IDs and a source flag. Selected keys alone are
formatted. The 1,028-record allocation regression failed before the change
(186,830 retained bytes) and passes afterward (95,326). Zero, signed-range
boundaries and maximum unsigned IDs are checked; the differential fuzzer now
also includes the maximum unsigned key. Existing allocation-failure coverage
crosses both sources.

The interrupted Debug log ended with a login timeout without a final summary.
The isolated wrong-password test passes, and a complete rerun passes without
changing authentication or deadlines. Debug and ReleaseSafe each pass 1,728
tests, one existing real-Klippy skip, zero failures and 326 fuzz harnesses.
The interrupted timeout's cause remains unconfirmed. Matched portable and
Cortex-A7 ReleaseSmall binaries are frozen for the subsequent measurements.

## 2026-10-21: tuning round 3, reserve legacy row fields

Second resumed round requested by the user. `mapJobRow` now reserves its 11
known fields through `ObjectMap.ensureTotalCapacity` before allocating column
strings and metadata. No field, ownership rule or SQLite operation changes.
The 200-row regression checks all IDs, field counts, payloads and SQL nulls.
Its 768 KiB budget fails before the change at 858,758 bytes and passes afterward
at 517,988 bytes. Existing page allocation-failure injection and the differential
fuzzer cover the new reservation failure.

Debug and ReleaseSafe each pass 1,729 tests, one real-Klippy skip, zero failures
and 326 fuzz harnesses. Portable and Cortex-A7 ReleaseSmall builds complete.
Formatting and diff checks pass. Matched timing measurements follow this
verified source commit; production remains unchanged.

## 2026-10-21: tuning round 4, reuse SQLite's override index

Third resumed round requested by the user. The history page reader no longer
duplicates canonical KV IDs in a hash map. With KV rows present, its legacy ID
query excludes overridden rows through the existing namespace/key primary key.
Legacy-only pages retain the original simple query. SQL `%06llX` matches the
canonical key format without truncating 64-bit legacy IDs. A new regression
checks overrides above 32 bits and at the signed maximum; the differential
fuzzer includes a maximum signed table ID with optional KV replacement. Existing
allocation-failure injection covers both query paths. The 64 KiB key-index
budget fails before the change at 95,326 bytes and passes at 43,992 bytes.

Earlier response-container experiments were rejected. The 200-row response
retained 1,196,070 bytes before, 1,196,412 with `ObjectMap.clone`, 1,196,640 with
exact field reservation and 1,196,070 with an exact response-array reservation.
None reduced arena backing storage for that fixture; none of those source
changes is retained.

Debug and ReleaseSafe each pass 1,730 tests, one real-Klippy skip, zero failures
and 326 fuzz harnesses. Portable and Cortex-A7 ReleaseSmall builds complete;
the ARM binary is static ELF32 ARM EABI5 with hard-float ABI. Formatting and
diff checks pass. Timing, mixed-store and physical validation follow this
verified source commit. Production remains unchanged.

## 2026-10-21: verify and publish three resumed tuning rounds

The user's three further rounds are complete: scalar key selection `68a36ef`,
legacy JSON field reservation `720f5c1` and indexed override exclusion
`296526e`. `docs/PERFORMANCE.md` and `docs/MEMORY.md` distinguish deterministic
arena reductions from variable CPU, latency and RSS measurements. Retained
key-index storage falls 186,830 → 95,326 → 43,992 bytes; the separate legacy-row
fixture falls 858,758 → 517,988. Rejected response-container experiments remain
recorded above.

Matched ReleaseSmall host runs cover 102 trials and 723,560 requests for these
three rounds, all successful, with six-query parity preflights at every
startup. The first R2 KV timing regression is retained alongside its stable
six-trial repeat. R4 mixed-store CPU medians are equal; latency and RSS
regressions are retained. The preceding statement-reuse round's 30 trials are
also archived. Source commits, executable hashes, seed hashes, CPU affinity,
load reports and full metric ranges are stored under
`docs/perf/history-tuning-20261021/`. SVG/PNG charts were inspected; all metric
directions are labeled. These are allocation improvements, not universal CPU,
RSS or latency wins.

Physical validation runs the four frozen ARM executables in the Forge-X
chroot, bound only to loopback 7126, against copied data. All 36 trials and
12,960 requests succeed; all 72 history comparisons match. A report-label bug
in the scratch harness was fixed, and saved responses were independently
compared after the completed captures. An additional mixed-store seed initially
copied stale main-file contents while its edits remained in a WAL sidecar.
Closing the private SQLite connection before copying and checking the remote
file hash corrected the harness. The corrected ARM check passes all 12
comparisons, including wide IDs and 268 expected visible jobs. Neither harness
failure changed production or required a phobos code change.

The 16 MiB memory floor and ready/idle/zero-target guards remained satisfied.
Minimum sampled available memory is 57,088 KiB; probes report no swapped pages.
Existing production swap is reported separately. Owned probes and their
directory are removed. Final production remains v0.2.1 as PID 2243 with the
same executable hash and boot ID, ready, print complete and both heater targets
zero. Port 7126 has no listener. No reboot, printer control, live database
mutation, swap adjustment or experimental deployment occurred.

Final Debug and ReleaseSafe each pass 1,730 tests, one existing real-Klippy skip,
zero failures and 326 fuzz harnesses. The host Debug binary is restored after
cross-compilation. API coverage passes at 123/123 endpoints, 130/130 methods and
27/27 notifications; the generated table check passes without regeneration.
Formatting and diff checks pass. `graphify` remains unavailable, so its update
is skipped and graph output is excluded.

## 2026-10-21: prepare v0.2.2

The user requested a new release and printer installation. Advance the package
version and README release link to v0.2.2 and add versioned notes for changes
since v0.2.1: lazy temperature fields, paged history reads, owned JSON decoding,
nullable legacy end times, scoped statement reuse, scalar keys, field-map
reservation and indexed override exclusion. Notes retain identity differences,
feature limits and measured timing/RSS regressions. SQLite, compiler and
Moonraker pins do not change.

Source commit `7b70f96` passed local Debug/ReleaseSafe (1,730 passed, one skip,
326 fuzz harnesses), API/table gates and complete CI run 39604186802, including
all seven profiles, three native suites and both native release-asset smoke
checks. Release metadata and packaging checks are repeated for the new version
before the annotated tag. Initial production inspection finds v0.2.1 ready,
print standby and both targets zero, with boot ID unchanged. Deployment will
use the published Cortex-A7 asset, preserve the old executable/launcher and
copy the stopped database before replacing the daemon. No board or Klipper
restart is part of installation.

The version-matched host Debug binary reports 0.2.2. Fresh API coverage remains
100%, the generated-table check passes, and all nine release-helper tests pass.
Relative release-note links resolve through the packaging helper. Formatting
and diff checks pass. Full native suites and all release profiles are required
again by main/tag CI before publication.

## 2026-10-21: publish and install v0.2.2

At the user's request, release commit
`b079b773823c0d655823f91c1d08f0f96a67ad39` and annotated tag `v0.2.2` were
pushed without rewriting history. Main CI 39612767322 passed; tag workflow
39614476733 completed its required checks, builds, native suites, native
asset smoke tests, packaging and publication. The public release contains
seven static Linux assets plus profiles and checksums. All downloaded assets
pass `scripts/build-release.sh --verify-only`; the official Cortex-A7 asset
matches the tag-produced executable already exercised inside the chroot.
Release source validation is 1,730 passed, one gated real-Klippy skip, zero
failures and 326 fuzz harnesses in Debug/ReleaseSafe; API/table gates remain
123/123 paths, 130/130 methods and 27/27 notifications. No API regeneration or
runtime code change is part of the later documentation update.

The user authorized installation on 7125 and use of the normal database.
Before switching, readiness/standby/zero-target and queue guards passed.
The exact old running binary and launcher were saved; after terminating only
the verified old daemon, its stopped database and any WAL/SHM files were
copied under `/data/phobos-backups/v0.2.2-20261021T142806Z/`. The new launcher
executes `/data/phobos-v0.2.2`, the official Cortex-A7 SHA256
`94737315462468de6ec1fa54cb86c46c4127f5918b452c532c0311606ed56290`.
PID 29180 owns the production listener on 7125. It passes 29 HTTP and six
WebSocket reads, including directory capacity, history filters/order, persisted
floats, temperature and console stores. All 26 components are healthy with
no warnings, 270 jobs and seven nullable end times. The board boot ID remains
`6213a6c1-a3b6-4b38-b637-5aa9a116a117`. No board or Klipper restart was used.
The private installation probe on 7126 was stopped and its owned directory
removed. Release/build docs now distinguish current validation from older
ARM32 smoke evidence. Public release notes link to current documentation on
main; the release tag and binary assets are unchanged.

## 2026-10-21: current benchmarks compare v0.2.2 with Moonraker

The user requested that current benchmark tables and graphics contain only
the latest release and Moonraker. `docs/PERFORMANCE.md`, `docs/MEMORY.md`, the
README, build/release notes and harness guide now point to a fresh versioned
capture under `docs/perf/v0.2.2/`. Earlier captures remain unchanged archives,
including negative results, and are excluded from current figures. All twelve
figures use the maintained plotter and record their input hashes. Higher
throughput and lower latency/RSS/CPU per request are explicitly labeled.

Both phobos executables are unmodified published ReleaseSmall assets. The
x86-64 SHA256 is `f81657748202cec356e841b7409371de4d74104cdac95e39c99c2a739079022d`;
the physical Cortex-A7 hash is the installed hash above. Host Moonraker stays
at pin `9008485843740c93e0154ccbdac1fc2b02b03aaa` on Python 3.12.12. The printer
reference is the actual Forge-X 1.4.2 Moonraker on Python 3.11.10, whose entry,
history and database module hashes were reread. Config and seed hashes, process
sampling periods, worker limits and repetition order accompany each capture.
Every backend restores independent inputs. The populated seed has 266 legacy
jobs plus the same 64 KiB item; empty host stores contain the item only.

Forty-two eight-second host trials produce 643,189 successful requests; thirty
eight-second printer trials produce 8,159 successful requests. Three fresh
process repetitions alternate backend order and reverse workload order in the
middle repetition. No compilation or simultaneous benchmark ran during timed
host capture. Servers/generator/stub/controller have fixed host affinity, but
the shared desktop CPUs are not exclusive. Host preflights include unlimited
history before idle measurement. Seventy-two host history checks and all 24
physical history comparisons pass. Fresh seven-endpoint physical preflights
retain only the documented identity, capability/default, namespace-policy and
private-path warning differences; no new code bug is observed in that scope.

Printer median idle RSS is 3,044 KiB for v0.2.2 and 36,696 KiB for Moonraker;
maximum sampled load RSS is 3,500 and 36,816 KiB. At 75/s, median CPU time per
request is 3.017 versus 11.850 ms (74.5% lower). One phobos 64 KiB trial delivers
8.96/s against 10/s despite all requests succeeding. Host populated 1,200/s
mix median p99 is worse for phobos (1.58 versus 0.96 ms); all trial ranges
remain visible. Available board memory stays above 23,960 KiB with the 16 MiB
stop guard. Probe swap stays zero, board SwapFree ranges 3,072 to 11,552 KiB,
and production VmSwap ranges 0 to 428 KiB. No swap control or cache adjustment
was used. The printer kernel has no perf events; no sampled device CPU profile
or isolated-host/long-soak guarantee is claimed.

After removing the owned benchmark probes/directory and SSH tunnel, the final
29 HTTP/six WebSocket production checks pass again. PID, release hash and boot
ID are unchanged; ready, standby, targets zero, no 7126 listener. The final
record reports 3,352 KiB production RSS, 140 KiB production swap, 57,612 KiB
board MemAvailable and 3,328 KiB SwapFree. No benchmark opened the live database
or sent printer-control commands. The rollback snapshot remains available.

Verification: all 31 performance/release Python tests and measurement-helper
smoke tests pass. Independent checks validate all 72 trials and 651,348
successful requests, aggregate calculations, exact executable and plot-input
hashes, parity records, twelve current graphic links, document targets and final
printer state. Representative plots were visually inspected. `git diff --check`
passes. Graph output is excluded because `graphify` is unavailable. No source
change or additional release tag is needed for these measured documentation
updates; the post-release documentation update is prepared for a fast-forward
push on main.

## 2026-10-22: independent KVM benchmarks on the second PC

The user requested VM benchmarks with guaranteed performance and no CPU steal,
offered the Ryzen 9 5950X PC at 192.168.0.99, authorized QEMU installation and
temporary sudo access, and prohibited printer access. No printer was contacted.
`docs/PERFORMANCE.md`, `docs/MEMORY.md`, release/build notes, README and the
harness guide now use the complete second-PC capture for active x86-64 figures.
The versioned `VM_METHOD.md` records inputs, configuration and counter definitions.
Published v0.2.2 assets, source, tag and API coverage are unchanged.

QEMU 11.1.2 uses KVM, four FIFO vCPUs on exclusive physical cores, unused SMT
siblings, an isolated complete L3 group, 4 GiB preallocated locked RAM, no NIC
and no VM swap. Both daemons use the same guest CPU, local Klippy stub and
independent copies of populated/empty history. Forty-two matched twenty-second
trials, three fresh-process repetitions per case, produce 1,607,980 successful
requests. All 72 parsed-history checks match. The stopped guest's extracted
phobos binary matches the published x86-64 SHA256; its kernel hash also matches.

The strict zero-steal/guaranteed-performance request is not established. The
aggregate guest counter records two steal ticks; individual CPU counters round
to zero. All raw deltas remain. Maximum server-vCPU host run-queue delay is
0.0011543543221001374% of its observed boundary interval, maximum any-vCPU delay
0.001168089124419008%. Frequencies vary. No trial is discarded for interference.
Phobos uses less CPU per request in four of five populated workloads, but the
history page uses 3.0% more CPU than Moonraker. Moonraker has lower median p99
for history and the 600/s mix. Phobos has lower sampled RSS throughout.

The first PC's 30 complete rich-history trials remain in `vm-local-partial/`,
including nonzero interference and the later private-disk capacity failure.
Its incomplete empty-history case has no result row. Second-PC CPU-incompatible
setup utilities were replaced before measurement; generator smoke preflights
then passed. The complete run uses a 16 GiB private disk and a free-space guard.
Earlier shared-host and printer captures remain unchanged. Printer states in
the active reports are explicitly historical.

Cleanup stops the owned VM, removes its partition, restores user/system slices
to CPUs 0-31, verifies unchanged frequency policies, releases both PCs' owned
sleep inhibitors and removes the temporary sudo rule. QEMU, BusyBox and Vegeta
packages remain installed. No existing VM or golden image was changed.

Verification: all 31 performance/release Python tests and measurement-helper
shell smoke checks pass. Independent assertions validate all 42 rows, request
totals, matched repetitions, guest/host counter arithmetic, affinity, no quota
throttling, locked-memory/swap samples, parity, asset and plot hashes, twelve
active charts and documentation links. Representative figures were visually
inspected. `git diff --check` passes. Source suites are not rerun for these
measurement/documentation-only changes. `graphify` is unavailable, so graph
output is excluded.

## 2026-10-22: Fluidd startup subscriptions and database array keys

The user reported Invalid params immediately on opening Fluidd and missing
console output. Read-only replay of Fluidd 1.37.7-b2edab5's served startup code
against production reproduces a 400 from `printer.objects.subscribe`: the
Forge-X configuration exposes 262 objects after Fluidd's menu exclusion, while
`Connections.replaceSubscriptions` allowed 256. Fluidd enables notifications
and loads `server.gcode_store` only after that subscription succeeds. Existing
console responses were already present in the production store.

Raise the bounded subscription allowance to 1,024, retaining the name and frame
limits and allocating only requested map entries. A boundary regression accepts
262 and 1,024 objects, then rejects 1,025 without replacing the previous set.
A full WebSocket test subscribes 262 objects, receives a simulated Klippy console
response and reads the same response from the console store. The simulator returns
the actual objects/subscribe result fields instead of null.

Fluidd's settings code also uses array database keys. The shared item path now
accepts dotted strings or literal string segments, preserving embedded dots
and the original request key in responses. Both SQLite and file backends use
the same parser, retain the 16-segment bound and reject empty or non-string
segments. Public and debug handlers share validation and access checks. The
storage format is unchanged. DEVELOPMENT.md documents these limits; the
generated API table records the database path bound as partial behavior parity.

Verification: failing regressions first reproduced the string-only database
parser and the 256-object cap. Complete standalone Debug and ReleaseSafe suites
each pass 1,735 tests with one real-Klippy skip, zero failures and 327 fuzz tests.
Both include the new WebSocket console test. All 109 Python tool tests pass;
format, lint, type and diff checks pass. Surface coverage remains 123/123
endpoints, 130/130 methods and 27/27 notifications; the generated table check
passes. Independent local daemons match Moonraker for six HTTP/WebSocket array
key write/read/delete responses, including literal dotted segments. Malformed
common keys return 400 on both daemons. Both private daemons were stopped.

The 54-event older conformance capture reports the same seven failures against
the published v0.2.2 binary and this build: server.info, file-root paths and USB
details. Those pre-existing capture/configuration differences are retained,
not reported as a passing replay. No API identity, Python stub, reboot no-op or
optional component behavior changes. The native Debug binary remains installed
in zig-out. The static ARM Cortex-A7 ReleaseSmall build has SHA256
`a224e2699893895523acda2e95af90699abbae13e9ecd85a4a337281fcb97944`.

The user requires deployment after the current print. No running printer
service has been restarted during these checks; the completed print still has
a nonzero nozzle target at this entry. Printer staging uses a unique executable
and private probe directory. Browser automation is unavailable, so no visual
Fluidd result is claimed. Graph output is excluded because graphify is absent.

## 2026-10-22: deploy the Fluidd compatibility fixes after calibration

The user authorized a phobos restart after printing, then clarified that bed-mesh
calibration must finish first. The initial probe launch was rejected by its
preflight when a new 60-degree bed target appeared; no probe or restart occurred
then. Read-only checks subsequently observed Mesh Bed Leveling Complete, profile
`auto`, inactive motion, completed print state and zero heater targets.

The static ARM build recorded above ran inside the Forge-X chroot on loopback
7126 with a private data directory and fresh database. Its minimal configuration
exposes 268 objects because it omits production's six hidden-object exclusions.
The full subscription returns all 268 statuses, both literal array-key
write/read/delete paths pass, and the config directory's filesystem usage is
valid. Those writes touched only the private probe database. The probe was
stopped before deployment.

Only the owned production phobos PID was stopped. While it was stopped, the
database, WAL and SHM were copied with the old executable and launcher into
`/data/phobos-backups/fluidd-20261021T180219Z`. The snapshot database SHA256 is
`d6bca7b80e685f0048eee93f4767f73ab9e8073ce3f06c2c9bf3b092f2b26b15`.
The launcher now executes `/data/phobos-fluidd-20261022`, a patched v0.2.2 build
from commit e0b9bf7. Published v0.2.2 assets and its tag are unchanged. The running
executable matches ARM SHA256
`a224e2699893895523acda2e95af90699abbae13e9ecd85a4a337281fcb97944`.

Before/after checks replay the same production Fluidd subscription: 262 objects
returned 400 before and all 262 statuses after deployment. All 26 production
components remain loaded, without failed components or warnings. Existing
Fluidd uiSettings read identically through dotted and array keys, with the array
key echoed intact. Directory stat succeeds. The console store starts empty after
the daemon restart; live console fan-out is covered by the host WebSocket test,
but no printer gcode was sent to manufacture a console event or a visual result.

Klippy remains ready, mesh profile auto is intact and both heater targets remain
zero at verification. The board boot ID is unchanged. No Klippy restart, board
restart, movement or heater command was sent. Probe port 7126 is closed and its
owned scratch directory is removed; production serves 7125. The normal host
Debug binary was rebuilt successfully. The fixes were fast-forward pushed to
main; CI checks, all seven build profiles, native x86-64/AArch64 smoke tests and
the x86-64 Debug suite pass at this entry. Remaining CI suites are still running.

Subsequent [CI run 39648295675](https://github.com/maci0/phobos/actions/runs/39648295675)
passes for source commit e0b9bf7: all seven static build profiles, both native
smoke jobs, packaging, x86-64 Debug/ReleaseSafe and native AArch64 ReleaseSafe.
Each test job reports 1,735 passed, one skipped, zero failed and 327 fuzz tests.
Publication is skipped because this is a main-branch fix, not a release tag.
A read-only 60-second production WebSocket observation also accepts the exact
262-object subscription; no natural console event occurs during that idle
window, so it adds no claim of real-printer console event or visual verification.

## 2026-10-22: visual Fluidd verification and startup timings

The user authorized browser testing against the real printer and reported slow
initial data loading. Fluidd 1.37.7-b2edab5 was opened against the running patched
phobos. Rendered Chromium screenshots verify the dashboard, temperature graph,
console, Jobs, History, Configuration and System pages. The console displays 130
real stored entries from the printer. No Invalid params or disconnected banner,
API response error, browser exception or blocked mutating request occurs in the
captured runs. This visual evidence supersedes the earlier unavailable-browser
limitation; it does not claim a new live console event during this test.

Three fresh browser profiles load heater/job data and console history in
1.504, 1.502 and 1.401 seconds. The complete 262-object subscription returns
about 369 KB and takes 386, 493 and 317 milliseconds respectively. Browser-side
timings run from request send to response delivery, including queueing, transfer
and parsing; they are not measurements of server CPU time. Reopening the cached
profile takes 1.180 seconds, followed by two warm reloads at 0.904 and 0.901
seconds. The temperature graph also renders after its deferred component loads.
No longer stall is reproduced. These observations use an already-running
daemon, not a cold server or a controlled load-independent benchmark.

Evidence is retained in ignored `.scratch/fluidd-visual/`: asserted browser
checks, request timings, cold/warm JSON captures and screenshots. Request
instrumentation observes responses without replacing them and guards printer,
file and database mutations. Only navigation links were clicked; no printer
control or console command was used. Browser sessions are closed. The printer
remains idle with zero heater targets, the same executable and board boot ID,
and no listener on probe port 7126. No daemon restart, configuration edit or
source change was needed. Verification for this evidence-only update is the
browser assertions, image inspection and `git diff --check`; source suites and
published performance graphics are unchanged.

## 2026-10-22: measured reply and serialization optimizations

Requested by the user: profile optimized code, improve speed and allocation
work, benchmark on the physical printer first and then the isolated benchmark
PC, and keep that PC awake. Production could be stopped for printer tests.

`src/json/value.zig` adds a portable vector scan for long plain ASCII API
strings. Escaping, Unicode, punctuation, options and scalar formatting remain
in `std.json`. HTTP and JSON-RPC results use the same wrapper. Differential
tests cover all byte values around vector boundaries, nested values, options,
writer failures, allocation failures and bounded fuzz input. The Cortex-A7
disassembly contains NEON loads/comparisons for this path.

`history.zig` reserves known response map/array sizes; `sqlite_store.zig`
uses the already-reserved row capacity. Field-preservation and allocation-failure
tests accompany a capacity-boundary fuzz test. `klippy_connection.zig` routes
replies through a typed envelope without constructing a second result tree.
The waiter keeps one owned payload and decodes the result once. Notifications
still receive full parsing and depth validation. Tests cover ownership after
source clobbering, invalid skipped JSON, escaped keys, present-null methods and
reply IDs. A 256 KiB reply must route with less than payload-size plus 4 KiB
of allocation.

TCP listeners set TCP_NODELAY through typed libc because the installed
`std.Io.net` has no socket-option setter. IPv4/IPv6 inheritance and failure
tests plus a bounded fuzz test cover the adapter; the accepted-socket test
also passes on the physical ARM printer. Transfers and cancellation stay in
`std.Io`. `AGENTS.md` and `docs/STDLIB.md` record the checked exception.

The existing load/profile tools disable response-body retention. An initial
VM study filled its private 8 GiB capture disk during the last populated-history
trial; all 44 completed trials and the exact storage failure remain archived.
The fresh accepted study uses 16 GiB, a 2 GiB free-space floor and identical
ten-second/body-retention settings for every backend. A regression test drives
the real load script against 128 KiB loopback replies and checks successful
delivery with bounded capture size. A separate 50-request check transfers
6,553,600 bytes while retaining an 8,154-byte capture. Retained-byte counters
are explicitly distinguished from uncollected wire throughput.

The [capture directory](perf/optimization-20261022/) records exact source blobs,
executable hashes, fixtures, all trials, scheduling and cleanup. A frozen
baseline at `7764f3697a04` is retained for before/after comparisons; rebuilding
it with explicit x86-64 baseline CPU settings reproduces the measured hash.
Active tables and 12 graphics show only the current 0.2.2 development build
and Moonraker. Published v0.2.2 captures remain archived unchanged. The
performance, memory and harness docs distinguish the development build from
published release assets and label which metric direction is better.

The printer completes 36 twelve-second HTTP trials, 15,660 requests, 108 full
268-object subscriptions and 54 exact history comparisons. Compared with the
pre-change build, median CPU falls 7.2% for the 64 KiB response and 16.8% for a
full subscription. Info p99 worsens with overlapping trial ranges; it is
reported rather than omitted. Earlier host-forwarded and interrupted runs
remain archived, including an unexplained host monitoring timeout. The final
study moves timed health checks onto the printer. No new behavior bug is
observed in the tested reads; retained identity/default/policy/environment
differences are listed in `mismatches.json`.

The isolated four-vCPU KVM run completes 54 ten-second trials and 706,480
successful requests with 108 matching history checks. The 64 KiB and synthetic
config reply CPU medians fall 6.9% and 3.1% respectively. Moonraker remains
faster for history and the synthetic config reply. Resident-memory changes
over baseline are inconsistent; no universal reduction is claimed. Guest
aggregate steal increases one exported tick, with zero per-CPU tick deltas.
Maximum host server-vCPU run-queue delay is 0.000608% of its window. Locked RAM
stays at least 4,838,436 KiB; VM/cgroup swap and quota throttling stay zero.
These controls do not prove literal zero steal or fixed physical performance.

Verification: Debug and ReleaseSafe each pass 1,745 tests, skip the gated local
real-Klippy test and find 331 fuzz tests. API surface coverage remains 123/123
HTTP endpoints, 130/130 RPC methods and 27/27 notifications; generated API
coverage docs need no regeneration. All seven static profiles pass ELF/ABI and
checksum verification. The harness passes 23 Python tests, failure/cleanup
smoke tests, shell syntax and shellcheck, Black, Ruff, mypy, Zig formatting and
`git diff --check`. Plot-input hashes, source blobs and trial counts are checked;
representative graphics are visually inspected.

Production is restored with its original executable hash on port 7125,
PID 27309, ready, print complete/idle and both heater targets zero. The board
boot ID is unchanged, port 7126 is closed and owned probe files are removed.
No candidate is installed, no live database is opened by a probe and no hardware
control, board restart or swap adjustment is used. The VM is stopped, exact
prior CPU slice limits/frequency policies restored, owned partitions/disks
removed, and remote sleep inhibition and temporary sudo access released.

Unperformed: printing, uploads, long soaks, notification-flood throughput and
physical testing of the other release architectures. The native optimized
profile guides hot-path selection; shared-host timing is excluded from the
comparison. `graphify-out/graph.json` exists but the executable is absent, so
graph updates are skipped and that directory is not a deliverable.

## 2026-10-22: install the verified optimization build

The user's earlier production-deployment authorization and printer takeover
instruction cover installing the tested ARM binary after the idle benchmarks.
Source commit `00ba70f14869` is installed as `/data/phobos-speed-20261022`,
SHA256 `a31858612a226140fdc435f61b17c773360f4a0d2d61b322cc7fda7bb1890ad8`.
It remains a 0.2.2 development build, not a new published release.

The old executable and launcher are backed up under
`/data/phobos-backups/speed-20261022T102807Z`. The production database and any
sidecars are copied only after the old daemon stops; the backup directory is
mode 0700. The launcher points to the new binary and starts it inside the
Forge-X chroot on 7125. A failure trap restores the previous database/launcher
and daemon if startup validation fails. No board or Klippy restart is used.

Immediate and later read-only checks pass: ready, 26 components, no failures
or warnings, all 262 requested subscription objects returned without an RPC
error, directory disk usage valid, print complete, idle and both heater targets
zero. The console store endpoint returns its expected list; it has no new
entries after the daemon restart and no gcode is issued to manufacture output.
New PID 27463 and the executable hash match. The board boot ID remains
`6213a6c1-a3b6-4b38-b637-5aa9a116a117`. The
[deployment record](perf/optimization-20261022/deployment.json) is separate
from the earlier benchmark cleanup state.

## 2026-10-22: remove the remaining measured read bottlenecks

The user requested fixes for the cases where Moonraker remained faster, including
the largest Klippy config-reply gap, and updated measurements on the printer and
isolated VM. The development version remains 0.2.2; no published asset or tag is
replaced. Source parent is `40ff6db18306`; exact candidate source blobs and binary
hashes are recorded in `perf/optimization-20261022-2/`.

Klippy replies now receive one full standard JSON parse and depth check. The
waiter owns that parsed arena until it copies the result to its caller. A 64 KiB
standard reader reduces socket-read overhead. Long valid UTF-8 JSON strings use
a 1 KiB output buffer, portable vector comparisons and mask/ctz scans. A 896-byte
escape table is generated at compile time by the standard JSON encoder;
nondefault options and invalid UTF-8 retain its runtime encoder. No parser or
dependency is added. CPU microbenchmarks on both native and physical ARM support
the selected vector path; slower parser/inlining and vector alternatives remain
in the experiment archive.

Legacy job-history pages without KV overrides use ordered SQL LIMIT/OFFSET,
preserving negative-ID exclusion, ordering, offsets, unlimited semantics and
null end times. Mixed/noncanonical histories retain their validation/fallback.
A 10,000-job, one-row-page regression fails before this change and passes after,
checking content and request allocation below 64 KiB. Each incoming Klippy status
push now becomes one notification per interested client after object/field
filtering. A regression fails before batching and verifies one frame, exact
masks, unauthenticated/unsubscribed exclusion and unchanged input afterward.
Connection references, Core ordering and write deadlines stay intact.

The entry point now uses `std.process.Init.gpa`, whose selection in installed
Zig 0.17 `lib/std/start.zig:780` uses a checked allocator in Debug/ReleaseSafe
and libc for this linked ReleaseFast program. The prior comment incorrectly
described all startup modes as debug allocation and overrode release modes
with SMP. Focused comparisons retain their overlapping RSS ranges. The larger
parsed-reply arena is a documented peak-memory tradeoff, not an RSS reduction.
The 256 KiB reply test observes 594,223 allocation bytes, below 2.5 times wire
size plus 4 KiB, and checks ownership after overwriting input.

The release helper and documented deployment/memory/profile builds now use
ReleaseFast; published v0.2.2 assets remain ReleaseSmall. Hosted CI adds full
ReleaseFast suites on x86-64 and native AArch64 and runs floating-point ABI
probes in the shipped mode. Two existing allocation-failure tests use the
existing no-remap test allocator pattern to make every failpoint reproducible
under optimized execution; no failpoint is skipped.

Verification on the selected source: Debug, ReleaseSafe and ReleaseFast each
pass 1,750 tests, skip the gated local real-Klippy fixture and find 331 fuzz
tests. The local real-printer substitute is verified separately on hardware.
All seven static profiles pass ELF/ABI/hash checks. All five compatible ARM32
floating-point profiles run on the printer and pass five C/Zig return/addition
checks each; the native probe also passes. Build-policy tests pass four cases
including two fuzz tests. Python scanner/client/harness/release tests pass 110.
The current Debug CLI API gate remains 123/123 HTTP endpoints, 130/130 RPC methods
and 27/27 notifications. Generated coverage documentation is already current
and is not regenerated. Zig formatting, shell syntax, shellcheck -x, Black,
Ruff, mypy, harness failure/cleanup smoke and `git diff --check` pass.

The local corroborating KVM study completes 54 trials and 719,983 successful
requests, with 108 matching history comparisons. Each trial lasts at least
10 seconds and offers at least 2,000 requests; config trials last 40 seconds.
Phobos has lower median CPU, p99 and sampled RSS for every measured workload;
the closest config p99 result is only 0.8% lower, with overlapping ranges.
Aggregate guest steal sums to 18 exported ticks; maximum host server-vCPU
run-queue delay is 0.047250% of its window. Locked memory stays at least
4,838,196 KiB, with no VM/cgroup swap or quota throttling. CPU limits are restored
and the owned VM stops. No literal zero-steal or fixed-frequency guarantee is
made. A separate local FIFO/idle-poll trial was invalidated after starving a
host kernel worker; none of the accepted studies uses either setting.

The physical printer completes 24 HTTP trials, 10,440 successful requests,
126 full subscriptions and 36 matching history comparisons. Subscription
arrivals sample seven phases of live Klippy's 250 ms timer at 1.75/s. Klippy
uses CLOCK_MONOTONIC_RAW; an earlier mixed-clock harness assertion and transient
startup restoration check are corrected against live source hashes. Earlier
completed/negative results and both harness failures are retained. The old
production binary is restored afterward, ready on 7125 with 26 components,
262/262 subscription objects, valid console/disk-usage responses, print complete,
idle and zero heater targets. Boot ID is unchanged and 7126 is closed. No
hardware command, board/Klippy restart or production database probe is used.

The user explicitly requested retaining the remote sudo rule and preventing
sleep. `/etc/sudoers.d/phobos-bench` is retained on 192.168.0.99; the
`phobos-benchmark-awake` systemd service blocks sleep/idle there. The controller
also remains inhibited during the work. Cleanup must not remove the sudo rule
or the remote inhibitor. `graphify-out/graph.json` exists but the executable is
absent, so graph updates are skipped and that directory is not a deliverable.

The subsequent remote KVM study on 192.168.0.99 completes 54 trials and 719,980
successful requests, with 108 matching history checks. Aggregate guest steal
is one tick (CPU 0); server/generator per-CPU steal deltas are zero at exported
counter resolution. Maximum server-vCPU host run-queue delay is 0.000693% of its
window, locked RAM stays at least 4,837,408 KiB and VM/cgroup swap/throttling stay
zero. The remote disk is 8 GiB, the local disk 16 GiB; body retention is disabled
for both and each backend receives matched controls. Cleanup restores CPU limits.

The remote config CPU median falls from the retained baseline's 3.185 to
1.525 ms, but remains above Moonraker's 0.995 ms; p99 is 3.020 versus 2.679 ms.
All other measured remote workloads favor phobos for median CPU, p99 and sampled
RSS. The remote config result is a remaining performance gap, not excluded as
noise. The user then requested ten further bpftrace profiling/optimization rounds,
including memory improvements. This capture is their starting baseline; deployment
of the new build is deferred until those rounds finish. Current performance and
memory reports, twelve current-versus-Moonraker graphics, all trial statistics,
negative experiments and verification evidence are updated from measured JSON.

### 2026-10-22: profiling rounds 1 through 4

At the user's request for ten profiling rounds and lower memory use, optimized
symbol builds are sampled with bpftrace on owned local and remote fixture
processes. Timing comparisons run separately without instrumentation, with
matched private databases and alternating binary order. The remote sudo rule
and sleep/idle inhibitor are retained; both hosts' blockers are rechecked.
Final isolated VM and physical-printer verification remains pending.

Round 1 replaces repeated growth of long ASCII value tokens with one bounded
allocation in `json/parse.zig`, keeping the standard JSON token parser and
Unicode/key fallback. Klippy uses that adapter. Differential malformed/byte/fuzz,
decoded-length, ownership and every-allocation-failure tests pass; the 256 KiB
reply budget tightens to twice wire size plus 4 KiB. Three remote trials reduce
median config CPU from 1.2833 to 1.0283 ms/request and p99 from 2.2047 to
1.8695 ms. RSS does not improve in those trials and is not claimed as a gain.

Round 2 writes encoded string vectors directly into `std.Io.Writer` capacity,
retaining the small/unbuffered fallback. Exact-size writer tests first expose an
over-reservation error, then pass with the corrected bound. Full writer options,
UTF-8, failures and nested-value fuzz checks remain. Remote median API CPU moves
from 1.025 to 1.0167 ms/request; standalone encoder improvements are larger and
are not substituted for request timings. A further batching prototype stays out.

Round 3 rejects a direct SMP startup allocator after a 3.6% CPU regression.
The daemon instead owns a native I/O backend with the existing 1 MiB handler
stack bound and actual startup environment on all architectures. A real child
process reproduces the omitted-environment defect before the fix. Native median
trial-maximum RSS falls from 10,016 to 5,952 KiB, with CPU rising from 1.020 to
1.0633 ms/request and p99 from 1.8615 to 1.9165 ms. Post-load smaps identify
anonymous huge pages as the discrete baseline RSS steps; allocator slab sizes
are not their cause. Host huge-page policy is unchanged. The memory goal
justifies this measured tradeoff pending final combined verification.

Round 4 samples an independent six-route mix, 45,600 successful requests per
profile. Local SQLite preparation accounts for 13.4% inclusive samples.
`SqliteStore` now retains two prepared statements under its existing mutex,
resets execution on success/failure, clears copied table-name bindings and
finalizes before closing. Query results remain fresh. The preparation-count
test fails before the change; namespace writes, schema create/drop, bounded
schema fuzz and allocation-failure recovery pass afterward. Three alternating
remote trials complete 108,000 requests: median CPU 0.105 to 0.102778 ms/request,
p99 0.623953 to 0.611397 ms and sampled maximum RSS 5,772 to 5,768 KiB. Final
Debug and ReleaseFast suites each pass 1,763 tests, skip one local real-Klippy
fixture and find 334 fuzz tests. Earlier stages' full suites also pass before
the next source change. Diagnostic logs, raw profiles, binary/source snapshots
and per-trial statistics are retained in `.scratch/speed28/`; the current
published benchmark tables still identify their unchanged `b381577` baseline.

### 2026-10-22: profiling round 5

The large-record profile samples 4,220 stacks: JSON decoding accounts for 37%
inclusive samples and `pread` for 16.5% leaf samples. SQLite JSON records and
history columns now use the long-token adapter's caller-arena entry point.
Its 256 KiB record test fails the allocation budget before the change and
passes after, also checking ownership after the input is overwritten. Both
entry points participate in differential byte/malformed/fuzz and every-allocation
failure checks. Short documents delegate directly to the standard parser;
validated plain strings bulk-copy once without running the escape loop.

The first extension regresses history CPU by 5.9% and large-record CPU by 2.7%.
A later variant improves large records but regresses config CPU by 11.6%.
That config profile samples a generic `mem.findPos` search at 23.45% leaf CPU;
disassembly confirms its call in `Source.nextAllocMax`. Moving the plain return
alone does not correct it. Replacing the Unicode-escape substring search with
standard scalar searches and a preceding-byte check removes that sampled call.
All rejected variants and their measurements remain private scratch evidence.

Final alternating remote comparisons use three trials per binary and workload,
without instrumentation. Config median CPU falls from 1.010 to 0.888333 ms/request
and p99 from 1.850391 to 1.723567 ms; sampled maximum RSS medians are both
5,948 KiB. Large-record CPU falls from 0.165556 to 0.136674 ms and p99 from
0.450576 to 0.352772 ms; RSS is 5,152 versus 5,156 KiB. History CPU is 0.460
versus 0.461667 ms and p99 0.520052 versus 0.521906 ms, with identical 5,360 KiB
RSS medians. The small history regression is retained rather than omitted.
These pinned-host diagnostics make no isolated-VM or universal-win claim.

Debug and ReleaseFast each pass 1,764 tests, skip one gated local real-Klippy
fixture and find 334 fuzz tests on the final scalar-search source. The six
standalone parser tests also pass in ReleaseFast. Source is preserved under
`.scratch/speed28/source-round05/`, with raw profiles, rejected binaries and
the three accepted `round05-scalar-*-ab/trials.json` captures beside it.
The published benchmark tables remain the earlier baseline pending all ten
rounds and final isolated/printer verification.

### 2026-10-23: profiling round 6

The owned fixture populates files named by its 266 history rows, then checks
history `exists` fields before load. A mixed history/directory profile places
`statx` at 21.4% leaf samples and file existence at 11.4% inclusive samples.
Existence now uses `Resolved.stat` and its regular-file kind, preserving the
checked root/component/symlink traversal while avoiding file-data open, fstat
and close. Vendor `file_manager.py:386` uses `Path.is_file`, supporting this
metadata-only behavior. No filesystem result cache is introduced.

The data-open-denied regression fails before the change. In-root aliases,
escaping links/traversal, directories, missing files and generated file
creation/deletion pass afterward. Debug and ReleaseFast each pass 1,766 tests,
skip one gated local real-Klippy fixture and find 335 fuzz tests.
Three alternating remote trials per binary complete 36,000 requests: median
CPU 0.485 to 0.450 ms/request, p99 0.604563 to 0.540922 ms and sampled maximum
RSS 5,612 to 5,604 KiB. Raw profiles, per-trial data and exact source remain in
`.scratch/speed28/round06-*` and `source-round06/`. Isolated and physical
verification of the combined candidate remains pending.

### 2026-10-23: profiling rounds 7 through 10

The user requested ten profiling rounds with CPU and memory improvements.
Round 7 profiles a private fake-Klippy fixture containing 1,000 console entries
and two 32-sample temperature stores. Console snapshots now read the deque
directly, reserve only the requested array length and use exact three-field
standard map storage. The old handler fails the one-entry 8 KiB allocation
budget; the first growth-slack variant fails the full 512 KiB budget. The
retained exact-capacity variant passes both, wrapped FIFO, count edge cases
and every request allocation failure. Three alternating remote pairs complete
27,000 requests: median CPU 0.226667 to 0.180000 ms/request, p99 0.467676 to
0.406977 ms and sampled maximum RSS 5,764 to 5,564 KiB. These pinned-host
diagnostics are not isolated release measurements.

Round 8 audits subscription masking and fanout without another source change.
At 100 fresh subscriptions/s, 3,800 sessions validate 22,664 notifications.
The default 50-connection limit rejects the 200/s diagnostic with HTTP 503;
those failed runs are excluded from timings. A private 100-connection limit
then accepts all 7,600 sessions and 45,535 notifications. The C allocation
trace records 63,538 calls and 50,269,838 requested bytes in its 20-second
window. Requested bytes and mmap sizes are not RSS. Subscription copies must
remain connection-owned rather than borrowing request arenas.

Round 9 completes 3,800 fresh WebSocket config sessions, checking the entire
328 KiB reply. Its 1,379 CPU samples distribute work among copies, decoding,
encoding and socket writes. No speculative streaming/ownership rewrite is
retained. Existing outbound TLS certificate/hostname and allocation-failure
tests pass; TLS is not separately profiled and inbound TLS is not implemented.
The WebSocket limit remains 10 MiB; the Klippy ETX frame limit is 20 MiB.

Round 10 completes all 34,200 requests across nine paths with populated history,
console and heater fixtures. Its 3,968 samples identify remaining copies,
sendmsg, parsing, encoding and SQLite/history work. Compilation runs alongside
this diagnostic, so its absolute timing is not release comparison evidence.
No further source change is justified by these last three audits.

Evidence is retained in `.scratch/speed28/round07-exact-*`,
`round08-subscriptions-*`, `round09-websocket-config/`,
`round10-combined/` and `rounds.json`. Combined source passes Debug,
ReleaseSafe and ReleaseFast: 1,768 passed, one gated local real-Klippy skip,
zero failures and 335 fuzz tests. On the user's fresh release request, the
package becomes 0.2.3 and all seven ReleaseFast assets are rebuilt before
isolated measurements, physical validation and publication. The remote sudo
rule and both hosts' sleep blockers remain in place at the user's request.

### 2026-10-23: v0.2.3 final measurements, printer installation and release

The user requested refreshed graphics, a release, physical testing and
publication. All seven static ReleaseFast profiles pass ELF, ABI and checksum
validation. The native benchmark executable is byte-identical to the matrix
asset. Final Debug, ReleaseSafe and ReleaseFast each pass 1,768 tests, one
gated local real-Klippy skip, zero failures and 335 fuzz tests. All 110 Python
tooling tests, four build-policy tests, formatting, shell checks, lint/type
checks and harness cleanup smoke checks pass. SQLite source hashes match.
API registration remains 123/123 endpoints, 130/130 methods and 27/27
notifications; the generated API table passes its freshness check unchanged.

Independent local and remote KVM studies each complete 36 trials and 72 history
comparisons. They complete 479,975 and 479,993 successful requests respectively.
Each uses the actual stripped v0.2.3 asset, matched rich/empty seeds, at least
2,000 offered requests per trial, locked 4 GiB RAM, an isolated physical L3
group, pinned vCPUs and no guest NIC. Local aggregate guest steal is six ticks;
remote steal counters remain zero. Maximum server-vCPU host run-queue delays
are 0.050139% locally and 0.002091% remotely. Neither VM swaps or encounters
quota throttling. CPU partitions are removed, prior slice limits restored and
frequency policies left unchanged. The remote sudo rule and sleep inhibitor
are retained, as requested. Literal zero scheduling delay and fixed physical
frequency are not claimed.

The Forge-X chroot study completes all 24 HTTP trials, 10,440 requests,
126 full 268-object subscriptions and 36 matching history comparisons using
private databases on loopback 7126. Production is paused during load and
restored afterward. Every measured HTTP case has lower median p99 and sampled
RSS with phobos. Remote large-config CPU remains 2.0% above Moonraker,
1.025 versus 1.005 ms/request; every other HTTP workload CPU median favors
phobos. Subscription latency ranges overlap. All twelve active graphics now
show only v0.2.3 and Moonraker, with metric directions and trial ranges.
Numeric sources, executable/source hashes, isolation windows, rejected
experiments and limits are under `docs/perf/optimization-20261023/`.

All five compatible ARM32 daemon assets then pass against real Klippy using
the full Forge-X config, private copied seeds, disabled automatic updates and
disabled job-queue startup. Each verifies all 26 production components,
262/262 requested objects, directory capacity, Fluidd array keys, config/history
reads and all four temperature stores advancing. All five C/Zig floating-point
probes pass. Only this Cortex-A7 board is physically certified. Native AArch64
execution is delegated to the existing hosted CI. Probe processes and owned
printer scratch files are removed afterward.

The authorized production switch installs `/data/phobos-v0.2.3`, SHA256
`ea85ea002a5c138821951f646f56deddf2aa6e001a84eef22c0f549a7fc2372d`,
as PID 13619 on 7125. The launcher, running executable and stopped database
with WAL/SHM sidecars are saved in
`/data/phobos-backups/v0.2.3-20261022T164357Z/`, with rollback guards. Production
is ready and idle, both targets zero, all 26 components healthy and all 262
subscription objects returned. No probe listens on 7126. Board boot ID stays
`6213a6c1-a3b6-4b38-b637-5aa9a116a117`. No hardware command, board reboot,
Klipper restart or firmware restart is used.

Post-install checks match all 273 history job IDs and seven null end times
against an owned copy of the stopped backup, including its WAL. An initial
backup check omitted sidecars and saw only 266 legacy rows; copying the saved
WAL/SHM exposes the seven KV jobs and makes the check pass. Another check
incorrectly expected the default database path in config output; descriptor
inode comparison verifies the actual open database without opening its live
file. Both are corrected harness assumptions, not daemon failures. Deployment
and preservation JSON remain separate from benchmark snapshots. All four
production temperature stores advance; sampled production RSS is 5,876 KiB
with zero process swap after the read checks, not a matched benchmark value.

Package version and release notes become 0.2.3. README, build, standard-library,
memory, performance and harness documentation are updated. The local release
assembler validates all seven assets and versioned note links before commit.
Graphify is skipped because its executable is absent; `graphify-out` is not a
deliverable. Long soaks, printing/uploads, maximum capacity, file-backend
performance and other physical printer models remain unchecked. Main CI and
tag publication follow this verified source commit; their run IDs are reported
with publication rather than asserted in advance.

### 2026-10-23: MQTT test synchronization after native AArch64 CI

Main CI run 39817668216 passes every profile build, both native asset smoke
checks, all x86-64 suites and AArch64 ReleaseSafe. AArch64 ReleaseFast catches
the existing reconnect test asserting 130 subscriptions when the broker has
observed only 100. `MqttCtx.connectBroker` queues subscription writes before
calling its connection hook; the hook does not promise broker receipt. The
test awaited that hook and immediately inspected the independently running
broker. It now also waits for the broker's full count using the existing
bounded wait, retaining the exact assertion. No production code or timeout
is changed. Publication stops before any tag is created.

After correction, Debug, ReleaseSafe and ReleaseFast each pass 1,768 tests,
one skip, zero failures and 335 fuzz tests. Rebuilt native and Cortex-A7 assets
are byte-identical to the measured/printer-tested matrix, so no deployment
restart or replacement measurements are needed. Other captured source blobs
match commit 15370cd8b9f474b15f6aa1225643c51b46b56b03. The capture verification
now names that immutable commit and records the test-only change separately.
This release's publication procedure also downloads and compares all seven
main-CI assets with the measured matrix before creating its annotated tag.
Evidence is `docs/perf/optimization-20261023/post-capture-verification.json`,
the failed hosted run and `.scratch/speed28/mqtt-sync-*` logs/binaries.

### 2026-10-23: publication and live temperature-store verification

The user-authorized release is published at https://github.com/maci0/phobos/releases/tag/v0.2.3.
Annotated tag v0.2.3 points to c1dfde028063656e5e6a5a23e7c31179c8877ea6; main and tag pushes succeed.
Main CI 39820286081 and tag CI 39822018131 pass every build, native suite,
asset smoke, packaging and publication check. Before tagging, all seven main-CI
binaries match the measured matrix byte for byte. After publication, the seven
downloaded binaries and both manifests also match. No asset or tag is moved or
overwritten. The initial failed CI remains recorded with its test-race fix.

The installed Cortex-A7 hash matches the published asset. A read-only live
check confirms Klippy ready, 26 components, all four temperature stores at
1,200 samples, an unchanged board boot ID and no probe listener on 7126.
The stopped backup preserves all 273 job IDs and seven null end times, as
recorded separately. The test-only synchronization change requires no second
printer restart. Both owned VM images/guest trees are removed after copying
their captures and harness; templates and frequency policies are untouched,
CPU reservations are restored, and the sudo rule and sleep blockers remain.

Evidence is `docs/perf/optimization-20261023/publication.json`,
`printer/post-publication-state.json`, the linked hosted runs and
`.scratch/speed28/publication.json`. This documentation follow-up changes no
runtime source, measured data, release assets or annotated tag.

GitHub's aggregate tag-workflow status remains in progress despite all 17
job records showing completed/success and successful public publication.
Independent downloads and checksum/byte comparisons complete without
fabricating a workflow conclusion. The actual aggregate and job states are
retained in the publication JSON.

## 2026-10-24: track Forge-X API and behavior separately

Requested: compare upstream and Forge-X Moonraker and assess a startup flag for
selecting compatibility behavior. Added `api/forge_x_surface.json` and
`docs/api/FORGE_X.md`, with the source revisions, registered API differences,
behavior gaps, current Phobos evidence and an explicitly unimplemented startup
profile proposal. Updated the scanner guide and development guide; corrected
the scanner guide's stale statement that no CI workflow existed.

Compared Phobos's unchanged Moonraker pin
`9008485843740c93e0154ccbdac1fc2b02b03aaa` with Forge-X's `1.4.2` branch at
`f2c3f272d6e27400818a514d9d31d754eeb1b5e3`, downloaded by full revision. Forge-X
`main` is a different release line. Neither the local beta checkout at
`95d1771d8161df5e93eacdf3ec501861e607e202` nor the vendor checkout was changed.
The archive hashes are recorded in the tracker. Ignoring caches, bytecode and
generated version files, 55 source paths differ. A dated upstream reference,
`d4d2074466c834532b46c965beb233f6341e493a`, reduces that inventory to 19 paths;
it is not asserted to be Forge-X's exact fork point. Version drift is kept
separate from custom behavior. Full source/API diff captures and the comparison
script are private scratch artifacts under `.scratch/forgex-compat-20261024/`.

The comparison reproduced two tooling bugs: legacy string-list request verbs
became dynamic names, and literal remote registrations were compared using
their unmounted paths. Added three tests and confirmed they failed for those
reasons before fixing the shared extractor and coverage path normalization.
Unknown list elements remain dynamic. The pinned upstream scan and generated
coverage table remain unchanged.

Verification: all 113 Python tooling tests passed, including 75 API-scanner
tests and its bounded fuzz cases. The focused undefined-name/syntax Ruff check
and `git diff --check` passed. The Forge-X snapshot has no API drift against
its new baseline. The v0.2.3 native dump retains upstream coverage of 123/123
paths, 130/130 RPC names and 27/27 notifications. Separate Forge-X coverage is
117/121 paths, 124/129 RPC names and 27/28 notifications; its expected nonzero
result records the missing timelapse implementation. Four additional timelapse
Klippy remote methods are missing outside that coverage score. The tracker
also records existing-route differences, including print-start macros, upload
dialogs, service preflight, Feather events and object-filtering scope.

No daemon behavior, package version, release, deployment or printer state was
changed. No new runtime flag or WASM integration is claimed. Native Zig suites,
physical-printer workflows and third-party integrations were not rerun for
this tooling/documentation change.

## 2026-10-24: Native Forge-X compatibility

Requested: implement the missing Forge-X features identified by the separate
source/API comparison. Reference: Forge-X `1.4.2`,
`f2c3f272d6e27400818a514d9d31d754eeb1b5e3`, with the upstream vendor pin and both
API baselines unchanged.

Added the validated startup profile `--compat moonraker|forge-x`, CLI schema/help
and API-dump identity. The Forge-X profile selects packaged G-code conversion,
stock print macros, object-query scope, updater service verification and
automatic-refresh skip markers. Standard `moonraker.asvc` loading is shared.
Native timelapse loads from configuration, with bounded HTTP capture, persisted
settings, quiet macro acknowledgements, print-session/final-frame handling,
generation cancellation, ZIP export and FFmpeg video/preview output. Feather
status refresh and active-token progress/failure forwarding are implemented.
See `docs/api/FORGE_X.md`, `docs/TIMELAPSE.md` and `docs/FILE_MANAGEMENT.md` for
behavior and limits.

Upload tests exposed a write-only atomic staging descriptor being reused as a
reader. Conversion now reopens the checked temporary name and verifies its inode;
ordinary uploads retain single-file staging when their destination is unchanged.
Truncated forms cannot publish. Update-progress temporary JSON now uses a scoped
arena; service allowlist parsing preserves state on invalid/allocation-failed
replacement. Capture/output publication checks its generation, and parked
acknowledgements cannot release a later generation. Git conflict paths are
bounded, deduplicated and UTF-8 safe.

Verification: `scripts/test.sh Debug`, `ReleaseSafe` and `ReleaseFast` each
completed with 1,803 passed, one physical-Klippy skip and zero failures, including
342 bounded fuzz tests. Native FFmpeg encoded and decoded an MP4 and generated a
rotated JPEG preview. Loopback HTTP tests exercised snapshot size limits and
multipart fields arriving after a 3MF archive. Service tests used injected
runners; Git refresh/update fixtures used owned local repositories. All four
build-policy tests and their two fuzz tests passed. All 114 Python tooling tests,
the focused Ruff syntax/undefined-name check, Zig formatting and whitespace
checks passed.

Both source scans have no API drift. Runtime dumps retain upstream coverage of
123/123 paths, 130/130 RPC names and 27/27 notifications, and now cover Forge-X
121/121 paths, 129/129 RPC names and 28/28 notifications. The generated table was
updated from the verified dump and its check passes. These are name counts,
not a claim of complete behavioral equivalence. CI has separate coverage gates
and installs FFmpeg for native encoding fixtures; hosted CI was not run here.

Static ARM32 Cortex-A7 ReleaseSafe/ReleaseSmall and AArch64 Cortex-A53
ReleaseSmall builds succeeded. An isolated ARM ReleaseSmall probe inside the
printer chroot on `127.0.0.1:7126` returned ready state, live print/heater status
and filesystem-capacity/directory results. It used a private data directory and
only read-only requests. The first copy exhausted the printer's small temporary
filesystem; only this attempt's files were removed before using the smaller
binary. Probe configuration preserved Forge-X's required
`file_system_observer: none` on its kernel without inotify and trusted only
loopback. The probe was stopped, port 7126 checked clear and its files removed.
Production on 7125 remained ready, with the print complete and both heater
targets zero. No production binary/config/database was replaced or directly
opened, and no motion, heater, update, reboot or shutdown action was requested.
The native Debug host binary was restored after cross builds.

Real camera optics, parked motion, macro/UI dialogs, service updates and
third-party integrations remain hardware/integration checks, not fixture-proven
claims. The package version is unchanged; no release or production deployment
was performed. Python-version identity, API 1.5.0, missing-CAN empty results,
optional components and existing safety no-ops remain deliberate. Full Python
component loading, Jinja2, LDAP, Apprise and a WASM extension host were not added.
`graphify-out/graph.json` exists, but `graphify` is not installed, so its update
was skipped and no graph artifact was changed.

## 2026-10-24: Prepare v0.3.0

Requested: a new minor release, deployment to the existing Forge-X printer and
README instructions for running it. Bumped the package from 0.2.3 to 0.3.0 and
added release notes for the native Forge-X implementation and separate API
tracker. The README now documents the Cortex-A7 asset, checksum verification,
persistent storage, chroot/config/database paths, explicit compatibility profile,
launcher, safe stopped-database backups and rollback. Existing v0.2.3 benchmark
results keep their measured version. Publication and deployment results follow
after verification; no deployment success is claimed by this preparation entry.

Preparation checks pass: native package identity reports 0.3.0; upstream and
Forge-X registration coverage remain 100%, and the generated API table passes
its freshness check. All 114 Python tooling tests, four build-policy tests,
Python lint/format/type checks, measurement smoke tests, Zig formatting,
SQLite source hashes and whitespace checks pass. Complete daemon suites and
the seven-profile release matrix are running before tag publication.

The new-version Debug suite passes 1,803 tests with one skip and 342 fuzz tests.
The README download block stops on any failed download or checksum before
copying an executable. The read-only production baseline is ready with all
26 components healthy, all 262 requested subscription objects present, valid
directory capacity and both heater targets zero. Production is still v0.2.3.

## 2026-10-24: v0.3.0 publication and deployment

Annotated tag `v0.3.0` points to
`b6f56018c9ae789f031125c5cd1d1eb1123a3f12`. Commits and tag were pushed
normally to origin; no force push or verification bypass was used.
[Main CI](https://github.com/maci0/phobos/actions/runs/40071654973) and
[tag CI](https://github.com/maci0/phobos/actions/runs/40072436851) completed
successfully. The publication job verified its uploaded files before publishing
the [release](https://github.com/maci0/phobos/releases/tag/v0.3.0).

Fresh local Debug, ReleaseSafe and ReleaseFast suites each pass 1,803 tests,
with one gated real-Klippy skip, zero failures and 342 fuzz tests. All seven
local static ReleaseFast profiles build and pass ELF/ABI/checksum validation.
Every local release checksum and profile entry matches the green main-CI bundle
and the subsequently downloaded public release. The earlier preparation checks
also cover 114 Python tooling tests, four build-policy tests, both 100% API
registration gates, generated-table freshness, formatting/lint/type checks,
measurement smoke tests and SQLite source hashes. The native Debug host binary
was restored and reports package version 0.3.0. No new performance comparison
is claimed; v0.2.3 measurements retain their original labels.

Deployment used the Cortex-A7 asset from the green main-CI bundle while tag CI
ran. It matches the published binary byte for byte, SHA256
`0069056fcff9baf8c1edc612869180e863883eba2808b7805a88b1a84a2f30ef`.
Before stopping the exact verified v0.2.3 PID, a fresh check confirmed print
complete, idle, ready and both heater targets zero. Preserved the running old
executable, launcher and configuration in the private backup directory
`/data/phobos-backups/v0.3.0-20261024T070206Z/`. After phobos stopped, copied
its database and any WAL/SHM files there. No external database tool opened the
live database. The saved database SHA256 is
`d6bca7b80e685f0048eee93f4767f73ab9e8073ce3f06c2c9bf3b092f2b26b15`.
The replacement was staged on persistent storage and the launcher replaced
atomically, with automatic rollback available on failed health checks.

Production PID 16706 runs `/data/phobos-v0.3.0 --compat forge-x -d
/root/printer_data` inside `/data/.mod/.forge-x`, serving 7125. Its package
identity and executable hash match the release. The final check reports Klippy
ready, no failed components or warnings, all 26 production components and
262/262 requested subscription objects. All 273 history jobs remain. Directory
capacity is valid. The four temperature stores advance from two samples after
startup to 659 each at final capture. Fluidd subscription parameters, an
existing saved settings array-key read and HTTP 200 page retrieval pass without
writing settings or issuing hardware commands. A missing nested settings key
returns the expected not-found response, not invalid params. The empty console
store is readable; visible console event delivery was not newly exercised.
The C/Zig floating-point probe also passed on the physical Cortex-A7.

The printer remains idle with both heater targets zero. Board boot ID
`6213a6c1-a3b6-4b38-b637-5aa9a116a117` is unchanged. No board/firmware/Klipper
restart, motion, heating, real update or system power action was requested.
No probe listens on 7126. Owned deployment-check files were removed; the
rollback backup and installed executable remain. Existing boot integration was
left unchanged, and no reboot was used to test startup persistence.

The session had no available browser, so Fluidd was checked through HTTP and
WebSocket requests rather than visually. Real camera/parking/print-macro and
managed-update workflows retain their documented hardware/integration limits.
API/software/Python identity, missing-CAN results and safety no-ops remain
deliberate. `graphify` remains unavailable, so no graph refresh was performed.

## 2026-10-24: Check the user-initiated reboot

The delayed response to the earlier connectivity question arrived after v0.3.0
had already been deployed. The user rebooted the printer. Its new boot ID is
`68cde3ec-7565-4002-8cf5-74df2701d63f`. The unchanged Forge-X boot service
started Python Moonraker as PID 2078; it became ready, idle, with both heater
targets zero and 273 history jobs. This confirms that updating the manual
`/data/phobos-run.sh` launcher alone does not select phobos at boot.

After checking the exact Python executable, command line, chroot and PID file,
stopped only that API daemon. Saved its service script and manual launcher and,
after it stopped, copied the database and any WAL/SHM files into the private
backup `/data/phobos-backups/post-reboot-v0.3.0-20261024T094348Z/`. Started the
already-published v0.3.0 through Forge-X's existing `start-stop-daemon`, with
PID tracking in `/run/moonraker.pid`. Production PID 2326 is phobos, ready with
26 healthy components, all 273 history jobs, idle and both heater targets zero.
The binary checksum still matches the release. No further board or Klipper
restart, motion, heating or update was requested.

Prepared a one-line service change and updated the README's boot instructions.
The actual BusyBox helper matches `/proc/PID/cmdline`, so its executable matcher
must use `/data/phobos-v0.3.0` directly. A shell launcher replaces itself and
cannot be matched afterward. Non-mutating process-match checks confirm that
difference. The proposed direct-binary launch with `-o` passes a live repeated
start test: the PID stays 2326, the helper returns success and the API remains
ready. Shell syntax and whitespace checks pass. Daemon source and release
assets did not change, so the complete suites were not repeated.

The service file `/opt/config/mod/.root/S65moonraker` remains unchanged while
approval is pending: the user's earlier restriction protects `/opt/config`.
The proposed edit selects the installed binary, keeps logging and compatibility
arguments, and preserves the existing Forge-X setup and stop/PID-file handling.
It does not require a board reboot. Startup on a subsequent reboot remains
unverified and will still select Moonraker until that service change is applied.
