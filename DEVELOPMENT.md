# Development Guide

How to build, test, and extend phobos. [`TODO.md`](TODO.md) has current status and
open work; this file covers how to work in the codebase.

## 0. Non-negotiable rules

1. **No AI attribution** in commits, code comments, docs, or PRs.
   Commit with `git -c user.name='maci' -c user.email='maci.stgn@gmail.com' commit`.
2. **Every function gets a unit test and a fuzz test**, written with the
   implementation, in the same file as `test {}` blocks.
3. **TDD**: write the failing test, watch it fail, write the minimal
   implementation, watch it pass, commit. Small, frequent commits.
4. **Standard library I/O**: `std.Io.net` + `std.Io.Threaded` for sockets,
   `std.http` for the HTTP and WebSocket servers. The standard library has no
   WebSocket client; masked client frames stay in `components/ws_client.zig`.
5. **Match upstream exactly**: each component copies endpoint paths, params,
   response shapes, and error semantics from
   `vendor/moonraker/moonraker/components/<name>.py`. Observable behavior must
   be identical.

## 1. Toolchain

- **Zig 0.17.0** (pinned by `minimum_zig_version` in `build.zig.zon`; the code uses
  the `std.Io` API).
- Python 3 + `uv` for the `api_scanner` tooling.
- Vendored Moonraker source is gitignored. Restore it:
  ```sh
  git clone https://github.com/Arksine/moonraker vendor/moonraker
  git -C vendor/moonraker checkout 900848584374
  ```
- `vendor/sqlite/` contains the pinned amalgamation compiled by the default
  build, currently SQLite 3.54.1. Its manifest records the upstream version,
  source ID, archive/file hashes and absence of local patches.

## 2. Building & testing

> **Host quirk:** Zig cannot link the system glibc on some hosts (GCC 16 `.sframe`
> relocations), and the deploy target is musl anyway. `build.zig` defaults the native
> target to **musl**, so the commands below work. **Never run a plain glibc `zig build`.**

```sh
# Full suite (the first compile of the SQLite amalgamation is slow, so wrap in a timeout)
scripts/test.sh Debug
scripts/test.sh ReleaseSafe
scripts/test.sh ReleaseFast

# A single file with no ../ imports (e.g. config, jsonrpc, store):
zig test -target x86_64-linux-musl src/config/confighelper.zig

# Cross-compile the deploy binary:
zig build -Dtarget=arm-linux-musleabihf -Dcpu=cortex_a7 -Doptimize=ReleaseFast
file zig-out/bin/phobos   # -> ELF 32-bit ARM, statically linked

# Seven static Linux release profiles, with isolated prefixes and ELF/ABI checks:
scripts/build-release.sh
scripts/build-release.sh --verify-only
```

Notes:
- `scripts/test.sh` installs and runs the exact standalone artifact under
  `.scratch/tests-<mode>/bin/phobos-tests`, with bounded build/run timeouts.
  Manual `zig build test-artifact` installs `bin/phobos-tests` under its prefix.
  Do not pass the unsupported runtime `--test-filter` option.
  After an ARM build, restore the host `zig-out/bin/phobos` with
  `zig build -Doptimize=Debug` before running the host suite.
- Files under `src/components/`, `src/testutil/`, and `src/transport/` use `../`
  imports and **build only via `zig build test`** (the module root is
  `src/main.zig`). Single-file `zig test` fails on them with "import of file
  outside module path".
- Run socket and WebSocket tests under a `timeout`; a deadlock otherwise hangs
  the suite.
- `TestServer.startKlippyBridge` waits for the simulator and the bridge's proxy
  gate before returning, so immediate printer requests use the finished handshake.
- DataStore backend: `[database] backend`, vendored SQLite (default) or the
  pure-Zig file backend.
- [Linux build profiles](docs/BUILDS.md) documents the release matrix, CPU and
  kernel requirements, and the C-only `-Dsoftfp` option. Building or validating
  an artifact does not install it or establish compatibility with every printer.
- [Performance](docs/PERFORMANCE.md) and [memory](docs/MEMORY.md) record the
  versioned VM and earlier printer measurements. The VM method records CPU
  reservation and measured scheduling interference. Plots consume checked-in
  measured JSON summaries; raw captures and private configurations stay in
  `.scratch/`.
- [CI and releases](docs/CI.md) documents the hosted test/build matrix,
  `uv.lock`, tag requirements, verified draft publication and local commands.

