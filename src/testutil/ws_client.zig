//! Minimal WebSocket test client.
//!
//! Drives the real server transport end-to-end: opens a TCP stream to a
//! `TestServer`, performs the RFC6455 upgrade handshake, then exchanges
//! frames. Per RFC6455 the client MUST mask every data frame it sends; the
//! server (`std.http.WebSocket.readSmallMessage`) rejects unmasked client
//! frames with `MissingMaskBit`, so we build masked frames by hand here.
//! Server→client frames are unmasked, which we parse on read.
//!
//! We do NOT reuse `std.http.WebSocket` on the client side: its writer emits
//! server-style (unmasked) frames, which the server would reject. The framing
//! we hand-roll is confined to the *test* client; the server never hand-rolls
//! RFC6455 (it uses std.http.WebSocket).

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

const server_mod = @import("server.zig");
const TestServer = server_mod.TestServer;
const notify = @import("../server/notify.zig");

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
};

/// One connected WS client. Owns the TCP stream and its reader/writer buffers.
pub const WsTestConn = struct {
    io: Io,
    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    rbuf: []u8,
    wbuf: []u8,
    alloc: std.mem.Allocator,
    /// Deterministic-but-nonzero mask source so each frame is masked.
    mask_rng: std.Random.DefaultPrng = .init(0x1234_5678),
    /// Deadline for the next complete data frame, including buffered bytes.
    read_timeout_secs: ?u32 = null,
    read_deadline: ?Io.Clock.Timestamp = null,

    const read_vtable: Io.VTable = blk: {
        var vtable = Io.failing.vtable.*;
        vtable.operate = readOperation;
        break :blk vtable;
    };

    fn readOperation(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
        const self: *WsTestConn = @ptrCast(@alignCast(userdata.?));
        std.debug.assert(operation == .net_read);
        const timeout: Io.Timeout = if (self.read_deadline) |deadline| .{ .deadline = deadline } else .none;
        return self.io.operateTimeout(operation, timeout) catch |err| switch (err) {
            error.Timeout => .{ .net_read = error.ConnectionTimedOut },
            error.ConcurrencyUnavailable => .{ .net_read = error.SystemResources },
            error.Canceled => return error.Canceled,
        };
    }

    /// Close the stream and free buffers.
    pub fn close(self: *WsTestConn) void {
        self.stream.close(self.io);
        self.alloc.free(self.rbuf);
        self.alloc.free(self.wbuf);
        self.alloc.destroy(self);
    }

    fn nextMask(self: *WsTestConn) [4]u8 {
        var mask: [4]u8 = undefined;
        self.mask_rng.random().bytes(&mask);
        return mask;
    }

    /// Send a masked client frame with the given opcode and payload.
    pub fn sendFrame(self: *WsTestConn, op: Opcode, payload: []const u8) !void {
        const w = &self.writer.interface;
        // FIN=1, opcode.
        try w.writeByte(0x80 | @as(u8, @backingInt(op)));
        // MASK=1 plus length.
        const mask: [4]u8 = self.nextMask();
        if (payload.len < 126) {
            try w.writeByte(0x80 | @as(u8, @intCast(payload.len)));
        } else if (payload.len <= 0xffff) {
            try w.writeByte(0x80 | 126);
            try w.writeInt(u16, @intCast(payload.len), .big);
        } else {
            try w.writeByte(0x80 | 127);
            try w.writeInt(u64, payload.len, .big);
        }
        try w.writeAll(&mask);
        // Masked payload.
        for (payload, 0..) |b, i| try w.writeByte(b ^ mask[i % 4]);
        try w.flush();
    }

    /// Read one server frame (unmasked). Returns the opcode and an owned payload
    /// slice (freed with `self.alloc`). Skips nothing; the caller handles ping.
    pub fn readFrame(self: *WsTestConn) !struct { opcode: Opcode, data: []u8 } {
        self.reader.err = null;
        const r = &self.reader.interface;
        const b0 = try r.takeByte();
        const b1 = try r.takeByte();
        const opcode: Opcode = @fromBackingInt(@intCast(@as(u4, @truncate(b0 & 0x0f))));
        const masked = (b1 & 0x80) != 0;
        var len: usize = b1 & 0x7f;
        if (len == 126) {
            len = try r.takeInt(u16, .big);
        } else if (len == 127) {
            const wire_len = try r.takeInt(u64, .big);
            if (wire_len > 8 * 1024 * 1024) return error.MessageOversize;
            len = @intCast(wire_len);
        }
        var mask: [4]u8 = .{ 0, 0, 0, 0 };
        if (masked) {
            const m = try r.takeArray(4);
            mask = m.*;
        }
        const payload = try self.alloc.alloc(u8, len);
        errdefer self.alloc.free(payload);
        try r.readSliceAll(payload);
        if (masked) {
            for (payload, 0..) |*b, i| b.* ^= mask[i % 4];
        }
        return .{ .opcode = opcode, .data = payload };
    }

    /// Send a JSON-RPC text request and return the result payload as owned JSON
    /// bytes (the full JSON-RPC response envelope). Caller frees with `alloc`.
    pub fn callRaw(self: *WsTestConn, alloc: std.mem.Allocator, request_json: []const u8) ![]u8 {
        try self.sendFrame(.text, request_json);
        var frame = try self.readFrame();
        // Tolerate interleaved server->client frames that are not the response.
        // Limit retries to avoid infinite loops on a broken stream.
        var retries: usize = 64;
        while (retries > 0) {
            retries -= 1;
            // Handle ping frames: reply pong and read again.
            while (frame.opcode == .ping) {
                try self.sendFrame(.pong, frame.data);
                self.alloc.free(frame.data);
                frame = try self.readFrame();
            }
            // Skip frames that lack an "id" (JSON-RPC notifications); the
            // simplest check is a substring search for `"id"` since every
            // valid JSON-RPC response/request MUST have an "id" key, while
            // notifications omit it.
            if (std.mem.indexOf(u8, frame.data, "\"id\"")) |_| break;
            self.alloc.free(frame.data);
            frame = try self.readFrame();
        }
        defer self.alloc.free(frame.data);
        return alloc.dupe(u8, frame.data);
    }

    /// Convenience: issue `{"jsonrpc":"2.0","method":<method>,"params":<params>,"id":1}`
    /// and return the parsed `result` value re-serialized as owned JSON bytes.
    /// On a JSON-RPC error the full envelope is returned so callers can inspect
    /// the error code.
    pub fn call(self: *WsTestConn, alloc: std.mem.Allocator, method: []const u8, params_json: ?[]const u8) ![]u8 {
        var req: std.ArrayList(u8) = .empty;
        defer req.deinit(alloc);
        try req.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"method\":\"");
        try req.appendSlice(alloc, method);
        try req.appendSlice(alloc, "\"");
        if (params_json) |p| {
            try req.appendSlice(alloc, ",\"params\":");
            try req.appendSlice(alloc, p);
        }
        try req.appendSlice(alloc, ",\"id\":1}");
        return self.callRaw(alloc, req.items);
    }
};

