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
//! discovers ttys every five seconds and owns one persistent serial reader per
//! device. Readers retrieve errors.txt before exposing nullable readings and
//! record CSV updates under Core. Device reboot uses the TD-1 settings protocol,
//! never host reboot commands. Every reader is stopped and joined on removal.
//! Protocol tests use pseudo-terminals; physical device timing is unverified.

const std = @import("std");
const webreq = @import("../json/params.zig");
const registry = @import("../server/registry.zig");
const serial_mod = @import("serial.zig");

const Registry = registry.Registry;
const Core = @import("../server/core.zig").Core;
const sleep = @import("../util/sleep.zig");

/// Discovery interval (td1.py `_watch_for_new_devices` sleeps 5 s).
const scan_interval: std.Io.Duration = .fromSeconds(5);

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
    if (!std.unicode.utf8ValidateSlice(line)) return null;
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
        if (list.items.len == max_devices) break;
        const ids = readTd1Ids(io, alloc, tty_root, entry.name) orelse continue;
        if (!isTd1VidPid(ids.vid, ids.pid) or ids.serial.len == 0 or !std.unicode.utf8ValidateSlice(ids.serial)) {
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

/// Moonraker uses UTC datetime.isoformat() followed by an extra `Z`.
pub fn scanTimestamp(io: std.Io, buf: []u8) []const u8 {
    const ns = @max(0, std.Io.Clock.real.now(io).toNanoseconds());
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, @divFloor(ns, std.time.ns_per_s))) };
    const yd = seconds.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = seconds.getDaySeconds();
    const micros: u32 = @intCast(@divFloor(@mod(ns, std.time.ns_per_s), std.time.ns_per_us));
    const prefix = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        yd.year,              md.month.numeric(),      @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch return "1970-01-01T00:00:00+00:00Z";
    const tail = if (micros == 0)
        std.fmt.bufPrint(buf[prefix.len..], "+00:00Z", .{})
    else
        std.fmt.bufPrint(buf[prefix.len..], ".{d:0>6}+00:00Z", .{micros});
    return buf[0 .. prefix.len + (tail catch return "1970-01-01T00:00:00+00:00Z").len];
}

const protocol_timeout: std.Io.Duration = .fromSeconds(5);
const reboot_wait: std.Io.Duration = .fromSeconds(10);
const max_error_bytes = 4096;
const max_error_blocks = 64;
const max_devices = 64;

const Lines = struct {
    bytes: [max_error_bytes]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    /// The returned line includes its newline and borrows until the next call.
    fn next(self: *Lines, reader: *DeviceReader, port: *serial_mod.Serial, deadline: std.Io.Timeout, abort_for_reboot: bool) ![]const u8 {
        while (true) {
            if (reader.stop.isSet()) return error.Canceled;
            if (abort_for_reboot and reader.reboot_requested.load(.acquire)) return error.RebootRequested;
            if (deadline.deadline.untilNow(reader.io).raw.nanoseconds >= 0) return error.Timeout;
            if (std.mem.indexOfScalar(u8, self.bytes[self.start..self.end], '\n')) |at| {
                const line = self.bytes[self.start..][0 .. at + 1];
                self.start += at + 1;
                return line;
            }
            std.mem.copyForwards(u8, &self.bytes, self.bytes[self.start..self.end]);
            self.end -= self.start;
            self.start = 0;
            if (self.end == self.bytes.len) return error.LineTooLong;
            const n = try port.readSomeTimeout(self.bytes[self.end..], deadline);
            self.end += n;
            if (n == 0 and deadline.deadline.untilNow(reader.io).raw.nanoseconds >= 0) return error.Timeout;
        }
    }
};

