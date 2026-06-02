//! machine.* core API component — Moonraker-compatible machine management.
//!
//! Mirrors the endpoints registered in
//! `vendor/moonraker/moonraker/components/machine.py` and the `machine.proc_stats`
//! endpoint from `vendor/moonraker/moonraker/components/proc_stats.py`:
//!
//!   GET  /machine/system_info        → machine.system_info
//!   GET  /machine/proc_stats         → machine.proc_stats
//!   POST /machine/reboot             → machine.reboot
//!   POST /machine/shutdown           → machine.shutdown
//!   POST /machine/services/restart   → machine.services.restart
//!   POST /machine/services/stop      → machine.services.stop
//!   POST /machine/services/start     → machine.services.start
//!   GET  /machine/sudo/info          → machine.sudo.info
//!   POST /machine/sudo/password      → machine.sudo.password
//!   GET  /machine/peripherals/usb    → machine.peripherals.usb
//!   GET  /machine/peripherals/serial → machine.peripherals.serial
//!   GET  /machine/peripherals/video  → machine.peripherals.video
//!   GET  /machine/peripherals/canbus → machine.peripherals.canbus
//!
//! SYSTEM CONTROL IS STUBBED. reboot/shutdown and the service actions never
//! touch the host: they validate inputs and return Moonraker's ack shape (the
//! bare string "ok"). This is deliberate — phobos must not reboot or stop
//! services on the development machine. The stubs are noted at each handler.
//!
//! REAL DATA WHERE READABLE. system_info and proc_stats read the live Linux
//! /proc and /sys trees (cpuinfo, meminfo, os-release, /proc/stat,
//! /proc/net/dev, thermal zones). Every parser is split into a pure function
//! that takes the file *contents* as a slice (so it can be fuzzed with
//! malformed/truncated input without touching the real filesystem) plus a thin
//! wrapper that reads the file and feeds the parser. Parsers never crash on
//! garbage; they return the zeroed/empty default shape instead.
//!
//! Fields that require systemd / dbus / a Raspberry Pi mailbox (service_state,
//! virtualization details, throttled_state, canbus enumeration) get faithful
//! empty/default values matching what Moonraker reports when those subsystems
//! are unavailable. The SHAPE of every response matches upstream exactly.

const std = @import("std");
const registry = @import("../server/registry.zig");
const notify = @import("../server/notify.zig");

const Registry = registry.Registry;
const NotifyBus = notify.NotifyBus;
const Dir = std.Io.Dir;

// ---------------------------------------------------------------------------
// File paths (mirrors machine.py / proc_stats.py constants)
// ---------------------------------------------------------------------------

const CPUINFO_PATH = "/proc/cpuinfo";
const MEMINFO_PATH = "/proc/meminfo";
const OS_RELEASE_PATH = "/etc/os-release";
const CGROUP_PATH = "/proc/1/cgroup";
const CPU_STAT_PATH = "/proc/stat";
const NET_DEV_PATH = "/proc/net/dev";
const TEMPERATURE_PATH = "/sys/class/thermal/thermal_zone0/temp";

/// The list of services Moonraker treats as allowed by default
/// (assets/default_allowed_services). Used to populate available_services /
/// service_state shape; without systemd phobos reports an empty service map but
/// still exposes the allowed list semantics through is_service_allowed.
pub const default_allowed_services = [_][]const u8{
    "klipper",
    "klipper_mcu",
    "webcamd",
    "MoonCord",
    "KlipperScreen",
    "moonraker-telegram-bot",
    "moonraker-obico",
    "sonar",
    "crowsnest",
    "octoeverywhere",
    "ratos-configurator",
};

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

/// machine.* state. Mostly stateless; holds the sudo password (set via
/// machine.sudo.password) and the live io used for reading /proc & /sys. io is
/// wired after the event loop starts (setIo); handlers fall back to empty
/// shapes when io is absent (pure unit tests).
pub const MachineCtx = struct {
    gpa: std.mem.Allocator,
    io: ?std.Io = null,
    bus: ?*NotifyBus = null,
    /// Optional reference to the live connection registry for websocket_connections count.
    conns: ?*@import("../server/connections.zig").Connections = null,
    /// Set when a sudo password has been supplied. Owned by the ctx allocator.
    sudo_password: ?[]const u8 = null,
    /// Proc stat timer stop flag. Set by deinit, polled by the timer thread.
    proc_stat_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Handle for the proc_stat timer thread, joined in deinit.
    proc_stat_thread: ?std.Thread = null,

    pub fn setIo(self: *MachineCtx, io: std.Io) void {
        self.io = io;
        // Start the periodic proc_stat emission if a bus is wired.
        if (self.bus != null) {
            self.proc_stat_thread = std.Thread.spawn(.{}, procStatTimerThread, .{self}) catch null;
        }
    }

    pub fn deinit(self: *MachineCtx) void {
        self.proc_stat_stop.store(true, .release);
        // Clear io so the timer thread sees null and returns early.
        self.io = null;
        if (self.proc_stat_thread) |th| {
            th.join();
            self.proc_stat_thread = null;
        }
        if (self.sudo_password) |p| self.gpa.free(p);
        self.sudo_password = null;
    }
};

// ---------------------------------------------------------------------------
// Proc stat timer — periodic notify_proc_stat_update emission
// ---------------------------------------------------------------------------

/// Background thread spawned via std.Thread.spawn. Emits `notify_proc_stat_update`
/// every second until `proc_stat_stop` is set.
fn procStatTimerThread(self: *MachineCtx) void {
    while (!self.proc_stat_stop.load(.acquire)) {
        // Sleep 1 second using Linux nanosleep.
        var req: std.os.linux.timespec = .{ .sec = 1, .nsec = 0 };
        _ = std.os.linux.nanosleep(&req, null);
        if (self.proc_stat_stop.load(.acquire)) break;
        if (self.io) |io| {
            emitProcStatUpdate(self, io) catch {};
        } else break;
    }
}

