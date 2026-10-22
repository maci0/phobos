# Optimization capture method

Measured builds are the pre-change source at `7764f3697a04117543f2d6a793e679fa7ab4a6f3`
and the development build described by the source blobs and executable SHA256s
in the environment records. Both report package version 0.2.2; the candidate
is not a published release asset. The active plots contain the candidate and
Moonraker only. `all-builds.json` retains the baseline for before/after checks.
All builds use Zig 0.17.0, static musl and ReleaseSmall. Phobos embeds SQLite
3.54.1. No new package or compiler flags account for the measured changes.

The frozen private seed contains 266 migrated history jobs, including seven
null end times, plus a synthetic 64 KiB JSON record. Each fresh process gets
an independent copy, configuration, logs and temporary files. The empty VM
fixture starts with the synthetic value alone. No probe opens the production
database. Update components/remotes are omitted to avoid remote refresh.

The independent mix cycles through `/server/info`, `/server/config`,
`/machine/system_info`, `/server/database/list`,
`/server/history/list?limit=20` and `/access/info`. None queries Klippy.
Six history cases compare complete parsed results across every process:
`limit=20`, `limit=7&start=3&order=asc`, `limit=0`, `limit=20&since=0`,
`limit=0&before=2000000000`, and
`limit=1&start=9223372036854775807`.

## Real printer

The Forge-X 1.4.2 chroot runs Linux 5.4.61 on two Cortex-A7 cores with
110,404 KiB RAM. Its installed Moonraker uses Python 3.11.10 and API 1.4.0.
The phobos candidate and baseline use the Cortex-A7 hard-float profile.
Production is stopped during each study and restored afterward. Probes run
sequentially on `127.0.0.1:7126` inside the chroot against the real Klippy UDS.
No hardware command, target change, board restart or swap adjustment is used.

All server threads inherit CPU 1 affinity. The fixed-arrival Python stdlib
generator uses CPU 0 and printer loopback; SSH is outside the timed request
path. HTTP workers keep connections alive, use a three-second timeout and
have at most eight workers. Each request latency starts at its scheduled
arrival, including generator queueing. This avoids hiding overload by slowing
the offered rate. The generator validates HTTP status and representative JSON
responses. All full subscriptions validate every returned object name.

| Workload | Offered requests/s | Duration |
| --- | ---: | ---: |
| info50 | 50 | 12 s |
| independent75 | 75 | 12 s |
| history10 | 10 | 12 s |
| database64k10 | 10 | 12 s |
| full WebSocket subscription | 1 | 12 s |

Each repetition starts new candidate, baseline and Moonraker processes.
Repetition 2 reverses that order and the HTTP workload order. History and
endpoint preflights precede five seconds of idle observation, then HTTP load,
then 12 new WebSocket connections with a full 268-object subscription. The
probe config exposes six more objects than the production Fluidd config.
These subscription timings include JSON decoding by the client helper and
are not a browser-page loading benchmark.

A printer-local health thread checks readiness, idle/complete state and zero
heater targets about every 700 ms plus request time. Its server work is
included in process CPU. About 100 ms process samples record RSS, threads,
CPU ticks and board memory during load; a separate roughly 250 ms sampler
covers the full process lifetime. A 16 MiB MemAvailable floor stops the owned
probe. The load RSS summaries use the 100 ms measurements, avoiding confusion
with startup/preflight samples that share the controller's subscription label.
VmHWM includes earlier preflights and is not a workload-specific peak.
The printer exports process counters at 100 Hz; small CPU differences can be
one tick. Its kernel disables perf events, so no on-device sampled profile
is claimed.

## Isolated KVM guest

The Ryzen 9 5950X benchmark PC runs a private four-vCPU KVM guest with 4 GiB
preallocated locked RAM and no virtual network device. Both daemons, Vegeta
and the stub run inside it; requests use guest loopback. Moonraker is pinned
to `9008485843740c93e0154ccbdac1fc2b02b03aaa`. Python and its SQLite version
are recorded separately from phobos's embedded SQLite.

