# AGENTS.md: coding conventions for phobos

Phobos is a memory-efficient Zig 0.17 reimplementation of Moonraker. Status lives
in `TODO.md`, workflow in `DEVELOPMENT.md`, architecture and measurements in `docs/`.
The append-only change and verification ledger is `docs/PROVENANCE.md`.

## Project goals (weigh every change against these)

- **Low memory use is a primary goal.** Target: a static musl binary on 32-bit
  ARM (Cortex-A7). Historical measurements are in `docs/MEMORY.md`; they are not a current
  performance guarantee. Reproduce with `scripts/measure-memory.sh`. Rules:
    - prefer fixed, stack, and caller-provided buffers; use `std.heap`
      allocators only when a fixed buffer cannot bound the size
    - per-request work uses an arena freed on return; keep long-lived state
      minimal and do not cache what is cheap to recompute
    - bound every buffer, ring, and queue; no unbounded growth on hostile or
      large input
    - no per-item heap churn in hot paths (status fan-out, parsing): reuse
      buffers, stream instead of accumulating
    - a new dependency or a large static table needs a memory justification
- **100% Moonraker API parity** (surface and behaviour). The coverage gate and
  the conformance oracle must stay green.
- **Idiomatic Zig.** Generate tables and dispatch with `comptime` and
  `@typeInfo` instead of runtime duplication; tagged unions with exhaustive
  `switch` (no `else` where the compiler should catch new cases); explicit
  error sets with `try`/`errdefer`; slices over pointers; `defer` for cleanup.
  Move work to compile time wherever it removes runtime cost or branches.

## Stay on Zig 0.17.0

Zig 0.17 has no `std.fs.cwd`, `std.posix.access`, `std.Thread.Mutex`, or
`std.Thread.sleep`. Verify an API exists before using it. `std.Thread.spawn`
and `join` exist and run the background workers; only the `std.Thread` sync
primitives are gone, so use `std.Io.Mutex`.

- Use `std.Io` paths:
    - filesystem through `std.Io.Dir.cwd().<op>(io, ...)` (`openFile`,
      `writeFile`, `access`, `createDirPath`, `deleteTree`)
    - sockets through `std.Io.net`; async work and sleeps through the threaded
      `io` handle
    - do not reintroduce `std.fs.cwd()`, `std.net`, `std.Thread.sleep`, or
      `std.Thread.Mutex`

- Use builtins and comptime:
    - `@typeInfo`, `@TypeOf`, `@import("builtin")`
    - `@intCast`, `@fromBackingInt`, `@backingInt`
    - `@memcpy`, `@memset`
    - `@atomicLoad`, `@atomicStore`
    - build lookup tables, enum↔string maps, and per-variant dispatch from a
      tagged union with `comptime`; `inline for` over a comptime spec list (the
      proxy and endpoint spec arrays) keeps the data in one place at zero
      runtime cost
    - exhaustive `switch` on enums and tagged unions, without `else`, where the
      compiler should flag every new case
    - Zig has no `@builtin`; platform and build info is
      `const builtin = @import("builtin");`

- No low-level OS work by default:
    - no direct syscalls
    - no new fork/exec code
    - no `std.os`, `std.posix`, or raw libc unless Zig 0.17 has no API for it
    - unavoidable low-level code sits behind a local wrapper
    - platform exceptions: termios in `serial.zig`, system identity and the V4L2 layout in
      `machine.zig`, and the C `statvfs` shim. Use typed platform declarations;
      reads, close, cancellation, and device control go through `std.Io`.
      `docs/STDLIB.md` lists the checked APIs and adapter limits.
    - socket addresses and bound ports come from `socket.address`, not raw syscalls
    - file-root paths open through `file_manager.Resolved`; its `abs` field is a
      display and cache key only. Mutate through checked directory handles and
      replace uploaded or copied files atomically.
    - timestamps use `std.Io.Clock`; secrets use `io.randomSecure` with errors
      propagated. Pass the startup I/O handle through constructors. `clock_io`
      keeps clocks available before optional component I/O and workers start.
    - interruptible timers use `std.Io.Event.waitTimeout` with an absolute
      deadline to handle spurious wakes. Signal the event before joining the worker.

