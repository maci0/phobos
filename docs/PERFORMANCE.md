# Performance: phobos vs Moonraker

Historical load tests of phobos and stock Moonraker on the same x86-64 host
with Klippy replaced by a stub. The exact source revision and date were not
recorded with every result. These values predate the current review and are not
a baseline or performance guarantee for the current checkout.
Memory at idle is covered in [`MEMORY.md`](MEMORY.md).

## Recorded results

| | phobos | Moonraker |
|---|---|---|
| Idle RSS (settled) | 3.4 MB | 57 MB (16× more) |
| Binary / runtime | 2.2 MB static, no runtime | CPython + ~20 deps |

Throughput and p50 latency, Klippy stubbed, same host, vegeta:

| Endpoint | phobos | Moonraker |
|---|---|---|
| `server.info` @9k | 9 000/s · 0.05 ms | 9 000/s · 0.43 ms |
| `server.config` @5k | 5 000/s · 0.06 ms | 5 000/s · 0.48 ms |
| `machine.system_info` @5k | 5 000/s · 0.04 ms (cached) | 2 000/s · 0.22 ms |
| `server.database.get_item` @5k | 5 000/s · 0.08 ms | n/a: Moonraker's query path needs a fuller Klippy handshake than the stub gives |
| `printer.objects.query` (Klippy-proxied) | ~4 000/s, scales with load | n/a (same reason) |

Local reads run at ~5-8× lower latency than Moonraker's asyncio path, with a
tighter tail. The Klippy-proxied `objects.query` path does ~4 000 req/s; it
capped near 1 000 req/s while every request ran under the `Core` lock.

## Graphs

![throughput vs load](perf/throughput_vs_load.png)
![latency vs load](perf/latency_vs_load.png)
![query optimisation journey](perf/query_journey.png)
![memory and latency](perf/memory_and_latency.png)

phobos tracks the ideal throughput line to ~80 k req/s while Moonraker's single
event loop flattens near 6 k. Moonraker's p50 jumps from 0.37 ms to ~260 ms once
that loop backs up (~10 k req/s); phobos is still at 50 µs there. The graphs
are rendered from data points hardcoded in
[`tools/perf_harness/plot_perf.py`](../tools/perf_harness/plot_perf.py).

## Method

Both servers proxy printer queries to the same single Klippy over a unix
socket, so a real Klippy is a shared bottleneck that hides each server's own
cost. The harness removes it:

- **Klippy stub.** [`tools/perf_harness/klippy_stub.py`](../tools/perf_harness/klippy_stub.py)
  speaks the Klipper API protocol (JSON-RPC frames delimited by `\x03`) and
  answers `info`, `objects/list`, `objects/query` and `objects/subscribe` from
  canned data. Both servers connect to it through `klippy_uds_address`. It stays
  at ~1% CPU under load, in that capture; other workloads may differ. Generic HTTP mocking
  tools do not apply because Klippy's protocol is not HTTP; if a test ever needs
  a mock faster than the server, the ~80-line protocol can be ported to a
  compiled language.