A cgroup v2 isolated partition reserves the complete L3 group on host CPUs
8-15 and 24-31. User/system slices temporarily exclude those CPUs. vCPUs
0/1/2/3 pin to host CPUs 10/11/12/13 with SCHED_FIFO priority 10; the emulator
uses CPU 8. SMT siblings are unused. In the guest the server uses CPU 1,
Vegeta CPUs 2/3, and the controller/stub CPU 0. `idle=poll`, `nohz_full=1-3`,
`rcu_nocbs=1-3` and `irqaffinity=0` reduce scheduling interruptions. Idle polling
occupies four host cores; it is a measurement control, not a deployment setting.

The host's existing frequency governor and bounds remain unchanged. The VM
cgroup disallows swap; a one-second monitor checks locked RAM and zero
VM/cgroup swap. Sleep/idle inhibitors cover setup, trials and cleanup. Each
run saves and restores the exact prior slice CPU limits, removes its owned
partition and stops only its own QEMU process. The guest syncs and remounts
its private disk read-only before completion. Results are extracted read-only
after QEMU exits. No existing VM or golden image is modified.

| Populated-history workload | Offered requests/s | Duration |
| --- | ---: | ---: |
| info-5000 | 5,000 | 10 s |
| independent-1200 | 1,200 | 10 s |
| history-200 | 200 | 10 s |
| database64k-200 | 200 | 10 s |
| klippy-config-50 | 50 | 10 s |

The empty fixture runs only independent-1200. The Klippy workload queries a
synthetic configfile object containing repeated macro strings. The raw trial
IDs retain the initial `klippy328k-50` label; response bytes are recorded rather
than inferred from that label. The stub returns canned data and executes nothing.
The other four workloads are independent of Klippy response latency. The
stub does not reproduce continuous status floods.

Three repetitions use candidate/baseline/Moonraker,
Moonraker/baseline/candidate, then baseline/candidate/Moonraker order.
Workloads reverse in repetition 2. Each process handles preflights, settles
for two seconds, records five seconds idle, and runs a two-second 200/s mix
warmup. Vegeta uses eight fixed workers, keepalive and a two-second timeout.
Process samples are about 100 ms. CPU time divides process user+system tick
deltas by successful requests and includes generator startup/finish overhead.
The private disk is 16 GiB, with a 2 GiB free-space stop floor. Vegeta uses
`-max-body=0` after full content preflights. It still drains each response;
its `bytes_in` field counts retained bytes and is therefore zero, not wire
traffic. See the pinned [Vegeta implementation](https://github.com/tsenart/vegeta/blob/v12.13.0/lib/attack.go#L558-L569).
An initial twenty-second run filled its 8 GiB disk while recording response
bodies. Its 44 completed trials and failure remain archived separately; none
is substituted into the final ten-second comparison.

Guest CPU counters surround every load; steal is index 7, exported at 100 Hz.
Serial BEGIN/END boundaries retain host vCPU affinity, scheduler nanosecond
run-queue delay and cgroup CPU counters. Host windows include a 250 ms start
lead and result collection. Positive counters are retained. Exclusive cores
cannot eliminate kernel, interrupt, thermal or memory-bus interference and do
not establish guaranteed physical performance or literal zero steal.

## Interpretation

Lower CPU time, latency and RSS are better. Higher successful throughput is
better; at a paced rate the goal is to meet the offered rate, not maximize it.
Tables use the median of three trial statistics. Plot whiskers are trial
minima/maxima, not confidence intervals; request percentiles are not pooled.
RSS is resident pages, not allocations or private memory. Samples can miss
short peaks, and allocators can retain freed pages. Negative and interrupted
studies remain recorded separately rather than silently dropped.

Raw databases, response bodies, process logs and binary load captures stay in
ignored scratch storage. Checked-in records contain numerical summaries,
hashes, affinity, scheduling, parity and cleanup evidence. The existing
[`plot_perf.py`](../../../tools/perf_harness/plot_perf.py) regenerates the four
figures per environment from `summary.json` and sibling idle summaries.
Each graphic records its input hashes. Earlier release measurements remain
under [`v0.2.2`](../v0.2.2/); they are a different study.