- Use structured stdlib helpers:
    - `std.mem` for slicing, search, and copying
    - `std.fmt.bufPrint` / `bufPrintSentinel` for fixed buffers
    - `std.testing` helpers in tests
    - `std.heap` allocators only when fixed buffers are not enough

- Make ownership explicit:
    - a function that allocates documents who frees
    - caller-provided buffers for hot paths and config serialization
    - `defer` / `errdefer` throughout
    - known bugs, each hit in this codebase:
        - a StringHashMap key and a struct field duped from the same source must
          be separate allocations, or `deinit` double-frees
        - a setter that replaces an owned slice frees the old one
        - `*Locked` emit variants assume the Core lock is held

- Allocator lifetime, the main source of UAFs and leaks here:
    - never store memory from a per-request or per-message arena in a structure
      that outlives the arena (maps, caches, `last_value`). Dupe into the stable
      owner (`self.gpa`). The arena is freed on return, leaving dangling keys and
      a cross-allocator free at `deinit`.
    - store APIs that deep-copy their input (`publishTopic` → `deepCopyValue`,
      `setMeasurement`) leave the caller owning the builder: `defer
      builder.deinit(gpa)`; the store does not take ownership.
    - free map keys and values with the allocator that made them. A snapshot map
      that aliases another map's entries must not be cleared with
      `clearRetainingCapacity` (it leaks them); deep-copy and free, or free the
      entries explicitly.

- Slices over raw pointers internally:
    - `[]const u8` / `[]u8` in Zig logic
    - `[*:0]const u8` only at C interop boundaries
    - convert with `std.mem.span()` only at those boundaries

- Enum APIs stay consistent: `count`, `toIndex`, `fromIndex`, `toStr`, `label`,
  and a safe default for out-of-range input.

- Errors:
    - return `!T` / `!void`
    - `catch return` on non-critical failure paths
    - no silent `catch {}` outside known best-effort cases (such as hardware
      writes after in-memory state is committed)

- Concurrency:
    - `std.Io.Mutex`, locked through the `io` handle (`lockUncancelable(io)` /
      `unlock(io)`); `std.atomic.Value(T)` for cross-thread scalar flags. Teardown
      paths use `lockUncancelable`: `lock(io) catch {}` followed by a mutation
      unlocks a mutex it never held.
    - the `Core` mutex (`src/server/core.zig`) serializes handler execution and
      notification fan-out; background tasks run outside it. Inbound work on a
      background thread (the MQTT reader, for one) that mutates shared state or
      emits must run under `core.run(io, fn, args)` to serialize with handlers.
    - fan-out over a list whose connections can be removed concurrently: do not
      hold the registry lock across blocking socket writes, which stalls every
      add and remove. Pin under the lock (refcount++), release, write, re-lock,
      drop the refs; `remove` defers the free while pinned. See
      `Connections.broadcast`. Holding the lock throughout is memory-safe but a
      liveness hazard.
    - never select-then-act across a dropped lock without pinning; that is the
      snapshot-pointers-then-write UAF.
    - store every spawned thread or future that references ctx state and join it
      before freeing that state; a fire-and-forget `io.async`/`std.Thread.spawn`
      racing `deinit` is a UAF. Stop with an atomic flag; `shutdown(.recv)`
      unblocks a blocked read before the join.
    - never block on a network round-trip (a Klippy proxy request, for one) while
      holding `Core`. If a handler blocks reading a socket whose reader thread
      needs `Core` to dispatch, the server deadlocks. The Klippy bridge
      (`klippy_connection.zig`) shows the fix: one persistent reader drains the
      socket continuously (a stalled drain lets Klippy's status flood
      backpressure and wedge the server), routes responses to per-id waiters,
      and `request()` releases `Core` for the round-trip while it blocks on its
      waiter. Reuse that pattern for any request/response over a shared,
      continuously-pushed socket.
    - background thread stacks reserve 16 MiB each by default. Pass
      `.{ .stack_size = 1 << 20 }` to `std.Thread.spawn` (enough for bounded
      JSON/TLS/HTTP work) to keep VmSize small.

- Process spawning:
    - `std.process` only where Zig 0.17 environment handling is safe
    - go through a mockable command runner (`machine.zig` `RunCmdFn`) so the
      logic is unit-testable without touching the host
    - host-mutating commands (reboot, shutdown, apt, pip) are deliberate no-ops;
      never run them by default

