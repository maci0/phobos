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
//! but never touch the host. AGENT: do not implement them, not behind a flag
//! and not as a provider. `systemctl reboot` rebooted the dev host. See
//! handleReboot/handleShutdown.
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
const jv = @import("../json/value.zig");
const clock = @import("../util/clock.zig");
const sleep = @import("../util/sleep.zig");

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

/// System provider kind — which init/service manager drives machine.services.*
/// (Moonraker's `provider` config). phobos collapses systemd_cli/systemd_dbus to
/// one `systemd` path (both shell out to `systemctl`); `supervisord*` uses
/// `supervisorctl`; Forge-X `simple` runs `<script_path>/<service> <action>`.
/// `none` keeps service state in-memory only. reboot/shutdown stay deliberate
/// no-ops for every provider, including `simple` (host safety).
pub const Provider = enum { systemd, supervisord, simple, none };

/// Map a Moonraker `provider` config string to phobos's provider kind.
pub fn providerKind(name: []const u8) Provider {
    if (std.mem.startsWith(u8, name, "supervisord")) return .supervisord;
    if (std.mem.eql(u8, name, "simple")) return .simple;
    if (std.mem.eql(u8, name, "none")) return .none;
    return .systemd; // systemd_dbus (default), systemd_cli, or unknown → systemd
}

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

