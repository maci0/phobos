# Phobos — Server Spine Design

**Date:** 2026-06-01
**Status:** Approved (approach C)
**Scope:** First implementation slice — the server spine. Components plug into this later.

## 1. Goal

Reimplement Moonraker (Klipper's API server) in Zig with **100% identical externally
observable behavior** and **minimal memory footprint**, targeting ARM Cortex-A7.

"Identical behavior" is defined as: byte/JSON-equal responses and identical
server-push notification streams for the same request sequence, across all
transports (HTTP REST, HTTP JSON-RPC, WebSocket, Unix socket). This is the
*contract*. Internal structure is free to differ from the Python implementation
wherever that reduces memory use.

Vendored reference: Moonraker commit `9008485`. API contract:
`docs/api/API_SURFACE.md` (~110 endpoints, 130 JSON-RPC methods, 27 notifications).
Why upstream tests can't be the oracle: `docs/TEST_RUN_FINDINGS.md`.

## 2. Chosen approach (C): contract-faithful, internals-lean, golden oracle

Rejected alternatives:
- **A (faithful internal port):** copies Python idioms (asyncio/Tornado object graphs)
  that waste memory in Zig. Lowest parity risk but defeats the memory goal.
- **B (clean rewrite to contract):** leanest but no guard against ordering/lifecycle/
  error-semantics drift.

C keeps the *external contract* as the spec, enforced by a black-box conformance
harness that diffs phobos against stock Moonraker. Internals are designed for low
RSS, not to imitate Python.

## 3. Toolchain & target

- **Compiler:** Zig 0.16.0 (pinned).
- **Primary target:** `arm-linux-musleabihf`, `-mcpu=cortex_a7` (NEON, hard-float),
  fully static binary. Rationale: musl + static gives the lowest resident memory and
  removes glibc malloc-arena / dynamic-loader overhead for a long-running daemon.
- **Dev/CI target:** native `x86_64-linux` for fast iteration and to run the golden
  oracle next to a real Moonraker process.
- **libc:** linked only because SQLite (C) needs it; Zig code uses Zig std allocators,
  not libc malloc, for its own data.

## 3a. Zig 0.16 constraints & the std.Io decision (revised)

The Zig 0.16 "Io rewrite" relocated all networking to **`std.Io.net`** (the old
`std.net` and most of `std.posix`'s socket layer are gone), operating over a pluggable
**`std.Io`** backend (`Threaded`, `Uring`, `Kqueue`, fiber `Evented`). Per the user's
direction, phobos **uses the standard library** (`std.Io.net`, `std.Io`, and `std.http`
where it fits) rather than hand-rolling sockets or a reactor.

- **No language async/await** — removed from Zig. Concurrency is the `std.Io` model:
  `io.async(fn, args)` → `Future`, `future.await(io)`, blocking-style calls that the
  backend schedules. No `async fn`, no `std.event.Loop`.
- **Backend = `std.Io.Threaded`** (thread pool). Rationale: the deploy target is 32-bit
  ARM **Cortex-A7 (`arm` arch)**, where `std.Io.Evented`/fiber is **not implemented**
  (`fiber.supported` covers only aarch64/riscv64/x86_64). `Threaded` is the only std
  backend available on the target, so we use it on **both** dev and target for behavioral
  consistency. Validated end-to-end (Threaded + `net` TCP echo) before adopting.
- **Consequence for the memory goal:** `Threaded` parks a blocking op on a worker
  thread/stack for its duration. This suits Moonraker's workload — a 3D-printer host has
  a *handful* of concurrent clients (a few web UIs, not thousands of idle sockets) — so
  the thread/stack count stays small. We bound it: small `stack_size`, a configured
  `async_limit`/`concurrent_limit`, and we do not hold a worker per idle connection any
  longer than a request needs. Document the realistic concurrency ceiling.
- **Allocator boundary:** Zig std allocators (`DebugAllocator`, arenas, page allocator)
  manage their own pages via `mmap`, not libc `malloc`. Linked C (SQLite, resolver,
  stdio) uses libc `malloc` — musl mallocng on the static target (lean), glibc arenas on
  a glibc dev build. **Host note:** this dev machine's system glibc cannot be linked by
  Zig 0.16 (GCC 16 `.sframe` reloc); dev/CI/oracle builds use `x86_64-linux-musl` (Zig's
  bundled musl, static). Deploy uses `arm-linux-musleabihf -mcpu=cortex_a7`, static.

## 4. Runtime model

`std.Io.Threaded`-backed concurrency with a **single serialized server core** to
preserve Moonraker's observable single-loop ordering:

- One `std.Io.Threaded` instance; `io = threaded.io()` threaded through the app.
- The listener runs an accept loop; each accepted connection is handled by
  `io.async(handleConn, .{...})`. Connection IO (read request, write response, WS
  frames) uses `std.Io.net` `Stream` reader/writer.
- **Ordering contract:** Moonraker processes requests and emits notifications on one
  asyncio loop, so clients observe a single total order. Under a thread pool that order
  is *not* automatic. Phobos restores it with a **serialized core**: all shared-state
  mutation, JSON-RPC method execution, and notification fan-out happen under a single
  core mutex (or equivalently a single-consumer command queue). Connection IO is
  concurrent; the *logical* request handling and notify emission are serialized. This is
  the minimal mechanism that keeps the observable ordering identical to Moonraker.
- Blocking sub-operations Moonraker offloads (shell commands, file IO) are
  `io.async` tasks; their results re-enter the core under the same lock.
- Backpressure: bounded per-connection write buffers and bounded notification queues;
  drops/closes match Moonraker where it has limits.

## 5. Memory strategy

- **Arena-per-request:** each HTTP request / RPC call gets an arena allocator that is
  *reset* (not individually freed) at end of request. Eliminates per-allocation
  bookkeeping and fragmentation.
- **Fixed pools:** preallocated connection objects, parse buffers, and frame buffers;
  pool size is a config bound. `Stream` reader/writer buffers are caller-provided
  fixed slices (std.Io gives us this control) — size them small and reuse.
- **Bounded buffers everywhere:** no unbounded reads; streaming for uploads/downloads.
- **No global allocator churn:** long-lived state (registry, config, store handles)
  in a dedicated arena that lives for process lifetime.
- **Thread-pool footprint:** keep `std.Io.Threaded` `stack_size` small and the
  concurrency limit low (printer workload = few clients); a worker stack is the main
  per-concurrency cost, so bounding concurrency bounds RSS.

## 6. Module decomposition

Each module has one purpose, a defined interface, and is independently testable.

| Module | Purpose | Depends on |
|---|---|---|
| `io` | `std.Io.Threaded` bootstrap, `Io` handle, accept loop, conn spawn helpers | std.Io |
| `net/http` | HTTP/1.1 request parse + response serialize (over `std.Io.net` Stream; evaluate `std.http`) | io |
| `net/ws` | WebSocket RFC6455 framing (handshake, frames, close, ping/pong) | net/http |
| `jsonrpc` | JSON-RPC 2.0 dispatch + error codes (-32700/-32600/-32601/-32602) | (none) |
| `transport/http` | REST + `/server/jsonrpc` → jsonrpc | net/http, jsonrpc |
| `transport/ws` | `/websocket`, `/klippysocket` → jsonrpc | net/ws, jsonrpc |
| `transport/unixsocket` | internal socket → jsonrpc | io, jsonrpc |
| `server` | component registry, lifecycle, **serialized core** (mutex/queue), event/notification bus | io |
| `core` | transport-agnostic `server.info`, `server.config`, notify plumbing | server, jsonrpc |
| `config` | confighelper port behind `ConfigBackend` interface | (none) |
| `store` | `DataStore` interface; default drop-in SQLite impl | (none) |

**HTTP build-vs-buy (idiomatic + lean):** prefer `std.http`/`std.Io.net` primitives
over re-implementing where they give byte-exact control. The spine evaluates
`std.http.Server` for request parsing; if its forced response headers/format diverge
from Moonraker's goldens, fall back to a thin custom HTTP/1.1 codec over `Stream`
reader/writer. The oracle decides. Either way we do not hand-roll sockets.

**Module-boundary note (review H1):** `server.connection.identify` and
`server.websocket.id` are **WebSocket-transport-only**, `auth_required=False`, and
need a live connection handle (`get_client_connection()`); upstream returns
`connection_id = id(self)`. They therefore live in **`transport/ws`** (hanging off the
WS connection object), NOT in `core`. `core` holds only the transport-agnostic
`server.info` / `server.config`.

### Interfaces (stable boundaries)

- **`ConfigBackend`**: `get(section, key, default, type) -> value`, section iteration,
  include resolution. Default impl parses `moonraker.conf` identically to confighelper
  (INI-ish: `[section]`, `#`/`;` comments, multiline, type coercion, `[include ...]`).
- **`DataStore`**: namespaced get/insert/update/delete/list. For the spine slice the
  default impl = drop-in SQLite reading the existing database file. The
  leaner-native-backend question (Q2) is **deferred to the database component slice**
  (review M2): `server.database.*` has SQLite-specific semantics (compact, backup format,
  namespace ordering) that cannot be validated as "preserved" without that slice's own
  conformance fixtures. The spine only needs read access to bootstrap config-adjacent
  state; it does not pre-authorize a store swap.

## 7. Observable-contract details to preserve

- **Method registration is a runtime table**, not hardcoded derivation (review M1).
  The dispatcher consults a populated map. Static endpoints derive names via path
  `/`→`.` with multi-verb endpoints prefixing the last segment `get_`/`post_`/`delete_`
  (per `common.py::APIDefinition.create`). Dynamic Klipper-proxied endpoints
  (`printer.*`) register at runtime with **no** verb-prefixing — a different rule — so
  registration must be additive/table-driven from day one or the klippy_connection
  slice will fight the dispatcher.
- HTTP wrapping: `{"result": ...}` envelope, except `wrap_result=False` endpoints
  (octoprint compat, zeroconf SSDP) which return raw.
- Error envelopes and codes identical across transports.
- **Auth hook is transport-aware from day one** (review M1): the hook receives the
  `transport_type` and **short-circuits (bypasses auth) for the INTERNAL transport**.
  Auth chain order (from `authorization.py`, implemented in the later `authorization`
  slice): JWT → oneshot token → API key → force-login gate → trusted IP/range/domain.
  `auth_required=False` set: `/access/login`, `/access/refresh_jwt`, `/access/info`,
  `/server/connection/identify`, `/server/zeroconf/ssdp`. The spine reserves the
  transport-aware hook point; it does not implement the chain.
- **`server.info` payload (full, review H2):** must reproduce all keys incl.
  `klippy_connected`, `klippy_state`, `components`, `failed_components`,
  `registered_directories`, `warnings`, `websocket_count`, `moonraker_version`,
  `missing_klippy_requirements`, `api_version`, `api_version_string`, and honor the
  `raw` boolean param (controls `<br/>` substitution in `warnings`). API version
  string `1.5.0`.

## 8. Parity oracle (the real test suite)

`conformance/` harness:
1. Boots stock Moonraker → **golden capture** of responses + notification streams for
   a scripted request sequence. Bring-up is the documented invocation from
   `TEST_RUN_FINDINGS.md` (`uv run --with pytest ... -o "pythonpath=scripts tests"`
   plus the PHOBOS VENDOR PATCH `conftest.py`); reuse `tests/fixtures`
   (`HttpClient`, `WebsocketClient`) and `tests/assets` configs.
2. **Spine capture runs WITHOUT Klippy** (Klippy proxying is out of scope, §11). The
   golden `server.info` is therefore the *disconnected* state (`klippy_connected:
   false`, `klippy_state: "disconnected"`, `missing_klippy_requirements: []`); phobos
   must reproduce that pinned disconnected payload faithfully.
3. Boots phobos with the same config/datadir, replays the identical sequence.
4. Asserts **normalized** JSON-equality (see §8a) of every response and the ordered
   notification stream; diffs are failures.
Captures are checked in as golden files so CI can run phobos-only once captured.

## 8a. Field-normalization manifest (review B1/B2 — first-class spine deliverable)

Naive byte/JSON-equality is **impossible by construction** for several first-slice
fields. The oracle compares after canonicalization per this manifest; equality means
"equal after applying the rule." The manifest is versioned with the spec.

| Field (method) | Why it diverges | Rule |
|---|---|---|
| `connection_id` (`server.connection.identify`) | upstream = `id(self)`, a process memory address | **mask value**; assert type=int, presence, and uniqueness/monotonicity per connection (shape, not value) |
| `websocket_id` (`server.websocket.id`) | same `id(self)` source | mask value; assert int + present |
| `moonraker_version` / `software_version` (`server.info`) | git-describe string | **version-pin**: capture goldens with a phobos-matched `software_version` override so both sides emit the same string |
| `components` / `failed_components` (`server.info`) | membership+order depend on which optional components loaded | sort, then compare the spine's known-loaded set; do not assert optional-component membership in the spine slice |
| `registered_directories` (`server.info`) | env/datadir dependent | path-relativize to datadir, then compare |
| `warnings` (`server.info`) | env-dependent text, `<br/>` substitution under `raw` | compare structure/count and the `raw` branch behavior, not exact env-coupled text |
| config file paths (`server.config`) | absolute/relative paths resolved against runtime datadir | path-relativize to datadir before compare |
| any timestamp/uptime/`*_id` derived from object identity | non-deterministic | mask value; assert type+presence |

The masking/normalization layer is **spine code with its own unit + fuzz tests**, not
an afterthought — false failures from missing normalization would otherwise erode
trust in the oracle.

## 9. Testing policy

Per project rule: **every function gets a unit test AND a fuzz test**, written
alongside the implementation, not after.
- Unit: `std.testing` in-file test blocks.
- Fuzz: Zig fuzz harnesses; priority targets are the parsers (HTTP, WS framing,
  JSON-RPC, config) and the JSON-RPC dispatcher — they take untrusted input.
- Plus the conformance oracle (§8) for behavioral parity.

## 10. First-slice acceptance criteria

A phobos binary that, for a minimal config:
1. Cross-compiles to `arm-linux-musleabihf cortex_a7`, static, and runs natively for dev.
2. Serves HTTP + WebSocket on the configured host/port.
3. Dispatches JSON-RPC over HTTP REST, `/server/jsonrpc`, and `/websocket`.
4. Answers `server.info` (full payload, §7), `server.config` (transport-agnostic
   `core`) and the WS-only `server.connection.identify` (in `transport/ws`) with
   payloads **normalized-equal** (§8a) to stock Moonraker, verified by the oracle.
5. Emits at least one notification (`notify_*`) with identical framing/ordering.
6. Has unit + fuzz tests for every function — including the §8a normalization layer —
   and passes the oracle for the above.

## 11. Out of scope (this slice)

Components (file_manager, update_manager, power, history, machine, mqtt, authorization
logic, etc.), Klippy connection proxying, MQTT transport. They register into the spine
in later slices, each its own spec → plan → implementation cycle.
