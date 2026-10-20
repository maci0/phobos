//! Minimal RFC 6455 WebSocket *client* over `std.Io.net`.
//!
//! Used by the Spoolman component for a live connection to a Spoolman server
//! (ws://host/api/v1/spool): a client handshake, reading server text frames
//! (server→client frames are unmasked), ping→pong keepalive, and masked client
//! writes for pong/close, with bounded message assembly.

const std = @import("std");
const net = std.Io.net;
const Io = std.Io;
const tls_transport = @import("../util/tls.zig");

const WebSocket = std.http.Server.WebSocket;
pub const Opcode = WebSocket.Opcode;

pub const Message = struct { opcode: Opcode, data: []u8 };
pub const max_message_len = 8 * 1024 * 1024;

pub const WsClient = struct {
    io: Io,
    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    rbuf: []u8,
    wbuf: []u8,
    gpa: std.mem.Allocator,
    tls: ?*tls_transport.State = null,
    heartbeat: ?struct {
        interval: Io.Duration,
        timeout: Io.Duration,
        next_ping: Io.Clock.Timestamp,
        pong_deadline: ?Io.Clock.Timestamp = null,
        nonce: [8]u8 = undefined,
    } = null,

    const heartbeat_vtable: Io.VTable = blk: {
        var vtable = Io.failing.vtable.*;
        vtable.operate = heartbeatOperation;
        break :blk vtable;
    };

    /// Enable ping/pong liveness checks on the connection's reader thread.
    pub fn enableHeartbeat(self: *WsClient, interval: Io.Duration, timeout: Io.Duration) void {
        self.heartbeat = .{
            .interval = interval,
            .timeout = timeout,
            .next_ping = .fromNow(self.io, .{ .raw = interval, .clock = .awake }),
        };
        const heartbeat_io: Io = .{ .userdata = self, .vtable = &heartbeat_vtable };
        self.reader.io = heartbeat_io;
        self.writer.io = heartbeat_io;
        if (self.tls) |t| {
            t.net_reader.io = heartbeat_io;
            t.net_writer.io = heartbeat_io;
        }
    }

    fn heartbeatTick(self: *WsClient) !void {
        const heartbeat = if (self.heartbeat) |*h| h else return;
        const now = Io.Clock.Timestamp.now(self.io, .awake);
        if (heartbeat.pong_deadline) |deadline| {
            if (now.compare(.gte, deadline)) return error.WsPingTimeout;
        } else if (now.compare(.gte, heartbeat.next_ping)) {
            try self.io.randomSecure(&heartbeat.nonce);
            heartbeat.pong_deadline = .fromNow(self.io, .{ .raw = heartbeat.timeout, .clock = .awake });
            try self.writeFrame(.ping, &heartbeat.nonce);
        }
    }

    fn heartbeatOperation(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
        const self: *WsClient = @ptrCast(@alignCast(userdata.?));
        const heartbeat = &self.heartbeat.?;
        switch (operation) {
            .net_read => while (true) {
                self.heartbeatTick() catch return .{ .net_read = error.ConnectionTimedOut };
                return self.io.operateTimeout(operation, .{ .deadline = heartbeat.pong_deadline orelse heartbeat.next_ping }) catch |err| switch (err) {
                    error.Timeout => continue,
                    error.Canceled => return error.Canceled,
                    error.ConcurrencyUnavailable => .{ .net_read = error.SystemResources },
                };
            },
            .net_write => return self.io.operateTimeout(operation, .{ .duration = .{ .raw = heartbeat.timeout, .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => .{ .net_write = error.ConnectionTimedOut },
                error.Canceled => return error.Canceled,
                error.ConcurrencyUnavailable => .{ .net_write = error.SystemResources },
            },
            else => unreachable,
        }
    }

    /// Connect to `host:port` and complete the WS upgrade handshake for `path`.
    /// Heap-allocated (stable address; reader/writer hold pointers into it).
    pub fn connect(gpa: std.mem.Allocator, io: Io, host: []const u8, port: u16, path: []const u8, tls_opts: ?tls_transport.Options) !*WsClient {
        const stream = if (net.IpAddress.parse(host, port)) |ip|
            try ip.connect(io, .{ .mode = .stream })
        else |_|
            try (try net.HostName.init(host)).connect(io, port, .{ .mode = .stream });
        errdefer stream.close(io);

        const rbuf = try gpa.alloc(u8, if (tls_opts == null) 8192 else 0);
        errdefer gpa.free(rbuf);
        const wbuf = try gpa.alloc(u8, if (tls_opts == null) 4096 else 0);
        errdefer gpa.free(wbuf);

        const self = try gpa.create(WsClient);
        errdefer gpa.destroy(self);
        self.* = .{
            .io = io,
            .stream = stream,
            .reader = undefined,
            .writer = undefined,
            .rbuf = rbuf,
            .wbuf = wbuf,
            .gpa = gpa,
        };
        self.reader = stream.reader(io, self.rbuf);
        self.writer = stream.writer(io, self.wbuf);
        if (tls_opts) |opts| self.tls = try tls_transport.connect(gpa, io, stream, opts);
        errdefer if (self.tls) |t| tls_transport.deinit(gpa, t);
        try self.handshake(host, port, path);
        return self;
    }

    fn input(self: *WsClient) *Io.Reader {
        return if (self.tls) |t| &t.client.reader else &self.reader.interface;
    }

    fn output(self: *WsClient) *Io.Writer {
        return if (self.tls) |t| &t.client.writer else &self.writer.interface;
    }

    fn flush(self: *WsClient) !void {
        if (self.tls) |t| try tls_transport.flush(t) else try self.writer.interface.flush();
    }

    fn handshake(self: *WsClient, host: []const u8, port: u16, path: []const u8) !void {
        if (std.mem.indexOfAny(u8, host, "\r\n") != null or
            std.mem.indexOfAny(u8, path, "\r\n ") != null) return error.WsHandshakeFailed;
        var nonce: [16]u8 = undefined;
        try self.io.randomSecure(&nonce);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &nonce);
        const w = self.output();
        try w.print(
            "GET {s} HTTP/1.1\r\nHost: {s}{s}{s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
            .{ path, if (std.mem.indexOfScalar(u8, host, ':') != null) "[" else "", host, if (std.mem.indexOfScalar(u8, host, ':') != null) "]" else "", port, key },
        );
        try self.flush();
        var http: std.http.Reader = .{ .in = self.input(), .interface = undefined, .state = .ready, .max_head_len = 8192 };
        try validateHandshake(try http.receiveHead(), &key);
    }

    /// Write a masked client control frame (clients MUST mask, RFC 6455
    /// §5.3). Control payloads are at most 125 bytes (§5.5), which
    /// `readFrameHeader` enforces on the frames this echoes.
    fn writeFrame(self: *WsClient, op: Opcode, payload: []const u8) !void {
        std.debug.assert(payload.len <= 125);
        var mask: [4]u8 = undefined;
        try self.io.randomSecure(&mask);
        const w = self.output();
        try w.writeByte(@bitCast(WebSocket.Header0{ .opcode = op, .fin = true }));
        try w.writeByte(@bitCast(WebSocket.Header1{ .payload_len = @fromBackingInt(@as(u7, @intCast(payload.len))), .mask = true }));
        try w.writeAll(&mask);
        for (payload, 0..) |b, i| try w.writeByte(b ^ mask[i % 4]);
        try self.flush();
    }

    /// Read the next data (text/binary) message, answering pings with pongs.
    /// Returns error.WsClosed on a close frame. Data is owned by `alloc`.
    pub fn readMessage(self: *WsClient, alloc: std.mem.Allocator) !Message {
        const r = self.input();
        var data: std.ArrayList(u8) = .empty;
        errdefer data.deinit(alloc);
        var message_op: ?Opcode = null;
        while (true) {
            try self.heartbeatTick();
            const frame = try readFrameHeader(r);
            switch (frame.op) {
                .ping, .pong, .connection_close => {
                    var control: [125]u8 = undefined;
                    const payload = control[0..frame.len];
                    try r.readSliceAll(payload);
                    if (frame.op == .ping) try self.writeFrame(.pong, payload);
                    if (frame.op == .pong) if (self.heartbeat) |*heartbeat| {
                        if (heartbeat.pong_deadline != null and std.mem.eql(u8, payload, &heartbeat.nonce)) {
                            heartbeat.pong_deadline = null;
                            heartbeat.next_ping = .fromNow(self.io, .{ .raw = heartbeat.interval, .clock = .awake });
                        }
                    };
                    if (frame.op == .connection_close) {
                        self.writeFrame(.connection_close, payload) catch {};
                        return error.WsClosed;
                    }
                    continue;
                },
                .continuation => if (message_op == null) return error.WsProtocolError,
                .text, .binary => {
                    if (message_op != null) return error.WsProtocolError;
                    message_op = frame.op;
                },
                _ => unreachable,
            }
            if (frame.len > max_message_len - data.items.len) return error.WsMessageTooLarge;
            const start = data.items.len;
            try data.resize(alloc, start + frame.len);
            try r.readSliceAll(data.items[start..]);
            if (frame.fin) {
                if (message_op.? == .text and !std.unicode.utf8ValidateSlice(data.items)) return error.WsProtocolError;
                return .{ .opcode = message_op.?, .data = try data.toOwnedSlice(alloc) };
            }
        }
    }

    /// Interrupt a blocking readMessage from another thread (teardown).
    pub fn shutdownRecv(self: *WsClient) void {
        self.stream.shutdown(self.io, .recv) catch {};
    }

    pub fn deinit(self: *WsClient) void {
        if (self.tls) |t| tls_transport.deinit(self.gpa, t);
        self.stream.close(self.io);
        self.gpa.free(self.rbuf);
        self.gpa.free(self.wbuf);
        self.gpa.destroy(self);
    }
};

fn validateHandshake(bytes: []const u8, key: []const u8) !void {
    const head = try std.http.Client.Response.Head.parse(bytes);
    if (head.status != .switching_protocols or head.version != .@"HTTP/1.1") return error.WsHandshakeFailed;
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    sha1.final(&digest);
    var accept: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept, &digest);
    var headers = std.http.HeaderIterator.init(bytes);
    var upgraded = false;
    var connected = false;
    var accepted = false;
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "upgrade")) upgraded = std.ascii.eqlIgnoreCase(header.value, "websocket");
        if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-accept")) accepted = std.mem.eql(u8, header.value, &accept);
        if (std.ascii.eqlIgnoreCase(header.name, "connection")) {
            var tokens = std.mem.tokenizeAny(u8, header.value, ", \t");
            while (tokens.next()) |token| connected = connected or std.ascii.eqlIgnoreCase(token, "upgrade");
        }
    }
    if (!upgraded or !connected or !accepted) return error.WsHandshakeFailed;
}

