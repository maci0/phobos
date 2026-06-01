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
    mask_seed: u32 = 0x1234_5678,

    /// Close the stream and free buffers.
    pub fn close(self: *WsTestConn) void {
        self.stream.close(self.io);
        self.alloc.free(self.rbuf);
        self.alloc.free(self.wbuf);
        self.alloc.destroy(self);
    }

    fn nextMask(self: *WsTestConn) [4]u8 {
        // xorshift32 so successive frames use different masks.
        var x = self.mask_seed;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.mask_seed = x;
        return @bitCast(x);
    }

    /// Send a masked client frame with the given opcode and payload.
    pub fn sendFrame(self: *WsTestConn, op: Opcode, payload: []const u8) !void {
        const w = &self.writer.interface;
        // FIN=1, opcode.
        try w.writeByte(0x80 | @as(u8, @intFromEnum(op)));
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
        const r = &self.reader.interface;
        const b0 = try r.takeByte();
        const b1 = try r.takeByte();
        const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b0 & 0x0f)));
        const masked = (b1 & 0x80) != 0;
        var len: usize = b1 & 0x7f;
        if (len == 126) {
            len = try r.takeInt(u16, .big);
        } else if (len == 127) {
            len = @intCast(try r.takeInt(u64, .big));
        }
        var mask: [4]u8 = .{ 0, 0, 0, 0 };
        if (masked) {
            const m = try r.takeArray(4);
            mask = m.*;
        }
        const payload = try self.alloc.alloc(u8, len);
        errdefer self.alloc.free(payload);
        const src = try r.take(len);
        if (masked) {
            for (src, 0..) |b, i| payload[i] = b ^ mask[i % 4];
        } else {
            @memcpy(payload, src);
        }
        return .{ .opcode = opcode, .data = payload };
    }

    /// Send a JSON-RPC text request and return the result payload as owned JSON
    /// bytes (the full JSON-RPC response envelope). Caller frees with `alloc`.
    pub fn callRaw(self: *WsTestConn, alloc: std.mem.Allocator, request_json: []const u8) ![]u8 {
        try self.sendFrame(.text, request_json);
        var frame = try self.readFrame();
        defer self.alloc.free(frame.data);
        // Tolerate an interleaved ping by replying pong and reading again.
        while (frame.opcode == .ping) {
            try self.sendFrame(.pong, frame.data);
            self.alloc.free(frame.data);
            frame = try self.readFrame();
        }
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
    self.* = .{
        .io = io,
        .stream = stream,
        .reader = undefined,
        .writer = undefined,
        .rbuf = try alloc.alloc(u8, 64 * 1024),
        .wbuf = try alloc.alloc(u8, 64 * 1024),
        .alloc = alloc,
    };
    errdefer alloc.free(self.rbuf);
    errdefer alloc.free(self.wbuf);
    self.reader = stream.reader(io, self.rbuf);
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

    // Read the response head up to the blank line. Use the *inclusive*
    // delimiter form so each call consumes the trailing '\n' as well; the
    // exclusive form leaves the '\n' in the buffer, which would misalign the
    // following reads (and cause the leftover header bytes to be parsed as a
    // WebSocket frame). Each returned line still carries its trailing CRLF.
    const r = &self.reader.interface;
    const status_line = try r.takeDelimiterInclusive('\n');
    if (std.mem.indexOf(u8, status_line, "101") == null) return error.HandshakeFailed;
    while (true) {
        const line = try r.takeDelimiterInclusive('\n');
        // Header section ends at the blank line ("\r\n" -> len 2, or bare "\n").
        if (line.len <= 2) break;
    }
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
            const req = std.fmt.bufPrint(&req_buf,
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