/// One owner keeps the reader joined; handlers pin it while Core is released.
const DeviceReader = struct {
    ctx: *Td1Ctx,
    io: std.Io,
    core: *Core,
    path: []const u8,
    serial: []const u8,
    baud: u32,
    refs: std.atomic.Value(u32) = .init(1),
    thread: ?std.Thread = null,
    stop: std.Io.Event = .unset,
    finished: std.Io.Event = .unset,
    reboot_requested: std.atomic.Value(bool) = .init(false),
    reboot_ok: std.atomic.Value(bool) = .init(false),

    fn create(ctx: *Td1Ctx, io: std.Io, core: *Core, device: Td1Device) !*DeviceReader {
        const self = try ctx.gpa.create(DeviceReader);
        errdefer ctx.gpa.destroy(self);
        const path = try ctx.gpa.dupe(u8, device.path);
        errdefer ctx.gpa.free(path);
        const serial = try ctx.gpa.dupe(u8, device.serial);
        self.* = .{ .ctx = ctx, .io = io, .core = core, .path = path, .serial = serial, .baud = ctx.baud };
        return self;
    }

    fn retain(self: *DeviceReader) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    fn release(self: *DeviceReader) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        std.debug.assert(self.thread == null);
        const gpa = self.ctx.gpa;
        gpa.free(self.path);
        gpa.free(self.serial);
        gpa.destroy(self);
    }

    fn start(self: *DeviceReader) !void {
        self.thread = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, run, .{self});
    }

    fn stopAndJoin(self: *DeviceReader) void {
        self.stop.set(self.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn deadline(self: *DeviceReader) std.Io.Timeout {
        return (std.Io.Timeout{ .duration = .{ .raw = protocol_timeout, .clock = .awake } }).toDeadline(self.io);
    }

    fn checkErrorFile(self: *DeviceReader, port: *serial_mod.Serial, lines: *Lines) !void {
        while (!self.stop.isSet()) {
            const until = self.deadline();
            try port.writeTimeout("retrieve file\nerrors.txt\n", until);
            const ready = while (true) {
                const raw = lines.next(self, port, until, true) catch |err| {
                    if (err == error.Timeout) break false;
                    return err;
                };
                const ack = std.mem.trim(u8, raw, " \t\r\n");
                if (std.mem.eql(u8, ack, "No file named errors.txt")) {
                    try self.core.run(self.io, Td1Ctx.recordInitialization, .{ self.ctx, self.serial, @as(?[]const u8, null) });
                    return;
                }
                if (std.mem.eql(u8, ack, "ready")) break true;
            };
            if (!ready) continue;
            const size_line = try lines.next(self, port, until, true);
            const size = try std.fmt.parseInt(usize, std.mem.trim(u8, size_line, " \t\r\n"), 10);
            if (size > max_error_bytes) return error.ErrorFileTooLong;
            const blocks_line = try lines.next(self, port, until, true);
            const blocks = try std.fmt.parseInt(usize, std.mem.trim(u8, blocks_line, " \t\r\n"), 10);
            if (blocks > max_error_blocks) return error.TooManyBlocks;
            var content: [max_error_bytes]u8 = undefined;
            var used: usize = 0;
            for (0..blocks) |_| {
                _ = try lines.next(self, port, until, true);
                const block = try lines.next(self, port, until, true);
                if (block.len > content.len - used) return error.ErrorFileTooLong;
                if (!std.unicode.utf8ValidateSlice(block)) return error.InvalidUtf8;
                @memcpy(content[used..][0..block.len], block);
                used += block.len;
                try port.writeTimeout("ready\n", until);
            }
            try self.core.run(self.io, Td1Ctx.recordInitialization, .{ self.ctx, self.serial, @as(?[]const u8, content[0..used]) });
            return;
        }
        return error.Canceled;
    }

    fn reboot(self: *DeviceReader, port: *serial_mod.Serial, lines: *Lines) !void {
        const until = self.deadline();
        try port.writeTimeout("change settings\n", until);
        while (true) {
            const ack = std.mem.trim(u8, try lines.next(self, port, until, false), " \t\r\n");
            if (std.mem.eql(u8, ack, "ready")) break;
        }
        try port.writeTimeout("RGB_Enabled = True\ndone\n", until);
        if (!std.unicode.utf8ValidateSlice(try lines.next(self, port, until, false))) return error.InvalidUtf8;
        self.reboot_ok.store(true, .release);
    }

    fn run(self: *DeviceReader) void {
        defer self.finished.set(self.io);
        var port = serial_mod.Serial.open(self.io, self.path, self.baud) catch return;
        defer port.close();
        var lines: Lines = .{};
        self.checkErrorFile(&port, &lines) catch |err| {
            if (err != error.RebootRequested) return;
        };
        while (!self.stop.isSet()) {
            if (self.reboot_requested.load(.acquire)) {
                self.reboot(&port, &lines) catch return;
                return;
            }
            const raw = lines.next(self, &port, self.deadline(), true) catch |err| switch (err) {
                error.Timeout, error.RebootRequested => continue,
                else => return,
            };
            const reading = parseTd1Line(raw) orelse continue;
            self.core.run(self.io, Td1Ctx.recordReading, .{ self.ctx, self.serial, reading }) catch continue;
        }
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
    /// Core protects the map; its owner stops and joins readers outside Core.
    readers: std.StringHashMap(*DeviceReader),
    /// Background discovery/poll plumbing (set via setIo/setCore + startPolling).
    io: ?std.Io = null,
    core: ?*Core = null,
    poll_thread: ?std.Thread = null,
    poll_stop: std.Io.Event = .unset,
    tty_root: []const u8 = "/sys/class/tty",
    dev_prefix: []const u8 = "/dev",
    baud: u32 = 115200,

    pub fn init(alloc: std.mem.Allocator, clock_io: std.Io) Td1Ctx {
        return .{ .clock_io = clock_io, .gpa = alloc, .conns = std.StringHashMap(Td1Connection).init(alloc), .readers = std.StringHashMap(*DeviceReader).init(alloc) };
    }

    pub fn setIo(self: *Td1Ctx, io: std.Io) void {
        self.io = io;
    }
    pub fn setCore(self: *Td1Ctx, core: *Core) void {
        self.core = core;
    }

    /// Start the background discovery/poll loop (no-op without io/core or if
    /// already running). On a host without a TD-1, scanOnce simply finds nothing.
    pub fn startPolling(self: *Td1Ctx) !void {
        if (self.poll_thread != null) return;
        if (self.io == null or self.core == null) return;
        self.poll_stop.reset();
        self.poll_thread = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, pollLoop, .{self});
    }

    pub fn stopPolling(self: *Td1Ctx) void {
        self.poll_stop.set(self.clock_io);
        if (self.poll_thread) |t| {
            t.join();
            self.poll_thread = null;
        }
        const io = self.io orelse return;
        const core = self.core orelse return;
        while (true) {
            core.lock(io);
            var it = self.readers.iterator();
            const entry = it.next() orelse {
                core.unlock(io);
                break;
            };
            const reader = entry.value_ptr.*;
            _ = self.readers.remove(entry.key_ptr.*);
            core.unlock(io);
            reader.stopAndJoin();
            reader.release();
        }
    }

    fn pollLoop(self: *Td1Ctx) void {
        const io = self.io orelse return;
        const core = self.core orelse return;
        while (!self.poll_stop.isSet()) {
            self.scanOnce(io, core);
            if (sleep.untilStopped(io, scan_interval, &self.poll_stop)) return;
        }
    }

    pub fn deinit(self: *Td1Ctx) void {
        self.stopPolling();
        var it = self.conns.iterator();
        while (it.next()) |entry| {
            freeConnection(self.gpa, entry.value_ptr.*);
            self.gpa.free(entry.key_ptr.*);
        }
        self.conns.deinit();
        self.readers.deinit();
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
        var ts_buf: [40]u8 = undefined;
        const new_scan = try self.gpa.dupe(u8, scanTimestamp(self.clock_io, &ts_buf));
        if (conn.color) |c| self.gpa.free(c);
        conn.color = new_color;
        self.gpa.free(conn.scan_time);
        conn.scan_time = new_scan;
        conn.td = reading.td;
        conn.done_initializing = true;
    }

    fn recordInitialization(self: *Td1Ctx, serial_number: []const u8, content: ?[]const u8) !void {
        const conn = self.conns.getPtr(serial_number) orelse return error.NotFound;
        const owned = if (content) |text| try self.gpa.dupe(u8, text) else null;
        if (conn.error_msg) |old| self.gpa.free(old);
        conn.error_msg = owned;
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

    /// Discover, start new readers and reap disconnected or finished readers.
    /// Device protocol I/O runs only on each device's owned worker.
    pub fn scanOnce(self: *Td1Ctx, io: std.Io, core: *Core) void {
        if (self.poll_stop.isSet()) return;
        self.io = io;
        self.core = core;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const devs = findTd1Devices(io, a, self.tty_root, self.dev_prefix);
        for (devs) |device| {
            if (self.poll_stop.isSet()) return;
            core.lock(io);
            if (self.readers.get(device.serial)) |existing| {
                if (!existing.finished.isSet()) {
                    core.unlock(io);
                    continue;
                }
                _ = self.readers.remove(device.serial);
                _ = self.removeConnection(device.serial);
                core.unlock(io);
                existing.stopAndJoin();
                existing.release();
            } else core.unlock(io);
            const reader = DeviceReader.create(self, io, core, device) catch continue;
            const added = core.run(io, addReader, .{ self, reader }) catch false;
            if (!added) {
                reader.release();
                continue;
            }
            reader.start() catch |err| {
                std.debug.print("phobos: warning: TD1 reader {s} failed: {}\n", .{ reader.serial, err });
                reader.finished.set(io);
            };
        }
        while (true) {
            core.lock(io);
            var removed: ?*DeviceReader = null;
            var it = self.readers.valueIterator();
            outer: while (it.next()) |entry| {
                for (devs) |device| if (std.mem.eql(u8, device.serial, entry.*.serial)) continue :outer;
                removed = entry.*;
                break;
            }
            if (removed) |reader| {
                _ = self.readers.remove(reader.serial);
                _ = self.removeConnection(reader.serial);
            }
            core.unlock(io);
            const reader = removed orelse break;
            reader.stopAndJoin();
            reader.release();
        }
    }

    fn addReader(self: *Td1Ctx, reader: *DeviceReader) !bool {
        if (self.readers.count() >= max_devices or self.readers.contains(reader.serial)) return false;
        var timestamp: [40]u8 = undefined;
        try self.addConnection(.{ .serial_number = reader.serial, .scan_time = scanTimestamp(self.clock_io, &timestamp) });
        errdefer _ = self.removeConnection(reader.serial);
        try self.readers.put(reader.serial, reader);
        return true;
    }
};

// ---------------------------------------------------------------------------
// Param helpers
// ---------------------------------------------------------------------------

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

/// Ask the device's owned reader to complete its settings reboot handshake.
/// Core is released while waiting. No board or host command is executed.
pub fn handleReboot(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *Td1Ctx = @ptrCast(@alignCast(ctx_ptr));
    const serial = try webreq.required([]const u8, params, "serial");
    var found = false;
    if (ctx.readers.get(serial)) |reader| {
        reader.retain();
        defer reader.release();
        reader.reboot_requested.store(true, .release);
        const io = reader.io;
        const result = blk: {
            if (ctx.core) |core| core.unlock(io);
            defer if (ctx.core) |core| core.lock(io);
            break :blk reader.finished.waitTimeout(io, .{ .duration = .{ .raw = reboot_wait, .clock = .awake } });
        };
        try result;
        if (!reader.reboot_ok.load(.acquire)) return error.Td1RebootFailed;
        if (ctx.readers.get(serial) == reader) _ = ctx.removeConnection(serial);
        found = true;
    } else found = ctx.removeConnection(serial);
    var out: std.json.ObjectMap = .empty;
    try out.put(alloc, "status", .{ .string = if (found) "ok" else "serial_error" });
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
        .{ "ttyACM2", "e4b2\n", "0045\n", "\xff\n" },
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

test "persistent TD1 reader initializes nullable data, records CSV and completes device reboot" {
    const Pty = @import("../testutil/pty.zig").Pty;
    const Peer = struct {
        pty: *Pty,
        allow_reading: std.Io.Event = .unset,
        done: std.Io.Event = .unset,

        fn expectBytes(master: *serial_mod.Serial, expected: []const u8) !void {
            const timeout = (std.Io.Timeout{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } }).toDeadline(master.io);
            var bytes: [64]u8 = undefined;
            var used: usize = 0;
            while (used < expected.len) used += try master.readSomeTimeout(bytes[used..expected.len], timeout);
            try testing.expectEqualStrings(expected, bytes[0..used]);
        }

        fn run(self: *@This()) !void {
            defer self.done.set(self.pty.master.io);
            const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } };
            try expectBytes(&self.pty.master, "retrieve file\nerrors.txt\n");
            try self.pty.master.writeTimeout("No file named errors.txt\n", timeout);
            try self.allow_reading.waitTimeout(self.pty.master.io, timeout);
            try self.pty.master.writeTimeout("ts,sn,fw,batt,1.72,Green\n", timeout);
            try expectBytes(&self.pty.master, "change settings\n");
            try self.pty.master.writeTimeout("ts,sn,fw,batt,2.0,stale\nready\n", timeout);
            try expectBytes(&self.pty.master, "RGB_Enabled = True\ndone\n");
            try self.pty.master.writeTimeout("restarting\n", timeout);
        }
    };
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pty = try Pty.init(io);
    defer pty.deinit();
    var keepalive = try serial_mod.Serial.open(io, pty.path(), 115200);
    defer keepalive.close();
    var peer: Peer = .{ .pty = &pty };
    var serving = try io.concurrent(Peer.run, .{&peer});
    defer _ = serving.cancel(io) catch {};
    var ttys = try FakeTtys.init(&.{.{ "ttyACM0", "e4b2\n", "0045\n", "SCANME\n" }});
    defer ttys.deinit();
    try ttys.tmp.dir.symLink(io, pty.path(), "dev/ttyACM0", .{});
    var core = Core.init();
    var ctx = Td1Ctx.init(std.heap.smp_allocator, io);
    defer ctx.deinit();
    ctx.tty_root = ttys.sys;
    ctx.dev_prefix = ttys.dev;

    ctx.scanOnce(io, &core);
    const State = struct {
        fn initialized(context: *Td1Ctx) bool {
            return if (context.conns.get("SCANME")) |conn| conn.done_initializing else false;
        }
        fn hasReading(context: *Td1Ctx) bool {
            return if (context.conns.get("SCANME")) |conn| conn.td != null else false;
        }
    };
    var start = std.Io.Clock.Timestamp.now(io, .awake);
    while (!core.run(io, State.initialized, .{&ctx})) {
        if (start.untilNow(io).raw.nanoseconds > std.time.ns_per_s) return error.Timeout;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial = try core.run(io, handleGetData, .{ @as(*anyopaque, @ptrCast(&ctx)), .null, a });
    const initial_data = initial.object.get("devices").?.object.get("SCANME").?.object;
    try testing.expect(initial_data.get("td").? == .null);
    try testing.expect(initial_data.get("error").? == .null);
    try testing.expect(std.mem.endsWith(u8, initial_data.get("scan_time").?.string, "+00:00Z"));
    peer.allow_reading.set(io);
    start = std.Io.Clock.Timestamp.now(io, .awake);
    while (!core.run(io, State.hasReading, .{&ctx})) {
        if (start.untilNow(io).raw.nanoseconds > std.time.ns_per_s) return error.Timeout;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    const data = try core.run(io, handleGetData, .{ @as(*anyopaque, @ptrCast(&ctx)), .null, a });
    const reading = data.object.get("devices").?.object.get("SCANME").?.object;
    try testing.expectEqual(@as(f64, 1.72), reading.get("td").?.float);
    try testing.expectEqualStrings("Green", reading.get("color").?.string);
    const reboot = try core.run(io, handleReboot, .{ @as(*anyopaque, @ptrCast(&ctx)), try objParams(a, "{\"serial\":\"SCANME\"}"), a });
    try testing.expectEqualStrings("ok", reboot.object.get("status").?.string);
    try peer.done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    try serving.await(io);

    try ttys.tmp.dir.deleteTree(io, "sys/ttyACM0");
    ctx.scanOnce(io, &core);
    try testing.expectEqual(@as(usize, 0), ctx.conns.count());
    try testing.expectEqual(@as(usize, 0), ctx.readers.count());
}

test "scanOnce: a device node that cannot be opened is still listed" {
    var ttys = try FakeTtys.init(&.{.{ "ttyACM0", "e4b2\n", "0045\n", "NODEV\n" }});
    defer ttys.deinit();
    var core = Core.init();
    var ctx = Td1Ctx.init(std.heap.smp_allocator, testing.io);
    defer ctx.deinit();
    ctx.tty_root = ttys.sys;
    ctx.dev_prefix = ttys.dev;
    ctx.scanOnce(testing.io, &core);
    try testing.expect(!ctx.conns.get("NODEV").?.done_initializing);
}

test "TD1 errors.txt blocks are acknowledged and exposed before any reading" {
    const Pty = @import("../testutil/pty.zig").Pty;
    const Peer = struct {
        pty: *Pty,
        done: std.Io.Event = .unset,
        oversized: bool = false,

        fn readExpected(self: *@This(), expected: []const u8) !void {
            const until = (std.Io.Timeout{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } }).toDeadline(self.pty.master.io);
            var buf: [64]u8 = undefined;
            var n: usize = 0;
            while (n < expected.len) n += try self.pty.master.readSomeTimeout(buf[n..expected.len], until);
            try testing.expectEqualStrings(expected, buf[0..n]);
        }

        fn run(self: *@This()) !void {
            defer self.done.set(self.pty.master.io);
            const until: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } };
            try self.readExpected("retrieve file\nerrors.txt\n");
            if (self.oversized) {
                try self.pty.master.writeTimeout("ready\n4097\n", until);
                return;
            }
            try self.pty.master.writeTimeout("ready\n7\n2\n4\nbad\n", until);
            try self.readExpected("ready\n");
            try self.pty.master.writeTimeout("3\nio\n", until);
            try self.readExpected("ready\n");
        }
    };
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();
    for ([_]bool{ false, true }) |oversized| {
        var pty = try Pty.init(aio);
        defer pty.deinit();
        var keepalive = try serial_mod.Serial.open(aio, pty.path(), 115200);
        defer keepalive.close();
        var peer: Peer = .{ .pty = &pty, .oversized = oversized };
        var serving = try aio.concurrent(Peer.run, .{&peer});
        defer _ = serving.cancel(aio) catch {};
        var core = Core.init();
        var ctx = Td1Ctx.init(std.heap.smp_allocator, aio);
        defer ctx.deinit();
        ctx.io = aio;
        ctx.core = &core;
        const reader = try DeviceReader.create(&ctx, aio, &core, .{ .path = pty.path(), .serial = "ERROR" });
        const added = try core.run(aio, Td1Ctx.addReader, .{ &ctx, reader });
        try testing.expect(added);
        try reader.start();
        try peer.done.waitTimeout(aio, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
        try serving.await(aio);
        if (oversized) {
            try reader.finished.waitTimeout(aio, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
            try testing.expect(!ctx.conns.get("ERROR").?.done_initializing);
        } else {
            const Check = struct {
                fn initialized(context: *Td1Ctx) bool {
                    return context.conns.get("ERROR").?.done_initializing;
                }
            };
            const start = std.Io.Clock.Timestamp.now(aio, .awake);
            while (!core.run(aio, Check.initialized, .{&ctx})) {
                if (start.untilNow(aio).raw.nanoseconds > std.time.ns_per_s) return error.Timeout;
                try std.Io.sleep(aio, .fromMilliseconds(1), .awake);
            }
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const result = try core.run(aio, handleGetData, .{ @as(*anyopaque, @ptrCast(&ctx)), .null, arena.allocator() });
            const data = result.object.get("devices").?.object.get("ERROR").?.object;
            try testing.expectEqualStrings("bad\nio\n", data.get("error").?.string);
            try testing.expect(data.get("td").? == .null);
            try testing.expect(data.get("color").? == .null);
        }
    }
}

test "TD1 reader records release partial allocations and replace initialization data" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            var core = Core.init();
            var ctx = Td1Ctx.init(alloc, testing.io);
            defer ctx.deinit();
            const reader = try DeviceReader.create(&ctx, testing.io, &core, .{ .path = "fixture", .serial = "ALLOC" });
            defer reader.release();
            try testing.expect(try ctx.addReader(reader));
            defer _ = ctx.readers.remove(reader.serial);
            try ctx.recordInitialization("ALLOC", "first error");
            try ctx.recordInitialization("ALLOC", "second error");
            try ctx.recordReading("ALLOC", .{ .td = 1.75, .color = "blue" });
            try testing.expectEqualStrings("second error", ctx.conns.get("ALLOC").?.error_msg.?);
        }
    }.run, .{});
}