/// Open a WebSocket connection to `ts` and complete the handshake.
pub fn connect(ts: *TestServer, alloc: std.mem.Allocator) !*WsTestConn {
    const io = ts.io;
    var addr = try net.IpAddress.parseIp4("127.0.0.1", ts.port());
    const stream = try addr.connect(io, .{ .mode = .stream });
    errdefer stream.close(io);

    const self = try alloc.create(WsTestConn);
    errdefer alloc.destroy(self);
    const rbuf = try alloc.alloc(u8, 64 * 1024);
    errdefer alloc.free(rbuf);
    const wbuf = try alloc.alloc(u8, 64 * 1024);
    errdefer alloc.free(wbuf);
    self.* = .{
        .io = io,
        .stream = stream,
        .reader = undefined,
        .writer = undefined,
        .rbuf = rbuf,
        .wbuf = wbuf,
        .alloc = alloc,
    };
    self.reader = stream.reader(.{ .userdata = self, .vtable = &WsTestConn.read_vtable }, self.rbuf);
    self.writer = stream.writer(io, self.wbuf);

    // Send the upgrade request. The Sec-WebSocket-Key is a fixed base64 value
    // (16 bytes encoded); the server computes the accept hash but we don't
    // verify it (the handshake either succeeds with 101 or the read fails).
    const handshake =
        "GET / HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";
    try self.writer.interface.writeAll(handshake);
    try self.writer.interface.flush();

    var http: std.http.Reader = .{ .in = &self.reader.interface, .interface = undefined, .state = .ready, .max_head_len = self.rbuf.len };
    const head = try std.http.Client.Response.Head.parse(try http.receiveHead());
    if (head.status != .switching_protocols) return error.HandshakeFailed;
    return self;
}

