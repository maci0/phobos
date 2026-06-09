# Performance: phobos vs Moonraker

How phobos's request handling compares to stock Moonraker, measured on identical
hardware with Klippy taken out of the loop, plus the hot-path profiling that drove
the optimisations.

## TL;DR

phobos is **dramatically lighter and lower-latency than Moonraker on every read
path**, and after the optimisation work below the once-serialised Klippy-proxy
path scales too.

| | phobos | Moonraker |
|---|---|---|
| Idle RSS (settled) | **3.4 MB** | 57 MB (**16× more**) |
| Binary / runtime | 2.2 MB static, no runtime | CPython + ~20 deps |

Throughput / latency, Klippy stubbed, same host (vegeta, p50 latency):

| Endpoint | phobos | Moonraker |
|---|---|---|
| `server.info` @9k | **9 000/s · 0.05 ms** | 9 000/s · 0.43 ms |
| `server.config` @5k | **5 000/s · 0.06 ms** | 5 000/s · 0.48 ms |
| `machine.system_info` @9k | **9 000/s · 0.06 ms** | 2 000/s · 0.22 ms |
| `server.database.get_item` @5k | **5 000/s · 0.08 ms** | (n/a — Moonraker query path needs a fuller Klippy handshake) |
| `printer.objects.query` (Klippy-proxied) | **~4 000/s, scales with load** | — |

Local reads run **~5–8× lower latency** than Moonraker's asyncio path with a
tighter tail; `system_info` is both faster *and* ~4–5× higher throughput
(Moonraker recomputes less but phobos now caches it). The Klippy-proxy path
(`objects.query`) used to serialise on the single `Core` lock and cap ~1 k req/s;
after the off-`Core` work below it does **~4 k req/s** and scales. See the
[optimisation journey](#optimisation-journey).

## Optimisation journey

Each fix, measured on the `objects.query` flood (the heaviest path) plus the
endpoint it most affected. All driven by the profiling below.

| Change | what | impact |
|---|---|---|
| `smp_allocator` in release | `init.gpa` (DebugAllocator) captured a dwarf stack trace per allocation | `server.info` p99 4.57 ms → **0.34 ms**; `config` un-saturated (2 k→3 k/s); `query` p50 64 ms → ~5 ms |
| Bound connection concurrency | `std.Io.Threaded` pool grew unbounded under a Klippy stall (28 k threads observed) | fd/thread blow-up gone; stable under load |
| `Core` lock → dispatcher (per-method) | move the lock out of the transports so REST + JSON-RPC agree on which methods skip it | enables the off-Core reads below without the JSON-RPC deadlock the REST-only attempt hit |
| off-Core read proxies | `objects.query`/`list`, `printer.info`, `query_endstops`, `gcode.help` run lock-free | `query` ~1 070/s (5 s p99, saturating) → **~4 000/s, p99 ≤230 ms, scales** |
| drop status deep-copy | parse Klippy response straight into the request arena (`parseFromSliceLeaky`) | fewer copies of the status payload on every `query` |
| off-Core local reads | `server.info`/`config`/`system_info`/`database.get_item` lock-free (store is thread-safe; `server.info` gets a leaf mutex) | reads run in parallel instead of serialising |
| cache `machine.system_info` | it rebuilt the payload + spawned `ip` (subprocess) per call | **165/s → 9 000/s** (p50 5 s → 0.06 ms) |

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

**`objects.query`** ([SVG](perf/query_flamegraph.svg), post-optimisation) — two towers:

![objects.query flamegraph](perf/query_flamegraph.svg)

- the **Klippy reader** thread (`readerLoop` → `readFrame` → `json.Scanner` /
  `parseFromTokenSource` → arena allocs) decoding the status frame, and
- the **request** thread (`handleParsedAuth` → `proxyReq` → **`requestOffCore`** →
  **`parseFromSliceLeaky`**) translating it to the client response.

On-CPU time is JSON parse/encode + arena allocation of the status payload. The
request thread now shows `requestOffCore` (lock-free) and `parseFromSliceLeaky`
(no second deep-copy) — the two optimisations. What's left is intrinsic JSON
work; the throughput is bounded by the single Klippy socket + reader, not by the
`Core` lock any more.

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

3. **Local reads off-Core too.** `server.info`, `server.config`,
   `machine.system_info`, `server.database.get_item` are now `off_core` (the store
   is internally synchronised; `server.info` gets a small leaf `state_mutex` for the
   Klippy-mutated fields) — they run in parallel instead of serialising.
4. **`machine.system_info` cached.** It rebuilt the payload and spawned `ip` (a
   subprocess) on every call — ~165 req/s under load. The data is static, so it's
   built once into an arena and reused: **165 → 9 000 req/s** (p50 5 s → 0.06 ms),
   matching Moonraker's collect-once behaviour.

Bounded connection concurrency was already in place (`io.zig`,
`max_concurrent_conns = 128`). All of the above land with **1239 tests passing**
and both Mainsail + Fluidd validated against phobos on real hardware (WS
`objects.query` over the off-Core path returns correct results, no deadlock).

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
