//! Minimal RFC 6455 WebSocket *client* over `std.Io.net`.
//!
//! Used by the Spoolman component for a live connection to a Spoolman server
//! (ws://host/api/v1/spool): a client handshake, reading server text frames
//! (server→client frames are unmasked), ping→pong keepalive, and masked client
//! writes for pong/close. Host resolution is IPv4-literal / "localhost" only.

const std = @import("std");
const net = std.Io.net;
const Io = std.Io;

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,
};

pub const Message = struct { opcode: Opcode, data: []u8 };

pub const WsClient = struct {
    io: Io,
    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    rbuf: []u8,
    wbuf: []u8,
    gpa: std.mem.Allocator,
    mask_seed: u32 = 0x9E37_79B9,

    /// Connect to `host:port` and complete the WS upgrade handshake for `path`.
    /// Heap-allocated (stable address; reader/writer hold pointers into it).
    pub fn connect(gpa: std.mem.Allocator, io: Io, host: []const u8, port: u16, path: []const u8) !*WsClient {
        const ip = if (std.mem.eql(u8, host, "localhost"))
            try net.IpAddress.parseIp4("127.0.0.1", port)
        else
            try net.IpAddress.parseIp4(host, port);
        const stream = try ip.connect(io, .{ .mode = .stream });
        errdefer stream.close(io);

        const rbuf = try gpa.alloc(u8, 8192);
        errdefer gpa.free(rbuf);
        const wbuf = try gpa.alloc(u8, 4096);
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
        try self.handshake(host, path);
        return self;
    }

    fn handshake(self: *WsClient, host: []const u8, path: []const u8) !void {
        const w = &self.writer.interface;
        // A fixed valid Sec-WebSocket-Key (the RFC example). We don't verify the
        // server's Accept — a 101 status is sufficient for our use.
        try w.print(
            "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n",
            .{ path, host },
        );
        try w.flush();

        // takeDelimiterInclusive consumes the '\n' (Exclusive does NOT, which
        // would leave the delimiter and misframe the following bytes).
        const r = &self.reader.interface;
        const status = try r.takeDelimiterInclusive('\n');
        if (std.mem.indexOf(u8, status, "101") == null) return error.WsHandshakeFailed;
        while (true) {
            const line = try r.takeDelimiterInclusive('\n');
            if (std.mem.trimEnd(u8, line, "\r\n").len == 0) break; // blank line ends headers
        }
    }

    fn nextMask(self: *WsClient) [4]u8 {
        var x = self.mask_seed;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.mask_seed = x;
        return @bitCast(x);
    }

    /// Write a masked client frame (clients MUST mask, RFC 6455 §5.3).
    fn writeFrame(self: *WsClient, op: Opcode, payload: []const u8) !void {
        const w = &self.writer.interface;
        try w.writeByte(0x80 | @as(u8, @intFromEnum(op)));
        const mask = self.nextMask();
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
        for (payload, 0..) |b, i| try w.writeByte(b ^ mask[i % 4]);
        try w.flush();
    }

    /// Read the next data (text/binary) message, answering pings with pongs.
    /// Returns error.WsClosed on a close frame. Data is owned by `alloc`.
    pub fn readMessage(self: *WsClient, alloc: std.mem.Allocator) !Message {
        const r = &self.reader.interface;
        while (true) {
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
            if (masked) mask = (try r.takeArray(4)).*;
            const payload = try alloc.alloc(u8, len);
            errdefer alloc.free(payload);
            const src = try r.take(len);
            if (masked) {
                for (src, 0..) |b, i| payload[i] = b ^ mask[i % 4];
            } else {
                @memcpy(payload, src);
            }
            switch (opcode) {
                .ping => {
                    self.writeFrame(.pong, payload) catch {};
                    alloc.free(payload);
                    continue;
                },
                .pong => {
                    alloc.free(payload);
                    continue;
                },
                .close => {
                    alloc.free(payload);
                    return error.WsClosed;
                },
                else => return .{ .opcode = opcode, .data = payload },
            }
        }
    }

    /// Interrupt a blocking readMessage from another thread (teardown).
    pub fn shutdownRecv(self: *WsClient) void {
        self.stream.shutdown(self.io, .recv) catch {};
    }

    pub fn deinit(self: *WsClient) void {
        self.stream.close(self.io);
        self.gpa.free(self.rbuf);
        self.gpa.free(self.wbuf);
        self.gpa.destroy(self);
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// Minimal test WS server: accept, drain the HTTP request, send a lenient 101
/// (the client does not verify Accept), push one unmasked text frame, then read
/// until the client drops.
fn testServer(server: *net.Server, io: Io, payload: []const u8) void {
    const stream = server.accept(io) catch return;
    defer stream.close(io);
    var rbuf: [2048]u8 = undefined;
    var wbuf: [512]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var w = stream.writer(io, &wbuf);
    while (true) {
        const line = r.interface.takeDelimiterInclusive('\n') catch return;
        if (std.mem.trimEnd(u8, line, "\r\n").len == 0) break;
    }
    w.interface.writeAll("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: x\r\n\r\n") catch return;
    w.interface.writeByte(0x81) catch return; // FIN | text
    w.interface.writeByte(@intCast(payload.len)) catch return; // unmasked, len < 126
    w.interface.writeAll(payload) catch return;
    w.interface.flush() catch return;
    while (true) _ = r.interface.takeByte() catch break;
}

fn testServerPort(server: *net.Server) u16 {
    var sa: std.os.linux.sockaddr.in = undefined;
    var slen: std.os.linux.socklen_t = @sizeOf(@TypeOf(sa));
    _ = std.os.linux.getsockname(server.socket.handle, @ptrCast(&sa), &slen);
    return std.mem.bigToNative(u16, sa.port);
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

    const ws = try WsClient.connect(alloc, io, "127.0.0.1", port, "/api/v1/spool");
    const msg = try ws.readMessage(alloc);
    defer alloc.free(msg.data);
    try testing.expectEqual(Opcode.text, msg.opcode);
    try testing.expectEqualStrings(payload, msg.data);
    ws.deinit();
    sf.await(io);
}