## 3. Zig 0.17 cheat sheet (checked against the installed std)

These differ from older Zig docs:

- **Allocator**: use `std.process.Init.gpa` at startup and pass `std.mem.Allocator`
  into components. Debug/ReleaseSafe use the checked startup allocator; this
  musl-linked ReleaseFast program uses the libc allocator.
  (`GeneralPurposeAllocator` is gone). Tests: `std.testing.allocator`. The
  owned `Threaded.init` backends need a thread-safe allocator, such as
  `std.heap.smp_allocator`.
- **ArrayList is unmanaged**: `var xs: std.ArrayList(T) = .empty;` then
  `try xs.append(alloc, item)`, `xs.deinit(alloc)`, `xs.items`.
- **Fuzzing**: `try std.testing.fuzz(ctx, testOne, .{});` where
  `testOne: fn(@TypeOf(ctx), smith: *std.testing.Smith) anyerror!void`. Fill bytes with
  `smith.bytesWithHash(&buf, 0)`; bounded ints with
  `smith.valueRangeAtMostWithHash(u8, 0, 255, 0)`. The input is a `*Smith`, not a
  byte slice.
- **Networking**: `std.Io.net` over `std.Io.Threaded`. Bound and accepted sockets
  expose their address in `socket.address`, including ephemeral ports through
  `getPort()`. `IpAddress.parse` handles either IP family; `HostName.connect`
  resolves DNS. An accepted socket's address is the peer.
- **HTTP/WS**: `std.http.Server.init(reader, writer)` over a `std.Io.net.Stream`;
  `receiveHead()`, `request.respond(body, .{...})`, `request.respondWebSocket(...)`,
  `ws.readSmallMessage()` / `ws.writeMessage(bytes, .text)`. Client:
  `std.http.Client.fetch(...)`. The secure WebSocket and MQTT clients share the
  heap-stable `std.crypto.tls.Client` state in `util/tls.zig`.
- **JSON**: parse with `std.json.parseFromSlice(std.json.Value, alloc, src, .{})`;
  serialize with `std.json.Stringify`. `Value.object` is an insertion-ordered
  `StringArrayHashMap`. `ObjectMap` is unmanaged (`.empty`, `put(alloc, k, v)`);
  `Array` is managed (`.init(alloc)`, `append(v)`).
- **Mutex**: `std.Thread.Mutex` does not exist; use `std.Io.Mutex`, which
  cooperates with the Threaded scheduler. `lockUncancelable(io)` gives a
  non-erroring critical section.
- **Filesystem**: `std.fs.cwd()` is gone; FS ops take `std.Io.Dir`/`std.Io.File`
  and a live `io`. Virtual files (`/proc`, `/sys`) report size 0, so stream them to
  EOF instead of a size-based `allocRemaining`.
  File-root operations get checked handles from `file_manager.Resolved`; never open
  its lexical `abs` path. [`docs/STDLIB.md`](docs/STDLIB.md) covers symlink
  handling, atomic writes, and the remaining platform adapters.
- **errno on raw Linux syscalls**: `std.os.linux.errno(rc)` returns `std.os.linux.E`.

## 4. The concurrency model (read before touching handlers or notifications)

Klippy keeps its internal ready state while seeding initial subscriptions.
During a ready handshake, `server.info` reports startup until proxy requests are
available, then publishes ready. Its connected flag includes startup and shutdown.

- Stateful handlers run through the **single Core mutex**. Selected read handlers
  use their own synchronization; blocking network and process work must release
  Core and reacquire it before reading or changing shared component state.
- The Core mutex is **non-reentrant**. Anything a handler calls that re-acquires
  it **deadlocks the server**.
- To emit a notification from a handler, use **`NotifyBus.emitLocked`** (does not
  take the Core lock), never `NotifyBus.emit` (takes it and deadlocks).
- `Connections.add` / `nextId` take the Core lock to share the monotonic
  sequence. Do not call them from a handler that holds the lock, and do not hold
  the Core lock in a unit test while calling code that re-enters it.
- Each connection has its own write mutex, so a notification and a JSON-RPC
  response cannot interleave on one socket.
- MQTT publish and subscribe handlers exclude the MQTT transport because its reader
  must remain available to receive subscription responses. Shutdown wakes subscribers
  before joining workers and permits at most one second for offline publication.
  An unanswered PINGREQ closes the connection after one keepalive interval.
  The dispatcher removes `mqtt_timestamp` and checks duplicates after method
  validation for each request, including batch entries. The last 20 timestamps
  use 640 bytes of SHA-256 fingerprints, preserving numeric equality and object
  key-order independence without retaining request arenas.

