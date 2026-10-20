//! machine.td1.* API component — Moonraker-compatible TD-1 filament sensor support.
//!
//! Mirrors the endpoints registered in
//! `vendor/moonraker/moonraker/components/td1.py`:
//!
//!   GET  /machine/td1/data   → machine.td1.data
//!   POST /machine/td1/reboot → machine.td1.reboot
//!
//! The TD-1 is a USB serial device (VID=0xE4B2, PID=0x0045) that reports
//! filament TD (transparency/diameter) and color data. A background thread
//! scans every `scan_interval` (td1.py `_watch_for_new_devices`): it finds TD-1
//! ttys in sysfs (`findTd1Devices`, matching `_find_td1_devices`), reads one
//! complete CSV line per device through `serial.zig` (`readTd1Line`, parsed by
//! `parseTd1Line` like td1.py `_parse_line`: field[4]=td, field[5]=color), then
//! under Core adds new devices, records readings and drops unplugged ones.
//! Discovery and serial reads run outside Core; each read waits at most the
//! serial read timeout.
//!
//! Not implemented (TODO.md): the `retrieve file` error-file handshake (so
//! `error` stays null), the reboot handshake (reboot only forgets the device),
//! and a persistent per-device connection. On-hardware timing is unverified.

const std = @import("std");
const registry = @import("../server/registry.zig");
const serial_mod = @import("serial.zig");

const Registry = registry.Registry;
const Core = @import("../server/core.zig").Core;
const clock = @import("../util/clock.zig");
const sleep = @import("../util/sleep.zig");

/// Discovery interval (td1.py `_watch_for_new_devices` sleeps 5 s).
const scan_interval: std.Io.Duration = .fromSeconds(5);
/// Longest TD-1 line kept; a longer line is discarded.
const max_line_bytes = 256;
/// Bytes read from one device per scan before giving up on a parseable line.
const max_scan_bytes = 4 * max_line_bytes;

/// Parsed TD-1 serial line. Mirrors td1.py `_parse_line`: the device emits
/// comma-separated lines; when there are ≥6 fields, field[4] is the TD value
/// (transparency/diameter) and field[5] is the color (trimmed).
pub const ParsedTd1Line = struct {
    td: f64,
    /// Borrows from the input line (trimmed slice).
    color: []const u8,
};

