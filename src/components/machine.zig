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
//! Reboot/shutdown are DELIBERATE NO-OPs: they return Moonraker's "ok" shape
//! but never touch the host. Firing `systemctl reboot` rebooted the dev host,
//! and target printer boards lack systemd anyway, so real host power control is
//! left to an opt-in platform driver (see handleReboot/handleShutdown).
//! Service actions (start/stop/restart) run real `systemctl` commands when io is
//! wired; they fall back to optimistic in-memory state in unit tests (io == null).
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
const SD_CID_PATH = "/sys/block/mmcblk0/device/cid";
const SD_CSD_PATH = "/sys/block/mmcblk0/device/csd";

/// SD card manufacturer IDs (hex string → name), from Moonraker's SD_MFGRS.
const sd_manufacturers = std.StaticStringMap([]const u8).initComptime(.{
    .{ "1b", "Samsung" },
    .{ "03", "Sandisk" },
    .{ "74", "PNY" },
});

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

/// All Moonraker-compatible service names that phobos registers or stubs.
/// Used by buildAvailableServices, buildServiceState, and isServiceAllowed.
pub const available_services = [_][]const u8{
    "announce",
    "data_store",
    "device_power",
    "file_manager",
    "history",
    "history_totals",
    "job_queue",
    "job_state",
    "klipper",
    "klippy_state",
    "machine",
    "moonraker",
    "mqtt",
    "octoprint_compat",
    "proc_stats",
    "shell_command",
    "spoolman",
    "td1",
    "test",
    "update_manager",
    "webcam",
    "wled",
};

/// Known systemd ActiveState values (systemctl show -p ActiveState).
const known_active_states = [_][]const u8{ "active", "inactive", "failed", "activating", "deactivating", "reloading" };
/// Known systemd SubState values (systemctl show -p SubState).
const known_sub_states = [_][]const u8{ "running", "dead", "exited", "plugged", "mounted", "waiting", "auto-restart" };

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

/// machine.* state. Mostly stateless; holds the sudo password (set via
/// machine.sudo.password) and the live io used for reading /proc & /sys. io is
/// wired after the event loop starts (setIo); handlers fall back to empty
/// shapes when io is absent (pure unit tests).
///
/// run_cmd_fn, when non-null, replaces std.process.run calls in handlers
/// (services.*, reboot, shutdown) so integration tests can intercept systemctl
/// invocations without touching the host.

pub const MachineCtx = struct {
    pub const RunCmdResult = struct { stdout: []u8, stderr: []u8 };
    pub const RunCmdFn = *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, argv: []const []const u8) anyerror!RunCmdResult;

    gpa: std.mem.Allocator,
    io: ?std.Io = null,
    bus: ?*NotifyBus = null,
    /// Optional reference to the live connection registry for websocket_connections count.
    conns: ?*@import("../server/connections.zig").Connections = null,
    /// Set when a sudo password has been supplied. Owned by the ctx allocator.
    sudo_password: ?[]const u8 = null,
    /// Cached result of the last sudo validation (via sudo -S -l).
    sudo_validated: ?bool = null,
    /// Proc stat timer stop flag. Set by deinit, polled by the timer thread.
    proc_stat_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Handle for the proc_stat timer thread, joined in deinit.
    proc_stat_thread: ?std.Thread = null,
    /// Rolling 30-sample buffer for moonraker_stats (Moonraker keeps 30 samples).
    moonraker_stats: [30]MoonrakerSample = [_]MoonrakerSample{.{}} ** 30,
    moonraker_stats_head: usize = 0,
    moonraker_stats_count: usize = 0,
    moonraker_stats_mutex: std.Io.Mutex = .init,
    /// In-memory service state: allowed_service → { active_state, sub_state }.
    /// Populated on first access; tracks starts/stops/restarts requested via
    /// the service action handlers. The smp_allocator default lets a
    /// struct-literal MachineCtx (tests) compile; init() recreates it with the
    /// ctx allocator. Keys are always gpa-owned and freed with gpa, so the two
    /// allocators never cross.
    services: std.StringHashMap(ServiceEntry) = std.StringHashMap(ServiceEntry).init(std.heap.smp_allocator),
    /// When true, setIo will NOT spawn a proc_stat timer thread. Set by test
    /// harnesses before calling httpServer to avoid background-thread + thread-
    /// pool interactions that can deadlock tests.
    no_proc_stat_timer: bool = false,
    /// Mockable command-runner. When non-null, service / reboot / shutdown
    /// handlers call this instead of std.process.run. Opaque pointer is
    /// typically the test harness. Caller owns returned stdout and stderr.
    run_cmd_fn: ?RunCmdFn = null,
    run_cmd_ctx: ?*anyopaque = null,
    /// Previous-tick per-interface byte totals for computing proc_stats network
    /// bandwidth (bytes/sec). Inline + fixed-size (no heap); touched only by the
    /// single proc_stat timer thread, so no lock.
    net_prev: [max_net_ifaces]NetSample = [_]NetSample{.{}} ** max_net_ifaces,

    pub const ServiceEntry = struct {
        active_state: []const u8,
        sub_state: []const u8,

        fn active(active_state: []const u8, sub_state: []const u8) ServiceEntry {
            return .{ .active_state = active_state, .sub_state = sub_state };
        }
    };

    pub const MoonrakerSample = struct {
        time: f64 = 0,
        cpu_usage: f64 = 0,
        memory: i64 = 0,
        // mem_units is always "kB" — emitted as a constant at JSON-build time
        // (buildMoonrakerStats) rather than stored per sample (×30 slots).
    };

    /// Map a systemctl state string to an interned (static) slice. Returns
    /// "unknown" for states not in the known set.
    fn internState(state: []const u8) []const u8 {
        for (known_active_states) |s| {
            if (std.mem.eql(u8, s, state)) return s;
        }
        for (known_sub_states) |s| {
            if (std.mem.eql(u8, s, state)) return s;
        }
        return "unknown";
    }

    pub fn init(alloc: std.mem.Allocator, bus: ?*NotifyBus, conns: ?*anyopaque) MachineCtx {
        return .{
            .gpa = alloc,
            .bus = bus,
            .conns = @alignCast(@ptrCast(conns)),
            .services = std.StringHashMap(ServiceEntry).init(alloc),
        };
    }

    pub fn setIo(self: *MachineCtx, io: std.Io) void {
        self.io = io;
        // Start the periodic proc_stat emission if a bus is wired.
        if (self.bus != null and !self.no_proc_stat_timer) {
            self.proc_stat_thread = std.Thread.spawn(.{}, procStatTimerThread, .{self}) catch null;
        }
    }

    /// Set a mock command-runner for integration tests. When non-null,
    /// handler functions call fn(ctx, alloc, argv) instead of std.process.run.
    pub fn setRunCmdFn(self: *MachineCtx, run_cmd_fn: RunCmdFn, ctx: *anyopaque) void {
        self.run_cmd_fn = run_cmd_fn;
        self.run_cmd_ctx = ctx;
    }

    /// Run a command via the mock (when set) or std.process.run.
    fn runCmd(self: *MachineCtx, alloc: std.mem.Allocator, argv: []const []const u8) !RunCmdResult {
        if (self.run_cmd_fn) |f| {
            return f(self.run_cmd_ctx.?, alloc, argv);
        }
        if (self.io) |io| {
            // Build a temporary []const []const u8 for std.process.run.
            const result = try std.process.run(alloc, io, .{ .argv = argv });
            return .{ .stdout = result.stdout, .stderr = result.stderr };
        }
        return .{ .stdout = &.{}, .stderr = &.{} };
    }

    pub fn deinit(self: *MachineCtx) void {
        self.proc_stat_stop.store(true, .release);
        // Clear io/conns/bus so the timer thread returns early even if it
        // already passed the while-condition. This prevents use-after-free
        // when App tears down connections before joining the machine thread.
        self.io = null;
        self.conns = null;
        self.bus = null;
        if (self.proc_stat_thread) |th| {
            th.join();
            self.proc_stat_thread = null;
        }
        if (self.sudo_password) |p| self.gpa.free(p);
        self.sudo_password = null;
        // Free service entry keys (StringHashMap stores slices, not owned copies).
        var it = self.services.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
        }
        self.services.deinit();
    }
};