/// Read system files and emit `notify_proc_stat_update` on the bus.
/// Reuses the same parser functions as handleProcStats.
fn emitProcStatUpdate(self: *MachineCtx, io: std.Io) !void {
    const bus = self.bus orelse return;
    const alloc = std.heap.smp_allocator;

    var cpu_temp: std.json.Value = .null;
    var network: std.json.Value = .{ .object = .empty };
    var sys_cpu: std.json.Value = .{ .object = .empty };
    var sys_mem: std.json.Value = .{ .object = .empty };
    var mem: i64 = 0;

    // Read CPU temperature.
    if (readFile(io, alloc, TEMPERATURE_PATH)) |txt| {
        if (parseCpuTemp(txt)) |t| cpu_temp = .{ .float = t };
    }

    // Read network stats.
    if (readFile(io, alloc, NET_DEV_PATH)) |txt| {
        network = try parseNetDev(alloc, txt);
    }

    // Read system CPU usage.
    if (readFile(io, alloc, CPU_STAT_PATH)) |txt| {
        sys_cpu = try parseCpuStat(alloc, txt);
    }

    // Read system memory.
    if (readFile(io, alloc, MEMINFO_PATH)) |txt| {
        sys_mem = try parseSystemMemory(alloc, txt);
    }

    // Read process RSS (kB) for moonraker_stats.memory.
    if (readFile(io, alloc, "/proc/self/statm")) |txt| {
        mem = parseProcMem(txt);
    }

    // Process CPU usage since last tick (thread-local tracking).
    const cpu_usage = procCpuUsage();

    // Build moonraker_stats: a single-sample array of {time, cpu_usage, memory, mem_units}.
    var sample: std.json.ObjectMap = .empty;
    try sample.put(alloc, "time", .{ .float = nowSeconds() });
    try sample.put(alloc, "cpu_usage", .{ .float = cpu_usage });
    try sample.put(alloc, "memory", .{ .integer = mem });
    try sample.put(alloc, "mem_units", .{ .string = "kB" });

    var samples: std.json.Array = .init(alloc);
    try samples.append(.{ .object = sample });

    // Event payload: mirrors Moonraker's proc_stats:proc_stat_update shape.
    var event_data: std.json.ObjectMap = .empty;
    try event_data.put(alloc, "moonraker_stats", .{ .array = samples });
    try event_data.put(alloc, "cpu_temp", cpu_temp);
    try event_data.put(alloc, "network", network);
    try event_data.put(alloc, "system_cpu_usage", sys_cpu);
    try event_data.put(alloc, "system_memory", sys_mem);
    const ws_count: i64 = if (self.conns) |c| @intCast(c.count(io)) else 0;
    try event_data.put(alloc, "websocket_connections", .{ .integer = ws_count });

    // JSON-RPC params: [event_data].
    var params_arr: std.json.Array = .init(alloc);
    try params_arr.append(.{ .object = event_data });

    _ = try bus.emit(io, notify.names.proc_stat_update, .{ .array = params_arr });
}

/// Parse RSS (resident set size in kB) from /proc/self/statm field 1.
fn parseProcMem(text: []const u8) i64 {
    var fields = std.mem.tokenizeAny(u8, text, " \t\r\n");
    _ = fields.next(); // size
    const rss_str = fields.next() orelse return 0;
    const pages = std.fmt.parseInt(i64, rss_str, 10) catch return 0;
    return pages * 4; // 4 kB pages → kB
}

/// Process CPU usage since last call (thread-local state). Returns 0 on first
/// call, then the percentage of one CPU core consumed between successive calls.
fn procCpuUsage() f64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.PROCESS_CPUTIME_ID, &ts);
    const proc_now = @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1.0e9;
    const wall_now = nowSeconds();

    const S = struct {
        var last_wall: f64 = 0;
        var last_proc: f64 = 0;
    };

    const usage: f64 = if (S.last_wall > 0 and wall_now > S.last_wall) blk: {
        const wall_diff = wall_now - S.last_wall;
        const proc_diff = proc_now - S.last_proc;
        break :blk if (wall_diff > 0) @round(100.0 * (proc_diff / wall_diff) * 100.0) / 100.0 else 0.0;
    } else 0.0;

    S.last_wall = wall_now;
    S.last_proc = proc_now;
    return usage;
}

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

fn getStrDefault(params: std.json.Value, field: []const u8, default_val: []const u8) []const u8 {
    return getOptStr(params, field) orelse default_val;
}

fn getBool(params: std.json.Value, field: []const u8, default_val: bool) bool {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return default_val;
            return switch (v) {
                .bool => |b| b,
                .string => |s| std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1"),
                .integer => |i| i != 0,
                else => default_val,
            };
        },
        else => return default_val,
    }
}

// ---------------------------------------------------------------------------
// File reading helper
// ---------------------------------------------------------------------------

/// Read a whole file into an arena-allocated slice. Returns null on any error
/// (missing file, permission denied) so callers fall back to the empty shape.
///
/// Streams chunk-by-chunk until EOF rather than trusting the stat size: /proc
/// and /sys virtual files report a size of 0 even though they yield content, so
/// the size-based `allocRemaining` would return an empty slice for them.
fn readFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const f = Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    var rbuf: [4096]u8 = undefined;
    var fr = f.reader(io, &rbuf);
    var out: std.ArrayList(u8) = .empty;
    // Cap total read to guard against unbounded /proc files.
    const max_total: usize = 4 * 1024 * 1024;
    while (out.items.len < max_total) {
        const chunk = fr.interface.peekGreedy(1) catch |e| {
            if (e == error.EndOfStream) break;
            return null;
        };
        out.appendSlice(alloc, chunk) catch return null;
        fr.interface.toss(chunk.len);
    }
    return out.items;
}

// ===========================================================================
// CPU info parser (/proc/cpuinfo) + memory (/proc/meminfo)
// ===========================================================================

/// Parsed pieces of /proc/cpuinfo we expose. All optional / defaulted.
pub const CpuParse = struct {
    cpu_desc: []const u8 = "",
    serial_number: []const u8 = "",
    hardware_desc: []const u8 = "",
    model: []const u8 = "",
};

/// Pure parser for /proc/cpuinfo text. Robust against truncated / malformed
/// input: only fills fields it finds, otherwise leaves the "" default.
/// Returned slices borrow `text`.
pub fn parseCpuinfo(text: []const u8) CpuParse {
    var out: CpuParse = .{};
    // cpu_desc: first "model name : <desc>" line.
    out.cpu_desc = matchKeyColon(text, "model name") orelse "";
    // ARM SBC fields, present only on the last cpuinfo block in practice but a
    // line scan is sufficient and robust.
    out.hardware_desc = matchKeyColon(text, "Hardware") orelse "";
    out.model = matchKeyColon(text, "Model") orelse "";
    if (matchKeyColon(text, "Serial")) |sn| {
        // Strip leading zeros like Moonraker's `0*` regex group.
        out.serial_number = std.mem.trimStart(u8, sn, "0");
    }
    return out;
}

/// Find a line of the form "<key><whitespace>:<whitespace><value>" and return
/// the trimmed value, or null. Scans line by line so partial files are safe.
fn matchKeyColon(text: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const lhs = std.mem.trim(u8, line[0..colon], " \t\r");
        if (!std.mem.eql(u8, lhs, key)) continue;
        const rhs = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
        if (rhs.len == 0) continue;
        return rhs;
    }
    return null;
}

/// Parse MemTotal from /proc/meminfo. Returns (kib, units) or (0, "") on any
/// failure. Units mirror Moonraker (`parts[2]`, typically "kB").
pub fn parseMemTotal(text: []const u8) struct { total: i64, units: []const u8 } {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "MemTotal:")) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        _ = fields.next(); // "MemTotal:"
        const num = fields.next() orelse return .{ .total = 0, .units = "" };
        const units = fields.next() orelse "";
        const val = std.fmt.parseInt(i64, num, 10) catch return .{ .total = 0, .units = "" };
        return .{ .total = val, .units = units };
    }
    return .{ .total = 0, .units = "" };
}

/// Count online CPUs from /proc/cpuinfo by counting "processor" lines. Falls
/// back to 1 when none are found (always at least one logical CPU).
pub fn parseCpuCount(text: []const u8) i64 {
    var count: i64 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const lhs = std.mem.trim(u8, line[0..colon], " \t\r");
        if (std.mem.eql(u8, lhs, "processor")) count += 1;
    }
    return if (count == 0) 1 else count;
}

