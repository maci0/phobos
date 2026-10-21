# Memory footprint

Current comparison: **phobos v0.2.2 versus Moonraker**, measured 2026-10-21
with the published static musl ReleaseSmall assets. The
[performance report](PERFORMANCE.md) gives matched workloads, rates, repetition
order, exact versions and capture limits. These tables and graphics contain
only v0.2.2 and Moonraker.

**Lower RSS is better.** KiB means 1,024 bytes. RSS measures resident pages,
not total allocations or private memory. Idle values are medians of three
fresh-process trial medians, with their min/max range. Load tables give the
largest sampled RSS across every workload and repetition; plots give each
workload's median trial maximum with min/max whiskers. Samples can miss brief
peaks. Worker pools and earlier workloads can leave pages resident.

## Cortex-A7 printer

Forge-X 1.4.2 chroot, Linux 5.4.61, two Cortex-A7 cores, 110,404 KiB RAM.
The official Cortex-A7 asset is 2,629,960 bytes,
SHA256 `94737315462468de6ec1fa54cb86c46c4127f5918b452c532c0311606ed56290`.
The reference is the actual Forge-X Moonraker on Python 3.11.10. Each private
probe uses loopback 7126, the same minimal core config and its own copy of the
266-job seed plus a 64 KiB record. Production v0.2.2 stays on 7125. The probe
config has fewer components than production; this is not an all-components
memory guarantee.

| Process | Median idle KiB ↓ (trial range) | Maximum sampled load KiB ↓ | Peak threads |
| --- | ---: | ---: | ---: |
| phobos v0.2.2 | 3,044 (3,016 to 3,096) | 3,500 | 14 |
| Moonraker | 36,696 (33,048 to 36,788) | 36,816 | 4 |

![Forge-X RSS, v0.2.2 versus Moonraker, lower is better](perf/v0.2.2/printer/memory.png)

Thirty eight-second load trials and six idle windows use roughly 250 ms RSS
and board samples. MemAvailable stayed at or above
23,960 KiB, with a 16 MiB stop guard. Maximum probe
VmSwap was 0 KiB. Existing board SwapFree ranged
from 3,072 to 11,552
KiB; production VmSwap ranged from 0 to
428 KiB. A zero probe VmSwap does not establish
that the board avoided swapping. Swap settings were unchanged.

[Idle trials](perf/v0.2.2/printer/idle-trials.json),
[all load trials](perf/v0.2.2/printer/summary.json),
[environment](perf/v0.2.2/printer/environment.json) and
[board limits](perf/v0.2.2/printer/board-memory.json) retain the observations.
After cleanup production remains PID 29180, ready, standby,
both heater targets zero, with its release hash and boot ID unchanged.
[Final state](perf/v0.2.2/printer/final-state.json) records production RSS and
swap separately from the probes. No long-soak or reboot-persistence test is
claimed.

## x86-64 host, populated history

Ryzen 9 9950X, CachyOS Linux 7.2.10, pinned server/generator/stub affinity on
a shared desktop. The official x86-64 asset is 2,751,384 bytes, SHA256
`f81657748202cec356e841b7409371de4d74104cdac95e39c99c2a739079022d`.
Moonraker pin `900848584374` runs on Python 3.12.12. Both backends use the same
stub and copied 266-job seed plus 64 KiB record.

| Process | Median idle KiB ↓ (trial range) | Maximum sampled load KiB ↓ | Peak threads |
| --- | ---: | ---: | ---: |
| phobos v0.2.2 | 6,400 (4,372 to 8,396) | 13,296 | 18 |
| Moonraker | 55,076 (55,060 to 55,152) | 56,176 | 5 |

![Populated host RSS, v0.2.2 versus Moonraker, lower is better](perf/v0.2.2/host-rich/memory.png)

## x86-64 host, empty history

Same setup, independent fresh databases with the same 64 KiB record.

| Process | Median idle KiB ↓ (trial range) | Maximum sampled load KiB ↓ | Peak threads |
| --- | ---: | ---: | ---: |
| phobos v0.2.2 | 7,932 (5,924 to 12,000) | 12,368 | 18 |
| Moonraker | 53,776 (53,528 to 53,808) | 54,080 | 5 |

![Empty-history host RSS, v0.2.2 versus Moonraker, lower is better](perf/v0.2.2/host-empty/memory.png)

Host sampling is about 100 ms. Each fixture has three fresh-process starts
per backend and five-second idle windows. Full idle ranges and per-workload
load maxima are retained with the
[populated](perf/v0.2.2/host-rich/idle-trials.json) and
[empty](perf/v0.2.2/host-empty/idle-trials.json) captures. Shared-host scheduling,
connection worker allocation and workload order contribute to RSS variation;
one low sample is not a memory guarantee.

## Allocation and ownership limits

`VmSize` includes reserved address space and is not RSS. Thread stacks reserve
bounded space; request arenas free their contents on return. Long-lived
component state, SQLite pages and connection workers can remain resident.
Temperature rings allocate only reported fields, retaining the configured
1,200-sample bound. Ordinary unfiltered history pages select scalar IDs before
decoding records, reuse one scoped legacy statement, and own returned strings.
Filtered and unlimited history can still decode the full namespace, and the
scalar ID index grows with job count. These mechanisms do not imply a fixed
RSS reduction for every workload.

The file backend remains available but is not measured here and still links
SQLite. `scripts/measure-memory.sh [port]` is a separate minimal idle fixture
without Klippy and uses a bare Python baseline. Its outputs are not comparable
to these connected-daemon measurements. Never point a measurement helper at
the live printer database. The [harness](../tools/perf_harness/README.md) and
[performance report](PERFORMANCE.md#reproduce-and-limits) describe reproduction.

Historical [temperature allocations](perf/temperature-memory-20261021.json),
[history arena/tuning results](perf/history-tuning-20261021/summary.json) and
[earlier process captures](perf/history-memory-20261021/printer/aggregate.json)
remain archived, with favorable and unfavorable results intact. They are not
current v0.2.2-versus-Moonraker measurements and are excluded from these graphics.