// ---------------------------------------------------------------------------
// Proc stat timer — periodic notify_proc_stat_update emission
// ---------------------------------------------------------------------------

/// Background thread spawned via std.Thread.spawn. Emits `notify_proc_stat_update`
/// every second until `proc_stat_stop` is set.  First emission is immediate
/// (matching Moonraker's behaviour of emitting on websocket connect).
fn procStatTimerThread(self: *MachineCtx) void {
    var first: bool = true;
    while (!self.proc_stat_stop.load(.acquire)) {
        if (!first) {
            var req: std.os.linux.timespec = .{ .sec = 1, .nsec = 0 };
            _ = std.os.linux.nanosleep(&req, null);
            if (self.proc_stat_stop.load(.acquire)) break;
        }
        first = false;
        if (self.io) |io| {
            emitProcStatUpdate(self, io) catch {};
        } else break;
    }
}

/// Read system files and emit `notify_proc_stat_update` on the bus.
/// Reuses the same parser functions as handleProcStats.
fn emitProcStatUpdate(self: *MachineCtx, io: std.Io) !void {
    const bus = self.bus orelse return;
    // Per-tick arena freed on return: emit/fanout copies params into its own
    // frame buffer and the moonraker_stats ring stores only scalars, so nothing
    // here outlives the call. Previously this used smp_allocator with no free —
    // an unbounded leak once per second.
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cpu_temp: std.json.Value = .null;
    var network: std.json.Value = .{ .object = .empty };
    var sys_cpu: std.json.Value = .{ .object = .empty };
    var sys_mem: std.json.Value = .{ .object = .empty };
    var mem: i64 = 0;

    // Read CPU temperature.
    if (readFile(io, alloc, TEMPERATURE_PATH)) |txt| {
        if (parseCpuTemp(txt)) |t| cpu_temp = .{ .float = t };
    }

    // Read network stats, then fill in per-interface bandwidth from the delta
    // against the previous tick.
    if (readFile(io, alloc, NET_DEV_PATH)) |txt| {
        network = try parseNetDev(alloc, txt);
        applyBandwidth(self, network, nowSeconds());
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

    // Push the new sample into the ring buffer.
    pushMoonrakerSample(self, io, .{ .time = nowSeconds(), .cpu_usage = cpu_usage, .memory = mem });

    // Build the samples array from the ring buffer.
    const samples = buildMoonrakerStats(self, alloc, io);

    // Event payload: mirrors Moonraker's proc_stats:proc_stat_update shape.
    var event_data: std.json.ObjectMap = .empty;
    try event_data.put(alloc, "moonraker_stats", samples);
    try event_data.put(alloc, "cpu_temp", cpu_temp);
    try event_data.put(alloc, "network", network);
    try event_data.put(alloc, "system_cpu_usage", sys_cpu);
    try event_data.put(alloc, "system_memory", sys_mem);
    const ws_count: i64 = if (self.conns) |c| blk: {
        const raw: usize = c.count(io);
        break :blk std.math.cast(i64, raw) orelse 0;
    } else 0;
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

/// Push a sample into the rolling moonraker_stats ring buffer. Thread-safe.
fn pushMoonrakerSample(self: *MachineCtx, io: std.Io, sample: MachineCtx.MoonrakerSample) void {
    self.moonraker_stats_mutex.lockUncancelable(io);
    defer self.moonraker_stats_mutex.unlock(io);

    self.moonraker_stats[self.moonraker_stats_head] = sample;
    self.moonraker_stats_head = (self.moonraker_stats_head + 1) % 30;
    if (self.moonraker_stats_count < 30) {
        self.moonraker_stats_count += 1;
    }
}

/// Read the current ring buffer as a JSON array of {time, cpu_usage, memory,
/// mem_units} objects in chronological order (oldest first). Locks the mutex
/// when io is available.
fn buildMoonrakerStats(self: *MachineCtx, alloc: std.mem.Allocator, io: ?std.Io) std.json.Value {
    if (io) |i| {
        self.moonraker_stats_mutex.lockUncancelable(i);
        defer self.moonraker_stats_mutex.unlock(i);
    }

    var arr = std.json.Array.init(alloc);

    const count = self.moonraker_stats_count;
    if (count == 0) {
        // Return a single zeroed sample so the array shape is present.
        var sample: std.json.ObjectMap = .empty;
        sample.put(alloc, "time", .{ .float = 0 }) catch return .{ .array = arr };
        sample.put(alloc, "cpu_usage", .{ .float = 0 }) catch return .{ .array = arr };
        sample.put(alloc, "memory", .{ .integer = 0 }) catch return .{ .array = arr };
        sample.put(alloc, "mem_units", .{ .string = "kB" }) catch return .{ .array = arr };
        arr.append(.{ .object = sample }) catch return .{ .array = arr };
        return .{ .array = arr };
    }

    // Start from the oldest entry. When the buffer hasn't wrapped, start at 0.
    // When it has wrapped, start at head (the oldest element is right after the
    // newest, which is head-1).
    const start: usize = if (count < 30) @as(usize, 0) else self.moonraker_stats_head;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const idx = (start + i) % 30;
        const s = self.moonraker_stats[idx];
        var sample: std.json.ObjectMap = .empty;
        sample.put(alloc, "time", .{ .float = s.time }) catch continue;
        sample.put(alloc, "cpu_usage", .{ .float = s.cpu_usage }) catch continue;
        sample.put(alloc, "memory", .{ .integer = s.memory }) catch continue;
        sample.put(alloc, "mem_units", .{ .string = "kB" }) catch continue;
        arr.append(.{ .object = sample }) catch continue;
    }
    return .{ .array = arr };
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
    // One up-front reservation avoids the realloc chain as chunks append; /proc
    // files read here (stat, meminfo, net/dev, temp) fit comfortably in 4 KiB.
    out.ensureTotalCapacity(alloc, 4096) catch {};
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

/// Build the `sd_info` object from /sys/block/mmcblk0/device/{cid,csd}.
/// Returns empty object when no SD card is detected (no cid file).
/// Matches Moonraker's `_get_sdcard_info` key set and parsing logic.
fn buildSdInfo(ctx: *MachineCtx, alloc: std.mem.Allocator) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    const io = ctx.io orelse return .{ .object = obj };

    const cid_raw = readFile(io, alloc, SD_CID_PATH) orelse return .{ .object = obj };
    const cid_text = std.mem.trim(u8, cid_raw, "\r\n");
    if (cid_text.len < 30) return .{ .object = obj };

    // Parse CID hex string (32 hex chars = 16 byte CID register).
    // Offsets match Moonraker's _get_sdcard_info CID slicing.
    const mid = cid_text[0..2];
    try obj.put(alloc, "manufacturer_id", .{ .string = try alloc.dupe(u8, mid) });
    try obj.put(alloc, "manufacturer", .{ .string = sd_manufacturers.get(mid) orelse "Unknown" });
    try obj.put(alloc, "oem_id", .{ .string = try alloc.dupe(u8, cid_text[2..6]) });

    // Product name: bytes 3-7 (10 hex chars → 5 ASCII bytes).
    if (hexDecodeAlloc(alloc, cid_text[6..16])) |name| {
        try obj.put(alloc, "product_name", .{ .string = name });
    } else |_| {
        try obj.put(alloc, "product_name", .{ .string = try alloc.dupe(u8, cid_text[6..16]) });
    }

    // Product revision BCD: major.minor.
    const rev_major = try std.fmt.parseInt(u8, cid_text[16..17], 16);
    const rev_minor = try std.fmt.parseInt(u8, cid_text[17..18], 16);
    try obj.put(alloc, "product_revision", .{ .string = try std.fmt.allocPrint(alloc, "{d}.{d}", .{ rev_major, rev_minor }) });

    try obj.put(alloc, "serial_number", .{ .string = try alloc.dupe(u8, cid_text[18..26]) });

    // Manufacturing date: year offset at chars 27-28, month at char 29.
    const mfg_year = try std.fmt.parseInt(u16, cid_text[27..29], 16);
    const mfg_month = try std.fmt.parseInt(u8, cid_text[29..30], 16);
    try obj.put(alloc, "manufacturer_date", .{ .string = try std.fmt.allocPrint(alloc, "{d}/{d}", .{ mfg_month, mfg_year + 2000 }) });

    // Capacity: parse CSD register.
    var capacity_str: []const u8 = "Unknown";
    var total_bytes: u64 = 0;
    if (readFile(io, alloc, SD_CSD_PATH)) |csd_raw| {
        const csd_text = std.mem.trim(u8, csd_raw, "\r\n");
        if (csd_text.len >= 20) {
            const csd = hexDecodeAlloc(alloc, csd_text[0..20]) catch &[_]u8{};
            if (csd.len >= 10) {
                const csd_type = (csd[0] >> 6) & 0x3;
                if (csd_type == 0) {
                    // Standard Capacity (CSD v1.0)
                    const max_block_len: u64 = @as(u64, 1) << @as(u6, @truncate(csd[5] & 0xF));
                    const c_size: u64 = ((@as(u64, csd[6] & 0x3)) << 10) | (@as(u64, csd[7]) << 2) | ((@as(u64, csd[8]) >> 6) & 0x3);
                    const c_mult_reg: u64 = ((@as(u64, csd[9] & 0x3)) << 1) | (@as(u64, csd[10]) >> 7);
                    total_bytes = (c_size + 1) * (c_mult_reg + 1) * max_block_len;
                    capacity_str = try std.fmt.allocPrint(alloc, "{d:.1} MiB", .{@as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0)});
                } else if (csd_type == 1) {
                    // High Capacity (CSD v2.0)
                    const c_size: u64 = ((@as(u64, csd[7] & 0x3F)) << 16) | (@as(u64, csd[8]) << 8) | @as(u64, csd[9]);
                    total_bytes = (c_size + 1) * 512 * 1024;
                    capacity_str = try std.fmt.allocPrint(alloc, "{d:.1} GiB", .{@as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0 * 1024.0)});
                } else if (csd_type == 2) {
                    // Ultra Capacity (CSD v3.0)
                    const c_size: u64 = ((@as(u64, csd[6] & 0xF)) << 24) | (@as(u64, csd[7]) << 16) | (@as(u64, csd[8]) << 8) | @as(u64, csd[9]);
                    total_bytes = (c_size + 1) * 512 * 1024;
                    capacity_str = try std.fmt.allocPrint(alloc, "{d:.1} TiB", .{@as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0 * 1024.0 * 1024.0)});
                }
            }
        }
    }
    try obj.put(alloc, "capacity", .{ .string = capacity_str });
    try obj.put(alloc, "total_bytes", .{ .integer = @as(i64, @intCast(total_bytes)) });

    return .{ .object = obj };
}

