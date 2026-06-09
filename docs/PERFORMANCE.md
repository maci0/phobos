# Performance: phobos vs Moonraker

How phobos's request handling compares to stock Moonraker, measured on identical
hardware with Klippy taken out of the loop, plus the hot-path profiling that drove
the optimisations.

## TL;DR

| | phobos | Moonraker | ratio |
|---|---|---|---|
| Idle RSS (settled) | **3.5 MB** | 57 MB | **16× less** |
| `server.info` p50 latency | **0.05 ms** | 0.24–0.38 ms | **5–7× lower** |
| `server.info` sustained | **9 000 req/s** (p99 0.34 ms) | 5 000 req/s (p99 2 ms) | ~1.8× |
| `server.config` sustained | **3 000 req/s** (p99 0.18 ms) | 3 000 req/s (p99 0.92 ms) | similar throughput, ~5× lower latency |
| Binary / runtime | 2.1 MB static, no runtime | CPython + ~20 deps | — |

phobos is **dramatically lighter and lower-latency** on every local read path. The
**Klippy-proxied** path (`printer.objects.query`) used to serialise on the single
`Core` lock and cap ~1 k req/s; after the off-`Core` read-proxy work below it does
**~4.6 k req/s** and scales with load — see [profiling](#hot-path-profiling).

## Methodology

The hard part of a fair comparison is that *both* servers proxy printer queries to
the same single Klippy over a unix socket — so a real Klippy is the shared
bottleneck and hides each server's own cost. We remove it:

- **Klippy stub** — [`tools/perf_harness/klippy_stub.py`](../tools/perf_harness/klippy_stub.py)
  speaks the real Klipper API protocol (JSON-RPC frames delimited by `\x03`) and
  answers `info` / `objects/list` / `objects/query` / `objects/subscribe` instantly
  from canned data. Both phobos and Moonraker connect to it identically
  (`klippy_uds_address`). It stays at **~1 % CPU** under load, so it is never the
  bottleneck.
- **Load** — [vegeta](https://github.com/tsenart/vegeta), keep-alive, constant
  arrival rate, 6–12 s per point.
- **Equal footing** — both servers on the same x86-64 host, same stub, same
  endpoints, pointed at a copy of a real `moonraker-sql.db`. phobos built
  `ReleaseFast`; Moonraker from its own venv.
- Reproduce: [`tools/perf_harness/bench_local.sh`](../tools/perf_harness/bench_local.sh)
  (must run as one invocation). On-printer comparison: `compare.sh` (see the
  [perf harness README](../tools/perf_harness/README.md)).

### On "the best high-performance API mocking tool"

For an HTTP API you would reach for WireMock (JVM), Mockoon, Prism, or hand-roll a
Go/`fasthttp` mock — all fine at tens of thousands of req/s. **None of them apply
here**: Klippy is not HTTP, it is a custom length/ETX-framed JSON-RPC stream over a
unix socket, so the mock has to be protocol-specific. A small purpose-built stub is
the right tool, and Python is fast enough — the stub answers from a dict and idles
at ~1 % CPU while phobos is pinned. If a future test needs the mock to outrun the
server (it doesn't today), port `klippy_stub.py` to Go/Rust to drop the GIL; the
protocol is ~80 lines. The bottleneck this harness exposed is in phobos, not the
mock.

## Results (Klippy stubbed, local, vegeta)

```
## phobos (ReleaseFast)   idle_RSS=3.5 MB   klippy=ready
  info   @2000:  thru=2000/s  succ=100%  p50=0.05ms  p99=0.11ms
  info   @5000:  thru=5000/s  succ=100%  p50=0.05ms  p99=0.21ms
  info   @9000:  thru=8999/s  succ=100%  p50=0.05ms  p99=0.34ms
  config @3000:  thru=3000/s  succ=100%  p50=0.06ms  p99=0.18ms
  query  @2000+: thru=~4640/s succ=94%   p50=17ms    p99<=230ms (off-Core, scales)

## moonraker (Python/asyncio)  idle_RSS=57 MB
  info   @2000:  thru=2000/s  succ=100%  p50=0.24ms  p99=0.71ms
  info   @5000:  thru=5001/s  succ=100%  p50=0.38ms  p99=2.09ms
  config @3000:  thru=3000/s  succ=100%  p50=0.37ms  p99=0.92ms
  query  @2000:  (needs a fuller Klippy "ready" handshake than the stub gives —
                  Moonraker rejects printer queries while klippy_state=startup)
```

- **Memory** is the headline: 3.5 MB vs 57 MB. phobos is a single static binary with
  no interpreter, GC, or virtualenv; Moonraker carries CPython + tornado + ~20
  packages before serving a byte. See [`docs/MEMORY.md`](MEMORY.md) for the
  per-backend breakdown (SQLite ~2.2 MB / file ~1.2 MB on armv7).
- **Latency**: phobos answers local reads in ~50 µs, 5–7× faster than Moonraker's
  asyncio path, with a far tighter tail.
- **Throughput**: both scale to thousands of req/s on simple reads; phobos goes
  higher (9 k vs 5 k) at a fraction of the latency.

## Hot-path profiling

`perf record -g --call-graph=dwarf` against phobos under an `objects.query` flood
(the heaviest path). Two findings:

### Fixed: dwarf stack-trace capture on every allocation

The top of the profile was **`debug.captureCurrentStackTrace` / `Dwarf.SelfUnwinder`
/ `getDebugInfoAllocator` (~15–20 %)**. Cause: `init.gpa` (std's `DebugAllocator`)
captures a dwarf stack trace on *every* allocation for leak/UAF detection — useful
in tests, pure overhead in a release daemon, and worst on allocation-heavy
proxy requests.

Fix ([`src/main.zig`](../src/main.zig)): use the lock-sharded
`std.heap.smp_allocator` in release; keep the checked allocator only for `Debug`.

### Flamegraphs

Generated with [`tools/perf_harness/profile.sh`](../tools/perf_harness/profile.sh)
— a frame-pointer release build (`zig build -Doptimize=ReleaseFast -Dprofile`)
under a vegeta flood through the Klippy stub, captured with perf and rendered via
[FlameGraph](https://github.com/brendangregg/FlameGraph). (`USE_BPFTRACE=1` swaps
perf for an eBPF/bpftrace capture where root is available; the perf path needs no
privileges and produces the same on-CPU flamegraph.)

**`objects.query`** ([SVG](perf/query_flamegraph.svg)) — two towers:

![objects.query flamegraph](perf/query_flamegraph.svg)

- the **Klippy reader** thread (`readerLoop` → `readFrame` → `json.Scanner` /
  `parseFromTokenSource` → arena allocs) decoding the status frame, and
- the **request** thread (`handleParsedAuth` → `requestConcurrent` →
  `json.parse` + `mem.copyForwards`) translating it to the client response.

On-CPU time is dominated by **JSON parse/encode + allocation + `memcpy`** of the
status payload — the status object is decoded then deep-copied into the client
response more than once. The off-CPU serialisation (the `requestConcurrent`
unlock/wait/lock visible mid-stack) is what caps throughput.

**`server.info`** ([SVG](perf/info_flamegraph.svg)) — almost flat: a little arena
alloc + the response write, then idle. The fast path has nothing to optimise.

Before → after:

| path | before | after |
|---|---|---|
| `server.info` p99 | 4.57 ms | **0.34 ms** |
| `server.config` @3 k | saturates (p99 3.2 s) | **3 000/s, p99 0.18 ms** |
| `objects.query` p50 | 64 ms | **~5 ms** |
| `objects.query` throughput | ~1 070/s | **~2 160/s** |

### Remaining bottleneck

After the allocator fix the on-CPU profile is dominated by JSON
encode/decode + `memcpy` of the Klippy status payload — but `objects.query` still
caps at ~1–2 k req/s with a high tail while the CPU is *not* saturated and the stub
idles at 1 %. That is **off-CPU serialisation**, not compute:

- Every request runs under the single **`Core` mutex** (Moonraker's single-loop
  observable-ordering guarantee, reproduced on purpose). The proxy releases `Core`
  for the Klippy round-trip, but re-acquires it to build the response, and the
  Klippy reader also dispatches under `Core` — so concurrent queries contend on one
  lock.
- All Klippy traffic flows through **one socket** with a write mutex; round-trips
  pipeline via per-id waiters but still serialise on that lock.

### Done: off-`Core` read proxies + fewer payload copies

Both fixes the flamegraph pointed at, now landed:

1. **`Core` acquisition moved out of the transports into `Dispatcher.handle`**
   (per-method, keyed off a `read_only`/`off_core` flag), and the REST path makes
   the same per-route decision — so REST and JSON-RPC **agree**: both skip `Core`
   for read-only methods and hold it for everything else. The Klippy read proxies
   (`objects.query`/`list`, `printer.info`, `query_endstops`, `gcode.help`) are now
   marked `off_core` and run lock-free via a no-`Core` Klippy request, so concurrent
   reads execute in parallel instead of serialising on the one lock. (An earlier
   attempt that only changed the REST path deadlocked over JSON-RPC; moving the lock
   into the dispatcher is what makes it safe.)
2. **Dropped the redundant deep-copy** of the Klippy status payload: the proxy now
   parses the response straight into the per-request arena (`parseFromSliceLeaky`)
   and returns it, instead of `parseFromSlice` + a full `deepCopyValue`.

Measured (Klippy stubbed): `objects.query` went from **~1 070 req/s, p50 64 ms,
p99 5 s (saturating)** to **~4 640 req/s, p50 17 ms, p99 ≤ 230 ms** and it now
*scales* with offered load. `server.info` is unchanged (9 k req/s, 50 µs). 1239
tests pass, including the real-Klippy-proxy path.

Still open: bounded connection concurrency is already in place (`io.zig`,
`max_concurrent_conns = 128`); marking the local reads (`server.info`,
`server.config`, `database.get_item`, `machine.system_info`) `off_core` too is a
cheap follow-up now that the mechanism exists.

## Reproduce

```sh
# one invocation — sandboxed background procs don't survive across calls
zig build -Doptimize=ReleaseFast
bash tools/perf_harness/bench_local.sh   # writes /tmp/perf-report.txt

# profile the hot path (needs perf; ReleaseFast keeps symbols)
tools/perf_harness/profile.sh            # or USE_BPFTRACE=1 for eBPF
```

Numbers vary with host/kernel; the ratios (phobos lighter + lower-latency on reads,
serialisation-bound on the Klippy proxy) hold.
