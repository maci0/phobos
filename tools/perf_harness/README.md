# Performance harness

Tools to compare phobos against stock Moonraker on identical hardware and to
profile phobos's on-CPU hot path under load. Current measurements and their
limits are in [`docs/PERFORMANCE.md`](../../docs/PERFORMANCE.md) and
[`docs/MEMORY.md`](../../docs/MEMORY.md).
Current tables and graphics compare the 0.2.2 development build with
Moonraker. The [capture directory](../../docs/perf/optimization-20261022/) contains populated
and empty-history VM trials plus real Forge-X trials, with exact binary,
source and seed hashes. The [capture method](../../docs/perf/optimization-20261022/METHOD.md)
records exclusive physical cores, locked RAM, guest steal and host run-queue
delay; these controls do not guarantee zero steal or fixed physical performance.
No printer is contacted for the VM study. Older captures retain their original
versions and are excluded from the current figures. Higher throughput is better; lower
latency, RSS and CPU time per completed request are better.

## Layout

| File | Purpose |
|---|---|
| `targets.txt` | vegeta target list: hot read endpoints (info, config, system_info, database item, objects/query, history). `TARGET` is replaced with `host:port`. |
| `targets-fast.txt` | Klippy-independent subset (no `printer.objects.query`), isolating phobos's own dispatch from the shared Klippy round-trip. |
| `loadtest.sh` | `loadtest.sh <host:port> <label> [rate] [dur]`: load one backend, print a latency report and histogram. |
| `compare.sh` | `compare.sh <hostA:portA> <labelA> <hostB:portB> <labelB> [rate] [dur]`: side-by-side run. |
| `bench_local.sh` | Builds an isolated ReleaseFast binary, runs both servers against `klippy_stub.py`, and writes a report below `.scratch/bench-*/`. |
| `klippy_stub.py` | Answers the Klipper API protocol from canned data so Klippy latency drops out of the measurement. |
| `profile.sh` | Builds with `-Doptimize=ReleaseFast -Dprofile` (release LTO policy, symbols, frame pointers), loads it through the stub, and renders a `perf` (or `USE_BPFTRACE=1` bpftrace) on-CPU flamegraph. |
| `plot_perf.py` | Renders throughput, p99 latency, process RSS and CPU from explicit measured trial JSON. Writes only the selected output directory. |

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
capture. Profiling starts after two seconds of load warmup, waits for the load
process to finish and rejects failed or empty request sets. The capture includes
the Vegeta JSON report, folded stacks and, with perf, raw stacks and a flat CPU
report. Perf samples user-space cycles; frame-pointer profiling changes code
generation and is separate from uninstrumented latency/CPU comparisons.
`PERF_SUDO=1` runs only counter collection/decoding through `sudo -n`, keeping
the server and load generator under the caller's identity when attachment is
restricted. The default invokes perf directly.
`loadtest.sh` keeps its binary capture below `.scratch/load-*/`; its
label is display text, not a filename.

Load commands set `-max-body=0` so large replies do not fill capture files or
the generator heap. Vegeta still drains each response before timing it as
complete. Its `bytes_in` counts retained body bytes, so zero here does not
mean zero wire traffic. These scripts measure status and timing; validate
response contents separately before load.

`plot_perf.py --input <capture>/summary.json --output-dir <capture>/plots` reads
trial records containing `backend`, `workload`, `repetition`, `requested_rate`,
`duration_seconds`, the Vegeta JSON report in `vegeta`, and the process sample
summary in `process` (`cpu_percent_one_core`, `rss_kib_max`). Both backends must
have matching workloads, rates, durations and repetitions. Sibling
`phobos/idle.json` and `moonraker/idle.json` supply `rss_kib_median` and
`cpu_percent_one_core`. It rejects missing or invalid measurements, draws trial
min/max ranges, and records input SHA256s beside the four PNGs. It contains no
historical measurements and does not write to `docs/` automatically. Run it
with `uv run tools/perf_harness/plot_perf.py` so its inline matplotlib dependency
is available.

## On-printer method

1. Prepare independent copies of the same database and equivalent configurations
   on a dedicated test printer. Keep both copies separate from the live database.
2. Bind the candidate to a separate loopback port. Keep the production service
   running. Do not run a load comparison during printing.
3. Sample `VmRSS`/`Threads` from `/proc/<pid>/status` during the run.

Use identical copied inputs, rates, durations and collectors for each backend.
Read process user/system CPU ticks before and after each trial, normalize by
completed requests, and retain actual throughput when a paced run falls behind.
Record board available memory and swap alongside probe RSS. A production
readiness/idle check and a stop guard protect the shared board; terminate only
the owned probe PID.

For a private Moonraker probe, omit update components when no network refresh
is intended. `enable_auto_refresh: false` disables periodic refresh but does not
prevent Moonraker's initial refresh. Keep probe config, logs, sockets and database
separate from production. The [versioned report](../../docs/PERFORMANCE.md)
records the actual Forge-X comparison and this kernel's disabled perf events.

## Helper checks

`timeout 90 bash tools/perf_harness/tests/smoke.sh` checks setup, capture paths,
failure propagation and owned-process cleanup with command doubles. It runs no
load or privileged profiler. The Python checks are
`uv run --with pytest --with matplotlib python -m pytest tools/perf_harness/tests --basetemp=.scratch/metrics-tests`.