/// Build the `cpu_info` object (Moonraker `_get_cpu_info`). Always returns the
/// full key set; fields default to ""/null when /proc is unreadable.
fn buildCpuInfo(ctx: *MachineCtx, alloc: std.mem.Allocator) !std.json.Value {
    var cpu: CpuParse = .{};
    var cpu_count: i64 = 1;
    var total_memory: ?i64 = null;
    var mem_units: []const u8 = "";

    if (ctx.io) |io| {
        if (readFile(io, alloc, CPUINFO_PATH)) |txt| {
            cpu = parseCpuinfo(txt);
            cpu_count = parseCpuCount(txt);
        }
        if (readFile(io, alloc, MEMINFO_PATH)) |txt| {
            const mem = parseMemTotal(txt);
            if (mem.total > 0) {
                total_memory = mem.total;
                mem_units = mem.units;
            }
        }
    }

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "cpu_count", .{ .integer = cpu_count });
    try obj.put(alloc, "bits", .{ .string = if (@bitSizeOf(usize) == 64) "64bit" else "32bit" });
    try obj.put(alloc, "processor", .{ .string = @tagName(@import("builtin").cpu.arch) });
    try obj.put(alloc, "cpu_desc", .{ .string = cpu.cpu_desc });
    try obj.put(alloc, "serial_number", .{ .string = cpu.serial_number });
    try obj.put(alloc, "hardware_desc", .{ .string = cpu.hardware_desc });
    try obj.put(alloc, "model", .{ .string = cpu.model });
    if (total_memory) |tm| {
        try obj.put(alloc, "total_memory", .{ .integer = tm });
    } else {
        try obj.put(alloc, "total_memory", .null);
    }
    try obj.put(alloc, "memory_units", .{ .string = mem_units });
    return .{ .object = obj };
}

// ===========================================================================
// Distribution info (/etc/os-release)
// ===========================================================================

pub const DistroParse = struct {
    name: []const u8 = "",
    id: []const u8 = "",
    version: []const u8 = "",
    version_codename: []const u8 = "",
    like: []const u8 = "",
};

/// Pure parser for os-release syntax (KEY=VALUE, value optionally quoted).
/// Robust against missing keys / malformed lines. Returned slices borrow
/// `text`.
pub fn parseOsRelease(text: []const u8) DistroParse {
    var out: DistroParse = .{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        var val = line[eq + 1 ..];
        // Strip surrounding quotes.
        if (val.len >= 2 and (val[0] == '"' or val[0] == '\'') and val[val.len - 1] == val[0]) {
            val = val[1 .. val.len - 1];
        }
        if (std.mem.eql(u8, key, "PRETTY_NAME")) {
            out.name = val;
        } else if (std.mem.eql(u8, key, "ID")) {
            out.id = val;
        } else if (std.mem.eql(u8, key, "VERSION_ID")) {
            out.version = val;
        } else if (std.mem.eql(u8, key, "VERSION_CODENAME")) {
            out.version_codename = val;
        } else if (std.mem.eql(u8, key, "ID_LIKE")) {
            out.like = val;
        }
    }
    // Fall back to NAME if PRETTY_NAME absent.
    if (out.name.len == 0) {
        if (matchKeyEq(text, "NAME")) |n| out.name = n;
    }
    return out;
}

fn matchKeyEq(text: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, line[0..eq], key)) continue;
        var val = line[eq + 1 ..];
        if (val.len >= 2 and (val[0] == '"' or val[0] == '\'') and val[val.len - 1] == val[0]) {
            val = val[1 .. val.len - 1];
        }
        return val;
    }
    return null;
}

/// Build the `distribution` object. Matches the key set Moonraker derives from
/// the `distro` library (name, id, version, codename, release_info, like,
/// kernel_version).
fn buildDistribution(ctx: *MachineCtx, alloc: std.mem.Allocator) !std.json.Value {
    var d: DistroParse = .{};
    if (ctx.io) |io| {
        if (readFile(io, alloc, OS_RELEASE_PATH)) |txt| {
            d = parseOsRelease(txt);
        }
    }

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "name", .{ .string = d.name });
    try obj.put(alloc, "id", .{ .string = d.id });
    try obj.put(alloc, "version", .{ .string = d.version });
    try obj.put(alloc, "codename", .{ .string = d.version_codename });
    // release_info: distro.distro_release_info() — empty dict on os-release
    // based distros.
    try obj.put(alloc, "release_info", .{ .object = .empty });
    try obj.put(alloc, "like", .{ .string = d.like });
    try obj.put(alloc, "kernel_version", .{ .string = readKernelVersion(ctx, alloc) });
    return .{ .object = obj };
}

/// Kernel release string from uname(2). Empty string on failure.
fn readKernelVersion(ctx: *MachineCtx, alloc: std.mem.Allocator) []const u8 {
    _ = ctx;
    const uts = std.posix.uname();
    const rel = std.mem.sliceTo(&uts.release, 0);
    return alloc.dupe(u8, rel) catch "";
}

// ===========================================================================
// Virtualization (/proc/1/cgroup container detection)
// ===========================================================================

pub const VirtParse = struct {
    virt_type: []const u8 = "none",
    virt_identifier: []const u8 = "none",
};

/// Pure container detection from /proc/1/cgroup contents. Matches machine.py's
/// `_check_inside_container` cgroup branch (docker / lxc substrings). systemd's
/// `systemd-detect-virt` (VM detection) is unavailable in phobos so VM types
/// are not reported — faithful to Moonraker's "none" default with no dbus.
pub fn parseVirtualization(cgroup_text: []const u8) VirtParse {
    const types = [_][]const u8{ "docker", "lxc" };
    for (types) |t| {
        if (std.mem.indexOf(u8, cgroup_text, t) != null) {
            return .{ .virt_type = "container", .virt_identifier = t };
        }
    }
    return .{};
}

fn buildVirtualization(ctx: *MachineCtx, alloc: std.mem.Allocator) !std.json.Value {
    var v: VirtParse = .{};
    if (ctx.io) |io| {
        if (readFile(io, alloc, CGROUP_PATH)) |txt| {
            v = parseVirtualization(txt);
        }
    }
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "virt_type", .{ .string = v.virt_type });
    try obj.put(alloc, "virt_identifier", .{ .string = v.virt_identifier });
    return .{ .object = obj };
}

// ===========================================================================
// system_info handler
// ===========================================================================

/// GET /machine/system_info → { "system_info": { ... } }
///
/// Full Moonraker shape: cpu_info, sd_info, distribution, virtualization,
/// network, canbus, python, available_services, service_state, instance_ids,
/// provider. Real values where readable; empty/default for systemd/dbus-only
/// fields.
pub fn handleSystemInfo(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *MachineCtx = @ptrCast(@alignCast(ctx_ptr));

    var sys: std.json.ObjectMap = .empty;

    try sys.put(alloc, "cpu_info", try buildCpuInfo(ctx, alloc));
    // sd_info: only populated on SBCs with an mmcblk0 SD card. Empty otherwise.
    try sys.put(alloc, "sd_info", .{ .object = .empty });
    try sys.put(alloc, "distribution", try buildDistribution(ctx, alloc));
    try sys.put(alloc, "virtualization", try buildVirtualization(ctx, alloc));
    // network/canbus require a NETLINK / `ip` shell walk; reported empty until
    // that subsystem lands. Shape (object) matches upstream.
    try sys.put(alloc, "network", .{ .object = .empty });
    try sys.put(alloc, "canbus", .{ .object = .empty });
    try sys.put(alloc, "python", try buildPython(alloc));
    // available_services / service_state require systemd. Empty (no dbus).
    try sys.put(alloc, "available_services", .{ .array = .init(alloc) });
    try sys.put(alloc, "service_state", .{ .object = .empty });
    try sys.put(alloc, "provider", .{ .string = "systemd_dbus" });

    // instance_ids: Moonraker's unit names. Defaults match a standard install.
    var ids: std.json.ObjectMap = .empty;
    try ids.put(alloc, "moonraker", .{ .string = "moonraker" });
    try ids.put(alloc, "klipper", .{ .string = "klipper" });
    try sys.put(alloc, "instance_ids", .{ .object = ids });

    var out: std.json.ObjectMap = .empty;
    try out.put(alloc, "system_info", .{ .object = sys });
    return .{ .object = out };
}

