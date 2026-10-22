# Read performance capture, 2026-10-23

The candidate is phobos v0.2.3 with ReleaseFast, bulk ASCII JSON decoding,
direct buffered encoding, reused SQLite
statements, checked metadata-only file existence, compact console snapshots
and 1 MiB worker stacks. Its binaries match the release matrix. Source parent,
every Zig source blob, binary hashes, compiler version,
seed hash and reference versions are in the environment JSON. No dependency
was added. The earlier [study](../optimization-20261022/) remains unchanged.

Only candidate and Moonraker appear in active graphics. `all-builds.json`
contains the same two measured backends. Compare only
rows with the same fixture, rate, duration, collectors and environment.
Each table reports the median of three trial statistics. Whiskers show trial
minima/maxima, not confidence intervals or pooled request percentiles.
Lower CPU time, latency and RSS are better. Higher successful throughput is
better, but paced throughput measures meeting the offered rate, not capacity.

## Fixtures and fidelity

Fresh processes get separate copies of the same frozen SQLite seed containing
266 legacy history jobs, seven null end times and a synthetic 64 KiB database
item. Empty-history processes get only the synthetic item. No probe opens the
production database. History preflights compare six cases, including offsets,
ascending order, unlimited reads, time filters and a huge offset. Content checks
validate the database item and config reply before timing. Body retention is
disabled in Vegeta after these checks; zero `bytes_in` means retained body bytes,
not zero wire traffic. Responses are fully drained.

The independent mix cycles server info, config, machine system info, database
namespaces, a 20-job history page and access info. It does not query Klippy.
The focused config workload queries a large synthetic Klippy config response;
the stub executes nothing and does not reproduce a continuous status flood.

## Physical Forge-X

The installed Forge-X 1.4.2 Moonraker uses API 1.4.0 and Python 3.11.10.
Both servers run sequentially inside its chroot on loopback 7126. Production
on 7125 is paused during load and restored afterward. All server threads pin
to Cortex-A7 CPU 1. The Python stdlib fixed-arrival generator pins to CPU 0;
SSH carries monitoring and results outside the timed path. No hardware control,
heating, print, board restart, swap adjustment or firmware restart is issued.

HTTP trials last 12 seconds at 50/s info, 75/s independent mix, 10/s history
and 10/s 64 KiB database reads. Keepalive, at most eight workers and a three
second timeout apply to both servers. Latency starts at the scheduled arrival,
including queueing. Process counters and RSS are sampled about every 100 ms
during load; lifetime/idle samples are roughly 250 ms. VmHWM can retain an
earlier preflight peak and is not a per-workload peak. Health guards require
Klippy ready, complete/standby state, idle, zero targets and at least 16 MiB
board MemAvailable. Existing board swap is recorded separately from probe swap.

Each repetition also opens 21 fresh full-object WebSocket subscriptions over
12 seconds at 1.75/s, with at most two workers. Live Klippy's subscription tick
is 250 ms. An interval of 4/7 seconds samples seven tick phases, repeated three
times; the earlier 1 Hz generator sampled one phase and remains archived.
Scheduled and worker-start latencies use CLOCK_MONOTONIC. An additional metric
subtracts Klippy's eventtime from the decoded reply's CLOCK_MONOTONIC_RAW time,
matching its live chelper clock. That metric includes Klippy encoding, transport,
server work and client decoding. It is not Fluidd page-loading time. Live source
hashes record the timer and clock implementation. An initial mixed-clock run
failed a harness assertion; its completed HTTP rows and reason are archived.

## Isolated native KVM

The remote benchmark PC and local corroboration host are Ryzen 9 5950X systems.
Each private KVM guest has four vCPUs, 4 GiB preallocated locked RAM and no
network card. The remote disk is 8 GiB; the local disk is 16 GiB. Moonraker is
pinned to `900848584374` and its
msgspec JSON backend is enabled. Python/SQLite/kernel versions are recorded.
Candidate and reference run sequentially from fresh databases. The inherited
guest template contains an unused baseline executable; it is never run.