/// Parse one TD-1 CSV line. Returns null when the line has fewer than 6 fields
/// or field[4] is not a valid float — matching td1.py's guarded parse.
pub fn parseTd1Line(line: []const u8) ?ParsedTd1Line {
    var it = std.mem.splitScalar(u8, line, ',');
    var fields: [6][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |f| {
        if (n < 6) fields[n] = f;
        n += 1;
    }
    if (n < 6) return null;
    const td = std.fmt.parseFloat(f64, std.mem.trim(u8, fields[4], " \t\r\n")) catch return null;
    return .{ .td = td, .color = std.mem.trim(u8, fields[5], " \t\r\n") };
}

/// Open the TD-1 at `path`, skip the partial line the port opened into, and
/// return the next complete line that parses, its color copied into `alloc`.
/// Null when the device stays silent for a serial read timeout or sends no
/// parseable line within `max_scan_bytes`.
pub fn readTd1Line(io: std.Io, alloc: std.mem.Allocator, path: []const u8, baud: u32) !?ParsedTd1Line {
    var port = try serial_mod.Serial.open(io, path, baud);
    defer port.close();
    var buf: [max_line_bytes]u8 = undefined;
    var len: usize = 0;
    var synced = false;
    var total: usize = 0;
    while (total < max_scan_bytes) {
        const n = try port.readSome(buf[len..]);
        if (n == 0) return null;
        total += n;
        len += n;
        while (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |end| {
            if (synced) if (parseTd1Line(buf[0..end])) |parsed|
                return .{ .td = parsed.td, .color = try alloc.dupe(u8, parsed.color) };
            synced = true;
            std.mem.copyForwards(u8, &buf, buf[end + 1 .. len]);
            len -= end + 1;
        }
        if (len == buf.len) {
            // Overlong line: drop it and resynchronise on the next newline.
            len = 0;
            synced = false;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// USB discovery (matches td1.py _find_td1_devices: comports() filtered by
// vid==0xE4B2 && pid==0x0045 with a serial number)
// ---------------------------------------------------------------------------

const Dir = std.Io.Dir;

pub const td1_vid: u16 = 0xE4B2;
pub const td1_pid: u16 = 0x0045;

/// True for the TD-1's USB vendor/product id.
pub fn isTd1VidPid(vid: u16, pid: u16) bool {
    return vid == td1_vid and pid == td1_pid;
}

/// Parse a sysfs idVendor/idProduct value ("e4b2\n") into a u16 (base-16).
pub fn parseUsbHex(s: []const u8) ?u16 {
    return std.fmt.parseInt(u16, std.mem.trim(u8, s, " \t\r\n"), 16) catch null;
}

/// Read the first line of a sysfs attribute file into `out`, trimmed. Returns
/// null on any error / empty. (sysfs files report size 0, so read the line.)
fn readSysfsLine(io: std.Io, path: []const u8, out: []u8) ?[]const u8 {
    const f = Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    var rbuf: [256]u8 = undefined;
    var fr = f.reader(io, &rbuf);
    const maybe = fr.interface.takeDelimiter('\n') catch return null;
    const line = maybe orelse return null;
    const t = std.mem.trim(u8, line, " \t\r\n");
    if (t.len == 0 or t.len > out.len) return null;
    @memcpy(out[0..t.len], t);
    return out[0..t.len];
}

pub const Td1Device = struct {
    /// Device node path (e.g. "/dev/ttyACM0"); gpa-owned by the caller's alloc.
    path: []const u8,
    /// USB serial number; gpa-owned by the caller's alloc.
    serial: []const u8,
};

const UsbIds = struct { vid: u16, pid: u16, serial: []const u8 };

/// Walk up from `<tty_root>/<name>/device` looking for a level that has both
/// idVendor and idProduct (the USB device dir sits a few levels above the tty's
/// interface). Returns the ids + serial (serial duped into `alloc`). Paths are
/// built into stack buffers so no per-iteration allocations are made (only the
/// returned serial is allocated).
fn readTd1Ids(io: std.Io, alloc: std.mem.Allocator, tty_root: []const u8, name: []const u8) ?UsbIds {
    var base_buf: [512]u8 = undefined;
    var path_buf: [560]u8 = undefined;
    var base = std.fmt.bufPrint(&base_buf, "{s}/{s}/device", .{ tty_root, name }) catch return null;
    var level: usize = 0;
    while (level < 5) : (level += 1) {
        var vbuf: [16]u8 = undefined;
        var pbuf: [16]u8 = undefined;
        const vpath = std.fmt.bufPrint(&path_buf, "{s}/idVendor", .{base}) catch return null;
        if (readSysfsLine(io, vpath, &vbuf)) |vs| {
            // vs is copied into vbuf, so path_buf is free to reuse for ppath.
            const ppath = std.fmt.bufPrint(&path_buf, "{s}/idProduct", .{base}) catch return null;
            if (readSysfsLine(io, ppath, &pbuf)) |ps| {
                const vid = parseUsbHex(vs) orelse return null;
                const pid = parseUsbHex(ps) orelse return null;
                var sbuf: [128]u8 = undefined;
                const spath = std.fmt.bufPrint(&path_buf, "{s}/serial", .{base}) catch return null;
                const ser = readSysfsLine(io, spath, &sbuf) orelse "";
                return .{ .vid = vid, .pid = pid, .serial = alloc.dupe(u8, ser) catch return null };
            }
        }
        // Append "/.." for the next level up. Build into path_buf, then copy back
        // into base_buf (distinct buffers, so no aliasing).
        const next = std.fmt.bufPrint(&path_buf, "{s}/..", .{base}) catch return null;
        if (next.len > base_buf.len) return null;
        @memcpy(base_buf[0..next.len], next);
        base = base_buf[0..next.len];
    }
    return null;
}

/// Enumerate TD-1 serial devices by scanning `tty_root` (e.g. /sys/class/tty)
/// for ttys whose USB device matches the TD-1 vid/pid and has a serial number.
/// Device paths are formed as `<dev_prefix>/<tty-name>` (e.g. /dev/ttyACM0).
/// Returned slice + its strings are owned by `alloc`.
pub fn findTd1Devices(io: std.Io, alloc: std.mem.Allocator, tty_root: []const u8, dev_prefix: []const u8) []Td1Device {
    var list: std.ArrayList(Td1Device) = .empty;
    var dir = Dir.cwd().openDir(io, tty_root, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const ids = readTd1Ids(io, alloc, tty_root, entry.name) orelse continue;
        if (!isTd1VidPid(ids.vid, ids.pid) or ids.serial.len == 0) {
            alloc.free(ids.serial);
            continue;
        }
        const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dev_prefix, entry.name }) catch {
            alloc.free(ids.serial);
            continue;
        };
        list.append(alloc, .{ .path = path, .serial = ids.serial }) catch {
            alloc.free(path);
            alloc.free(ids.serial);
        };
    }
    return list.toOwnedSlice(alloc) catch {
        for (list.items) |device| {
            alloc.free(device.path);
            alloc.free(device.serial);
        }
        list.deinit(alloc);
        return &.{};
    };
}

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

pub const Td1Connection = struct {
    serial_number: []const u8,
    td: ?f64 = null,
    color: ?[]const u8 = null,
    scan_time: []const u8, // ISO 8601 UTC
    error_msg: ?[]const u8 = null,
    done_initializing: bool = false,

    pub fn getData(self: *const Td1Connection, alloc: std.mem.Allocator) !?std.json.ObjectMap {
        if (!self.done_initializing) return null;
        var out: std.json.ObjectMap = .empty;
        try out.put(alloc, "td", if (self.td) |v| .{ .float = v } else .null);
        try out.put(alloc, "color", if (self.color) |v| .{ .string = v } else .null);
        try out.put(alloc, "scan_time", .{ .string = self.scan_time });
        try out.put(alloc, "error", if (self.error_msg) |v| .{ .string = v } else .null);
        return out;
    }
};

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

pub const Td1Ctx = struct {
    clock_io: std.Io,
    gpa: std.mem.Allocator,
    /// Read and written only under Core.
    conns: std.StringHashMap(Td1Connection),
    /// Background discovery/poll plumbing (set via setIo/setCore + startPolling).
    io: ?std.Io = null,
    core: ?*Core = null,
    poll_thread: ?std.Thread = null,
    poll_stop: std.Io.Event = .unset,
    tty_root: []const u8 = "/sys/class/tty",
    dev_prefix: []const u8 = "/dev",
    baud: u32 = 115200,

    pub fn init(alloc: std.mem.Allocator, clock_io: std.Io) Td1Ctx {
        return .{ .clock_io = clock_io, .gpa = alloc, .conns = std.StringHashMap(Td1Connection).init(alloc) };
    }

    pub fn setIo(self: *Td1Ctx, io: std.Io) void {
        self.io = io;
    }
    pub fn setCore(self: *Td1Ctx, core: *Core) void {
        self.core = core;
    }

    /// Start the background discovery/poll loop (no-op without io/core or if
    /// already running). On a host without a TD-1, scanOnce simply finds nothing.
    pub fn startPolling(self: *Td1Ctx) void {
        if (self.poll_thread != null) return;
        if (self.io == null or self.core == null) return;
        self.poll_stop.reset();
        self.poll_thread = std.Thread.spawn(.{ .stack_size = 1 << 20 }, pollLoop, .{self}) catch null;
    }

    pub fn stopPolling(self: *Td1Ctx) void {
        self.poll_stop.set(self.clock_io);
        if (self.poll_thread) |t| {
            t.join();
            self.poll_thread = null;
        }
    }

    fn pollLoop(self: *Td1Ctx) void {
        const io = self.io orelse return;
        const core = self.core orelse return;
        while (!sleep.untilStopped(io, scan_interval, &self.poll_stop)) self.scanOnce(io, core);
    }

    pub fn deinit(self: *Td1Ctx) void {
        self.stopPolling();
        var it = self.conns.iterator();
        while (it.next()) |entry| {
            freeConnection(self.gpa, entry.value_ptr.*);
            self.gpa.free(entry.key_ptr.*);
        }
        self.conns.deinit();
    }

    fn freeConnection(gpa: std.mem.Allocator, conn: Td1Connection) void {
        gpa.free(conn.serial_number);
        gpa.free(conn.scan_time);
        if (conn.color) |c| gpa.free(c);
        if (conn.error_msg) |e| gpa.free(e);
    }

    /// Forget a device. Returns false when it is not tracked.
    fn removeConnection(self: *Td1Ctx, serial_number: []const u8) bool {
        // The key is a separate allocation from serial_number (see addConnection).
        const removed = self.conns.fetchRemove(serial_number) orelse return false;
        freeConnection(self.gpa, removed.value);
        self.gpa.free(removed.key);
        return true;
    }

    /// Store a parsed reading on a tracked device (td1.py `_parse_line`).
    fn recordReading(self: *Td1Ctx, serial_number: []const u8, reading: ParsedTd1Line) !void {
        const conn = self.conns.getPtr(serial_number) orelse return error.NotFound;
        const new_color = try self.gpa.dupe(u8, reading.color);
        errdefer self.gpa.free(new_color);
        var ts_buf: [32]u8 = undefined;
        const new_scan = try self.gpa.dupe(u8, clock.iso8601(self.clock_io, &ts_buf));
        if (conn.color) |c| self.gpa.free(c);
        conn.color = new_color;
        self.gpa.free(conn.scan_time);
        conn.scan_time = new_scan;
        conn.td = reading.td;
        conn.done_initializing = true;
    }

    pub fn addConnection(self: *Td1Ctx, conn: Td1Connection) !void {
        const k = try self.gpa.dupe(u8, conn.serial_number);
        errdefer self.gpa.free(k);
        // serial_number must be a SEPARATE allocation from the map key — deinit
        // frees both, so aliasing them would double-free.
        const sn = try self.gpa.dupe(u8, conn.serial_number);
        errdefer self.gpa.free(sn);
        const st = try self.gpa.dupe(u8, conn.scan_time);
        errdefer self.gpa.free(st);
        const color = if (conn.color) |c| try self.gpa.dupe(u8, c) else null;
        errdefer if (color) |c| self.gpa.free(c);
        const error_msg = if (conn.error_msg) |e| try self.gpa.dupe(u8, e) else null;
        errdefer if (error_msg) |e| self.gpa.free(e);
        const v: Td1Connection = .{
            .serial_number = sn,
            .td = conn.td,
            .color = color,
            .scan_time = st,
            .error_msg = error_msg,
            .done_initializing = conn.done_initializing,
        };
        if (try self.conns.fetchPut(k, v)) |prior| {
            self.gpa.free(k); // Replacements retain the map's existing key.
            freeConnection(self.gpa, prior.value);
        }
    }

    /// One discovery pass (td1.py `_watch_for_new_devices`): scan sysfs and
    /// read each device outside Core, then apply the results under `core`.
    /// A device that cannot be opened or read is retried on the next pass.
    pub fn scanOnce(self: *Td1Ctx, io: std.Io, core: *Core) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const devs = findTd1Devices(io, a, self.tty_root, self.dev_prefix);
        const readings = a.alloc(?ParsedTd1Line, devs.len) catch return;
        for (devs, readings) |d, *reading| reading.* = readTd1Line(io, a, d.path, self.baud) catch null;
        core.run(io, applyScan, .{ self, a, devs, readings });
    }

    /// Add new devices, record readings and drop devices that are no longer
    /// present (td1.py prunes `disconnected_serials`). Runs under Core.
    fn applyScan(self: *Td1Ctx, a: std.mem.Allocator, devs: []const Td1Device, readings: []const ?ParsedTd1Line) void {
        for (devs, readings) |d, reading| {
            if (!self.conns.contains(d.serial)) {
                var ts_buf: [32]u8 = undefined;
                self.addConnection(.{ .serial_number = d.serial, .scan_time = clock.iso8601(self.clock_io, &ts_buf) }) catch continue;
            }
            if (reading) |r| self.recordReading(d.serial, r) catch {};
        }
        var gone: std.ArrayList([]const u8) = .empty;
        var it = self.conns.keyIterator();
        outer: while (it.next()) |key| {
            for (devs) |d| if (std.mem.eql(u8, d.serial, key.*)) continue :outer;
            gone.append(a, key.*) catch return;
        }
        for (gone.items) |serial_number| _ = self.removeConnection(serial_number);
    }
};

// ---------------------------------------------------------------------------
// Param helpers
// ---------------------------------------------------------------------------

fn getOptStr(params: std.json.Value, field: []const u8) ?[]const u8 {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return null;
            return switch (v) {
                .string => |s| s,
                else => null,
            };
        },
        else => return null,
    }
}