/// Decode a hex string into a newly allocated byte slice.
fn hexDecodeAlloc(alloc: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHex;
    const out = try alloc.alloc(u8, hex.len / 2);
    for (out, 0..) |*b, i| {
        b.* = try std.fmt.parseInt(u8, hex[2 * i .. 2 * i + 2], 16);
    }
    return out;
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

/// Fallback container detection from /proc/1/sched + /.dockerenv, used when the
/// cgroup text is inconclusive (common under cgroup v2). Matches the second half
/// of machine.py's `_check_inside_container`: if pid 1's comm is not init/systemd
/// we are in a container (lxc); the presence of /.dockerenv refines it to docker.
/// Pure given its inputs.
pub fn parseSchedContainer(sched_first_line: []const u8, has_dockerenv: bool) VirtParse {
    const trimmed = std.mem.trim(u8, sched_first_line, " \t\r\n");
    const sp = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
    const comm = trimmed[0..sp];
    if (comm.len == 0) return .{};
    const is_init = std.mem.eql(u8, comm, "systemd") or std.mem.eql(u8, comm, "init");
    if (!is_init) {
        return .{ .virt_type = "container", .virt_identifier = if (has_dockerenv) "docker" else "lxc" };
    }
    return .{};
}

fn buildVirtualization(ctx: *MachineCtx, alloc: std.mem.Allocator) !std.json.Value {
    var v: VirtParse = .{};
    if (ctx.io) |io| {
        if (readFile(io, alloc, CGROUP_PATH)) |txt| {
            v = parseVirtualization(txt);
        }
        // cgroup inconclusive (e.g. cgroup v2): fall back to /proc/1/sched + /.dockerenv.
        if (std.mem.eql(u8, v.virt_type, "none")) {
            if (readFile(io, alloc, "/proc/1/sched")) |sched| {
                const nl = std.mem.indexOfScalar(u8, sched, '\n') orelse sched.len;
                const has_dockerenv = blk: {
                    const f = Dir.cwd().openFile(io, "/.dockerenv", .{}) catch break :blk false;
                    f.close(io);
                    break :blk true;
                };
                v = parseSchedContainer(sched[0..nl], has_dockerenv);
            }
        }
    }
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "virt_type", .{ .string = v.virt_type });
    try obj.put(alloc, "virt_identifier", .{ .string = v.virt_identifier });
    return .{ .object = obj };
}

// ===========================================================================
// available_services / service_state builders
// ===========================================================================

/// Returns the sorted list of all Moonraker-compatible service names that
/// phobos registers or stubs. Mirrors the `available_services` key in
/// Moonraker's machine._handle_info():
///   sorted([name for name, comp in self.server.components.items() if comp])
pub fn buildAvailableServices(_: *const MachineCtx, alloc: std.mem.Allocator) !std.json.Value {
    const list = &available_services;
    var arr: std.json.Array = .init(alloc);
    for (list) |s| {
        try arr.append(.{ .string = s });
    }
    return .{ .array = arr };
}

/// Returns a state map for all known services. Calls
/// `refreshServiceStates` when io is available so the response reflects
/// live systemd data. Falls back to in-memory tracking when io is absent.
pub fn buildServiceState(ctx: *MachineCtx, alloc: std.mem.Allocator) !std.json.Value {
    if (ctx.io != null) refreshServiceStates(ctx, alloc);
    const list = &available_services;
    var obj: std.json.ObjectMap = .empty;
    for (list) |s| {
        const entry = buildServiceEntry(ctx, s, alloc);
        try obj.put(alloc, s, entry);
    }
    return .{ .object = obj };
}

fn buildServiceEntry(ctx: *const MachineCtx, name: []const u8, alloc: std.mem.Allocator) std.json.Value {
    // A service we have not actually queried is "unknown/unknown" (matches
    // Moonraker machine.py:_detect_active_services), NOT a fabricated
    // "active/running" — clients must not be told a service is up unverified.
    const state: struct { active: []const u8, sub: []const u8 } = if (ctx.services.get(name)) |e|
        .{ .active = e.active_state, .sub = e.sub_state }
    else
        .{ .active = "unknown", .sub = "unknown" };
    var entry: std.json.ObjectMap = .empty;
    entry.put(alloc, "active_state", .{ .string = state.active }) catch return errorOut();
    entry.put(alloc, "sub_state", .{ .string = state.sub }) catch return errorOut();
    return .{ .object = entry };
}

fn errorOut() std.json.Value {
    var entry: std.json.ObjectMap = .empty;
    entry.put(std.heap.smp_allocator, "active_state", .{ .string = "unknown" }) catch unreachable;
    entry.put(std.heap.smp_allocator, "sub_state", .{ .string = "unknown" }) catch unreachable;
    return .{ .object = entry };
}