fn readFrameHeader(r: *Io.Reader) !struct { op: Opcode, fin: bool, len: usize } {
    const h0: WebSocket.Header0 = @bitCast(try r.takeByte());
    const h1: WebSocket.Header1 = @bitCast(try r.takeByte());
    // Server frames carry no RSV bits (no extension negotiated) and no mask.
    if (h0.rsv1 != 0 or h0.rsv2 != 0 or h0.rsv3 != 0 or h1.mask) return error.WsProtocolError;
    const op = h0.opcode;
    switch (op) {
        .continuation, .text, .binary, .connection_close, .ping, .pong => {},
        _ => return error.WsProtocolError,
    }
    const len: u64 = switch (h1.payload_len) {
        .len16 => len: {
            const n = try r.takeInt(u16, .big);
            if (n < 126) return error.WsProtocolError;
            break :len n;
        },
        .len64 => len: {
            const n = try r.takeInt(u64, .big);
            if (n < 65536 or n >> 63 != 0) return error.WsProtocolError;
            break :len n;
        },
        _ => @backingInt(h1.payload_len),
    };
    if (@backingInt(op) >= 8 and (!h0.fin or len > 125 or (op == .connection_close and len == 1))) return error.WsProtocolError;
    if (len > max_message_len) return error.WsMessageTooLarge;
    return .{ .op = op, .fin = h0.fin, .len = @intCast(len) };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// Send a message through the standard server handshake and frame writer.
fn testServer(server: *net.Server, io: Io, payload: []const u8) void {
    const stream = server.accept(io) catch return;
    defer stream.close(io);
    var rbuf: [2048]u8 = undefined;
    var wbuf: [512]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var w = stream.writer(io, &wbuf);
    var http = std.http.Server.init(&r.interface, &w.interface);
    var request = http.receiveHead() catch return;
    const key = switch (request.upgradeRequested()) {
        .websocket => |key| key orelse return,
        else => return,
    };
    var ws = request.respondWebSocket(.{ .key = key }) catch return;
    ws.writeMessage(payload, .text) catch return;
    while (true) _ = r.interface.takeByte() catch break;
}

fn testServerPort(server: *net.Server) u16 {
    return server.socket.address.getPort();
}

test "WsClient: message larger than the reader buffer" {
    var threaded = Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer server.deinit(io);
    const payload: [9000]u8 = @splat('x');
    var future = io.async(testServer, .{ &server, io, @as([]const u8, &payload) });
    defer future.cancel(io);
    const ws = try WsClient.connect(testing.allocator, io, "localhost", testServerPort(&server), "/websocket", null);
    defer ws.deinit();
    const message = try ws.readMessage(testing.allocator);
    defer testing.allocator.free(message.data);
    try testing.expectEqualStrings(&payload, message.data);
}

test "WebSocket handshake validates the accept and exact status" {
    const headers = "\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n";
    try validateHandshake("HTTP/1.1 101 Switching Protocols" ++ headers, "dGhlIHNhbXBsZSBub25jZQ==");
    try testing.expectError(error.WsHandshakeFailed, validateHandshake("HTTP/1.1 200 101" ++ headers, "dGhlIHNhbXBsZSBub25jZQ=="));
    try testing.expectError(error.WsHandshakeFailed, validateHandshake("HTTP/1.1 101 Switching Protocols" ++ headers, "wrong key"));
}

test "WebSocket heartbeat detects a silent peer and accepts matching pongs" {
    const aio = testing.io;
    const Peer = struct {
        fn run(s: *net.Server, io: Io, answer: bool, partial: bool) !void {
            const stream = try s.accept(io);
            defer stream.close(io);
            var rbuf: [2048]u8 = undefined;
            var wbuf: [512]u8 = undefined;
            var r = stream.reader(io, &rbuf);
            var w = stream.writer(io, &wbuf);
            var http = std.http.Server.init(&r.interface, &w.interface);
            var request = try http.receiveHead();
            _ = try request.respondWebSocket(.{ .key = request.upgradeRequested().websocket.? });
            try w.interface.flush();
            if (partial) {
                try w.interface.writeAll("\x81\x20partial");
                try w.interface.flush();
            }
            const ping = try r.interface.takeArray(14);
            try testing.expectEqual(@as(u8, 0x89), ping[0]);
            try testing.expectEqual(@as(u8, 0x88), ping[1]);
            if (answer) {
                var pong: [10]u8 = .{ 0x8a, 8 } ++ @as([8]u8, undefined);
                for (pong[2..], 0..) |*b, i| b.* = ping[6 + i] ^ ping[2 + i % 4];
                try w.interface.writeAll(&pong);
                try w.interface.writeAll("\x81\x02ok");
                try w.interface.flush();
            } else {
                // A pong with the wrong payload must not satisfy our ping.
                try w.interface.writeAll("\x8a\x00");
                try w.interface.flush();
            }
            while (true) _ = try r.interface.takeByte();
        }
    };
    for ([_]bool{ false, true }) |answer| {
        var server = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(aio, .{});
        defer server.deinit(aio);
        var peer = try aio.concurrent(Peer.run, .{ &server, aio, answer, false });
        defer peer.cancel(aio) catch {};
        const ws = try WsClient.connect(testing.allocator, aio, "127.0.0.1", testServerPort(&server), "/", null);
        defer ws.deinit();
        ws.enableHeartbeat(.fromMilliseconds(20), .fromMilliseconds(50));
        const started = Io.Clock.Timestamp.now(aio, .awake);
        if (answer) {
            const message = try ws.readMessage(testing.allocator);
            defer testing.allocator.free(message.data);
            try testing.expectEqualStrings("ok", message.data);
        } else {
            try testing.expectError(error.ReadFailed, ws.readMessage(testing.allocator));
            try testing.expectEqual(error.ConnectionTimedOut, ws.reader.err.?);
        }
        try testing.expect(started.untilNow(aio).raw.toMilliseconds() < 1000);
    }
    var server = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(aio, .{});
    defer server.deinit(aio);
    var peer = try aio.concurrent(Peer.run, .{ &server, aio, false, true });
    defer peer.cancel(aio) catch {};
    const ws = try WsClient.connect(testing.allocator, aio, "127.0.0.1", testServerPort(&server), "/", null);
    defer ws.deinit();
    ws.enableHeartbeat(.fromMilliseconds(20), .fromMilliseconds(50));
    try testing.expectError(error.ReadFailed, ws.readMessage(testing.allocator));
    try testing.expectEqual(error.ConnectionTimedOut, ws.reader.err.?);
}

test "WebSocket frame rejects oversized and invalid lengths before allocation" {
    for ([_][]const u8{ "\x81\x7f\x00\x00\x00\x01\x00\x00\x00\x00", "\x81\x7f\x00\x00\x00\x00\x00\x80\x00\x01" }) |bytes| {
        var r = Io.Reader.fixed(bytes);
        try testing.expectError(error.WsMessageTooLarge, readFrameHeader(&r));
    }
    for ([_][]const u8{ "\x81\x80", "\xc1\x00", "\x83\x00", "\x09\x00", "\x81\x7e\x00\x01", "\x88\x01" }) |bytes| {
        var r = Io.Reader.fixed(bytes);
        try testing.expectError(error.WsProtocolError, readFrameHeader(&r));
    }
}

test "fuzz WebSocket headers and handshake stay bounded" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var bytes: [256]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            var r = Io.Reader.fixed(&bytes);
            const frame = readFrameHeader(&r) catch null;
            if (frame) |f| try testing.expect(f.len <= max_message_len);
            validateHandshake(&bytes, "dGhlIHNhbXBsZSBub25jZQ==") catch {};
        }
    }.run, .{});
}