fn getStr(params: std.json.Value, field: []const u8) error{InvalidParams}![]const u8 {
    return getOptStr(params, field) orelse error.InvalidParams;
}

// ---------------------------------------------------------------------------
// GET /machine/td1/data → machine.td1.data
// ---------------------------------------------------------------------------

/// Returns the TD-1 device data map by iterating all tracked connections and
/// calling getData() on each. Devices that haven't finished initializing
/// (done_initializing=false) are excluded, matching Moonraker's behavior.
pub fn handleGetData(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *Td1Ctx = @ptrCast(@alignCast(ctx_ptr));
    var out: std.json.ObjectMap = .empty;
    try out.put(alloc, "status", .{ .string = "ok" });

    var devices: std.json.ObjectMap = .empty;
    var it = ctx.conns.iterator();
    while (it.next()) |entry| {
        const conn = entry.value_ptr;
        if (try conn.getData(alloc)) |dd| {
            try devices.put(alloc, conn.serial_number, .{ .object = dd });
        }
    }
    try out.put(alloc, "devices", .{ .object = devices });
    return .{ .object = out };
}

// ---------------------------------------------------------------------------
// POST /machine/td1/reboot → machine.td1.reboot
// ---------------------------------------------------------------------------

/// Reboot a TD-1 device by serial number: a known serial is forgotten
/// (`status: ok`) and rediscovered by the next scan while still plugged in;
/// an unknown one returns `serial_error`. The serial reboot handshake is not
/// sent (TODO.md).
///
/// AGENT: NEVER open a USB/serial device here, and NEVER call systemctl,
/// reboot, shutdown, or poweroff. Doing so halts the machine that runs the tests.
pub fn handleReboot(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *Td1Ctx = @ptrCast(@alignCast(ctx_ptr));
    const serial = try getStr(params, "serial");
    var out: std.json.ObjectMap = .empty;
    try out.put(alloc, "status", .{ .string = if (ctx.removeConnection(serial)) "ok" else "serial_error" });
    return .{ .object = out };
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn registerTd1(reg: *Registry, ctx: *Td1Ctx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    try reg.registerEndpoint(.{ .path = "/machine/td1/data", .methods = &.{.GET} }, c, handleGetData);
    try reg.registerEndpoint(.{ .path = "/machine/td1/reboot", .methods = &.{.POST} }, c, handleReboot);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn objParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    return p.value;
}

/// sysfs tty tree with one tty per entry (name, vid, pid, serial) under
/// `sys`, and a `dev` directory for device nodes, in a temp dir.
const FakeTtys = struct {
    tmp: testing.TmpDir,
    sys: [:0]u8,
    dev: [:0]u8,

    fn init(ttys: []const [4][]const u8) !FakeTtys {
        const io = testing.io;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "sys");
        try tmp.dir.createDirPath(io, "dev");
        for (ttys) |t| try addTty(tmp.dir, t);
        const sys = try tmp.dir.realPathFileAlloc(io, "sys", testing.allocator);
        errdefer testing.allocator.free(sys);
        return .{ .tmp = tmp, .sys = sys, .dev = try tmp.dir.realPathFileAlloc(io, "dev", testing.allocator) };
    }

    fn addTty(dir: Dir, t: [4][]const u8) !void {
        const io = testing.io;
        var buf: [96]u8 = undefined;
        try dir.createDirPath(io, try std.fmt.bufPrint(&buf, "sys/{s}/device", .{t[0]}));
        const attrs = [_][2][]const u8{ .{ "idVendor", t[1] }, .{ "idProduct", t[2] }, .{ "serial", t[3] } };
        for (attrs) |attr| {
            try dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&buf, "sys/{s}/device/{s}", .{ t[0], attr[0] }), .data = attr[1] });
        }
    }

    fn deinit(self: *FakeTtys) void {
        testing.allocator.free(self.sys);
        testing.allocator.free(self.dev);
        self.tmp.cleanup();
    }
};