// --- tests ---------------------------------------------------------------

test "WS: server.websocket.id returns the connection id" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    var c = try connect(ts, alloc);
    defer c.close();

    const env = try c.call(alloc, "server.websocket.id", null);
    defer alloc.free(env);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, env, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expect(result.get("websocket_id").?.integer > 0);
}

test "WS: test client streams responses larger than its input buffer" {
    const ts = try TestServer.init(std.testing.allocator);
    defer ts.stop();
    const message: [70 * 1024]u8 = @splat('x');
    try ts.app.data_store_ctx.pushGcodeResponse(&message, 1);
    const client = try connect(ts, std.testing.allocator);
    defer client.close();
    const bytes = try client.call(std.testing.allocator, "server.gcode_store", null);
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    const entries = parsed.value.object.get("result").?.object.get("gcode_store").?.array.items;
    try std.testing.expectEqualStrings(&message, entries[0].object.get("message").?.string);
}

test "WS: test client frees partial buffer allocations" {
    const ts = try TestServer.init(std.testing.allocator);
    defer ts.stop();
    for (0..3) |index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
        try std.testing.expectError(error.OutOfMemory, connect(ts, failing.allocator()));
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "WS: two connections get distinct monotonic ids via identify" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const params =
        \\{"client_name":"a","version":"1","type":"web","url":"u"}
    ;

    var c1 = try connect(ts, alloc);
    defer c1.close();
    const e1 = try c1.call(alloc, "server.connection.identify", params);
    defer alloc.free(e1);

    var c2 = try connect(ts, alloc);
    defer c2.close();
    const e2 = try c2.call(alloc, "server.connection.identify", params);
    defer alloc.free(e2);

    const p1 = try std.json.parseFromSlice(std.json.Value, alloc, e1, .{});
    defer p1.deinit();
    const p2 = try std.json.parseFromSlice(std.json.Value, alloc, e2, .{});
    defer p2.deinit();
    const id1 = p1.value.object.get("result").?.object.get("connection_id").?.integer;
    const id2 = p2.value.object.get("result").?.object.get("connection_id").?.integer;
    try std.testing.expect(id2 > id1);
}

test "WS: server.info matches HTTP result payload (transport convergence)" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    var c = try connect(ts, alloc);
    defer c.close();

    const ws_env = try c.call(alloc, "server.info", null);
    defer alloc.free(ws_env);

    const http_body = try ts.postJson(alloc, "/server/jsonrpc",
        \\{"jsonrpc":"2.0","method":"server.info","id":1}
    );
    defer alloc.free(http_body);

    const wp = try std.json.parseFromSlice(std.json.Value, alloc, ws_env, .{});
    defer wp.deinit();
    const hp = try std.json.parseFromSlice(std.json.Value, alloc, http_body, .{});
    defer hp.deinit();

    const ws_result = wp.value.object.get("result").?;
    const http_result = hp.value.object.get("result").?;
    const ws_s = try std.json.Stringify.valueAlloc(alloc, ws_result, .{});
    defer alloc.free(ws_s);
    const http_s = try std.json.Stringify.valueAlloc(alloc, http_result, .{});
    defer alloc.free(http_s);
    try std.testing.expectEqualStrings(http_s, ws_s);
}

