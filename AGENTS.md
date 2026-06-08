# AGENTS.md — coding conventions for phobos

Phobos is a memory-efficient Zig 0.16 reimplementation of Moonraker. See
`TODO.md`, `DEVELOPMENT.md`, and `docs/` for status and architecture.

## Project goals (weigh every change against these)

- **Low memory usage is an EXPLICIT, primary goal.** Target is a static musl
  binary on 32-bit ARM (Cortex-A7). Measured: ~1.2 MB binary, idle RSS ~2.2 MB on
  a real armv7 printer (of which only ~0.7 MB is unreclaimable private-dirty heap)
  vs that same printer's own Moonraker at ~10 MB and desktop Moonraker at
  50–80 MB. Must stay tiny — reproduce with `scripts/measure-memory.sh`, see
  `docs/MEMORY.md`. Concretely:
    - prefer fixed/stack buffers and caller-provided buffers over heap; reach for
      `std.heap` allocators only when a fixed buffer genuinely can't bound the size
    - per-request work uses an arena that is freed on return — keep long-lived
      state minimal; don't cache what you can recompute cheaply
    - bound every buffer/ring/queue; no unbounded growth on hostile/large input
    - avoid per-item heap churn in hot paths (status fan-out, parsing); reuse
      buffers, stream rather than accumulate
    - a new dependency or a large static table needs a memory justification
- **100% Moonraker API parity** (surface + behaviour) — the coverage gate and
  conformance oracle must stay green.
- **Idiomatic Zig.** Lean on the language: `comptime` and `@typeInfo` to generate
  tables/dispatch instead of runtime duplication; tagged unions + exhaustive
  `switch` (no `else` when you want the compiler to catch new cases); explicit
  error sets and `try`/`errdefer`; slices over pointers; `defer` for cleanup.
  Push work to compile time wherever it removes runtime cost or branches.

## Stay on Zig 0.16.0

Avoid writing code that assumes older `std.fs`, `std.net`, or `std.Thread`
synchronization APIs. This Zig build is stripped: `std.fs.cwd`,
`std.posix.access`, `std.Thread.Mutex`, and `std.Thread.sleep` are NOT available
— verify an API exists before using it, and prefer the `std.Io` paths below.
(`std.Thread.spawn`/`join` ARE available and used for background workers; only
the `std.Thread` *sync* primitives are absent — use `std.Io.Mutex` instead.)

- Prefer `std.Io` paths:
    - filesystem through `std.Io.Dir.cwd().<op>(io, ...)` (e.g. `openFile`,
      `writeFile`, `access`, `createDirPath`, `deleteTree`)
    - sockets through `std.Io.net`; the threaded `io` handle for async/sleeps
    - avoid reintroducing `std.fs.cwd()`, `std.net`, `std.Thread.sleep`,
      `std.Thread.Mutex`

- Prefer Zig builtins and comptime — push work to compile time:
    - `@typeInfo`, `@TypeOf`, `@import("builtin")`
    - `@intCast`, `@enumFromInt`, `@intFromEnum`
    - `@memcpy`, `@memset`
    - `@atomicLoad`, `@atomicStore`
    - use `comptime` to build lookup tables, derive enum↔string maps, and
      generate per-variant dispatch from a tagged union instead of hand-writing
      parallel runtime code; `inline for` over a comptime spec list (e.g. the
      proxy/endpoint spec arrays) keeps the data in one place with zero runtime cost
    - exhaustive `switch` on enums/tagged unions WITHOUT an `else` where you want
      the compiler to flag every new case
    - Note: Zig has no `@builtin`; platform/build info is `const builtin =
      @import("builtin");`.

