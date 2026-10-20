//! Native socket writes with one absolute deadline per complete frame.
const std = @import("std");
const Io = std.Io;
const SocketDeadline = @import("socket_deadline.zig").SocketDeadline;

pub const write_timeout: Io.Duration = .fromSeconds(5);

pub const DeadlineWriter = struct {
    io: Io,
    stream: Io.net.Stream,
    timeout: Io.Duration = write_timeout,
    deadline: ?Io.Clock.Timestamp = null,
    interface: Io.Writer,

    pub fn init(io: Io, stream: Io.net.Stream, buffer: []u8) DeadlineWriter {
        return .{ .io = io, .stream = stream, .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    /// Call under the session's write mutex before each complete frame.
    pub fn beginFrame(self: *DeadlineWriter) void {
        self.deadline = .fromNow(self.io, .{ .raw = self.timeout, .clock = .awake });
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *DeadlineWriter = @alignCast(@fieldParentPtr("interface", w));
        if (self.deadline == null) self.beginFrame();
        const deadline = self.deadline.?;
        if (deadline.compare(.lte, .now(self.io, .awake))) return self.fail();
        const result = self.io.operateTimeout(.{ .net_write = .{
            .socket_handle = self.stream.socket.handle,
            .header = w.buffered(),
            .data = data,
            .splat = splat,
        } }, .{ .deadline = deadline }) catch return self.fail();
        return w.consume(result.net_write catch return self.fail());
    }

    fn fail(self: *DeadlineWriter) error{WriteFailed} {
        // Shut down both directions to release the session's blocked reader.
        self.stream.shutdown(self.io, .both) catch {};
        return error.WriteFailed;
    }
};

/// A connected TCP pair over loopback: `server` is the accepted end.
const LoopbackPair = struct {
    listener: Io.net.Server,
    client: Io.net.Stream,
    server: Io.net.Stream,

    fn init(io: Io) !LoopbackPair {
        var addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
        var listener = try addr.listen(io, .{});
        errdefer listener.deinit(io);
        const client = try listener.socket.address.connect(io, .{ .mode = .stream });
        errdefer client.close(io);
        return .{ .listener = listener, .client = client, .server = try listener.accept(io) };
    }

    fn deinit(self: *LoopbackPair, io: Io) void {
        self.server.close(io);
        self.client.close(io);
        self.listener.deinit(io);
    }
};

test "DeadlineWriter gives up on a peer that stops reading and shuts the socket down" {
    const io = std.testing.io;
    var pair = try LoopbackPair.init(io);
    defer pair.deinit(io);
    var buf: [1024]u8 = undefined;
    var out = DeadlineWriter.init(io, pair.server, &buf);
    out.timeout = .fromMilliseconds(100);
    out.beginFrame();
    const chunk: [64 * 1024]u8 = @splat('x');
    const start = Io.Clock.Timestamp.now(io, .awake);
    const failed = for (0..1024) |_| {
        out.interface.writeAll(&chunk) catch break true;
    } else false;
    try std.testing.expect(failed);
    try std.testing.expect(start.untilNow(io).raw.toMilliseconds() < 5000);
    var read_deadline: SocketDeadline = .{ .base_io = io, .timeout = .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(1), .clock = .awake }) } };
    var rbuf: [64 * 1024]u8 = undefined;
    var r = pair.client.reader(read_deadline.io(), &rbuf);
    _ = try r.interface.discardRemaining();
}

test "DeadlineWriter keeps the first deadline across successful partial frame writes" {
    const io = std.testing.io;
    var pair = try LoopbackPair.init(io);
    defer pair.deinit(io);
    var out = DeadlineWriter.init(io, pair.server, &.{});
    out.timeout = .fromMilliseconds(20);
    out.beginFrame();
    try out.interface.writeAll("first");
    try Io.sleep(io, .fromMilliseconds(30), .awake);
    try std.testing.expectError(error.WriteFailed, out.interface.writeAll("second"));
    var read_deadline: SocketDeadline = .{ .base_io = io, .timeout = .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(1), .clock = .awake }) } };
    var buf: [16]u8 = undefined;
    var reader = pair.client.reader(read_deadline.io(), &buf);
    try std.testing.expectEqualStrings("first", try reader.interface.take(5));
    try std.testing.expectError(error.EndOfStream, reader.interface.takeByte());
}

test "DeadlineWriter starts a fresh budget after an idle completed frame" {
    const io = std.testing.io;
    var pair = try LoopbackPair.init(io);
    defer pair.deinit(io);
    var out = DeadlineWriter.init(io, pair.server, &.{});
    out.timeout = .fromMilliseconds(20);
    out.beginFrame();
    try out.interface.writeAll("first");
    try Io.sleep(io, .fromMilliseconds(30), .awake);
    out.beginFrame();
    try out.interface.writeAll("second");
    var read_deadline: SocketDeadline = .{ .base_io = io, .timeout = .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(1), .clock = .awake }) } };
    var buf: [16]u8 = undefined;
    var reader = pair.client.reader(read_deadline.io(), &buf);
    try std.testing.expectEqualStrings("firstsecond", try reader.interface.take(11));
}

test "fuzz DeadlineWriter delivers every byte to a reading peer" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const io = std.testing.io;
            var pair = try LoopbackPair.init(io);
            defer pair.deinit(io);
            var payload: [9000]u8 = undefined;
            const n = smith.valueRangeAtMostWithHash(u16, 0, payload.len, 0);
            smith.bytesWithHash(payload[0..n], 1);
            var buf: [100]u8 = undefined;
            var out = DeadlineWriter.init(io, pair.server, &buf);
            out.beginFrame();
            try out.interface.writeAll(payload[0..n]);
            try out.interface.splatBytesAll("ab", 3);
            try out.interface.flush();
            try pair.server.shutdown(io, .send);
            var read_deadline: SocketDeadline = .{ .base_io = io, .timeout = .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(1), .clock = .awake }) } };
            var rbuf: [16 * 1024]u8 = undefined;
            var reader = pair.client.reader(read_deadline.io(), &rbuf);
            var got: Io.Writer.Allocating = .init(std.testing.allocator);
            defer got.deinit();
            _ = try reader.interface.streamRemaining(&got.writer);
            try std.testing.expectEqualSlices(u8, payload[0..n], got.written()[0..n]);
            try std.testing.expectEqualStrings("ababab", got.written()[n..]);
        }
    }.run, .{});
}
