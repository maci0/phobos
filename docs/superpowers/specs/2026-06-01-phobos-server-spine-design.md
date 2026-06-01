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
- **libc:** linked only because liblmdb (C) needs it; Zig code uses Zig std allocators,
  not libc malloc, for its own data.

## 3a. Zig 0.16 constraints

- **No language async/await** — removed from Zig. The reactor is a hand-rolled,
  explicit state-machine/callback design. No `async fn`, no `std.event.Loop` (gone).
- **`std.Io` not used** — its interface churned across 0.13→0.16; phobos owns its
  reactor to avoid the moving target.
- **Allocator boundary, scoped precisely:** Zig std allocators (`DebugAllocator`/GPA,
  arenas, page allocator) manage their own pages via `mmap` and do **not** route
  phobos-owned allocations through libc `malloc`. **However**, linked C code retains
  its own allocator: liblmdb, the libc DNS resolver, and stdio call libc `malloc`.
  On the **musl-static target** that is musl's mallocng (lean); on the **native
  x86_64 dev/CI build** it is typically glibc with arenas. So: the "no glibc arena
  overhead" rationale holds for the deployed target only — dev and target differ in
  allocator behavior, which the oracle host must account for.

## 4. Runtime model

Single-threaded epoll event loop (`Reactor`) mirroring asyncio semantics:

- fd readiness registration (level/edge as appropriate), one-shot and periodic timers,
  and a deferred-callback queue (asyncio `call_soon` equivalent) that preserves FIFO
  ordering — this ordering is part of the observable contract for notification
  delivery.
- No threads, no locks on the hot path. A small **bounded** worker queue handles only
  the operations Moonraker itself offloads (shell commands, blocking file IO); results
  re-enter the loop via an eventfd/self-pipe wakeup.
- Backpressure: bounded per-connection write buffers; bounded notification fan-out
  queues. Drops/closes match Moonraker's behavior where it has limits.

## 5. Memory strategy

- **Arena-per-request:** each HTTP request / RPC call gets an arena allocator that is
  *reset* (not individually freed) at end of request. Eliminates per-allocation
  bookkeeping and fragmentation.
- **Fixed pools:** preallocated connection objects, parse buffers, and frame buffers;
  pool size is a config bound.
- **Bounded buffers everywhere:** no unbounded reads; streaming for uploads/downloads.
- **No global allocator churn:** long-lived state (registry, config, store handles)
  in a dedicated arena that lives for process lifetime.

## 6. Module decomposition

Each module has one purpose, a defined interface, and is independently testable.

| Module | Purpose | Depends on |
|---|---|---|
| `reactor` | epoll loop, timers, deferred-call queue, worker wakeup | (none) |
| `net/http` | HTTP/1.1 request parse + response serialize | reactor |
| `net/ws` | WebSocket RFC6455 framing (handshake, frames, close, ping/pong) | net/http |
| `jsonrpc` | JSON-RPC 2.0 dispatch + error codes (-32700/-32600/-32601/-32602) | (none) |
| `transport/http` | REST + `/server/jsonrpc` → jsonrpc | net/http, jsonrpc |
| `transport/ws` | `/websocket`, `/klippysocket` → jsonrpc | net/ws, jsonrpc |
| `transport/unixsocket` | internal socket → jsonrpc | reactor, jsonrpc |
| `server` | component registry, lifecycle, event/notification bus | reactor |
| `core` | transport-agnostic `server.info`, `server.config`, notify plumbing | server, jsonrpc |
| `config` | confighelper port behind `ConfigBackend` interface | (none) |
| `store` | `DataStore` interface; default drop-in liblmdb impl | (none) |

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
  default impl = drop-in liblmdb reading the existing database file. The
  leaner-native-backend question (Q2) is **deferred to the database component slice**
  (review M2): `server.database.*` has LMDB-specific semantics (compact, backup format,
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