/// Comptime perfect-hash intern map: a known systemd state string → its static
/// literal. Derived from the arrays above at compile time (no duplication, no
/// runtime/heap cost), replacing the per-query linear scan in `internState`.
const state_intern_map = blk: {
    const all = known_active_states ++ known_sub_states;
    var kvs: [all.len]struct { []const u8, []const u8 } = undefined;
    for (all, 0..) |s, i| kvs[i] = .{ s, s };
    break :blk std.StaticStringMap([]const u8).initComptime(kvs);
};

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

    /// Length of the moonraker_stats ring buffer (Moonraker keeps 30 samples).
    pub const moonraker_stats_len = 30;

    gpa: std.mem.Allocator,
    clock_io: std.Io,
    proc_cpu_wall: f64 = 0,
    proc_cpu_time: f64 = 0,
    io: ?std.Io = null,
    bus: ?*NotifyBus = null,
    /// Optional reference to the live connection registry for websocket_connections count.
    conns: ?*@import("../server/connections.zig").Connections = null,
    /// Configured system `provider` string (Moonraker's `[machine] provider`),
    /// reported verbatim in system_info and used to pick the service manager.
    /// Default matches Moonraker. `provider_owned` is true once setProvider has
    /// duped a config value (so deinit frees it; the default literal is not).
    provider_name: []const u8 = "systemd_dbus",
    provider_owned: bool = false,
    /// Forge-X `[machine] script_path`. `simple` runs `<script_path>/<service> <action>`.
    /// Empty means the action stays in-memory and no script is spawned.
    script_path: []const u8 = "",
    script_path_owned: bool = false,
    /// `[machine] script_timeout` seconds. Stored for the simple provider.
    script_timeout_s: f64 = 30,
    /// Set when a sudo password has been supplied. Owned by the ctx allocator.
    sudo_password: ?[]const u8 = null,
    /// Cached result of the last sudo validation (via sudo -S -l).
    sudo_validated: ?bool = null,
    /// Proc stat timer stop flag. Set by deinit, polled by the timer thread.
    proc_stat_stop: std.Io.Event = .unset,
    /// Handle for the proc_stat timer thread, joined in deinit.
    proc_stat_thread: ?std.Thread = null,
    /// Rolling sample buffer for moonraker_stats (length `moonraker_stats_len`).
    moonraker_stats: [moonraker_stats_len]MoonrakerSample = @splat(.{}),
    moonraker_stats_head: usize = 0,
    moonraker_stats_count: usize = 0,
    moonraker_stats_mutex: std.Io.Mutex = .init,
    /// Cached `machine.system_info` payload (built once, into `system_info_arena`).
    ///
    /// WHY A CACHE: building system_info spawns TWO subprocesses (`ip -json` for
    /// network/canbus and `systemctl show` for service_state) plus several /proc
    /// reads — ~ms each. Moonraker collects system_info ONCE at startup for the
    /// same reason; phobos mirrors that.
    ///
    /// WHY IT IS STILL CORRECT (the bug a naive cache caused): service_state and
    /// network are not truly static. So the cache is INVALIDATED on every API
    /// service action (see `invalidateSystemInfo`, called from `doServiceAction`)
    /// — a Mainsail/Fluidd stop/start rebuilds it with fresh state. External
    /// (non-API) service or IP changes are not observed until the next API action
    /// or restart; Moonraker needs systemd/netlink events for those too, which
    /// phobos does not have.
    ///
    /// WHY ON-Core, NOT off_core, AND DEEP-COPIED PER REQUEST: the cache is built
    /// AND freed (on invalidate) under the Core lock, so handleSystemInfo must run
    /// under Core too (NOT off_core) or a concurrent invalidate could free the
    /// cache mid-serialize. Each request returns a `jv.deepCopy` into its own
    /// arena, so the response is serialized (outside Core) from memory the
    /// invalidate cannot free. Do not mark this endpoint off_core.
    system_info_cache: ?std.json.Value = null,
    system_info_arena: ?std.heap.ArenaAllocator = null,
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
    net_prev: [max_net_ifaces]NetSample = @splat(.{}),
    /// Separate baseline for the GET /machine/proc_stats handler so a GET can't
    /// perturb the timer's `net_prev` (which would spike the pushed samples). GETs
    /// are Core-serialised, so this needs no lock either.
    net_prev_get: [max_net_ifaces]NetSample = @splat(.{}),

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
        return state_intern_map.get(state) orelse "unknown";
    }

    pub fn init(alloc: std.mem.Allocator, clock_io: std.Io, bus: ?*NotifyBus, conns: ?*anyopaque) MachineCtx {
        return .{
            .gpa = alloc,
            .clock_io = clock_io,
            .bus = bus,
            .conns = @ptrCast(@alignCast(conns)),
            .services = std.StringHashMap(ServiceEntry).init(alloc),
        };
    }

    /// Set the configured system provider (from `[machine] provider`). The string
    /// is duped + owned; reported verbatim and used to pick the service manager.
    pub fn setProvider(self: *MachineCtx, name: []const u8) !void {
        const dup = try self.gpa.dupe(u8, name);
        if (self.provider_owned) self.gpa.free(self.provider_name);
        self.provider_name = dup;
        self.provider_owned = true;
    }

    /// Directory of Forge-X init scripts. A trailing slash is kept as given;
    /// `std.fs.path.join` builds `<dir>/<service>`.
    pub fn setScriptPath(self: *MachineCtx, path: []const u8) !void {
        const dup = try self.gpa.dupe(u8, path);
        if (self.script_path_owned) self.gpa.free(self.script_path);
        self.script_path = dup;
        self.script_path_owned = true;
    }

    pub fn setIo(self: *MachineCtx, io: std.Io) void {
        self.io = io;
        // Start the periodic proc_stat emission if a bus is wired.
        if (self.bus != null and !self.no_proc_stat_timer and self.proc_stat_thread == null) {
            self.proc_stat_stop.reset();
            self.proc_stat_thread = std.Thread.spawn(.{ .stack_size = 1 << 20 }, procStatTimerThread, .{self}) catch null;
        }
    }

    /// Set a mock command-runner for integration tests. When non-null,
    /// handler functions call fn(ctx, alloc, argv) instead of std.process.run.
    pub fn setRunCmdFn(self: *MachineCtx, run_cmd_fn: RunCmdFn, ctx: *anyopaque) void {
        self.run_cmd_fn = run_cmd_fn;
        self.run_cmd_ctx = ctx;
    }

    /// The live io when host processes may be spawned directly; null when a
    /// mock command runner is installed or io is absent.
    fn hostIo(self: *const MachineCtx) ?std.Io {
        return if (self.run_cmd_fn == null) self.io else null;
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
        self.proc_stat_stop.set(self.clock_io);
        if (self.proc_stat_thread) |th| {
            th.join();
            self.proc_stat_thread = null;
        }
        self.io = null;
        self.conns = null;
        self.bus = null;
        if (self.system_info_arena) |*ar| ar.deinit();
        if (self.sudo_password) |p| self.gpa.free(p);
        if (self.provider_owned) self.gpa.free(self.provider_name);
        if (self.script_path_owned) self.gpa.free(self.script_path);
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
    const io = self.io orelse return;
    var first: bool = true;
    while (!self.proc_stat_stop.isSet()) {
        if (!first) {
            // Sleep the 1-second tick in 100 ms chunks so deinit→join returns
            // within ~100 ms instead of up to a full second (see util/sleep.zig).
            if (sleep.untilStopped(io, .fromSeconds(1), &self.proc_stat_stop)) break;
        }
        first = false;
        emitProcStatUpdate(self, io) catch {};
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
        applyBandwidth(&self.net_prev, network, nowSeconds(io));
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
    const cpu_usage = procCpuUsage(self, io);

    // Push the new sample into the ring buffer.
    pushMoonrakerSample(self, io, .{ .time = nowSeconds(io), .cpu_usage = cpu_usage, .memory = mem });

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

/// Process CPU usage since last call for this context. Returns 0 on first
/// call, then the percentage of one CPU core consumed between successive calls.
fn procCpuUsage(self: *MachineCtx, io: std.Io) f64 {
    const proc_now = clock.processCpuSeconds(io);
    const wall_now = clock.monotonicSeconds(io);
    const usage: f64 = if (self.proc_cpu_wall > 0 and wall_now > self.proc_cpu_wall) blk: {
        const wall_diff = wall_now - self.proc_cpu_wall;
        const proc_diff = proc_now - self.proc_cpu_time;
        break :blk if (wall_diff > 0) @round(100.0 * (proc_diff / wall_diff) * 100.0) / 100.0 else 0.0;
    } else 0.0;

    self.proc_cpu_wall = wall_now;
    self.proc_cpu_time = proc_now;
    return usage;
}

/// Push a sample into the rolling moonraker_stats ring buffer. Thread-safe.
fn pushMoonrakerSample(self: *MachineCtx, io: std.Io, sample: MachineCtx.MoonrakerSample) void {
    self.moonraker_stats_mutex.lockUncancelable(io);
    defer self.moonraker_stats_mutex.unlock(io);

    self.moonraker_stats[self.moonraker_stats_head] = sample;
    self.moonraker_stats_head = (self.moonraker_stats_head + 1) % MachineCtx.moonraker_stats_len;
    if (self.moonraker_stats_count < MachineCtx.moonraker_stats_len) {
        self.moonraker_stats_count += 1;
    }
}

/// Read the current ring buffer as a JSON array of {time, cpu_usage, memory,
/// mem_units} objects in chronological order (oldest first). Locks the mutex
/// when io is available.
fn buildMoonrakerStats(self: *MachineCtx, alloc: std.mem.Allocator, io: ?std.Io) std.json.Value {
    if (io) |i| self.moonraker_stats_mutex.lockUncancelable(i);
    defer if (io) |i| self.moonraker_stats_mutex.unlock(i);

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
    const start: usize = if (count < MachineCtx.moonraker_stats_len) @as(usize, 0) else self.moonraker_stats_head;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const idx = (start + i) % MachineCtx.moonraker_stats_len;
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

// ---------------------------------------------------------------------------
// File reading helper
// ---------------------------------------------------------------------------

const max_file_bytes = 4 * 1024 * 1024;

/// Read bounded file contents into an owned slice, including size-zero proc/sys files.
/// Returns null on I/O or allocation failure.
fn readFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const f = Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    var rbuf: [4096]u8 = undefined;
    var fr = f.readerStreaming(io, &rbuf);
    return fr.interface.allocRemaining(alloc, .limited(max_file_bytes)) catch null;
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
        // Moonraker's `0*(.+)` leaves a single 0 when the serial is all zeros.
        const stripped = std.mem.trimStart(u8, sn, "0");
        out.serial_number = if (stripped.len == 0) "0" else stripped;
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
    try obj.put(alloc, "processor", .{ .string = unameField(.machine, alloc) });
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
/// `distro.version_parts()`: the first three numeric dot fields of VERSION_ID.
/// `1.4.2-6966333` is major 1, minor 4, build_number 2. A version with no
/// digits yields empty strings. The slices borrow `version`.
pub fn parseVersionParts(version: []const u8) struct { major: []const u8 = "", minor: []const u8 = "", build_number: []const u8 = "" } {
    var out: [3][]const u8 = .{ "", "", "" };
    var n: usize = 0;
    var i: usize = 0;
    while (i < version.len and n < 3) {
        const start = std.mem.findAnyPos(u8, version, i, "0123456789") orelse break;
        i = std.mem.findNonePos(u8, version, start, "0123456789") orelse version.len;
        out[n] = version[start..i];
        n += 1;
        if (i < version.len and version[i] == '.') i += 1;
    }
    return .{ .major = out[0], .minor = out[1], .build_number = out[2] };
}

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
/// Returns an empty object when no SD card is detected (no cid file).
fn buildSdInfo(ctx: *MachineCtx, alloc: std.mem.Allocator) !std.json.Value {
    const io = ctx.io orelse return .{ .object = .empty };
    const cid_raw = readFile(io, alloc, SD_CID_PATH) orelse return .{ .object = .empty };
    return parseSdInfo(alloc, cid_raw, readFile(io, alloc, SD_CSD_PATH));
}

/// Pure parser for the SD CID and CSD register texts (Moonraker
/// `_get_sdcard_info`). A malformed CID yields `{}`; a missing or malformed CSD
/// keeps capacity "Unknown" and total_bytes 0. Allocates from `alloc` (an arena).
pub fn parseSdInfo(alloc: std.mem.Allocator, cid_raw: []const u8, csd_raw: ?[]const u8) !std.json.Value {
    const empty: std.json.Value = .{ .object = .empty };
    const cid_text = try std.ascii.allocLowerString(alloc, std.mem.trim(u8, cid_raw, &std.ascii.whitespace));
    if (cid_text.len < 30) return empty;

    // Offsets match Moonraker's CID slicing.
    var name_buf: [5]u8 = undefined;
    const name_raw = std.fmt.hexToBytes(&name_buf, cid_text[6..16]) catch return empty;
    // `decode("ascii", errors="ignore")` drops non-ASCII bytes.
    var name_len: usize = 0;
    for (name_raw) |b| {
        if (!std.ascii.isAscii(b)) continue;
        name_buf[name_len] = b;
        name_len += 1;
    }
    const rev_major = std.fmt.parseInt(u8, cid_text[16..17], 16) catch return empty;
    const rev_minor = std.fmt.parseInt(u8, cid_text[17..18], 16) catch return empty;
    const mfg_year = std.fmt.parseInt(u16, cid_text[27..29], 16) catch return empty;
    const mfg_month = std.fmt.parseInt(u8, cid_text[29..30], 16) catch return empty;

    var obj: std.json.ObjectMap = .empty;
    const mid = cid_text[0..2];
    try obj.put(alloc, "manufacturer_id", .{ .string = mid });
    try obj.put(alloc, "manufacturer", .{ .string = sd_manufacturers.get(mid) orelse "Unknown" });
    try obj.put(alloc, "oem_id", .{ .string = cid_text[2..6] });
    try obj.put(alloc, "product_name", .{ .string = try alloc.dupe(u8, name_buf[0..name_len]) });
    try obj.put(alloc, "product_revision", .{ .string = try std.fmt.allocPrint(alloc, "{d}.{d}", .{ rev_major, rev_minor }) });
    try obj.put(alloc, "serial_number", .{ .string = cid_text[18..26] });
    try obj.put(alloc, "manufacturer_date", .{ .string = try std.fmt.allocPrint(alloc, "{d}/{d}", .{ mfg_month, mfg_year + 2000 }) });

    var capacity_str: []const u8 = "Unknown";
    var total_bytes: u64 = 0;
    if (csd_raw) |raw| {
        if (parseCsdCapacity(std.mem.trim(u8, raw, &std.ascii.whitespace))) |cap| {
            total_bytes = cap.total_bytes;
            const scaled = @as(f64, @floatFromInt(total_bytes)) / cap.divisor;
            capacity_str = try std.fmt.allocPrint(alloc, "{d:.1} {s}", .{ scaled, cap.unit });
        }
    }
    try obj.put(alloc, "capacity", .{ .string = capacity_str });
    // At most 2^47 bytes (CSD v3.0), so the cast cannot fail.
    try obj.put(alloc, "total_bytes", .{ .integer = @intCast(total_bytes) });
    return .{ .object = obj };
}

/// SD card capacity decoded from the CSD register, with Moonraker's display unit.
const SdCapacity = struct { total_bytes: u64, divisor: f64, unit: []const u8 };

/// Decode the 128-bit CSD register (32 hex digits) into the card capacity.
/// Returns null for malformed text or an unknown CSD structure version.
fn parseCsdCapacity(csd_text: []const u8) ?SdCapacity {
    if (csd_text.len != 32) return null;
    var csd: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&csd, csd_text) catch return null;
    switch (csd[0] >> 6) {
        0 => {
            // Standard Capacity (CSD v1.0): (C_SIZE + 1) * 2^(C_SIZE_MULT + 2) * 2^READ_BL_LEN.
            const read_bl_len: u6 = @intCast(csd[5] & 0xF);
            const c_size: u64 = (@as(u64, csd[6] & 0x3) << 10) | (@as(u64, csd[7]) << 2) | (csd[8] >> 6);
            const c_size_mult: u6 = @intCast(((csd[9] & 0x3) << 1) | (csd[10] >> 7));
            return .{ .total_bytes = (c_size + 1) << (c_size_mult + 2) << read_bl_len, .divisor = 1024.0 * 1024.0, .unit = "MiB" };
        },
        1 => {
            // High Capacity (CSD v2.0)
            const c_size: u64 = (@as(u64, csd[7] & 0x3F) << 16) | (@as(u64, csd[8]) << 8) | csd[9];
            return .{ .total_bytes = (c_size + 1) * 512 * 1024, .divisor = 1024.0 * 1024.0 * 1024.0, .unit = "GiB" };
        },
        2 => {
            // Ultra Capacity (CSD v3.0)
            const c_size: u64 = (@as(u64, csd[6] & 0xF) << 24) | (@as(u64, csd[7]) << 16) | (@as(u64, csd[8]) << 8) | csd[9];
            return .{ .total_bytes = (c_size + 1) * 512 * 1024, .divisor = 1024.0 * 1024.0 * 1024.0 * 1024.0, .unit = "TiB" };
        },
        else => return null,
    }
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
    const parts = parseVersionParts(d.version);
    var version_parts: std.json.ObjectMap = .empty;
    try version_parts.put(alloc, "major", .{ .string = parts.major });
    try version_parts.put(alloc, "minor", .{ .string = parts.minor });
    try version_parts.put(alloc, "build_number", .{ .string = parts.build_number });
    try obj.put(alloc, "version_parts", .{ .object = version_parts });
    try obj.put(alloc, "codename", .{ .string = d.version_codename });
    // release_info: distro.distro_release_info() — empty dict on os-release
    // based distros.
    try obj.put(alloc, "release_info", .{ .object = .empty });
    try obj.put(alloc, "like", .{ .string = d.like });
    try obj.put(alloc, "kernel_version", .{ .string = readKernelVersion(ctx, alloc) });
    return .{ .object = obj };
}

const UnameField = enum { release, machine };

/// `release` is the kernel version. `machine` is `uname -m` (`armv7l` on the
/// printer), which is what Moonraker uses for `processor` when
/// `platform.processor()` is empty.
fn unameField(which: UnameField, alloc: std.mem.Allocator) []const u8 {
    const uts = std.posix.uname();
    const raw = switch (which) {
        .release => std.mem.sliceTo(&uts.release, 0),
        .machine => std.mem.sliceTo(&uts.machine, 0),
    };
    return alloc.dupe(u8, raw) catch "";
}

/// Kernel release string from uname(2). Empty string on failure.
fn readKernelVersion(ctx: *MachineCtx, alloc: std.mem.Allocator) []const u8 {
    _ = ctx;
    return unameField(.release, alloc);
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

// ===========================================================================
// Network / canbus enumeration (parses `ip -json -det address`)
// ===========================================================================

const NetInfo = struct { network: std.json.Value, canbus: std.json.Value };

fn jsonStr(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn jsonInt(o: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| jv.floatToInt(f),
        else => null,
    };
}

/// Parse `ip -json -det address` output into Moonraker's network/canbus maps.
/// network[ifname] = {mac_address, ip_addresses:[{family,address,is_link_local}]}
/// for UP ethernet links; canbus[ifname] = {tx_queue_len, bitrate, driver} for
/// CAN links. Mirrors machine.py `_parse_network_interfaces`. Pure given `text`;
/// returns empty maps on any parse failure. Strings borrow `alloc`.
fn parseIpAddrJson(alloc: std.mem.Allocator, text: []const u8) NetInfo {
    var net: std.json.ObjectMap = .empty;
    var can: std.json.ObjectMap = .empty;
    const empty: NetInfo = .{ .network = .{ .object = net }, .canbus = .{ .object = can } };

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch return empty;
    if (parsed.value != .array) return empty;

    for (parsed.value.array.items) |ifc| {
        if (ifc != .object) continue;
        const o = ifc.object;
        const name = jsonStr(o, "ifname") orelse continue;
        const link_type = jsonStr(o, "link_type") orelse "";

        // Moonraker gates ALL interfaces on operstate == "UP" (machine.py:677),
        // including canbus.
        const operstate = jsonStr(o, "operstate") orelse "";
        if (!std.mem.eql(u8, operstate, "UP")) continue;

        if (std.mem.eql(u8, link_type, "can")) {
            var c: std.json.ObjectMap = .empty;
            // Real `ip -json` uses `txqlen`, not `txqueuelen` (machine.py:683).
            c.put(alloc, "tx_queue_len", .{ .integer = jsonInt(o, "txqlen") orelse 0 }) catch continue;
            // Moonraker reads bitrate from linkinfo.info_data.bittiming.bitrate
            // (default -1) and driver from linkinfo.info_data.bittiming_const.name
            // (default "unknown") — machine.py:684-689.
            var bitrate: i64 = -1;
            var driver: []const u8 = "unknown";
            if (o.get("linkinfo")) |li| {
                if (li == .object) {
                    if (li.object.get("info_data")) |idv| {
                        if (idv == .object) {
                            if (idv.object.get("bittiming")) |bt| {
                                if (bt == .object) bitrate = jsonInt(bt.object, "bitrate") orelse -1;
                            }
                            if (idv.object.get("bittiming_const")) |bc| {
                                if (bc == .object) driver = jsonStr(bc.object, "name") orelse "unknown";
                            }
                        }
                    }
                }
            }
            c.put(alloc, "bitrate", .{ .integer = bitrate }) catch continue;
            c.put(alloc, "driver", .{ .string = alloc.dupe(u8, driver) catch "unknown" }) catch continue;
            can.put(alloc, alloc.dupe(u8, name) catch continue, .{ .object = c }) catch continue;
            continue;
        }

        // Only UP ethernet links with a MAC appear in `network` (machine.py:691-693).
        if (!std.mem.eql(u8, link_type, "ether")) continue;
        if (o.get("address") == null) continue;

        var ips: std.json.Array = .init(alloc);
        if (o.get("addr_info")) |ai| {
            if (ai == .array) {
                for (ai.array.items) |a| {
                    if (a != .object) continue;
                    const fam = jsonStr(a.object, "family") orelse continue;
                    const local = jsonStr(a.object, "local") orelse continue;
                    const famname = if (std.mem.eql(u8, fam, "inet")) "ipv4" else if (std.mem.eql(u8, fam, "inet6")) "ipv6" else fam;
                    // Moonraker uses the authoritative `scope` field (machine.py:699).
                    const is_ll = std.mem.eql(u8, jsonStr(a.object, "scope") orelse "", "link");
                    var e: std.json.ObjectMap = .empty;
                    e.put(alloc, "family", .{ .string = famname }) catch continue;
                    e.put(alloc, "address", .{ .string = alloc.dupe(u8, local) catch continue }) catch continue;
                    e.put(alloc, "is_link_local", .{ .bool = is_ll }) catch continue;
                    ips.append(.{ .object = e }) catch continue;
                }
            }
        }
        // Moonraker drops interfaces with no usable addresses (machine.py:704).
        if (ips.items.len == 0) continue;
        var n: std.json.ObjectMap = .empty;
        n.put(alloc, "mac_address", .{ .string = alloc.dupe(u8, jsonStr(o, "address") orelse "") catch "" }) catch continue;
        n.put(alloc, "ip_addresses", .{ .array = ips }) catch continue;
        net.put(alloc, alloc.dupe(u8, name) catch continue, .{ .object = n }) catch continue;
    }
    return .{ .network = .{ .object = net }, .canbus = .{ .object = can } };
}

/// Run `ip -json -det address` and parse it. Returns empty maps when io is
/// absent or `ip` is unavailable/failed.
fn buildNetworkInfo(ctx: *MachineCtx, alloc: std.mem.Allocator) NetInfo {
    const empty: NetInfo = .{ .network = .{ .object = .empty }, .canbus = .{ .object = .empty } };
    // Forge-X keeps `ip` in /usr/sbin, which is not on a chroot daemon PATH.
    const tries = [_][]const []const u8{
        &.{ "ip", "-json", "-det", "address" },
        &.{ "/usr/sbin/ip", "-json", "-det", "address" },
        &.{ "/sbin/ip", "-json", "-det", "address" },
    };
    for (tries) |argv| {
        const res = ctx.runCmd(alloc, argv) catch continue;
        if (res.stdout.len == 0) continue;
        return parseIpAddrJson(alloc, res.stdout);
    }
    return empty;
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
    // Moonraker's simple/none provider replaces a bare-metal "none" with
    // unknown/unknown (BaseProvider.check_virt_status). A detected container
    // is kept. The live Forge-X printer reports unknown/unknown.
    const kind = providerKind(ctx.provider_name);
    if ((kind == .simple or kind == .none) and std.mem.eql(u8, v.virt_type, "none")) {
        v.virt_type = "unknown";
        v.virt_identifier = "unknown";
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
pub fn buildAvailableServices(ctx: *const MachineCtx, alloc: std.mem.Allocator) !std.json.Value {
    var arr: std.json.Array = .init(alloc);
    // Forge-X `simple` (and `none`) do not discover units. Moonraker's
    // SimpleProvider leaves available_services empty, which is what the
    // printer reports. systemd and supervisord keep the known list.
    const kind = providerKind(ctx.provider_name);
    if (kind == .simple or kind == .none) return .{ .array = arr };
    for (available_services) |s| try arr.append(.{ .string = s });
    return .{ .array = arr };
}

/// Returns a state map for all known services. Calls
/// `refreshServiceStates` when io is available so the response reflects
/// live systemd data. Falls back to in-memory tracking when io is absent.
pub fn buildServiceState(ctx: *MachineCtx, alloc: std.mem.Allocator) !std.json.Value {
    const kind = providerKind(ctx.provider_name);
    if (kind == .simple or kind == .none) return .{ .object = .empty };
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
    // Only the systemd provider queries systemctl. `simple` and `none` must
    // not spawn it; a GET of system_info would otherwise hit the host.
    if (providerKind(ctx.provider_name) != .systemd) return;

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

    const result = ctx.runCmd(alloc, &argv) catch return;
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
    // See the MachineCtx.system_info_cache doc comment for the full rationale
    // (cache to avoid 2 subprocesses/call; invalidated on service actions; runs
    // under Core; deep-copied per request so an invalidate can't free it mid-use).
    if (ctx.io == null) return buildSystemInfoValue(ctx, alloc); // bare tests
    if (ctx.system_info_cache == null) {
        var arena = std.heap.ArenaAllocator.init(ctx.gpa);
        errdefer arena.deinit(); // build failure must not leak the arena
        const built = try buildSystemInfoValue(ctx, arena.allocator());
        ctx.system_info_arena = arena; // commit both together only on success
        ctx.system_info_cache = built;
    }
    return jv.deepCopy(alloc, ctx.system_info_cache.?);
}

/// Drop the cached system_info so the next request rebuilds it with fresh
/// service_state / network. Called under Core whenever a service action mutates
/// ctx.services. Safe to free here because handleSystemInfo runs under Core too
/// (it never serializes the cache directly — it returns a deep copy).
pub fn invalidateSystemInfo(ctx: *MachineCtx) void {
    if (ctx.system_info_arena) |*ar| ar.deinit();
    ctx.system_info_arena = null;
    ctx.system_info_cache = null;
}

fn buildSystemInfoValue(ctx: *MachineCtx, alloc: std.mem.Allocator) anyerror!std.json.Value {
    var sys: std.json.ObjectMap = .empty;

    try sys.put(alloc, "cpu_info", try buildCpuInfo(ctx, alloc));
    try sys.put(alloc, "sd_info", try buildSdInfo(ctx, alloc));
    try sys.put(alloc, "distribution", try buildDistribution(ctx, alloc));
    try sys.put(alloc, "virtualization", try buildVirtualization(ctx, alloc));
    // network/canbus from `ip -json -det address` (empty when ip is absent).
    const netinfo = buildNetworkInfo(ctx, alloc);
    try sys.put(alloc, "network", netinfo.network);
    try sys.put(alloc, "canbus", netinfo.canbus);
    try sys.put(alloc, "python", try buildPython(alloc));
    try sys.put(alloc, "available_services", try buildAvailableServices(ctx, alloc));
    try sys.put(alloc, "service_state", try buildServiceState(ctx, alloc));
    try sys.put(alloc, "provider", .{ .string = ctx.provider_name });

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
/// Fill each interface's per-second `bandwidth` from the rx/tx delta vs its
/// previous sample stored in `prev`. The caller passes which baseline to use: the
/// timer thread its own `net_prev`, the GET handler a separate `net_prev_get`, so
/// the two never share state and a GET can't skew the pushed timer samples.
fn applyBandwidth(prev: *[max_net_ifaces]NetSample, network: std.json.Value, now: f64) void {
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
        for (prev) |*s| {
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
            // Fill per-interface bandwidth from the rx/tx delta since the last
            // sample (Moonraker reports this on the GET too, not just the push).
            // Uses the GET's OWN baseline so it never perturbs the timer's samples.
            applyBandwidth(&ctx.net_prev_get, network, nowSeconds(ctx.clock_io));
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
    try out.put(alloc, "system_uptime", .{ .float = uptimeSeconds(ctx.clock_io) });
    try out.put(alloc, "system_memory", sys_mem);
    const ws_count: i64 = if (ctx.conns) |c| blk: {
        const cio = ctx.io orelse break :blk 0;
        break :blk @intCast(c.count(cio));
    } else 0;
    try out.put(alloc, "websocket_connections", .{ .integer = ws_count });
    return .{ .object = out };
}

fn nowSeconds(io: std.Io) f64 {
    return clock.wallSeconds(io);
}

/// System uptime from CLOCK_BOOTTIME (seconds). 0 on failure.
fn uptimeSeconds(io: std.Io) f64 {
    return clock.bootSeconds(io);
}

// ===========================================================================
// reboot / shutdown
// ===========================================================================

/// POST /machine/reboot → "ok".
///
/// AGENT: NEVER implement this. It stays a no-op that returns "ok".
/// Do not call systemctl reboot, systemctl poweroff, shutdown, reboot,
/// poweroff, or a guest/host halt. Do not add a flag or a provider that
/// runs those commands. Doing so reboots the machine that runs the tests.
/// `sudo systemctl reboot` already rebooted the developer host once.
/// The "ok" string is Moonraker's response shape and nothing else.
pub fn handleReboot(ctx_ptr: *anyopaque, _: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    _ = ctx_ptr;
    return .{ .string = "ok" };
}

/// POST /machine/shutdown → "ok".
///
/// AGENT: NEVER implement this. Same rule as `handleReboot`. It returns
/// "ok" and must not power off, shut down, or halt the host or the guest.
/// Do not wire systemctl, shutdown, poweroff, or reboot behind a flag.
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

fn hostPowerWord(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "reboot") or std.mem.eql(u8, arg, "shutdown") or std.mem.eql(u8, arg, "poweroff");
}

/// Optimistic post-action state for a service when the manager can't be queried
/// (the `none` provider, no io, or a failed status query).
fn optimisticState(action: ServiceAction) struct { []const u8, []const u8 } {
    return switch (action) {
        .start, .restart => .{ "active", "running" },
        .stop => .{ "inactive", "dead" },
    };
}

/// Parse `supervisorctl status <name>` output → (active_state, sub_state). The
/// state is the second whitespace-separated token (RUNNING/STOPPED/STARTING/…).
fn supervisorState(out: []const u8) struct { []const u8, []const u8 } {
    var it = std.mem.tokenizeAny(u8, out, " \t\r\n");
    _ = it.next(); // program name
    const st = it.next() orelse return .{ "unknown", "unknown" };
    if (std.mem.eql(u8, st, "RUNNING")) return .{ "active", "running" };
    if (std.mem.eql(u8, st, "STOPPED")) return .{ "inactive", "dead" };
    if (std.mem.eql(u8, st, "STARTING")) return .{ "activating", "start" };
    if (std.mem.eql(u8, st, "STOPPING")) return .{ "deactivating", "stop" };
    if (std.mem.eql(u8, st, "FATAL") or std.mem.eql(u8, st, "BACKOFF")) return .{ "failed", "failed" };
    return .{ "unknown", "unknown" };
}

/// Shared helper for the three service action endpoints. Validates the `service`
/// param against the allow-list, runs `systemctl <action> <service>`, reads the
/// resulting state via `systemctl show`, and emits
/// `notify_service_state_changed`. Falls back to optimistic in-memory state
/// when io is null (unit test path).
fn doServiceAction(ctx: *MachineCtx, params: std.json.Value, alloc: std.mem.Allocator, action: ServiceAction) !std.json.Value {
    const name = try getStr(params, "service");
    if (!isServiceAllowed(name)) return error.Forbidden;
    // This action changes service_state, so the cached system_info is now stale —
    // drop it (covers every exit below). Runs under Core, same as handleSystemInfo.
    defer invalidateSystemInfo(ctx);

    const kind = providerKind(ctx.provider_name);
    // `none` keeps state in-memory only; otherwise run the manager when wired.
    if (kind != .none and (ctx.io != null or ctx.run_cmd_fn != null)) {
        const action_str = @tagName(action);
        var new_active: []const u8 = "unknown";
        var new_sub: []const u8 = "unknown";
        switch (kind) {
            .systemd => {
                // systemctl <start|stop|restart> --no-block <service>.
                var argv: [4][]const u8 = .{ "systemctl", action_str, "--no-block", name };
                if (ctx.runCmd(alloc, &argv)) |ar| {
                    alloc.free(ar.stdout);
                    alloc.free(ar.stderr);
                } else |_| {}
                var show_argv: [6][]const u8 = .{ "systemctl", "show", "-p", "ActiveState,SubState", "--value", name };
                const show_result = ctx.runCmd(alloc, &show_argv) catch return .{ .string = "ok" };
                defer alloc.free(show_result.stdout);
                defer alloc.free(show_result.stderr);
                var lines = std.mem.splitScalar(u8, show_result.stdout, '\n');
                const active_line = lines.next() orelse "";
                const sub_line = lines.next() orelse "";
                if (active_line.len > 0) new_active = MachineCtx.internState(active_line);
                if (sub_line.len > 0) new_sub = MachineCtx.internState(sub_line);
            },
            .supervisord => {
                // supervisorctl <start|stop|restart> <service>; state from
                // `supervisorctl status <service>` (RUNNING/STOPPED/…).
                var argv: [3][]const u8 = .{ "supervisorctl", action_str, name };
                if (ctx.runCmd(alloc, &argv)) |ar| {
                    alloc.free(ar.stdout);
                    alloc.free(ar.stderr);
                } else |_| {}
                var st_argv: [3][]const u8 = .{ "supervisorctl", "status", name };
                if (ctx.runCmd(alloc, &st_argv)) |st| {
                    defer alloc.free(st.stdout);
                    defer alloc.free(st.stderr);
                    new_active, new_sub = supervisorState(st.stdout);
                } else |_| {
                    // Optimistic fallback if the query fails.
                    new_active, new_sub = optimisticState(action);
                }
            },
            .simple => {
                // Forge-X SimpleProvider: `<script_path>/<service> <action>`.
                // No shell. reboot/shutdown/poweroff are refused. An empty
                // script_path does not spawn anything.
                new_active, new_sub = optimisticState(action);
                if (!hostPowerWord(action_str) and !hostPowerWord(name) and ctx.script_path.len != 0) {
                    if (std.fs.path.join(alloc, &.{ ctx.script_path, name })) |script| {
                        defer alloc.free(script);
                        if (!hostPowerWord(script)) {
                            var argv: [2][]const u8 = .{ script, action_str };
                            if (ctx.runCmd(alloc, &argv)) |ar| {
                                alloc.free(ar.stdout);
                                alloc.free(ar.stderr);
                            } else |_| {}
                        }
                    } else |_| {}
                }
            },
            .none => unreachable,
        }

        const entry = MachineCtx.ServiceEntry.active(new_active, new_sub);
        if (ctx.services.getPtr(name)) |existing| {
            existing.* = entry;
        } else {
            const key = try ctx.gpa.dupe(u8, name);
            errdefer ctx.gpa.free(key);
            try ctx.services.put(key, entry);
        }

        if (ctx.bus) |bus| {
            if (ctx.io) |io| {
                var svc_obj: std.json.ObjectMap = .empty;
                svc_obj.put(alloc, "active_state", .{ .string = new_active }) catch {};
                svc_obj.put(alloc, "sub_state", .{ .string = new_sub }) catch {};
                var outer: std.json.ObjectMap = .empty;
                outer.put(alloc, name, .{ .object = svc_obj }) catch {};
                _ = bus.emitLocked(io, notify.names.service_state_changed, .{ .object = outer }) catch {};
            }
        }

        return .{ .string = "ok" };
    }

    // `none` provider, or no runner: optimistic in-memory state.
    const new_active: []const u8, const new_sub: []const u8 = optimisticState(action);

    const entry = MachineCtx.ServiceEntry.active(new_active, new_sub);
    if (ctx.services.getPtr(name)) |existing| {
        existing.* = entry;
    } else {
        const key = try ctx.gpa.dupe(u8, name);
        errdefer ctx.gpa.free(key);
        try ctx.services.put(key, entry);
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
            if (ctx.hostIo()) |io| {
                const valid = runPasswordCheck(io, &sudo_list_argv, pwd);
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

    // Validate the password via sudo -S -l when host processes may run.
    if (ctx.hostIo()) |io| {
        const valid = runPasswordCheck(io, &sudo_list_argv, pwd);
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

const sudo_list_argv = [_][]const u8{ "sudo", "-S", "-l" };

/// Run `argv` with `password` and a newline on stdin. Returns true when it
/// exits 0 with output, false on a non-zero exit, and null when the command
/// cannot run or the result is undetermined. Production passes
/// `sudo_list_argv`; the password never reaches argv.
fn runPasswordCheck(io: std.Io, argv: []const []const u8, password: []const u8) ?bool {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    defer child.kill(io);

    // Write the password + newline to stdin, then close it so the command reads EOF.
    if (child.stdin) |sin| {
        var wbuf: [128]u8 = undefined;
        var writer = sin.writer(io, &wbuf);
        writer.interface.writeAll(password) catch {};
        writer.interface.writeAll("\n") catch {};
        writer.interface.flush() catch {};
        sin.close(io);
        child.stdin = null;
    }

    // Only whether stdout was non-empty matters.
    var out_len: usize = 0;
    if (child.stdout) |sout| {
        var rbuf: [256]u8 = undefined;
        var reader = sout.reader(io, &rbuf);
        out_len = reader.interface.discardRemaining() catch 0;
    }

    const term = child.wait(io) catch return null;

    if (term == .exited and term.exited == 0 and out_len > 0) {
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

/// Build the JSON object for one USB device folder `base` (e.g.
/// /sys/bus/usb/devices/1-1). Returns null if `base` is not a device folder
/// (no bDeviceClass). class/subclass/protocol carry the raw hex codes
/// (Moonraker falls back to these when usb.ids name resolution is unavailable).
fn buildUsbDevice(io: std.Io, alloc: std.mem.Allocator, base: []const u8) !?std.json.Value {
    const cls = sysAttr(io, alloc, try std.fs.path.join(alloc, &.{ base, "bDeviceClass" })) orelse return null;
    const subcls = sysAttr(io, alloc, try std.fs.path.join(alloc, &.{ base, "bDeviceSubClass" })) orelse "";
    const proto = sysAttr(io, alloc, try std.fs.path.join(alloc, &.{ base, "bDeviceProtocol" })) orelse "";
    const devnum = sysAttr(io, alloc, try std.fs.path.join(alloc, &.{ base, "devnum" })) orelse "";
    const busnum = sysAttr(io, alloc, try std.fs.path.join(alloc, &.{ base, "busnum" })) orelse "";
    const vid = sysAttr(io, alloc, try std.fs.path.join(alloc, &.{ base, "idVendor" })) orelse "";
    const pid = sysAttr(io, alloc, try std.fs.path.join(alloc, &.{ base, "idProduct" })) orelse "";

    var dev: std.json.ObjectMap = .empty;
    try dev.put(alloc, "device_num", .{ .integer = std.fmt.parseInt(i64, devnum, 10) catch 0 });
    try dev.put(alloc, "bus_num", .{ .integer = std.fmt.parseInt(i64, busnum, 10) catch 0 });
    try dev.put(alloc, "vendor_id", .{ .string = try toLowerDup(alloc, vid) });
    try dev.put(alloc, "product_id", .{ .string = try toLowerDup(alloc, pid) });
    try dev.put(alloc, "usb_location", .{ .string = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ busnum, devnum }) });
    try dev.put(alloc, "manufacturer", manuf(io, alloc, base));
    try dev.put(alloc, "product", attrOrNull(io, alloc, base, "product"));
    try dev.put(alloc, "serial", attrOrNull(io, alloc, base, "serial"));
    // Raw hex class codes (no usb.ids DB to resolve names → description null).
    try dev.put(alloc, "class", if (cls.len > 0) .{ .string = try toLowerDup(alloc, cls) } else .null);
    try dev.put(alloc, "subclass", if (subcls.len > 0) .{ .string = try toLowerDup(alloc, subcls) } else .null);
    try dev.put(alloc, "protocol", if (proto.len > 0) .{ .string = try toLowerDup(alloc, proto) } else .null);
    try dev.put(alloc, "description", .null);
    return .{ .object = dev };
}

fn enumUsb(io: std.Io, alloc: std.mem.Allocator, arr: *std.json.Array) !void {
    var dir = Dir.cwd().openDir(io, "/sys/bus/usb/devices", .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const base = try std.fs.path.join(alloc, &.{ "/sys/bus/usb/devices", entry.name });
        if (try buildUsbDevice(io, alloc, base)) |dev| try arr.append(dev);
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

/// Read a symlink and return the basename of its target, duped into `alloc`.
fn readLinkBasename(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ?[]const u8 {
    var buf: [512]u8 = undefined;
    const n = Dir.cwd().readLink(io, path, &buf) catch return null;
    if (n == 0) return null;
    return alloc.dupe(u8, std.fs.path.basename(buf[0..n])) catch null;
}

/// A /dev/serial/by-{id,path} symlink: its full path + the tty basename it
/// points at (e.g. link=/dev/serial/by-id/usb-Klipper..., target_base=ttyACM0).
const SerialLink = struct { link: []const u8, target_base: []const u8 };

/// Scan a /dev/serial/by-* directory into a list of (link, target-basename).
/// Returns an empty slice when the directory is absent.
fn collectSerialLinks(io: std.Io, alloc: std.mem.Allocator, dir_path: []const u8) []const SerialLink {
    var list: std.ArrayList(SerialLink) = .empty;
    var dir = Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const link = std.fs.path.join(alloc, &.{ dir_path, entry.name }) catch continue;
        const target_base = readLinkBasename(io, alloc, link) orelse continue;
        list.append(alloc, .{ .link = link, .target_base = target_base }) catch continue;
    }
    return list.items;
}

fn findSerialLink(links: []const SerialLink, dev_name: []const u8) ?[]const u8 {
    for (links) |l| {
        if (std.mem.eql(u8, l.target_base, dev_name)) return l.link;
    }
    return null;
}

/// Build the JSON object for one tty under `tty_root` (e.g. /sys/class/tty).
/// Returns null when the tty has no backing `device` folder. driver_name comes
/// from the `device/driver` symlink; device_type from `device/subsystem`
/// (usb → "usb", else "hardware_uart"). path_by_id/by_hardware are resolved from
/// the supplied by-id/by-path link tables. Matches machine.py find_serial_devices.
fn buildSerialDevice(
    io: std.Io,
    alloc: std.mem.Allocator,
    tty_root: []const u8,
    dev_name: []const u8,
    by_id: []const SerialLink,
    by_path: []const SerialLink,
) !?std.json.Value {
    const dev_dir = try std.fs.path.join(alloc, &.{ tty_root, dev_name, "device" });
    _ = Dir.cwd().statFile(io, dev_dir, .{}) catch return null;
    const driver = readLinkBasename(io, alloc, try std.fs.path.join(alloc, &.{ dev_dir, "driver" })) orelse "";
    const subsystem = readLinkBasename(io, alloc, try std.fs.path.join(alloc, &.{ dev_dir, "subsystem" }));
    const device_type: []const u8 = if (subsystem) |s|
        (if (std.mem.eql(u8, s, "usb")) "usb" else "hardware_uart")
    else
        "unknown";

    var dev: std.json.ObjectMap = .empty;
    try dev.put(alloc, "device_type", .{ .string = device_type });
    try dev.put(alloc, "device_path", .{ .string = try std.fmt.allocPrint(alloc, "/dev/{s}", .{dev_name}) });
    try dev.put(alloc, "device_name", .{ .string = try alloc.dupe(u8, dev_name) });
    try dev.put(alloc, "driver_name", .{ .string = driver });
    try dev.put(alloc, "path_by_hardware", if (findSerialLink(by_path, dev_name)) |p| .{ .string = p } else .null);
    try dev.put(alloc, "path_by_id", if (findSerialLink(by_id, dev_name)) |p| .{ .string = p } else .null);
    try dev.put(alloc, "usb_location", .null);
    return .{ .object = dev };
}

fn enumSerial(io: std.Io, alloc: std.mem.Allocator, arr: *std.json.Array) !void {
    const by_id = collectSerialLinks(io, alloc, "/dev/serial/by-id");
    const by_path = collectSerialLinks(io, alloc, "/dev/serial/by-path");
    var dir = Dir.cwd().openDir(io, "/sys/class/tty", .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (try buildSerialDevice(io, alloc, "/sys/class/tty", entry.name, by_id, by_path)) |dev| try arr.append(dev);
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

// linux/videodev2.h; the standard library provides the ioctl encoder, not this ABI.
const V4l2Capability = extern struct {
    driver: [16]u8,
    card: [32]u8,
    bus_info: [32]u8,
    version: u32,
    capabilities: u32,
    device_caps: u32,
    reserved: [3]u32,
};
const VIDIOC_QUERYCAP = std.os.linux.IOCTL.IOR('V', 0, V4l2Capability);

const V4l2Cap = struct {
    driver: []const u8,
    bus_info: []const u8,
    version: u32,
    caps: u32,

    fn read(io: std.Io, file: std.Io.File, alloc: std.mem.Allocator) !?V4l2Cap {
        var raw: V4l2Capability = std.mem.zeroes(V4l2Capability);
        const result = try io.operate(.{ .device_io_control = .{ .file = file, .code = VIDIOC_QUERYCAP, .arg = &raw } });
        if (result.device_io_control < 0) return null;
        const driver = try alloc.dupe(u8, cField(&raw.driver));
        errdefer alloc.free(driver);
        return .{
            .driver = driver,
            .bus_info = try alloc.dupe(u8, cField(&raw.bus_info)),
            .version = raw.version,
            .caps = raw.capabilities,
        };
    }
};

/// Trim a fixed-size C string field at its first NUL.
fn cField(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end];
}

/// Decode a v4l2 capability bitmask into Moonraker-style capability names.
fn decodeV4l2Caps(alloc: std.mem.Allocator, caps: u32) std.json.Array {
    const flags = [_]struct { bit: u32, name: []const u8 }{
        .{ .bit = 0x00000001, .name = "VIDEO_CAPTURE" },
        .{ .bit = 0x00001000, .name = "VIDEO_CAPTURE_MPLANE" },
        .{ .bit = 0x00000002, .name = "VIDEO_OUTPUT" },
        .{ .bit = 0x00002000, .name = "VIDEO_OUTPUT_MPLANE" },
        .{ .bit = 0x00000004, .name = "VIDEO_OVERLAY" },
        .{ .bit = 0x00000010, .name = "VBI_CAPTURE" },
        .{ .bit = 0x00800000, .name = "META_CAPTURE" },
        .{ .bit = 0x00010000, .name = "TUNER" },
        .{ .bit = 0x00020000, .name = "AUDIO" },
        .{ .bit = 0x01000000, .name = "READWRITE" },
        .{ .bit = 0x04000000, .name = "STREAMING" },
        .{ .bit = 0x80000000, .name = "DEVICE_CAPS" },
    };
    var arr: std.json.Array = .init(alloc);
    for (flags) |f| {
        if (caps & f.bit != 0) arr.append(.{ .string = f.name }) catch {};
    }
    return arr;
}

/// Format a v4l2 KERNEL_VERSION u32 as "major.minor.patch".
fn formatV4l2Version(alloc: std.mem.Allocator, v: u32) []const u8 {
    return std.fmt.allocPrint(alloc, "{d}.{d}.{d}", .{ (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff }) catch "";
}

/// Issue VIDIOC_QUERYCAP on a /dev/videoN node. Read-only ioctl; returns null
/// when the node can't be opened or the ioctl fails (no device / not a v4l2 cap).
fn queryV4l2Cap(io: std.Io, alloc: std.mem.Allocator, dev_path: []const u8) ?V4l2Cap {
    const f = Dir.cwd().openFile(io, dev_path, .{}) catch return null;
    defer f.close(io);
    return V4l2Cap.read(io, f, alloc) catch null;
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
        // Query the device for bus_info / version / capabilities (read-only
        // ioctl; degrades to the sysfs-only values when no device is present).
        var hardware_bus: []const u8 = "";
        var version: []const u8 = "";
        var caps_arr: std.json.Array = .init(alloc);
        if (queryV4l2Cap(io, alloc, try std.fmt.allocPrint(alloc, "/dev/{s}", .{entry.name}))) |cap| {
            hardware_bus = cap.bus_info;
            version = formatV4l2Version(alloc, cap.version);
            caps_arr = decodeV4l2Caps(alloc, cap.caps);
            if (drv_name.len == 0 and cap.driver.len > 0) drv_name = cap.driver;
        }
        try dev.put(alloc, "driver_name", .{ .string = drv_name });
        try dev.put(alloc, "hardware_bus", .{ .string = hardware_bus });
        try dev.put(alloc, "capabilities", .{ .array = caps_arr });
        try dev.put(alloc, "version", .{ .string = version });
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

    // NOT off_core: buildSystemInfoValue calls refreshServiceStates which mutates
    // ctx.services, shared with the Core-held /machine/services/* handlers.
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
    return .{ .clock_io = std.testing.io, .gpa = alloc, .io = null };
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
    const zero = parseCpuinfo("Serial\t\t: 0000000000000000\n");
    try testing.expectEqualStrings("0", zero.serial_number);
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

test "parseVersionParts: Forge-X VERSION_ID 1.4.2-6966333" {
    const p = parseVersionParts("1.4.2-6966333");
    try testing.expectEqualStrings("1", p.major);
    try testing.expectEqualStrings("4", p.minor);
    try testing.expectEqualStrings("2", p.build_number);
    const partial = parseVersionParts("7.2");
    try testing.expectEqualStrings("7", partial.major);
    try testing.expectEqualStrings("2", partial.minor);
    try testing.expectEqualStrings("", partial.build_number);
    const empty = parseVersionParts("");
    try testing.expectEqualStrings("", empty.major);
    try testing.expectEqualStrings("", empty.build_number);
}

test "buildDistribution includes version_parts" {
    var c = testCtx(testing.allocator);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try buildDistribution(&c, arena.allocator());
    const parts = v.object.get("version_parts").?.object;
    try testing.expect(parts.get("major") != null);
    try testing.expect(parts.get("minor") != null);
    try testing.expect(parts.get("build_number") != null);
}

test "simple provider virtualization is unknown outside a container" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = MachineCtx.init(a, testing.io, null, null);
    defer c.deinit();
    try c.setProvider("simple");
    const v = try buildVirtualization(&c, a);
    try testing.expectEqualStrings("unknown", v.object.get("virt_type").?.string);
    try testing.expectEqualStrings("unknown", v.object.get("virt_identifier").?.string);
}

test "simple provider reports no discovered services" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = MachineCtx.init(a, testing.io, null, null);
    defer c.deinit();
    try c.setProvider("simple");
    const listed = try buildAvailableServices(&c, a);
    try testing.expectEqual(@as(usize, 0), listed.array.items.len);
    const state = try buildServiceState(&c, a);
    try testing.expectEqual(@as(usize, 0), state.object.count());
}

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

// ---- decodeV4l2Caps / formatV4l2Version ----

test "decodeV4l2Caps: capture + streaming + device_caps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // VIDEO_CAPTURE | STREAMING | DEVICE_CAPS
    const arr = decodeV4l2Caps(a, 0x00000001 | 0x04000000 | 0x80000000);
    try testing.expectEqual(@as(usize, 3), arr.items.len);
    try testing.expectEqualStrings("VIDEO_CAPTURE", arr.items[0].string);
    try testing.expectEqualStrings("STREAMING", arr.items[1].string);
    try testing.expectEqualStrings("DEVICE_CAPS", arr.items[2].string);
    try testing.expectEqual(@as(usize, 0), decodeV4l2Caps(a, 0).items.len);
}

test "formatV4l2Version: KERNEL_VERSION u32 → major.minor.patch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 5.15.0 = (5<<16)|(15<<8)|0 = 0x050F00
    try testing.expectEqualStrings("5.15.0", formatV4l2Version(a, 0x050F00));
    try testing.expectEqualStrings("6.1.27", formatV4l2Version(a, (6 << 16) | (1 << 8) | 27));
}

test "fuzz decodeV4l2Caps: any bitmask never crashes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            _ = decodeV4l2Caps(arena.allocator(), smith.valueWithHash(u32, 0));
        }
    }.run, .{});
}

// ---- buildSerialDevice ----

test "buildSerialDevice: driver_name + device_type from sysfs symlinks" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, "{s}/{s}", .{ testing.TmpDir.parent_dir_path, &tmp.sub_path });
    // ttyACM0: a USB serial device (subsystem→usb, driver→cdc_acm).
    try tmp.dir.createDirPath(io, "ttyACM0/device");
    try tmp.dir.createDirPath(io, "drivers/cdc_acm");
    try tmp.dir.createDirPath(io, "bus/usb");
    try tmp.dir.symLink(io, "../drivers/cdc_acm", "ttyACM0/device/driver", .{});
    try tmp.dir.symLink(io, "../bus/usb", "ttyACM0/device/subsystem", .{});

    // A by-id symlink pointing at ttyACM0.
    try tmp.dir.createDirPath(io, "by-id");
    try tmp.dir.symLink(io, "../../ttyACM0", "by-id/usb-Klipper_stm32-if00", .{});
    const byid_dir = try std.fs.path.join(a, &.{ root, "by-id" });
    const by_id = collectSerialLinks(io, a, byid_dir);

    const v = (try buildSerialDevice(io, a, root, "ttyACM0", by_id, &.{})).?;
    const o = v.object;
    try testing.expectEqualStrings("/dev/ttyACM0", o.get("device_path").?.string);
    try testing.expectEqualStrings("cdc_acm", o.get("driver_name").?.string);
    try testing.expectEqualStrings("usb", o.get("device_type").?.string);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ byid_dir, "usb-Klipper_stm32-if00" }), o.get("path_by_id").?.string);
    try testing.expectEqual(std.json.Value.null, o.get("path_by_hardware").?);

    // A tty with no device folder → null.
    try tmp.dir.createDirPath(io, "tty0");
    try testing.expect((try buildSerialDevice(io, a, root, "tty0", &.{}, &.{})) == null);
}

// ---- buildUsbDevice ----

test "buildUsbDevice: emits ids + raw hex class/subclass/protocol" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, "{s}/{s}", .{ testing.TmpDir.parent_dir_path, &tmp.sub_path });
    const base = try std.fs.path.join(a, &.{ root, "1-1" });
    try tmp.dir.createDirPath(io, "1-1");
    inline for (.{
        .{ "bDeviceClass", "00" }, .{ "bDeviceSubClass", "00" },   .{ "bDeviceProtocol", "00" },
        .{ "devnum", "4" },        .{ "busnum", "1" },             .{ "idVendor", "1D50" },
        .{ "idProduct", "614E" },  .{ "manufacturer", "Klipper" }, .{ "product", "stm32" },
    }) |kv| {
        try tmp.dir.writeFile(io, .{ .sub_path = "1-1/" ++ kv[0], .data = kv[1] });
    }

    const v = (try buildUsbDevice(io, a, base)).?;
    const o = v.object;
    try testing.expectEqual(@as(i64, 4), o.get("device_num").?.integer);
    try testing.expectEqual(@as(i64, 1), o.get("bus_num").?.integer);
    try testing.expectEqualStrings("1d50", o.get("vendor_id").?.string); // lower-cased
    try testing.expectEqualStrings("614e", o.get("product_id").?.string);
    try testing.expectEqualStrings("1:4", o.get("usb_location").?.string);
    try testing.expectEqualStrings("00", o.get("class").?.string);
    try testing.expectEqualStrings("00", o.get("subclass").?.string);
    try testing.expectEqualStrings("00", o.get("protocol").?.string);

    // A non-device folder (no bDeviceClass) → null.
    try tmp.dir.createDirPath(io, "usb1");
    try testing.expect((try buildUsbDevice(io, a, try std.fs.path.join(a, &.{ root, "usb1" }))) == null);
}

