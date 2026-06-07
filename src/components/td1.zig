//! machine.td1.* API component — Moonraker-compatible TD-1 filament sensor support.
//!
//! Mirrors the endpoints registered in
//! `vendor/moonraker/moonraker/components/td1.py`:
//!
//!   GET  /machine/td1/data   → machine.td1.data
//!   POST /machine/td1/reboot → machine.td1.reboot
//!
//! The TD-1 is a USB serial device (VID=0xE4B2, PID=0x0045) that reports
//! filament TD (transparency/diameter) and color data. Serial-port comms are
//! implemented: `pollSerialOnce` opens the device via `serial.zig` and parses a
//! TD-1 CSV line (`parseTd1Line`, matching td1.py `_parse_line`: field[4]=td,
//! field[5]=color). The CSV parser is unit-tested; the live USB enumeration /
//! hotplug loop and on-hardware timing are not verified here (no device).

const std = @import("std");
const registry = @import("../server/registry.zig");
const serial_mod = @import("serial.zig");

const Registry = registry.Registry;

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

/// Current UTC time as an ISO-8601 string ("YYYY-MM-DDTHH:MM:SSZ"), written into
/// `buf` (needs >= 20 bytes). Used for TD-1 scan timestamps.
pub fn nowIso8601(buf: []u8) []const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    const secs: u64 = @intCast(@max(0, ts.sec));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,
        md.month.numeric(),
        @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch "1970-01-01T00:00:00Z";
}

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

pub const Td1Ctx = struct {
    gpa: std.mem.Allocator,
    conns: std.StringHashMap(Td1Connection),

    pub fn init(alloc: std.mem.Allocator) Td1Ctx {
        return .{ .gpa = alloc, .conns = std.StringHashMap(Td1Connection).init(alloc) };
    }

    pub fn deinit(self: *Td1Ctx) void {
        var it = self.conns.iterator();
        while (it.next()) |entry| {
            const conn = entry.value_ptr;
            self.gpa.free(conn.serial_number);
            self.gpa.free(conn.scan_time);
            if (conn.color) |c| self.gpa.free(c);
            if (conn.error_msg) |e| self.gpa.free(e);
            self.gpa.free(entry.key_ptr.*);
        }
        self.conns.deinit();
    }

    /// Read one line from the TD-1 serial device and update the named
    /// connection's td/color (matching td1.py run_serial → _parse_line). A line
    /// that fails to parse is ignored. Best-effort: opening/reading errors
    /// propagate; a malformed line is a no-op.
    pub fn pollSerialOnce(self: *Td1Ctx, io: std.Io, serial_number: []const u8, path: []const u8, baud: u32) !void {
        var ser = try serial_mod.Serial.open(io, path, baud);
        defer ser.close();
        var buf: [256]u8 = undefined;
        const n = try ser.readSome(&buf);
        const data = buf[0..n];
        const line = if (std.mem.indexOfScalar(u8, data, '\n')) |i| data[0..i] else data;
        const parsed = parseTd1Line(line) orelse return;
        const conn = self.conns.getPtr(serial_number) orelse return error.NotFound;
        const new_color = try self.gpa.dupe(u8, parsed.color);
        errdefer self.gpa.free(new_color);
        // Refresh scan_time on each successful reading (td1.py _parse_line sets
        // `_scan_time = datetime.utcnow().isoformat()+"Z"`).
        var ts_buf: [32]u8 = undefined;
        const new_scan = try self.gpa.dupe(u8, nowIso8601(&ts_buf));
        if (conn.color) |c| self.gpa.free(c);
        conn.color = new_color;
        self.gpa.free(conn.scan_time);
        conn.scan_time = new_scan;
        conn.td = parsed.td;
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
        const v: Td1Connection = .{
            .serial_number = sn,
            .td = conn.td,
            .color = if (conn.color) |c| try self.gpa.dupe(u8, c) else null,
            .scan_time = st,
            .error_msg = if (conn.error_msg) |e| try self.gpa.dupe(u8, e) else null,
            .done_initializing = conn.done_initializing,
        };
        try self.conns.put(k, v);
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
        if (conn.getData(alloc)) |dev_data| {
            if (dev_data) |dd| {
                try devices.put(alloc, conn.serial_number, .{ .object = dd });
            }
        } else |_| {
            // Allocation failed; skip this device to avoid partial responses.
        }
    }
    try out.put(alloc, "devices", .{ .object = devices });
    return .{ .object = out };
}

// ---------------------------------------------------------------------------
// POST /machine/td1/reboot → machine.td1.reboot
// ---------------------------------------------------------------------------

