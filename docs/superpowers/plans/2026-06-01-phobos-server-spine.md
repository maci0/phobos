# Phobos Server Spine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the phobos server spine — `std.Io.net` + `std.Io.Threaded` networking, HTTP/1.1 + WebSocket transports, a JSON-RPC 2.0 dispatcher, the always-on `server.info`/`server.config`/`server.connection.identify` methods, a notification bus, and a golden-capture conformance oracle — in Zig 0.16, byte-for-byte behavior-equal (after the §8a normalization manifest) to stock Moonraker.

**Architecture:** Networking via `std.Io.net` over the `std.Io.Threaded` backend (the only std Io backend on 32-bit ARM Cortex-A7; `std.net` and the old socket layer are gone in 0.16). Listener accept loop spawns a per-connection `io.async` task; connection IO uses `std.Io.net` `Stream` reader/writer with caller-provided fixed buffers. Moonraker's single-loop observable ordering is restored by a **serialized server core**: JSON-RPC execution, shared-state mutation, and notification fan-out run under one core mutex/queue while connection IO stays concurrent. All transports (HTTP REST, `/server/jsonrpc`, `/websocket`) converge on one JSON-RPC dispatcher consulting a runtime method table. Arena-per-request allocation, bounded buffers, small thread-pool stacks. liblmdb linked for the drop-in data store; phobos-owned data uses Zig std allocators.

**Tech Stack:** Zig 0.16.0; target `arm-linux-musleabihf -mcpu=cortex_a7` static (deploy) + native `x86_64-linux` (dev/CI); liblmdb (C); Python `uv`-run stock Moonraker as the golden oracle source.

**Reference docs (read before starting):**
- Spec: `docs/superpowers/specs/2026-06-01-phobos-server-spine-design.md` (authoritative)
- API contract: `docs/api/API_SURFACE.md`
- Why upstream tests are unusable: `docs/TEST_RUN_FINDINGS.md`
- Coverage map: `docs/TEST_COVERAGE.md`

**Zig 0.16.0 API cheatsheet (verified against installed std — use these exact forms):**
- **Allocator:** `var gpa: std.heap.DebugAllocator(.{}) = .init; defer _ = gpa.deinit();` (`GeneralPurposeAllocator` is gone). Tests use `std.testing.allocator`.
- **ArrayList is unmanaged:** `var xs: std.ArrayList(T) = .empty;` then `try xs.append(alloc, item);`, `xs.deinit(alloc);`, `xs.items`. The allocator is passed to every mutating method — there is no `.init(alloc)`.
- **Fuzzing:** `std.testing.fuzz(context, testOne, .{})` where `testOne: fn(@TypeOf(context), smith: *std.testing.Smith) anyerror!void`. The input is a `*Smith` structured generator, **not** `[]const u8`. Pull bytes with `smith.bytesWithHash(buf, 0)` / values with `smith.valueRangeAtMostWithHash(u8, 0, 255, 0)`. Helper used throughout: fill a stack buffer via `bytesWithHash`, slice it, feed the parser.
- **Networking = `std.Io.net` over `std.Io.Threaded`** (NOT raw syscalls, NOT a custom reactor — both rejected). `std.net` is gone in 0.16; networking moved under `std.Io`. Validated pattern:
  ```zig
  var threaded = std.Io.Threaded.init(gpa, .{}); defer threaded.deinit();
  const io = threaded.io();
  var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
  var server = try addr.listen(io, .{ .reuse_address = true });   // -> net.Server
  defer server.deinit(io);
  const stream = try server.accept(io);                            // -> net.Stream (scheduled by io)
  var rbuf: [N]u8 = undefined; var r = stream.reader(io, &rbuf);   // r.interface is *std.Io.Reader
  const line = try r.interface.takeDelimiterExclusive('\n');
  var wbuf: [N]u8 = undefined; var w = stream.writer(io, &wbuf);   // w.interface is *std.Io.Writer
  try w.interface.print("...", .{}); try w.interface.flush();
  // client: try std.Io.net.IpAddress.parseIp4(ip,port) then .connect(io, .{ .mode = .stream })
  // concurrency: var fut = io.async(func, .{args}); ... fut.await(io);
  // ephemeral-port readback: std.os.linux.getsockname(server.socket.handle, &sa, &len) then std.mem.bigToNative(u16, sa.port)
  ```
  Caller-provided fixed reader/writer buffers = our memory control. `getsockname` for ephemeral-port readback is the lone raw-syscall exception (no std wrapper).