// ---- parseIpAddrJson ----

test "parseIpAddrJson: UP ethernet + CAN interfaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const txt =
        \\[
        \\ {"ifname":"lo","link_type":"loopback","operstate":"UNKNOWN","address":"00:00:00:00:00:00","addr_info":[]},
        \\ {"ifname":"eth0","link_type":"ether","operstate":"UP","address":"aa:bb:cc:dd:ee:ff",
        \\  "addr_info":[{"family":"inet","local":"192.168.1.5","scope":"global"},{"family":"inet6","local":"fe80::1","scope":"link"}]},
        \\ {"ifname":"wlan0","link_type":"ether","operstate":"DOWN","address":"11:22:33:44:55:66","addr_info":[]},
        \\ {"ifname":"can0","link_type":"can","operstate":"UP","txqlen":10,
        \\  "linkinfo":{"info_kind":"can","info_data":{"bittiming":{"bitrate":500000},"bittiming_const":{"name":"mcp251xfd"}}}}
        \\]
    ;
    const r = parseIpAddrJson(a, txt);
    const net = r.network.object;
    // Only the UP ethernet link is present (lo/loopback + DOWN wlan0 excluded).
    try testing.expectEqual(@as(usize, 1), net.count());
    const eth0 = net.get("eth0").?.object;
    try testing.expectEqualStrings("aa:bb:cc:dd:ee:ff", eth0.get("mac_address").?.string);
    const ips = eth0.get("ip_addresses").?.array;
    try testing.expectEqual(@as(usize, 2), ips.items.len);
    try testing.expectEqualStrings("ipv4", ips.items[0].object.get("family").?.string);
    try testing.expectEqualStrings("192.168.1.5", ips.items[0].object.get("address").?.string);
    try testing.expectEqual(false, ips.items[0].object.get("is_link_local").?.bool);
    try testing.expectEqualStrings("ipv6", ips.items[1].object.get("family").?.string);
    try testing.expectEqual(true, ips.items[1].object.get("is_link_local").?.bool); // fe80::

    const can = r.canbus.object;
    try testing.expectEqual(@as(usize, 1), can.count());
    const can0 = can.get("can0").?.object;
    try testing.expectEqual(@as(i64, 10), can0.get("tx_queue_len").?.integer);
    try testing.expectEqual(@as(i64, 500000), can0.get("bitrate").?.integer);
    try testing.expectEqualStrings("mcp251xfd", can0.get("driver").?.string);
}