- Tests:
    - Python tool tests use a project-local `--basetemp=.scratch/<name>`.
      Measurement helpers keep captures, data and build prefixes below `.scratch/`
      and terminate only child PIDs they created. Do not restore fixed shared
      Klippy sockets or process-group cleanup signals.
    - temperature sampling and automatic update refresh start only in the daemon
      entry point. Tests tick them synchronously; no sampler uses the testing
      allocator.
    - tests sit at the bottom of each module (`test { ... }` blocks)
    - every function gets a unit test and a fuzz test (project rule)
    - pure tests for parsers, builders, and helpers
    - tests run under `std.testing.allocator`, which catches leaks and
      double-frees; exercise allocation paths with it (arenas hide these bugs)
    - fuzz harnesses are deterministic and bounded
    - update tests fetch only local temporary repositories, never the checkout's
      `origin` or a real deployment
    - fixtures (datadirs, config files, sockets, fake sysfs roots, missing
      paths) live in a `std.testing.tmpDir`, never a fixed `/tmp` or cwd path.
      `App.init` takes the datadir; Unix sockets use the relative
      `.zig-cache/tmp/<sub_path>/...` path to fit the 108-byte `sun_path`.
      Every wait in a test has a time deadline.
    - the Klippy sim (`src/testutil/klippy_sim.zig`) does not reproduce a real
      Klippy's continuous status flood or backpressure, so it hides bridge
      concurrency and protocol bugs (a proxy deadlock and a wrong
      `objects/subscribe` shape both passed the sim). Validate bridge and
      transport changes on a real printer: cross-compile, `cat binary | ssh
      root@<printer> 'cat >/tmp/p; chmod +x /tmp/p'`, symlink
      `/tmp/klippy_uds -> /tmp/uds`, run on a port other than 7125, send
      read-only requests only (no gcode, moves, or heating), then kill the
      process and remove the symlink. Diagnose hangs with
      `/proc/<pid>/task/*/wchan` (`unix_stream_read_generic` = blocked read,
      `futex_wait_queue_me` = lock contention).
    - files with no `../` imports run standalone via
      `zig test -target x86_64-linux-musl src/<f>.zig`; files under
      `src/components` use `../` imports and build only via `zig build test`

- build.zig:
    - keep link and backend choices explicit
    - no global-machine assumptions: this host's glibc cannot be linked, so the
      native target defaults to musl; never run a plain `zig build` against glibc
    - project-local cache and config for reproducible test runs

## Build / test quick reference

- DataStore backend: `[database] backend` (`sqlite` | `file`). SQLite (default)
  compiles the tracked amalgamation from `vendor/sqlite/`; its revision and
  checksums are in `vendor/sqlite/README.md`. The file backend stores JSON
  through Zig I/O; the binary still links SQLite.
- Test binary without the build runner's `--listen=-` hang:
  `zig build test-artifact -Doptimize=Debug`, then run the newest standalone
  `.zig-cache/o/<hash>/test --cache-dir=./.zig-cache` under a timeout. Do not pass
  `--test-filter` to the standalone runner or expand all cached test binaries.
- Full suite: `timeout 220 zig build test --summary all`
- `schema` prints a CLI Spec 0.3 document without loading config or binding a
  socket. `-o`/`--output` take `auto`, `text`, or `json`; `auto` is text on a
  pipe. `--dump-api` stdout is the API document. `--version` prints the
  Moonraker compatibility string; `-o json --version` prints the package version.
- Coverage gate (must stay 100%):
  `mkdir -p .scratch && zig build && zig-out/bin/phobos --dump-api > .scratch/api-dump.json &&
   PYTHONPATH=tools uv run --with tree-sitter --with tree-sitter-python python -m api_scanner coverage --baseline api/api_surface.json --phobos .scratch/api-dump.json`
- Release (LTO, stripped): add `-Doptimize=ReleaseSmall`.
- Cross-compile (deploy): `zig build -Dtarget=arm-linux-musleabihf -Dcpu=cortex_a7 -Doptimize=ReleaseSmall`
- Conformance oracle (normalized equality against vendored Moonraker):
  `conformance/replay.py` against `conformance/golden/`.
- Gated real-Klippy integration test: boot the stack with `.testenv/run-klippy.sh`
  (local, gitignored; native Linux host MCU plus Klippy via uv). The test skips
  when `/tmp/klippy_uds` is absent.
