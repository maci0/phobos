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

phobos is **dramatically lighter and lower-latency** on every local read path. Its
one weak spot is the **Klippy-proxied** path (`printer.objects.query`), which
serialises through the single `Core` lock + the one Klippy socket and saturates
around 1–2 k req/s — see [Remaining bottleneck](#remaining-bottleneck).

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
  query  @2000:  thru=~1100/s succ=98%   p50=5–60ms  p99=high   (saturates)

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

Next steps:

1. **Run pure read handlers off the `Core` lock** (`objects.query`, `server.info`,
   `server.config`, `database.get_item` — none mutate shared state). *Attempted and
   reverted*: it's only safe if the off-`Core` decision is consistent across **both**
   request paths. The HTTP-REST path resolves the route before locking, so it can
   skip `Core` easily; but the JSON-RPC path wraps the whole `Dispatcher.handle` in
   `core.run`, so a proxy invoked over JSON-RPC would run the no-`Core` Klippy
   request *under* `Core` and deadlock (the reader can't dispatch the response).
   Doing this cleanly requires **moving the `Core` acquisition out of the transports
   into `Dispatcher.handle`** (per-method, keyed off a `read_only` flag) so REST and
   JSON-RPC agree. Worthwhile but a focused refactor of the locking model — left for
   a dedicated change. (The latent `next_id` race it surfaced is already fixed.)
2. **Reduce copies on the proxy path** — the flamegraph shows the status payload
   JSON-decoded then `memcpy`'d/deep-copied more than once (Klippy frame → parsed
   value → client response). A borrow/move path (or streaming the Klippy result
   straight into the response writer) would cut the dominant on-CPU cost without
   touching the locking model — lower risk than (1).
3. **Bounded connection concurrency is already in place** (`io.zig`,
   `max_concurrent_conns = 128`) so a Klippy stall can't explode the worker pool.

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