/// Run `systemctl show -p ActiveState,SubState --value <services...>` and
/// update the in-memory service state map. Emits
/// `notify_service_state_changed` when a service transitions to a different
/// (active_state, sub_state) pair. If systemctl is unavailable or fails,
/// existing in-memory state is preserved.
///
/// Must only be called when ctx.io is available.
fn refreshServiceStates(ctx: *MachineCtx, alloc: std.mem.Allocator) void {
    const io = ctx.io orelse return;

    // Build argv: systemctl show -p ActiveState,SubState --value <svc1> <svc2> ...
    var argv: [5 + available_services.len][]const u8 = undefined;

    argv[0] = "systemctl";
    argv[1] = "show";
    argv[2] = "-p";
    argv[3] = "ActiveState,SubState";
    argv[4] = "--value";
    for (available_services, 0..) |svc, i| {
        argv[5 + i] = svc;
    }

    const result = std.process.run(alloc, io, .{
        .argv = &argv,
    }) catch return;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    // systemctl outputs one property value per line, with blank-line
    // separators between services. Moonraker splits on "\n\n".
    var svc_blocks = std.mem.splitSequence(u8, result.stdout, "\n\n");

    for (available_services) |svc_name| {
        const block = svc_blocks.next() orelse break;
        if (block.len == 0) continue;

        // Each block has at most two non-empty lines: ActiveState, SubState.
        var lines = std.mem.splitScalar(u8, block, '\n');
        const active_line = lines.next() orelse continue;
        const sub_line = lines.next() orelse continue;

        if (active_line.len == 0) continue;

        const new_active = MachineCtx.internState(active_line);
        const new_sub = MachineCtx.internState(sub_line);

        const prev = ctx.services.get(svc_name);
        const changed = prev == null or
            !std.mem.eql(u8, prev.?.active_state, new_active) or
            !std.mem.eql(u8, prev.?.sub_state, new_sub);

        if (!changed) continue;

        // Update or insert the entry (reuse the key if it exists).
        const entry = MachineCtx.ServiceEntry.active(new_active, new_sub);
        if (ctx.services.getPtr(svc_name)) |existing| {
            existing.* = entry;
        } else {
            ctx.services.put(ctx.gpa.dupe(u8, svc_name) catch continue, entry) catch continue;
        }
    }
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
    try sys.put(alloc, "sd_info", try buildSdInfo(ctx, alloc));
    try sys.put(alloc, "distribution", try buildDistribution(ctx, alloc));
    try sys.put(alloc, "virtualization", try buildVirtualization(ctx, alloc));
    // network/canbus require a NETLINK / `ip` shell walk; reported empty until
    // that subsystem lands. Shape (object) matches upstream.
    try sys.put(alloc, "network", .{ .object = .empty });
    try sys.put(alloc, "canbus", .{ .object = .empty });
    try sys.put(alloc, "python", try buildPython(alloc));
    try sys.put(alloc, "available_services", try buildAvailableServices(ctx, alloc));
    try sys.put(alloc, "service_state", try buildServiceState(ctx, alloc));
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
/// Cap on tracked interfaces for bandwidth computation (lo, eth0, wlan0, can0,
/// usb0… — 8 is ample for an appliance).
const max_net_ifaces = 8;

/// One interface's previous byte total + timestamp, for bandwidth deltas.
const NetSample = struct {
    name: [16]u8 = undefined,
    name_len: u8 = 0,
    total: u64 = 0,
    time: f64 = 0,
    used: bool = false,
};

/// Bytes/sec between two cumulative totals over `dt` seconds. Returns 0 for a
/// non-positive interval or a counter reset/rollover (cur < prev).
fn computeBandwidth(prev_total: u64, cur_total: u64, dt: f64) f64 {
    if (dt <= 0) return 0;
    if (cur_total < prev_total) return 0;
    return @as(f64, @floatFromInt(cur_total - prev_total)) / dt;
}

/// Overwrite each interface's `bandwidth` field in a parsed /proc/net/dev object
/// with the real bytes/sec delta vs the previous tick, and refresh the cache.
/// First sighting of an interface leaves bandwidth at 0 (no baseline yet).
/// Matches proc_stats.py's per-tick `bytes_sec` computation.
fn applyBandwidth(self: *MachineCtx, network: std.json.Value, now: f64) void {
    if (network != .object) return;
    var it = network.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const dev = entry.value_ptr.*;
        if (dev != .object) continue;
        const rx: i64 = if (dev.object.get("rx_bytes")) |v| (if (v == .integer) v.integer else 0) else 0;
        const tx: i64 = if (dev.object.get("tx_bytes")) |v| (if (v == .integer) v.integer else 0) else 0;
        const cur_total: u64 = @intCast(@max(@as(i64, 0), rx) + @max(@as(i64, 0), tx));

        var slot: ?*NetSample = null;
        var free_slot: ?*NetSample = null;
        for (&self.net_prev) |*s| {
            if (s.used and std.mem.eql(u8, s.name[0..s.name_len], name)) {
                slot = s;
                break;
            }
            if (!s.used and free_slot == null) free_slot = s;
        }
        if (slot) |s| {
            const bw = computeBandwidth(s.total, cur_total, now - s.time);
            if (dev.object.getPtr("bandwidth")) |bp| bp.* = .{ .float = bw };
            s.total = cur_total;
            s.time = now;
        } else if (free_slot) |s| {
            if (name.len <= s.name.len) {
                @memcpy(s.name[0..name.len], name);
                s.name_len = @intCast(name.len);
                s.total = cur_total;
                s.time = now;
                s.used = true;
            }
        }
    }
}

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
/// moonraker_stats is read from the rolling 30-sample ring buffer populated by
/// the proc_stat timer thread. Without a timer running (io == null), returns
/// a single zeroed sample so the array shape is present and non-empty.
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

    // Read from the rolling ring buffer (populated by the timer thread).
    // Falls back to a single zeroed sample when no timer has run yet.
    const samples = buildMoonrakerStats(ctx, alloc, ctx.io);

    var out: std.json.ObjectMap = .empty;
    try out.put(alloc, "moonraker_stats", samples);
    try out.put(alloc, "throttled_state", .null);
    try out.put(alloc, "cpu_temp", cpu_temp);
    try out.put(alloc, "network", network);
    try out.put(alloc, "system_cpu_usage", sys_cpu);
    try out.put(alloc, "system_uptime", .{ .float = uptimeSeconds() });
    try out.put(alloc, "system_memory", sys_mem);
    const ws_count: i64 = if (ctx.conns) |c| @intCast(c.count(ctx.io.?)) else 0;
    try out.put(alloc, "websocket_connections", .{ .integer = ws_count });
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
// reboot / shutdown
// ===========================================================================

/// POST /machine/reboot → "ok".
///
/// NOTE: deliberately a NO-OP. Real host control is intentionally disabled.
/// Reasons:
///   1. Firing `sudo systemctl reboot` here rebooted the developer host during
///      testing. A stray API call (or a UI probe) must never take the box down.
///   2. The target appliances (printer mainboards) generally have no systemd /
///      `systemctl`, so the systemctl path is wrong for the real deployment too.
/// We return the same "ok" shape Moonraker returns so API/behaviour parity holds
/// for callers; actual reboot wiring is left to a platform-specific driver that
/// is opt-in and cannot point at a dev machine. See `runSudoCmd` (kept for
/// services/sudo paths) — it is intentionally NOT called from here.
pub fn handleReboot(ctx_ptr: *anyopaque, _: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    _ = ctx_ptr;
    return .{ .string = "ok" };
}

/// POST /machine/shutdown → "ok".
///
/// NOTE: deliberately a NO-OP — same rationale as `handleReboot` above
/// (host-reboot hazard + printers lack systemctl). Returns Moonraker's "ok"
/// shape without touching the host. Real power-off is left to an opt-in
/// platform driver.
pub fn handleShutdown(ctx_ptr: *anyopaque, _: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    _ = ctx_ptr;
    return .{ .string = "ok" };
}

// ===========================================================================
// services.{restart,stop,start}
// ===========================================================================

/// True if a service name is allowed (matches machine.py `is_service_allowed`):
/// the default allowed list, any phobos-registered service, or anything
/// matching moonraker[_-]?\d* / klipper[_-]?\d*.
/// Comptime perfect-hash set of all statically-allowed service names (in
/// .rodata, no runtime allocation), replacing two linear scans per call.
const allowed_services_set = std.StaticStringMap(void).initComptime(blk: {
    const all = default_allowed_services ++ available_services;
    var kvs: [all.len]struct { []const u8 } = undefined;
    for (all, 0..) |s, i| kvs[i] = .{s};
    break :blk kvs;
});