/// The `python` sub-object. phobos is not Python; we report the interpreter
/// shape Moonraker emits (version tuple + string) with phobos' identity so the
/// key set is present and honest.
fn buildPython(alloc: std.mem.Allocator) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    var ver: std.json.Array = .init(alloc);
    // Moonraker reports sys.version_info as a 5-tuple. phobos has no Python; we
    // emit a zeroed tuple so the shape (array of ints) is faithful.
    try ver.append(.{ .integer = 0 });
    try ver.append(.{ .integer = 0 });
    try ver.append(.{ .integer = 0 });
    try ver.append(.{ .string = "final" });
    try ver.append(.{ .integer = 0 });
    try obj.put(alloc, "version", .{ .array = ver });
    try obj.put(alloc, "version_string", .{ .string = "phobos (Zig reimplementation, no Python)" });
    return .{ .object = obj };
}

// ===========================================================================
// proc_stats handler
// ===========================================================================

/// Parse system-wide CPU usage line aggregates from /proc/stat. We compute a
/// single-sample utilisation snapshot (Moonraker tracks deltas; with one
/// request we report the instantaneous busy fraction since boot, which is a
/// faithful subset of the rolling shape). Returns per-cpu busy percent.
///
/// Robust against malformed lines. Returned map keys borrow `text`.
pub fn parseCpuStat(alloc: std.mem.Allocator, text: []const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "cpu")) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        const name = fields.next() orelse continue;
        var sum: i128 = 0;
        var idle: i128 = 0;
        var idx: usize = 0;
        while (fields.next()) |tok| : (idx += 1) {
            const v = std.fmt.parseInt(i128, tok, 10) catch break;
            sum += v;
            if (idx == 3) idle = v; // 4th value is idle
        }
        if (sum <= 0) continue;
        const used: f64 = @floatFromInt(sum - idle);
        const total: f64 = @floatFromInt(sum);
        const pct = std.math.round(100.0 * (used / total) * 100.0) / 100.0;
        try obj.put(alloc, try alloc.dupe(u8, name), .{ .float = pct });
    }
    return .{ .object = obj };
}

/// Parse MemTotal / MemAvailable into the system_memory shape
/// { total, available, used }. Robust against missing keys (omits them).
pub fn parseSystemMemory(alloc: std.mem.Allocator, text: []const u8) !std.json.Value {
    var total: ?i64 = null;
    var avail: ?i64 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "MemTotal:")) {
            total = parseSecondInt(trimmed);
        } else if (std.mem.startsWith(u8, trimmed, "MemAvailable:")) {
            avail = parseSecondInt(trimmed);
        }
    }
    var obj: std.json.ObjectMap = .empty;
    if (total) |t| try obj.put(alloc, "total", .{ .integer = t });
    if (avail) |a| try obj.put(alloc, "available", .{ .integer = a });
    if (total != null and avail != null) {
        try obj.put(alloc, "used", .{ .integer = total.? - avail.? });
    }
    return .{ .object = obj };
}

/// Extract the integer after the first token of a "Key: <int> kB" line.
fn parseSecondInt(line: []const u8) ?i64 {
    var fields = std.mem.tokenizeAny(u8, line, " \t\r");
    _ = fields.next(); // key
    const num = fields.next() orelse return null;
    return std.fmt.parseInt(i64, num, 10) catch null;
}

/// Parse /proc/net/dev into the network shape:
///   { "<dev>": { rx_bytes, tx_bytes, rx_packets, tx_packets,
///                rx_errs, tx_errs, rx_drop, tx_drop, bandwidth } }
/// Robust against the two header lines and malformed rows. Keys borrow `text`.
pub fn parseNetDev(alloc: std.mem.Allocator, text: []const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t\r");
        if (name.len == 0) continue;
        // Skip header rows ("Inter-|", "face |") which contain no colon+digits.
        var fields = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t\r");
        var vals: [16]i64 = undefined;
        var n: usize = 0;
        while (fields.next()) |tok| {
            if (n >= vals.len) break;
            vals[n] = std.fmt.parseInt(i64, tok, 10) catch {
                n = 0;
                break;
            };
            n += 1;
        }
        if (n < 16) continue;
        var dev: std.json.ObjectMap = .empty;
        try dev.put(alloc, "rx_bytes", .{ .integer = vals[0] });
        try dev.put(alloc, "tx_bytes", .{ .integer = vals[8] });
        try dev.put(alloc, "rx_packets", .{ .integer = vals[1] });
        try dev.put(alloc, "tx_packets", .{ .integer = vals[9] });
        try dev.put(alloc, "rx_errs", .{ .integer = vals[2] });
        try dev.put(alloc, "tx_errs", .{ .integer = vals[10] });
        try dev.put(alloc, "rx_drop", .{ .integer = vals[3] });
        try dev.put(alloc, "tx_drop", .{ .integer = vals[11] });
        try dev.put(alloc, "bandwidth", .{ .float = 0.0 });
        try obj.put(alloc, try alloc.dupe(u8, name), .{ .object = dev });
    }
    return .{ .object = obj };
}

/// Parse a thermal zone temp file (millidegrees C → float degrees). Returns
/// null on malformed input.
pub fn parseCpuTemp(text: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    const milli = std.fmt.parseInt(i64, trimmed, 10) catch return null;
    return @as(f64, @floatFromInt(milli)) / 1000.0;
}

/// GET /machine/proc_stats → Moonraker's proc_stats shape:
///   { moonraker_stats, throttled_state, cpu_temp, network,
///     system_cpu_usage, system_uptime, system_memory,
///     websocket_connections }
///
/// moonraker_stats is the rolling sample queue (Moonraker keeps the last 30
/// samples). Without a long-lived sampling timer phobos returns a single fresh
/// sample so the array shape is present and non-empty. throttled_state requires
/// a Raspberry Pi mailbox → null (matching upstream on non-Pi hosts).
pub fn handleProcStats(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *MachineCtx = @ptrCast(@alignCast(ctx_ptr));

    var cpu_temp: std.json.Value = .null;
    var network: std.json.Value = .{ .object = .empty };
    var sys_cpu: std.json.Value = .{ .object = .empty };
    var sys_mem: std.json.Value = .{ .object = .empty };

    if (ctx.io) |io| {
        if (readFile(io, alloc, TEMPERATURE_PATH)) |txt| {
            if (parseCpuTemp(txt)) |t| cpu_temp = .{ .float = t };
        }
        if (readFile(io, alloc, NET_DEV_PATH)) |txt| {
            network = try parseNetDev(alloc, txt);
        }
        if (readFile(io, alloc, CPU_STAT_PATH)) |txt| {
            sys_cpu = try parseCpuStat(alloc, txt);
        }
        if (readFile(io, alloc, MEMINFO_PATH)) |txt| {
            sys_mem = try parseSystemMemory(alloc, txt);
        }
    }

    // moonraker_stats: a single sample { time, cpu_usage, memory, mem_units }.
    var samples: std.json.Array = .init(alloc);
    var sample: std.json.ObjectMap = .empty;
    try sample.put(alloc, "time", .{ .float = nowSeconds() });
    try sample.put(alloc, "cpu_usage", .{ .float = 0.0 });
    try sample.put(alloc, "memory", .{ .integer = 0 });
    try sample.put(alloc, "mem_units", .{ .string = "kB" });
    try samples.append(.{ .object = sample });

    var out: std.json.ObjectMap = .empty;
    try out.put(alloc, "moonraker_stats", .{ .array = samples });
    try out.put(alloc, "throttled_state", .null);
    try out.put(alloc, "cpu_temp", cpu_temp);
    try out.put(alloc, "network", network);
    try out.put(alloc, "system_cpu_usage", sys_cpu);
    try out.put(alloc, "system_uptime", .{ .float = uptimeSeconds() });
    try out.put(alloc, "system_memory", sys_mem);
    try out.put(alloc, "websocket_connections", .{ .integer = 0 });
    return .{ .object = out };
}

