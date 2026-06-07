//! Minimal Linux sysfs GPIO driver (`/sys/class/gpio`).
//!
//! Used by the power component to drive `type: gpio` devices on the target
//! board (Cortex-A7). sysfs GPIO is the legacy-but-universally-available
//! interface; modern libgpiod/chardev is not exposed through Zig's std, and the
//! embedded target ships the sysfs interface.
//!
//! `root` is overridable so the driver can be exercised against a temporary
//! directory in tests without touching real hardware. All filesystem access
//! goes through `std.Io.Dir` (no raw syscalls).

const std = @import("std");
const Dir = std.Io.Dir;
const Io = std.Io;

pub const SysfsGpio = struct {
    io: Io,
    /// GPIO controller root. Real hardware: "/sys/class/gpio". Tests point this
    /// at a temp dir holding a pre-created `gpio<pin>/{direction,value}`.
    root: []const u8 = "/sys/class/gpio",

    fn writePath(self: SysfsGpio, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype, data: []const u8) !void {
        const path = try std.fmt.allocPrint(alloc, fmt, args);
        defer alloc.free(path);
        try Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = data });
    }

    /// Export the pin if not already exported. Best-effort: a kernel returns
    /// EBUSY (surfacing as a write error) when the pin is already exported,
    /// which is not an error condition for us.
    pub fn exportPin(self: SysfsGpio, alloc: std.mem.Allocator, pin: u32) void {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{pin}) catch return;
        self.writePath(alloc, "{s}/export", .{self.root}, s) catch {};
    }

    /// Release the pin. Best-effort.
    pub fn unexportPin(self: SysfsGpio, alloc: std.mem.Allocator, pin: u32) void {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{pin}) catch return;
        self.writePath(alloc, "{s}/unexport", .{self.root}, s) catch {};
    }

    /// Drive `pin` to the given physical level: export (best-effort), set the
    /// direction to output, and write the value. `physical_high` is the level
    /// placed on the line — the caller applies any active-low inversion.
    pub fn setValue(self: SysfsGpio, alloc: std.mem.Allocator, pin: u32, physical_high: bool) !void {
        self.exportPin(alloc, pin);
        try self.writePath(alloc, "{s}/gpio{d}/direction", .{ self.root, pin }, "out");
        try self.writePath(alloc, "{s}/gpio{d}/value", .{ self.root, pin }, if (physical_high) "1" else "0");
    }

    /// Read the physical level of `pin` (export + direction=in best-effort first).
    /// Returns 1 if the value file's first byte is '1', else 0. Errors if the pin
    /// is not exported / value file is missing.
    pub fn readValue(self: SysfsGpio, alloc: std.mem.Allocator, pin: u32) !u1 {
        self.exportPin(alloc, pin);
        // Direction=in is best-effort: some pins are input-only / already set.
        self.writePath(alloc, "{s}/gpio{d}/direction", .{ self.root, pin }, "in") catch {};
        const path = try std.fmt.allocPrint(alloc, "{s}/gpio{d}/value", .{ self.root, pin });
        defer alloc.free(path);
        const f = try Dir.cwd().openFile(self.io, path, .{});
        defer f.close(self.io);
        var buf: [8]u8 = undefined;
        var r = f.reader(self.io, &buf);
        const n = try r.interface.readSliceShort(&buf);
        if (n == 0) return error.EmptyValue;
        return if (buf[0] == '1') 1 else 0;
    }
};

// ===========================================================================
// Tests — against a temp directory simulating an exported pin.
// ===========================================================================

const testing = std.testing;

fn readSmall(io: Io, path: []const u8, buf: []u8) ![]u8 {
    const f = try Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var r = f.reader(io, buf);
    const n = try r.interface.readSliceShort(buf);
    return buf[0..n];
}

test "SysfsGpio.setValue: writes direction=out and value high/low" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "/tmp/phobos_gpio_test_root";
    const pindir = root ++ "/gpio17";
    // Fresh tree simulating an exported pin (gpio17/{direction,value}).
    Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, pindir);
    try Dir.cwd().writeFile(io, .{ .sub_path = pindir ++ "/direction", .data = "in" });
    try Dir.cwd().writeFile(io, .{ .sub_path = pindir ++ "/value", .data = "0" });
    defer Dir.cwd().deleteTree(io, root) catch {};

    const gpio = SysfsGpio{ .io = io, .root = root };

    try gpio.setValue(testing.allocator, 17, true);
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("out", try readSmall(io, pindir ++ "/direction", &buf));
    var buf2: [8]u8 = undefined;
    try testing.expectEqualStrings("1", try readSmall(io, pindir ++ "/value", &buf2));

    try gpio.setValue(testing.allocator, 17, false);
    var buf3: [8]u8 = undefined;
    try testing.expectEqualStrings("0", try readSmall(io, pindir ++ "/value", &buf3));

    // export wrote the pin number to <root>/export.
    var buf4: [8]u8 = undefined;
    try testing.expectEqualStrings("17", try readSmall(io, root ++ "/export", &buf4));
}

test "SysfsGpio.setValue: missing pin dir errors (no crash)" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "/tmp/phobos_gpio_test_missing";
    Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, root);
    defer Dir.cwd().deleteTree(io, root) catch {};

    const gpio = SysfsGpio{ .io = io, .root = root };
    // No gpio99 dir → writing direction fails; must return an error, not crash.
    try testing.expectError(error.FileNotFound, gpio.setValue(testing.allocator, 99, true));
}

test "fuzz SysfsGpio.setValue: arbitrary pins never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var buf: [5]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const pin = std.mem.readInt(u32, buf[0..4], .little) % 1024;
            const gpio = SysfsGpio{ .io = io, .root = "/tmp/phobos_gpio_fuzz_nonexistent" };
            // Nonexistent root → always errors, never crashes.
            gpio.setValue(testing.allocator, pin, buf[4] & 1 == 1) catch {};
        }
    }.run, .{});
}
