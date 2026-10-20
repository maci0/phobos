//! Absolute deadlines for native socket readers and writers.
const std = @import("std");
const Io = std.Io;

pub const SocketDeadline = struct {
    base_io: Io,
    timeout: Io.Timeout,

    /// This adapter only supports socket read/write operations. It must outlive
    /// every native reader or writer using the returned handle.
    pub fn io(self: *SocketDeadline) Io {
        return .{ .userdata = self, .vtable = &vtable };
    }

    const vtable: Io.VTable = blk: {
        var result = Io.failing.vtable.*;
        result.operate = operate;
        break :blk result;
    };

    fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
        const self: *SocketDeadline = @ptrCast(@alignCast(userdata.?));
        std.debug.assert(operation == .net_read or operation == .net_write);
        return self.base_io.operateTimeout(operation, self.timeout) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Timeout => switch (operation) {
                .net_read => .{ .net_read = error.ConnectionTimedOut },
                .net_write => .{ .net_write = error.ConnectionTimedOut },
                else => unreachable,
            },
            error.ConcurrencyUnavailable => switch (operation) {
                .net_read => .{ .net_read = error.SystemResources },
                .net_write => .{ .net_write = error.SystemResources },
                else => unreachable,
            },
        };
    }
};

test "native socket reader fails at its absolute deadline" {
    const io = std.testing.io;
    var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer listener.deinit(io);
    const client = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    const server = try listener.accept(io);
    defer server.close(io);
    var deadline: SocketDeadline = .{ .base_io = io, .timeout = .{ .deadline = .fromNow(io, .{ .raw = .fromMilliseconds(20), .clock = .awake }) } };
    var buffer: [16]u8 = undefined;
    var reader = server.reader(deadline.io(), &buffer);
    try std.testing.expectError(error.ReadFailed, reader.interface.takeByte());
    try std.testing.expectEqual(error.ConnectionTimedOut, reader.err.?);
}

test "fuzz native deadline sockets preserve payloads and repeated writes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const io = std.testing.io;
            var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
            defer listener.deinit(io);
            const client = try listener.socket.address.connect(io, .{ .mode = .stream });
            defer client.close(io);
            const server = try listener.accept(io);
            defer server.close(io);
            var deadline: SocketDeadline = .{ .base_io = io, .timeout = .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(1), .clock = .awake }) } };
            var bytes: [256]u8 = undefined;
            const len = smith.valueRangeAtMostWithHash(u16, 0, bytes.len, 0);
            smith.bytesWithHash(bytes[0..len], 1);
            var writer = client.writer(deadline.io(), &.{});
            try writer.interface.writeAll(bytes[0..len]);
            try writer.interface.splatBytesAll("ab", 3);
            var buffer: [512]u8 = undefined;
            var reader = server.reader(deadline.io(), &buffer);
            try std.testing.expectEqualSlices(u8, bytes[0..len], try reader.interface.take(len));
            try std.testing.expectEqualStrings("ababab", try reader.interface.take(6));
        }
    }.run, .{});
}