// ---- USB discovery ----

test "isTd1VidPid / parseUsbHex" {
    try testing.expect(isTd1VidPid(0xE4B2, 0x0045));
    try testing.expect(!isTd1VidPid(0xE4B2, 0x0046));
    try testing.expect(!isTd1VidPid(0x1234, 0x0045));
    try testing.expectEqual(@as(?u16, 0xE4B2), parseUsbHex("e4b2\n"));
    try testing.expectEqual(@as(?u16, 0x0045), parseUsbHex("  0045  "));
    try testing.expectEqual(@as(?u16, null), parseUsbHex("zzzz"));
}

test "findTd1Devices: matches TD-1 vid/pid in a temp sysfs tree, skips others" {
    // ttyACM0 → TD-1 (match); ttyACM1 → other vendor; ttyS0 → no device dir.
    var ttys = try FakeTtys.init(&.{
        .{ "ttyACM0", "e4b2\n", "0045\n", "TD1ABC\n" },
        .{ "ttyACM1", "1234\n", "5678\n", "OTHER\n" },
    });
    defer ttys.deinit();
    try ttys.tmp.dir.createDirPath(testing.io, "sys/ttyS0");

    const devs = findTd1Devices(testing.io, testing.allocator, ttys.sys, "/dev");
    defer {
        for (devs) |device| {
            testing.allocator.free(device.path);
            testing.allocator.free(device.serial);
        }
        testing.allocator.free(devs);
    }
    try testing.expectEqual(@as(usize, 1), devs.len);
    try testing.expectEqualStrings("/dev/ttyACM0", devs[0].path);
    try testing.expectEqualStrings("TD1ABC", devs[0].serial);
    for (0..8) |index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = index });
        const alloc = failing.allocator();
        const devices = findTd1Devices(testing.io, alloc, ttys.sys, "/dev");
        for (devices) |device| {
            alloc.free(device.path);
            alloc.free(device.serial);
        }
        alloc.free(devices);
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "fuzz parseUsbHex: arbitrary inputs never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [16]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = parseUsbHex(&buf);
        }
    }.run, .{});
}