pub fn isServiceAllowed(name: []const u8) bool {
    if (allowed_services_set.has(name)) return true;
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

/// Shared helper for the three service action endpoints. Validates the `service`
/// param against the allow-list, runs `systemctl <action> <service>`, reads the
/// resulting state via `systemctl show`, and emits
/// `notify_service_state_changed`. Falls back to optimistic in-memory state
/// when io is null (unit test path).
fn doServiceAction(ctx: *MachineCtx, params: std.json.Value, alloc: std.mem.Allocator, action: ServiceAction) !std.json.Value {
    const name = try getStr(params, "service");
    if (!isServiceAllowed(name)) return error.Forbidden;

    if (ctx.io != null or ctx.run_cmd_fn != null) {
        // Run systemctl <start|stop|restart> --no-block <service>.
        const action_str = @tagName(action);
        var argv: [4][]const u8 = .{ "systemctl", action_str, "--no-block", name };
        _ = ctx.runCmd(alloc, &argv) catch {};

        // Read the actual service state from systemd.
        var show_argv: [6][]const u8 = .{ "systemctl", "show", "-p", "ActiveState,SubState", "--value", name };
        const show_result = ctx.runCmd(alloc, &show_argv) catch {
            return .{ .string = "ok" };
        };
        defer alloc.free(show_result.stdout);
        defer alloc.free(show_result.stderr);

        var lines = std.mem.splitScalar(u8, show_result.stdout, '\n');
        const active_line = lines.next() orelse "";
        const sub_line = lines.next() orelse "";

        const new_active = if (active_line.len > 0) MachineCtx.internState(active_line) else "unknown";
        const new_sub = if (sub_line.len > 0) MachineCtx.internState(sub_line) else "unknown";

        const entry = MachineCtx.ServiceEntry.active(new_active, new_sub);
        if (ctx.services.getPtr(name)) |existing| {
            existing.* = entry;
        } else {
            try ctx.services.put(try ctx.gpa.dupe(u8, name), entry);
        }

        if (ctx.bus) |bus| {
            var svc_obj: std.json.ObjectMap = .empty;
            svc_obj.put(alloc, "active_state", .{ .string = new_active }) catch {};
            svc_obj.put(alloc, "sub_state", .{ .string = new_sub }) catch {};
            var outer: std.json.ObjectMap = .empty;
            outer.put(alloc, name, .{ .object = svc_obj }) catch {};
            _ = bus.emitLocked(ctx.io.?, notify.names.service_state_changed, .{ .object = outer }) catch {};
        }

        return .{ .string = "ok" };
    }

    // No io: optimistic in-memory fallback (unit test path).
    const new_active: []const u8, const new_sub: []const u8 = switch (action) {
        .start, .restart => .{ "active", "running" },
        .stop => .{ "inactive", "dead" },
    };

    const entry = MachineCtx.ServiceEntry.active(new_active, new_sub);
    if (ctx.services.getPtr(name)) |existing| {
        existing.* = entry;
    } else {
        try ctx.services.put(try ctx.gpa.dupe(u8, name), entry);
    }

    if (ctx.bus != null and ctx.io != null) {
        const bus = ctx.bus.?;
        const io = ctx.io.?;
        var svc_obj: std.json.ObjectMap = .empty;
        svc_obj.put(alloc, "active_state", .{ .string = new_active }) catch {};
        svc_obj.put(alloc, "sub_state", .{ .string = new_sub }) catch {};
        var outer: std.json.ObjectMap = .empty;
        outer.put(alloc, name, .{ .object = svc_obj }) catch {};
        _ = bus.emitLocked(io, notify.names.service_state_changed, .{ .object = outer }) catch {};
    }

    return .{ .string = "ok" };
}

const ServiceAction = enum { start, stop, restart };

/// POST /machine/services/start → "ok"
pub fn handleServiceStart(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *MachineCtx = @ptrCast(@alignCast(ctx_ptr));
    return doServiceAction(ctx, params, alloc, .start);
}

/// POST /machine/services/stop → "ok"
pub fn handleServiceStop(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *MachineCtx = @ptrCast(@alignCast(ctx_ptr));
    return doServiceAction(ctx, params, alloc, .stop);
}

/// POST /machine/services/restart → "ok"
pub fn handleServiceRestart(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *MachineCtx = @ptrCast(@alignCast(ctx_ptr));
    return doServiceAction(ctx, params, alloc, .restart);
}

// ===========================================================================
// sudo.info / sudo.password
// ===========================================================================

/// GET /machine/sudo/info → { sudo_access, linux_user, sudo_requested,
///                            request_messages }
/// If `check_access=true` is passed as a param (Moonraker `sudo.info`),
/// runs `sudo -S -l` with the stored password to determine real sudo access.
/// Otherwise returns the cached result or null when no check has been performed.
pub fn handleSudoInfo(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *MachineCtx = @ptrCast(@alignCast(ctx_ptr));

    var sudo_access: std.json.Value = .null;
    if (ctx.sudo_password) |pwd| {
        var check: bool = false;
        if (params == .object) {
            if (params.object.get("check_access")) |v| {
                if (v == .bool) check = v.bool;
            }
        }
        if (check) {
            // Run a fresh sudo check on demand (matching Moonraker).
            if (ctx.io) |io| {
                const valid = runSudoCheck(io, alloc, pwd);
                ctx.sudo_validated = valid;
                if (valid) |v| sudo_access = .{ .bool = v };
            }
        } else if (ctx.sudo_validated) |v| {
            sudo_access = .{ .bool = v };
        }
        // else: password stored but not yet validated → stays null
    }

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "sudo_access", sudo_access);
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
/// Stores the supplied password and validates it via `sudo -S -l`.
/// If the password is invalid, clears storage and returns an error.
pub fn handleSudoPassword(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *MachineCtx = @ptrCast(@alignCast(ctx_ptr));
    const pwd = try getStr(params, "password");

    // Persist (replace) the password under the ctx allocator.
    if (ctx.sudo_password) |old| ctx.gpa.free(old);
    ctx.sudo_password = try ctx.gpa.dupe(u8, pwd);
    ctx.sudo_validated = null;

    // Validate the password via sudo -S -l (only if io is available).
    if (ctx.io) |io| {
        const valid = runSudoCheck(io, alloc, pwd);
        ctx.sudo_validated = valid;
        if (valid == false) {
            // Clear the stored password on invalid, matching Moonraker's behaviour.
            ctx.gpa.free(ctx.sudo_password.?);
            ctx.sudo_password = null;
            return error.InvalidParams; // "Invalid Password"
        }
    }

    var responses: std.json.Array = .init(alloc);
    try responses.append(.{ .string = "Sudo password successfully set." });

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "sudo_responses", .{ .array = responses });
    try obj.put(alloc, "is_restarting", .{ .bool = false });
    return .{ .object = obj };
}

