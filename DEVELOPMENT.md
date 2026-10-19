# Development Guide

How to build, test, and extend phobos. Read [`TODO.md`](TODO.md) first for current status
and what's next; read this for *how* to work in the codebase.

## 0. Non-negotiable rules

1. **No AI attribution anywhere** — commits, code comments, docs, PRs. Write as a human.
   Commit with `git -c user.name='maci' -c user.email='maci.stgn@gmail.com' commit`.
2. **Every function gets a unit test AND a fuzz test**, written alongside the
   implementation (not later), in the same file as `test {}` blocks.
3. **TDD**: write the failing test → run it and watch it fail → minimal implementation →
   run it and watch it pass → commit. Small, frequent commits.
4. **Use the standard library for I/O** — `std.Io.net` + `std.Io.Threaded` for sockets,
   `std.http` for HTTP and WebSocket servers. The standard library has no WebSocket
   client; keep masked client frames in `components/ws_client.zig`.
5. **Match upstream exactly** — every component reads its
   `vendor/moonraker/moonraker/components/<name>.py` to copy endpoint paths, params,
   response shapes, and error semantics. The goal is identical observable behavior.

## 1. Toolchain

- **Zig 0.17.0** (pinned; this repo uses APIs specific to 0.16's "Io rewrite", updated for 0.17).
- Python 3 + `uv` for the `api_scanner` tooling.
- Vendored Moonraker source is gitignored. Restore it:
  ```sh
  git clone --depth 50 https://github.com/Arksine/moonraker vendor/moonraker
  # pinned commit: 9008485
  ```

## 2. Building & testing

> **Host quirk:** Zig 0.16 cannot link the system glibc on some hosts (GCC 16 `.sframe`
> relocation), and the deploy target is musl anyway. The build defaults the native target
> to **musl**, so the commands below work. **Never run a plain glibc `zig build`.**

```sh
# Full suite (vendors SQLite; first compile of the C amalgamation is slow — timeout-wrap)
timeout 220 zig build test --summary all

# A single file that has NO ../ imports (e.g. config, jsonrpc, store):
zig test -target x86_64-linux-musl src/config/confighelper.zig

# Cross-compile the deploy binary:
zig build -Dtarget=arm-linux-musleabihf -Dcpu=cortex_a7 -Doptimize=ReleaseSmall
file zig-out/bin/phobos   # -> ELF 32-bit ARM, statically linked
```

Notes:
- For the standalone runner, build with `zig build test-artifact -Doptimize=Debug`,
  then run the newest `.zig-cache/o/*/test --cache-dir=./.zig-cache` under a timeout.
  After an ARM build, restore `zig-out/bin/phobos` with `zig build -Doptimize=Debug`
  before running the host suite.
- Files under `src/components/`, `src/testutil/`, `src/transport/` use `../` imports and
  **only build via `zig build test`** (the module root is `src/main.zig`). Single-file
  `zig test` fails on them with "import of file outside module path".
- Always run socket/WS tests under a `timeout` — a bug can deadlock and hang the suite.
- DataStore backend selectable via `[database] backend`: vendored SQLite (default) or pure-Zig file backend.

## 3. Zig 0.17 cheat sheet (verified against the installed std)

These differ from older Zig docs — use these forms:

- **Allocator**: `var gpa: std.heap.DebugAllocator(.{}) = .init; defer _ = gpa.deinit();`
  (`GeneralPurposeAllocator` is gone). Tests: `std.testing.allocator`. The threadsafe
  allocator for `Threaded.init` is `std.heap.smp_allocator`.
- **ArrayList is unmanaged**: `var xs: std.ArrayList(T) = .empty;` then
  `try xs.append(alloc, item)`, `xs.deinit(alloc)`, `xs.items`.
- **Fuzzing**: `try std.testing.fuzz(ctx, testOne, .{});` where
  `testOne: fn(@TypeOf(ctx), smith: *std.testing.Smith) anyerror!void`. Fill bytes with
  `smith.bytesWithHash(&buf, 0)`; bounded ints with
  `smith.valueRangeAtMostWithHash(u8, 0, 255, 0)`. The input is a `*Smith`, **not** a byte
  slice.
- **Networking**: use `std.Io.net` over `std.Io.Threaded`. Bound and accepted sockets
  expose their address in `socket.address`, including ephemeral ports through
  `getPort()`. Use `IpAddress.parse` for either IP family and `HostName.connect`
  for DNS. Accepted socket addresses identify the peer.
- **HTTP/WS**: `std.http.Server.init(reader, writer)` over a `std.Io.net.Stream`;
  `receiveHead()`, `request.respond(body, .{...})`, `request.respondWebSocket(...)`,
  `ws.readSmallMessage()` / `ws.writeMessage(bytes, .text)`. Client:
  `std.http.Client.fetch(...)`. Secure WebSocket and MQTT clients share the
  heap-stable `std.crypto.tls.Client` state in `util/tls.zig`.
- **JSON**: parse with `std.json.parseFromSlice(std.json.Value, alloc, src, .{})`;
  serialize with `std.json.Stringify`. `Value.object` is an insertion-ordered
  `StringArrayHashMap`. `ObjectMap` is unmanaged (`.empty`, `put(alloc, k, v)`); `Array`
  is managed (`.init(alloc)`, `append(v)`).
- **Mutex**: `std.Thread.Mutex` does **not** exist here; use `std.Io.Mutex` (it cooperates
  with the Threaded scheduler). `lockUncancelable(io)` for a non-erroring critical section.
- **Filesystem**: `std.fs.cwd()` is gone; FS ops need `std.Io.Dir`/`std.Io.File` + a live
  `io`. Virtual files (`/proc`, `/sys`) report size 0 — read by streaming to EOF, not by
  size-based `allocRemaining`.
- **errno on raw linux syscalls**: `std.os.linux.errno(rc)` returns `std.os.linux.E`.

## 4. The concurrency model (read before touching handlers or notifications)

- Handlers run via `core.run(io, fn, args)` which holds the **single Core mutex**. So
  while a handler executes, the Core lock is **held**.
- The Core mutex is **non-reentrant**. Anything a handler calls that re-acquires it
  **deadlocks the whole server**.
- Therefore, to emit a notification from inside a handler, use **`NotifyBus.emitLocked`**
  (does not take the Core lock), never `NotifyBus.emit` (takes it → deadlock).
- `Connections.add` / `nextId` take the Core lock to share the monotonic sequence — so do
  **not** call them from inside a handler that already holds the lock, and do **not** hold
  the Core lock in a unit test while calling code that re-enters it (this exact mistake
  hung the suite once — see `TODO.md`).
- Each connection has its own write mutex so a notification and a JSON-RPC response can't
  interleave on the same socket.

## 5. Adding (or completing) a component — the standard pattern

Every component follows the same shape. Use `src/components/power.zig` (correct
notification emission) and `src/components/database.zig` (store-backed CRUD) as templates.

1. **Read the source of truth**: `vendor/moonraker/moonraker/components/<name>.py`. Note
   every endpoint's path, HTTP methods, params, response shape, error responses, and any
   `notify_*` it emits and the exact payload.
2. **Create `src/components/<name>.zig`** with:
   - A `Ctx` struct holding what it needs (`DataStore`, `*NotifyBus`, config, and — if it
     emits notifications — `io: ?std.Io` plus a `pub fn setIo(self, io)`).
   - One handler per endpoint:
     `fn handleX(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value`.
     Cast `ctx`, do the work, build the result `std.json.Value` in `alloc`.
   - For notifications: `const io = ctx.io orelse return; bus.emitLocked(io, notify.names.X, .{ .array = arr }) catch {};`
   - A `pub fn registerX(app/registry, ctx)` that registers each endpoint via
     `Registry.registerEndpoint` with the correct `ApiDef` (path, methods, transports,
     `wrap_result`, `auth_required`). The registry derives the JSON-RPC method name.
3. **Wire it into `src/app.zig`**: add the `Ctx` to `App`, init/deinit it, call
   `registerX` from `registerAll()`, and (if it emits) call `ctx.setIo(io)` in
   `httpServer()`.
4. **Tests** (in-file): integration via `TestServer` (round-trip each endpoint, assert
   exact shapes), unit tests for pure helpers, a fuzz harness per function, and — for any
   emitting handler — a **socket-level** test that issues a real request and asserts the
   notification arrives (with a bounded wait so a deadlock fails fast). Match error shapes.
5. **Verify**:
   ```sh
   timeout 220 zig build test
   tools/coverage.sh            # must stay at / reach 100%
   ```
6. **Commit** with a Conventional-Commits message, no AI attribution.

When a subsystem is genuinely absent (Klippy, MQTT broker, real hardware), register the
endpoints with **faithful shapes / the exact Moonraker error** and note the stub in a code
comment — don't invent behavior, and don't skip the endpoint.

## 6. The API coverage / drift tooling

`tools/api_scanner/` is an AST-based extractor of Moonraker's API surface. Keep it green.

```sh
# regenerate the baseline after bumping vendor/moonraker:
PYTHONPATH=tools python3 -m api_scanner baseline --source vendor/moonraker/moonraker

# fail-on-drift gate (CI): exit 1 if the surface changed vs the committed baseline
PYTHONPATH=tools python3 -m api_scanner diff --source vendor/moonraker/moonraker \
  --baseline api/api_surface.json

# coverage of phobos vs the baseline (exit 0 == 100%)
tools/coverage.sh

# scanner's own tests
uv run --with pytest python -m pytest tools/api_scanner/tests -q
```

When upstream Moonraker adds/changes endpoints, `diff` shows exactly what moved; implement
the delta in phobos, regenerate the baseline, and confirm `coverage` is back to 100%.

## 7. Definition of done for a change

- Suite green: `zig build test` (or the direct test binary).
- `tools/coverage.sh` exits 0 (still 100%).
- New/changed functions have unit **and** fuzz tests.
- Emitting handlers have a socket-level notification test.
- No AI attribution; commit message is conventional and human.
- If you added a stub or a known limitation, it's noted in the code and in `TODO.md`.

## Runtime ownership and native I/O

See [standard library choices](docs/STDLIB.md) for APIs and platform adapters.

Pass the startup `std.Io` handle through component constructors. `clock_io` keeps
clocks available before optional workers and notifications start. Use
`std.Io.Clock` for timestamps and `io.randomSecure` for secrets, propagating
entropy failures. Timer workers wait on an owned `std.Io.Event`; signal it before
joining. Workers that can block in a network handshake use an owned
`std.Io.Future` so teardown can cancel the operation.

Persistent JSON snapshots deep-copy request/message data into their stable
owner. Print statistics alternate between two reusable arenas; callers borrow
the snapshot until the next update. Cross-thread printing checks use the atomic
flag. Background Klippy pushes enter Core before modifying component state;
response correlation stays outside Core so pending requests can complete.

Use `createDirPathOpen` for data roots and database parents that may already be
directory symlinks. `createDirPath` rejects an existing final symlink in the
installed threaded backend. File-backed namespace replacement uses
`Dir.createFileAtomic`, syncs the complete temporary file, then replaces the
previous namespace. Namespace replacement does not claim directory-fsync
protection against power loss.