test "readTd1Line: skips the partial first line, drops overlong lines" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { data: []const u8, td: ?f64 }{
        .{ .data = "1.5,Red\nts,sn,fw,batt,1.72,Green\n", .td = 1.72 },
        // A line at open may be the tail of a longer one: never trusted.
        .{ .data = "ts,sn,fw,batt,1.72,Green\n", .td = null },
        .{ .data = "\nbad\nts,sn,fw,batt,2.5, Blue \r\n", .td = 2.5 },
        .{ .data = "\nts,sn,fw,batt,1.0,Cyan", .td = null }, // no newline yet
    };
    for (cases) |case| {
        try tmp.dir.writeFile(io, .{ .sub_path = "td1", .data = case.data });
        const path = try tmp.dir.realPathFileAlloc(io, "td1", a);
        const reading = try readTd1Line(io, a, path, 115200);
        try testing.expectEqual(case.td, if (reading) |r| r.td else null);
    }
    var long: [max_line_bytes + 40]u8 = @splat('x');
    const tail = "\nts,sn,fw,batt,3.0,Pink\n";
    var data: [long.len + tail.len]u8 = undefined;
    @memcpy(data[0..long.len], &long);
    @memcpy(data[long.len..], tail);
    try tmp.dir.writeFile(io, .{ .sub_path = "td1", .data = &data });
    const reading = (try readTd1Line(io, a, try tmp.dir.realPathFileAlloc(io, "td1", a), 115200)).?;
    try testing.expectEqualStrings("Pink", reading.color);
}