- **Load.** [vegeta](https://github.com/tsenart/vegeta), keep-alive, constant
  arrival rate, 6-12 s per point.
- **Equal footing.** Same x86-64 host (32 cores), same stub, same endpoints, a
  copy of a real `moonraker-sql.db`. phobos built `ReleaseFast`; Moonraker ran
  from its own venv.
- Reproduce with [`tools/perf_harness/bench_local.sh`](../tools/perf_harness/bench_local.sh).
  The on-printer comparison uses `compare.sh`; see the
  [perf harness README](../tools/perf_harness/README.md).

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
  query  @2000:  (needs a fuller Klippy "ready" handshake than the stub gives;
                  Moonraker rejects printer queries while klippy_state=startup)
```

- **Memory:** 3.5 MB vs 57 MB. Moonraker loads CPython, tornado and ~20
  packages before serving a request. [`MEMORY.md`](MEMORY.md) has the
  per-backend breakdown (SQLite ~2.2 MB, file ~1.2 MB on armv7).
- **Latency:** phobos answers local reads in ~50 µs, 5-7× faster than
  Moonraker, with a tighter tail.
- **Throughput:** both reach thousands of req/s on simple reads; phobos goes
  higher (9 k vs 5 k) at a fraction of the latency.

## Upper bounds

Each path pushed until it broke. vegeta, phobos and the stub share the 32-core
host, so the top end measures the host as well as phobos.

| Path | Flat, sub-ms | p99 starts climbing | Breaks |
|---|---|---|---|
| `server.info` (in-memory) | ≤ 20 k req/s (p99 < 1 ms) | 40-80 k (p99 10-15 ms, p50 still 0.05 ms) | ~120 k (70% success) |
| `database.get_item` (SQLite) | ≤ 20 k req/s | 40 k (p99 11 ms) | > 40 k (not reached) |
| `objects.query` (Klippy proxy) | n/a | from ~6 k offered | plateaus ~3.5 k/s |

- **Local reads** sustain ~80 000 req/s at 100% success with p50 at 50 µs. The
  break at ~120 k comes from three processes contending for 32 cores, not from
  phobos. A printer sees single-digit req/s in practice.

  The same `server.info` sweep against Moonraker:

  | Offered | phobos p50 | Moonraker p50 |
  |---|---|---|
  | 5 k | 0.05 ms | 0.37 ms |
  | 10 k | 0.05 ms | 263 ms (loop backs up) |
  | 20 k | 0.07 ms | 271 ms |
  | 80 k | 0.05 ms | 226 ms |

  Moonraker holds to ~5 k req/s; at ~7-10 k its p50 jumps to ~260 ms and
  throughput stops at ~6 k/s, with CPU at ~55% because one event-loop thread
  cannot use the other 31 cores. phobos holds 0.05 ms p50 to 80 k because
  off-`Core` reads run across the thread pool: a ~12× higher read ceiling.
- **`objects.query`** plateaus at ~3 000-3 500 req/s with the stub at 3% CPU
  and phobos at 30%. The limit is the single Klippy socket: every query
  multiplexes over one connection with serial round-trips, so past ~3.5 k/s
  requests queue (p50 stays ~15 ms, p99 climbs to seconds). Moonraker has the
  same one-socket constraint, and a real Klippy is slower than the stub.

## Memory and threads under load

ReleaseFast, Klippy stubbed, vegeta:

| State | VmRSS | Threads |
|---|---|---|
| idle (settled) | 3.5 MB | 6 |
| `server.info` @ 8 000 req/s (local, off-Core) | 12.4 MB | 63 |
| `objects.query` @ 2 000 req/s (Klippy-proxied) | ~12 MB | 54 |

`server.info` sustains 8 000 req/s at 100% success, p50 32 µs; `objects.query`
is bounded by the Klippy socket (p50 ~12 ms). RSS growth comes from the
`std.Io.Threaded` worker pool, which grows to the peak number of concurrent
connection tasks and is not shrunk; `max_concurrent_conns = 128` in
`src/io.zig` bounds it. The printer has 107 MB of RAM.

## Virtual memory on 32-bit targets

The connection-handler pool peaks at ~128 threads. With the runtime-default
16 MB stack that reserved ~2.1 GB of VSZ, enough to exhaust the 3 GB user
address space on armv7 under load. Handlers need ~120 KB of stack (the 64 KB
file buffer plus bounded JSON depth), so on 32-bit targets `src/main.zig` owns
its `std.Io.Threaded` with a 1 MB stack (`io.Listener.handler_stack_size`).
VSZ drops to ~180 MB (≈12×) with no change in throughput; RSS is ~9 MB after a
load spike either way because it counts touched pages, not the reservation. On
64-bit targets (`ptrBitWidth() > 32`) the runtime-default backend is used.

## Large G-code files

Both directions of `/server/files/...` stream to or from disk in 64 KB chunks,
so a large transfer runs in constant memory.

- **Download** (`GET /server/files/<root>/<path>`): the handler resolves the
  path and the transport streams it with `respondStreaming` (content length from
  the file size), copying file to socket with `std.Io.Reader.streamRemaining`.
- **Upload** (`POST /server/files/upload`): intercepted before the body is read.
  A bounded multipart scanner (`streamUntilSeparator`, which holds back only
  `boundary.len - 1` bytes between reads) parses the form incrementally and
  writes the file part to disk, buffering only the small `root`/`path` fields.
  The disk write runs off `Core`; `notify_filelist_changed` and the result build
  stay under `Core`.

Peak RSS during a 150 MB transfer:

| | phobos, buffered | phobos, streaming | Moonraker |
|---|---|---|---|
| download | +150 MB spike | flat (+0.1 MB) | streams (flat) |
| upload | +150 MB spike | flat (+0.14 MB) | streams (flat) |
| baseline RSS | 3.4 MB | 3.4 MB | ~57 MB |

Moonraker also streams both directions (tornado `StaticFileHandler` for
downloads, `@stream_request_body` with `data_received` for uploads). Both
transfers were verified byte-exact.

## JSON nesting depth

`std.json` parsing is iterative, so deep input parses without touching the
stack. `std.json.Stringify` serializes with a fixed 256-level nesting stack: a
deeper value panics, and corrupts memory in release builds where the bounds
check is off. A client could store a deeply nested value through
`server.database.item` and crash a later `GET`, or send deep `params` to a
Klippy proxy.

`jv.exceedsDepth` rejects values past `max_value_depth` (100 in
`src/json/value.zig`; real Moonraker data is under 10 deep) with
`InvalidParams`, on database insert and on Klippy request serialization, so
over-deep values never reach `Stringify`. `src/test_stress.zig` runs the
adversarial cases (20 k-deep arrays and objects, 1 M-wide arrays, depth at the
limit) each on a fresh 1 MB-stack thread, to expose stack regressions in the host suite.

## Hot-path profiling

[`tools/perf_harness/profile.sh`](../tools/perf_harness/profile.sh) builds with
frame pointers (`zig build -Doptimize=ReleaseFast -Dprofile`), runs a vegeta
flood through the Klippy stub, captures with `perf record` (or bpftrace with
`USE_BPFTRACE=1`, which needs root), and renders a
[FlameGraph](https://github.com/brendangregg/FlameGraph). The perf path needs
no privileges and produces the same on-CPU flamegraph.

### Allocator stack traces

Before the allocator change, the top of the profile was
`debug.captureCurrentStackTrace` / `Dwarf.SelfUnwinder` /
`getDebugInfoAllocator` at ~15-20%. `init.gpa` (std's `DebugAllocator`)
captures a DWARF stack trace on every allocation for leak and use-after-free
detection. [`src/main.zig`](../src/main.zig) uses the lock-sharded
`std.heap.smp_allocator` in release builds and keeps the checked allocator for
`Debug`.

| Path | Before | After |
|---|---|---|
| `server.info` p99 | 4.57 ms | 0.34 ms |
| `server.config` @3 k | saturates (p99 3.2 s) | 3 000/s, p99 0.18 ms |
| `objects.query` p50 | 64 ms | ~5 ms |
| `objects.query` throughput | ~1 070/s | ~2 160/s |

### Flamegraphs

**`objects.query`** ([SVG](perf/query_flamegraph.svg)):

![objects.query flamegraph](perf/query_flamegraph.svg)

The committed SVG has no resolved symbols (every frame is `[phobos]` or
`[unknown]`), so it does not show the breakdown below, which was recorded from
the original capture. Some frame names have since changed (`readFrame` no
longer exists in `src/components/klippy_connection.zig`); rerun `profile.sh`
to confirm. The recorded profile had two towers:

- the Klippy reader thread (`readerLoop` → `readFrame` → `json.Scanner` /
  `parseFromTokenSource` → arena allocations) decoding the status frame, and
- the request thread (`handleParsedAuth` → `proxyReq` → `requestOffCore` →
  `parseFromSliceLeaky`) translating it into the client response.

On-CPU time is JSON parse and encode plus arena allocation of the status
payload. Throughput is bounded by the single Klippy socket and reader.

**`server.info`** ([SVG](perf/info_flamegraph.svg)) is nearly flat: a little
arena allocation and the response write.

**Pure dispatch** ([`perf/flamegraph-serverinfo.svg`](perf/flamegraph-serverinfo.svg))
spends ~25% in `ArenaAllocator.alloc` and ~30% in `wrapResult` →
`jsonStringify`, building and serializing the response. Caching immutable
response bodies would help only synthetic single-endpoint floods, not the
Klippy-bound workload, so it is not done.

## Reproduce

```sh
zig build -Doptimize=ReleaseFast
bash tools/perf_harness/bench_local.sh   # writes /tmp/perf-report.txt

# profile the hot path (needs perf; FlameGraph at $FLAMEGRAPH_DIR or ~/FlameGraph)
tools/perf_harness/profile.sh            # or USE_BPFTRACE=1 for eBPF
```

Absolute numbers vary with host and kernel.