test "buildNetworkInfo uses /usr/sbin/ip when ip is not on PATH" {
    const Mock = struct {
        fn run(_: *anyopaque, gpa: std.mem.Allocator, argv: []const []const u8) anyerror!MachineCtx.RunCmdResult {
            if (argv.len > 0 and std.mem.eql(u8, argv[0], "/usr/sbin/ip")) {
                const out = try gpa.dupe(u8,
                    \\[{"ifname":"wlan0","link_type":"ether","operstate":"UP","address":"dc:84:03:6d:ea:6a","addr_info":[{"family":"inet","local":"192.168.0.150","scope":"global"}]}]
                );
                return .{ .stdout = out, .stderr = &.{} };
            }
            return .{ .stdout = &.{}, .stderr = &.{} };
        }
    };
    var dummy: u8 = 0;
    var c = MachineCtx.init(testing.allocator, testing.io, null, null);
    defer c.deinit();
    c.setRunCmdFn(Mock.run, @ptrCast(&dummy));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const net = buildNetworkInfo(&c, arena.allocator());
    try testing.expect(net.network.object.get("wlan0") != null);
}

test "parseIpAddrJson: garbage/empty yields empty maps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 0), parseIpAddrJson(a, "").network.object.count());
    try testing.expectEqual(@as(usize, 0), parseIpAddrJson(a, "not json").network.object.count());
    try testing.expectEqual(@as(usize, 0), parseIpAddrJson(a, "{}").canbus.object.count());
}