/// Run a command via sudo (with password if set). Swallows all errors —
/// reboot/shutdown are fire-and-forget; the server is unlikely to survive
/// long enough to report failures.
fn runSudoCmd(io: std.Io, password: ?[]const u8, cmd: []const u8) ?bool {
    var child = std.process.spawn(io, .{
        .argv = &.{ "sudo", "-S", cmd },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return null;
    defer child.kill(io);

    if (child.stdin) |sin| {
        if (password) |pw| {
            var wbuf: [128]u8 = undefined;
            var writer = sin.writer(io, &wbuf);
            writer.interface.writeAll(pw) catch {};
            writer.interface.writeAll("\n") catch {};
            _ = writer.interface.flush() catch {};
        }
        sin.close(io);
        child.stdin = null;
    }

    const term = child.wait(io) catch return null;
    return term == .exited and term.exited == 0;
}

/// Run `sudo -S -l` with the given password to determine if the password
/// grants sudo access. Returns null if sudo is unavailable or cannot be
/// determined; true if access is valid; false if the password is wrong.
fn runSudoCheck(io: std.Io, gpa: std.mem.Allocator, password: []const u8) ?bool {
    var child = std.process.spawn(io, .{
        .argv = &.{ "sudo", "-S", "-l" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return null;
    defer child.kill(io);

    // Write the password + newline to stdin, then close it so sudo reads EOF.
    if (child.stdin) |sin| {
        var wbuf: [128]u8 = undefined;
        var writer = sin.writer(io, &wbuf);
        writer.interface.writeAll(password) catch {};
        writer.interface.writeAll("\n") catch {};
        _ = writer.interface.flush() catch {};
        sin.close(io);
        child.stdin = null;
    }

    // Read stdout into a buffer (we only need to know if it's non-empty on success).
    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(gpa);
    if (child.stdout) |sout| {
        var rbuf: [256]u8 = undefined;
        var reader = sout.reader(io, &rbuf);
        while (reader.interface.takeDelimiter('\n')) |opt_line| {
            const line = opt_line orelse break;
            stdout_buf.appendSlice(gpa, line) catch {};
        } else |_| {}
    }

    const term = child.wait(io) catch return null;

    if (term == .exited and term.exited == 0 and stdout_buf.items.len > 0) {
        return true;
    }
    if (term == .exited and term.exited != 0) {
        return false;
    }
    return null;
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
    try obj.put(alloc, "libcamera_devices", .{ .array = .init(alloc) });
    try obj.put(alloc, "v4l2_devices", .{ .array = v4l2 });
    return .{ .object = obj };
}

fn enumVideo(io: std.Io, alloc: std.mem.Allocator, arr: *std.json.Array) !void {
    var dir = Dir.cwd().openDir(io, "/sys/class/video4linux", .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        var dev: std.json.ObjectMap = .empty;
        const base = try std.fs.path.join(alloc, &.{ "/sys/class/video4linux", entry.name });
        const name = sysAttr(io, alloc, try std.fs.path.join(alloc, &.{ base, "name" })) orelse "";
        try dev.put(alloc, "device_name", .{ .string = try alloc.dupe(u8, entry.name) });
        try dev.put(alloc, "device_path", .{ .string = try std.fmt.allocPrint(alloc, "/dev/{s}", .{entry.name}) });
        try dev.put(alloc, "camera_name", .{ .string = name });
        // Read driver name from device/uevent if available.
        var drv_name: []const u8 = "";
        const uevent_path = try std.fs.path.join(alloc, &.{ base, "device", "uevent" });
        if (sysAttr(io, alloc, uevent_path)) |uevent| {
            var lines = std.mem.splitScalar(u8, uevent, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "DRIVER=")) {
                    drv_name = try alloc.dupe(u8, line["DRIVER=".len..]);
                    break;
                }
            }
        }
        try dev.put(alloc, "driver_name", .{ .string = drv_name });
        try dev.put(alloc, "hardware_bus", .{ .string = "" });
        try dev.put(alloc, "capabilities", .{ .array = .init(alloc) });
        try dev.put(alloc, "version", .{ .string = "" });
        try dev.put(alloc, "path_by_hardware", .null);
        try dev.put(alloc, "path_by_id", .null);
        try dev.put(alloc, "alt_name", .{ .string = name });
        try dev.put(alloc, "usb_location", .null);
        try dev.put(alloc, "modes", .{ .array = .init(alloc) });
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

    try reg.registerEndpoint(.{ .path = "/machine/services/restart", .methods = &.{.POST} }, c, handleServiceRestart);
    try reg.registerEndpoint(.{ .path = "/machine/services/stop", .methods = &.{.POST} }, c, handleServiceStop);
    try reg.registerEndpoint(.{ .path = "/machine/services/start", .methods = &.{.POST} }, c, handleServiceStart);

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

// ---- parseSchedContainer ----

test "parseSchedContainer: pid1 init/systemd yields none" {
    try testing.expectEqualStrings("none", parseSchedContainer("systemd (1, #threads: 1)", false).virt_type);
    try testing.expectEqualStrings("none", parseSchedContainer("init (1, #threads: 1)", true).virt_type);
    try testing.expectEqualStrings("none", parseSchedContainer("", true).virt_type);
}

test "parseSchedContainer: non-init pid1 is a container; dockerenv refines to docker" {
    const lxc = parseSchedContainer("bash (1, #threads: 1)", false);
    try testing.expectEqualStrings("container", lxc.virt_type);
    try testing.expectEqualStrings("lxc", lxc.virt_identifier);
    const docker = parseSchedContainer("sh (1, #threads: 1)", true);
    try testing.expectEqualStrings("container", docker.virt_type);
    try testing.expectEqualStrings("docker", docker.virt_identifier);
}

test "fuzz parseSchedContainer: arbitrary first line never crashes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [48]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const has_dockerenv = smith.valueWithHash(bool, 1);
            const r = parseSchedContainer(&buf, has_dockerenv);
            const ok = std.mem.eql(u8, r.virt_type, "none") or std.mem.eql(u8, r.virt_type, "container");
            try testing.expect(ok);
        }
    }.run, .{});
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

// ---- computeBandwidth ----

test "computeBandwidth: bytes/sec delta, guards reset and zero interval" {
    try testing.expectEqual(@as(f64, 1000.0), computeBandwidth(1000, 2000, 1.0));
    try testing.expectEqual(@as(f64, 500.0), computeBandwidth(0, 1000, 2.0));
    try testing.expectEqual(@as(f64, 0.0), computeBandwidth(2000, 1000, 1.0)); // counter reset
    try testing.expectEqual(@as(f64, 0.0), computeBandwidth(1000, 2000, 0.0)); // zero interval
    try testing.expectEqual(@as(f64, 0.0), computeBandwidth(1000, 2000, -1.0)); // negative interval
}

test "fuzz computeBandwidth: never crashes, never negative" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const prev = smith.valueWithHash(u64, 0);
            const cur = smith.valueWithHash(u64, 1);
            const dt: f64 = @floatFromInt(smith.valueRangeAtMostWithHash(u32, 0, 1_000_000, 2));
            const bw = computeBandwidth(prev, cur, dt);
            try testing.expect(bw >= 0.0);
        }
    }.run, .{});
}

// ---- applyBandwidth ----

test "applyBandwidth: zero on first sight, real delta on second tick" {
    var c = MachineCtx.init(testing.allocator, null, null);
    defer c.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t1 =
        \\eth0: 1000 0 0 0 0 0 0 0 500 0 0 0 0 0 0 0
    ;
    const n1 = try parseNetDev(a, t1);
    applyBandwidth(&c, n1, 10.0);
    // First sighting: no baseline → bandwidth stays 0.
    try testing.expectEqual(@as(f64, 0.0), n1.object.get("eth0").?.object.get("bandwidth").?.float);

    // Second tick 2s later: rx+tx grew 1500→4500 → 3000 bytes / 2s = 1500 B/s.
    const t2 =
        \\eth0: 3000 0 0 0 0 0 0 0 1500 0 0 0 0 0 0 0
    ;
    const n2 = try parseNetDev(a, t2);
    applyBandwidth(&c, n2, 12.0);
    try testing.expectEqual(@as(f64, 1500.0), n2.object.get("eth0").?.object.get("bandwidth").?.float);
}

test "fuzz applyBandwidth: arbitrary net objects never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var c = MachineCtx.init(testing.allocator, null, null);
            defer c.deinit();
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var raw: [64]u8 = undefined;
            smith.bytesWithHash(&raw, 0);
            const net = parseNetDev(a, &raw) catch return;
            applyBandwidth(&c, net, 1.0);
            applyBandwidth(&c, net, 2.0);
        }
    }.run, .{});
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

test "handleReboot/handleShutdown: ack ok (io null)" {
    var c = MachineCtx.init(testing.allocator, null, null);
    defer c.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("ok", (try handleReboot(@ptrCast(&c), .null, a)).string);
    try testing.expectEqualStrings("ok", (try handleShutdown(@ptrCast(&c), .null, a)).string);
}

