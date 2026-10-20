//! Bounded messages over the native server WebSocket frame codec.
const std = @import("std");
const Io = std.Io;
const WebSocket = std.http.Server.WebSocket;

pub const max_message_size = 10 * 1024 * 1024;

pub const MessageBuffer = struct {
    alloc: std.mem.Allocator,
    reader: *Io.Reader,
    original: []u8,
    owned: ?[]u8 = null,
    fragments: std.ArrayList(u8) = .empty,
    fragment_opcode: ?WebSocket.Opcode = null,
    completed: bool = false,

    pub fn init(alloc: std.mem.Allocator, reader: *Io.Reader) MessageBuffer {
        return .{ .alloc = alloc, .reader = reader, .original = reader.buffer };
    }

    pub fn deinit(self: *MessageBuffer) void {
        self.fragments.deinit(self.alloc);
        if (self.owned) |buffer| self.alloc.free(buffer);
        self.reader.buffer = self.original;
        self.reader.seek = 0;
        self.reader.end = 0;
    }

    /// Returned data is borrowed until the next read or deinit.
    pub fn read(self: *MessageBuffer, ws: *WebSocket) !WebSocket.SmallMessage {
        if (self.completed) {
            self.fragments.clearAndFree(self.alloc);
            self.completed = false;
        }
        while (true) {
            if (self.owned != null and self.reader.bufferedLen() <= self.original.len) {
                self.replace(self.original);
                self.alloc.free(self.owned.?);
                self.owned = null;
            }
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
            switch (h0.opcode) {
                .text, .binary => {
                    if (self.fragment_opcode != null) return error.UnexpectedOpCode;
                    if (!h0.fin) self.fragment_opcode = h0.opcode;
                },
                .continuation => {
                    if (self.fragment_opcode == null) return error.UnexpectedOpCode;
                    if (size > max_message_size - self.fragments.items.len) return error.MessageOversize;
                },
                .ping, .pong, .connection_close => {},
                _ => return error.UnexpectedOpCode,
            }
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
            // The native reader accepts complete data frames only. Validate
            // sequencing here, then let it decode each fragment's payload.
            const normalized = try self.reader.peekArray(2);
            const opcode = if (h0.opcode == .continuation) self.fragment_opcode.? else h0.opcode;
            normalized[0] = @bitCast(WebSocket.Header0{ .opcode = opcode, .fin = true });
            const message = try ws.readSmallMessage();
            if (self.fragment_opcode != null and (opcode == .text or opcode == .binary)) {
                const required = self.fragments.items.len + message.data.len;
                if (required > self.fragments.capacity) {
                    const capacity = @min(max_message_size, std.math.ceilPowerOfTwoAssert(usize, required));
                    try self.fragments.ensureTotalCapacityPrecise(self.alloc, capacity);
                }
                self.fragments.appendSliceAssumeCapacity(message.data);
                if (!h0.fin) continue;
                self.fragment_opcode = null;
                self.completed = true;
                return .{ .opcode = opcode, .data = self.fragments.items };
            }
            return message;
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

test "native websocket joins fragments while returning interleaved control frames" {
    const wire = [_]u8{ 0x01, 0x82, 0, 0, 0, 0, 'a', 'b' } ++
        [_]u8{ 0x89, 0x81, 0, 0, 0, 0, '!' } ++
        [_]u8{ 0x8a, 0x81, 0, 0, 0, 0, '?' } ++
        [_]u8{ 0x00, 0x82, 0, 0, 0, 0, 'c', 'd' } ++
        [_]u8{ 0x80, 0x82, 0, 0, 0, 0, 'e', 'f' } ++
        [_]u8{ 0x81, 0x81, 0, 0, 0, 0, 'x' };
    var source: Io.Reader = .fixed(&wire);
    var small: [16]u8 = undefined;
    var limited = source.limited(.unlimited, &small);
    var out: Io.Writer = .failing;
    var ws: WebSocket = .{ .key = "", .input = &limited.interface, .output = &out };
    var buffer = MessageBuffer.init(std.testing.allocator, ws.input);
    defer buffer.deinit();
    const ping = try buffer.read(&ws);
    try std.testing.expectEqual(WebSocket.Opcode.ping, ping.opcode);
    try std.testing.expectEqualStrings("!", ping.data);
    const joined = try buffer.read(&ws);
    try std.testing.expectEqual(WebSocket.Opcode.text, joined.opcode);
    try std.testing.expectEqualStrings("abcdef", joined.data);
    try std.testing.expectEqualStrings("x", (try buffer.read(&ws)).data);
    try std.testing.expectEqual(@as(usize, 0), buffer.fragments.capacity);
}

test "native websocket validates fragment sequencing and total size" {
    for ([_][]const u8{
        &.{ 0x80, 0x80, 0, 0, 0, 0 },
        &.{ 0x01, 0x80, 0, 0, 0, 0, 0x81, 0x80, 0, 0, 0, 0 },
    }) |wire| {
        var bytes: [32]u8 = undefined;
        @memcpy(bytes[0..wire.len], wire);
        var source: Io.Reader = .fixed(bytes[0..wire.len]);
        var out: Io.Writer = .failing;
        var ws: WebSocket = .{ .key = "", .input = &source, .output = &out };
        var buffer = MessageBuffer.init(std.testing.allocator, ws.input);
        defer buffer.deinit();
        try std.testing.expectError(error.UnexpectedOpCode, buffer.read(&ws));
    }
    var wire = [_]u8{ 0x01, 0x81, 0, 0, 0, 0, 'a', 0x80, 0xff, 0, 0, 0, 0, 0, 0xa0, 0, 0 };
    var source: Io.Reader = .fixed(&wire);
    var out: Io.Writer = .failing;
    var ws: WebSocket = .{ .key = "", .input = &source, .output = &out };
    var buffer = MessageBuffer.init(std.testing.allocator, ws.input);
    defer buffer.deinit();
    try std.testing.expectError(error.MessageOversize, buffer.read(&ws));
    try std.testing.expectEqual(@as(usize, 1), buffer.fragments.items.len);
    try std.testing.expectEqual(@as(usize, 1), buffer.fragments.capacity);
    try std.testing.expect(buffer.owned == null);
}

test "native websocket close interrupts a fragmented message" {
    var wire = [_]u8{ 0x01, 0x81, 0, 0, 0, 0, 'a', 0x88, 0x80, 0, 0, 0, 0 };
    var source: Io.Reader = .fixed(&wire);
    var out: Io.Writer = .failing;
    var ws: WebSocket = .{ .key = "", .input = &source, .output = &out };
    var buffer = MessageBuffer.init(std.testing.allocator, ws.input);
    defer buffer.deinit();
    try std.testing.expectError(error.ConnectionClose, buffer.read(&ws));
}

test "native websocket fragment storage cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            const wire = [_]u8{ 0x01, 0xfe, 0, 64, 0, 0, 0, 0 } ++ @as([64]u8, @splat('a')) ++ [_]u8{ 0x80, 0x81, 0, 0, 0, 0, 'z' };
            var source: Io.Reader = .fixed(&wire);
            var small: [8]u8 = undefined;
            var limited = source.limited(.unlimited, &small);
            var out: Io.Writer = .failing;
            var ws: WebSocket = .{ .key = "", .input = &limited.interface, .output = &out };
            var buffer = MessageBuffer.init(alloc, ws.input);
            defer buffer.deinit();
            const message = try buffer.read(&ws);
            try std.testing.expectEqual(@as(usize, 65), message.data.len);
            try std.testing.expectEqual(@as(u8, 'z'), message.data[64]);
            try std.testing.expect(buffer.fragments.capacity <= max_message_size);
        }
    }.run, .{});
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
            const mask = [_]u8{ 1, 2, 3, 4 };
            const fragmented = smith.valueRangeAtMostWithHash(u8, 0, 1, 3) == 1;
            const split = if (fragmented) smith.valueRangeAtMostWithHash(u16, 0, size, 2) else size;
            const parts = [_][]const u8{ payload[0..split], payload[split..size] };
            for (parts[0..@as(usize, if (fragmented) 2 else 1)], 0..) |part, frame| {
                try wire.writer.writeAll(&.{ if (!fragmented) 0x82 else if (frame == 0) 0x02 else 0x80, 0xfe });
                try wire.writer.writeInt(u16, @intCast(part.len), .big);
                try wire.writer.writeAll(&mask);
                for (part, 0..) |b, i| try wire.writer.writeByte(b ^ mask[i % mask.len]);
            }
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

test "fuzz native websocket rejects malformed fragment headers without exceeding storage bounds" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var wire: [128]u8 = undefined;
            smith.bytesWithHash(&wire, 0);
            var source: Io.Reader = .fixed(&wire);
            var small: [16]u8 = undefined;
            var limited = source.limited(.unlimited, &small);
            var out: Io.Writer = .failing;
            var ws: WebSocket = .{ .key = "", .input = &limited.interface, .output = &out };
            var buffer = MessageBuffer.init(std.testing.allocator, ws.input);
            defer buffer.deinit();
            const message = buffer.read(&ws) catch return;
            try std.testing.expect(message.data.len <= max_message_size);
            try std.testing.expect(buffer.fragments.capacity <= max_message_size);
        }
    }.run, .{});
}
