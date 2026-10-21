# KVM capture method

The current VM results compare published phobos v0.2.2 with Moonraker
`9008485843740c93e0154ccbdac1fc2b02b03aaa`. Both servers run inside the
same private guest, sequentially, against a local
[`klippy_stub.py`](../../../tools/perf_harness/klippy_stub.py).
No printer is contacted. The VM has no network device. All HTTP uses guest
loopback port 17413; the stub uses a guest-local Unix socket.

## Host and guest controls

The second PC is a Ryzen 9 5950X with 64 GiB RAM and Linux
7.2.9-2-cachyos. Its complete second L3 group, CPUs 8-15 and 24-31,
is a cgroup v2 `isolated` partition with matching `cpuset.cpus.exclusive`.
Both user and system slices exclude these CPUs. Ordinary-process affinity
attempts to all 16 reserved CPUs must fail. No existing services are stopped.
Interrupts, host kernel work and shared memory/thermal effects remain possible.

QEMU runs four vCPUs with SCHED_FIFO priority 10, pinned respectively to
physical CPUs 10, 11, 12 and 13; their SMT siblings remain unused. The emulator
pins to CPU 8. Guest server affinity is CPU 1, generator 2/3, controller/stub 0.
The guest command line includes `idle=poll nohz_full=1-3 rcu_nocbs=1-3 irqaffinity=0`.
The full [QEMU command](vm-qemu-command.json) records KVM, CPU features and
devices. The recorded default host CPU-model expansion is descriptive; the
runtime feature overrides are in the command.

Guest RAM is 4 GiB, preallocated and locked with an unlimited inherited
memlock limit. QEMU runs as the ordinary host user. The owned VM cgroup sets
`memory.swap.max=0`; the guest has no configured swap. A one-second root
monitor outside the reserved partition records locked memory, VM/cgroup swap
and physical frequencies. Cgroup CPU counters must show no quota throttling.
The performance governor and frequency bounds are left unchanged. Sleep/idle
inhibitors cover the controller and test host throughout capture.

The guest uses the host kernel and a private 16 GiB ext4 disk, static BusyBox,
the existing managed Python 3.12.12 runtime, its Moonraker environment and
host-compatible shared libraries. Vegeta 12.13.0 comes from the second PC's
package. The copied first-PC BusyBox and Vegeta binaries used unsupported CPU
instructions; they were replaced before measured trials. Preflight includes
a two-second load-generator smoke test for each backend and fixture. No
measured row comes from those failed setup attempts.

## Inputs and collection

Each backend/process gets separate config, logs, temporary files and database.
The populated fixture copies the same private 266-job migrated seed, including
seven null end times; the empty fixture starts fresh. Both fixtures insert
the same JSON record containing 65,536 `x` bytes at namespace `perf`, key
`large`. Hashes of the binary, seed and guest kernel accompany each fixture.
Python's SQLite version and phobos's embedded SQLite version are recorded
separately. No live printer database is opened.

The shared configuration is:

```ini
[server]
host: 127.0.0.1
port: 17413
klippy_uds_address: /bench/k.sock
[machine]
provider: none
[authorization]
trusted_clients: 127.0.0.1
[announcements]
dev_mode: true
[history]
[job_queue]
load_on_startup: false
automatic_transition: false
```

Moonraker receives `-n` and its own Unix API socket. Update components/remotes
are omitted. Readiness requires `klippy_state=ready`. Seven read endpoints
must return 200, and the database item must contain the exact synthetic value.
Six history cases compare complete parsed results across backends and starts:
`limit=20`, `limit=7&start=3&order=asc`, `limit=0`, `limit=20&since=0`,
`limit=0&before=2000000000`, and
`limit=1&start=9223372036854775807`. Each fixture/backend starts three fresh
processes, producing 72 history checks.

Every process settles for two seconds, records a five-second idle window,
and runs a two-second 200/s independent-mix warmup. Vegeta uses eight fixed
workers, keepalive and a two-second timeout. Timed load lasts 20 seconds.
The free-space guard requires more than 2 GiB before each measured trial.

| Workload | Targets | Offered requests/s |
| --- | --- | ---: |
| info-5000 | `/server/info` | 5,000 |
| independent-600 | Independent mix below | 600 |
| independent-1200 | Independent mix below | 1,200 |
| history-200 | `/server/history/list?limit=20` | 200 |
| database64k-200 | `/server/database/item?namespace=perf&key=large` | 200 |

The independent mix cycles through `/server/info`, `/server/config`,
`/machine/system_info`, `/server/database/list`,
`/server/history/list?limit=20` and `/access/info`. None issues a Klippy query
or a request to an external service. Populated history runs all five workloads;
empty history runs info-5000 and independent-1200. Backend order is
phobos/Moonraker, Moonraker/phobos, phobos/Moonraker. Workload order reverses
in repetition 2. All complete trials remain in the results, including nonzero
interference and unfavorable observations.

Process `/proc/<pid>/stat` user+system ticks and `/proc/<pid>/status` RSS/threads
are sampled about every 100 ms and around the generator invocation. CPU time
per request divides the server CPU delta by successful requests. Sampling
includes generator startup/finish overhead. RSS is sampled, so brief peaks
may be missed. Process CPU excludes other guest tasks and idle polling;
the VM occupies four physical cores even while the daemon is idle.

Before and after load, the guest captures all `/proc/stat` CPU counters.
Steal is index 7 of each CPU line, exported at 100 Hz. Aggregate and per-CPU
tick deltas are retained separately because their rounding can differ. Serial
BEGIN precedes a 250 ms lead; END follows report collection. Host boundaries
snapshot each vCPU's `/proc/<tid>/schedstat`, affinity and cgroup CPU counters.
Host scheduling delay is the run-queue wait delta divided by the elapsed
host boundary interval, in nanoseconds. That interval includes the start lead
and collection overhead, so it is not exactly the guest's 20-second load.

## Cleanup and interpretation

The guest stops only its children, syncs, and remounts the disk read-only before
completion. The manager stops only its QEMU child, verifies unchanged frequency
policies, removes its CPU partition and releases its sleep inhibitor. JSON is
extracted read-only after the VM stops. The temporary passwordless-sudo rule
and controller/idle inhibitors are removed after final checks. Package installs
remain; no host reboot or existing VM change is needed.

Exclusive cores, locked RAM and no quota throttling reduce interference. They
do not establish literal zero steal or guaranteed physical performance. Read
the measured [isolation summary](vm-isolation-summary.json) and retain every
positive counter. The [first-PC partial study](vm-local-partial/README.md) is
an archive, not part of the active figures.

Counter definitions:
[isolated cpusets](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html#cpuset),
[KVM steal time](https://docs.kernel.org/virt/kvm/x86/msr.html#custom-msr-list),
[per-task scheduler counters](https://kernel.org/doc/html/latest/scheduler/sched-stats.html).
