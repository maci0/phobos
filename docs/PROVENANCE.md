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