Trusted-client authentication accepts forwarded addresses only from a trusted
socket peer, including endpoints where authentication is optional.
Unreadable or malformed auth records abort startup. User creation, key rotation,
password reset, logout and deletion persist before changing live credentials.
Successful logout and deletion notify connection revocation after releasing the
auth mutex. Usernames must be nonempty and contain no dots because the store
uses dots for record paths; unsupported names return 400 before changing state.

## 5. Adding (or completing) a component

Every component has the same layout. Templates: `src/components/power.zig`
(notification emission) and `src/components/database.zig` (store-backed CRUD).

1. **Read the source of truth**: `vendor/moonraker/moonraker/components/<name>.py`.
   Record every endpoint's path, HTTP methods, params, response shape, error
   responses, and each `notify_*` it emits with its exact payload.
2. **Create `src/components/<name>.zig`** with:
   - A `Ctx` struct holding its dependencies (`DataStore`, `*NotifyBus`, config,
     and, if it emits notifications, `io: ?std.Io` plus `pub fn setIo(self, io)`).
   - One handler per endpoint:
     `fn handleX(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value`.
     Cast `ctx`, do the work, build the result `std.json.Value` in `alloc`.
   - Emit handler notifications with `NotifyBus.emitLocked`. Handle allocation
     and transport failures according to the component contract; do not add an
     empty catch as a default.
   - A `pub fn registerX(app/registry, ctx)` that registers each endpoint via
     `Registry.registerEndpoint` with the correct `ApiDef` (path, methods,
     transports, `wrap_result`, `auth_required`). The registry derives the
     JSON-RPC method name.
3. **Wire it into `src/app.zig`**: add the `Ctx` to `App`, init and deinit it,
   call `registerX` from `registerAll()`, and, if it emits, call `ctx.setIo(io)`
   in `httpServer()`.
4. **Tests** (in-file): `TestServer` integration tests that round-trip each
   endpoint and assert exact shapes and error shapes, unit tests for pure
   helpers, a fuzz harness per function, and, for each emitting handler, a
   **socket-level** test that sends a real request and waits a bounded time for
   the notification, so a deadlock fails fast.
5. **Verify**:
   ```sh
   timeout 220 zig build test
   tools/coverage.sh            # must stay at 100%
   ```
6. **Commit** with a Conventional Commits message, no AI attribution.

When a subsystem is absent (Klippy, MQTT broker, real hardware), register the
endpoints with Moonraker's exact shapes or exact error and note the stub in a
code comment. Do not invent behavior and do not skip the endpoint.

## 6. API coverage and drift tooling

`tools/api_scanner/` is an AST-based extractor of Moonraker's API surface. Keep it green.

```sh
# regenerate the baseline after bumping vendor/moonraker:
PYTHONPATH=tools uv run --with tree-sitter --with tree-sitter-python python -m api_scanner baseline --source vendor/moonraker/moonraker

# drift gate: exit 1 if the surface changed vs the committed baseline
PYTHONPATH=tools uv run --with tree-sitter --with tree-sitter-python python -m api_scanner diff --source vendor/moonraker/moonraker \
  --baseline api/api_surface.json

# coverage of phobos vs the baseline (exit 0 == 100%)
tools/coverage.sh

# scanner's own tests
uv run --with pytest --with tree-sitter --with tree-sitter-python python -m pytest tools/api_scanner/tests -q
```

When upstream Moonraker adds or changes endpoints, `diff` lists what moved:
implement the delta, regenerate the baseline, and confirm coverage is back to 100%.

Forge-X uses a separate [`api/forge_x_surface.json`](api/forge_x_surface.json)
baseline and [behavior tracker](docs/api/FORGE_X.md). Pass that baseline
explicitly for Forge-X checks. Do not replace the upstream baseline or infer
behavioral parity from endpoint-name coverage.

## 7. Definition of done

Append the change, requester, source evidence and verification to
[`docs/PROVENANCE.md`](docs/PROVENANCE.md). Record unperformed checks explicitly.

- Suite green: `zig build test` (or the standalone test binary).
- `tools/coverage.sh` exits 0.
- New and changed functions have unit and fuzz tests.
- Emitting handlers have a socket-level notification test.
- No AI attribution; the commit message is conventional and human.
- A new stub or known limitation is noted in the code and in `TODO.md`.