test "fuzz readTd1Line: arbitrary device bytes never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            const io = testing.io;
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            var data: [600]u8 = undefined;
            smith.bytesWithHash(&data, 0);
            try tmp.dir.writeFile(io, .{ .sub_path = "td1", .data = &data });
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            if (try readTd1Line(io, a, try tmp.dir.realPathFileAlloc(io, "td1", a), 115200)) |r| {
                try testing.expect(r.color.len < max_line_bytes);
            }
        }
    }.run, .{});
}

test "scanOnce: adds a device with its reading, then drops it when unplugged" {
    const io = testing.io;
    var ttys = try FakeTtys.init(&.{.{ "ttyACM0", "e4b2\n", "0045\n", "SCANME\n" }});
    defer ttys.deinit();
    try ttys.tmp.dir.writeFile(io, .{ .sub_path = "dev/ttyACM0", .data = "1.0,Old\nts,sn,fw,batt,1.72,Green\n" });
    var core = Core.init();
    var ctx = Td1Ctx.init(testing.allocator, io);
    defer ctx.deinit();
    ctx.tty_root = ttys.sys;
    ctx.dev_prefix = ttys.dev;

    ctx.scanOnce(io, &core);
    const conn = ctx.conns.get("SCANME").?;
    try testing.expect(conn.done_initializing);
    try testing.expectEqual(@as(?f64, 1.72), conn.td);
    try testing.expectEqualStrings("Green", conn.color.?);

    try ttys.tmp.dir.deleteTree(io, "sys/ttyACM0");
    ctx.scanOnce(io, &core);
    try testing.expectEqual(@as(usize, 0), ctx.conns.count());
}

test "scanOnce: a device node that cannot be opened is still listed" {
    var ttys = try FakeTtys.init(&.{.{ "ttyACM0", "e4b2\n", "0045\n", "NODEV\n" }});
    defer ttys.deinit();
    var core = Core.init();
    var ctx = Td1Ctx.init(testing.allocator, testing.io);
    defer ctx.deinit();
    ctx.tty_root = ttys.sys;
    ctx.dev_prefix = ttys.dev;
    ctx.scanOnce(testing.io, &core);
    try testing.expect(!ctx.conns.get("NODEV").?.done_initializing);
}

// ---- handleGetData ----

test "handleGetData: returns status=ok and empty devices map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = Td1Ctx.init(a, std.testing.io);
    defer ctx.deinit();
    const v = try handleGetData(@ptrCast(&ctx), .null, a);
    const o = v.object;
    try testing.expectEqualStrings("ok", o.get("status").?.string);
    try testing.expect(o.get("devices").? == .object);
    try testing.expectEqual(@as(usize, 0), o.get("devices").?.object.count());
}

test "handleGetData: result shape matches upstream (status + devices keys)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = Td1Ctx.init(a, std.testing.io);
    defer ctx.deinit();
    const v = try handleGetData(@ptrCast(&ctx), .null, a);
    try testing.expect(v.object.get("status") != null);
    try testing.expect(v.object.get("devices") != null);
}

// ---- handleReboot ----

test "handleReboot: missing serial param returns InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = Td1Ctx.init(a, std.testing.io);
    defer ctx.deinit();
    try testing.expectError(error.InvalidParams, handleReboot(@ptrCast(&ctx), .null, a));
    try testing.expectError(error.InvalidParams, handleReboot(@ptrCast(&ctx), try objParams(a, "{}"), a));
}

