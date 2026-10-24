//! Minimal serial-port (UART / USB-CDC) driver over `std.Io.File` + termios.
//!
//! Used by the TD-1 filament sensor. Opens the character device read/write and
//! configures it for raw 8N1 at the requested baud (termios best-effort:
//! failures, e.g. on a non-tty, are ignored so the byte path still works). An
//! unsupported baud rate is an error. Writes block until complete; a read waits
//! at most `read_timeout_ds` for the first byte and returns 0 when none arrives.
//!
//! Tests cover regular-file bytes and pseudo-terminal baud/raw settings.
//! Physical UART and USB-CDC timing still requires target hardware.

const std = @import("std");
const Dir = std.Io.Dir;
const Io = std.Io;

/// termios VTIME: deciseconds a read waits for the first byte (VMIN = 0).
pub const read_timeout_ds: u8 = 10;

pub const Serial = struct {
    io: Io,
    file: std.Io.File,

    pub fn open(io: Io, path: []const u8, baud: u32) !Serial {
        const speed = try baudToSpeed(baud);
        const file = try Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        configureRaw(file.handle, speed);
        return .{ .io = io, .file = file };
    }

    /// Best-effort raw 8N1 configuration. Silently returns when the fd is not a
    /// terminal (e.g. a regular file in tests) or termios is unavailable.
    fn configureRaw(handle: std.posix.fd_t, spd: std.posix.speed_t) void {
        var t = std.posix.tcgetattr(handle) catch return;
        t.iflag = .{};
        t.oflag = .{};
        t.lflag = .{};
        t.cflag = .{ .CSIZE = .CS8, .CREAD = true, .CLOCAL = true };
        // Linux tcsetattr reads the baud bits in cflag, including with musl.
        t.cflag = @bitCast(@as(u32, @bitCast(t.cflag)) | @as(u32, @backingInt(spd)));
        t.cc[@backingInt(std.posix.V.MIN)] = 0;
        t.cc[@backingInt(std.posix.V.TIME)] = read_timeout_ds;
        std.posix.tcsetattr(handle, .NOW, t) catch {};
    }

    /// Map a numeric rate to its termios constant. `B0` (hang up) is excluded.
    pub fn baudToSpeed(baud: u32) error{UnsupportedBaud}!std.posix.speed_t {
        const speeds = comptime std.meta.tags(std.posix.speed_t);
        const rates = comptime blk: {
            @setEvalBranchQuota(10_000);
            var out: [speeds.len]u32 = undefined;
            for (speeds, &out) |speed, *rate| rate.* = std.fmt.parseInt(u32, @tagName(speed)[1..], 10) catch unreachable;
            break :blk out;
        };
        for (speeds, rates) |speed, rate| {
            if (rate != 0 and baud == rate) return speed;
        }
        return error.UnsupportedBaud;
    }

    pub fn write(self: *Serial, bytes: []const u8) !void {
        try self.file.writeStreamingAll(self.io, bytes);
    }

    /// Cancel and join a stalled write at `timeout`; `bytes` stays borrowed.
    pub fn writeTimeout(self: *Serial, bytes: []const u8, timeout: Io.Timeout) !void {
        const Outcome = union(enum) { wrote: anyerror!void, expired: Io.Cancelable!void };
        var outcomes: [2]Outcome = undefined;
        var select: Io.Select(Outcome) = .init(self.io, &outcomes);
        defer select.cancelDiscard();
        try select.concurrent(.wrote, write, .{ self, bytes });
        try select.concurrent(.expired, Io.Timeout.sleep, .{ timeout, self.io });
        switch (try select.await()) {
            .wrote => |result| try result,
            .expired => |result| {
                try result;
                return error.Timeout;
            },
        }
    }

    /// Read up to `buf.len` bytes; returns the count actually read, 0 when the
    /// read timeout expires without data or at end of file.
    pub fn readSome(self: *Serial, buf: []u8) !usize {
        return self.file.readStreaming(self.io, &.{buf}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
    }

    /// Cancel and join a read at `timeout`; unread bytes remain on the stream.
    pub fn readSomeTimeout(self: *Serial, buf: []u8, timeout: Io.Timeout) !usize {
        const Outcome = union(enum) { read: anyerror!usize, expired: Io.Cancelable!void };
        var outcomes: [2]Outcome = undefined;
        var select: Io.Select(Outcome) = .init(self.io, &outcomes);
        defer select.cancelDiscard();
        try select.concurrent(.read, readSome, .{ self, buf });
        try select.concurrent(.expired, Io.Timeout.sleep, .{ timeout, self.io });
        return switch (try select.await()) {
            .read => |result| try result,
            .expired => |result| blk: {
                try result;
                break :blk error.Timeout;
            },
        };
    }

    pub fn close(self: *Serial) void {
        self.file.close(self.io);
    }
};

// ===========================================================================
// Tests — byte path against a regular file (termios no-ops on non-tty).
// ===========================================================================

const testing = std.testing;

test "Serial: open/write then reopen/read round-trips bytes" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "serial", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(io, "serial", testing.allocator);
    defer testing.allocator.free(path);

    {
        var s = try Serial.open(io, path, 115200);
        defer s.close();
        try s.write("{\"on\":true}");
    }
    {
        var s = try Serial.open(io, path, 115200);
        defer s.close();
        var buf: [64]u8 = undefined;
        const n = try s.readSome(&buf);
        try testing.expectEqualStrings("{\"on\":true}", buf[0..n]);
    }
}