## 8. Runtime ownership and native I/O

[`docs/STDLIB.md`](docs/STDLIB.md) lists the APIs and platform adapters.

Pass the startup `std.Io` handle through component constructors. `clock_io` keeps
clocks available before optional workers and notifications start. Use
`std.Io.Clock` for timestamps and `io.randomSecure` for secrets, propagating
entropy failures. Timer workers wait on an owned `std.Io.Event`; signal it before
joining. Workers that can block in a network handshake use an owned
`std.Io.Future` so teardown can cancel the operation.

Persistent JSON snapshots deep-copy request and message data into their stable
owner. Print statistics alternate between two reusable arenas; callers borrow
the snapshot until the next update. Cross-thread printing checks use the atomic
flag. Background Klippy pushes enter Core before modifying component state;
response correlation stays outside Core so pending requests can complete.

Use `createDirPathOpen` for data roots and database parents that may already be
directory symlinks; `createDirPath` rejects an existing final symlink in the
installed threaded backend. File-backed namespace replacement writes with
`Dir.createFileAtomic`, syncs the complete temporary file, then replaces the
previous namespace. It makes no directory-fsync guarantee against power loss.

Startup parses configuration once and resolves bind and datastore settings
before opening the datastore. File-read errors, parse errors and unknown
backends fail before database creation. `App.setConfig` is the file-loading
entry point; `App.setParsedConfig` consumes an existing parser, including on
error. A component-configuration error requires App teardown because published
configuration strings remain borrowed until then. A second load is rejected.
A persisted queue that cannot be read fails initialization rather than replacing
it with a partial or empty queue.
Enqueue allocates every new job before changing the existing queue. Deleting a
migrated history job commits its table row and KV shadow in one transaction.
History totals and auxiliary fields propagate allocation and store failures;
reset builds the response before changing either persisted or auxiliary totals.
Configuration wildcard matching uses an iterative last-star retry, so repeated
wildcards cannot consume recursive stack space or exponential retry work.
Only an explicit `[database] path` overrides the backend defaults under the
datadir: `database/moonraker-sql.db` for SQLite, `database` for the file backend.
File-backend deployments that used the previous default directory can retain it
by setting `[database] path` to `<data>/database/moonraker-sql.db` explicitly.
SQLite scalar records require their exact encoded length and UTF-8 strings;
corrupt values produce a backend error instead of a substituted value.
SQLite paths reject embedded NUL before creating parents or entering the C API.
Reads and dotted mutations share the migrated history/totals record loader.
Database item keys accept dotted strings or arrays of literal string segments.
Array segments preserve dots in property names, including Fluidd settings keys.
Both storage backends keep the 16-segment bound and reject empty segments.
GET with an absent or null key returns the namespace; responses preserve the
original key type. Internal callers pass a string or `datastore.Key` through
the same item methods; parsed segments borrow their caller for that store call.
WebSocket subscriptions allow 1,024 objects per client and 1,024 fields per
object, with names up to 256 bytes and the existing transport frame limits.
The maps allocate only requested entries. Fluidd subscribes to every object;
the Forge-X configuration exposes 262, exceeding the previous 256-object cap.
Fluidd enables notifications and loads console history after subscription
succeeds, so rejecting that request also leaves its console empty.
KV records shadow complete table records; deleting the final shadow field clears
the backing row in the same transaction so it cannot reappear.
Queue snapshots own their filename/id strings; snapshot and persistence share a
save mutex so concurrent changes cannot commit an older snapshot last. Callers
release the jobs mutex before saving, and backend I/O holds only the save mutex.
Configuration text, including every included file, must be valid UTF-8.

HTTP headers have a fresh absolute one-hour idle deadline per request, matching
Tornado's default. Bodies and upgraded sockets use their own I/O policy. CORS
falls back to trusted IPv4 Origin hosts only when `cors_domains` is nonempty.

Extension agents identify over WebSocket and own their registered Klippy methods
until disconnect. Agent events exclude their originating connection. Transport
code replaces `_connection_id` and injects the actual connection only into
`connection.*` calls. Agent replies correlate on both request and connection id;
response handling remains available while an extension request waits outside
Core. Requests have a twenty-second total deadline, at most 32 global waiters and
16 owned request tasks per WebSocket. Disconnect cancels and joins those tasks,
wakes external callers and removes the agent's methods. Agent/method names are
bounded to 256 bytes, with 256 agents and 256 dynamic methods at most.