test "fuzz parseIpAddrJson: arbitrary input never crashes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var buf: [96]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = parseIpAddrJson(a, &buf);
        }
    }.run, .{});
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
    var c = MachineCtx.init(testing.allocator, testing.io, null, null);
    defer c.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t1 =
        \\eth0: 1000 0 0 0 0 0 0 0 500 0 0 0 0 0 0 0
    ;
    const n1 = try parseNetDev(a, t1);
    applyBandwidth(&c.net_prev, n1, 10.0);
    // First sighting: no baseline → bandwidth stays 0.
    try testing.expectEqual(@as(f64, 0.0), n1.object.get("eth0").?.object.get("bandwidth").?.float);

    // Second tick 2s later: rx+tx grew 1500→4500 → 3000 bytes / 2s = 1500 B/s.
    const t2 =
        \\eth0: 3000 0 0 0 0 0 0 0 1500 0 0 0 0 0 0 0
    ;
    const n2 = try parseNetDev(a, t2);
    applyBandwidth(&c.net_prev, n2, 12.0);
    try testing.expectEqual(@as(f64, 1500.0), n2.object.get("eth0").?.object.get("bandwidth").?.float);
}

test "fuzz applyBandwidth: arbitrary net objects never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var c = MachineCtx.init(testing.allocator, testing.io, null, null);
            defer c.deinit();
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var raw: [64]u8 = undefined;
            smith.bytesWithHash(&raw, 0);
            const net = parseNetDev(a, &raw) catch return;
            applyBandwidth(&c.net_prev, net, 1.0);
            applyBandwidth(&c.net_prev, net, 2.0);
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