test "TD1 timestamps retain UTC offset and microseconds from datetime isoformat" {
    const Fake = struct {
        nanos: i96,
        fn now(raw: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return .{ .nanoseconds = self.nanos };
        }
    };
    var fake: Fake = .{ .nanos = 1_700_000_000 * std.time.ns_per_s + 123_456 * std.time.ns_per_us };
    var vtable = std.Io.failing.vtable.*;
    vtable.now = Fake.now;
    const aio: std.Io = .{ .userdata = &fake, .vtable = &vtable };
    var buf: [40]u8 = undefined;
    try testing.expectEqualStrings("2023-11-14T22:13:20.123456+00:00Z", scanTimestamp(aio, &buf));
    fake.nanos = 0;
    try testing.expectEqualStrings("1970-01-01T00:00:00+00:00Z", scanTimestamp(aio, &buf));
}

test "fuzz TD1 line reader consumes arbitrary bounded serial bytes or times out" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            const aio = testing.io;
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            var bytes: [128]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            try tmp.dir.writeFile(aio, .{ .sub_path = "serial", .data = &bytes });
            const path = try tmp.dir.realPathFileAlloc(aio, "serial", testing.allocator);
            defer testing.allocator.free(path);
            var port = try serial_mod.Serial.open(aio, path, 115200);
            defer port.close();
            var core = Core.init();
            var ctx = Td1Ctx.init(testing.allocator, aio);
            defer ctx.deinit();
            const reader = try DeviceReader.create(&ctx, aio, &core, .{ .path = path, .serial = "FUZZ" });
            defer reader.release();
            var lines: Lines = .{};
            const until = (std.Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }).toDeadline(aio);
            var count: usize = 0;
            while (lines.next(reader, &port, until, true)) |line| {
                try testing.expect(line.len <= max_error_bytes);
                try testing.expect(std.mem.endsWith(u8, line, "\n"));
                count += line.len;
            } else |err| try testing.expectEqual(error.Timeout, err);
            try testing.expect(count <= bytes.len);
        }
    }.run, .{});
}