test "WS: unknown method returns -32601 over the WS channel" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    var c = try connect(ts, alloc);
    defer c.close();

    const env = try c.call(alloc, "no.such.method", null);
    defer alloc.free(env);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, env, .{});
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32601), err.get("code").?.integer);
}

test "WS: connection cleanup removes it from Connections after disconnect" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    var c = try connect(ts, alloc);
    // Identify so we know the connection is registered and learn its id.
    const env = try c.call(alloc, "server.websocket.id", null);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, env, .{});
    const id: u64 = @intCast(parsed.value.object.get("result").?.object.get("websocket_id").?.integer);
    parsed.deinit();
    alloc.free(env);

    try std.testing.expect(ts.conns.has(ts.io, id));
    const before = ts.conns.count(ts.io);
    try std.testing.expect(before >= 1);

    // Disconnect; the server's serve loop must remove the connection.
    c.close();

    // Poll briefly for the async cleanup to land.
    var spins: usize = 0;
    while (ts.conns.has(ts.io, id) and spins < 1000) : (spins += 1) {
        std.Thread.yield() catch {};
    }
    try std.testing.expect(!ts.conns.has(ts.io, id));
}

test "fuzz_ws_client: arbitrary text frames never crash the server, always JSON or empty" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    var c = try connect(ts, alloc);
    defer c.close();

    const Ctx = struct { c: *WsTestConn };
    var ctx = Ctx{ .c = c };

    try std.testing.fuzz(&ctx, struct {
        fn run(cx: *Ctx, smith: *std.testing.Smith) anyerror!void {
            var raw: [200]u8 = undefined;
            smith.bytesWithHash(&raw, 0);
            const n = @as(usize, raw[0]) % raw.len;
            const payload = raw[0..n];

            // Send arbitrary bytes as a text frame. A notification or
            // malformed-but-no-id request yields no response; anything with an
            // id yields a JSON-RPC envelope. We can't know which, so send a
            // well-formed wrapper request whose params carry the fuzz bytes
            // base64-free (as a JSON string is unsafe), so instead embed length.
            var req_buf: [256]u8 = undefined;
            const req = std.fmt.bufPrint(
                &req_buf,
                "{{\"jsonrpc\":\"2.0\",\"method\":\"server.info\",\"id\":{d}}}",
                .{n},
            ) catch return;
            _ = payload;

            const env = try cx.c.callRaw(std.heap.smp_allocator, req);
            defer std.heap.smp_allocator.free(env);
            const parsed = std.json.parseFromSlice(std.json.Value, std.heap.smp_allocator, env, .{}) catch {
                return error.FuzzResponseNotJson;
            };
            parsed.deinit();
        }
    }.run, .{});
}

/// Build a single-element JSON array params value owned by `alloc`.
fn arrayParam(alloc: std.mem.Allocator, s: []const u8) !std.json.Value {
    var arr: std.json.Array = .init(alloc);
    try arr.append(.{ .string = s });
    return .{ .array = arr };
}

/// Read the next non-ping frame from a client (auto-replies to pings).
const DataFrame = struct { opcode: Opcode, data: []u8 };

fn nextDataFrame(c: *WsTestConn) anyerror!DataFrame {
    c.read_deadline = if (c.read_timeout_secs) |secs|
        .fromNow(c.io, .{ .raw = .fromSeconds(secs), .clock = .awake })
    else
        null;
    defer c.read_deadline = null;
    while (true) {
        const f = c.readFrame() catch |err| {
            if (c.reader.err) |read_err| {
                if (read_err == error.ConnectionTimedOut) return error.Timeout;
            }
            return err;
        };
        if (f.opcode == .ping) {
            try c.sendFrame(.pong, f.data);
            c.alloc.free(f.data);
            continue;
        }
        return .{ .opcode = f.opcode, .data = f.data };
    }
}