// AGENT: NEVER implement this test for real. machine.reboot and
// machine.shutdown stay no-ops that return "ok". Running systemctl reboot,
// systemctl poweroff, shutdown, reboot, or poweroff halts the machine that
// runs the tests. Do not add a flag, a provider, or a real path behind the
// stub. A skipped or no-op assertion is the correct result.
test "handleReboot/handleShutdown: ack ok (io null)" {
    var c = MachineCtx.init(testing.allocator, testing.io, null, null);
    defer c.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("ok", (try handleReboot(@ptrCast(&c), .null, a)).string);
    try testing.expectEqualStrings("ok", (try handleShutdown(@ptrCast(&c), .null, a)).string);
}

test "service handlers: start/stop/restart update state; disallowed Forbidden" {
    var c = MachineCtx.init(testing.allocator, testing.io, null, null);
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
    var c = MachineCtx.init(testing.allocator, testing.io, null, null);
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

test "providerKind + supervisorState parsing" {
    try testing.expectEqual(Provider.systemd, providerKind("systemd_dbus"));
    try testing.expectEqual(Provider.systemd, providerKind("systemd_cli"));
    try testing.expectEqual(Provider.systemd, providerKind("anything_else"));
    try testing.expectEqual(Provider.supervisord, providerKind("supervisord_cli"));
    try testing.expectEqual(Provider.simple, providerKind("simple"));
    try testing.expectEqual(Provider.none, providerKind("none"));
    const run = supervisorState("klipper                          RUNNING   pid 1, uptime 0:00:05");
    try testing.expectEqualStrings("active", run[0]);
    try testing.expectEqualStrings("running", run[1]);
    const stop = supervisorState("klipper STOPPED");
    try testing.expectEqualStrings("inactive", stop[0]);
    const unk = supervisorState("");
    try testing.expectEqualStrings("unknown", unk[0]);
}

test "fuzz supervisorState: arbitrary output never crashes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = supervisorState(&buf);
            _ = providerKind(&buf);
        }
    }.run, .{});
}

