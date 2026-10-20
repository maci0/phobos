//! Minimal Linux sysfs GPIO output driver (`/sys/class/gpio`).
//!
//! Used by the power component to drive `type: gpio` devices on the target
//! board (Cortex-A7). sysfs GPIO is the legacy-but-universally-available
//! interface; modern libgpiod/chardev is not exposed through Zig's std, and the
//! embedded target ships the sysfs interface.
//!
//! `root` is overridable so the driver can be exercised against a temporary
//! directory in tests without touching real hardware. All filesystem access
//! goes through `std.Io.Dir` (no raw syscalls); paths are formatted into
//! `Dir.max_path_bytes` stack buffers.

const std = @import("std");
const Dir = std.Io.Dir;
const Io = std.Io;

/// A parsed Klipper-style pin: sysfs line number + active-low inversion.
pub const ParsedPin = struct { line: u32, inverted: bool };

/// Parse a Klipper pin spec into a sysfs line + inversion. Handles a leading
/// "!" (active-low) and "^"/"~" (pull-up/down, irrelevant to an output), an
/// optional "gpiochipN/" chip prefix, a "gpio" prefix, and a bare or trailing
/// number. Returns null when no line number can be extracted.
pub fn parsePin(spec: []const u8) ?ParsedPin {
    var s = std.mem.trim(u8, spec, " \t");
    var inverted = false;
    // Strip modifier prefixes in any order.
    while (s.len > 0 and (s[0] == '!' or s[0] == '^' or s[0] == '~')) {
        if (s[0] == '!') inverted = true;
        s = s[1..];
    }
    // Drop a "gpiochipN/" chip prefix.
    if (std.mem.indexOfScalar(u8, s, '/')) |slash| s = s[slash + 1 ..];
    // Drop a leading "gpio" token.
    if (std.mem.startsWith(u8, s, "gpio")) s = s["gpio".len..];
    // Take the trailing run of digits.
    var i: usize = s.len;
    while (i > 0 and std.ascii.isDigit(s[i - 1])) i -= 1;
    const digits = s[i..];
    if (digits.len == 0) return null;
    const line = std.fmt.parseInt(u32, digits, 10) catch return null;
    return .{ .line = line, .inverted = inverted };
}

pub const SysfsGpio = struct {
    io: Io,
    /// GPIO controller root. Real hardware: "/sys/class/gpio". Tests point this
    /// at a temp dir holding a pre-created `gpio<pin>/{direction,value}`.
    root: []const u8 = "/sys/class/gpio",

    fn writePath(self: SysfsGpio, comptime fmt: []const u8, args: anytype, data: []const u8) !void {
        var buf: [Dir.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, fmt, args);
        try Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = data });
    }

    /// Drive `pin` to the given physical level: export (best-effort: the kernel
    /// rejects an already exported pin with EBUSY), set the direction to output,
    /// and write the value. `physical_high` is the level placed on the line; the
    /// caller applies any active-low inversion.
    pub fn setValue(self: SysfsGpio, pin: u32, physical_high: bool) !void {
        var buf: [16]u8 = undefined;
        const number = try std.fmt.bufPrint(&buf, "{d}", .{pin});
        self.writePath("{s}/export", .{self.root}, number) catch {};
        try self.writePath("{s}/gpio{d}/direction", .{ self.root, pin }, "out");
        try self.writePath("{s}/gpio{d}/value", .{ self.root, pin }, if (physical_high) "1" else "0");
    }
};

// ===========================================================================
// Tests — against a temp directory simulating an exported pin.
// ===========================================================================

const testing = std.testing;

fn readSmall(io: Io, dir: Dir, path: []const u8, buf: []u8) ![]u8 {
    const f = try dir.openFile(io, path, .{});
    defer f.close(io);
    return buf[0..try f.readStreaming(io, &.{buf})];
}

test "parsePin: gpio prefixes, chip prefix, inversion, bare number" {
    try testing.expectEqual(@as(u32, 26), parsePin("gpio26").?.line);
    try testing.expectEqual(false, parsePin("gpio26").?.inverted);
    try testing.expectEqual(@as(u32, 27), parsePin("!gpio27").?.line);
    try testing.expectEqual(true, parsePin("!gpio27").?.inverted);
    try testing.expectEqual(@as(u32, 5), parsePin("^~gpio5").?.line); // pull modifiers ignored
    try testing.expectEqual(@as(u32, 13), parsePin("gpiochip0/gpio13").?.line);
    try testing.expectEqual(@as(u32, 7), parsePin("7").?.line); // bare number
    try testing.expectEqual(@as(u32, 4), parsePin("!4").?.line);
    // No trailing digits → unparseable.
    try testing.expect(parsePin("") == null);
    try testing.expect(parsePin("gpio") == null);
    try testing.expect(parsePin("abc") == null);
    try testing.expect(parsePin("gpio99999999999") == null); // overflows u32
}

test "fuzz parsePin: arbitrary specs never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [24]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const len = smith.valueRangeAtMostWithHash(u8, 0, buf.len, 1);
            _ = parsePin(buf[0..len]);
        }
    }.run, .{});
}

test "SysfsGpio.setValue: writes direction=out and value high/low" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Fresh tree simulating an exported pin (gpio17/{direction,value}).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "gpio17");
    try tmp.dir.writeFile(io, .{ .sub_path = "gpio17/direction", .data = "in" });
    try tmp.dir.writeFile(io, .{ .sub_path = "gpio17/value", .data = "0" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);

    const gpio = SysfsGpio{ .io = io, .root = root };

    try gpio.setValue(17, true);
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("out", try readSmall(io, tmp.dir, "gpio17/direction", &buf));
    var buf2: [8]u8 = undefined;
    try testing.expectEqualStrings("1", try readSmall(io, tmp.dir, "gpio17/value", &buf2));

    try gpio.setValue(17, false);
    var buf3: [8]u8 = undefined;
    try testing.expectEqualStrings("0", try readSmall(io, tmp.dir, "gpio17/value", &buf3));

    // export wrote the pin number to <root>/export.
    var buf4: [8]u8 = undefined;
    try testing.expectEqualStrings("17", try readSmall(io, tmp.dir, "export", &buf4));
}

test "SysfsGpio.setValue: missing pin dir errors (no crash)" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);

    const gpio = SysfsGpio{ .io = io, .root = root };
    // No gpio99 dir → writing direction fails; must return an error, not crash.
    try testing.expectError(error.FileNotFound, gpio.setValue(99, true));
}

test "SysfsGpio.setValue: a root longer than a path errors without allocating" {
    const long_root: [Dir.max_path_bytes]u8 = @splat('x');
    const gpio = SysfsGpio{ .io = testing.io, .root = &long_root };
    try testing.expectError(error.NoSpaceLeft, gpio.setValue(1, true));
}

test "fuzz SysfsGpio.setValue: arbitrary pins never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var buf: [5]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const pin = std.mem.readInt(u32, buf[0..4], .little);
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            var root_buf: [64]u8 = undefined;
            const root = try std.fmt.bufPrint(&root_buf, "{s}/{s}/nonexistent", .{ testing.TmpDir.parent_dir_path, &tmp.sub_path });
            const gpio = SysfsGpio{ .io = io, .root = root };
            // Nonexistent root → always errors, never crashes.
            try testing.expectError(error.FileNotFound, gpio.setValue(pin, buf[4] & 1 == 1));
        }
    }.run, .{});
}