fn nowSeconds() f64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1.0e9;
}

/// System uptime from CLOCK_BOOTTIME (seconds). 0 on failure.
fn uptimeSeconds() f64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.BOOTTIME, &ts);
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1.0e9;
}

// ===========================================================================
// reboot / shutdown (STUBBED — never touch the host)
// ===========================================================================

/// POST /machine/reboot → "ok". STUB: phobos does NOT reboot the host; this
/// validates the request and returns Moonraker's ack. Real reboot would call
/// the systemd-logind D-Bus `Reboot` method.
pub fn handleReboot(_: *anyopaque, _: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    return .{ .string = "ok" };
}

/// POST /machine/shutdown → "ok". STUB: phobos does NOT power off the host.
pub fn handleShutdown(_: *anyopaque, _: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    return .{ .string = "ok" };
}

// ===========================================================================
// services.{restart,stop,start} (STUBBED)
// ===========================================================================

/// True if a service name is allowed (matches machine.py `is_service_allowed`):
/// the default allowed list, or anything matching moonraker[_-]?\d* /
/// klipper[_-]?\d*.
pub fn isServiceAllowed(name: []const u8) bool {
    for (default_allowed_services) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return prefixWithOptIndex(name, "moonraker") or prefixWithOptIndex(name, "klipper");
}

/// Match `<base>` optionally followed by '_'/'-' then digits (and nothing
/// else): the `base[_-]?\d*` regex from machine.py.
fn prefixWithOptIndex(name: []const u8, base: []const u8) bool {
    if (!std.mem.startsWith(u8, name, base)) return false;
    var rest = name[base.len..];
    if (rest.len == 0) return true;
    if (rest[0] == '_' or rest[0] == '-') rest = rest[1..];
    for (rest) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Shared handler for the three service actions. STUB: validates the `service`
/// param against the allow-list and returns "ok"; never runs systemctl / dbus.
/// Disallowed services error like Moonraker ("Service '<x>' not allowed").
pub fn handleServiceAction(_: *anyopaque, params: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    const name = try getStr(params, "service");
    if (!isServiceAllowed(name)) return error.Forbidden;
    // STUB: a real implementation would call SystemdDbusProvider.do_service_action.
    return .{ .string = "ok" };
}

// ===========================================================================
// sudo.info / sudo.password
// ===========================================================================

/// GET /machine/sudo/info → { sudo_access, linux_user, sudo_requested,
///                            request_messages }
/// sudo_access is null unless check_access was requested (phobos cannot run a
/// real sudo probe → reports null even then, faithful to "unknown"). No pending
/// sudo requests in phobos, so sudo_requested=false / request_messages=[].
pub fn handleSudoInfo(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *MachineCtx = @ptrCast(@alignCast(ctx_ptr));
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "sudo_access", .null);
    try obj.put(alloc, "linux_user", .{ .string = linuxUser(ctx, alloc) });
    try obj.put(alloc, "sudo_requested", .{ .bool = false });
    try obj.put(alloc, "request_messages", .{ .array = .init(alloc) });
    return .{ .object = obj };
}

/// Best-effort current username, resolved from the effective uid via
/// /etc/passwd (read through the ctx io). Falls back to the numeric uid string.
/// (std.posix.getenv / std.process env access are unavailable on the static
/// musl target, so we resolve through passwd instead.)
fn linuxUser(ctx: *MachineCtx, alloc: std.mem.Allocator) []const u8 {
    const uid = std.os.linux.geteuid();
    if (ctx.io) |io| {
        if (readFile(io, alloc, "/etc/passwd")) |txt| {
            if (userForUid(txt, uid)) |name| return name;
        }
    }
    return std.fmt.allocPrint(alloc, "{d}", .{uid}) catch "";
}

/// Resolve a username for `uid` from /etc/passwd text. Pure & robust: scans
/// "name:x:uid:..." lines, returns the name slice (borrowing `text`) or null.
pub fn userForUid(text: []const u8, uid: u32) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const name = fields.next() orelse continue;
        _ = fields.next() orelse continue; // passwd field
        const uid_str = fields.next() orelse continue;
        const parsed = std.fmt.parseInt(u32, uid_str, 10) catch continue;
        if (parsed == uid and name.len != 0) return name;
    }
    return null;
}

/// POST /machine/sudo/password → { sudo_responses, is_restarting }
/// Stores the supplied password. STUB: phobos performs no real sudo access
/// check (no shell_command component yet), so it accepts the password and
/// reports the success ack shape without restarting.
pub fn handleSudoPassword(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *MachineCtx = @ptrCast(@alignCast(ctx_ptr));
    const pwd = try getStr(params, "password");

    // Persist (replace) the password under the ctx allocator.
    if (ctx.sudo_password) |old| ctx.gpa.free(old);
    ctx.sudo_password = try ctx.gpa.dupe(u8, pwd);

    var responses: std.json.Array = .init(alloc);
    try responses.append(.{ .string = "Sudo password successfully set." });

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "sudo_responses", .{ .array = responses });
    try obj.put(alloc, "is_restarting", .{ .bool = false });
    return .{ .object = obj };
}

// ===========================================================================
// peripherals.{usb,serial,video,canbus}
// ===========================================================================
//
// Enumerate from /sys and /dev where readable. Each handler returns the exact
// Moonraker response wrapper; the device lists are empty when the relevant
// sysfs trees are absent (typical on a dev workstation without the hardware).

/// GET /machine/peripherals/usb → { "usb_devices": [...] }
/// Enumerates /sys/bus/usb/devices. Each entry mirrors sysfs_devs.find_usb_devices.
pub fn handleUsb(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *MachineCtx = @ptrCast(@alignCast(ctx_ptr));
    var arr: std.json.Array = .init(alloc);
    if (ctx.io) |io| {
        enumUsb(io, alloc, &arr) catch {};
    }
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "usb_devices", .{ .array = arr });
    return .{ .object = obj };
}