test "fuzz WebSocket messages and heartbeat replies stay bounded" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var bytes: [512]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            var output: [512]u8 = undefined;
            var client: WsClient = undefined;
            client.io = testing.io;
            client.tls = null;
            client.reader.interface = .fixed(&bytes);
            client.writer.interface = .fixed(&output);
            const deadline = Io.Clock.Timestamp.fromNow(testing.io, .{ .raw = .fromSeconds(20), .clock = .awake });
            client.heartbeat = .{
                .interval = .fromSeconds(20),
                .timeout = .fromSeconds(20),
                .next_ping = deadline,
                .pong_deadline = deadline,
                .nonce = @splat(0),
            };
            const message = client.readMessage(arena.allocator()) catch return;
            try testing.expect(message.data.len <= max_message_len);
            if (message.opcode == .text) try testing.expect(std.unicode.utf8ValidateSlice(message.data));
        }
    }.run, .{});
}

test "WsClient: handshake then read a server text frame" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ip = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try ip.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = testServerPort(&server);

    const payload = "{\"resource\":\"spool\",\"type\":\"deleted\",\"payload\":{\"id\":5}}";
    var sf = io.async(testServer, .{ &server, io, @as([]const u8, payload) });

    const ws = try WsClient.connect(alloc, io, "127.0.0.1", port, "/api/v1/spool", null);
    const msg = try ws.readMessage(alloc);
    defer alloc.free(msg.data);
    try testing.expectEqual(Opcode.text, msg.opcode);
    try testing.expectEqualStrings(payload, msg.data);
    ws.deinit();
    sf.await(io);
}