test "fuzz TD1 timestamps format bounded UTC dates" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            const Fake = struct {
                nanos: i96,
                fn now(raw: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
                    const self: *@This() = @ptrCast(@alignCast(raw.?));
                    return .{ .nanoseconds = self.nanos };
                }
            };
            const seconds = smith.valueRangeAtMostWithHash(u64, 0, 253_402_300_799, 0);
            const micros = smith.valueRangeAtMostWithHash(u32, 0, 999_999, 1);
            var fake: Fake = .{ .nanos = @as(i96, seconds) * std.time.ns_per_s + @as(i96, micros) * std.time.ns_per_us };
            var vtable = std.Io.failing.vtable.*;
            vtable.now = Fake.now;
            const aio: std.Io = .{ .userdata = &fake, .vtable = &vtable };
            var buf: [40]u8 = undefined;
            const text = scanTimestamp(aio, &buf);
            try testing.expectEqual(@as(usize, if (micros == 0) 26 else 33), text.len);
            try testing.expect(std.mem.endsWith(u8, text, "+00:00Z"));
        }
    }.run, .{});
}

test "scanOnce leaves tracked devices unchanged after polling stops" {
    const aio = testing.io;
    var ttys = try FakeTtys.init(&.{.{ "ttyACM0", "e4b2\n", "0045\n", "NEW\n" }});
    defer ttys.deinit();
    var core = Core.init();
    var ctx = Td1Ctx.init(testing.allocator, aio);
    defer ctx.deinit();
    try ctx.addConnection(.{ .serial_number = "OLD", .scan_time = "now" });
    ctx.tty_root = ttys.sys;
    ctx.dev_prefix = ttys.dev;
    ctx.poll_stop.set(aio);
    ctx.scanOnce(aio, &core);
    try testing.expectEqual(@as(usize, 1), ctx.conns.count());
    try testing.expect(ctx.conns.contains("OLD"));
}