fn enumUsb(io: std.Io, alloc: std.mem.Allocator, arr: *std.json.Array) !void {
    var dir = Dir.cwd().openDir(io, "/sys/bus/usb/devices", .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const base = try std.fs.path.join(alloc, &.{ "/sys/bus/usb/devices", entry.name });
        // Only device folders have a bDeviceClass file.
        const cls_path = try std.fs.path.join(alloc, &.{ base, "bDeviceClass" });
        const cls = sysAttr(io, alloc, cls_path) orelse continue;
        var dev: std.json.ObjectMap = .empty;
        const devnum = sysAttr(io, alloc, try std.fs.path.join(alloc, &.{ base, "devnum" })) orelse "";
        const busnum = sysAttr(io, alloc, try std.fs.path.join(alloc, &.{ base, "busnum" })) orelse "";
        const vid = sysAttr(io, alloc, try std.fs.path.join(alloc, &.{ base, "idVendor" })) orelse "";
        const pid = sysAttr(io, alloc, try std.fs.path.join(alloc, &.{ base, "idProduct" })) orelse "";
        try dev.put(alloc, "device_num", .{ .integer = std.fmt.parseInt(i64, devnum, 10) catch 0 });
        try dev.put(alloc, "bus_num", .{ .integer = std.fmt.parseInt(i64, busnum, 10) catch 0 });
        try dev.put(alloc, "vendor_id", .{ .string = try toLowerDup(alloc, vid) });
        try dev.put(alloc, "product_id", .{ .string = try toLowerDup(alloc, pid) });
        try dev.put(alloc, "usb_location", .{ .string = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ busnum, devnum }) });
        try dev.put(alloc, "manufacturer", manuf(io, alloc, base));
        try dev.put(alloc, "product", attrOrNull(io, alloc, base, "product"));
        try dev.put(alloc, "serial", attrOrNull(io, alloc, base, "serial"));
        try dev.put(alloc, "class", .null);
        try dev.put(alloc, "subclass", .null);
        try dev.put(alloc, "protocol", .null);
        try dev.put(alloc, "description", .null);
        _ = cls;
        try arr.append(.{ .object = dev });
    }
}

fn manuf(io: std.Io, alloc: std.mem.Allocator, base: []const u8) std.json.Value {
    return attrOrNull(io, alloc, base, "manufacturer");
}

fn attrOrNull(io: std.Io, alloc: std.mem.Allocator, base: []const u8, name: []const u8) std.json.Value {
    const p = std.fs.path.join(alloc, &.{ base, name }) catch return .null;
    const v = sysAttr(io, alloc, p) orelse return .null;
    return .{ .string = v };
}

/// Read a single sysfs attribute (one line), trimmed. null on any error.
fn sysAttr(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const raw = readFile(io, alloc, path) orelse return null;
    const t = std.mem.trim(u8, raw, " \t\r\n");
    return t;
}

fn toLowerDup(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    const buf = try alloc.alloc(u8, s.len);
    return std.ascii.lowerString(buf, s);
}

/// GET /machine/peripherals/serial → { "serial_devices": [...] }
/// Enumerates /sys/class/tty entries that have a backing device.
pub fn handleSerial(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *MachineCtx = @ptrCast(@alignCast(ctx_ptr));
    var arr: std.json.Array = .init(alloc);
    if (ctx.io) |io| {
        enumSerial(io, alloc, &arr) catch {};
    }
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "serial_devices", .{ .array = arr });
    return .{ .object = obj };
}

fn enumSerial(io: std.Io, alloc: std.mem.Allocator, arr: *std.json.Array) !void {
    var dir = Dir.cwd().openDir(io, "/sys/class/tty", .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const dev_dir = try std.fs.path.join(alloc, &.{ "/sys/class/tty", entry.name, "device" });
        // Skip ttys without a backing device folder.
        _ = Dir.cwd().statFile(io, dev_dir, .{}) catch continue;
        var dev: std.json.ObjectMap = .empty;
        try dev.put(alloc, "device_type", .{ .string = "unknown" });
        try dev.put(alloc, "device_path", .{ .string = try std.fmt.allocPrint(alloc, "/dev/{s}", .{entry.name}) });
        try dev.put(alloc, "device_name", .{ .string = try alloc.dupe(u8, entry.name) });
        try dev.put(alloc, "driver_name", .{ .string = "" });
        try dev.put(alloc, "path_by_hardware", .null);
        try dev.put(alloc, "path_by_id", .null);
        try dev.put(alloc, "usb_location", .null);
        try arr.append(.{ .object = dev });
    }
}

/// GET /machine/peripherals/video → { v4l2_devices, libcamera_devices }
/// Enumerates /sys/class/video4linux. libcamera is unavailable in phobos → [].
pub fn handleVideo(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *MachineCtx = @ptrCast(@alignCast(ctx_ptr));
    var v4l2: std.json.Array = .init(alloc);
    if (ctx.io) |io| {
        enumVideo(io, alloc, &v4l2) catch {};
    }
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "v4l2_devices", .{ .array = v4l2 });
    try obj.put(alloc, "libcamera_devices", .{ .array = .init(alloc) });
    return .{ .object = obj };
}

fn enumVideo(io: std.Io, alloc: std.mem.Allocator, arr: *std.json.Array) !void {
    var dir = Dir.cwd().openDir(io, "/sys/class/video4linux", .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        var dev: std.json.ObjectMap = .empty;
        try dev.put(alloc, "device_name", .{ .string = try alloc.dupe(u8, entry.name) });
        try dev.put(alloc, "device_path", .{ .string = try std.fmt.allocPrint(alloc, "/dev/{s}", .{entry.name}) });
        const name = sysAttr(io, alloc, std.fs.path.join(alloc, &.{ "/sys/class/video4linux", entry.name, "name" }) catch "") orelse "";
        try dev.put(alloc, "camera_name", .{ .string = name });
        try dev.put(alloc, "driver_name", .{ .string = "" });
        try dev.put(alloc, "alt_name", .{ .string = name });
        try dev.put(alloc, "hardware_bus", .{ .string = "" });
        try dev.put(alloc, "modes", .{ .array = .init(alloc) });
        try dev.put(alloc, "path_by_hardware", .null);
        try dev.put(alloc, "path_by_id", .null);
        try dev.put(alloc, "usb_location", .null);
        try arr.append(.{ .object = dev });
    }
}

/// GET /machine/peripherals/canbus → { "can_uuids": [...] }
/// Querying CAN UUIDs requires opening a SocketCAN socket and running the
/// Klipper admin protocol; phobos returns an empty list (no CAN bus probe).
pub fn handleCanbus(_: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    _ = getStrDefault(params, "interface", "can0"); // accepted, unused (stub)
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "can_uuids", .{ .array = .init(alloc) });
    return .{ .object = obj };
}

// ===========================================================================
// Registration
// ===========================================================================