- **JSON:** parse with `std.json.parseFromSlice(std.json.Value, alloc, src, .{})`. Serialize with `std.json.Stringify` (struct: `Stringify.valueAlloc(alloc, v, .{})`) — there is no free `std.json.stringify`. Insertion-order key output: `std.json.Value`'s `object` is an `ArrayHashMap`, so it preserves insertion order; verify against goldens before assuming.
- **Build: link flags live on the Module, not the Compile.** Pass `.link_libc = true` into `b.createModule(...)`, then `mod.linkSystemLibrary("lmdb", .{})` on that module (or `exe.root_module.linkSystemLibrary(...)`). `exe.linkLibC()` does not exist in 0.16.
- **ArenaAllocator.reset** returns `bool`: `_ = self.arena.reset(.retain_capacity);` is correct.

**Conventions for every task:**
- TDD: write the failing test first, watch it fail, minimal impl, watch it pass, commit.
- **Project rule (non-negotiable):** every function gets a **unit test AND a fuzz test** alongside it. Where several functions form one parser/codec over the same untrusted input (e.g. `acceptKey` + frame codec in `net/ws.zig`), a single module fuzz harness that drives **each public function** satisfies the rule — but it must call each function, not just one. Parsers/dispatchers are the priority fuzz targets.
- Run unit tests: `zig build test`. Run a single module's tests: `zig test src/<mod>.zig`.
- Run fuzz (smoke, bounded): `zig build fuzz` (wires `std.testing.fuzz` harnesses; in CI run with an iteration cap).
- Commit messages: Conventional Commits, **no AI attribution**, human-authored voice.
- Commit after every green step group.

---

## File Structure

```
phobos/
  build.zig                     # build graph: exe, test step, fuzz step, cross-target option
  build.zig.zon                 # package manifest (name, version, deps: lmdb via system lib)
  src/
    main.zig                    # entry: parse args, load config, build server, run std.Io listener
    io.zig                      # std.Io.Threaded bootstrap, Io handle, accept loop, conn spawn
    json/value.zig              # minimal JSON value + parse/stringify (canonical key order)
    jsonrpc.zig                 # JSON-RPC 2.0 envelope, error codes, dispatch table
    net/http.zig                # HTTP/1.1 request parser + response serializer
    net/ws.zig                  # WebSocket RFC6455 handshake + frame codec
    transport/http.zig          # REST routes + /server/jsonrpc -> jsonrpc
    transport/ws.zig            # /websocket -> jsonrpc; WS-only connection.identify/websocket.id
    server/registry.zig         # component/method registry, lifecycle
    server/notify.zig           # notification bus (FIFO fan-out, bounded queues)
    core/methods.zig            # server.info, server.config payload builders
    config/confighelper.zig     # INI-ish parser behind ConfigBackend interface
    config/backend.zig          # ConfigBackend interface
    store/datastore.zig         # DataStore interface
    store/lmdb_store.zig        # drop-in liblmdb impl
    oracle/normalize.zig        # §8a field-normalization manifest (mask/sort/relativize)
    util/arena.zig              # arena-per-request helper, fixed pools
  conformance/
    capture.py                  # boots stock Moonraker (vendored fixtures), records goldens
    replay.zig                  # drives phobos, asserts normalized-equality vs goldens
    golden/                     # checked-in normalized golden captures
  docs/...                      # already present
```

Each `src/*.zig` carries its own `test { ... }` blocks and a `fuzz_*` test. No separate
`tests/` tree — Zig convention is in-file tests.

---

## Task 0: Project scaffold + cross-target build

**Files:**
- Create: `build.zig`, `build.zig.zon`, `src/main.zig`, `src/util/arena.zig`

- [ ] **Step 1: Write the failing test** — `src/util/arena.zig` with a trivial `requestArena` that resets:

```zig
const std = @import("std");

/// Per-request arena: allocate freely, reset (not free) at end of request.
pub const RequestArena = struct {
    arena: std.heap.ArenaAllocator,
    pub fn init(child: std.mem.Allocator) RequestArena {
        return .{ .arena = std.heap.ArenaAllocator.init(child) };
    }
    pub fn allocator(self: *RequestArena) std.mem.Allocator {
        return self.arena.allocator();
    }
    pub fn reset(self: *RequestArena) void {
        _ = self.arena.reset(.retain_capacity);
    }
    pub fn deinit(self: *RequestArena) void {
        self.arena.deinit();
    }
};

test "request arena reuses capacity across reset" {
    var ra = RequestArena.init(std.testing.allocator);
    defer ra.deinit();
    const a = ra.allocator();
    const buf1 = try a.alloc(u8, 1000);
    @memset(buf1, 1);
    ra.reset();
    const buf2 = try a.alloc(u8, 1000);
    try std.testing.expectEqual(@as(usize, 1000), buf2.len);
}

test "fuzz arena: random alloc/reset cycles never leak or crash" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var ra = RequestArena.init(std.testing.allocator);
            defer ra.deinit();
            var buf: [256]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            for (buf) |b| {
                _ = ra.allocator().alloc(u8, b) catch {};
                if (b % 7 == 0) ra.reset();
            }
        }
    }.run, .{});
}
```

