//! Bounded buffer growth for the native server WebSocket codec.
const std = @import("std");
const Io = std.Io;
const WebSocket = std.http.Server.WebSocket;

pub const max_message_size = 10 * 1024 * 1024;

pub const MessageBuffer = struct {
    alloc: std.mem.Allocator,
    reader: *Io.Reader,
    original: []u8,
    owned: ?[]u8 = null,

    pub fn init(alloc: std.mem.Allocator, reader: *Io.Reader) MessageBuffer {
        return .{ .alloc = alloc, .reader = reader, .original = reader.buffer };
    }

    pub fn deinit(self: *MessageBuffer) void {
        if (self.owned) |buffer| self.alloc.free(buffer);
        self.reader.buffer = self.original;
        self.reader.seek = 0;
        self.reader.end = 0;
    }

    /// Returned data is borrowed until the next read or deinit.
    pub fn read(self: *MessageBuffer, ws: *WebSocket) !WebSocket.SmallMessage {
        if (self.owned != null and self.reader.bufferedLen() <= self.original.len) {
            self.replace(self.original);
            self.alloc.free(self.owned.?);
            self.owned = null;
        }
        while (true) {
            const first = try self.reader.peekArray(2);
            const h0: WebSocket.Header0 = @bitCast(first[0]);
            const h1: WebSocket.Header1 = @bitCast(first[1]);
            if (h0.rsv1 != 0 or h0.rsv2 != 0 or h0.rsv3 != 0) return error.UnexpectedOpCode;
            const header_len: usize = switch (h1.payload_len) {
                .len16 => 4,
                .len64 => 10,
                else => 2,
            };
            const header = try self.reader.peek(header_len);
            const size: u64 = switch (h1.payload_len) {
                .len16 => std.mem.readInt(u16, header[2..4], .big),
                .len64 => std.mem.readInt(u64, header[2..10], .big),
                else => @backingInt(h1.payload_len),
            };
            if (size > max_message_size) return error.MessageOversize;
            if (!h1.mask) return error.MissingMaskBit;
            if (h0.opcode == .ping or h0.opcode == .pong or h0.opcode == .connection_close) {
                if (!h0.fin or size > 125) return error.UnexpectedOpCode;
            }
            // The native reader skips pongs internally. Consume them here so
            // the following frame's required capacity is checked first.
            if (h0.opcode == .pong) {
                try self.reader.discardAll(header_len + 4 + @as(usize, @intCast(size)));
                continue;
            }
            if (size > self.reader.buffer.len) {
                const buffer = try self.alloc.alloc(u8, @intCast(size));
                self.replace(buffer);
                if (self.owned) |old| self.alloc.free(old);
                self.owned = buffer;
            }
            return ws.readSmallMessage();
        }
    }

    fn replace(self: *MessageBuffer, buffer: []u8) void {
        const remaining = self.reader.buffered();
        @memcpy(buffer[0..remaining.len], remaining);
        self.reader.buffer = buffer;
        self.reader.seek = 0;
        self.reader.end = remaining.len;
    }
};

test "native websocket grows for a large message then releases its buffer" {
    const alloc = std.testing.allocator;
    const payload = try alloc.alloc(u8, 65536);
    defer alloc.free(payload);
    @memset(payload, 'x');
    var wire: Io.Writer.Allocating = .init(alloc);
    defer wire.deinit();
    try wire.writer.writeAll(&.{ 0x8a, 0x80, 0, 0, 0, 0, 0x81, 0xff });
    try wire.writer.writeInt(u64, payload.len, .big);
    try wire.writer.writeAll(&.{ 0, 0, 0, 0 });
    try wire.writer.writeAll(payload);
    try wire.writer.writeAll(&.{ 0x81, 0x81, 0, 0, 0, 0, 'y' });
    var source: Io.Reader = .fixed(wire.written());
    var original: [32]u8 = undefined;
    var limited = source.limited(.unlimited, &original);
    var out: Io.Writer = .failing;
    var ws: WebSocket = .{ .key = "", .input = &limited.interface, .output = &out };
    var buffer = MessageBuffer.init(alloc, ws.input);
    defer buffer.deinit();
    try std.testing.expectEqualSlices(u8, payload, (try buffer.read(&ws)).data);
    try std.testing.expect(buffer.owned != null);
    try std.testing.expectEqualStrings("y", (try buffer.read(&ws)).data);
    try std.testing.expect(buffer.owned == null);
}

test "native websocket rejects an oversized announced length before allocation" {
    var source: Io.Reader = .fixed(&.{ 0x81, 0xff, 0, 0, 0, 0, 0, 0xa0, 0, 1 });
    var out: Io.Writer = .failing;
    var ws: WebSocket = .{ .key = "", .input = &source, .output = &out };
    var buffer = MessageBuffer.init(std.testing.allocator, ws.input);
    defer buffer.deinit();
    try std.testing.expectError(error.MessageOversize, buffer.read(&ws));
    try std.testing.expect(buffer.owned == null);
}

test "fuzz native websocket buffer accepts bounded masked frames" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            const alloc = std.testing.allocator;
            var payload: [4096]u8 = undefined;
            const size = smith.valueRangeAtMostWithHash(u16, 0, payload.len, 0);
            smith.bytesWithHash(payload[0..size], 1);
            var wire: Io.Writer.Allocating = .init(alloc);
            defer wire.deinit();
            try wire.writer.writeAll(&.{ 0x82, 0xfe });
            try wire.writer.writeInt(u16, size, .big);
            const mask = [_]u8{ 1, 2, 3, 4 };
            try wire.writer.writeAll(&mask);
            for (payload[0..size], 0..) |b, i| try wire.writer.writeByte(b ^ mask[i % mask.len]);
            var source: Io.Reader = .fixed(wire.written());
            var original: [32]u8 = undefined;
            var limited = source.limited(.unlimited, &original);
            var out: Io.Writer = .failing;
            var ws: WebSocket = .{ .key = "", .input = &limited.interface, .output = &out };
            var buffer = MessageBuffer.init(alloc, ws.input);
            defer buffer.deinit();
            try std.testing.expectEqualSlices(u8, payload[0..size], (try buffer.read(&ws)).data);
        }
    }.run, .{});
}