pub fn registerMachine(reg: *Registry, ctx: *MachineCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    try reg.registerEndpoint(.{ .path = "/machine/system_info", .methods = &.{.GET} }, c, handleSystemInfo);
    try reg.registerEndpoint(.{ .path = "/machine/proc_stats", .methods = &.{.GET} }, c, handleProcStats);

    try reg.registerEndpoint(.{ .path = "/machine/reboot", .methods = &.{.POST} }, c, handleReboot);
    try reg.registerEndpoint(.{ .path = "/machine/shutdown", .methods = &.{.POST} }, c, handleShutdown);

    try reg.registerEndpoint(.{ .path = "/machine/services/restart", .methods = &.{.POST} }, c, handleServiceAction);
    try reg.registerEndpoint(.{ .path = "/machine/services/stop", .methods = &.{.POST} }, c, handleServiceAction);
    try reg.registerEndpoint(.{ .path = "/machine/services/start", .methods = &.{.POST} }, c, handleServiceAction);

    try reg.registerEndpoint(.{ .path = "/machine/sudo/info", .methods = &.{.GET} }, c, handleSudoInfo);
    try reg.registerEndpoint(.{ .path = "/machine/sudo/password", .methods = &.{.POST} }, c, handleSudoPassword);

    try reg.registerEndpoint(.{ .path = "/machine/peripherals/usb", .methods = &.{.GET} }, c, handleUsb);
    try reg.registerEndpoint(.{ .path = "/machine/peripherals/serial", .methods = &.{.GET} }, c, handleSerial);
    try reg.registerEndpoint(.{ .path = "/machine/peripherals/video", .methods = &.{.GET} }, c, handleVideo);
    try reg.registerEndpoint(.{ .path = "/machine/peripherals/canbus", .methods = &.{.GET} }, c, handleCanbus);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn objParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    return p.value;
}

fn testCtx(alloc: std.mem.Allocator) MachineCtx {
    return .{ .gpa = alloc, .io = null };
}

// ---- parseCpuinfo ----

test "parseCpuinfo: extracts model name as cpu_desc" {
    const txt = "processor\t: 0\nmodel name\t: AMD Ryzen 9 9950X 16-Core Processor\n\n" ++
        "processor\t: 1\nmodel name\t: AMD Ryzen 9 9950X 16-Core Processor\n";
    const r = parseCpuinfo(txt);
    try testing.expectEqualStrings("AMD Ryzen 9 9950X 16-Core Processor", r.cpu_desc);
}

test "parseCpuinfo: ARM Hardware/Serial/Model fields" {
    const txt = "processor\t: 0\nHardware\t: BCM2835\nSerial\t\t: 0000000012345678\n" ++
        "Model\t\t: Raspberry Pi 4 Model B Rev 1.4\n";
    const r = parseCpuinfo(txt);
    try testing.expectEqualStrings("BCM2835", r.hardware_desc);
    try testing.expectEqualStrings("12345678", r.serial_number); // leading zeros stripped
    try testing.expectEqualStrings("Raspberry Pi 4 Model B Rev 1.4", r.model);
}

test "parseCpuinfo: empty/garbage yields defaults" {
    try testing.expectEqualStrings("", parseCpuinfo("").cpu_desc);
    try testing.expectEqualStrings("", parseCpuinfo("garbage with no colon").cpu_desc);
    try testing.expectEqualStrings("", parseCpuinfo("model name :").cpu_desc); // empty value
}

test "parseCpuCount: counts processor lines, min 1" {
    try testing.expectEqual(@as(i64, 2), parseCpuCount("processor : 0\nprocessor : 1\n"));
    try testing.expectEqual(@as(i64, 1), parseCpuCount("no cpus here"));
    try testing.expectEqual(@as(i64, 1), parseCpuCount(""));
}

// ---- parseMemTotal ----

test "parseMemTotal: parses kB value and units" {
    const r = parseMemTotal("MemTotal:       129446704 kB\nMemFree: 5 kB\n");
    try testing.expectEqual(@as(i64, 129446704), r.total);
    try testing.expectEqualStrings("kB", r.units);
}

test "parseMemTotal: missing/garbage yields zero" {
    try testing.expectEqual(@as(i64, 0), parseMemTotal("").total);
    try testing.expectEqual(@as(i64, 0), parseMemTotal("MemTotal: notanumber kB").total);
    try testing.expectEqual(@as(i64, 0), parseMemTotal("MemFree: 5 kB").total);
}

// ---- parseOsRelease ----

test "parseOsRelease: quoted PRETTY_NAME and ID" {
    const txt =
        \\NAME="CachyOS Linux"
        \\PRETTY_NAME="CachyOS"
        \\ID=cachyos
        \\ID_LIKE=arch
        \\VERSION_ID=rolling
    ;
    const r = parseOsRelease(txt);
    try testing.expectEqualStrings("CachyOS", r.name);
    try testing.expectEqualStrings("cachyos", r.id);
    try testing.expectEqualStrings("arch", r.like);
    try testing.expectEqualStrings("rolling", r.version);
}

test "parseOsRelease: falls back to NAME when no PRETTY_NAME" {
    const r = parseOsRelease("NAME=\"Debian GNU/Linux\"\nID=debian\n");
    try testing.expectEqualStrings("Debian GNU/Linux", r.name);
    try testing.expectEqualStrings("debian", r.id);
}

test "parseOsRelease: empty/comment lines safe" {
    const r = parseOsRelease("# comment\n\nbadline_no_eq\nID=x\n");
    try testing.expectEqualStrings("x", r.id);
    try testing.expectEqualStrings("", r.name);
}

// ---- parseVirtualization ----

test "parseVirtualization: detects docker and lxc" {
    var r = parseVirtualization("0::/docker/abc123");
    try testing.expectEqualStrings("container", r.virt_type);
    try testing.expectEqualStrings("docker", r.virt_identifier);
    r = parseVirtualization("12:cpuset:/lxc/foo");
    try testing.expectEqualStrings("lxc", r.virt_identifier);
}

test "parseVirtualization: bare metal yields none" {
    const r = parseVirtualization("0::/init.scope\n");
    try testing.expectEqualStrings("none", r.virt_type);
    try testing.expectEqualStrings("none", r.virt_identifier);
    try testing.expectEqualStrings("none", parseVirtualization("").virt_type);
}

// ---- parseCpuStat ----

test "parseCpuStat: computes busy percent per cpu" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // cpu: user nice system idle iowait irq softirq ...
    const txt = "cpu  100 0 50 850 0 0 0 0\ncpu0 10 0 5 85 0 0 0\nintr 999\n";
    const v = try parseCpuStat(a, txt);
    // total=1000, idle=850 → used=150 → 15.0%
    try testing.expectEqual(@as(f64, 15.0), v.object.get("cpu").?.float);
    try testing.expect(v.object.get("cpu0") != null);
    try testing.expect(v.object.get("intr") == null);
}

test "parseCpuStat: garbage safe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parseCpuStat(a, "cpu garbage tokens here\ncpu\n");
    try testing.expectEqual(@as(usize, 0), v.object.count());
}

// ---- parseSystemMemory ----

test "parseSystemMemory: total/available/used" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parseSystemMemory(a, "MemTotal: 1000 kB\nMemAvailable: 400 kB\n");
    try testing.expectEqual(@as(i64, 1000), v.object.get("total").?.integer);
    try testing.expectEqual(@as(i64, 400), v.object.get("available").?.integer);
    try testing.expectEqual(@as(i64, 600), v.object.get("used").?.integer);
}

test "parseSystemMemory: missing available omits used" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parseSystemMemory(a, "MemTotal: 1000 kB\n");
    try testing.expect(v.object.get("total") != null);
    try testing.expect(v.object.get("used") == null);
}

// ---- parseNetDev ----

test "parseNetDev: parses device rows, skips headers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const txt =
        \\Inter-|   Receive
        \\ face |bytes    packets errs drop fifo frame compressed multicast|bytes packets
        \\    lo: 1142450583 2033434 0 0 0 0 0 0 1142450583 2033434 0 0 0 0 0 0
    ;
    const v = try parseNetDev(a, txt);
    const lo = v.object.get("lo").?.object;
    try testing.expectEqual(@as(i64, 1142450583), lo.get("rx_bytes").?.integer);
    try testing.expectEqual(@as(i64, 1142450583), lo.get("tx_bytes").?.integer);
    try testing.expectEqual(@as(i64, 2033434), lo.get("rx_packets").?.integer);
    try testing.expect(lo.get("bandwidth") != null);
}

