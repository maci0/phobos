//! Minimal serial-port (UART / USB-CDC) driver over `std.Io.File` + termios.
//!
//! Used by WLED serial strips and the TD-1 filament sensor. Opens the character
//! device read/write, configures it for raw 8N1 at the requested baud (termios
//! best-effort — failures, e.g. on a non-tty, are ignored so the byte path still
//! works), and exposes blocking write/read.
//!
//! NOTE: exercised in tests against a regular file (byte path). Baud/raw termios
//! configuration is applied on real ttys only and is not verified here — it
//! requires physical serial hardware.

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
        t.cflag.CSIZE = .CS8;
        t.cflag.PARENB = false;
        t.cflag.CSTOPB = false;
        t.cflag.CREAD = true;
        t.cflag.CLOCAL = true;
        const spd = baudToSpeed(baud);
        t.ispeed = spd;
        t.ospeed = spd;
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
        var r = self.file.reader(self.io, buf);
        return r.interface.readSliceShort(buf);
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

    const path = "/tmp/phobos_serial_test.dev";
    Dir.cwd().deleteFile(io, path) catch {};
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "" });
    defer Dir.cwd().deleteFile(io, path) catch {};

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
    try testing.expectError(error.FileNotFound, Serial.open(io, "/tmp/phobos_serial_nope_xyz", 115200));
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