A cgroup reserves the complete L3 group on host CPUs 8-15/24-31, including SMT
siblings. User/system slices exclude those CPUs. Guest vCPUs 0/1/2/3 pin to
physical cores 10/11/12/13; the emulator uses CPU 8. Scheduling is SCHED_OTHER
with nice -20, without idle polling. Inside the guest the server uses CPU 1,
generator CPUs 2/3 and stub/controller CPU 0. VM swap is forbidden. Existing
frequency policies stay unchanged. Fixed frequency and literal zero steal
are not claimed; every window retains guest steal ticks, host run-queue delay,
affinity, RAM locking, swap, quota and frequency observations. No trial is
discarded for interference or an unfavorable result. Kernel/interrupt/thermal
and memory-bus effects can still influence timings.

Rich-fixture rates are 5,000/s info, 1,200/s independent mix, 200/s history,
200/s database and 50/s config. The empty fixture runs the 1,200/s mix. Each
trial lasts at least 10 seconds and offers at least 2,000 requests: the config
trial lasts 40 seconds, all others 10. The minimum count was chosen before
the final runs to give p99 more than five tail observations. Earlier 10-second
config trials remain archived and are not used for cross-duration speedups.

Each process gets endpoint/history preflights, two seconds to settle, five
seconds idle and a two-second 200/s mix warmup. Backend/workload orders vary by
repetition. Vegeta uses eight workers, keepalive and a two-second timeout.
The guest stops children and remounts its private disk read-only on completion.
The manager stops QEMU, removes its CPU partition and restores exact prior
slice limits. Cleanup JSON records these checks. The remote sudo rule and
sleep inhibitor remain in place at the user's request.

## Reproduction and limits

The existing [harness](../../../tools/perf_harness/README.md) documents generator,
sampling, affinity and plotting commands. To regenerate a plot set:

```sh
uv run --locked python tools/perf_harness/plot_perf.py \
  --input docs/perf/optimization-20261023/printer/summary.json \
  --output-dir docs/perf/optimization-20261023/printer \
  --title 'phobos v0.2.3 vs Moonraker, Forge-X Cortex-A7'
```

Repeat for `vm-rich` and `vm-empty`. Plot-input hashes identify measured sources.
Private seeds, job bodies, logs, profiles and binary load captures remain in
ignored scratch storage. The ten profiling rounds, including rejected variants and audits without a
source change, are retained under [profiling](profiling/README.md). Older
experiments remain in their original capture directories. No valid final
study uses FIFO scheduling or idle polling.

These captures do not measure maximum capacity, printing, uploads, device
drivers, the file backend, long soaks or notification-flood throughput. Other
ARM/AArch64 profiles pass build/ABI verification. All five compatible ARM32
daemon assets and floating-point probes run on this physical printer.
API identity, the Python stub, supported optional components, CAN empty-list
fallback and deliberate no-op machine power commands remain unchanged.

## Additional physical release checks

All five compatible ARM32 daemon assets execute against real Klippy on this
Cortex-A7 board, using the full Forge-X config with a private copied seed,
loopback 7126, automatic updates disabled and job-queue startup disabled. Each
checks version 0.2.3, all 26 production components, all 262 requested objects,
directory capacity, private Fluidd array-key round trips, real config values,
a 20-job history page and advancement of all four temperature stores over
five seconds. Separate C/Zig floating-point probes pass for all five profiles.
These smoke checks run after the benchmark, not during timed trials. They
certify compatibility on this board, not native ARMv6 or other printer models.
Probe processes are stopped and the previous production daemon is restored
before deployment. The board boot ID stays unchanged. No hardware command is
issued. Full raw logs and copied databases remain private scratch files.

Dates in the report use Asia/Singapore; raw captures retain UTC timestamps.

## Post-capture test synchronization

The first native AArch64 ReleaseFast CI run catches an MQTT test race: the
connection hook follows queued subscription writes, while broker receipt may
still lag. The test now uses its existing bounded wait before
asserting exactly 130 subscriptions. Production MQTT code is unchanged.
Captured source blobs match commit `15370cd8b9f474b15f6aa1225643c51b46b56b03`.
The [follow-up verification](post-capture-verification.json) records the
test-only source change and byte-identical rebuilt native/Cortex-A7 assets.
This release's tag is withheld until all seven CI assets match the measured
assets, preserving the benchmark's relevance to the published binaries.
