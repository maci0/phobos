# Performance harness

Tools to compare phobos against stock Moonraker on identical hardware and to
profile phobos's on-CPU hot path under load. Results and analysis:
[`docs/PERFORMANCE.md`](../../docs/PERFORMANCE.md).

## Layout

| File | Purpose |
|---|---|
| `targets.txt` | vegeta target list: hot read endpoints (info, config, system_info, database item, objects/query, history). `TARGET` is replaced with `host:port`. |
| `targets-fast.txt` | Klippy-independent subset (no `printer.objects.query`), isolating phobos's own dispatch from the shared Klippy round-trip. |
| `loadtest.sh` | `loadtest.sh <host:port> <label> [rate] [dur]`: load one backend, print a latency report and histogram. |
| `compare.sh` | `compare.sh <hostA:portA> <labelA> <hostB:portB> <labelB> [rate] [dur]`: side-by-side run. |
| `bench_local.sh` | phobos and Moonraker on the same host against `klippy_stub.py`; writes `/tmp/perf-report.txt`. Run from the repo root. |
| `klippy_stub.py` | Answers the Klipper API protocol from canned data so Klippy latency drops out of the measurement. |
| `profile.sh` | Builds with `-Doptimize=ReleaseFast -Dprofile` (unstripped, frame pointers), loads it through the stub, and renders a `perf` (or `USE_BPFTRACE=1` bpftrace) on-CPU flamegraph. |
| `plot_perf.py` | Renders `docs/perf/*.png` from the measured data points hardcoded in the script. |

Requires [`vegeta`](https://github.com/tsenart/vegeta) for load and `perf` or
`bpftrace` for profiling; `profile.sh` also needs
[FlameGraph](https://github.com/brendangregg/FlameGraph) at `$FLAMEGRAPH_DIR`
(default `~/FlameGraph`). Use an isolated host and database copies for both
backends. The legacy `bench_local.sh` and `profile.sh` scripts use fixed `/tmp`
paths, including `/tmp/klippy_uds`; do not run them on a host with an existing
Klippy socket.

## On-printer method

1. Prepare independent copies of the same database and equivalent configurations
   on a dedicated test printer. Keep both copies separate from the live database.
2. Bind the candidate to a separate loopback port. Keep the production service
   running. Do not run a load comparison during printing.
3. Sample `VmRSS`/`Threads` from `/proc/<pid>/status` during the run.

## Printer results (armv7, 2× Cortex-A7, 107 MB RAM)

Mixed read endpoints, keep-alive. Measured while every request still ran under
the `Core` lock, before reads moved off it:

| Load | phobos throughput, success | Moonraker throughput, success |
|---|---|---|
| 200 req/s, mixed | 107 req/s, 89% | 13 req/s, 11% |
| 500 req/s, fast subset | 52 req/s, 17% | 15 req/s, 5% |

- phobos sustained ~3-8× Moonraker's throughput with higher success ratios.
- Unloaded single-request latency was ~57 µs p50. Under heavy concurrency the
  ceiling was the shared Klippy round-trip (both backends proxy
  `printer.objects.query` over one Klippy socket) plus phobos's serialized
  `Core`.

## Profiling notes

`profile.sh` keeps frame pointers so `perf` stacks resolve; a `ReleaseSmall`
build strips them and shows `[unknown]` frames. Under high concurrency the
profile is dominated by syscall and futex time in the `Core` mutex and
`std.Io.Threaded`'s per-connection workers. That profile predates the read
path moving off `Core`. `std.Io.Threaded` grows its worker pool to the peak
number of concurrent connection tasks and never shrinks it;
`max_concurrent_conns = 128` in `src/io.zig` bounds that growth.

Selected read handlers run off the `Core` lock; inspect dispatcher registration
and component synchronization before changing that policy.
Not done: reusing per-request buffers for JSON encoding on the hottest endpoints.