test "TD1 polling starts discovery immediately and joins every reader on stop" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();
    var ttys = try FakeTtys.init(&.{.{ "ttyACM0", "e4b2\n", "0045\n", "POLL\n" }});
    defer ttys.deinit();
    var core = Core.init();
    var ctx = Td1Ctx.init(std.heap.smp_allocator, aio);
    defer ctx.deinit();
    ctx.io = aio;
    ctx.core = &core;
    ctx.tty_root = ttys.sys;
    ctx.dev_prefix = ttys.dev;
    try ctx.startPolling();
    const Check = struct {
        fn found(context: *Td1Ctx) bool {
            return context.readers.contains("POLL");
        }
    };
    const start = std.Io.Clock.Timestamp.now(aio, .awake);
    while (!core.run(aio, Check.found, .{&ctx})) {
        if (start.untilNow(aio).raw.nanoseconds > std.time.ns_per_s) return error.Timeout;
        try std.Io.sleep(aio, .fromMilliseconds(1), .awake);
    }
    ctx.stopPolling();
    try testing.expect(ctx.poll_thread == null);
    try testing.expectEqual(@as(usize, 0), ctx.readers.count());
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
    try std.testing.expect(parseTd1Line("a,b,c,d,2.0,\xff") == null);
}

test "fuzz parseTd1Line: arbitrary input never crashes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [48]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            if (parseTd1Line(&buf)) |reading|
                try std.testing.expect(std.unicode.utf8ValidateSlice(reading.color));
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
