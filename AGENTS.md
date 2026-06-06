# AGENTS.md — coding conventions for phobos

Phobos is a memory-efficient Zig 0.16 reimplementation of Moonraker. See
`TODO.md`, `DEVELOPMENT.md`, and `docs/` for status and architecture.

## Stay on Zig 0.16.0

Avoid writing code that assumes older `std.fs`, `std.net`, `std.posix`, or
`std.Thread` APIs. This Zig build is stripped: `std.fs.cwd`,
`std.posix.access`, and `std.Thread.Mutex` are NOT available — verify an API
exists before using it, and prefer the `std.Io` paths below.

- Prefer `std.Io` paths:
    - filesystem through `std.Io.Dir.cwd().<op>(io, ...)` (e.g. `openFile`,
      `writeFile`, `access`, `createDirPath`, `deleteTree`)
    - sockets through `std.Io.net`; the threaded `io` handle for async/sleeps
    - avoid reintroducing `std.fs.cwd()`, `std.net`, `std.Thread.sleep`,
      `std.Thread.Mutex`

- Prefer Zig builtins and comptime where natural:
    - `@typeInfo`, `@TypeOf`, `@import("builtin")`
    - `@intCast`, `@enumFromInt`, `@intFromEnum`
    - `@memcpy`, `@memset`
    - `@atomicLoad`, `@atomicStore`
    - Note: Zig has no `@builtin`; platform/build info is `const builtin =
      @import("builtin");`.

- Avoid low-level OS work by default:
    - no direct syscalls
    - no new fork/exec code
    - avoid `std.os`, `std.posix`, raw libc unless there is no Zig 0.16 API
    - keep any unavoidable low-level code behind a local wrapper

- Prefer structured stdlib helpers:
    - `std.mem` for slicing/search/copying
    - `std.fmt.bufPrint` / `bufPrintZ` for fixed buffers
    - `std.testing` helpers in tests
    - `std.heap` allocators only when fixed buffers are not enough

- Make ownership explicit:
    - functions that allocate should document who frees
    - prefer caller-provided buffers for hot paths and config serialization
    - use `defer` / `errdefer` consistently
    - watch for the classic bugs: a StringHashMap key and a struct field duped
      from the same source must be SEPARATE allocations (else double-free in
      deinit); a setter that replaces an owned slice must free the old one;
      `*Locked` emit variants assume the Core lock is already held

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
      `unlock(io)`); use `std.atomic.Value(T)` for cross-thread scalar flags
    - the `Core` mutex (`src/server/core.zig`) serializes handler execution and
      notification fan-out; background tasks run outside it
    - hold a lock for the WHOLE fan-out, not just selection, so a concurrent
      teardown cannot free state mid-iteration
    - do not hold locks during long blocking I/O where avoidable; when a lock
      must span a write, ensure no inverse lock-order path exists
    - background threads: atomic stop flag + join in deinit; shut down the read
      side (`shutdown(.recv)`) to unblock a blocked read before joining

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
    - standalone-testable files (no `../` imports) run via
      `zig test -target x86_64-linux-musl src/<f>.zig`; files under
      `src/components` use `../` imports and build only via `zig build test`

- For build.zig:
    - keep link/backend choices explicit
    - avoid global-machine assumptions (this host's glibc cannot be linked; the
      native target defaults to musl — never run plain `zig build` against glibc)
    - prefer project-local cache/config for reproducible test runs

## Build / test quick reference

- Build test binary (avoids the `--listen=-` hang):
  `zig build test-artifact -Dwith_lmdb=false && ./.zig-cache/o/*/test --cache-dir=./.zig-cache`
- Full suite with lmdb: `timeout 220 zig build test --summary all`
- Coverage gate (must stay 100%):
  `zig build -Dwith_lmdb=false && zig-out/bin/phobos --dump-api > /tmp/d.json &&
   PYTHONPATH=tools python3 -m api_scanner coverage --baseline api/api_surface.json --phobos /tmp/d.json`
- Cross-compile (deploy): `zig build -Dtarget=arm-linux-musleabihf -Dcpu=cortex_a7 -Doptimize=ReleaseSmall`
