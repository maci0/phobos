# Memory footprint

phobos ships as one static binary with no interpreter, runtime or virtualenv,
with the historical idle measurements below. They do not measure the current checkout.
[`scripts/measure-memory.sh`](../scripts/measure-memory.sh) builds the release
binary, starts an idle server, and samples `/proc/<pid>/status` next to a bare
Python interpreter.

## x86-64 host

Measured 2026-10-20 at `db010e3`: `zig build -Doptimize=ReleaseSmall` (LTO,
stripped, static musl), SQLite backend, idle with no traffic, sampled after 6 s.

| | phobos | bare Python 3.14 (stdlib only) | Moonraker (typical) |
|---|---|---|---|
| On-disk | 2.43 MiB static binary | interpreter + `site-packages` | interpreter + deps |
| Idle RSS | 3.0 MB | 21.4 MB | 50-80 MB |
| Peak RSS (`VmHWM`) | 3.0 MB | n/a | n/a |
| `Private_Dirty` | 0.86 MB | n/a | n/a |
| Threads | 6 | n/a | n/a |
| Runtime dependencies | none | CPython | CPython, tornado, sqlite, jinja2 and more |

The Python column is an interpreter that has imported only `json`, `asyncio`,
`logging`, `pathlib` and `sqlite3`: the floor Moonraker starts from, before
tornado, jinja2 and its ~30 components load. phobos idles below that floor. A
full Moonraker cannot run on this host (its dependencies are not installed), so
its column is the commonly reported production range, not a local measurement.

## armv7 printer, by storage backend

The DataStore backend is selected at runtime with `[database] backend`. These
printer measurements predate the current review. Their exact source revision
was not recorded, so they are not a baseline for comparing new changes:

| Backend | Idle RSS | Private_Dirty | VmData | Notes |
|---|---|---|---|---|
| `sqlite` (default) | 2.18 MB | 2.28 MB | 21.8 MB | Reads and writes Moonraker's `moonraker-sql.db` |
| `file` (atomic rename) | 1.20 MB | 1.33 MB | 21.6 MB | Pure Zig, no C dependency |

The binary measured ~2.15 MB with either backend: SQLite is always linked so
the backend stays a runtime choice. Before SQLite was vendored the binary was
~1.2 MB; no build option drops it today.

- The file backend uses about 1 MB less resident RAM. That megabyte is SQLite's
  page cache and touched code. Pick the file backend when minimum memory matters
  more than Moonraker database compatibility.
- `VmData` is ~21.6 MB with either backend: the 1 MiB-capped thread stacks and
  arenas. An earlier store reserved a 200 MiB mmap; that reservation no longer
  exists.

## What the resident set contains

From `/proc/<pid>/smaps_rollup`:

- **`Private_Dirty`** (0.86 MB on x86-64) is phobos's own committed RAM: heap
  for the registry and dispatch tables, component state, and SQLite's internal
  structures.
- **`Private_Clean`** (2.1 MB on x86-64) is file-backed code and read-only data
  of the binary, including SQLite. Under memory pressure the kernel drops these
  pages and rereads them from disk, so they do not pin RAM.

Per-request allocations live in arenas freed when the request ends. Long-lived
state and the worker pool still affect resident memory under load.

## Why `VmSize` and `VmData` look large

`VmSize`/`VmData` read tens of MB (48 MB and 45 MB in the x86-64 run above).
That is reserved, uncommitted address space:

- **Thread stacks.** Background threads (Klippy bridge, proc-stat timer, MQTT
  reader and flush, announcement, Spoolman and job-queue timers) spawn with a
  1 MiB stack reservation instead of std's 16 MiB default, so five threads
  reserve ~5 MB instead of ~80 MB. Only touched pages become resident.
- **SQLite** uses a small resident page cache rather than a large reserved mmap,
  so it adds little to `VmSize`.

`VmRSS` reflects real RAM pressure.

## What keeps the footprint small

- No interpreter, garbage collector or event-loop runtime; async I/O goes
  through `std.Io`.
- `ReleaseSmall` with full LTO, stripped: unreachable code is dropped and no
  debug info ships.
- Per-request arena allocators; long-lived state uses the general allocator and
  is bounded.
- JSON-RPC method names are built at compile time as static strings, the
  dispatch map is built once, and HTTP route lookup is an O(1) path index.
- Reused buffers on hot paths. The MQTT inbound body buffer, for example, grows
  to the largest packet seen and is reused for later messages.

## Method

```sh
zig build -Doptimize=ReleaseSmall
./zig-out/bin/phobos -c <config-with-a-free-port> &   # idle, no traffic
sleep 6                                               # let startup allocations free
grep -E 'VmRSS|VmHWM|VmData|Threads' /proc/<pid>/status
```

Use a project-local scratch datadir with `-d` and a free loopback port. Never
point a measurement run at a live printer database. Record the commit, backend,
configuration, architecture, traffic and sampling interval beside the result.
