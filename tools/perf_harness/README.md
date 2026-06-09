# Performance harness

Tools to (a) compare phobos against stock Moonraker on identical hardware, and
(b) profile phobos's on-CPU hotpath under load so the slow paths can be optimised.

## Layout

| File | What |
|---|---|
| `targets.txt` | vegeta target list — a mix of hot read endpoints (info, config, system_info, db item, objects/query, history). `TARGET` is substituted with `host:port`. |
| `targets-fast.txt` | Klippy-independent subset (no `printer.objects.query`), to isolate phobos's own dispatch from the shared Klippy round-trip. |
| `loadtest.sh` | `loadtest.sh <host:port> <label> [rate] [dur]` — hammer one backend, print latency report + histogram. |
| `compare.sh` | `compare.sh <hostA:portA> <labelA> <hostB:portB> <labelB> [rate] [dur]` — side-by-side. |
| `profile.sh` | Build a frame-pointer/unstripped phobos, load it, capture a `perf` (or eBPF/`bpftrace`) on-CPU profile + folded stacks for a flamegraph. |

Needs [`vegeta`](https://github.com/tsenart/vegeta) for load, `perf` or `bpftrace`
for profiling. Run both backends on the **same machine** (swap them onto one
port) so the comparison is fair — Moonraker and phobos both talk to the same
Klippy over its unix socket.

## Method

1. Put the device's real `moonraker-sql.db` behind both (phobos opens it directly
   via `[database] path`; see the main README), and point Klippy's socket at each
   in turn.
2. `compare.sh printer:7125 moonraker printer:7125 phobos 200 15s` (swap the
   backend between runs, same port → identical client behaviour).
3. Sample `VmRSS`/`Threads` from `/proc/<pid>/status` during the run for the
   memory side of the comparison.

## Findings (real printer: armv7, 2× Cortex-A7, 107 MB RAM)

Mixed read endpoints, keep-alive, increasing offered load:

| Load | phobos throughput / success | Moonraker throughput / success |
|---|---|---|
| 200 req/s, mixed | **107 req/s, 89%** | 13 req/s, 11% |
| 500 req/s, fast subset | **52 req/s, 17%** | 15 req/s, 5% |

- **phobos sustains ~3–8× Moonraker's throughput** on the same hardware, with far
  better success ratios — native code with no interpreter/event-loop tax.
- **Single-request latency is tens of µs** (≈57 µs p50 unloaded); phobos is fast
  per request. The ceiling under heavy concurrency is the shared **Klippy
  round-trip** (both backends proxy `printer.objects.query` to the one Klippy
  socket, which serialises) plus phobos's serialised `Core` (Moonraker's
  single-loop observable ordering, reproduced on purpose).

## Profiling notes

`profile.sh` builds with `-Doptimize=ReleaseFast` and frame pointers so `perf`
stacks resolve (ReleaseSmall strips them → unreadable `[unknown]` frames). Under
high concurrency phobos's profile is dominated by **syscall/futex time** — the
`Core` mutex + `std.Io.Threaded`'s per-connection worker threads. `std.Io.Threaded`
grows its worker pool to the *peak* number of concurrent connection tasks and does
not shrink it, so a burst of slow (Klippy-blocked) connections can balloon the
thread count; capping concurrent connections (or the pool) bounds it.

Optimisation directions surfaced by the profile:
- **Bound connection concurrency** so a Klippy stall can't explode the worker pool.
- **Let pure read handlers run off the `Core` lock** (info/config/db-get/system_info
  don't need single-loop ordering) — would lift the read-path ceiling well above
  the current serialised rate.
- Reuse per-request scratch for JSON encoding on the hottest endpoints.