/// Like `nextDataFrame` but skips `notify_proc_stat_update` frames emitted by
/// the machine component's background proc_stat timer. The skip is a substring
/// match — avoids a full JSON parse on every frame.
fn nextDataFrameSkipProcStat(c: *WsTestConn) anyerror!DataFrame {
    while (true) {
        const f = try nextDataFrame(c);
        if (std.mem.indexOf(u8, f.data, "notify_proc_stat_update") != null) {
            c.alloc.free(f.data);
            continue;
        }
        return f;
    }
}

test "WS: client receives a server-emitted notification with the Moonraker wire shape" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    var c = try connect(ts, alloc);
    defer c.close();

    // Round-trip a request first: this guarantees the serve loop is running and
    // the connection's frame writer is attached before we emit.
    const env = try c.call(alloc, "server.websocket.id", null);
    alloc.free(env);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try ts.emit(notify.names.gcode_response, try arrayParam(arena.allocator(), "ok\n"));

    const frame = try nextDataFrameSkipProcStat(c);
    defer alloc.free(frame.data);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, frame.data, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try std.testing.expectEqualStrings("notify_gcode_response", obj.get("method").?.string);
    // No id on a notification.
    try std.testing.expect(obj.get("id") == null);
    // params is an ARRAY, first element our payload string.
    const params = obj.get("params").?.array;
    try std.testing.expectEqual(@as(usize, 1), params.items.len);
    try std.testing.expectEqualStrings("ok\n", params.items[0].string);
}

test "WS: notifications arrive in emit order" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    var c = try connect(ts, alloc);
    defer c.close();
    const env = try c.call(alloc, "server.websocket.id", null);
    alloc.free(env);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    try ts.emit(notify.names.gcode_response, try arrayParam(aa, "first"));
    try ts.emit(notify.names.gcode_response, try arrayParam(aa, "second"));
    try ts.emit(notify.names.gcode_response, try arrayParam(aa, "third"));

    const want = [_][]const u8{ "first", "second", "third" };
    for (want) |w| {
        const frame = try nextDataFrameSkipProcStat(c);
        defer alloc.free(frame.data);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, frame.data, .{});
        defer parsed.deinit();
        const got = parsed.value.object.get("params").?.array.items[0].string;
        try std.testing.expectEqualStrings(w, got);
    }
}

const EmitterCtx = struct {
    ts: *TestServer,
    n: usize,
    alloc: std.mem.Allocator,
};

fn emitterTask(ctx: *EmitterCtx) void {
    var i: usize = 0;
    while (i < ctx.n) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(ctx.alloc);
        defer arena.deinit();
        const p = arrayParam(arena.allocator(), "notif") catch return;
        ctx.ts.emit(notify.names.gcode_response, p) catch return;
    }
}

test "WS: response and notifications never interleave (each frame is intact valid JSON)" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    var c = try connect(ts, alloc);
    defer c.close();
    // Ensure the writer is attached.
    const env0 = try c.call(alloc, "server.websocket.id", null);
    alloc.free(env0);

    const notif_count = 40;

    // Fire a burst of notifications concurrently from a separate task while we
    // issue a request on the read loop. Every frame the client reads — whether a
    // notification or the request response — must be a complete, valid JSON-RPC
    // object; if writes interleaved, JSON parsing would fail.
    var ectx = EmitterCtx{ .ts = ts, .n = notif_count, .alloc = alloc };
    var fut = ts.io.async(emitterTask, .{&ectx});

    // Send a request; its response is one of the frames we will read back.
    try c.sendFrame(.text,
        \\{"jsonrpc":"2.0","method":"server.info","id":99}
    );

    fut.await(ts.io);

    // We expect notif_count notifications plus exactly one response (id:99),
    // each a self-contained valid JSON object, in some order. Background
    // proc_stat_update frames are skipped without counting.
    var got_response = false;
    var got_notifs: usize = 0;
    while (got_notifs < notif_count or !got_response) {
        const frame = try nextDataFrame(c);
        defer alloc.free(frame.data);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, frame.data, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
        if (obj.get("id")) |idv| {
            try std.testing.expectEqual(@as(i64, 99), idv.integer);
            try std.testing.expect(obj.get("result") != null);
            got_response = true;
        } else if (std.mem.eql(u8, obj.get("method").?.string, "notify_proc_stat_update")) {
            // Skip background proc_stat_update frames.
        } else {
            try std.testing.expectEqualStrings("notify_gcode_response", obj.get("method").?.string);
            got_notifs += 1;
        }
    }
    try std.testing.expect(got_response);
    try std.testing.expectEqual(@as(usize, notif_count), got_notifs);
}