test "provider abstraction: service action dispatches to the right manager" {
    const Mock = struct {
        first_cmd: ?[]const u8 = null,
        calls: usize = 0,
        fn run(ctx: *anyopaque, gpa: std.mem.Allocator, argv: []const []const u8) anyerror!MachineCtx.RunCmdResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.first_cmd == null and argv.len > 0) self.first_cmd = argv[0];
            self.calls += 1;
            const is_status = argv.len >= 2 and (std.mem.eql(u8, argv[1], "status") or std.mem.eql(u8, argv[1], "show"));
            const out = try gpa.dupe(u8, if (is_status) "klipper RUNNING pid 1\n" else "");
            return .{ .stdout = out, .stderr = &.{} };
        }
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Default provider → systemctl.
    {
        var mock = Mock{};
        var c = MachineCtx.init(a, testing.io, null, null);
        defer c.deinit();
        c.setRunCmdFn(Mock.run, @ptrCast(&mock));
        _ = try handleServiceStart(@ptrCast(&c), try objParams(a, "{\"service\":\"klipper\"}"), a);
        try testing.expectEqualStrings("systemctl", mock.first_cmd.?);
    }
    // supervisord → supervisorctl, RUNNING → active/running.
    {
        var mock = Mock{};
        var c = MachineCtx.init(a, testing.io, null, null);
        defer c.deinit();
        try c.setProvider("supervisord_cli");
        c.setRunCmdFn(Mock.run, @ptrCast(&mock));
        _ = try handleServiceStart(@ptrCast(&c), try objParams(a, "{\"service\":\"klipper\"}"), a);
        try testing.expectEqualStrings("supervisorctl", mock.first_cmd.?);
        try testing.expectEqualStrings("active", c.services.get("klipper").?.active_state);
    }
    // none → no real command is ever run; state is in-memory only.
    {
        var mock = Mock{};
        var c = MachineCtx.init(a, testing.io, null, null);
        defer c.deinit();
        try c.setProvider("none");
        c.setRunCmdFn(Mock.run, @ptrCast(&mock));
        _ = try handleServiceStart(@ptrCast(&c), try objParams(a, "{\"service\":\"klipper\"}"), a);
        try testing.expectEqual(@as(usize, 0), mock.calls);
        try testing.expectEqualStrings("active", c.services.get("klipper").?.active_state);
    }
    // simple → <script_path>/<service> <action>, never systemctl.
    // The mock records the path; the test does not spawn the script.
    {
        const Rec = struct {
            path: []const u8 = "",
            action: []const u8 = "",
            calls: usize = 0,
            alloc: std.mem.Allocator,
            fn run(ctx: *anyopaque, gpa: std.mem.Allocator, argv: []const []const u8) anyerror!MachineCtx.RunCmdResult {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.calls += 1;
                if (argv.len >= 1) self.path = try self.alloc.dupe(u8, argv[0]);
                if (argv.len >= 2) self.action = try self.alloc.dupe(u8, argv[1]);
                _ = gpa;
                return .{ .stdout = &.{}, .stderr = &.{} };
            }
        };
        var rec = Rec{ .alloc = testing.allocator };
        defer if (rec.path.len > 0) testing.allocator.free(rec.path);
        defer if (rec.action.len > 0) testing.allocator.free(rec.action);
        var c = MachineCtx.init(a, testing.io, null, null);
        defer c.deinit();
        try c.setProvider("simple");
        try c.setScriptPath("/no/such/scripts");
        c.setRunCmdFn(Rec.run, @ptrCast(&rec));
        _ = try handleServiceRestart(@ptrCast(&c), try objParams(a, "{\"service\":\"klipper\"}"), a);
        try testing.expectEqual(@as(usize, 1), rec.calls);
        try testing.expectEqualStrings("/no/such/scripts/klipper", rec.path);
        try testing.expectEqualStrings("restart", rec.action);
        _ = try handleReboot(@ptrCast(&c), .null, a);
        _ = try handleShutdown(@ptrCast(&c), .null, a);
        try testing.expectEqual(@as(usize, 1), rec.calls);
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
    var c = MachineCtx.init(testing.allocator, testing.io, null, null);
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
    var c = MachineCtx.init(testing.allocator, testing.io, null, null);
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
        "/machine/system_info",        "/machine/proc_stats",
        "/machine/reboot",             "/machine/shutdown",
        "/machine/services/restart",   "/machine/services/stop",
        "/machine/services/start",     "/machine/sudo/info",
        "/machine/sudo/password",      "/machine/peripherals/usb",
        "/machine/peripherals/serial", "/machine/peripherals/video",
        "/machine/peripherals/canbus",
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
            var c = MachineCtx{ .clock_io = std.testing.io, .gpa = a, .io = null };
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
            var c = MachineCtx{ .clock_io = std.testing.io, .gpa = a, .io = null };
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
            var c = MachineCtx{ .clock_io = std.testing.io, .gpa = a, .io = null };

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
            var c = MachineCtx{ .clock_io = std.testing.io, .gpa = a, .io = null };

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
            var c = MachineCtx{ .clock_io = std.testing.io, .gpa = a, .io = null };

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

test "buildSdInfo: no io returns empty object" {
    var ctx = testCtx(testing.allocator);
    const info = try buildSdInfo(&ctx, testing.allocator);
    try testing.expect(info.object.count() == 0);
}

test "parseCsdCapacity: CSD v1.0, v2.0 and v3.0 registers" {
    // 2 GB standard-capacity card: C_SIZE 3859, C_SIZE_MULT 7, READ_BL_LEN 10.
    const v1 = parseCsdCapacity("005e00325f5a83c4edb7bf9f96400089").?;
    try testing.expectEqual(@as(u64, 2023751680), v1.total_bytes);
    try testing.expectEqualStrings("MiB", v1.unit);
    // 8 GB SDHC card: C_SIZE 0x3b37.
    try testing.expectEqual(@as(u64, 7948206080), parseCsdCapacity("400e00325b5900003b377f800a40008d").?.total_bytes);
    // SDUC layout: C_SIZE 0x03ba2b.
    try testing.expectEqual(@as(u64, 128066781184), parseCsdCapacity("800e00325b590003ba2b7f800a400000").?.total_bytes);
    // Reserved structure version, truncated and non-hex registers.
    try testing.expectEqual(@as(?SdCapacity, null), parseCsdCapacity("c00e00325b5900003b377f800a40008d"));
    try testing.expectEqual(@as(?SdCapacity, null), parseCsdCapacity("005e00325f5a83c4edb7"));
    try testing.expectEqual(@as(?SdCapacity, null), parseCsdCapacity("zz5e00325f5a83c4edb7bf9f96400089"));
}

test "parseSdInfo: real CID and CSD registers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const info = try parseSdInfo(a, "035344534C303847801A2B3C4D017AC5\n", "005e00325f5a83c4edb7bf9f96400089\n");
    const o = info.object;
    try testing.expectEqualStrings("03", o.get("manufacturer_id").?.string);
    try testing.expectEqualStrings("Sandisk", o.get("manufacturer").?.string);
    try testing.expectEqualStrings("5344", o.get("oem_id").?.string);
    try testing.expectEqualStrings("SL08G", o.get("product_name").?.string);
    try testing.expectEqualStrings("8.0", o.get("product_revision").?.string);
    try testing.expectEqualStrings("1a2b3c4d", o.get("serial_number").?.string);
    try testing.expectEqualStrings("10/2023", o.get("manufacturer_date").?.string);
    try testing.expectEqualStrings("1930.0 MiB", o.get("capacity").?.string);
    try testing.expectEqual(@as(i64, 2023751680), o.get("total_bytes").?.integer);

    const hc = try parseSdInfo(a, "035344534c303847801a2b3c4d017ac5", "400e00325b5900003b377f800a40008d");
    try testing.expectEqualStrings("7.4 GiB", hc.object.get("capacity").?.string);

    const no_csd = try parseSdInfo(a, "035344534c303847801a2b3c4d017ac5", null);
    try testing.expectEqualStrings("Unknown", no_csd.object.get("capacity").?.string);
    try testing.expectEqual(@as(i64, 0), no_csd.object.get("total_bytes").?.integer);

    // Non-ASCII product-name bytes are dropped, as `errors="ignore"` does.
    const named = try parseSdInfo(a, "03534453ff303847801a2b3c4d017ac5", null);
    try testing.expectEqualStrings("S08G", named.object.get("product_name").?.string);
}

