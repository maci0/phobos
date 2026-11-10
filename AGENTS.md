# AGENTS.md: coding conventions for phobos

Phobos is a memory-efficient Zig 0.17 reimplementation of Moonraker. Status: `TODO.md`, workflow: `DEVELOPMENT.md`, architecture: `docs/`, ledger: `docs/PROVENANCE.md`.

## Project goals

- **Low memory use**: static musl binary on 32-bit ARM Cortex-A7. Measurements in `docs/MEMORY.md` and `docs/PERFORMANCE.md`. Reproduce: `scripts/measure-memory.sh`.
  - fixed/stack/caller-provided buffers; `std.heap` only when size unbounded
  - per-request arena freed on return; no long-lived caches for cheap recomputation
  - bound every buffer/ring/queue; no unbounded growth
  - no per-item heap churn in hot paths; reuse, stream
  - new dependency/large static table needs memory justification

- **100% Moonraker API parity** (surface + behavior). Coverage gate + conformance oracle must stay green.

- **Idiomatic Zig**: `comptime`/`@typeInfo` for tables/dispatch; exhaustive `switch` on enums/tagged unions (no `else`); explicit error sets with `try`/`errdefer`; slices over pointers; `defer` cleanup; move work to comptime.

## Zig 0.17 constraints

Missing: `std.fs.cwd`, `std.posix.access`, `std.Thread.Mutex`, `std.Thread.sleep`. Use `std.Io.Mutex`. `std.Thread.spawn`/`join` exist.

- **I/O**: `std.Io.Dir.cwd().<op>(io, ...)` for FS; `std.Io.net` for sockets; async/sleep via threaded `io` handle. No `std.fs.cwd()`, `std.net`, `std.Thread.sleep`, `std.Thread.Mutex`.
- **Builtins**: `@typeInfo`, `@TypeOf`, `@import("builtin")`, `@intCast`, `@fromBackingInt`, `@backingInt`, `@memcpy`, `@memset`, `@atomicLoad`, `@atomicStore`. Comptime tables/dispatch from tagged unions; `inline for` over spec arrays. `const builtin = @import("builtin");`
- **No raw OS**: no syscalls, no fork/exec, no `std.os`/`std.posix`/raw libc unless no Zig API. Platform exceptions (behind local wrappers): termios (`serial.zig`), system identity (`machine.zig`), V4L2 (`video_modes.zig`), CAN (`canbus.zig`), GPIO (`gpio_input.zig`), `statvfs`/`localtime` C shims, `TCP_NODELAY` (`io.zig`). See `docs/STDLIB.md`.
- **Paths/addresses**: socket addresses from `socket.address`; file roots via `file_manager.Resolved` (mutate via checked handles, atomic replace). Timestamps: `std.Io.Clock`; secrets: `io.randomSecure` (propagate errors). Pass startup `io` through constructors; `clock_io` for early clocks.
- **Timers**: `std.Io.Event.waitTimeout` with absolute deadline (handles spurious wakes). Signal event before joining worker.
- **Stdlib**: `std.mem` (slice/search/copy), `std.fmt.bufPrint`/`bufPrintSentinel` (fixed buffers), `std.testing` (tests), `std.heap` only when fixed buffers insufficient.

## Ownership & allocators

- Function allocating → documents who frees.
- `App.setParsedConfig` consumes parser even on error (components borrow config strings).
- Caller-provided buffers for hot paths/config serialization.
- `defer`/`errdefer` throughout.
- Known bug patterns:
  - `StringHashMap` key + struct field from same source → separate allocations or `deinit` double-frees
  - setter replacing owned slice → free old one
  - `*Locked` emit variants assume Core lock held

- **Allocator lifetime** (main UAF/leak source):
  - never store per-request/per-message arena memory in long-lived structures (maps, caches, `last_value`). Dupe into stable owner (`self.gpa`).
  - store APIs that deep-copy (`publishTopic`→`deepCopyValue`, `setMeasurement`) leave caller owning builder: `defer builder.deinit(gpa)`.
  - free map keys/values with their allocator. Snapshot map aliasing another map's entries → don't `clearRetainingCapacity` (leaks); deep-copy and free, or free entries explicitly.

- **Slices**: `[]const u8`/`[]u8` internally; `[*:0]const u8` only at C boundaries; `std.mem.span()` only there.
- **Enum APIs**: `count`, `toIndex`, `fromIndex`, `toStr`, `label`, safe default for out-of-range.
- **Errors**: return `!T`/`!void`; `catch return` on non-critical paths; no silent `catch {}` outside known best-effort (e.g., hardware writes after state commit).

## Concurrency