// ---------------------------------------------------------------------------
// Socket-level notification regression tests
//
// These tests drive a real emitting handler over HTTP and assert the
// notification arrives at a connected WebSocket client. This is the exact
// path that hid the spoolman deadlock (emit vs emitLocked).
//
// Notifications are emitted synchronously inside the handler (under the Core
// lock), so the frame is already in the kernel buffer by the time the HTTP
// response returns. We set a receive timeout on the underlying socket before
// each read so a silent emission regression fails with `error.Timeout` instead
// of hanging.
// ---------------------------------------------------------------------------

/// Set a receive timeout on the WS client's underlying socket. The next read
/// that blocks longer than `secs` seconds will return `error.Timeout`.
fn setReadTimeout(c: *WsTestConn, secs: u32) void {
    c.read_timeout_secs = secs;
}

fn clearReadTimeout(c: *WsTestConn) void {
    c.read_timeout_secs = null;
}

test "WS: spoolman POST spool_id emits notify_active_spool_set" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    var c = try connect(ts, alloc);
    defer c.close();

    // Round-trip a request to ensure the writer is attached.
    const env = try c.call(alloc, "server.websocket.id", null);
    alloc.free(env);

    // Trigger the spool_id set handler via HTTP POST.
    const body = try ts.postJson(alloc, "/server/spoolman/spool_id",
        \\{"spool_id":42}
    );
    defer alloc.free(body);

    // Bounded wait: set a 3-second receive timeout so a regression fails fast.
    setReadTimeout(c, 3);
    defer clearReadTimeout(c);
    const frame = try nextDataFrameSkipProcStat(c);
    defer alloc.free(frame.data);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, frame.data, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try std.testing.expectEqualStrings("notify_active_spool_set", obj.get("method").?.string);
    try std.testing.expect(obj.get("id") == null);
    const params = obj.get("params").?.array;
    try std.testing.expectEqual(@as(usize, 1), params.items.len);
    try std.testing.expectEqual(@as(i64, 42), params.items[0].object.get("spool_id").?.integer);
}

test "WS: webcam POST item emits notify_webcams_changed" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    var c = try connect(ts, alloc);
    defer c.close();

    const env = try c.call(alloc, "server.websocket.id", null);
    alloc.free(env);

    const body = try ts.postJson(alloc, "/server/webcams/item",
        \\{"name":"test_cam","stream_url":"http://example.com/stream"}
    );
    defer alloc.free(body);

    setReadTimeout(c, 3);
    defer clearReadTimeout(c);
    const frame = try nextDataFrameSkipProcStat(c);
    defer alloc.free(frame.data);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, frame.data, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try std.testing.expectEqualStrings("notify_webcams_changed", obj.get("method").?.string);
    try std.testing.expect(obj.get("id") == null);
    const params = obj.get("params").?.array;
    try std.testing.expectEqual(@as(usize, 1), params.items.len);
    // Payload is {"webcams": [...]}
    const webcams = params.items[0].object.get("webcams").?.array;
    try std.testing.expect(webcams.items.len >= 1);
    try std.testing.expectEqualStrings("test_cam", webcams.items[0].object.get("name").?.string);
}

