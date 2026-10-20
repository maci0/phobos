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
| `bench_local.sh` | Builds an isolated ReleaseFast binary, runs both servers against `klippy_stub.py`, and writes a report below `.scratch/bench-*/`. |
| `klippy_stub.py` | Answers the Klipper API protocol from canned data so Klippy latency drops out of the measurement. |
| `profile.sh` | Builds with `-Doptimize=ReleaseFast -Dprofile` (unstripped, frame pointers), loads it through the stub, and renders a `perf` (or `USE_BPFTRACE=1` bpftrace) on-CPU flamegraph. |
| `plot_perf.py` | Renders `docs/perf/*.png` from the measured data points hardcoded in the script. |

Requires [`vegeta`](https://github.com/tsenart/vegeta) for load and `perf` or
`bpftrace` for profiling, plus `curl`, `jq`, `uv` and Zig. `profile.sh` also needs
[FlameGraph](https://github.com/brendangregg/FlameGraph) at `$FLAMEGRAPH_DIR`
(default `~/FlameGraph`). Set `MOONRAKER_PYTHON` to an existing Moonraker
environment for `bench_local.sh`; it defaults to `vendor/moonraker/.venv/bin/python`.
The scripts do not install dependencies.

Each run creates a unique directory below `.scratch/` for configurations,
databases, sockets, logs and captures. Local benchmarks use fresh independent
databases, announcement development mode, no update refresh, and an empty local
USB-ID fixture. They leave the host binary and shared Klippy sockets alone.
Cleanup stops only child PIDs started by the run, with a bounded TERM wait.

Local ports default to 7140 for the comparison and 7141 for profiling. Override
with `PHOBOS_PERF_PORT`; port 7125 and existing HTTP listeners are refused.
`ZIG` selects the compiler. Unix sockets use short names in the owned directory;
the Moonraker comparison rejects paths beyond Linux's 107-byte pathname limit.
Both servers must report Klippy-ready before query load starts. The stub replies
to requests and advertises the proxy endpoints; it does not push status floods.

```sh
tools/perf_harness/bench_local.sh
tools/perf_harness/profile.sh /server/info 4000 10
tools/perf_harness/loadtest.sh 127.0.0.1:7140 local 200 15s
```

`profile.sh` accepts endpoint, rate, seconds and an optional SVG output path. The
default SVG stays in the run directory. `USE_BPFTRACE=1` selects a timed bpftrace
capture. `loadtest.sh` keeps its binary capture below `.scratch/load-*/`; its
label is display text, not a filename.

## On-printer method

1. Prepare independent copies of the same database and equivalent configurations
   on a dedicated test printer. Keep both copies separate from the live database.
2. Bind the candidate to a separate loopback port. Keep the production service
   running. Do not run a load comparison during printing.
3. Sample `VmRSS`/`Threads` from `/proc/<pid>/status` during the run.

## Historical printer results (armv7, 2× Cortex-A7, 107 MB RAM)

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

## Helper checks

`timeout 90 bash tools/perf_harness/tests/smoke.sh` checks setup, capture paths,
failure propagation and owned-process cleanup with command doubles. It runs no
load or privileged profiler. The Python checks are
`uv run --with pytest python -m pytest tools/perf_harness/tests --basetemp=.scratch/metrics-tests`.