- [ ] **Step 2: Write `build.zig`** — exe + `test` step aggregating all `src` tests + `fuzz` step + a `-Dtarget`/`-Dcpu` passthrough; default native, documented cross invocation:

```zig
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{}); // override: -Dtarget=arm-linux-musleabihf -Dcpu=cortex_a7
    const optimize = b.standardOptimizeOption(.{}); // deploy: -Doptimize=ReleaseSmall
    const with_lmdb = b.option(bool, "with_lmdb", "Link liblmdb") orelse true;

    // Link flags live on the Module in 0.16. Helper builds a module + applies them.
    const mkmod = struct {
        fn f(bb: *std.Build, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, lmdb: bool) *std.Build.Module {
            const m = bb.createModule(.{
                .root_source_file = bb.path("src/main.zig"),
                .target = t, .optimize = o, .link_libc = lmdb,
            });
            if (lmdb) m.linkSystemLibrary("lmdb", .{});
            return m;
        }
    }.f;

    const exe = b.addExecutable(.{ .name = "phobos", .root_module = mkmod(b, target, optimize, with_lmdb) });
    b.installArtifact(exe);

    const unit = b.addTest(.{ .root_module = mkmod(b, target, optimize, with_lmdb) });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(unit).step);

    const fuzz = b.addTest(.{ .root_module = mkmod(b, target, optimize, with_lmdb) });
    const fuzz_run = b.addRunArtifact(fuzz);
    fuzz_run.addArg("--fuzz");
    b.step("fuzz", "Run fuzz harnesses").dependOn(&fuzz_run.step);
}
```

- [ ] **Step 3: `build.zig.zon`** — name `phobos`, version `0.0.0`, minimal.
- [ ] **Step 4: `src/main.zig`** — `pub fn main()` that prints version + imports every module so `zig build test` discovers all in-file tests:

```zig
const std = @import("std");
pub const arena = @import("util/arena.zig");
// (add each module import as tasks land them, so `zig build test` aggregates their tests)
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    std.debug.print("phobos 0.0.0\n", .{});
}
test { std.testing.refAllDecls(@This()); }
```

- [ ] **Step 5: Run** `zig build test` → arena tests PASS. `zig build fuzz -- --fuzz` runs the fuzz smoke. Verify native build: `zig build`.
- [ ] **Step 6: Verify cross-compile** `zig build -Dtarget=arm-linux-musleabihf -Dcpu=cortex_a7 -Doptimize=ReleaseSmall` produces a static ARM binary (`file zig-out/bin/phobos` → "ARM, EABI5 ... statically linked"). *Note:* requires a `liblmdb` for the cross target; if unavailable, gate `linkSystemLibrary("lmdb")` behind a `-Dwith_lmdb` option (default true) and disable for the cross smoke until Task 9.
- [ ] **Step 7: Commit** — `git commit -m "build: scaffold phobos zig project with arena, test and fuzz steps"`

---

## Task 1: Io bootstrap — `std.Io.Threaded` + `std.Io.net` accept loop + serialized core