test "WebSocket assembles fragments and answers interleaved pings" {
    const aio = testing.io;
    var server = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(aio, .{});
    defer server.deinit(aio);
    const Peer = struct {
        fn run(s: *net.Server, io: Io) !void {
            const stream = try s.accept(io);
            defer stream.close(io);
            var rbuf: [2048]u8 = undefined;
            var wbuf: [512]u8 = undefined;
            var r = stream.reader(io, &rbuf);
            var w = stream.writer(io, &wbuf);
            var http = std.http.Server.init(&r.interface, &w.interface);
            var request = try http.receiveHead();
            const key = request.upgradeRequested().websocket.?;
            _ = try request.respondWebSocket(.{ .key = key });
            try w.interface.writeAll(&.{ 0x01, 2, 'h', 'e', 0x89, 1, '!', 0x80, 3, 'l', 'l', 'o' });
            try w.interface.flush();
            const pong = try r.interface.takeArray(7);
            try testing.expectEqual(@as(u8, 0x8a), pong[0]);
            try testing.expectEqual(@as(u8, 0x81), pong[1]);
            try testing.expectEqual(@as(u8, '!'), pong[6] ^ pong[2]);
        }
    };
    var future = try aio.concurrent(Peer.run, .{ &server, aio });
    defer future.cancel(aio) catch {};
    const ws = try WsClient.connect(testing.allocator, aio, "127.0.0.1", testServerPort(&server), "/", null);
    defer ws.deinit();
    const message = try ws.readMessage(testing.allocator);
    defer testing.allocator.free(message.data);
    try testing.expectEqualStrings("hello", message.data);
    try future.await(aio);
}