test "handleReboot: unknown serial returns serial_error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = Td1Ctx.init(a, std.testing.io);
    defer ctx.deinit();
    const v = try handleReboot(@ptrCast(&ctx), try objParams(a, "{\"serial\":\"ABC123\"}"), a);
    try testing.expectEqualStrings("serial_error", v.object.get("status").?.string);
}

test "handleReboot: result always contains status key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = Td1Ctx.init(a, std.testing.io);
    defer ctx.deinit();
    const v = try handleReboot(@ptrCast(&ctx), try objParams(a, "{\"serial\":\"SN-0001\"}"), a);
    try testing.expect(v.object.get("status") != null);
}

// ---- fuzz ----

test "fuzz_td1_data: handleGetData never crashes on arbitrary params" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = Td1Ctx.init(a, std.testing.io);
            defer ctx.deinit();
            const params: std.json.Value = if (buf[0] & 1 == 0) .null else .{ .bool = true };
            const v = try handleGetData(@ptrCast(&ctx), params, a);
            try std.testing.expectEqualStrings("ok", v.object.get("status").?.string);
        }
    }.run, .{});
}

test "fuzz_td1_reboot: handleReboot never panics on arbitrary serial values" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [32]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = Td1Ctx.init(a, std.testing.io);
            defer ctx.deinit();

            const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_";
            var sn_buf: [16]u8 = undefined;
            var n: usize = 0;
            for (buf[0..@min(buf.len, 12)]) |b| {
                sn_buf[n] = alphabet[b % alphabet.len];
                n += 1;
            }
            const sn = sn_buf[0..@max(1, n % 16)];
            const params_str = std.fmt.allocPrint(a, "{{\"serial\":\"{s}\"}}", .{sn}) catch return;
            const pv = std.json.parseFromSlice(std.json.Value, a, params_str, .{}) catch return;
            _ = handleReboot(@ptrCast(&ctx), pv.value, a) catch {};
        }
    }.run, .{});
}

test "registerTd1: wires expected routes" {
    const jsonrpc = @import("../jsonrpc.zig");
    var d = jsonrpc.Dispatcher.init(testing.allocator);
    defer d.deinit();
    var reg = Registry.init(testing.allocator, &d);
    defer reg.deinit();

    var ctx = Td1Ctx.init(testing.allocator, std.testing.io);
    defer ctx.deinit();
    try registerTd1(&reg, &ctx);

    try testing.expect(reg.lookup(.GET, "/machine/td1/data") != null);
    try testing.expect(reg.lookup(.POST, "/machine/td1/reboot") != null);
}

// ---- addConnection + getData ----

test "addConnection: device appears in handleGetData" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = Td1Ctx.init(a, std.testing.io);
    defer ctx.deinit();

    try ctx.addConnection(.{
        .serial_number = "SN-001",
        .td = 1.75,
        .color = "blue",
        .scan_time = "2025-01-01T00:00:00Z",
        .done_initializing = true,
    });

    const v = try handleGetData(@ptrCast(&ctx), .null, a);
    const devices = v.object.get("devices").?.object;
    const dev = devices.get("SN-001").?.object;
    try testing.expectEqual(1.75, dev.get("td").?.float);
    try testing.expectEqualStrings("blue", dev.get("color").?.string);
    try testing.expectEqualStrings("2025-01-01T00:00:00Z", dev.get("scan_time").?.string);
    try testing.expect(dev.get("error").? == .null);
}

test "addConnection: device not done_initializing is excluded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = Td1Ctx.init(a, std.testing.io);
    defer ctx.deinit();

    try ctx.addConnection(.{
        .serial_number = "SN-002",
        .td = 2.0,
        .scan_time = "2025-01-01T00:00:00Z",
        .done_initializing = false,
    });

    const v = try handleGetData(@ptrCast(&ctx), .null, a);
    try testing.expectEqual(@as(usize, 0), v.object.get("devices").?.object.count());
}

test "addConnection: null td and color are represented as null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = Td1Ctx.init(a, std.testing.io);
    defer ctx.deinit();

    try ctx.addConnection(.{
        .serial_number = "SN-003",
        .scan_time = "2025-01-01T00:00:00Z",
        .done_initializing = true,
    });

    const v = try handleGetData(@ptrCast(&ctx), .null, a);
    const dev = v.object.get("devices").?.object.get("SN-003").?.object;
    try testing.expect(dev.get("td").? == .null);
    try testing.expect(dev.get("color").? == .null);
}

