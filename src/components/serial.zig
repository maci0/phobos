//! Minimal serial-port (UART / USB-CDC) driver over `std.Io.File` + termios.
//!
//! Used by WLED serial strips and the TD-1 filament sensor. Opens the character
//! device read/write, configures it for raw 8N1 at the requested baud (termios
//! best-effort — failures, e.g. on a non-tty, are ignored so the byte path still
//! works), and exposes blocking write/read.
//!
//! Tests cover regular-file bytes and pseudo-terminal baud/raw settings.
//! Physical UART and USB-CDC timing still requires target hardware.

const std = @import("std");
const Dir = std.Io.Dir;
const Io = std.Io;

pub const Serial = struct {
    io: Io,
    file: std.Io.File,

    pub fn open(io: Io, path: []const u8, baud: u32) !Serial {
        const file = try Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        configureRaw(file.handle, baud);
        return .{ .io = io, .file = file };
    }

    /// Best-effort raw 8N1 configuration. Silently returns when the fd is not a
    /// terminal (e.g. a regular file in tests) or termios is unavailable.
    fn configureRaw(handle: std.posix.fd_t, baud: u32) void {
        var t = std.posix.tcgetattr(handle) catch return;
        t.iflag = .{};
        t.oflag = .{};
        t.lflag = .{};
        t.cflag = .{ .CSIZE = .CS8, .CREAD = true, .CLOCAL = true };
        const spd = baudToSpeed(baud);
        // Linux tcsetattr reads the baud bits in cflag, including with musl.
        t.cflag = @bitCast(@as(u32, @bitCast(t.cflag)) | @as(u32, @backingInt(spd)));
        t.ispeed = spd;
        t.ospeed = spd;
        t.cc[@backingInt(std.posix.V.MIN)] = 1;
        t.cc[@backingInt(std.posix.V.TIME)] = 0;
        std.posix.tcsetattr(handle, .NOW, t) catch {};
    }

    fn baudToSpeed(baud: u32) std.posix.speed_t {
        return switch (baud) {
            9600 => .B9600,
            19200 => .B19200,
            38400 => .B38400,
            57600 => .B57600,
            115200 => .B115200,
            else => .B115200,
        };
    }

    pub fn write(self: *Serial, bytes: []const u8) !void {
        var buf: [256]u8 = undefined;
        var w = self.file.writer(self.io, &buf);
        try w.interface.writeAll(bytes);
        try w.interface.flush();
    }

    /// Read up to `buf.len` bytes; returns the count actually read (may be 0).
    pub fn readSome(self: *Serial, buf: []u8) !usize {
        return self.file.readStreaming(self.io, &.{buf}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
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

test "baudToSpeed: known + fallback" {
    try testing.expectEqual(std.posix.speed_t.B9600, Serial.baudToSpeed(9600));
    try testing.expectEqual(std.posix.speed_t.B115200, Serial.baudToSpeed(115200));
    try testing.expectEqual(std.posix.speed_t.B115200, Serial.baudToSpeed(123456));
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
    var serial = try Serial.open(io, try std.fmt.bufPrint(&path, "/dev/pts/{d}", .{number}), 115200);
    defer serial.close();
    const attrs = try std.posix.tcgetattr(serial.file.handle);
    const baud_mask = comptime blk: {
        var mask: u32 = 0;
        for (std.meta.tags(std.posix.speed_t)) |speed| mask |= @backingInt(speed);
        break :blk mask;
    };
    try testing.expectEqual(@as(u32, @backingInt(std.posix.speed_t.B115200)), @as(u32, @bitCast(attrs.cflag)) & baud_mask);
    try testing.expectEqual(.CS8, attrs.cflag.CSIZE);
    try testing.expect(!attrs.cflag.PARENB and !attrs.cflag.CSTOPB and !attrs.cflag.CRTSCTS);
    try testing.expectEqual(@as(u8, 1), attrs.cc[@backingInt(std.posix.V.MIN)]);
    try testing.expectEqual(@as(u8, 0), attrs.cc[@backingInt(std.posix.V.TIME)]);
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