test "parseSdInfo: malformed CID yields an empty object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "0353", "035344534c303847801a2b3c4d017zc5", "035344534c3038zz801a2b3c4d017ac5" }) |cid| {
        const info = try parseSdInfo(a, cid, "400e00325b5900003b377f800a40008d");
        try testing.expectEqual(@as(usize, 0), info.object.count());
    }
}

test "fuzz parseSdInfo: arbitrary register text" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var cid: [34]u8 = undefined;
            var csd: [34]u8 = undefined;
            smith.bytesWithHash(&cid, 0);
            smith.bytesWithHash(&csd, 1);
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const info = try parseSdInfo(arena.allocator(), &cid, &csd);
            const n = info.object.count();
            try testing.expect(n == 0 or n == 9);
            _ = parseCsdCapacity(csd[0..32]);
        }
    }.run, .{});
}

test "runPasswordCheck: exit status and output decide the result" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // `cat` echoes the password and exits 0; `false` exits 1 without output.
    try testing.expectEqual(@as(?bool, true), runPasswordCheck(io, &.{"cat"}, "pwd; rm -rf /"));
    try testing.expectEqual(@as(?bool, false), runPasswordCheck(io, &.{"false"}, "x"));
    try testing.expectEqual(@as(?bool, null), runPasswordCheck(io, &.{"/nonexistent/phobos-check"}, "x"));
}

test "sudo handlers never spawn when a command runner is installed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Mock = struct {
        fn run(_: *anyopaque, _: std.mem.Allocator, _: []const []const u8) anyerror!MachineCtx.RunCmdResult {
            return error.Unexpected;
        }
    };
    var dummy: u8 = 0;
    var c = MachineCtx{ .clock_io = testing.io, .gpa = a, .io = testing.io };
    c.setRunCmdFn(Mock.run, @ptrCast(&dummy));
    _ = try handleSudoPassword(@ptrCast(&c), try objParams(a, "{\"password\":\"x\"}"), a);
    try testing.expectEqual(@as(?bool, null), c.sudo_validated);
    const info = try handleSudoInfo(@ptrCast(&c), try objParams(a, "{\"check_access\":true}"), a);
    try testing.expect(info.object.get("sudo_access").? == .null);
}

test "process CPU samples belong to each machine context" {
    const Clocks = struct {
        wall: i96 = std.time.ns_per_s,
        cpu: i96 = 0,
        fn now(userdata: ?*anyopaque, kind: std.Io.Clock) std.Io.Timestamp {
            const state: *@This() = @ptrCast(@alignCast(userdata.?));
            return .{ .nanoseconds = if (kind == .cpu_process) state.cpu else state.wall };
        }
    };
    var state: Clocks = .{};
    var vtable = std.testing.io.vtable.*;
    vtable.now = Clocks.now;
    const io: std.Io = .{ .userdata = &state, .vtable = &vtable };
    var first = MachineCtx.init(std.testing.allocator, io, null, null);
    defer first.deinit();
    var second = MachineCtx.init(std.testing.allocator, io, null, null);
    defer second.deinit();
    try std.testing.expectEqual(@as(f64, 0), procCpuUsage(&first, io));
    state.wall += std.time.ns_per_s;
    state.cpu += std.time.ns_per_s / 4;
    try std.testing.expectEqual(@as(f64, 25), procCpuUsage(&first, io));
    try std.testing.expectEqual(@as(f64, 0), procCpuUsage(&second, io));
}

test "fuzz process CPU sample starts independently of other contexts" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var first = MachineCtx.init(std.testing.allocator, std.testing.io, null, null);
            defer first.deinit();
            first.proc_cpu_wall = @floatFromInt(smith.valueRangeAtMostWithHash(u32, 1, 1000, 0));
            _ = procCpuUsage(&first, std.testing.io);
            var second = MachineCtx.init(std.testing.allocator, std.testing.io, null, null);
            defer second.deinit();
            try std.testing.expectEqual(@as(f64, 0), procCpuUsage(&second, std.testing.io));
        }
    }.run, .{});
}

const V4l2IoStub = struct {
    raw: V4l2Capability = std.mem.zeroes(V4l2Capability),
    result: i32 = 0,
    canceled: bool = false,

    const vtable: std.Io.VTable = blk: {
        var table = std.Io.failing.vtable.*;
        table.operate = operate;
        break :blk table;
    };

    fn io(self: *@This()) std.Io {
        return .{ .userdata = self, .vtable = &vtable };
    }

    fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        const self: *@This() = @ptrCast(@alignCast(userdata.?));
        std.debug.assert(operation == .device_io_control);
        const request = operation.device_io_control;
        std.debug.assert(request.code == std.os.linux.IOCTL.IOR('V', 0, V4l2Capability));
        if (self.canceled) return error.Canceled;
        const out: *V4l2Capability = @ptrCast(@alignCast(request.arg.?));
        out.* = self.raw;
        return .{ .device_io_control = self.result };
    }
};

test "video query uses native device control and owns typed capability fields" {
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(V4l2Capability));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(V4l2Capability, "bus_info"));
    try std.testing.expectEqual(@as(usize, 80), @offsetOf(V4l2Capability, "version"));
    var stub: V4l2IoStub = .{};
    @memcpy(stub.raw.driver[0..6], "uvcvid");
    @memcpy(stub.raw.bus_info[0..5], "usb-1");
    stub.raw.version = 0x060c05;
    stub.raw.capabilities = 0x04000001;
    const file: std.Io.File = .{ .handle = -1, .flags = .{ .nonblocking = false } };
    const cap = (try V4l2Cap.read(stub.io(), file, std.testing.allocator)).?;
    defer std.testing.allocator.free(cap.driver);
    defer std.testing.allocator.free(cap.bus_info);
    @memset(std.mem.asBytes(&stub.raw), 0);
    try std.testing.expectEqualStrings("uvcvid", cap.driver);
    try std.testing.expectEqualStrings("usb-1", cap.bus_info);
    try std.testing.expectEqual(@as(u32, 0x060c05), cap.version);
    try std.testing.expectEqual(@as(u32, 0x04000001), cap.caps);
    stub.result = -1;
    try std.testing.expectEqual(null, try V4l2Cap.read(stub.io(), file, std.testing.allocator));
    stub.canceled = true;
    try std.testing.expectError(error.Canceled, V4l2Cap.read(stub.io(), file, std.testing.allocator));
    stub.canceled = false;
    stub.result = 0;
    @memcpy(stub.raw.driver[0..6], "uvcvid");
    @memcpy(stub.raw.bus_info[0..5], "usb-1");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn read(alloc: std.mem.Allocator, peer: *V4l2IoStub, f: std.Io.File) !void {
            const result = (try V4l2Cap.read(peer.io(), f, alloc)).?;
            defer alloc.free(result.driver);
            defer alloc.free(result.bus_info);
        }
    }.read, .{ &stub, file });
}

test "fuzz video capability fields stay bounded with native device control" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var stub: V4l2IoStub = .{};
            smith.bytesWithHash(std.mem.asBytes(&stub.raw), 0);
            const file: std.Io.File = .{ .handle = -1, .flags = .{ .nonblocking = false } };
            const cap = (try V4l2Cap.read(stub.io(), file, std.testing.allocator)).?;
            defer std.testing.allocator.free(cap.driver);
            defer std.testing.allocator.free(cap.bus_info);
            try std.testing.expect(cap.driver.len <= stub.raw.driver.len);
            try std.testing.expect(cap.bus_info.len <= stub.raw.bus_info.len);
            try std.testing.expectEqual(stub.raw.version, cap.version);
        }
    }.run, .{});
}

test "machine file reads own exact storage and stream virtual files" {
    const alloc = std.testing.allocator;
    const aio = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(aio, .{ .sub_path = "sample", .data = "abc" });
    const path = try tmp.dir.realPathFileAlloc(aio, "sample", alloc);
    defer alloc.free(path);
    const contents = readFile(aio, alloc, path) orelse return error.MissingFile;
    defer alloc.free(contents);
    try std.testing.expectEqualStrings("abc", contents);
    const virtual = readFile(aio, alloc, "/proc/version") orelse return error.MissingFile;
    defer alloc.free(virtual);
    try std.testing.expect(std.mem.startsWith(u8, virtual, "Linux version "));
}

test "machine file reads reject oversized inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const aio = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try alloc.alloc(u8, max_file_bytes + 1);
    @memset(bytes, 'x');
    try tmp.dir.writeFile(aio, .{ .sub_path = "large", .data = bytes });
    const path = try tmp.dir.realPathFileAlloc(aio, "large", alloc);
    try std.testing.expect(readFile(aio, alloc, path) == null);
    try tmp.dir.writeFile(aio, .{ .sub_path = "large", .data = bytes[0..max_file_bytes] });
    try std.testing.expectEqual(max_file_bytes, (readFile(aio, alloc, path) orelse return error.MissingFile).len);
}

test "fuzz machine file reads preserve bytes with exact owned storage" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            const alloc = std.testing.allocator;
            const aio = std.testing.io;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var bytes: [128]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const len = smith.valueRangeAtMostWithHash(u8, 0, bytes.len, 1);
            try tmp.dir.writeFile(aio, .{ .sub_path = "sample", .data = bytes[0..len] });
            const path = try tmp.dir.realPathFileAlloc(aio, "sample", alloc);
            defer alloc.free(path);
            const contents = readFile(aio, alloc, path) orelse return error.MissingFile;
            defer alloc.free(contents);
            try std.testing.expectEqualSlices(u8, bytes[0..len], contents);
        }
    }.run, .{});
}