test "Serial.open: nonexistent device errors (no crash)" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}/nope", .{ testing.TmpDir.parent_dir_path, &tmp.sub_path });
    defer testing.allocator.free(path);
    try testing.expectError(error.FileNotFound, Serial.open(io, path, 115200));
}

test "baudToSpeed: every termios rate maps, others are rejected" {
    try testing.expectEqual(std.posix.speed_t.B9600, try Serial.baudToSpeed(9600));
    try testing.expectEqual(std.posix.speed_t.B115200, try Serial.baudToSpeed(115200));
    try testing.expectEqual(std.posix.speed_t.B230400, try Serial.baudToSpeed(230400));
    try testing.expectEqual(std.posix.speed_t.B4000000, try Serial.baudToSpeed(4000000));
    try testing.expectError(error.UnsupportedBaud, Serial.baudToSpeed(123456));
    try testing.expectError(error.UnsupportedBaud, Serial.baudToSpeed(0));
}

test "Serial.open: unsupported baud errors before opening" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "serial", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(io, "serial", testing.allocator);
    defer testing.allocator.free(path);
    try testing.expectError(error.UnsupportedBaud, Serial.open(io, path, 123456));
}

test "fuzz baudToSpeed: a mapped rate round-trips through its tag name" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            const baud = smith.valueWithHash(u32, 0);
            const speed = Serial.baudToSpeed(baud) catch return;
            try testing.expectEqual(baud, try std.fmt.parseInt(u32, @tagName(speed)[1..], 10));
        }
    }.run, .{});
}

test "fuzz Serial.open: arbitrary paths never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var buf: [32]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var s = Serial.open(io, &buf, 115200) catch return;
            s.close();
        }
    }.run, .{});
}

test "Serial.readSome advances the stream without losing unread bytes" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "serial", .data = "abcdefgh" });
    const path = try tmp.dir.realPathFileAlloc(io, "serial", testing.allocator);
    defer testing.allocator.free(path);
    var serial = try Serial.open(io, path, 115200);
    defer serial.close();
    var bytes: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try serial.readSome(&bytes));
    try testing.expectEqualStrings("abcd", &bytes);
    try testing.expectEqual(@as(usize, 4), try serial.readSome(&bytes));
    try testing.expectEqualStrings("efgh", &bytes);
    try testing.expectEqual(@as(usize, 0), try serial.readSome(&bytes));
}

test "Serial deadlines cancel silent reads and writes to a stalled pseudo-terminal" {
    const Pty = @import("../testutil/pty.zig").Pty;
    var threaded = Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();
    var pty = try Pty.init(aio);
    defer pty.deinit();
    var serial = try Serial.open(aio, pty.path(), 115200);
    defer serial.close();
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } };
    var byte: [1]u8 = undefined;
    try testing.expectError(error.Timeout, serial.readSomeTimeout(&byte, timeout));
    try pty.master.writeTimeout("a", timeout);
    try testing.expectEqual(@as(usize, 1), try serial.readSomeTimeout(&byte, timeout));
    try testing.expectEqualStrings("a", &byte);
    const payload: [64 * 1024]u8 = @splat('x');
    try testing.expectError(error.Timeout, serial.writeTimeout(&payload, timeout));
}