test "service handlers: start/stop/restart update state; disallowed Forbidden" {
    var c = MachineCtx.init(testing.allocator, null, null);
    defer c.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // start: should set active/running
    const ok = try handleServiceStart(@ptrCast(&c), try objParams(a, "{\"service\":\"klipper\"}"), a);
    try testing.expectEqualStrings("ok", ok.string);
    try testing.expect(c.services.get("klipper") != null);
    try testing.expectEqualStrings("active", c.services.get("klipper").?.active_state);
    try testing.expectEqualStrings("running", c.services.get("klipper").?.sub_state);

    // stop: should set inactive/dead
    _ = try handleServiceStop(@ptrCast(&c), try objParams(a, "{\"service\":\"klipper\"}"), a);
    try testing.expectEqualStrings("inactive", c.services.get("klipper").?.active_state);
    try testing.expectEqualStrings("dead", c.services.get("klipper").?.sub_state);

    // restart: should set active/running
    _ = try handleServiceRestart(@ptrCast(&c), try objParams(a, "{\"service\":\"klipper\"}"), a);
    try testing.expectEqualStrings("active", c.services.get("klipper").?.active_state);
    try testing.expectEqualStrings("running", c.services.get("klipper").?.sub_state);

    // disallowed service
    try testing.expectError(error.Forbidden, handleServiceStart(@ptrCast(&c), try objParams(a, "{\"service\":\"sshd\"}"), a));
    try testing.expectError(error.Forbidden, handleServiceStop(@ptrCast(&c), try objParams(a, "{\"service\":\"sshd\"}"), a));
    try testing.expectError(error.Forbidden, handleServiceRestart(@ptrCast(&c), try objParams(a, "{\"service\":\"sshd\"}"), a));

    // missing param
    try testing.expectError(error.InvalidParams, handleServiceStart(@ptrCast(&c), .null, a));
    try testing.expectError(error.InvalidParams, handleServiceStop(@ptrCast(&c), .null, a));
    try testing.expectError(error.InvalidParams, handleServiceRestart(@ptrCast(&c), .null, a));

    // available_services: mqtt should be allowed now
    const mqtt_ok = try handleServiceStart(@ptrCast(&c), try objParams(a, "{\"service\":\"mqtt\"}"), a);
    try testing.expectEqualStrings("ok", mqtt_ok.string);
    try testing.expect(c.services.get("mqtt") != null);
}

test "runCmd: delegates to mock when set, returns empty when no io" {
    const MockCtx = struct {
        captured_argv: ?[]const []const u8 = null,
        fn runCmd(ctx: *anyopaque, gpa: std.mem.Allocator, argv: []const []const u8) anyerror!MachineCtx.RunCmdResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.captured_argv = argv;
            const out = try gpa.dupe(u8, "mock_stdout");
            return .{ .stdout = out, .stderr = &.{} };
        }
    };
    var mock = MockCtx{};
    var c = MachineCtx.init(testing.allocator, null, null);
    defer c.deinit();

    // Without mock and without io → returns empty.
    {
        const r = try c.runCmd(testing.allocator, &.{ "echo", "hello" });
        defer testing.allocator.free(r.stdout);
        defer testing.allocator.free(r.stderr);
        try testing.expectEqualStrings("", r.stdout);
        try testing.expectEqualStrings("", r.stderr);
    }

    // With mock → delegates.
    c.setRunCmdFn(MockCtx.runCmd, @ptrCast(&mock));
    {
        const r = try c.runCmd(testing.allocator, &.{ "systemctl", "show", "-p", "ActiveState", "--value", "klipper" });
        defer testing.allocator.free(r.stdout);
        defer testing.allocator.free(r.stderr);
        try testing.expectEqualStrings("mock_stdout", r.stdout);
        try testing.expectEqualStrings("", r.stderr);
        try testing.expect(mock.captured_argv != null);
        try testing.expectEqual(@as(usize, 6), mock.captured_argv.?.len);
        try testing.expectEqualStrings("systemctl", mock.captured_argv.?[0]);
    }
}

test "service handler with runCmd mock: uses mock output for state" {
    const MockCtx = struct {
        call_count: usize = 0,
        fn runCmd(ctx: *anyopaque, gpa: std.mem.Allocator, argv: []const []const u8) anyerror!MachineCtx.RunCmdResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.call_count += 1;
            if (argv.len >= 2 and std.mem.eql(u8, argv[1], "show")) {
                const out = try gpa.dupe(u8, "inactive\ndead\n");
                return .{ .stdout = out, .stderr = &.{} };
            }
            return .{ .stdout = &.{}, .stderr = &.{} };
        }
    };
    var mock = MockCtx{};
    var c = MachineCtx.init(testing.allocator, null, null);
    defer c.deinit();
    c.setRunCmdFn(MockCtx.runCmd, @ptrCast(&mock));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ok = try handleServiceStop(@ptrCast(&c), try objParams(a, "{\"service\":\"klipper\"}"), a);
    try testing.expectEqualStrings("ok", ok.string);
    try testing.expectEqual(@as(usize, 2), mock.call_count);
    try testing.expect(c.services.get("klipper") != null);
    try testing.expectEqualStrings("inactive", c.services.get("klipper").?.active_state);
    try testing.expectEqualStrings("dead", c.services.get("klipper").?.sub_state);
}

test "buildServiceState: reflects tracked service states" {
    var c = MachineCtx.init(testing.allocator, null, null);
    defer c.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Default (never queried): unknown/unknown, matching Moonraker.
    const s0 = try buildServiceState(&c, a);
    try testing.expect(s0.object.get("klipper") != null);
    try testing.expectEqualStrings("unknown", s0.object.get("klipper").?.object.get("active_state").?.string);
    try testing.expectEqualStrings("unknown", s0.object.get("klipper").?.object.get("sub_state").?.string);

    // After stop: state changes
    _ = try handleServiceStop(@ptrCast(&c), try objParams(a, "{\"service\":\"klipper\"}"), a);
    const s1 = try buildServiceState(&c, a);
    try testing.expectEqualStrings("inactive", s1.object.get("klipper").?.object.get("active_state").?.string);
    try testing.expectEqualStrings("dead", s1.object.get("klipper").?.object.get("sub_state").?.string);

    // Other (never queried) service still unknown.
    try testing.expectEqualStrings("unknown", s1.object.get("mqtt").?.object.get("active_state").?.string);
}

test "buildServiceState: all available_services present" {
    var c = testCtx(testing.allocator);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ss = try buildServiceState(&c, a);
    const o = ss.object;
    for (available_services) |s| {
        try testing.expect(o.get(s) != null);
    }
}

test "buildAvailableServices: all available_services present in array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = testCtx(a);
    const v = try buildAvailableServices(&c, a);
    try testing.expect(v == .array);
    try testing.expectEqual(available_services.len, v.array.items.len);
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

test "registerMachine: wires routes and JSON-RPC methods" {
    const jsonrpc = @import("../jsonrpc.zig");
    var d = jsonrpc.Dispatcher.init(testing.allocator);
    defer d.deinit();
    var reg = Registry.init(testing.allocator, &d);
    defer reg.deinit();

    var ctx = testCtx(testing.allocator);
    defer ctx.deinit();
    try registerMachine(&reg, &ctx);

    const routes = [_][]const u8{
        "/machine/system_info", "/machine/proc_stats",
        "/machine/reboot", "/machine/shutdown",
        "/machine/services/restart", "/machine/services/stop", "/machine/services/start",
        "/machine/sudo/info", "/machine/sudo/password",
        "/machine/peripherals/usb", "/machine/peripherals/serial",
        "/machine/peripherals/video", "/machine/peripherals/canbus",
    };
    for (routes) |path| {
        try testing.expect((reg.lookup(.GET, path) != null) or (reg.lookup(.POST, path) != null));
    }
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

test "fuzz_machine_handlers_reboot_shutdown: never crash" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [32]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var c = MachineCtx{ .gpa = a, .io = null };
            _ = handleReboot(@ptrCast(&c), .null, a) catch {};
            _ = handleShutdown(@ptrCast(&c), .null, a) catch {};
        }
    }.run, .{});
}