- `std.Io.Mutex` via `io` handle (`lockUncancelable(io)`/`unlock(io)`); `std.atomic.Value(T)` for cross-thread flags. Teardown: `lockUncancelable` (not `lock(io) catch {}`).
- `Core` mutex (`src/server/core.zig`) serializes handlers + notification fan-out; background tasks run outside. Inbound background work mutating shared state/emitting → `core.run(io, fn, args)`.
- Klippy callbacks (`on_state`, `on_status`, `on_gcode`) run under Core on reader. Copy borrowed values or enqueue; no round trips. Internal subscription refresh off Core.
- Fan-out over concurrently removable connections: don't hold registry lock across blocking writes. Pin (refcount++), release, write, re-lock, drop refs; `remove` defers free while pinned. See `Connections.broadcast`.
- Never select-then-act across dropped lock without pinning (UAF).
- Store every spawned thread/future referencing ctx state; join before freeing that state. Stop with atomic flag; `shutdown(.recv)` unblocks read before join.
- **Never block on network round-trip while holding Core** (deadlock). Klippy bridge (`klippy_connection.zig`): persistent reader drains socket continuously, routes to per-id waiters, `request()` releases Core for round-trip. Reuse this pattern.
- Background thread stacks default 16 MiB. Pass `.{ .stack_size = 1 << 20 }` to `std.Thread.spawn`.

## Process spawning

- `std.process` only where Zig 0.17 env handling safe.
- Mockable command runner (`machine.zig` `RunCmdFn`) for unit testing.
- Host-mutating commands (reboot, shutdown, apt, pip) = deliberate no-ops; never run by default.

## Tests

- Python tools: `--basetemp=.scratch/<name>`; captures/data/build prefixes under `.scratch/`; terminate only created child PIDs.
- Temperature sampling + auto-refresh start only in daemon entry; tests tick synchronously; no sampler uses testing allocator.
- Tests at module bottom (`test { ... }` blocks).
- **Every function: unit test + fuzz test** (project rule).
- Pure tests for parsers/builders/helpers.
- Tests under `std.testing.allocator` (catches leaks/double-frees); exercise allocation paths with it (arenas hide bugs).
- Fuzz harnesses: deterministic + bounded.
- Update tests: local temp repos only; never checkout's `origin` or real deployment.
- Fixtures (datadirs, configs, sockets, fake sysfs, missing paths): `std.testing.tmpDir` (never fixed `/tmp`/cwd). `App.init` takes datadir; Unix sockets: `.zig-cache/tmp/<sub_path>/...` (fits 108-byte `sun_path`). Every wait has deadline.
- Klippy sim (`src/testutil/klippy_sim.zig`) doesn't reproduce continuous status flood/backpressure → hides bridge concurrency bugs. Validate on real printer: cross-compile, deploy via SSH, symlink `/tmp/klippy_uds -> /tmp/uds`, run on port ≠ 7125, read-only requests, kill + remove symlink. Diagnose hangs: `/proc/<pid>/task/*/wchan` (`unix_stream_read_generic` = blocked read, `futex_wait_queue_me` = lock contention).
- Files with no `../` imports: `zig test -target x86_64-linux-musl src/<f.zig>`; files under `src/components` (use `../` imports): `zig build test` only.

## Build

- Explicit link/backend choices.
- Native target defaults to musl (host glibc unlinkable); never plain `zig build` against glibc.
- Project-local cache/config for reproducible tests.

## Quick reference

- **DataStore**: `[database] backend` = `sqlite` (default, compiles `vendor/sqlite/`) | `file` (pure-Zig JSON via Zig I/O; binary still links SQLite).
- **Test suite**: `scripts/test.sh Debug|ReleaseSafe|ReleaseFast` (installs `bin/phobos-tests` under `.scratch/tests-<mode>/`; no `--test-filter`).
- **CI**: `.github/workflows/ci.yml` (`docs/CI.md`); Python via `uv sync --locked`.
- **CLI**: `schema` (CLI Spec 0.3, no config/socket); `-o/--output` = `auto|text|json` (`auto`=text on pipe); `--dump-api`=API doc to stdout; `--version`=Moonraker compat string; `-o json --version`=package version.
- **Coverage gate** (100%):
  `mkdir -p .scratch && zig build && zig-out/bin/phobos --data-path "$PWD/.scratch/api-dump-data" --dump-api > .scratch/api-dump.json && PYTHONPATH=tools uv run --with tree-sitter --with tree-sitter-python python -m api_scanner coverage --baseline api/api_surface.json --phobos .scratch/api-dump.json`
- **Release** (LTO, stripped): `-Doptimize=ReleaseFast`.
- **Cross-compile**: `zig build -Dtarget=arm-linux-musleabihf -Dcpu=cortex_a7 -Doptimize=ReleaseFast`.
- **Release matrix**: `scripts/build-release.sh` (isolated static Linux profiles, ELF/ABI/checksums); `--verify-only` validates without compile. `docs/BUILDS.md` for CPU/kernel reqs and C-only `-Dsoftfp`. Never execute foreign artifacts on build host.
- **Conformance**: `conformance/replay.py` vs `conformance/golden/`.
- **Real-Klippy integration**: `.testenv/run-klippy.sh` (gitignored; native Linux MCU + Klippy via uv). Skips if `/tmp/klippy_uds` absent.