test "fuzz Serial deadlines preserve bounded pseudo-terminal bytes" {
    const Pty = @import("../testutil/pty.zig").Pty;
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var threaded = Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const aio = threaded.io();
            var pty = try Pty.init(aio);
            defer pty.deinit();
            var serial = try Serial.open(aio, pty.path(), 115200);
            defer serial.close();
            var expected: [16]u8 = undefined;
            smith.bytesWithHash(&expected, 0);
            const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } };
            try pty.master.writeTimeout(&expected, timeout);
            var actual: [16]u8 = undefined;
            var n: usize = 0;
            while (n < actual.len) n += try serial.readSomeTimeout(actual[n..], timeout);
            try testing.expectEqualSlices(u8, &expected, &actual);
        }
    }.run, .{});
}

test "Serial.open configures baud and raw 8N1 on a pseudo-terminal" {
    const io = testing.io;
    const master = try Dir.cwd().openFile(io, "/dev/ptmx", .{ .mode = .read_write });
    defer master.close(io);
    var unlock: c_int = 0;
    try testing.expectEqual(@as(i32, 0), (try io.operate(.{ .device_io_control = .{
        .file = master,
        .code = std.os.linux.T.IOCSPTLCK,
        .arg = &unlock,
    } })).device_io_control);
    var number: c_uint = undefined;
    try testing.expectEqual(@as(i32, 0), (try io.operate(.{ .device_io_control = .{
        .file = master,
        .code = std.os.linux.T.IOCGPTN,
        .arg = &number,
    } })).device_io_control);
    var path: [64]u8 = undefined;
    const baud_mask = comptime blk: {
        var mask: u32 = 0;
        for (std.meta.tags(std.posix.speed_t)) |speed| mask |= @backingInt(speed);
        break :blk mask;
    };
    for ([_]u32{ 9600, 57600, 115200, 230400 }) |baud| {
        var serial = try Serial.open(io, try std.fmt.bufPrint(&path, "/dev/pts/{d}", .{number}), baud);
        defer serial.close();
        const attrs = try std.posix.tcgetattr(serial.file.handle);
        try testing.expectEqual(@as(u32, @backingInt(try Serial.baudToSpeed(baud))), @as(u32, @bitCast(attrs.cflag)) & baud_mask);
        try testing.expectEqual(.CS8, attrs.cflag.CSIZE);
        try testing.expect(!attrs.cflag.PARENB and !attrs.cflag.CSTOPB and !attrs.cflag.CRTSCTS);
        try testing.expectEqual(@as(u8, 0), attrs.cc[@backingInt(std.posix.V.MIN)]);
        try testing.expectEqual(read_timeout_ds, attrs.cc[@backingInt(std.posix.V.TIME)]);
        // A silent device returns 0 after the read timeout instead of blocking.
        var bytes: [8]u8 = undefined;
        try testing.expectEqual(@as(usize, 0), try serial.readSome(&bytes));
    }
}

test "fuzz Serial.readSome preserves bytes across bounded read sizes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            const io = testing.io;
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            var expected: [32]u8 = undefined;
            smith.bytesWithHash(&expected, 0);
            try tmp.dir.writeFile(io, .{ .sub_path = "serial", .data = &expected });
            const path = try tmp.dir.realPathFileAlloc(io, "serial", testing.allocator);
            defer testing.allocator.free(path);
            var serial = try Serial.open(io, path, 115200);
            defer serial.close();
            var actual: [32]u8 = undefined;
            const chunk = smith.valueRangeAtMostWithHash(u8, 1, 16, 1);
            var offset: usize = 0;
            while (offset < actual.len) {
                const count = try serial.readSome(actual[offset..@min(actual.len, offset + chunk)]);
                try testing.expect(count > 0);
                offset += count;
            }
            try testing.expectEqualSlices(u8, &expected, &actual);
        }
    }.run, .{});
}
