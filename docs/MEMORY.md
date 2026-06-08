# Memory footprint

> **Note (post-SQLite switch):** the binary/RSS figures below were measured when
> the DataStore was lmdb. The store has since moved to a vendored SQLite (for
> Moonraker `moonraker-sql.db` compatibility), which grew the binary to **~2.1 MB**
> and replaces lmdb's reserved 200 MiB mmap with SQLite's (small, resident) page
> cache. The orders of magnitude vs Moonraker still hold; the detailed lmdb-mmap
> discussion is retained as background but the exact RSS needs re-measuring on the
> SQLite build (`scripts/measure-memory.sh`). The pure-Zig atomic-rename file
> backend (`store/file_store.zig`) is the leaner, no-SQLite alternative.

phobos is a from-scratch Zig reimplementation of Moonraker (a Python/asyncio
service). The headline reason to care is resource use on small printer hosts:
phobos ships as a **single static binary** (~2.1 MB with SQLite, ~1.2 MB with the
file backend) with **no runtime, no interpreter, and no virtualenv**, and idles in
a few megabytes of RAM.

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

## What the ~3.7 MB RSS is actually made of

Sampling `/proc/<pid>/smaps_rollup`, the resident set breaks down as:

- **`Private_Dirty` ≈ 0.7 MB** — the only pages that are genuinely phobos's own
  committed RAM (heap: registry + dispatch tables, component state, lmdb internal
  structures). This is the real floor, and it is already sub-megabyte.
- **The rest (~3 MB)** is `Private_Clean` / file-backed code+rodata: the binary's
  own pages and lmdb's, mapped from disk. These are **reclaimable** — under memory
  pressure the kernel drops them and re-reads from disk, so they don't pin RAM the
  way dirty pages do.

So there is very little resident memory left to cut: phobos already idles at its
floor. Steady-state RSS stays flat because request scratch lives in per-request
arenas freed at the end of each request.

## Why `VmSize`/`VmData` *looks* large (and why it isn't resident)

`VmSize`/`VmData` can read tens of MB once the background workers are up. That is
**reserved-but-uncommitted** address space, not resident RAM:

- **Thread stacks.** phobos runs a handful of background threads (klippy bridge,
  proc-stat timer, MQTT reader/flush, announcements/spoolman/job-queue timers).
  Each is now spawned with a **1 MiB stack reservation** instead of std's default
  **16 MiB** — so the worst-case reserved stack space drops ~16× (e.g. ~80 MB →
  ~5 MB at 5 threads). Only the few touched pages are ever resident, so this is a
  `VmSize` win, not an RSS one, but it stops the footprint *looking* huge.
- **lmdb** maps its database with a 200 MiB `map_size`; the mapping is lazy, so an
  empty/idle store commits almost none of it.

`VmRSS` is the number that reflects real RAM pressure, and that is the ~3.7 MB
above (of which only ~0.7 MB is unreclaimable).

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
