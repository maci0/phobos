# Memory footprint

phobos is a from-scratch Zig reimplementation of Moonraker (a Python/asyncio
service). The headline reason to care is resource use on small printer hosts:
phobos ships as a **single ~1.2 MB static binary** with **no runtime, no
interpreter, and no virtualenv**, and idles in a few megabytes of RAM.

Reproduce the numbers below with [`scripts/measure-memory.sh`](../scripts/measure-memory.sh)
(builds the release binary, starts an idle server, samples `/proc/<pid>/status`).

## Measured (this host, x86-64, ReleaseSmall + LTO + stripped)

| | phobos | bare Python 3 (stdlib only) | Moonraker (typical) |
|---|---|---|---|
| On-disk | **1.2 MB** static binary | interpreter + `site-packages` (tens–hundreds of MB) | + interpreter + deps |
| Idle RSS (settled) | **~3.7 MB** | ~25 MB | ~50–80 MB |
| Peak RSS at startup | ~6.3 MB (scratch frees to ~3.7 MB) | — | — |
| Runtime dependencies | none (static) | CPython | CPython + tornado + lmdb + jinja2 + … |

- **~3.7 MB idle RSS** vs **~25 MB** for a Python interpreter that has only
  imported `json`/`asyncio`/`sqlite3` — i.e. phobos uses **less than the floor**
  Moonraker starts from, before tornado, lmdb, jinja2, and its ~30 components are
  even loaded. Against a full Moonraker (~50–80 MB) that is a **~15–20× reduction**.
- The Python figure is measured here; a full Moonraker can't run in this sandbox
  (its deps aren't installed), so its number is the well-known production range,
  not a local measurement.

## Why `VmSize`/`VmData` looks large (and why it doesn't matter)

`VmData` is ~75 MB and `VmSize` ~9–80 MB depending on the moment. That is almost
entirely **reserved-but-uncommitted** address space, not resident RAM:

- **lmdb** maps its database file with a 200 MiB `map_size`. The mapping is lazy —
  pages become resident only as data is actually touched. An empty/idle store
  commits almost none of it.
- Zig's `smp_allocator` reserves per-CPU arenas up front; thread stacks reserve
  address space too. Again, reserved ≠ resident.

`VmRSS` (resident set) is the number that reflects real RAM pressure, and that is
the ~3.7 MB above.

## What drives phobos's small footprint

- **No interpreter/GC/event-loop runtime** — native code, `std.Io` for async I/O.
- **`ReleaseSmall` + full LTO + stripped** — the linker drops unreachable code;
  no debug info ships.
- **Per-request arena allocators** — request scratch is freed in one shot at the
  end of each request, so steady-state RSS stays flat; stable cross-request state
  uses the general allocator and is bounded.
- **Comptime dispatch** — JSON-RPC method names are derived at compile time into
  static strings (no startup heap dupes), the dispatch map is built once, and HTTP
  route lookup is an O(1) path index. See [`COVERAGE_HEATMAP.md`](api/COVERAGE_HEATMAP.md).
- **Reused scratch buffers** — e.g. the MQTT inbound body buffer grows to the
  largest packet seen and is reused, avoiding per-message alloc/free churn.

## Method

```sh
zig build -Doptimize=ReleaseSmall
./zig-out/bin/phobos -c <config-with-a-free-port> &   # idle, no traffic
sleep 6                                               # let startup scratch free
grep -E 'VmRSS|VmHWM|VmData|Threads' /proc/<pid>/status
```

Numbers vary a little with kernel/arch/allocator; the orders of magnitude do not.