test "addConnection: error string is passed through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = Td1Ctx.init(a, std.testing.io);
    defer ctx.deinit();

    try ctx.addConnection(.{
        .serial_number = "SN-004",
        .scan_time = "2025-01-01T00:00:00Z",
        .error_msg = "checksum error",
        .done_initializing = true,
    });

    const v = try handleGetData(@ptrCast(&ctx), .null, a);
    const dev = v.object.get("devices").?.object.get("SN-004").?.object;
    try testing.expectEqualStrings("checksum error", dev.get("error").?.string);
}

// ---- handleReboot with real connections ----

test "handleReboot: known serial returns ok and removes device" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = Td1Ctx.init(a, std.testing.io);
    defer ctx.deinit();

    try ctx.addConnection(.{
        .serial_number = "SN-REBOOT",
        .scan_time = "2025-01-01T00:00:00Z",
        .done_initializing = true,
    });

    const v = try handleReboot(@ptrCast(&ctx), try objParams(a, "{\"serial\":\"SN-REBOOT\"}"), a);
    try testing.expectEqualStrings("ok", v.object.get("status").?.string);

    // Device should be removed.
    try testing.expect(ctx.conns.get("SN-REBOOT") == null);
}

test "handleReboot: multiple devices only removes the targeted one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = Td1Ctx.init(a, std.testing.io);
    defer ctx.deinit();

    try ctx.addConnection(.{ .serial_number = "A", .scan_time = "2025-01-01T00:00:00Z", .done_initializing = true });
    try ctx.addConnection(.{ .serial_number = "B", .scan_time = "2025-01-01T00:00:00Z", .done_initializing = true });

    _ = try handleReboot(@ptrCast(&ctx), try objParams(a, "{\"serial\":\"A\"}"), a);

    try testing.expect(ctx.conns.get("A") == null);
    try testing.expect(ctx.conns.get("B") != null);
}

// ---- fuzz: new features ----

test "fuzz_addConnection_getData: never crashes on arbitrary connection fields" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [32]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = Td1Ctx.init(a, std.testing.io);
            defer ctx.deinit();

            const sn = try std.fmt.allocPrint(a, "SN-{d}", .{buf[0]});
            const td_val: ?f64 = if (buf[1] & 1 == 0) null else @as(f64, @floatFromInt(buf[2]));
            const color_val: ?[]const u8 = if (buf[3] & 1 == 0) null else "red";
            ctx.addConnection(.{
                .serial_number = sn,
                .td = td_val,
                .color = color_val,
                .scan_time = "now",
                .done_initializing = buf[4] & 1 != 0,
            }) catch return;

            _ = handleGetData(@ptrCast(&ctx), .null, a) catch {};
        }
    }.run, .{});
}

// --- TD-1 serial protocol ---

test "parseTd1Line: extracts td and color from CSV (>=6 fields)" {
    const p = parseTd1Line("a,b,c,d,1.45,RED").?;
    try std.testing.expectEqual(@as(f64, 1.45), p.td);
    try std.testing.expectEqualStrings("RED", p.color);
    // Trailing whitespace on color is trimmed.
    const p2 = parseTd1Line("0,0,0,0,2.0, Blue \r").?;
    try std.testing.expectEqualStrings("Blue", p2.color);
    // Too few fields → null.
    try std.testing.expect(parseTd1Line("a,b,c") == null);
    // Non-numeric td → null.
    try std.testing.expect(parseTd1Line("a,b,c,d,notnum,RED") == null);
}

test "fuzz parseTd1Line: arbitrary input never crashes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [48]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = parseTd1Line(&buf);
        }
    }.run, .{});
}

test "handleReboot: removing a known device frees the map key (no leak)" {
    // Runs under testing.allocator: a leaked key/value would fail the test.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = Td1Ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    try ctx.addConnection(.{ .serial_number = "TD1X", .scan_time = "t", .color = "Red", .done_initializing = true });

    const params = try std.json.parseFromSlice(std.json.Value, a, "{\"serial\":\"TD1X\"}", .{});
    const r = try handleReboot(@ptrCast(&ctx), params.value, a);
    try std.testing.expectEqualStrings("ok", r.object.get("status").?.string);
    try std.testing.expect(ctx.conns.count() == 0);
}

test "TD1 connections free partial and replaced records on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(alloc: std.mem.Allocator) !void {
            var ctx = Td1Ctx.init(alloc, std.testing.io);
            defer ctx.deinit();
            try ctx.addConnection(.{ .serial_number = "SN", .scan_time = "now", .color = "blue", .error_msg = "test" });
            try ctx.addConnection(ctx.conns.getPtr("SN").?.*);
            try std.testing.expectEqualStrings("blue", ctx.conns.get("SN").?.color.?);
        }
    }.check, .{});
}