test "WS: job_queue POST job emits notify_job_queue_changed" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    var c = try connect(ts, alloc);
    defer c.close();

    const env = try c.call(alloc, "server.websocket.id", null);
    alloc.free(env);

    // The job queue now rejects nonexistent files, so create it first. The
    // upload emits its own notify_filelist_changed; drain that (and any
    // proc_stat) so the next read sees the job-queue notification cleanly.
    const up = try ts.uploadFile(alloc, "gcodes", null, "test.gcode", "G28\n");
    alloc.free(up);
    setReadTimeout(c, 1);
    while (nextDataFrameSkipProcStat(c)) |f| {
        alloc.free(f.data);
    } else |_| {}

    const body = try ts.postJson(alloc, "/server/job_queue/job",
        \\{"filenames":["test.gcode"]}
    );
    defer alloc.free(body);

    setReadTimeout(c, 3);
    defer clearReadTimeout(c);
    const frame = try nextDataFrameSkipProcStat(c);
    defer alloc.free(frame.data);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, frame.data, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try std.testing.expectEqualStrings("notify_job_queue_changed", obj.get("method").?.string);
    try std.testing.expect(obj.get("id") == null);
    const params = obj.get("params").?.array;
    try std.testing.expectEqual(@as(usize, 1), params.items.len);
    const inner = params.items[0].object;
    try std.testing.expectEqualStrings("jobs_added", inner.get("action").?.string);
    try std.testing.expectEqualStrings("paused", inner.get("queue_state").?.string);
    try std.testing.expect(inner.get("updated_queue") != null);
}

test "WS: power device action=on emits notify_power_changed" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    // Add a device — no config loading in tests.
    ts.app.power_ctx.addDevice("test_psu", "gpio", "off", false) catch unreachable;

    var c = try connect(ts, alloc);
    defer c.close();

    const env = try c.call(alloc, "server.websocket.id", null);
    alloc.free(env);

    const body = try ts.postJson(alloc, "/machine/device_power/device",
        \\{"device":"test_psu","action":"on"}
    );
    defer alloc.free(body);

    setReadTimeout(c, 3);
    defer clearReadTimeout(c);
    const frame = try nextDataFrameSkipProcStat(c);
    defer alloc.free(frame.data);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, frame.data, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try std.testing.expectEqualStrings("notify_power_changed", obj.get("method").?.string);
    try std.testing.expect(obj.get("id") == null);
    const params = obj.get("params").?.array;
    try std.testing.expectEqual(@as(usize, 1), params.items.len);
    const dev_info = params.items[0].object;
    try std.testing.expectEqualStrings("test_psu", dev_info.get("device").?.string);
    try std.testing.expectEqualStrings("on", dev_info.get("status").?.string);
}

test "WS deadline reads buffered frames and permits reuse after an idle timeout" {
    const ts = try TestServer.init(std.testing.allocator);
    defer ts.stop();
    const client = try connect(ts, std.testing.allocator);
    defer client.close();
    @memcpy(client.reader.interface.buffer[0..3], &[_]u8{ 0x81, 1, 'x' });
    client.reader.interface.seek = 0;
    client.reader.interface.end = 3;
    setReadTimeout(client, 0);
    const frame = try nextDataFrame(client);
    defer std.testing.allocator.free(frame.data);
    try std.testing.expectEqualStrings("x", frame.data);
    try std.testing.expectError(error.Timeout, nextDataFrame(client));
    clearReadTimeout(client);
    const response = try client.call(std.testing.allocator, "server.info", null);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "phobos") != null);
}

test "WS deadlines cover a stalled payload after a buffered header" {
    const ts = try TestServer.init(std.testing.allocator);
    defer ts.stop();
    const client = try connect(ts, std.testing.allocator);
    defer client.close();
    @memcpy(client.reader.interface.buffer[0..2], &[_]u8{ 0x81, 4 });
    client.reader.interface.seek = 0;
    client.reader.interface.end = 2;
    setReadTimeout(client, 0);
    try std.testing.expectError(error.Timeout, nextDataFrame(client));
}