**Files:** Create `src/io.zig` (Io bootstrap + listener/accept loop + per-conn spawn) and `src/server/core.zig` (the serialized-core mutex wrapper that preserves Moonraker's single-loop ordering). The hand-rolled reactor is GONE — we use the std backend. See the networking cheatsheet above for the validated `std.Io.net` API.

- [ ] **Step 1: Failing test — `Listener` accepts a connection and the handler echoes**

```zig
test "listener accepts and a registered handler echoes a line" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var lst = try Listener.bind(io, "127.0.0.1", 0); // port 0 -> ephemeral
    defer lst.deinit(io);
    const port = lst.port();
    try std.testing.expect(port != 0);

    // serve one connection concurrently, echoing "echo:<line>"
    var fut = io.async(Listener.serveOnce, .{ &lst, io, echoHandler });

    var caddr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var cs = try caddr.connect(io, .{ .mode = .stream });
    defer cs.close(io);
    var wb: [64]u8 = undefined; var w = cs.writer(io, &wb);
    try w.interface.print("hello\n", .{}); try w.interface.flush();
    var rb: [64]u8 = undefined; var r = cs.reader(io, &rb);
    const reply = try r.interface.takeDelimiterExclusive('\n');
    try std.testing.expectEqualStrings("echo:hello", reply);
    fut.await(io);
}
```

- [ ] **Step 2:** Run `zig build test -Dwith_lmdb=false` (or `zig test -target x86_64-linux-musl src/io.zig`) → FAIL.
- [ ] **Step 3: Minimal impl** — `Listener.bind(io, host, port)` wraps `IpAddress.parseIp4 + listen(.{.reuse_address=true})`; `port()` reads the bound port via `getsockname`; `serveOnce(io, handler)` does one `accept` + calls handler with the `Stream`; `serve(io, handler)` loops `accept` and `io.async`-spawns a connection task per accept. `deinit`. Define `echoHandler` as an in-file test helper. **Run/test builds use `-Dwith_lmdb=false`** (no libc needed yet; host glibc link is broken — use musl).
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5: Serialized core** — in `src/server/core.zig`, add `Core` holding a `std.Thread.Mutex` and a monotonic sequence counter. Test that two `io.async` tasks calling `core.run(fn)` are mutually exclusive and that emitted notifications preserve a single total order (enqueue under the lock, drain in FIFO). This is the mechanism that makes thread-pool concurrency observably equal to Moonraker's single loop. Implement until green.
- [ ] **Step 6: Fuzz** — `fuzz_core`: many concurrent `io.async` tasks pushing notifications through `Core`; assert the drained order is a valid serialization (per-producer order preserved, no loss, no data race — run under `-fsanitize` / ThreadSanitizer-style assertions where available, else assert invariants). For `Listener`, a fuzz harness feeds random byte payloads through the echo path asserting no crash.
- [ ] **Step 7: Commit** — `feat: std.Io.net listener with serialized server core`

---

## Task 2: JSON value + JSON-RPC dispatcher

**Files:** Create `src/json/value.zig`, `src/jsonrpc.zig`. Parse via `std.json.parseFromSlice(std.json.Value, alloc, src, .{})`. Serialize via `std.json.Stringify` (`Stringify.valueAlloc(alloc, v, .{})`); `std.json.Value.object` is an `ArrayHashMap` that preserves insertion order, matching Moonraker's dict ordering — verify against goldens, do not sort unless a golden shows sorted. `src/json/value.zig` wraps these with the canonical-order helpers the rest of the code uses.

- [ ] **Step 1: Failing test — unknown method returns -32601**

```zig
test "dispatch unknown method yields method-not-found" {
    var d = Dispatcher.init(std.testing.allocator);
    defer d.deinit();
    const resp = try d.handle("{\"jsonrpc\":\"2.0\",\"method\":\"nope\",\"id\":1}");
    try std.testing.expect(std.mem.indexOf(u8, resp, "-32601") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"id\":1") != null);
}
```

- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3: Minimal impl** — `Dispatcher` with a `StringHashMap(MethodFn)` **runtime table** (per spec §7: table-driven, supports later dynamic `printer.*` registration with no verb-prefix). `handle()` parses the envelope, validates `jsonrpc=="2.0"`, routes by `method`, builds `{"jsonrpc":"2.0","result":...,"id":...}` or an error envelope. Error codes: `-32700` parse, `-32600` invalid request, `-32601` method not found, `-32602` invalid params.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5: Tests for each error code** + a registered echo method returning its params + notification (no `id`) producing **no** response. Implement until green.
- [ ] **Step 6: Fuzz** — `fuzz_jsonrpc`: feed arbitrary bytes to `handle()`; assert it never crashes and always returns either a valid JSON-RPC response or empty (for notifications). This is the top fuzz target — untrusted input.
- [ ] **Step 7: Commit** — `feat: json-rpc 2.0 dispatcher with runtime method table`

---

## Task 3: HTTP/1.1 parser + response serializer

**Files:** Create `src/net/http.zig`. Scope: request line, headers (case-insensitive), `Content-Length` body, keep-alive; response with status, headers, body. Chunked + uploads deferred to later slices (note in code).

- [ ] **Step 1: Failing test — parse a simple POST**

```zig
test "parse POST with content-length" {
    const raw = "POST /server/jsonrpc HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}";
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    const req = try p.parse(raw);
    try std.testing.expectEqualStrings("POST", req.method);
    try std.testing.expectEqualStrings("/server/jsonrpc", req.path);
    try std.testing.expectEqualStrings("{}", req.body);
}
```

- [ ] **Step 2:** Run → FAIL. **Step 3:** Minimal impl (incremental parser tolerant of partial buffers — returns `need_more` when incomplete). **Step 4:** PASS.
- [ ] **Step 5:** Add tests: header case-insensitivity, missing body, malformed request line → error; response serializer round-trip (`{"result":...}` wrapping happens in transport, not here). Implement until green.
- [ ] **Step 6: Fuzz** — `fuzz_http`: random bytes + truncations to `parse()`; never crash, partials return `need_more`, never read past buffer.
- [ ] **Step 7: Commit** — `feat: http/1.1 request parser and response serializer`

---

## Task 3b: Test harness — `TestServer` + HTTP/WS test clients

**Files:** Create `src/testutil/server.zig` (test-only; gated behind `if (builtin.is_test)` or kept in a `testutil` module imported only by tests). Tasks 4 and 6 use `TestServer.start`, `srv.get`, `srv.wsConnect`, `conn.call` — this task builds them so those tests are runnable. Without it the later tests reference undefined infrastructure.

- [ ] **Step 1: Failing test — TestServer boots and accepts a TCP connection**

```zig
test "TestServer starts on an ephemeral port and accepts a connection" {
    var srv = try TestServer.start(std.testing.allocator);
    defer srv.stop();
    var c = try std.net.tcpConnectToAddress(srv.address); // ephemeral port chosen by bind(0)
    defer c.close();
    try std.testing.expect(srv.port() != 0);
}
```

- [ ] **Step 2:** Run → FAIL. **Step 3:** Impl `TestServer`: own a `std.Io.Threaded` instance, bind a `Listener` (Task 1) on `127.0.0.1:0`, run its `serve` loop via `io.async` until `stop()`. Expose `address`/`port()`. Uses the production `std.Io.net` path — not a separate socket impl.
- [ ] **Step 4:** PASS.
- [ ] **Step 5:** Add `srv.get(path) []u8` (minimal blocking HTTP/1.1 client: send request, read response, return body), `srv.wsConnect() WsTestConn` (perform the RFC6455 handshake using `net/ws.acceptKey` logic on the client side), and `WsTestConn.call(method, params_json) -> result_json` (send a JSON-RPC frame, read the matching response frame). These reuse `net/http` and `net/ws` (Tasks 3 + 5) — so **schedule Task 5 (ws codec) before this task's WS client step**, or split: TCP+HTTP client now, WS client added right after Task 5. Keep `TestServer` itself dependency-light.
- [ ] **Step 6: Fuzz** — `fuzz_testclient` is **not required** (test-only helper, not production input surface); note this explicitly to satisfy the per-function rule by exception.
- [ ] **Step 7: Commit** — `test: TestServer and http/ws test clients for conformance-style tests`

---

## Task 4: HTTP transport + minimal `server.info`/`server.config` + server registry + auth hook

**Files:** Create `src/transport/http.zig`, `src/server/registry.zig`, `src/core/methods.zig`. Wire `Listener` (std.Io.net) → http parser → dispatcher, executing handlers under the serialized `Core`.

- [ ] **Step 1: Failing test — REST `GET /server/info` returns wrapped result with `api_version_string`**

```zig
test "GET /server/info returns wrapped result envelope" {
    var srv = try TestServer.start(std.testing.allocator); // boots std.Io listener+http on an ephemeral port
    defer srv.stop();
    const body = try srv.get("/server/info");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"api_version_string\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"klippy_connected\":false") != null);
}
```

- [ ] **Step 2:** FAIL. **Step 3:** Impl: registry maps endpoint path → APIDefinition (method-name derivation `/`→`.`, verb-prefix for multi-verb, per spec §7); HTTP transport wraps results as `{"result": ...}` except `wrap_result=false`; `core/methods.zig` builds the **full** `server.info` payload (all keys from spec §7) in the **disconnected** state (`klippy_connected:false`, `klippy_state:"disconnected"`, `missing_klippy_requirements:[]`, `api_version_string:"1.5.0"`, `software_version` from a build option so the oracle can pin it). **Step 4:** PASS.
- [ ] **Step 5: `raw` param** — add a test that `server.info` with `{"raw": true}` formats `warnings` with literal newlines and with `{"raw": false}` (default) substitutes `<br/>` (match `server.py::_handle_info_request`). Implement the `raw` branch in `core/methods.zig`. The normalize layer (Task 10) compares this branch; the behavior must exist here first.
- [ ] **Step 6: Transport-aware auth hook (spec §7, review M1)** — add a test that the dispatcher invokes an auth hook receiving the `transport_type`, and that `transport_type == .internal` **bypasses** auth while `.http`/`.websocket` invoke it. Impl a hook interface (a function pointer on the dispatcher) defaulting to allow-all for the spine, but with the INTERNAL short-circuit and the `auth_required` flag plumbed per APIDefinition (`/access/*`, `/server/connection/identify`, `/server/zeroconf/ssdp` = `false`). The auth *chain* itself is the later `authorization` slice; this only reserves the correctly-shaped hook so that slice is additive.
- [ ] **Step 7:** Add `/server/config` (echo loaded config tree, paths relativized later by normalize), `/server/jsonrpc` POST path hitting the same dispatcher, and error-envelope parity tests. Implement until green.
- [ ] **Step 8: Fuzz** — `fuzz_http_transport`: random request bytes into the transport; assert always a well-formed HTTP response, never a crash/hang.
- [ ] **Step 9: Commit** — `feat: http transport, registry, core server.info/config, transport-aware auth hook`

---

## Task 5: WebSocket framing + handshake

**Files:** Create `src/net/ws.zig`. RFC6455: `Sec-WebSocket-Accept` handshake, frame parse/build (FIN, opcode, mask, payload len 7/16/64), close/ping/pong, client→server frames are masked.

- [ ] **Step 1: Failing test — accept-key derivation**

```zig
test "sec-websocket-accept matches RFC6455 example" {
    const got = try acceptKey(std.testing.allocator, "dGhlIHNhbXBsZSBub25jZQ==");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", got);
}
```

- [ ] **Step 2:** FAIL. **Step 3:** Impl `acceptKey` (SHA1 of key+GUID, base64) + frame codec. **Step 4:** PASS.
- [ ] **Step 5:** Tests: parse a masked client text frame → unmasked payload; build a server text frame (unmasked); fragmented frames; close frame with code. Implement until green.
- [ ] **Step 6: Fuzz** — `fuzz_ws`: random bytes to the frame parser; never crash, reject invalid lengths, never read past buffer.
- [ ] **Step 7: Commit** — `feat: websocket rfc6455 handshake and frame codec`

---

## Task 6: WS transport + connection ids (`connection.identify`, `websocket.id`)

**Files:** Create `src/transport/ws.zig`. WS connections get a stable monotonic integer id (per spec §8a: shape, not Python's `id(self)`). These two methods are **WS-only**, `auth_required=false`, need the live connection handle.

- [ ] **Step 1: Failing test — identify returns a monotonic int connection_id**

```zig
test "two ws connections get distinct monotonic connection ids" {
    var srv = try TestServer.start(std.testing.allocator);
    defer srv.stop();
    var c1 = try srv.wsConnect(); defer c1.close();
    var c2 = try srv.wsConnect(); defer c2.close();
    const id1 = try c1.call("server.connection.identify", "{\"client_name\":\"a\",\"version\":\"1\",\"type\":\"web\",\"url\":\"x\"}");
    const id2 = try c2.call("server.connection.identify", "{\"client_name\":\"b\",\"version\":\"1\",\"type\":\"web\",\"url\":\"x\"}");
    try std.testing.expect(id2 > id1); // monotonic
}
```

- [ ] **Step 2:** FAIL. **Step 3:** Impl WS transport over the `std.Io.net` `Stream` + ws codec; per-connection struct holds a `u64` id from a monotonic counter (assigned under `Core`); register `server.connection.identify`/`server.websocket.id` in the dispatcher bound to the connection. **Step 4:** PASS.
- [ ] **Step 5:** Test that the same JSON-RPC dispatcher serves WS (call `server.info` over WS, assert same payload as HTTP) — proves transport convergence. Implement until green.
- [ ] **Step 6: Fuzz** — `fuzz_ws_transport`: random frame/payload sequences; never crash.
- [ ] **Step 7: Commit** — `feat: websocket transport with monotonic connection ids`

---

## Task 7: Config parser (confighelper subset, behind ConfigBackend)

**Files:** Create `src/config/backend.zig` (interface), `src/config/confighelper.zig`. Match confighelper: `[section]`, `key: value` / `key = value`, `#`/`;` comments, multiline (indented continuation), `getint/getfloat/getboolean` coercion, `[include glob]`. Validate coercion edge cases against the Python `tests/test_config.py` getter matrix (the one upstream area with real assertions).

- [ ] **Step 1: Failing test — section/key/type coercion**

```zig
test "parse sections and coerce types" {
    const src = "[server]\nhost: 0.0.0.0\nport = 7125\nenabled: true\n";
    var cfg = try Config.parse(std.testing.allocator, src);
    defer cfg.deinit();
    try std.testing.expectEqualStrings("0.0.0.0", cfg.get("server", "host").?);
    try std.testing.expectEqual(@as(i64, 7125), try cfg.getInt("server", "port"));
    try std.testing.expectEqual(true, try cfg.getBool("server", "enabled"));
}
```

- [ ] **Step 2:** FAIL. **Step 3:** Minimal parser + `ConfigBackend` vtable. **Step 4:** PASS.
- [ ] **Step 5:** Port the behaviors covered by `vendor/moonraker/tests/test_config.py` (comment stripping, defaults, bad-int error, include resolution) as Zig tests; implement until green. Cross-check error messages where they are observable via the API.
- [ ] **Step 6: Fuzz** — `fuzz_config`: random bytes; never crash, malformed → typed error not panic.
- [ ] **Step 7: Commit** — `feat: confighelper-compatible config parser behind ConfigBackend`

---

## Task 8: Notification bus + one `notify_*`

**Files:** Create `src/server/notify.zig`. FIFO fan-out to all subscribed WS connections, bounded per-connection queue, ordering preserved (contract). Emission goes through the serialized `Core` (Task 1) so the total order is deterministic. Emit one notification to prove framing/ordering.

- [ ] **Step 1: Failing test — subscribers receive notifications in emit order**

```zig
test "notifications delivered in FIFO emit order" {
    const alloc = std.testing.allocator;
    var core = Core.init();            // serialized core from Task 1 (mutex + seq)
    var bus = NotifyBus.init(alloc, &core);
    defer bus.deinit();
    var sink = TestSink.init(alloc);   // records JSON frames it receives
    defer sink.deinit();
    try bus.subscribe(sink.conn());
    try bus.emit("notify_a", "[1]");
    try bus.emit("notify_b", "[2]");
    bus.drain();                        // deliver queued notifications in FIFO
    try std.testing.expectEqual(@as(usize, 2), sink.frames.items.len);
    try std.testing.expect(std.mem.indexOf(u8, sink.frames.items[0], "notify_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.frames.items[1], "notify_b") != null);
}
```

- [ ] **Step 2:** FAIL. **Step 3:** Impl bus: `subscribe(conn)`, `emit(method, params)` enqueues a JSON-RPC notification (no `id`) per subscriber **under the `Core` lock** (preserves FIFO total order), `drain()` writes queued frames to each subscriber's `Stream`. Define `TestSink` in-file. **Step 4:** PASS.
- [ ] **Step 5:** Test bounded-queue backpressure (full queue → drop/close matching Moonraker) and exact wire shape `{"jsonrpc":"2.0","method":"notify_...","params":[...]}`. Implement until green.
- [ ] **Step 6: Fuzz** — `fuzz_notify`: random emit/subscribe/unsubscribe interleavings; never crash, never reorder.
- [ ] **Step 7: Commit** — `feat: notification bus with FIFO fan-out`

---

## Task 9: Drop-in liblmdb DataStore (read path)

**Files:** Create `src/store/datastore.zig` (interface), `src/store/lmdb_store.zig`. Spine needs only read access to bootstrap config-adjacent state (full `server.database.*` is a later slice). Link liblmdb; open the existing env read-only; namespaced get/list.

- [ ] **Step 1: Failing test — open vendored asset db and read a known namespace key** (use `vendor/moonraker/tests/assets` lmdb seed; copy into a temp dir in the test).
- [ ] **Step 2:** FAIL. **Step 3:** Impl `LmdbStore` over `mdb_env_open`/`mdb_txn_begin`/`mdb_get` (read-only), `DataStore` vtable. **Step 4:** PASS.
- [ ] **Step 5:** Test missing-key and missing-namespace semantics match Moonraker (returns null vs error). Implement until green. Now re-enable `linkSystemLibrary("lmdb")` for the cross target (Task 0 Step 6) or document the cross-lmdb build.
- [ ] **Step 6: Fuzz** — `fuzz_datastore`: random keys/namespaces against the open env; never crash.
- [ ] **Step 7: Commit** — `feat: drop-in liblmdb datastore read path`

---

## Task 10: Field-normalization layer (oracle manifest §8a)

**Files:** Create `src/oracle/normalize.zig`. Implements the spec §8a manifest: mask `connection_id`/`websocket_id`/identity ids, version-pin `moonraker_version`, sort `components`/`failed_components`, path-relativize `registered_directories` and config paths, structural-compare `warnings`. This is **spine code with its own tests** (per §8a), reused by the replay harness.

- [ ] **Step 1: Failing test — normalize masks connection_id and sorts components**

```zig
test "normalize masks volatile fields per manifest" {
    const a = "{\"connection_id\":123,\"components\":[\"b\",\"a\"]}";
    const b = "{\"connection_id\":999,\"components\":[\"a\",\"b\"]}";
    try std.testing.expect(try normalizedEqual(std.testing.allocator, a, b));
}
```

- [ ] **Step 2:** FAIL. **Step 3:** Impl `normalize(value, method)` applying per-field rules from a manifest table, and `normalizedEqual(a,b)`. **Step 4:** PASS.
- [ ] **Step 5:** One test per manifest row (version-pin, paths, warnings `raw` branch). Implement until green.
- [ ] **Step 6: Fuzz** — `fuzz_normalize`: random JSON pairs; never crash; `normalizedEqual(x,x)` always true.
- [ ] **Step 7: Commit** — `feat: oracle field-normalization layer per spec manifest`

---

## Task 11: Conformance oracle (golden capture + replay)

**Files:** Create `conformance/capture.py`, `conformance/replay.zig`, `conformance/golden/`.

- [ ] **Step 1:** `capture.py` — boot stock Moonraker **without Klippy** using the documented bring-up (`uv run --with pytest --with 'pytest-asyncio==0.21.2' --with 'pytest-timeout>=2.1.0' --with lmdb` + the vendor `conftest.py`) and the vendored `HttpClient`/`WebsocketClient` fixtures; record responses + notification stream for a scripted sequence (`server.info` over REST + `/server/jsonrpc` + WS; `server.config`; `server.connection.identify` over WS; one notification). Write normalized goldens to `conformance/golden/`.
- [ ] **Step 2:** Run capture once; commit goldens (`git add conformance/golden`).
- [ ] **Step 3:** `replay.zig` — boot phobos with the same config/datadir, replay the identical sequence, assert `normalizedEqual` (Task 10) against each golden and the ordered notification stream. Wire as `zig build oracle`.
- [ ] **Step 4:** Run `zig build oracle` → PASS (this is the parity gate).
- [ ] **Step 5:** Add a CI note: `zig build test && zig build oracle` is the green bar. No fuzz needed here (it is itself a test harness), but `capture.py` gets a smoke test that it produces non-empty goldens.
- [ ] **Step 6: Commit** — `test: conformance oracle with golden capture and replay`

---

## Task 12: Cross-target size/memory verification

**Files:** none (verification + a `docs/` note).

- [ ] **Step 1:** Build deploy binary: `zig build -Dtarget=arm-linux-musleabihf -Dcpu=cortex_a7 -Doptimize=ReleaseSmall`. Record `size zig-out/bin/phobos` and `file` output.
- [ ] **Step 2:** Run phobos natively under `/usr/bin/time -v` (or valgrind massif) through the oracle sequence; record peak RSS. Compare against stock Moonraker peak RSS for the same sequence (capture both numbers).
- [ ] **Step 3:** Write `docs/MEMORY_BASELINE.md` with binary size, peak RSS phobos vs Moonraker, and the measurement method. This is the memory-efficiency evidence the project exists for.
- [ ] **Step 4: Commit** — `docs: record memory baseline vs stock moonraker`

---

## Definition of done (spine slice)

- `zig build test` green (every function has unit + fuzz tests).
- `zig build oracle` green: `server.info` (full disconnected payload), `server.config`, WS `server.connection.identify`, and one notification are **normalized-equal** to stock Moonraker.
- Static `arm-linux-musleabihf cortex_a7` binary builds.
- `docs/MEMORY_BASELINE.md` shows phobos peak RSS below stock Moonraker for the spine sequence.
- All transports (HTTP REST, `/server/jsonrpc`, `/websocket`) resolve through the one JSON-RPC dispatcher.

Out of scope (later slices, each its own spec→plan): components (file_manager, update_manager, power, history, machine, mqtt, authorization logic), Klippy connection proxying, MQTT transport, DataStore write path + native-store decision.