test "WebSocket TLS verifies the server certificate and hostname" {
    const aio = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(aio, ".", alloc);
    const cert = try std.fs.path.join(alloc, &.{ dir, "cert.pem" });
    const key = try std.fs.path.join(alloc, &.{ dir, "key.pem" });
    const gen = std.process.run(alloc, aio, .{ .argv = &.{ "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost" } }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    try testing.expect(gen.term == .exited and gen.term.exited == 0);
    var server = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(aio, .{});
    defer server.deinit(aio);
    var reserve = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(aio, .{});
    const port = reserve.socket.address.getPort();
    reserve.deinit(aio);
    const listen = try std.fmt.allocPrint(alloc, "OPENSSL-LISTEN:{d},bind=127.0.0.1,cert={s},key={s},verify=0,reuseaddr,fork", .{ port, cert, key });
    const forward = try std.fmt.allocPrint(alloc, "TCP:127.0.0.1:{d}", .{testServerPort(&server)});
    var proxy = std.process.spawn(aio, .{ .argv = &.{ "socat", listen, forward }, .stdout = .ignore, .stderr = .ignore }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer proxy.kill(aio);
    var future = try aio.concurrent(testServer, .{ &server, aio, @as([]const u8, "secure") });
    defer future.cancel(aio);
    var client: ?*WsClient = null;
    for (0..50) |_| {
        client = WsClient.connect(testing.allocator, aio, "localhost", port, "/", .{ .host = "localhost", .ca_path = cert }) catch {
            try aio.sleep(.fromMilliseconds(10), .awake);
            continue;
        };
        break;
    }
    const ws = client orelse return error.TlsConnectFailed;
    defer ws.deinit();
    const message = try ws.readMessage(testing.allocator);
    defer testing.allocator.free(message.data);
    try testing.expectEqualStrings("secure", message.data);
}