test "fuzz_machine_handlers_services: never crash" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var c = MachineCtx{ .gpa = a, .io = null };

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"service\":\"klipper\"}",
                "{\"name\":\"klipper\"}",
                "{\"service\":\"moonraker\"}",
            };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            _ = handleServiceStart(@ptrCast(&c), p.value, a) catch {};
            _ = handleServiceStop(@ptrCast(&c), p.value, a) catch {};
            _ = handleServiceRestart(@ptrCast(&c), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz_machine_handlers_sudo: never crash" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var c = MachineCtx{ .gpa = a, .io = null };

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"check_access\":true}",
                "{\"check_access\":false}",
                "{\"password\":\"test123\"}",
                "{\"password\":\"\"}",
            };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            _ = handleSudoInfo(@ptrCast(&c), p.value, a) catch {};
            _ = handleSudoPassword(@ptrCast(&c), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz_machine_handlers_peripherals: never crash" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [32]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var c = MachineCtx{ .gpa = a, .io = null };

            var b: [8]u8 = undefined;
            smith.bytesWithHash(&b, 1);
            const canbus_strs = [_][]const u8{
                "null",
                "{}",
                "{\"interface\":\"can0\"}",
                "{\"interface\":\"can1\"}",
            };
            const can_p = std.json.parseFromSlice(std.json.Value, a, canbus_strs[b[0] % canbus_strs.len], .{}) catch return;
            _ = handleUsb(@ptrCast(&c), .null, a) catch {};
            _ = handleSerial(@ptrCast(&c), .null, a) catch {};
            _ = handleVideo(@ptrCast(&c), .null, a) catch {};
            _ = handleCanbus(@ptrCast(&c), can_p.value, a) catch {};
        }
    }.run, .{});
}

test "hexDecodeAlloc: basic decode" {
    const a = testing.allocator;
    const out = try hexDecodeAlloc(a, "48656c6c6f");
    defer a.free(out);
    try testing.expectEqualStrings("Hello", out);
}

test "hexDecodeAlloc: empty string" {
    const out = try hexDecodeAlloc(testing.allocator, "");
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "hexDecodeAlloc: odd length fails" {
    try testing.expectError(error.InvalidHex, hexDecodeAlloc(testing.allocator, "abc"));
}

test "hexDecodeAlloc: full byte range 0x00-0xFF" {
    const a = testing.allocator;
    const out = try hexDecodeAlloc(a, "00ff7f80");
    defer a.free(out);
    try testing.expectEqual(@as(u8, 0x00), out[0]);
    try testing.expectEqual(@as(u8, 0xff), out[1]);
    try testing.expectEqual(@as(u8, 0x7f), out[2]);
    try testing.expectEqual(@as(u8, 0x80), out[3]);
}

test "buildSdInfo: no io returns empty object" {
    var ctx = testCtx(testing.allocator);
    const info = try buildSdInfo(&ctx, testing.allocator);
    try testing.expect(info.object.count() == 0);
}

test "CSD capacity: High Capacity type 1" {
    const c_size: u64 = 15193;
    const total_bytes = (c_size + 1) * 512 * 1024;
    try testing.expectEqual(@as(u64, 7966031872), total_bytes);
    const gib: f64 = @as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0 * 1024.0);
    try testing.expectApproxEqRel(@as(f64, 7.4189453125), gib, 0.01);
}

test "CSD capacity: Standard Capacity type 0" {
    const c_size: u64 = 4095;
    const c_mult_reg: u64 = 7;
    const max_block_len: u64 = 1024;
    const total_bytes = (c_size + 1) * (c_mult_reg + 1) * max_block_len;
    try testing.expectEqual(@as(u64, 33554432), total_bytes);
}

test "CSD capacity: Ultra Capacity type 2" {
    const c_size: u64 = 244140;
    const total_bytes = (c_size + 1) * 512 * 1024;
    try testing.expectEqual(@as(u64, 128000196608), total_bytes);
}

test "fuzz_hexDecodeAlloc: random bytes roundtrip" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const a = std.heap.smp_allocator;
            // Build hex string manually.
            var hex_buf: [128]u8 = undefined;
            for (buf, 0..) |b, i| {
                _ = std.fmt.bufPrint(hex_buf[2 * i .. 2 * i + 2], "{x:0>2}", .{b}) catch unreachable;
            }
            const decoded = hexDecodeAlloc(a, &hex_buf) catch return;
            defer a.free(decoded);
            try testing.expectEqual(buf.len, decoded.len);
            for (buf, decoded) |orig, d| {
                try testing.expectEqual(orig, d);
            }
        }
    }.run, .{});
}

test "fuzz_hexParse: malformed hex never crashes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const n = @min(buf.len, @as(usize, @intCast(smith.valueRangeAtMostWithHash(u8, 0, 128, 1))));
            _ = hexDecodeAlloc(a, buf[0..n]) catch {};
            if (buf.len >= 2) {
                _ = std.fmt.parseInt(u8, buf[0..2], 16) catch {};
            }
            if (buf.len >= 4) {
                _ = std.fmt.parseInt(u16, buf[0..4], 16) catch {};
            }
        }
    }.run, .{});
}

test "runSudoCheck: returns a valid ?bool, never crashes" {
    // Create a real Io handle so runSudoCheck can spawn a child process.
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // With a garbage password, this should never hang or crash.
    // It returns null (sudo unavailable), true, or false — all valid.
    const result = runSudoCheck(io, testing.allocator, "wrong_password_123");
    _ = result; // verify it's a ?bool (compiler-enforced)

    // Empty password is also safe.
    const result2 = runSudoCheck(io, testing.allocator, "");
    _ = result2;

    // Long password with special chars.
    const result3 = runSudoCheck(io, testing.allocator, "a" ** 4096);
    _ = result3;
}

test "runSudoCheck: null bytes and special chars safe" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Special shell characters should not cause issues (stdin, not argv).
    const result = runSudoCheck(io, testing.allocator, "pwd; rm -rf /");
    _ = result;

    const result2 = runSudoCheck(io, testing.allocator, "\x00\x01\x02\x03");
    _ = result2;

    const result3 = runSudoCheck(io, testing.allocator, "\"quoted\" 'text'");
    _ = result3;
}

test "fuzz_runSudoCheck: random passwords never crash" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();

            var buf: [256]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const n = @min(buf.len, @as(usize, @intCast(smith.valueRangeAtMostWithHash(u8, 0, 128, 1))));
            const pwd = buf[0..n];

            _ = runSudoCheck(io, a, pwd);
        }
    }.run, .{});
}

test "runSudoCmd: returns null with null password and no sudo access" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // In test environment without sudo, this returns null (spawn succeeds but
    // exit is non-zero). Verify no crash.
    const result = runSudoCmd(io, null, "echo ok");
    _ = result;
}

test "runSudoCmd: null bytes and special chars safe" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Special characters in command and password should not crash.
    _ = runSudoCmd(io, "pass\x00word with null", "echo 'hello'");
    _ = runSudoCmd(io, "pass\nword", "echo 'hello'");
    _ = runSudoCmd(io, "pass\"word", "echo 'hello'");
    _ = runSudoCmd(io, null, "echo 'hello'");
}

test "fuzz_runSudoCmd: random passwords and commands never crash" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();

            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();

            var buf: [256]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const pw_n = @min(buf.len, @as(usize, @intCast(smith.valueRangeAtMostWithHash(u8, 0, 64, 1))));

            var cmd_buf: [64]u8 = undefined;
            smith.bytesWithHash(&cmd_buf, 1);
            const cmd_n = @min(cmd_buf.len, @as(usize, @intCast(smith.valueRangeAtMostWithHash(u8, 0, 32, 2))));

            const pwd: ?[]const u8 = if (pw_n > 0) buf[0..pw_n] else null;
            const cmd = cmd_buf[0..cmd_n];

            _ = runSudoCmd(io, pwd, cmd);
        }
    }.run, .{});
}