- Avoid low-level OS work by default:
    - no direct syscalls
    - no new fork/exec code
    - avoid `std.os`, `std.posix`, raw libc unless there is no Zig 0.16 API
    - keep any unavoidable low-level code behind a local wrapper
    - sanctioned exceptions already in use (no `std.Io` equivalent — reuse these
      patterns, don't invent new ones): termios in `serial.zig`, the bound-port
      read via `std.os.linux.getsockname` (mirror `io.zig` `Listener.port`),
      `std.os.linux.clock_gettime` for timestamps, sysfs GPIO in `gpio_sysfs.zig`

- Prefer structured stdlib helpers:
    - `std.mem` for slicing/search/copying
    - `std.fmt.bufPrint` / `bufPrintZ` for fixed buffers
    - `std.testing` helpers in tests
    - `std.heap` allocators only when fixed buffers are not enough

- Make ownership explicit:
    - functions that allocate should document who frees
    - prefer caller-provided buffers for hot paths and config serialization
    - use `defer` / `errdefer` consistently
    - watch for the classic bugs (all hit real defects in this codebase):
        - a StringHashMap key and a struct field duped from the same source must
          be SEPARATE allocations (else double-free in deinit)
        - a setter that replaces an owned slice must free the old one
        - `*Locked` emit variants assume the Core lock is already held

- Allocator lifetime — the #1 source of UAF/leaks here:
    - NEVER store memory allocated from a per-request / per-message arena into a
      structure that outlives that arena (maps, caches, `last_value`, etc.). Dupe
      into the owning *stable* allocator (`self.gpa`) instead. The arena is freed
      on return → dangling keys + cross-allocator free at `deinit`.
    - "store" APIs that DEEP-COPY their input (e.g. `publishTopic` →
      `deepCopyValue`, `setMeasurement`) leave the caller owning the builder —
      `defer builder.deinit(gpa)` it; do not assume the store took ownership.
    - keys/values in a map must be freed with the SAME allocator that made them;
      a snapshot map that aliases another map's entries must not be cleared with
      `clearRetainingCapacity` (leaks the entries) — deep-copy + free, or free
      the entries explicitly.

- Prefer slices over raw pointers internally:
    - use `[]const u8` / `[]u8` for Zig logic
    - reserve `[*:0]const u8` for C interop boundaries only
    - convert with `std.mem.span()` only at boundaries

- Keep enum APIs consistent:
    - `count`, `toIndex`, `fromIndex`, `toStr`, `label`, out-of-range safe default

- Use errors idiomatically:
    - return `!T` / `!void`
    - use `catch return` for non-critical failure paths
    - avoid silent `catch {}` except known acceptable best-effort cases
      (e.g. best-effort hardware writes after in-memory state is committed)

- For concurrency:
    - use `std.Io.Mutex` (lock via the `io` handle: `lockUncancelable(io)` /
      `unlock(io)`); use `std.atomic.Value(T)` for cross-thread scalar flags.
      On teardown paths use `lockUncancelable` — `lock(io) catch {}` then mutating
      is a bug (you'd unlock without holding it).
    - the `Core` mutex (`src/server/core.zig`) serializes handler execution and
      notification fan-out; background tasks run OUTSIDE it. Inbound work from a
      background thread (e.g. the MQTT reader) that mutates shared state or emits
      MUST run under `core.run(io, fn, args)` so it serializes with handlers.
    - fan-out over a shared list while connections can be concurrently removed:
      do NOT hold the registry lock across the (blocking) socket writes — that
      stalls all add/remove. Instead pin under the lock (refcount++), release,
      write, re-lock and drop the refs; `remove` defers the free while pinned.
      See `Connections.broadcast`. (Holding the lock the whole time is also
      memory-safe but a liveness hazard; the refcount pattern is preferred.)
    - never select-then-act across a dropped lock without pinning — the classic
      snapshot-pointers-then-write UAF.
    - background threads/tasks: store EVERY spawned thread/future that references
      ctx state and join it before freeing that state (a fire-and-forget
      `io.async`/`std.Thread.spawn` racing `deinit` is a UAF). Use an atomic stop
      flag; `shutdown(.recv)` to unblock a blocked read before joining.
    - NEVER block on a network round-trip (e.g. a Klippy proxy request) while
      holding the `Core` lock. A handler runs under `Core`; if it then blocks
      reading a socket whose reader thread needs `Core` to dispatch, you deadlock
      and wedge the whole server. The Klippy bridge (`klippy_connection.zig`)
      solves this: ONE persistent reader continuously drains the socket (so Klippy
      never backpressures on its status flood — a stalled drain was a real wedge),
      routes responses to per-id waiters, and `request()` RELEASES `Core` for the
      round-trip and blocks on its waiter. Reuse that pattern for any
      request/response over a shared, continuously-pushed socket; cap stack
      reservations on background threads (`.{ .stack_size = 1 << 20 }`).
    - background thread stacks default to 16 MiB reserved each — pass
      `.{ .stack_size = 1 << 20 }` to `std.Thread.spawn` (ample for bounded
      JSON/TLS/HTTP work) to keep VmSize small.

- For process spawning:
    - use `std.process` only where Zig 0.16 environment handling is safe
    - prefer a mockable command-runner (see `machine.zig` `RunCmdFn`) so logic is
      unit-testable without touching the host
    - NEVER run host-mutating commands (reboot/shutdown/apt/pip) by default —
      those are deliberate no-ops

- For tests:
    - keep tests at the bottom of modules (`test { ... }` blocks)
    - every function gets a unit test AND a fuzz test (project rule)
    - add pure tests for parsers/builders/helpers
    - tests run under `std.testing.allocator` — it detects leaks/double-free, so
      exercise allocation paths with it (arenas mask these bugs)
    - keep fuzz harnesses deterministic and bounded
    - the Klippy sim (`testutil/klippy_sim.zig`) does NOT reproduce a real
      Klippy's continuous status flood or backpressure, so it MASKS bridge
      concurrency/protocol bugs (a proxy deadlock + a wrong `objects/subscribe`
      shape both passed the sim and only showed against a real Klippy). For
      bridge/transport changes, cross-compile and validate against a real printer:
      `cat binary | ssh root@<printer> 'cat >/tmp/p; chmod +x /tmp/p'`, symlink
      `/tmp/klippy_uds -> /tmp/uds`, run on a NON-7125 port, hit it READ-ONLY
      (no gcode/move/heat), then kill + remove the symlink. Diagnose hangs with
      `/proc/<pid>/task/*/wchan` (e.g. `unix_stream_read_generic` = blocked read,
      `futex_wait_queue_me` = lock contention).
    - standalone-testable files (no `../` imports) run via
      `zig test -target x86_64-linux-musl src/<f>.zig`; files under
      `src/components` use `../` imports and build only via `zig build test`

- For build.zig:
    - keep link/backend choices explicit
    - avoid global-machine assumptions (this host's glibc cannot be linked; the
      native target defaults to musl — never run plain `zig build` against glibc)
    - prefer project-local cache/config for reproducible test runs

## Build / test quick reference

- phobos always links the vendored LMDB (no no-lmdb / NullStore mode). There is
  no `-Dwith_lmdb` option.
- Build test binary (avoids the `--listen=-` hang):
  `zig build test-artifact && ./.zig-cache/o/*/test --cache-dir=./.zig-cache`
- Full suite: `timeout 220 zig build test --summary all`
- Coverage gate (must stay 100%):
  `zig build && zig-out/bin/phobos --dump-api > /tmp/d.json &&
   PYTHONPATH=tools python3 -m api_scanner coverage --baseline api/api_surface.json --phobos /tmp/d.json`
- Release (LTO + stripped): add `-Doptimize=ReleaseSmall`.
- Cross-compile (deploy): `zig build -Dtarget=arm-linux-musleabihf -Dcpu=cortex_a7 -Doptimize=ReleaseSmall`
- Conformance oracle (normalized equality vs vendored Moonraker): see
  `conformance/replay.py` against `conformance/golden/`.
- Gated real-Klippy integration test: boot the stack with `.testenv/run-klippy.sh`
  (native linux host MCU + klippy via uv); the test skips when `/tmp/klippy_uds` is absent.