/// Reboot a TD-1 device by serial number.
/// Looks up the serial in the connection map. If found, removes it and returns
/// `{ "status": "ok" }` (in a real implementation the device would then be
/// re-discovered by the hotplug watcher within 5s). If not found, returns
/// `{ "status": "serial_error" }`.
pub fn handleReboot(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *Td1Ctx = @ptrCast(@alignCast(ctx_ptr));
    const serial = try getStr(params, "serial");

    var out: std.json.ObjectMap = .empty;
    if (ctx.conns.getEntry(serial)) |entry| {
        // Free the entry's value fields AND the map key (a separate allocation
        // from serial_number — see addConnection). remove() only unlinks; the
        // key would otherwise leak on every reboot of a known device.
        const key = entry.key_ptr.*;
        const conn = entry.value_ptr.*;
        ctx.gpa.free(conn.serial_number);
        ctx.gpa.free(conn.scan_time);
        if (conn.color) |c| ctx.gpa.free(c);
        if (conn.error_msg) |e| ctx.gpa.free(e);
        _ = ctx.conns.remove(serial);
        ctx.gpa.free(key);
        try out.put(alloc, "status", .{ .string = "ok" });
    } else {
        try out.put(alloc, "status", .{ .string = "serial_error" });
    }
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

// ---- nowIso8601 ----

test "nowIso8601: ISO-8601 UTC shape (YYYY-MM-DDTHH:MM:SSZ)" {
    var buf: [32]u8 = undefined;
    const s = nowIso8601(&buf);
    try testing.expectEqual(@as(usize, 20), s.len);
    try testing.expectEqual(@as(u8, '-'), s[4]);
    try testing.expectEqual(@as(u8, '-'), s[7]);
    try testing.expectEqual(@as(u8, 'T'), s[10]);
    try testing.expectEqual(@as(u8, ':'), s[13]);
    try testing.expectEqual(@as(u8, ':'), s[16]);
    try testing.expectEqual(@as(u8, 'Z'), s[19]);
    // Year is past the epoch and plausibly current-era.
    const year = try std.fmt.parseInt(u16, s[0..4], 10);
    try testing.expect(year >= 2020 and year < 3000);
}

test "fuzz nowIso8601: any buffer size never crashes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            // Buffer may be too small (then bufPrint fails → fallback literal);
            // either way it must not crash and must return a non-empty string.
            const n: usize = smith.valueRangeAtMostWithHash(u32, 0, 40, 0);
            var buf: [40]u8 = undefined;
            const s = nowIso8601(buf[0..n]);
            try testing.expect(s.len > 0);
        }
    }.run, .{});
}

// ---- handleGetData ----

test "handleGetData: returns status=ok and empty devices map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = Td1Ctx.init(a);
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
    var ctx = Td1Ctx.init(a);
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
    var ctx = Td1Ctx.init(a);
    defer ctx.deinit();
    try testing.expectError(error.InvalidParams, handleReboot(@ptrCast(&ctx), .null, a));
    try testing.expectError(error.InvalidParams, handleReboot(@ptrCast(&ctx), try objParams(a, "{}"), a));
}

test "handleReboot: unknown serial returns serial_error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = Td1Ctx.init(a);
    defer ctx.deinit();
    const v = try handleReboot(@ptrCast(&ctx), try objParams(a, "{\"serial\":\"ABC123\"}"), a);
    try testing.expectEqualStrings("serial_error", v.object.get("status").?.string);
}

test "handleReboot: result always contains status key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = Td1Ctx.init(a);
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
            var ctx = Td1Ctx.init(a);
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
            var ctx = Td1Ctx.init(a);
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

    var ctx = Td1Ctx.init(testing.allocator);
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
    var ctx = Td1Ctx.init(a);
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
    var ctx = Td1Ctx.init(a);
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
    var ctx = Td1Ctx.init(a);
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
    var ctx = Td1Ctx.init(a);
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
    var ctx = Td1Ctx.init(a);
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
    var ctx = Td1Ctx.init(a);
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
            var ctx = Td1Ctx.init(a);
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

test "pollSerialOnce: reads a line from the device and updates the connection" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const Dir = std.Io.Dir;

    const path = "/tmp/phobos_td1_serial.dev";
    Dir.cwd().deleteFile(io, path) catch {};
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "ts,sn,fw,batt,1.72,Green\n" });
    defer Dir.cwd().deleteFile(io, path) catch {};

    var ctx = Td1Ctx.init(std.testing.allocator);
    defer ctx.deinit();
    try ctx.addConnection(.{ .serial_number = "TD1A", .scan_time = "init", .done_initializing = false });

    try ctx.pollSerialOnce(io, "TD1A", path, 115200);

    const conn = ctx.conns.getPtr("TD1A").?;
    try std.testing.expect(conn.done_initializing);
    try std.testing.expectEqual(@as(f64, 1.72), conn.td.?);
    try std.testing.expectEqualStrings("Green", conn.color.?);
}

test "handleReboot: removing a known device frees the map key (no leak)" {
    // Runs under testing.allocator: a leaked key/value would fail the test.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = Td1Ctx.init(std.testing.allocator);
    defer ctx.deinit();
    try ctx.addConnection(.{ .serial_number = "TD1X", .scan_time = "t", .color = "Red", .done_initializing = true });

    const params = try std.json.parseFromSlice(std.json.Value, a, "{\"serial\":\"TD1X\"}", .{});
    const r = try handleReboot(@ptrCast(&ctx), params.value, a);
    try std.testing.expectEqualStrings("ok", r.object.get("status").?.string);
    try std.testing.expect(ctx.conns.count() == 0);
}
