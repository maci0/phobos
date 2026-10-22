# Memory footprint

Current measurements compare **phobos 0.2.2 development with Moonraker**,
measured 2026-10-22. The ReleaseFast build is not the published v0.2.2 asset.
The [performance report](PERFORMANCE.md) and [method](perf/optimization-20261022-2/METHOD.md) identify
sources, executable hashes, fixtures, rates and measured scheduling limits.
Every active graphic shows only the current build and Moonraker.

**Lower RSS is better.** KiB means 1,024 bytes. RSS counts resident pages,
including executable text and allocator-retained pages, not total allocations
or private memory. Idle values are medians of three fresh-process trial medians,
with their range. Load tables give the maximum sampled RSS across all workloads
and repetitions. Plots show each workload's median trial maximum with min/max
whiskers. Samples can miss brief peaks; VmSize and VmHWM are different metrics.

## Cortex-A7 printer

Forge-X 1.4.2 chroot, Linux 5.4.61, 110,404 KiB RAM. Production is paused during
load. Private probes use the same minimal config, 266-job seed and synthetic
64 KiB item; their component set is smaller than production. All server threads
run on CPU 1. The installed reference uses Python 3.11.10.

| Process | Median idle KiB ↓ (trial range) | Maximum sampled load KiB ↓ |
| --- | ---: | ---: |
| phobos development | 4,720 (4,548.0 to 4,772) | 6,452 |
| Moonraker | 37,880 (37,640.0 to 37,884) | 37,888 |

![printer memory, current phobos versus Moonraker](perf/optimization-20261022-2/printer/memory.png)

The table includes HTTP and full-subscription samples; the graphic covers HTTP
and idle. Load sampling is about 100 ms; lifetime/idle sampling about 250 ms.
VmHWM can retain a previous unlimited-history preflight peak and is not a
per-workload peak. Board MemAvailable stays above 20,508 KiB,
with a 16 MiB guard. Probe VmSwap stays 0 KiB.
Board SwapFree ranges from 0 to
472 KiB; zero probe swap does not prove the entire
board avoided swapping. Swap settings remain unchanged.
[Board observations](perf/optimization-20261022-2/printer/board-memory.json) retain these limits.

## KVM on the benchmark PC, populated history

Four vCPUs and 4 GiB locked RAM, with separate server, generator and stub CPUs,
an isolated physical L3 group and no VM swap. Both servers use the same fixture.
Runtime, SQLite and scheduling controls are in the [performance report](PERFORMANCE.md).

| Process | Median idle KiB ↓ (trial range) | Maximum sampled load KiB ↓ |
| --- | ---: | ---: |
| phobos development | 7,408 (7,400 to 9,444) | 11,672 |
| Moonraker | 57,800 (57,668 to 58,408) | 60,940 |

![vm-rich memory, current phobos versus Moonraker](perf/optimization-20261022-2/vm-rich/memory.png)

## KVM on the benchmark PC, empty history

Same controls with fresh databases containing only the 64 KiB item.

| Process | Median idle KiB ↓ (trial range) | Maximum sampled load KiB ↓ |
| --- | ---: | ---: |
| phobos development | 6,872 (4,860 to 8,908) | 10,892 |
| Moonraker | 58,252 (58,168 to 58,424) | 58,588 |

![vm-empty memory, current phobos versus Moonraker](perf/optimization-20261022-2/vm-empty/memory.png)

QEMU's locked host RAM is excluded from daemon RSS. RSS can vary by several
MiB between fresh phobos processes because of allocator/worker/address-layout
behavior. Three trials do not isolate those effects. The separate local-host
[corroboration](perf/optimization-20261022-2/local-vm/) is not pooled with remote-host measurements.

## Allocation and ownership

The entry point uses `std.process.Init.gpa`. Zig 0.17 selects a checked allocator
in Debug/ReleaseSafe and `std.heap.c_allocator` for this libc-linked ReleaseFast
program. The previous entry point overrode release modes with the SMP allocator.
Component and request allocations remain explicit. Focused allocator comparisons
are archived; no universal resident-memory reduction is attributed to that choice.

Klippy's reader owns a persistent 64 KiB standard I/O buffer. A reply is parsed
once into its own arena, retained by its waiter, copied into the caller's
allocator and released. There is a deliberate peak-memory tradeoff: the 256 KiB
reply allocation test observes about 580 KiB (594,223 bytes) of parsed storage, bounded below
2.5 times the wire size plus 4 KiB. Standard dynamic JSON string growth and arena
growth account for the spare capacity. The prior wire-copy allocation bound no
longer describes this implementation; the budget is not an RSS promise.

Long valid UTF-8 strings use a 1 KiB stack output buffer and a 896-byte compile-time
escape table derived from the standard encoder. SIMD comparisons find unescaped
runs. Nondefault options and invalid UTF-8 use the standard path. Status updates
are batched before per-client filtering, avoiding a separate frame per object.
Connection references, deadlines, authentication and field masks are preserved.

Legacy SQL history without KV overrides selects only the requested page instead
of collecting every ID and issuing one query per row. A 10,000-job, one-row-page
regression test checks correct content and less than 64 KiB request allocation.
Mixed KV/table histories retain the validated full-ID fallback; filtered and
unlimited reads may still decode the full namespace. Temperature rings remain
bounded. The file backend still links SQLite and is not measured.

ReleaseFast produces larger executables than ReleaseSmall and may increase
resident code pages. Earlier-build comparisons do not show a universal RAM
reduction; memory is traded for lower request CPU where measured. Published
[v0.2.2](perf/v0.2.2/) and earlier studies remain unchanged. These measurements
do not establish printing memory, long-soak behavior or all ARM/AArch64 hardware.