test "parseNetDev: garbage safe (no crash, empty)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parseNetDev(a, "eth0: not enough fields\nrandom\n");
    try testing.expectEqual(@as(usize, 0), v.object.count());
}

// ---- parseCpuTemp ----

test "parseCpuTemp: millidegrees to degrees" {
    try testing.expectEqual(@as(f64, 42.5), parseCpuTemp("42500\n").?);
    try testing.expect(parseCpuTemp("") == null);
    try testing.expect(parseCpuTemp("notanumber") == null);
}

// ---- isServiceAllowed ----

test "isServiceAllowed: defaults and moonraker/klipper patterns" {
    try testing.expect(isServiceAllowed("klipper"));
    try testing.expect(isServiceAllowed("crowsnest"));
    try testing.expect(isServiceAllowed("moonraker"));
    try testing.expect(isServiceAllowed("moonraker_1"));
    try testing.expect(isServiceAllowed("klipper-2"));
    try testing.expect(isServiceAllowed("moonraker2"));
    try testing.expect(!isServiceAllowed("sshd"));
    try testing.expect(!isServiceAllowed("moonraker_foo"));
    try testing.expect(!isServiceAllowed(""));
}

// ---- userForUid ----

test "userForUid: resolves name from passwd text" {
    const txt = "root:x:0:0:root:/root:/bin/bash\nmaci:x:1000:1000::/home/maci:/bin/zsh\n";
    try testing.expectEqualStrings("root", userForUid(txt, 0).?);
    try testing.expectEqualStrings("maci", userForUid(txt, 1000).?);
    try testing.expect(userForUid(txt, 4242) == null);
    try testing.expect(userForUid("garbage\nno colons", 0) == null);
    try testing.expect(userForUid("", 0) == null);
}

// ---- handlers (unit, io=null → empty/default shapes) ----

test "handleSystemInfo: full shape present" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = testCtx(a);
    const r = try handleSystemInfo(@ptrCast(&c), .null, a);
    const si = r.object.get("system_info").?.object;
    for ([_][]const u8{ "cpu_info", "sd_info", "distribution", "virtualization", "network", "canbus", "python", "available_services", "service_state", "instance_ids", "provider" }) |k| {
        try testing.expect(si.get(k) != null);
    }
    try testing.expect(si.get("cpu_info").?.object.get("cpu_count") != null);
    try testing.expect(si.get("instance_ids").?.object.get("moonraker") != null);
}

test "handleProcStats: full shape present" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = testCtx(a);
    const r = try handleProcStats(@ptrCast(&c), .null, a);
    const o = r.object;
    for ([_][]const u8{ "moonraker_stats", "throttled_state", "cpu_temp", "network", "system_cpu_usage", "system_uptime", "system_memory", "websocket_connections" }) |k| {
        try testing.expect(o.get(k) != null);
    }
    try testing.expect(o.get("moonraker_stats").? == .array);
    try testing.expectEqual(@as(usize, 1), o.get("moonraker_stats").?.array.items.len);
}

test "handleReboot/handleShutdown: ack ok" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("ok", (try handleReboot(undefined, .null, a)).string);
    try testing.expectEqualStrings("ok", (try handleShutdown(undefined, .null, a)).string);
}

test "handleServiceAction: allowed ok, disallowed Forbidden" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try handleServiceAction(undefined, try objParams(a, "{\"service\":\"klipper\"}"), a);
    try testing.expectEqualStrings("ok", ok.string);
    try testing.expectError(error.Forbidden, handleServiceAction(undefined, try objParams(a, "{\"service\":\"sshd\"}"), a));
    try testing.expectError(error.InvalidParams, handleServiceAction(undefined, .null, a));
}

test "handleSudoInfo: shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = testCtx(a);
    const r = try handleSudoInfo(@ptrCast(&c), .null, a);
    try testing.expect(r.object.get("sudo_access").? == .null);
    try testing.expect(r.object.get("linux_user") != null);
    try testing.expectEqual(false, r.object.get("sudo_requested").?.bool);
    try testing.expect(r.object.get("request_messages").? == .array);
}

test "handleSudoPassword: stores password and acks" {
    var c = testCtx(testing.allocator);
    defer c.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try handleSudoPassword(@ptrCast(&c), try objParams(a, "{\"password\":\"hunter2\"}"), a);
    try testing.expectEqual(false, r.object.get("is_restarting").?.bool);
    try testing.expectEqual(@as(usize, 1), r.object.get("sudo_responses").?.array.items.len);
    try testing.expectEqualStrings("hunter2", c.sudo_password.?);
    // overwrite works without leaking (checked by allocator)
    _ = try handleSudoPassword(@ptrCast(&c), try objParams(a, "{\"password\":\"new\"}"), a);
    try testing.expectEqualStrings("new", c.sudo_password.?);
}

test "handleSudoPassword: missing param errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = testCtx(a);
    try testing.expectError(error.InvalidParams, handleSudoPassword(@ptrCast(&c), .null, a));
}

test "peripherals: empty/default shapes with io=null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = testCtx(a);

    const usb = try handleUsb(@ptrCast(&c), .null, a);
    try testing.expectEqual(@as(usize, 0), usb.object.get("usb_devices").?.array.items.len);

    const ser = try handleSerial(@ptrCast(&c), .null, a);
    try testing.expect(ser.object.get("serial_devices").? == .array);

    const vid = try handleVideo(@ptrCast(&c), .null, a);
    try testing.expect(vid.object.get("v4l2_devices").? == .array);
    try testing.expect(vid.object.get("libcamera_devices").? == .array);

    const can = try handleCanbus(@ptrCast(&c), .null, a);
    try testing.expect(can.object.get("can_uuids").? == .array);
}

// ---- fuzz: proc parsers must never crash on malformed/truncated input ----

test "fuzz_machine_parsers: arbitrary bytes never crash any /proc parser" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const n = @as(usize, buf[0]) % buf.len;
            const text = buf[0..n];

            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            // None of these may panic on garbage.
            _ = parseCpuinfo(text);
            _ = parseCpuCount(text);
            _ = parseMemTotal(text);
            _ = parseOsRelease(text);
            _ = parseVirtualization(text);
            _ = parseCpuTemp(text);
            _ = userForUid(text, 0);
            _ = try parseCpuStat(a, text);
            _ = try parseSystemMemory(a, text);
            _ = try parseNetDev(a, text);
        }
    }.run, .{});
}

test "fuzz_machine_service: isServiceAllowed never crashes on arbitrary names" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const n = @as(usize, buf[0]) % buf.len;
            _ = isServiceAllowed(buf[0..n]);
        }
    }.run, .{});
}

test "fuzz_machine_handlers: system_info/proc_stats never crash with arbitrary params" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [32]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var c = MachineCtx{ .gpa = a, .io = null };
            // params irrelevant for these GET handlers; pass null.
            _ = handleSystemInfo(@ptrCast(&c), .null, a) catch {};
            _ = handleProcStats(@ptrCast(&c), .null, a) catch {};
        }
    }.run, .{});
}
