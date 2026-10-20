//! machine.device_power.* API component — Moonraker-compatible power device control.
//!
//! Mirrors the endpoints registered in
//! `vendor/moonraker/moonraker/components/power.py`:
//!
//!   GET  /machine/device_power/devices → machine.device_power.devices
//!   GET  /machine/device_power/status  → machine.device_power.status  (batch)
//!   POST /machine/device_power/on      → machine.device_power.on      (batch)
//!   POST /machine/device_power/off     → machine.device_power.off     (batch)
//!   GET  /machine/device_power/device  → machine.device_power.get_device (single)
//!   POST /machine/device_power/device  → machine.device_power.post_device (single)
//!
//! HTTP power devices (type "http" or any type with on_url/off_url configured)
//! send HTTP GET requests to the configured URLs. `tasmota` and `shelly` devices
//! derive their URLs from the configured address (see tasmotaUrls/shellyUrls,
//! wired in app.setConfig). `type: gpio` devices with a `pin` drive the line via
//! the sysfs GPIO driver (`gpio_sysfs.zig`), honouring active-low ("!pin"). The
//! remaining vendor types (tplink_smartplug, homeseer) track state in memory
//! only. A failed device request sets the state to "error" and fails the request
//! (Moonraker `set_power`).
//!
//! CORE LOCK. Handlers run under Core; device HTTP releases it for the round
//! trip (as `KlippyCtx.requestConcurrent` does) and re-resolves the device by
//! name afterwards. Each request is bounded by `http_timeout`.
//!
//! DEVICES FROM CONFIG. Without `[power <name>]` config sections (the spine
//! carries none), the devices map is empty and the list endpoint returns [].
//! Device-specific requests return a device-not-found error matching Moonraker's
//! `"No valid device named <x>"` message.
//!
//! NOTIFICATIONS. State changes emit `notify_power_changed` with the per-device
//! info payload via `bus.emitLocked` — handlers run under the held Core lock.

const std = @import("std");
const webreq = @import("../json/params.zig");
const registry = @import("../server/registry.zig");
const notify = @import("../server/notify.zig");
const NotifyBus = @import("../server/notify.zig").NotifyBus;
const Core = @import("../server/core.zig").Core;
const gpio_sysfs = @import("gpio_sysfs.zig");
const http_get = @import("http_get.zig");
const templates = @import("sensor_template.zig");
const clock = @import("../util/clock.zig");
const sleep = @import("../util/sleep.zig");
const jsonrpc = @import("../jsonrpc.zig");
const Config = @import("../config/confighelper.zig").ConfigParser;

const Registry = registry.Registry;

/// Request timeout of Moonraker's HTTP power devices (power.py `_send_http_command`).
const http_timeout: std.Io.Duration = .fromSeconds(20);
/// Largest device response body kept. Status replies are a few hundred bytes.
const max_response_bytes = 4096;
const generic_request_attempts = 3;
const generic_retry_pause: std.Io.Duration = .fromSeconds(1);
const max_request_template_bytes = 64 * 1024;

/// Send one HTTP request to a power or WLED device and return the 2xx response
/// body, a slice of `body`. A longer body, a non-2xx status or an expired
/// `timeout` is an error. The request runs as a concurrent task cancelled at
/// the deadline: the installed `std.Io.Threaded` backend panics on a socket
/// connect timeout, so cancelation bounds the connect.
pub fn deviceRequest(
    gpa: std.mem.Allocator,
    io: std.Io,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
    timeout: std.Io.Duration,
    body: []u8,
) ![]u8 {
    const json_header = [_]std.http.Header{.{ .name = "content-type", .value = "application/json" }};
    return deviceRequestHeaders(gpa, io, method, url, payload, if (payload != null) &json_header else &.{}, timeout, body, null);
}

fn deviceRequestHeaders(gpa: std.mem.Allocator, io: std.Io, method: std.http.Method, url: []const u8, payload: ?[]const u8, headers: []const std.http.Header, timeout: std.Io.Duration, body: []u8, status_out: ?*std.http.Status) ![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var writer: std.Io.Writer = .fixed(body);
    const Outcome = union(enum) {
        fetched: @typeInfo(@TypeOf(http_get.requestToWriter)).@"fn".return_type.?,
        expired: std.Io.Cancelable!void,
    };
    var outcomes: [2]Outcome = undefined;
    var select: std.Io.Select(Outcome) = .init(io, &outcomes);
    defer select.cancelDiscard();
    try select.concurrent(.fetched, http_get.requestToWriter, .{ &client, method, url, payload, headers, &writer });
    try select.concurrent(.expired, std.Io.sleep, .{ io, timeout, .awake });
    switch (try select.await()) {
        .expired => |result| {
            try result;
            return error.Timeout;
        },
        .fetched => |result| {
            const status = try result;
            if (status_out) |out| out.* = status;
            if (status.class() != .success) return error.HttpStatus;
            return writer.buffered();
        },
    }
}

// ---------------------------------------------------------------------------
// Device types (matches power.py dev_types)
// ---------------------------------------------------------------------------

/// A configured power device. State is tracked in memory and, for HTTP and
/// `type: gpio` devices, mirrored to real hardware on on/off (see setPower).
pub const Device = struct {
    name: []const u8,
    type_str: []const u8,
    state: []const u8, // "on" | "off" | "init" | "error"
    locked_while_printing: bool = false,
    /// KlipperDevice-specific field; always false for other types.
    is_shutdown: bool = false,
    /// Desired initial state on startup ("on" | "off" | null).
    initial_state: ?[]const u8 = null,
    /// HTTP device URLs. When non-null and io is wired, real HTTP GET
    /// requests are sent. on_url / off_url are used for power state changes;
    /// status_url is used for status-refresh queries.
    on_url: ?[]const u8 = null,
    off_url: ?[]const u8 = null,
    status_url: ?[]const u8 = null,
    /// sysfs GPIO line number (config `pin`). When set and io is wired,
    /// on/off drives the line via `gpio_sysfs`.
    gpio_pin: ?u32 = null,
    /// Active-low line: "on" drives the physical level low (Moonraker "!pin").
    gpio_active_low: bool = false,
    off_when_shutdown: bool = false,
    off_when_shutdown_delay: f64 = 0,
    on_when_job_queued: bool = false,
    bound_services: ?[]const u8 = null,
    restart_klipper_when_powered: bool = false,
    restart_delay: f64 = 1,
    restrict_action_processing: bool = true,
    timer: ?f64 = null,
    request_template: ?[]const u8 = null,
    response_template: ?[]const u8 = null,
    auto_off_at: ?f64 = null,
    shutdown_off_at: ?f64 = null,
    restart_at: ?f64 = null,
    need_scheduled_restart: bool = false,
    queued_on: bool = false,
    request_error: ?[]const u8 = null,
    requested_state: ?[]const u8 = null,

    fn dupe(self: Device, alloc: std.mem.Allocator) !Device {
        var owned = self;
        inline for (comptime std.meta.fieldNames(Device)) |field| {
            const T = @TypeOf(@field(owned, field));
            if (T == []const u8) @field(owned, field) = "";
            if (T == ?[]const u8) @field(owned, field) = null;
        }
        errdefer owned.deinit(alloc);
        inline for (comptime std.meta.fieldNames(Device)) |field| {
            const T = @TypeOf(@field(owned, field));
            if (T == []const u8) @field(owned, field) = try alloc.dupe(u8, @field(self, field));
            if (T == ?[]const u8) @field(owned, field) = if (@field(self, field)) |value| try alloc.dupe(u8, value) else null;
        }
        return owned;
    }

    fn deinit(self: *Device, alloc: std.mem.Allocator) void {
        inline for (comptime std.meta.fieldNames(Device)) |field| {
            const T = @TypeOf(@field(self, field));
            if (T == []const u8) alloc.free(@field(self, field));
            if (T == ?[]const u8) if (@field(self, field)) |value| alloc.free(value);
        }
    }
};

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

pub const PowerCtx = struct {
    gpa: std.mem.Allocator,
    bus: ?*NotifyBus,
    io: ?std.Io,
    /// Held by the caller of every handler once wired; released for device HTTP.
    core: ?*Core = null,
    /// Configured devices. Owned by the ctx; keys/values allocated with gpa.
    devices: std.StringHashMap(Device),
    /// Reports an active print. Mutating requests on `locked_while_printing`
    /// devices are rejected while it returns true (Moonraker `kconn.is_printing()`).
    printing_check: ?*const fn (*anyopaque) bool = null,
    printing_ctx: ?*anyopaque = null,
    /// sysfs GPIO controller root. Overridable so tests can target a temp dir.
    gpio_root: []const u8 = "/sys/class/gpio",
    requests: std.Io.Mutex = .init,
    timer_stop: std.Io.Event = .unset,
    timer_worker: ?std.Io.Future(void) = null,
    klippy_shutdown: bool = false,
    klippy_started: bool = false,
    klippy_ready: bool = false,
    tick_time: ?f64 = null,
    action_ctx: ?*anyopaque = null,
    service_action: ?*const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror!void = null,
    service_validate: ?*const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!void = null,
    firmware_restart: ?*const fn (*anyopaque, std.mem.Allocator) anyerror!void = null,

    pub fn init(alloc: std.mem.Allocator, bus: ?*NotifyBus) PowerCtx {
        return .{
            .gpa = alloc,
            .bus = bus,
            .io = null,
            .devices = std.StringHashMap(Device).init(alloc),
        };
    }

    pub fn deinit(self: *PowerCtx) void {
        self.stopTimerWorker();
        var it = self.devices.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.gpa);
        }
        self.devices.deinit();
    }

    pub fn setIo(self: *PowerCtx, io: std.Io) void {
        self.io = io;
    }

    pub fn configure(self: *PowerCtx, cfg: *const Config) !void {
        const names = try cfg.sectionNames(self.gpa);
        defer self.gpa.free(names);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        for (names) |section| {
            if (!std.mem.startsWith(u8, section, "power ")) continue;
            const name = section["power ".len..];
            if (name.len == 0) return error.InvalidValue;
            const kind = cfg.get(section, "type") orelse "gpio";
            const pin = if (cfg.get(section, "pin")) |spec| gpio_sysfs.parsePin(spec) orelse {
                std.debug.print("phobos: warning: power device '{s}': invalid pin, device not added\n", .{name});
                continue;
            } else null;
            var urls: ?ProtoUrls = null;
            if (cfg.get(section, "on_url") == null) if (cfg.get(section, "address")) |address| {
                const id = cfg.getInt(section, "output_id") catch |err| if (err == error.NoOption) @as(i64, if (std.mem.eql(u8, kind, "shelly")) 0 else 1) else return err;
                if (std.mem.eql(u8, kind, "tasmota")) urls = try tasmotaUrls(a, address, id, cfg.get(section, "password")) else if (std.mem.eql(u8, kind, "shelly")) urls = try shellyUrls(a, address, id);
            };
            const shutdown_delay = try configFloat(cfg, section, "off_when_shutdown_delay", 0, 0);
            const restart_delay = try configFloat(cfg, section, "restart_delay", 1, 0.000001);
            if (restart_delay <= 0.000001) return error.InvalidValue;
            if (std.mem.eql(u8, kind, "klipper_device") and
                ((try configBool(cfg, section, "off_when_shutdown", false)) or (try configBool(cfg, section, "restart_klipper_when_powered", false)))) return error.InvalidValue;
            const timer_value: ?f64 = if (cfg.get(section, "timer") != null) try configFloat(cfg, section, "timer", 0, 0.000001) else null;
            if (urls) |*u| if (cfg.get(section, "timer")) |delay| {
                const escaped = std.fmt.alt(std.Uri.Component{ .raw = delay }, .formatEscaped);
                if (std.mem.eql(u8, kind, "shelly")) u.off = try std.fmt.allocPrint(a, "{s}?turn=on&timer={f}", .{ u.status, escaped }) else if (std.mem.eql(u8, kind, "tasmota")) {
                    const address = cfg.get(section, "address").?;
                    const id = cfg.getInt(section, "output_id") catch 1;
                    const command = try std.fmt.allocPrint(a, "Backlog Delay {s}0; Power{d} OFF", .{ delay, id });
                    const auth = if (cfg.get(section, "password")) |password| try std.fmt.allocPrint(a, "&user=admin&password={f}", .{std.fmt.alt(std.Uri.Component{ .raw = password }, .formatEscaped)}) else "";
                    u.off = try std.fmt.allocPrint(a, "http://{s}/cm?cmnd={f}{s}", .{ address, std.fmt.alt(std.Uri.Component{ .raw = command }, .formatEscaped), auth });
                }
            };
            for ([_][]const u8{ "request_template", "response_template" }) |option| if (cfg.get(section, option)) |source| {
                var template = try templates.Template.init(self.gpa, source);
                template.deinit();
            };
            const services = cfg.get(section, "bound_services") orelse "";
            const service = cfg.get(section, "bound_service") orelse "";
            try self.addDevice(.{
                .name = name,
                .type_str = kind,
                .state = "off",
                .gpio_pin = if (pin) |p| p.line else null,
                .gpio_active_low = if (pin) |p| p.inverted else false,
                .locked_while_printing = try configBool(cfg, section, "locked_while_printing", false),
                .initial_state = if (cfg.get(section, "initial_state") != null) (if (try cfg.getBoolean(section, "initial_state")) "on" else "off") else null,
                .on_url = cfg.get(section, "on_url") orelse if (urls) |u| u.on else null,
                .off_url = cfg.get(section, "off_url") orelse if (urls) |u| u.off else null,
                .status_url = cfg.get(section, "status_url") orelse if (urls) |u| u.status else null,
                .off_when_shutdown = try configBool(cfg, section, "off_when_shutdown", false),
                .off_when_shutdown_delay = shutdown_delay,
                .on_when_job_queued = try configBool(cfg, section, if (cfg.get(section, "on_when_upload_queued") != null) "on_when_upload_queued" else "on_when_job_queued", false),
                .bound_services = try std.fmt.allocPrint(a, "{s},{s}", .{ services, service }),
                .restart_klipper_when_powered = try configBool(cfg, section, "restart_klipper_when_powered", false),
                .restart_delay = restart_delay,
                .restrict_action_processing = try configBool(cfg, section, "restrict_action_processing", true),
                .timer = if (std.mem.eql(u8, kind, "gpio") or std.mem.eql(u8, kind, "klipper_device") or std.mem.eql(u8, kind, "rf")) timer_value else null,
                .request_template = cfg.get(section, "request_template"),
                .response_template = cfg.get(section, "response_template"),
            });
        }
    }

    pub fn startTimerWorker(self: *PowerCtx) !void {
        const io = self.io orelse return error.NotReady;
        if (self.timer_worker != null or self.devices.count() == 0) return;
        self.timer_stop.reset();
        self.timer_worker = try io.concurrent(timerWorker, .{self});
    }

    pub fn stopTimerWorker(self: *PowerCtx) void {
        const io = self.io orelse return;
        self.timer_stop.set(io);
        if (self.timer_worker) |*worker| {
            worker.cancel(io);
            self.timer_worker = null;
        }
    }

    fn now(self: *const PowerCtx) f64 {
        return if (self.io) |io| clock.monotonicSeconds(io) else self.tick_time orelse 0;
    }

    /// Klippy callbacks run under Core and only schedule device work.
    pub fn onKlippyState(self: *PowerCtx, state: []const u8, now_seconds: f64) void {
        self.klippy_shutdown = std.mem.eql(u8, state, "shutdown");
        self.klippy_ready = std.mem.eql(u8, state, "ready");
        self.klippy_started = self.klippy_ready or self.klippy_shutdown or std.mem.eql(u8, state, "error");
        var it = self.devices.valueIterator();
        while (it.next()) |dev| {
            if (self.klippy_shutdown and dev.off_when_shutdown) dev.shutdown_off_at = now_seconds + dev.off_when_shutdown_delay;
            if (!self.klippy_shutdown) dev.shutdown_off_at = null;
            if (self.klippy_started and dev.need_scheduled_restart) {
                dev.need_scheduled_restart = false;
                dev.restart_at = if (self.klippy_ready) null else now_seconds + dev.restart_delay;
            }
        }
    }

    pub fn onJobQueued(self: *PowerCtx) void {
        var it = self.devices.valueIterator();
        while (it.next()) |dev| if (dev.on_when_job_queued) {
            dev.queued_on = true;
        };
    }

    pub fn validateBoundServices(self: *PowerCtx, alloc: std.mem.Allocator) !void {
        var it = self.devices.valueIterator();
        while (it.next()) |dev| {
            var tokens = std.mem.tokenizeAny(u8, dev.bound_services orelse "", ",\n");
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer seen.deinit(alloc);
            while (tokens.next()) |token| {
                var name = std.mem.trim(u8, token, " \t\r");
                if (std.mem.endsWith(u8, name, ".service")) name = name[0 .. name.len - ".service".len];
                if (name.len == 0) continue;
                const prior = try seen.getOrPut(alloc, name);
                if (prior.found_existing) continue;
                const validate = self.service_validate orelse return error.NotReady;
                try validate(self.action_ctx orelse return error.NotReady, alloc, name);
            }
        }
    }

    /// Tick under Core; callers provide monotonic seconds for deterministic tests.
    pub fn tick(self: *PowerCtx, now_seconds: f64, alloc: std.mem.Allocator) !void {
        self.tick_time = now_seconds;
        defer self.tick_time = null;
        var names: std.ArrayList([]const u8) = .empty;
        defer {
            for (names.items) |name| alloc.free(name);
            names.deinit(alloc);
        }
        var it = self.devices.keyIterator();
        while (it.next()) |name| {
            const copy = try alloc.dupe(u8, name.*);
            errdefer alloc.free(copy);
            try names.append(alloc, copy);
        }
        for (names.items) |name| {
            const dev = self.findDevice(name) orelse continue;
            const queued = dev.queued_on;
            dev.queued_on = false;
            const off = (if (dev.auto_off_at) |at| at <= now_seconds else false) or
                (self.klippy_shutdown and (if (dev.shutdown_off_at) |at| at <= now_seconds else false));
            if (off) {
                dev.auto_off_at = null;
                dev.shutdown_off_at = null;
            }
            const restart = if (dev.restart_at) |at| at <= now_seconds else false;
            if (restart) dev.restart_at = null;
            if (off or queued) _ = self.processDevice(name, if (off) "off" else "on", false, alloc) catch |err| {
                std.debug.print("phobos: warning: power device '{s}' scheduled request failed: {}\n", .{ name, err });
                continue;
            };
            if (restart) if (self.firmware_restart) |run| try run(self.action_ctx orelse return error.NotReady, alloc);
        }
    }

    fn processChanged(self: *PowerCtx, name: []const u8, alloc: std.mem.Allocator, actions: bool) !void {
        const dev = self.findDevice(name) orelse return error.NotFound;
        emitPowerChanged(self, alloc, dev);
        if (!actions) return;
        const state = try alloc.dupe(u8, dev.state);
        if (!std.mem.eql(u8, state, "on") and !std.mem.eql(u8, state, "off")) return;
        if (dev.restart_klipper_when_powered and std.mem.eql(u8, state, "on")) {
            dev.need_scheduled_restart = !self.klippy_started;
            dev.restart_at = if (self.klippy_started and !self.klippy_ready) self.now() + dev.restart_delay else null;
        }
        try self.processServices(name, alloc);
    }

    fn processServices(self: *PowerCtx, name: []const u8, alloc: std.mem.Allocator) !void {
        const dev = self.findDevice(name) orelse return error.NotFound;
        const state = try alloc.dupe(u8, dev.state);
        if (!std.mem.eql(u8, state, "on") and !std.mem.eql(u8, state, "off")) return;
        const services = try alloc.dupe(u8, dev.bound_services orelse "");
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(alloc);
        var tokens = std.mem.tokenizeAny(u8, services, ",\n");
        while (tokens.next()) |token| {
            var service = std.mem.trim(u8, token, " \t\r");
            if (std.mem.endsWith(u8, service, ".service")) service = service[0 .. service.len - ".service".len];
            if (service.len == 0) continue;
            const prior = try seen.getOrPut(alloc, service);
            if (prior.found_existing) continue;
            const run = self.service_action orelse return error.NotReady;
            run(self.action_ctx orelse return error.NotReady, alloc, if (std.mem.eql(u8, state, "on")) "start" else "stop", service) catch |err|
                std.debug.print("phobos: warning: bound service '{s}' action failed: {}\n", .{ service, err });
        }
    }

    /// Trusted callers may force a request past the printing lock.
    pub fn processDevice(self: *PowerCtx, name: []const u8, action: []const u8, force: bool, alloc: std.mem.Allocator) ![]const u8 {
        if (self.io) |io| {
            if (self.core) |core| core.unlock(io);
            self.requests.lockUncancelable(io);
            if (self.core) |core| core.lock(io);
        }
        defer if (self.io) |io| self.requests.unlock(io);
        return processRequest(self, self.findDevice(name) orelse return error.NotFound, action, alloc, force);
    }

    /// Drive every device configured with an `initial_state` to that state at
    /// startup (Moonraker `_set_initial_state`). Runs before `core` is wired, so
    /// device I/O does not release a lock. A failed device is left in "error".
    /// Does not emit a change notification (this is the boot baseline).
    pub fn applyInitialStates(self: *PowerCtx) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        var it = self.devices.valueIterator();
        while (it.next()) |dev| {
            const target = dev.initial_state orelse continue;
            const on = std.mem.eql(u8, target, "on");
            if (!on and !std.mem.eql(u8, target, "off")) continue;
            self.setPower(arena.allocator(), dev.name, on) catch |err|
                std.debug.print("phobos: warning: power device '{s}' initial state failed: {}\n", .{ dev.name, err });
            self.processServices(dev.name, arena.allocator()) catch |err|
                std.debug.print("phobos: warning: power device '{s}' initial services failed: {}\n", .{ dev.name, err });
        }
    }

    /// Drive a device's sysfs line. No-op without a configured pin or when io is
    /// not wired (unit-test path).
    fn driveGpio(self: *PowerCtx, dev: *const Device, on: bool) !void {
        const io = self.io orelse return;
        const pin = dev.gpio_pin orelse return;
        const g = gpio_sysfs.SysfsGpio{ .io = io, .root = self.gpio_root };
        // active_low: "on" places a LOW level on the line.
        try g.setValue(pin, on != dev.gpio_active_low);
    }

    /// HTTP GET `url` (borrowed from `alloc`, not from a device) with Core
    /// released. Returns the body in `alloc`, or null when io is not wired.
    fn deviceGet(self: *PowerCtx, alloc: std.mem.Allocator, url: []const u8) !?[]u8 {
        const io = self.io orelse return null;
        const body = try alloc.alloc(u8, max_response_bytes);
        if (self.core) |core| core.unlock(io);
        defer if (self.core) |core| core.lock(io);
        return try deviceRequest(self.gpa, io, .GET, url, null, http_timeout, body);
    }

    /// Switch device `name` on or off: drive its GPIO line or send its on/off
    /// URL, then record the new state. On a device failure the state becomes
    /// "error" and `error.DeviceRequestFailed` is returned. `name` must not
    /// borrow from a device: Core is released during HTTP.
    fn setPower(self: *PowerCtx, alloc: std.mem.Allocator, name: []const u8, on: bool) !void {
        const dev = self.findDevice(name) orelse return error.NotFound;
        const requested = try self.gpa.dupe(u8, if (on) "on" else "off");
        if (dev.requested_state) |old| self.gpa.free(old);
        dev.requested_state = requested;
        const url: ?[]const u8 = if (on) dev.on_url else dev.off_url;
        const owned_url = if (url) |u| try alloc.dupe(u8, u) else null;
        const ok = blk: {
            self.driveGpio(dev, on) catch |err| {
                std.debug.print("phobos: warning: power device '{s}' gpio drive failed: {}\n", .{ name, err });
                try self.recordError(name, err);
                break :blk false;
            };
            if (dev.response_template != null and self.io != null) {
                const result = self.genericRequest(alloc, name, if (on) "on" else "off") catch |err| {
                    try self.recordError(name, err);
                    break :blk false;
                };
                try self.setState(name, result);
                const updated = self.findDevice(name).?;
                updated.auto_off_at = if (std.mem.eql(u8, result, "on")) if (updated.timer) |timer| self.now() + timer else null else null;
                return;
            } else if (owned_url) |u| _ = self.deviceGet(alloc, u) catch |err| {
                std.debug.print("phobos: warning: power device '{s}' http request failed: {}\n", .{ name, err });
                try self.recordError(name, err);
                break :blk false;
            };
            break :blk true;
        };
        try self.setState(name, if (!ok) "error" else if (on) "on" else "off");
        if (!ok) return error.DeviceRequestFailed;
        const updated = self.findDevice(name).?;
        updated.auto_off_at = if (on) if (updated.timer) |timer| self.now() + timer else null else null;
    }

    fn recordError(self: *PowerCtx, name: []const u8, err: anyerror) !void {
        const dev = self.findDevice(name) orelse return error.NotFound;
        const message = try self.gpa.dupe(u8, @errorName(err));
        if (dev.request_error) |old| self.gpa.free(old);
        dev.request_error = message;
    }

    fn genericRequest(self: *PowerCtx, alloc: std.mem.Allocator, name: []const u8, command: []const u8) ![]const u8 {
        const dev = self.findDevice(name) orelse return error.NotFound;
        const url = try alloc.dupe(u8, if (std.mem.eql(u8, command, "status")) dev.status_url orelse return error.InvalidParams else if (std.mem.eql(u8, command, "on")) dev.on_url orelse return error.InvalidParams else dev.off_url orelse return error.InvalidParams);
        var request_storage: [max_request_template_bytes]u8 = undefined;
        var request_alloc = std.heap.FixedBufferAllocator.init(&request_storage);
        var request = GenericRequest{ .ctx = self, .alloc = request_alloc.allocator(), .url = url, .default_url = url };
        var vars: std.json.ObjectMap = .empty;
        var marker: std.json.ObjectMap = .empty;
        try marker.put(alloc, "__native", .{ .string = "http_request" });
        try vars.put(alloc, "http_request", .{ .object = marker });
        try vars.put(alloc, "command", .{ .string = command });
        var urls: std.json.ObjectMap = .empty;
        try urls.put(alloc, "on", .{ .string = try alloc.dupe(u8, dev.on_url orelse "") });
        try urls.put(alloc, "off", .{ .string = try alloc.dupe(u8, dev.off_url orelse "") });
        try urls.put(alloc, "status", .{ .string = try alloc.dupe(u8, dev.status_url orelse "") });
        try vars.put(alloc, "urls", .{ .object = urls });
        const response_source = try alloc.dupe(u8, dev.response_template orelse return error.InvalidParams);
        if (dev.request_template) |source| {
            var template = try templates.Template.init(alloc, source);
            defer template.deinit();
            _ = template.renderText(alloc, vars, .{ .ctx = &request, .call = GenericRequest.call }) catch |err| return request.failure orelse err;
            if (!request.sent) return error.NoHttpResponse;
        } else try request.send();
        var template = try templates.Template.init(alloc, response_source);
        defer template.deinit();
        const response = try template.renderText(alloc, vars, .{ .ctx = &request, .call = GenericRequest.call });
        if (std.ascii.eqlIgnoreCase(response, "on")) return "on";
        if (std.ascii.eqlIgnoreCase(response, "off")) return "off";
        return error.InvalidTemplateResult;
    }

    /// Get a device by name (borrowed pointer into the map).
    pub fn findDevice(self: *PowerCtx, name: []const u8) ?*Device {
        return self.devices.getPtr(name);
    }

    /// Update a device's state in-place.
    pub fn setState(self: *PowerCtx, name: []const u8, new_state: []const u8) !void {
        const dev = self.devices.getPtr(name) orelse return error.NotFound;
        const owned = try self.gpa.dupe(u8, new_state);
        self.gpa.free(dev.state);
        dev.state = owned;
    }

    /// Reject a mutating request on a `locked_while_printing` device during a
    /// print, matching Moonraker's `process_request` lock check.
    pub fn checkPrintingLock(self: *const PowerCtx, dev: *const Device) !void {
        if (!dev.locked_while_printing) return;
        const check = self.printing_check orelse return;
        if (check(self.printing_ctx orelse return)) return error.PrinterLocked;
    }

    /// Add or replace a device, copying all configuration strings.
    pub fn addDevice(self: *PowerCtx, opts: Device) !void {
        const k = try self.gpa.dupe(u8, opts.name);
        errdefer self.gpa.free(k);
        var dev = try opts.dupe(self.gpa);
        errdefer dev.deinit(self.gpa);
        if (try self.devices.fetchPut(k, dev)) |prior| {
            self.gpa.free(k); // Replacements retain the map's existing key.
            var old = prior.value;
            old.deinit(self.gpa);
        }
    }
};

const GenericRequest = struct {
    ctx: *PowerCtx,
    alloc: std.mem.Allocator,
    url: []const u8,
    default_url: []const u8,
    method: std.http.Method = .GET,
    payload: ?[]const u8 = null,
    headers: std.ArrayList(std.http.Header) = .empty,
    body: [max_response_bytes]u8 = undefined,
    response: []const u8 = "",
    sent: bool = false,
    status: std.http.Status = .ok,
    failure: ?anyerror = null,

    fn send(self: *GenericRequest) !void {
        const io = self.ctx.io orelse return error.NotReady;
        if (self.ctx.core) |core| core.unlock(io);
        defer if (self.ctx.core) |core| core.lock(io);
        for (0..generic_request_attempts) |attempt| {
            self.response = deviceRequestHeaders(self.ctx.gpa, io, self.method, self.url, self.payload, self.headers.items, http_timeout, &self.body, &self.status) catch |err| {
                if (err == error.Canceled or attempt + 1 == generic_request_attempts) return err;
                try io.sleep(generic_retry_pause, .awake);
                continue;
            };
            self.sent = true;
            return;
        }
    }

    fn marker(self: *const GenericRequest, alloc: std.mem.Allocator) !std.json.Value {
        var object: std.json.ObjectMap = .empty;
        try object.put(alloc, "__native", .{ .string = "response" });
        try object.put(alloc, "text", .{ .string = self.response });
        try object.put(alloc, "content", .{ .string = self.response });
        try object.put(alloc, "status_code", .{ .integer = @backingInt(self.status) });
        try object.put(alloc, "url", .{ .string = self.url });
        return .{ .object = object };
    }

    fn call(raw: *anyopaque, name: []const u8, args: []const std.json.Value, kwargs: std.json.ObjectMap, alloc: std.mem.Allocator) templates.RenderError!std.json.Value {
        const self: *GenericRequest = @ptrCast(@alignCast(raw));
        if (std.mem.eql(u8, name, "async_sleep")) {
            if (args.len != 1) return error.EvalError;
            const seconds: f64 = switch (args[0]) {
                .integer => |n| @floatFromInt(n),
                .float => |n| n,
                else => return error.EvalError,
            };
            if (!std.math.isFinite(seconds) or seconds < 0 or seconds > std.time.s_per_day) return error.EvalError;
            const io = self.ctx.io orelse return error.EvalError;
            if (self.ctx.core) |core| core.unlock(io);
            defer if (self.ctx.core) |core| core.lock(io);
            io.sleep(.fromMilliseconds(@intFromFloat(seconds * std.time.ms_per_s)), .awake) catch return error.EvalError;
            return .null;
        }
        if (std.mem.eql(u8, name, "http_request.send")) {
            if (args.len != 0) return error.EvalError;
            if (kwargs.get("method")) |value| self.method = std.meta.stringToEnum(std.http.Method, if (value == .string) value.string else return error.EvalError) orelse return error.EvalError;
            if (kwargs.get("url")) |value| self.url = try self.alloc.dupe(u8, if (value == .string) value.string else return error.EvalError);
            if (kwargs.get("body")) |value| self.payload = if (value == .null) null else if (value == .string) try self.alloc.dupe(u8, value.string) else try std.json.Stringify.valueAlloc(self.alloc, value, .{});
            self.send() catch |err| {
                self.failure = err;
                return error.EvalError;
            };
            return self.marker(alloc);
        }
        if (std.mem.eql(u8, name, "http_request.last_response")) return if (self.sent) self.marker(alloc) else .null;
        if (std.mem.eql(u8, name, "response.json")) return std.json.parseFromSliceLeaky(std.json.Value, alloc, self.response, .{}) catch error.EvalError;
        if (std.mem.eql(u8, name, "response.text")) return .{ .string = self.response };
        if (std.mem.eql(u8, name, "response.raise_for_status")) return .null;
        if (std.mem.eql(u8, name, "http_request.set_method")) {
            if (args.len != 1 or args[0] != .string) return error.EvalError;
            self.method = std.meta.stringToEnum(std.http.Method, args[0].string) orelse return error.EvalError;
        } else if (std.mem.eql(u8, name, "http_request.set_url")) {
            if (args.len != 1 or args[0] != .string) return error.EvalError;
            self.url = try self.alloc.dupe(u8, args[0].string);
        } else if (std.mem.eql(u8, name, "http_request.set_body")) {
            if (args.len != 1) return error.EvalError;
            self.payload = if (args[0] == .null) null else if (args[0] == .string) try self.alloc.dupe(u8, args[0].string) else try std.json.Stringify.valueAlloc(self.alloc, args[0], .{});
        } else if (std.mem.eql(u8, name, "http_request.add_header")) {
            if (args.len != 2 or args[0] != .string or args[1] != .string) return error.EvalError;
            try self.addHeader(args[0].string, args[1].string);
        } else if (std.mem.eql(u8, name, "http_request.set_headers")) {
            if (args.len != 1 or args[0] != .object) return error.EvalError;
            self.headers.clearRetainingCapacity();
            var it = args[0].object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* != .string) return error.EvalError;
                try self.addHeader(entry.key_ptr.*, entry.value_ptr.string);
            }
        } else if (std.mem.eql(u8, name, "http_request.reset")) {
            self.method = .GET;
            self.url = self.default_url;
            self.payload = null;
            self.headers.clearRetainingCapacity();
        } else return error.EvalError;
        return .null;
    }

    fn addHeader(self: *GenericRequest, name: []const u8, value: []const u8) templates.RenderError!void {
        if (name.len == 0) return error.EvalError;
        for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null) return error.EvalError;
        for (value) |byte| if ((byte < 32 and byte != '\t') or byte == 127) return error.EvalError;
        try self.headers.append(self.alloc, .{ .name = try self.alloc.dupe(u8, name), .value = try self.alloc.dupe(u8, value) });
    }
};

fn timerWorker(ctx: *PowerCtx) void {
    const io = ctx.io orelse return;
    while (!sleep.untilStopped(io, .fromMilliseconds(50), &ctx.timer_stop)) {
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        if (ctx.core) |core| core.lock(io);
        defer if (ctx.core) |core| core.unlock(io);
        ctx.tick(clock.monotonicSeconds(io), arena.allocator()) catch |err|
            std.debug.print("phobos: warning: power timer failed: {}\n", .{err});
    }
}

fn configBool(cfg: *const Config, section: []const u8, option: []const u8, default: bool) !bool {
    return cfg.getBoolean(section, option) catch |err| if (err == error.NoOption) default else return err;
}

fn configFloat(cfg: *const Config, section: []const u8, option: []const u8, default: f64, minimum: f64) !f64 {
    const value = cfg.getFloat(section, option) catch |err| if (err == error.NoOption) default else return err;
    if (value < minimum) return error.InvalidValue;
    return value;
}

// ---------------------------------------------------------------------------
// Param helpers
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Device info shape
// ---------------------------------------------------------------------------

/// Build the per-device info object matching PowerDevice.get_device_info():
///   { device, status, locked_while_printing, type }
/// KlipperDevice also adds `is_shutdown`; we always include it (false for
/// non-klipper devices) to match the shape KlipperDevice.get_device_info
/// extends with.
pub fn buildDeviceInfo(alloc: std.mem.Allocator, dev: *const Device) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "device", .{ .string = dev.name });
    try obj.put(alloc, "status", .{ .string = dev.state });
    try obj.put(alloc, "locked_while_printing", .{ .bool = dev.locked_while_printing });
    try obj.put(alloc, "type", .{ .string = dev.type_str });
    try obj.put(alloc, "is_shutdown", .{ .bool = dev.is_shutdown });
    return .{ .object = obj };
}

// ---------------------------------------------------------------------------
// Notification
// ---------------------------------------------------------------------------

/// Emit `notify_power_changed` with the device info payload.
/// Uses emitLocked — handlers run under the held Core lock.
fn emitPowerChanged(ctx: *PowerCtx, alloc: std.mem.Allocator, dev: *const Device) void {
    const bus = ctx.bus orelse return;
    const io = ctx.io orelse return;
    const info = buildDeviceInfo(alloc, dev) catch return;
    var arr: std.json.Array = .init(alloc);
    arr.append(info) catch return;
    bus.emitLocked(io, notify.names.power_changed, .{ .array = arr }) catch {};
}

// ---------------------------------------------------------------------------
// Protocol helpers
// ---------------------------------------------------------------------------

/// on/off/status URLs for a protocol-specific HTTP power device. Strings are
/// allocated in `alloc` (caller owns all three).
pub const ProtoUrls = struct { on: []const u8, off: []const u8, status: []const u8 };

/// Tasmota HTTP command URLs (Moonraker tasmota.py): cmnd=Power<id>%20<ON|OFF|>.
/// `password` (with user "admin") is appended when set.
pub fn tasmotaUrls(alloc: std.mem.Allocator, address: []const u8, output_id: i64, password: ?[]const u8) !ProtoUrls {
    const auth = if (password != null) "&user=admin&password=" else "";
    const escaped = std.fmt.alt(std.Uri.Component{ .raw = password orelse "" }, .formatEscaped);
    const on = try std.fmt.allocPrint(alloc, "http://{s}/cm?cmnd=Power{d}%20ON{s}{f}", .{ address, output_id, auth, escaped });
    errdefer alloc.free(on);
    const off = try std.fmt.allocPrint(alloc, "http://{s}/cm?cmnd=Power{d}%20OFF{s}{f}", .{ address, output_id, auth, escaped });
    errdefer alloc.free(off);
    return .{
        .on = on,
        .off = off,
        .status = try std.fmt.allocPrint(alloc, "http://{s}/cm?cmnd=Power{d}{s}{f}", .{ address, output_id, auth, escaped }),
    };
}

/// Shelly Gen1 relay URLs (Moonraker shelly.py): /relay/<id>?turn=<on|off>.
pub fn shellyUrls(alloc: std.mem.Allocator, address: []const u8, output_id: i64) !ProtoUrls {
    const on = try std.fmt.allocPrint(alloc, "http://{s}/relay/{d}?turn=on", .{ address, output_id });
    errdefer alloc.free(on);
    const off = try std.fmt.allocPrint(alloc, "http://{s}/relay/{d}?turn=off", .{ address, output_id });
    errdefer alloc.free(off);
    return .{
        .on = on,
        .off = off,
        .status = try std.fmt.allocPrint(alloc, "http://{s}/relay/{d}", .{ address, output_id }),
    };
}

/// Parse a status reply into on (true) / off (false); null when unrecognised.
/// Shelly reads `ison` (shelly.py `_send_status_request`); Tasmota reads the
/// `POWER<id>` or `POWER` key, ON/OFF in any case (tasmota.py). Other types
/// accept a body that names exactly one of on/off.
pub fn parseStatus(alloc: std.mem.Allocator, type_str: []const u8, body: []const u8) ?bool {
    if (std.mem.eql(u8, type_str, "shelly") or std.mem.eql(u8, type_str, "tasmota")) {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{}) catch return null;
        if (parsed != .object) return null;
        if (std.mem.eql(u8, type_str, "shelly")) {
            const ison = parsed.object.get("ison") orelse return null;
            return if (ison == .bool) ison.bool else null;
        }
        var it = parsed.object.iterator();
        while (it.next()) |entry| {
            if (!std.mem.startsWith(u8, entry.key_ptr.*, "POWER") or entry.value_ptr.* != .string) continue;
            const value = entry.value_ptr.string;
            if (std.ascii.eqlIgnoreCase(value, "on")) return true;
            if (std.ascii.eqlIgnoreCase(value, "off")) return false;
        }
        return null;
    }
    const has_on = std.mem.indexOf(u8, body, "\"on\"") != null or std.mem.indexOf(u8, body, "ON") != null;
    const has_off = std.mem.indexOf(u8, body, "\"off\"") != null or std.mem.indexOf(u8, body, "OFF") != null;
    if (has_on == has_off) return null;
    return has_on;
}

// ---------------------------------------------------------------------------
// State machine
// ---------------------------------------------------------------------------

/// Apply a power request ("on" | "off" | "toggle" | "status") to a device and
/// return the resulting state (ctx-owned or a literal; caller must not free).
/// A status request with a `status_url` refreshes the state from the device; a
/// failed or unrecognised reply sets "error" (Moonraker `refresh_status`).
fn processRequest(ctx: *PowerCtx, dev: *Device, req: []const u8, alloc: std.mem.Allocator, force: bool) ![]const u8 {
    // Device HTTP releases Core, which may replace `dev`; work by name.
    const name = try alloc.dupe(u8, dev.name);
    const before = try alloc.dupe(u8, dev.state);
    if (dev.status_url != null) {
        const url = try alloc.dupe(u8, dev.status_url.?);
        const type_str = try alloc.dupe(u8, dev.type_str);
        const generic = dev.response_template != null;
        const state = if (generic and ctx.io != null) ctx.genericRequest(alloc, name, "status") catch "error" else null;
        const body = if (!generic) ctx.deviceGet(alloc, url) catch null else null;
        const after = ctx.findDevice(name) orelse return error.NotFound;
        if (ctx.io != null) {
            const on = if (body) |b| parseStatus(alloc, type_str, b) else null;
            try ctx.setState(name, state orelse if (on) |v| (if (v) "on" else "off") else "error");
        }
        _ = after;
    }
    const current = ctx.findDevice(name) orelse return error.NotFound;
    if (std.mem.eql(u8, req, "status")) {
        if (!std.mem.eql(u8, before, current.state)) try ctx.processChanged(name, alloc, !current.restrict_action_processing);
        return (ctx.findDevice(name) orelse return error.NotFound).state;
    }
    // Resolve "toggle" to the opposite of the current state.
    const action: []const u8 = blk: {
        if (!std.mem.eql(u8, req, "toggle")) break :blk req;
        break :blk if (std.mem.eql(u8, current.state, "off")) "on" else "off";
    };
    if (!std.mem.eql(u8, action, "on") and !std.mem.eql(u8, action, "off")) {
        return error.InvalidParams;
    }
    if (std.mem.eql(u8, action, current.state)) {
        if (!std.mem.eql(u8, before, current.state)) try ctx.processChanged(name, alloc, !current.restrict_action_processing);
    } else {
        if (!force) try ctx.checkPrintingLock(current);
        try ctx.setPower(alloc, name, std.mem.eql(u8, action, "on"));
        try ctx.processChanged(name, alloc, true);
    }
    return (ctx.findDevice(name) orelse return error.NotFound).state;
}

// ---------------------------------------------------------------------------
// GET /machine/device_power/devices → machine.device_power.devices
// ---------------------------------------------------------------------------

/// Returns `{ "devices": [ { device, status, locked_while_printing, type, is_shutdown }, ... ] }`.
/// Without configured devices the list is empty, matching Moonraker when no
/// `[power <name>]` sections are present.
pub fn handleDevices(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *PowerCtx = @ptrCast(@alignCast(ctx_ptr));
    var arr: std.json.Array = .init(alloc);
    var it = ctx.devices.valueIterator();
    while (it.next()) |dev| {
        try arr.append(try buildDeviceInfo(alloc, dev));
    }
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "devices", .{ .array = arr });
    return .{ .object = obj };
}

// ---------------------------------------------------------------------------
// GET /machine/device_power/device?device=  → machine.device_power.get_device
// POST /machine/device_power/device?device=&action=  → machine.device_power.post_device
// ---------------------------------------------------------------------------

/// Shared handler for GET + POST /machine/device_power/device.
/// GET → returns { "<device>": "<state>" } (status query).
/// POST → requires `action` in [on|off|toggle], returns { "<device>": "<new_state>" }.
pub fn handleSingleDevice(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *PowerCtx = @ptrCast(@alignCast(ctx_ptr));
    const dev_name = try webreq.required([]const u8, params, "device");
    _ = ctx.findDevice(dev_name) orelse {
        // Matches Moonraker: "No valid device named <x>"
        return error.NotFound;
    };
    // GET = status query; POST applies `action` (on/off/toggle). Key on the
    // transport's injected `_method`, NOT on whether `action` is present —
    // otherwise `GET ...?action=on` would power the device on (unsafe method).
    const is_post = if ((try webreq.optional([]const u8, params, "_method"))) |m| std.mem.eql(u8, m, "POST") else false;
    const action: []const u8 = if (is_post) blk: {
        const a = (try webreq.optional([]const u8, params, "action")) orelse return error.InvalidParams;
        const al = std.ascii.allocLowerString(alloc, a) catch a;
        if (!std.mem.eql(u8, al, "on") and !std.mem.eql(u8, al, "off") and !std.mem.eql(u8, al, "toggle")) {
            return error.InvalidParams;
        }
        break :blk al;
    } else "status";

    const result_state = ctx.processDevice(dev_name, action, false, alloc) catch |err| {
        if (err != error.DeviceRequestFailed) return err;
        const failed = ctx.findDevice(dev_name) orelse return error.NotFound;
        if (params.object.get(jsonrpc.method_key) == null) return err;
        const message = try std.fmt.allocPrint(alloc, "Error Setting Device Status: {s} to {s}: {s}", .{ dev_name, failed.requested_state orelse action, failed.request_error orelse "DeviceRequestFailed" });
        try jsonrpc.setErrorReply(alloc, params, .bad_request, message);
        return error.UpstreamRequestFailed;
    };
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, dev_name, .{ .string = result_state });
    return .{ .object = obj };
}

// ---------------------------------------------------------------------------
// GET  /machine/device_power/status   → batch status
// POST /machine/device_power/on       → batch on
// POST /machine/device_power/off      → batch off
// ---------------------------------------------------------------------------

/// Batch handler: each param key is a device name (values are ignored by
/// Moonraker); keys starting with `_` are transport-injected and skipped.
/// Returns `{ "<device>": "<state>" | "device_not_found" | "error" }`.
fn handleBatch(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator, action: []const u8) anyerror!std.json.Value {
    const ctx: *PowerCtx = @ptrCast(@alignCast(ctx_ptr));
    var out: std.json.ObjectMap = .empty;
    switch (params) {
        .object => |obj| {
            var it = obj.iterator();
            var device_count: usize = 0;
            while (it.next()) |entry| {
                const name = entry.key_ptr.*;
                if (std.mem.startsWith(u8, name, "_")) continue;
                device_count += 1;
                if (ctx.findDevice(name) != null) {
                    const state = ctx.processDevice(name, action, false, alloc) catch "error";
                    try out.put(alloc, name, .{ .string = try alloc.dupe(u8, state) });
                } else {
                    try out.put(alloc, name, .{ .string = "device_not_found" });
                }
            }
            // If nothing was requested (all keys were internal) it's an empty param set.
            if (device_count == 0) return error.InvalidParams;
        },
        else => return error.InvalidParams,
    }
    return .{ .object = out };
}

pub fn handleStatus(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    return handleBatch(ctx_ptr, params, alloc, "status");
}

pub fn handleOn(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    return handleBatch(ctx_ptr, params, alloc, "on");
}

pub fn handleOff(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    return handleBatch(ctx_ptr, params, alloc, "off");
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn registerPower(reg: *Registry, ctx: *PowerCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    try reg.registerEndpoint(.{ .path = "/machine/device_power/devices", .methods = &.{.GET} }, c, handleDevices);
    try reg.registerEndpoint(.{ .path = "/machine/device_power/status", .methods = &.{.GET} }, c, handleStatus);
    try reg.registerEndpoint(.{ .path = "/machine/device_power/on", .methods = &.{.POST} }, c, handleOn);
    try reg.registerEndpoint(.{ .path = "/machine/device_power/off", .methods = &.{.POST} }, c, handleOff);
    try reg.registerEndpoint(.{ .path = "/machine/device_power/device", .methods = &.{ .GET, .POST } }, c, handleSingleDevice);
    try reg.dispatcher.registerEntry("set_device_power", .{ .ctx = c, .handler = handleRemotePower, .transports = &.{.INTERNAL} });
}

pub fn handleRemotePower(raw: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *PowerCtx = @ptrCast(@alignCast(raw));
    const name = try webreq.required([]const u8, params, "device");
    const state = if (params == .object) params.object.get("state") orelse return .null else return error.InvalidParams;
    const action: []const u8 = if (state == .bool) (if (state.bool) "on" else "off") else if (state == .string) blk: {
        const lower = try std.ascii.allocLowerString(alloc, state.string);
        if (std.mem.eql(u8, lower, "true")) break :blk "on";
        if (std.mem.eql(u8, lower, "false")) break :blk "off";
        if (!std.mem.eql(u8, lower, "on") and !std.mem.eql(u8, lower, "off") and !std.mem.eql(u8, lower, "toggle")) return .null;
        break :blk lower;
    } else return .null;
    _ = try ctx.processDevice(name, action, (try webreq.optional(bool, params, "force")) orelse false, alloc);
    return .null;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "tasmotaUrls: cmnd=Power<id> on/off/status, optional auth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try tasmotaUrls(a, "1.2.3.4", 1, null);
    try testing.expectEqualStrings("http://1.2.3.4/cm?cmnd=Power1%20ON", u.on);
    try testing.expectEqualStrings("http://1.2.3.4/cm?cmnd=Power1%20OFF", u.off);
    try testing.expectEqualStrings("http://1.2.3.4/cm?cmnd=Power1", u.status);
    const ua = try tasmotaUrls(a, "host", 2, "secret");
    try testing.expectEqualStrings("http://host/cm?cmnd=Power2%20ON&user=admin&password=secret", ua.on);
}

test "tasmotaUrls escapes reserved password bytes as one query value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const urls = try tasmotaUrls(arena.allocator(), "host", 2, "a&b #+c");
    try testing.expectEqualStrings("http://host/cm?cmnd=Power2%20ON&user=admin&password=a%26b%20%23%2Bc", urls.on);
}

test "tasmotaUrls accepts passwords larger than the former intermediate buffer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const password: [256]u8 = @splat('p');
    const urls = try tasmotaUrls(arena.allocator(), "host", 2, &password);
    try testing.expect(std.mem.endsWith(u8, urls.status, &password));
}

test "power protocol URL constructors release partial allocations" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            const tasmota = try tasmotaUrls(alloc, "host", 2, "a&b");
            defer alloc.free(tasmota.on);
            defer alloc.free(tasmota.off);
            defer alloc.free(tasmota.status);
            const shelly = try shellyUrls(alloc, "host", 0);
            defer alloc.free(shelly.on);
            defer alloc.free(shelly.off);
            defer alloc.free(shelly.status);
        }
    }.run, .{});
}

test "shellyUrls: /relay/<id>?turn=on|off + status" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try shellyUrls(a, "shelly.local", 0);
    try testing.expectEqualStrings("http://shelly.local/relay/0?turn=on", u.on);
    try testing.expectEqualStrings("http://shelly.local/relay/0?turn=off", u.off);
    try testing.expectEqualStrings("http://shelly.local/relay/0", u.status);
}

test "fuzz tasmota/shellyUrls: arbitrary address never crashes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var addr: [24]u8 = undefined;
            smith.bytesWithHash(&addr, 0);
            const id = smith.valueRangeLessThanWithHash(i64, 0, 16, 1);
            _ = tasmotaUrls(a, &addr, id, null) catch {};
            _ = shellyUrls(a, &addr, id) catch {};
            const escaped = try tasmotaUrls(a, "device", id, &addr);
            const start = std.mem.find(u8, escaped.status, "password=").? + "password=".len;
            const encoded = escaped.status[start..];
            try testing.expect(std.mem.findAny(u8, encoded, "&+#? ") == null);
            const decoded = try (std.Uri.Component{ .percent_encoded = encoded }).toRawMaybeAlloc(a);
            try testing.expectEqualSlices(u8, &addr, decoded);
        }
    }.run, .{});
}

fn objParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    return p.value;
}

fn testCtx(alloc: std.mem.Allocator) PowerCtx {
    return PowerCtx.init(alloc, null);
}

fn alwaysPrinting(_: *anyopaque) bool {
    return true;
}

/// Loopback HTTP device double: accepts one connection, reads the request
/// head, optionally takes `core` (blocks while a handler holds it), then
/// writes `reply` (or nothing when null) and closes.
pub const DeviceDouble = struct {
    io: std.Io,
    server: std.Io.net.Server,
    reply: ?[]const u8,
    stall_after_reply: bool = false,
    core: ?*Core = null,
    request_line: [128]u8 = undefined,
    request_len: usize = 0,

    pub fn bind(io: std.Io, reply: ?[]const u8) !DeviceDouble {
        var ip = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        return .{ .io = io, .server = try ip.listen(io, .{ .reuse_address = true }), .reply = reply };
    }

    pub fn url(self: *const DeviceDouble, buf: []u8, path: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ self.server.socket.address.getPort(), path });
    }

    pub fn serveOne(self: *DeviceDouble) void {
        const stream = self.server.accept(self.io) catch return;
        defer stream.close(self.io);
        var rbuf: [1024]u8 = undefined;
        var r = stream.reader(self.io, &rbuf);
        const first = r.interface.takeDelimiterInclusive('\n') catch return;
        self.request_len = @min(first.len, self.request_line.len);
        @memcpy(self.request_line[0..self.request_len], first[0..self.request_len]);
        while (r.interface.takeDelimiterInclusive('\n')) |line| {
            if (line.len <= 2) break;
        } else |_| return;
        if (self.core) |core| core.run(self.io, struct {
            fn noop() void {}
        }.noop, .{});
        const reply = self.reply orelse {
            // Hold the connection open until the client gives up.
            _ = r.interface.takeDelimiterInclusive('\n') catch {};
            return;
        };
        var wbuf: [256]u8 = undefined;
        var w = stream.writer(self.io, &wbuf);
        w.interface.writeAll(reply) catch return;
        w.interface.flush() catch return;
        if (self.stall_after_reply) _ = r.interface.takeDelimiterInclusive('\n') catch {};
    }
};

test "deviceRequest: 2xx body, non-2xx and an expired deadline" {
    const io = testing.io;
    var body: [64]u8 = undefined;
    var url_buf: [64]u8 = undefined;
    {
        var device = try DeviceDouble.bind(io, "HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: close\r\n\r\n{\"ison\":true}");
        defer device.server.deinit(io);
        var serving = try io.concurrent(DeviceDouble.serveOne, .{&device});
        defer serving.cancel(io);
        const reply = try deviceRequest(testing.allocator, io, .GET, try device.url(&url_buf, "/relay/0"), null, .fromSeconds(5), &body);
        try testing.expectEqualStrings("{\"ison\":true}", reply);
    }
    {
        var device = try DeviceDouble.bind(io, "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        defer device.server.deinit(io);
        var serving = try io.concurrent(DeviceDouble.serveOne, .{&device});
        defer serving.cancel(io);
        try testing.expectError(error.HttpStatus, deviceRequest(testing.allocator, io, .GET, try device.url(&url_buf, "/"), null, .fromSeconds(5), &body));
    }
    {
        var device = try DeviceDouble.bind(io, null);
        defer device.server.deinit(io);
        var serving = try io.concurrent(DeviceDouble.serveOne, .{&device});
        defer serving.cancel(io);
        try testing.expectError(error.Timeout, deviceRequest(testing.allocator, io, .GET, try device.url(&url_buf, "/"), null, .fromMilliseconds(100), &body));
    }
}

test "deviceRequest cancels a partial Content-Length body without panicking" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();
    var device = try DeviceDouble.bind(aio, "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nx");
    defer device.server.deinit(aio);
    device.stall_after_reply = true;
    var serving = try aio.concurrent(DeviceDouble.serveOne, .{&device});
    defer serving.cancel(aio);
    var url: [96]u8 = undefined;
    var body: [16]u8 = undefined;
    const start = std.Io.Clock.Timestamp.now(aio, .awake);
    try testing.expectError(error.Timeout, deviceRequest(std.heap.smp_allocator, aio, .GET, try device.url(&url, "/"), null, .fromMilliseconds(20), &body));
    try testing.expect(start.untilNow(aio).raw.toMilliseconds() < 5000);
}

test "fuzz deviceRequest: malformed URLs fail without a request" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var raw: [24]u8 = undefined;
            smith.bytesWithHash(&raw, 0);
            // A scheme-less URL never reaches the network.
            for (&raw) |*byte| if (byte.* == ':') {
                byte.* = '_';
            };
            var body: [16]u8 = undefined;
            if (deviceRequest(testing.allocator, testing.io, .GET, &raw, null, .fromMilliseconds(100), &body)) |_| {
                return error.TestUnexpectedResult;
            } else |_| {}
        }
    }.run, .{});
}

test "handleSingleDevice: releases Core for device HTTP" {
    const io = testing.io;
    var core = Core.init();
    var device = try DeviceDouble.bind(io, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}");
    defer device.server.deinit(io);
    // The double takes Core before replying: it would block until the
    // request timed out if the handler kept Core during the round trip.
    device.core = &core;
    var serving = try io.concurrent(DeviceDouble.serveOne, .{&device});
    defer serving.cancel(io);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(testing.allocator);
    defer ctx.deinit();
    ctx.setIo(io);
    ctx.core = &core;
    var url_buf: [64]u8 = undefined;
    try ctx.addDevice(.{ .name = "psu", .type_str = "http", .state = "off", .on_url = try device.url(&url_buf, "/on") });
    const params = try objParams(a, "{\"device\":\"psu\",\"action\":\"on\",\"_method\":\"POST\"}");
    const v = try core.run(io, handleSingleDevice, .{ @as(*anyopaque, @ptrCast(&ctx)), params, a });
    try testing.expectEqualStrings("on", v.object.get("psu").?.string);
    try testing.expectEqualStrings("GET /on HTTP/1.1\r\n", device.request_line[0..device.request_len]);
}

test "handleSingleDevice: a failed device request sets error and fails" {
    const io = testing.io;
    var device = try DeviceDouble.bind(io, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    defer device.server.deinit(io);
    var serving = try io.concurrent(DeviceDouble.serveOne, .{&device});
    defer serving.cancel(io);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(testing.allocator);
    defer ctx.deinit();
    ctx.setIo(io);
    var url_buf: [64]u8 = undefined;
    try ctx.addDevice(.{ .name = "psu", .type_str = "http", .state = "off", .on_url = try device.url(&url_buf, "/on") });
    const params = try objParams(a, "{\"device\":\"psu\",\"action\":\"toggle\",\"_method\":\"POST\"}");
    try testing.expectError(error.UpstreamRequestFailed, handleSingleDevice(@ptrCast(&ctx), params, a));
    const reply = try jsonrpc.errorReply(error.UpstreamRequestFailed, params, a);
    try testing.expectEqualStrings("Error Setting Device Status: psu to on: HttpStatus", reply.message);
    try testing.expectEqualStrings("error", ctx.findDevice("psu").?.state);
}

test "handleSingleDevice: shelly status reads ison" {
    const io = testing.io;
    var device = try DeviceDouble.bind(io, "HTTP/1.1 200 OK\r\nContent-Length: 47\r\nConnection: close\r\n\r\n{\"ison\":true,\"has_timer\":false,\"source\":\"http\"}");
    defer device.server.deinit(io);
    var serving = try io.concurrent(DeviceDouble.serveOne, .{&device});
    defer serving.cancel(io);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(testing.allocator);
    defer ctx.deinit();
    ctx.setIo(io);
    var url_buf: [64]u8 = undefined;
    try ctx.addDevice(.{ .name = "relay", .type_str = "shelly", .state = "off", .status_url = try device.url(&url_buf, "/relay/0") });
    const v = try handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"relay\"}"), a);
    try testing.expectEqualStrings("on", v.object.get("relay").?.string);
}

test "parseStatus: shelly ison, tasmota POWER keys, generic on/off" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(?bool, true), parseStatus(a, "shelly", "{\"ison\":true,\"timer_remaining\":0}"));
    try testing.expectEqual(@as(?bool, false), parseStatus(a, "shelly", "{\"ison\":false}"));
    try testing.expectEqual(@as(?bool, null), parseStatus(a, "shelly", "{\"ison\":\"on\"}"));
    try testing.expectEqual(@as(?bool, true), parseStatus(a, "tasmota", "{\"POWER2\":\"ON\"}"));
    try testing.expectEqual(@as(?bool, false), parseStatus(a, "tasmota", "{\"POWER\":\"off\"}"));
    try testing.expectEqual(@as(?bool, null), parseStatus(a, "tasmota", "{\"Power\":\"ON\"}"));
    try testing.expectEqual(@as(?bool, null), parseStatus(a, "tasmota", "not json"));
    try testing.expectEqual(@as(?bool, true), parseStatus(a, "http", "{\"state\":\"on\"}"));
    try testing.expectEqual(@as(?bool, null), parseStatus(a, "http", "{\"on\":\"off\"}"));
}

test "fuzz parseStatus: arbitrary bodies never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var body: [32]u8 = undefined;
            smith.bytesWithHash(&body, 0);
            const types = [_][]const u8{ "shelly", "tasmota", "http" };
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            _ = parseStatus(arena.allocator(), types[smith.valueRangeLessThanWithHash(u8, 0, types.len, 1)], &body);
        }
    }.run, .{});
}

test "handleOn: an empty device name is reported, not indexed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    const v = try handleOn(@ptrCast(&ctx), try objParams(a, "{\"\":null}"), a);
    try testing.expectEqualStrings("device_not_found", v.object.get("").?.string);
}

// ---- handleDevices ----

test "handleDevices: empty list when no devices configured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    const v = try handleDevices(@ptrCast(&ctx), .null, a);
    const arr = v.object.get("devices").?.array;
    try testing.expectEqual(@as(usize, 0), arr.items.len);
}

test "handleDevices: returns device info shape for configured device" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addDevice(.{ .name = "printer_psu", .type_str = "gpio", .state = "off", .locked_while_printing = false });
    const v = try handleDevices(@ptrCast(&ctx), .null, a);
    const arr = v.object.get("devices").?.array;
    try testing.expectEqual(@as(usize, 1), arr.items.len);
    const d = arr.items[0].object;
    try testing.expectEqualStrings("printer_psu", d.get("device").?.string);
    try testing.expectEqualStrings("off", d.get("status").?.string);
    try testing.expectEqualStrings("gpio", d.get("type").?.string);
    try testing.expectEqual(false, d.get("locked_while_printing").?.bool);
    try testing.expectEqual(false, d.get("is_shutdown").?.bool);
}

// ---- handleSingleDevice (GET semantics) ----

test "handleSingleDevice: GET device=unknown returns NotFound" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try testing.expectError(error.NotFound, handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"ghost\"}"), a));
}

test "handleSingleDevice: GET returns current status" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addDevice(.{ .name = "psu", .type_str = "gpio", .state = "off", .locked_while_printing = false });
    const v = try handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"psu\"}"), a);
    try testing.expectEqualStrings("off", v.object.get("psu").?.string);
}

// ---- handleSingleDevice (POST semantics — action param) ----

test "handleSingleDevice: POST action=on changes state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addDevice(.{ .name = "psu", .type_str = "gpio", .state = "off", .locked_while_printing = false });
    const v = try handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"psu\",\"action\":\"on\",\"_method\":\"POST\"}"), a);
    try testing.expectEqualStrings("on", v.object.get("psu").?.string);
    // State persisted.
    try testing.expectEqualStrings("on", ctx.findDevice("psu").?.state);
}

test "handleSingleDevice: POST action=toggle flips state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addDevice(.{ .name = "psu", .type_str = "gpio", .state = "off", .locked_while_printing = false });
    const v1 = try handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"psu\",\"action\":\"toggle\",\"_method\":\"POST\"}"), a);
    try testing.expectEqualStrings("on", v1.object.get("psu").?.string);
    const v2 = try handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"psu\",\"action\":\"toggle\",\"_method\":\"POST\"}"), a);
    try testing.expectEqualStrings("off", v2.object.get("psu").?.string);
}

test "handleSingleDevice: POST action=invalid returns InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addDevice(.{ .name = "psu", .type_str = "gpio", .state = "off", .locked_while_printing = false });
    try testing.expectError(error.InvalidParams, handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"psu\",\"action\":\"banana\",\"_method\":\"POST\"}"), a));
}

test "handleSingleDevice: locked_while_printing blocks mutating actions while printing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addDevice(.{ .name = "psu", .type_str = "gpio", .state = "off", .locked_while_printing = true }); // locked_while_printing=true
    ctx.printing_check = alwaysPrinting;
    ctx.printing_ctx = &ctx;

    try testing.expectError(error.PrinterLocked, handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"psu\",\"action\":\"on\",\"_method\":\"POST\"}"), a));
    const unchanged = try handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"psu\",\"action\":\"off\",\"_method\":\"POST\"}"), a);
    try testing.expectEqualStrings("off", unchanged.object.get("psu").?.string);
    try testing.expectError(error.PrinterLocked, handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"psu\",\"action\":\"toggle\",\"_method\":\"POST\"}"), a));
    // status is allowed even when locked (read-only).
    const v = try handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"psu\"}"), a);
    try testing.expectEqualStrings("off", v.object.get("psu").?.string);
    // Device state unchanged.
    try testing.expectEqualStrings("off", ctx.findDevice("psu").?.state);
}

test "handleSingleDevice: locked_while_printing allows operations when not printing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addDevice(.{ .name = "psu", .type_str = "gpio", .state = "off", .locked_while_printing = true }); // locked_while_printing=true
    // printing_active defaults to false — lock not enforced.
    const v = try handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"psu\",\"action\":\"on\",\"_method\":\"POST\"}"), a);
    try testing.expectEqualStrings("on", v.object.get("psu").?.string);
}

test "handleSingleDevice: unlocked device unaffected by printing_active" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addDevice(.{ .name = "fan", .type_str = "gpio", .state = "off", .locked_while_printing = false }); // locked_while_printing=false
    ctx.printing_check = alwaysPrinting;
    ctx.printing_ctx = &ctx;
    const v = try handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"fan\",\"action\":\"on\",\"_method\":\"POST\"}"), a);
    try testing.expectEqualStrings("on", v.object.get("fan").?.string);
}

// ---- batch handlers ----

test "handleOn: turns on named device" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addDevice(.{ .name = "psu", .type_str = "gpio", .state = "off", .locked_while_printing = false });
    const v = try handleOn(@ptrCast(&ctx), try objParams(a, "{\"psu\":null}"), a);
    try testing.expectEqualStrings("on", v.object.get("psu").?.string);
}

test "power batch results own state before another device releases Core" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(testing.allocator);
    defer ctx.deinit();
    try ctx.addDevice(.{ .name = "psu", .type_str = "gpio", .state = "off", .locked_while_printing = false });
    const value = try handleStatus(@ptrCast(&ctx), try objParams(a, "{\"psu\":null}"), a);
    const state = value.object.get("psu").?.string;
    try testing.expect(state.ptr != ctx.findDevice("psu").?.state.ptr);
    try ctx.setState("psu", "on");
    try testing.expectEqualStrings("off", state);
}

test "handleOff: turns off named device" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addDevice(.{ .name = "psu", .type_str = "gpio", .state = "on", .locked_while_printing = false });
    const v = try handleOff(@ptrCast(&ctx), try objParams(a, "{\"psu\":null}"), a);
    try testing.expectEqualStrings("off", v.object.get("psu").?.string);
}

test "handleStatus: unknown device → device_not_found" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    const v = try handleStatus(@ptrCast(&ctx), try objParams(a, "{\"ghost\":null}"), a);
    try testing.expectEqualStrings("device_not_found", v.object.get("ghost").?.string);
}

test "batch handlers: empty params returns InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try testing.expectError(error.InvalidParams, handleOn(@ptrCast(&ctx), .null, a));
    try testing.expectError(error.InvalidParams, handleOn(@ptrCast(&ctx), try objParams(a, "{}"), a));
}

test "batch handlers: locked_while_printing blocks on/off but not status" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addDevice(.{ .name = "psu", .type_str = "gpio", .state = "off", .locked_while_printing = true }); // locked_while_printing=true
    ctx.printing_check = alwaysPrinting;
    ctx.printing_ctx = &ctx;

    // Batch handlers catch errors from processRequest and return "error".
    const v_on = try handleOn(@ptrCast(&ctx), try objParams(a, "{\"psu\":null}"), a);
    try testing.expectEqualStrings("error", v_on.object.get("psu").?.string);
    const v_off = try handleOff(@ptrCast(&ctx), try objParams(a, "{\"psu\":null}"), a);
    try testing.expectEqualStrings("off", v_off.object.get("psu").?.string);
    // Status is still allowed.
    const v = try handleStatus(@ptrCast(&ctx), try objParams(a, "{\"psu\":null}"), a);
    try testing.expectEqualStrings("off", v.object.get("psu").?.string);
}

// ---- buildDeviceInfo ----

test "buildDeviceInfo: full key set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dev: Device = .{ .name = "test", .type_str = "gpio", .state = "on", .locked_while_printing = true, .is_shutdown = false };
    const v = try buildDeviceInfo(a, &dev);
    const o = v.object;
    try testing.expectEqualStrings("test", o.get("device").?.string);
    try testing.expectEqualStrings("on", o.get("status").?.string);
    try testing.expectEqualStrings("gpio", o.get("type").?.string);
    try testing.expectEqual(true, o.get("locked_while_printing").?.bool);
    try testing.expectEqual(false, o.get("is_shutdown").?.bool);
}

// ---- fuzz ----

test "fuzz_single_device: arbitrary params never crash handleSingleDevice" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [32]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = PowerCtx.init(a, null);
            defer ctx.deinit();
            ctx.addDevice(.{ .name = "psu", .type_str = "gpio", .state = "off", .locked_while_printing = false }) catch {};

            const alphabet = "abcdefghijklmnopqrstuvwxyz_";
            var name_buf: [16]u8 = undefined;
            for (buf[0..@min(16, buf.len)], 0..) |b, i| {
                name_buf[i] = alphabet[b % alphabet.len];
            }
            const name = name_buf[0..@min(8, buf[0] % 16 + 1)];
            const actions = [_][]const u8{ "on", "off", "toggle", "status", "banana", "" };
            const action = actions[buf[1] % actions.len];
            const params_str = try std.fmt.allocPrint(a, "{{\"device\":\"{s}\",\"action\":\"{s}\"}}", .{ name, action });
            const pv = try std.json.parseFromSlice(std.json.Value, a, params_str, .{});
            _ = handleSingleDevice(@ptrCast(&ctx), pv.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz_batch: arbitrary batch params never crash handleOn/Off/Status" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [16]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = PowerCtx.init(a, null);
            defer ctx.deinit();
            ctx.addDevice(.{ .name = "psu", .type_str = "gpio", .state = "off", .locked_while_printing = false }) catch {};
            ctx.addDevice(.{ .name = "fan", .type_str = "gpio", .state = "on", .locked_while_printing = true }) catch {};

            // Alternate between known and unknown device names.
            const names = [_][]const u8{ "psu", "fan", "unknown", "" };
            const nm = names[buf[0] % names.len];
            const params_str = try std.fmt.allocPrint(a, "{{\"{s}\":null}}", .{nm});
            const pv = std.json.parseFromSlice(std.json.Value, a, params_str, .{}) catch return;
            _ = handleOn(@ptrCast(&ctx), pv.value, a) catch {};
            _ = handleOff(@ptrCast(&ctx), pv.value, a) catch {};
            const snapshot = handleStatus(@ptrCast(&ctx), pv.value, a) catch return;
            if (ctx.findDevice(nm)) |device| {
                const state = snapshot.object.get(nm).?.string;
                try testing.expect(state.ptr != device.state.ptr);
                const saved = try a.dupe(u8, state);
                try ctx.setState(nm, "changed");
                try testing.expectEqualStrings(saved, state);
            }
        }
    }.run, .{});
}

test "fuzz_handleDevices: arbitrary params never crash" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [16]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = PowerCtx.init(a, null);
            defer ctx.deinit();
            ctx.addDevice(.{ .name = "psu", .type_str = "gpio", .state = "off", .locked_while_printing = false }) catch {};
            ctx.addDevice(.{ .name = "fan", .type_str = "gpio", .state = "on", .locked_while_printing = true }) catch {};
            _ = handleDevices(@ptrCast(&ctx), .null, a) catch {};
        }
    }.run, .{});
}

test "registerPower: wires expected routes and JSON-RPC methods" {
    var d = jsonrpc.Dispatcher.init(testing.allocator);
    defer d.deinit();
    var reg = Registry.init(testing.allocator, &d);
    defer reg.deinit();

    var ctx = testCtx(testing.allocator);
    defer ctx.deinit();
    try registerPower(&reg, &ctx);

    // GET routes
    try testing.expect(reg.lookup(.GET, "/machine/device_power/devices") != null);
    try testing.expect(reg.lookup(.GET, "/machine/device_power/status") != null);
    try testing.expect(reg.lookup(.GET, "/machine/device_power/device") != null);
    // POST routes
    try testing.expect(reg.lookup(.POST, "/machine/device_power/on") != null);
    try testing.expect(reg.lookup(.POST, "/machine/device_power/off") != null);
    try testing.expect(reg.lookup(.POST, "/machine/device_power/device") != null);
}

// ---- addDevice + new device fields ----

test "addDevice: accepts full Device opts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.addDevice(.{
        .name = "printer",
        .type_str = "gpio",
        .state = "off",
        .locked_while_printing = true,
        .initial_state = "on",
    });

    const dev = ctx.findDevice("printer").?;
    try testing.expectEqual(true, dev.locked_while_printing);
    try testing.expectEqualStrings("on", dev.initial_state.?);
}

test "applyInitialStates: drives configured devices to their initial_state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.addDevice(.{ .name = "lamp", .type_str = "gpio", .state = "off", .locked_while_printing = false, .is_shutdown = false, .initial_state = "on" });
    try ctx.addDevice(.{ .name = "fan", .type_str = "gpio", .state = "on", .locked_while_printing = false, .is_shutdown = false, .initial_state = "off" });
    try ctx.addDevice(.{ .name = "keep", .type_str = "gpio", .state = "off", .locked_while_printing = false, .is_shutdown = false }); // no initial_state

    ctx.applyInitialStates();
    try testing.expectEqualStrings("on", ctx.findDevice("lamp").?.state);
    try testing.expectEqualStrings("off", ctx.findDevice("fan").?.state);
    try testing.expectEqualStrings("off", ctx.findDevice("keep").?.state); // untouched
}

test "addDevice: optional fields default to null/false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.addDevice(.{
        .name = "simple",
        .type_str = "gpio",
        .state = "off",
        .locked_while_printing = false,
        .is_shutdown = false,
    });

    const dev = ctx.findDevice("simple").?;
    try testing.expectEqual(false, dev.is_shutdown);
    try testing.expectEqual(null, dev.gpio_pin);
    try testing.expectEqual(null, dev.initial_state);
    try testing.expectEqual(null, dev.on_url);
    try testing.expectEqual(null, dev.off_url);
    try testing.expectEqual(null, dev.status_url);
}

test "addDevice: http device with URLs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.addDevice(.{
        .name = "wled",
        .type_str = "http",
        .state = "off",
        .locked_while_printing = false,
        .is_shutdown = false,
        .on_url = "http://10.0.0.1/on",
        .off_url = "http://10.0.0.1/off",
        .status_url = "http://10.0.0.1/status",
    });

    const dev = ctx.findDevice("wled").?;
    try testing.expectEqualStrings("http", dev.type_str);
    try testing.expectEqualStrings("http://10.0.0.1/on", dev.on_url.?);
    try testing.expectEqualStrings("http://10.0.0.1/off", dev.off_url.?);
    try testing.expectEqualStrings("http://10.0.0.1/status", dev.status_url.?);
}

// --- Fuzz tests for internal functions ---

test "fuzz buildDeviceInfo: never panics, returns expected shape" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const dev: Device = .{
                .name = "test_dev",
                .type_str = if (buf[0] % 3 == 0) "gpio" else if (buf[0] % 3 == 1) "tasmota" else "klipper_device",
                .state = if (buf[1] % 2 == 0) "on" else "off",
                .locked_while_printing = buf[2] % 2 == 0,
                .is_shutdown = buf[3] % 2 == 0,
            };

            const info = try buildDeviceInfo(a, &dev);
            try testing.expect(info.object.get("device") != null);
            try testing.expect(info.object.get("status") != null);
            try testing.expect(info.object.get("locked_while_printing") != null);
            try testing.expect(info.object.get("type") != null);
            try testing.expect(info.object.get("is_shutdown") != null);
        }
    }.run, .{});
}

test "fuzz processRequest: never panics, handles all action states" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = PowerCtx.init(a, null);
            defer ctx.deinit();

            const name = try std.fmt.allocPrint(a, "d_{d}", .{buf[0] % 16});
            ctx.addDevice(.{ .name = name, .type_str = "gpio", .state = if (buf[1] % 2 == 0) "on" else "off", .locked_while_printing = false }) catch return;

            const dev = ctx.findDevice(name) orelse return;
            const actions = [_][]const u8{ "on", "off", "toggle", "status", "invalid" };
            const action = actions[buf[2] % actions.len];
            const force = buf[3] % 2 == 0;

            const result = processRequest(&ctx, dev, action, a, force);
            _ = result catch {};
        }
    }.run, .{});
}

test "fuzz addDevice/findDevice: round-trip, handles duplicates" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [32]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = PowerCtx.init(a, null);
            defer ctx.deinit();

            const alphabet = "abcdefghijklmnopqrstuvwxyz_-";
            var name_buf: [12]u8 = undefined;
            for (buf[0..@min(8, buf.len)], 0..) |b, i| {
                name_buf[i] = alphabet[b % alphabet.len];
            }
            const name = name_buf[0..@min(6, @max(1, buf[0] % 8))];

            const types = [_][]const u8{ "gpio", "tasmota", "shelly", "mqtt", "http" };
            const t = types[buf[1] % types.len];
            const state = if (buf[2] % 2 == 0) "on" else "off";

            // Adding same name twice is an error
            ctx.addDevice(.{ .name = name, .type_str = t, .state = state, .locked_while_printing = buf[3] % 2 == 0 }) catch {};

            // Should be findable
            const found = ctx.findDevice(name);
            if (found) |d| {
                try testing.expectEqualStrings(t, d.type_str);
            }
        }
    }.run, .{});
}

test "fuzz checkPrintingLock: correct gating behaviour" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const val = smith.valueWithHash(bool, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = PowerCtx.init(a, null);
            defer ctx.deinit();

            const dev: Device = .{
                .name = "x",
                .type_str = "gpio",
                .state = "on",
                .locked_while_printing = val,
                .is_shutdown = false,
            };

            // No printing = always allowed
            ctx.printing_check = null;
            try ctx.checkPrintingLock(&dev);

            // Printing active, only locked if locked_while_printing
            ctx.printing_check = alwaysPrinting;
            ctx.printing_ctx = &ctx;
            const result = ctx.checkPrintingLock(&dev);
            if (val) {
                try testing.expectError(error.PrinterLocked, result);
            } else {
                try result;
            }
        }
    }.run, .{});
}

test "fuzz setState: never panics, updates correctly" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = PowerCtx.init(a, null);
            defer ctx.deinit();

            ctx.addDevice(.{ .name = "d", .type_str = "gpio", .state = "off", .locked_while_printing = false }) catch return;
            const new_state = if (buf[0] % 2 == 0) "on" else "off";
            ctx.setState("d", new_state) catch return;
            try testing.expectEqualStrings(new_state, ctx.findDevice("d").?.state);

            // Unknown device errors
            try testing.expectError(error.NotFound, ctx.setState("ghost", "on"));
        }
    }.run, .{});
}

// --- GPIO hardware wiring ---

test "driveGpio: drives sysfs line on/off, honouring active_low" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "gpio23");
    try tmp.dir.writeFile(io, .{ .sub_path = "gpio23/direction", .data = "in" });
    try tmp.dir.writeFile(io, .{ .sub_path = "gpio23/value", .data = "0" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);

    const readVal = struct {
        fn f(i: std.Io, d: std.Io.Dir) ![]const u8 {
            const fh = try d.openFile(i, "gpio23/value", .{});
            defer fh.close(i);
            var buf: [8]u8 = undefined;
            var r = fh.reader(i, &.{});
            const n = try r.interface.readSliceShort(&buf);
            return std.testing.allocator.dupe(u8, buf[0..n]);
        }
    }.f;

    var ctx = PowerCtx.init(testing.allocator, null);
    defer ctx.deinit();
    ctx.setIo(io);
    ctx.gpio_root = root;

    // Active-high gpio device: on → 1, off → 0.
    try ctx.addDevice(.{ .name = "psu", .type_str = "gpio", .state = "off", .locked_while_printing = false, .is_shutdown = false, .gpio_pin = 23 });
    const dev = ctx.findDevice("psu").?;

    try ctx.driveGpio(dev, true);
    {
        const v = try readVal(io, tmp.dir);
        defer testing.allocator.free(v);
        try testing.expectEqualStrings("1", v);
    }
    try ctx.driveGpio(dev, false);
    {
        const v = try readVal(io, tmp.dir);
        defer testing.allocator.free(v);
        try testing.expectEqualStrings("0", v);
    }

    // Active-low: on → physical 0.
    dev.gpio_active_low = true;
    try ctx.driveGpio(dev, true);
    {
        const v = try readVal(io, tmp.dir);
        defer testing.allocator.free(v);
        try testing.expectEqualStrings("0", v);
    }
}

test "driveGpio: writes nothing without io or without a pin" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var ctx = PowerCtx.init(testing.allocator, null);
    defer ctx.deinit();
    ctx.gpio_root = root;
    try ctx.addDevice(.{ .name = "pinned", .type_str = "gpio", .state = "off", .gpio_pin = 5 });
    try ctx.addDevice(.{ .name = "bare", .type_str = "gpio", .state = "off" });
    try ctx.driveGpio(ctx.findDevice("pinned").?, true); // io not wired
    ctx.setIo(io);
    try ctx.driveGpio(ctx.findDevice("bare").?, true); // no pin
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "export", .{}));
}

test "power devices preserve ownership on replacement and allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(alloc: std.mem.Allocator) !void {
            var ctx = PowerCtx.init(alloc, null);
            defer ctx.deinit();
            const device: Device = .{
                .name = "test",
                .type_str = "mock",
                .state = "off",
                .locked_while_printing = false,
                .is_shutdown = false,
                .initial_state = "off",
                .on_url = "on",
                .off_url = "off",
                .status_url = "status",
            };
            try ctx.addDevice(device);
            try ctx.addDevice(ctx.findDevice("test").?.*);
            try ctx.setState("test", ctx.findDevice("test").?.state);
            try std.testing.expectEqualStrings("off", ctx.findDevice("test").?.state);
        }
    }.check, .{});
}

test "power schedules queue, shutdown, services, firmware restart and automatic off" {
    const Actions = struct {
        starts: usize = 0,
        stops: usize = 0,
        restarts: usize = 0,
        fn service(raw: *anyopaque, _: std.mem.Allocator, action: []const u8, name: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try testing.expectEqualStrings("klipper", name);
            if (std.mem.eql(u8, action, "start")) self.starts += 1 else self.stops += 1;
        }
        fn restart(raw: *anyopaque, _: std.mem.Allocator) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.restarts += 1;
        }
    };
    var actions: Actions = .{};
    var ctx = PowerCtx.init(testing.allocator, null);
    defer ctx.deinit();
    ctx.action_ctx = &actions;
    ctx.service_action = Actions.service;
    ctx.firmware_restart = Actions.restart;
    try ctx.addDevice(.{ .name = "psu", .type_str = "gpio", .state = "off", .on_when_job_queued = true, .off_when_shutdown = true, .off_when_shutdown_delay = 2, .bound_services = "klipper.service", .restart_klipper_when_powered = true, .restart_delay = 1, .timer = 10 });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    ctx.onJobQueued();
    try testing.expectEqualStrings("off", ctx.findDevice("psu").?.state);
    try ctx.tick(5, a);
    try testing.expectEqualStrings("on", ctx.findDevice("psu").?.state);
    try testing.expectEqual(@as(usize, 1), actions.starts);
    ctx.onKlippyState("error", 5);
    try ctx.tick(5.9, a);
    try testing.expectEqual(@as(usize, 0), actions.restarts);
    try ctx.tick(6, a);
    try testing.expectEqual(@as(usize, 1), actions.restarts);
    ctx.onKlippyState("shutdown", 7);
    try ctx.tick(8, a);
    try testing.expectEqualStrings("on", ctx.findDevice("psu").?.state);
    ctx.onKlippyState("ready", 8);
    try ctx.tick(9, a);
    try testing.expectEqualStrings("on", ctx.findDevice("psu").?.state);
    try ctx.tick(14.9, a);
    try testing.expectEqualStrings("on", ctx.findDevice("psu").?.state);
    try ctx.tick(15, a);
    try testing.expectEqualStrings("off", ctx.findDevice("psu").?.state);
    try testing.expectEqual(@as(usize, 1), actions.stops);
    ctx.onJobQueued();
    try ctx.tick(20, a);
    ctx.onKlippyState("shutdown", 20);
    try ctx.tick(22, a);
    try testing.expectEqualStrings("off", ctx.findDevice("psu").?.state);
    try testing.expectEqual(@as(usize, 2), actions.stops);
}

test "remote power force bypasses the printing lock only on the internal method" {
    var ctx = PowerCtx.init(testing.allocator, null);
    defer ctx.deinit();
    ctx.printing_check = alwaysPrinting;
    ctx.printing_ctx = &ctx;
    try ctx.addDevice(.{ .name = "psu", .type_str = "gpio", .state = "off", .locked_while_printing = true });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.PrinterLocked, handleSingleDevice(&ctx, try objParams(a, "{\"device\":\"psu\",\"action\":\"on\",\"force\":true,\"_method\":\"POST\"}"), a));
    _ = try handleRemotePower(&ctx, try objParams(a, "{\"device\":\"psu\",\"state\":\"TRUE\",\"force\":true}"), a);
    try testing.expectEqualStrings("on", ctx.findDevice("psu").?.state);
    var dispatcher = jsonrpc.Dispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    var reg = Registry.init(testing.allocator, &dispatcher);
    defer reg.deinit();
    try registerPower(&reg, &ctx);
    const request = try objParams(a, "{\"jsonrpc\":\"2.0\",\"method\":\"set_device_power\",\"params\":{\"device\":\"psu\",\"state\":false,\"force\":true},\"id\":1}");
    const response = try dispatcher.handleParsedRoot(.{ .transport = .WEBSOCKET }, request, a);
    try testing.expect(std.mem.indexOf(u8, response, "Method not found for transport") != null);
    try testing.expectEqualStrings("on", ctx.findDevice("psu").?.state);
}

test "generic HTTP renders request and response templates against a local device" {
    const io = testing.io;
    var device = try DeviceDouble.bind(io, "HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"power\":1}");
    defer device.server.deinit(io);
    var serving = try io.concurrent(DeviceDouble.serveOne, .{&device});
    defer serving.cancel(io);
    var ctx = PowerCtx.init(testing.allocator, null);
    defer ctx.deinit();
    ctx.setIo(io);
    var url: [96]u8 = undefined;
    try ctx.addDevice(.{ .name = "plug", .type_str = "http", .state = "off", .on_url = try device.url(&url, "/switch"), .request_template = "{% do http_request.set_method('POST') %}{% do http_request.set_body('on') %}{% do http_request.add_header('content-type', 'text/plain') %}{% do http_request.send() %}", .response_template = "{% set response = http_request.last_response().json() %}{% if response.power == 1 %}on{% else %}off{% endif %}" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("on", try ctx.processDevice("plug", "on", false, arena.allocator()));
    try testing.expectEqualStrings("POST /switch HTTP/1.1\r\n", device.request_line[0..device.request_len]);
}

test "power config validates timers and reads action options" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try cfg.parseString("[power psu]\npin: !gpio23\noff_when_shutdown: true\noff_when_shutdown_delay: 2\non_when_job_queued: true\nbound_services: klipper.service\nrestart_klipper_when_powered: true\nrestart_delay: 3\nrestrict_action_processing: false\ntimer: 5\n[power plug]\ntype: shelly\naddress: localhost\ntimer: 4\n", "test");
    var ctx = PowerCtx.init(testing.allocator, null);
    defer ctx.deinit();
    try ctx.configure(&cfg);
    const dev = ctx.findDevice("psu").?;
    try testing.expect(dev.off_when_shutdown and dev.on_when_job_queued and dev.restart_klipper_when_powered);
    try testing.expect(!dev.restrict_action_processing);
    try testing.expectEqual(@as(f64, 2), dev.off_when_shutdown_delay);
    try testing.expectEqual(@as(f64, 3), dev.restart_delay);
    try testing.expectEqual(@as(?f64, 5), dev.timer);
    const plug = ctx.findDevice("plug").?;
    try testing.expectEqual(@as(?f64, null), plug.timer);
    try testing.expectEqualStrings("http://localhost/relay/0?turn=on&timer=4", plug.off_url.?);
    var bad = Config.init(testing.allocator);
    defer bad.deinit();
    try bad.parseString("[power bad]\npin: gpio2\ntimer: -1\n", "test");
    try testing.expectError(error.InvalidValue, ctx.configure(&bad));
}

test "generic request wrapper validates headers, resets defaults and exposes response text" {
    var ctx = PowerCtx.init(testing.allocator, null);
    defer ctx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var request: GenericRequest = .{ .ctx = &ctx, .alloc = a, .url = "http://device/on", .default_url = "http://device/on" };
    _ = try GenericRequest.call(&request, "http_request.set_url", &.{.{ .string = "http://device/other" }}, .empty, a);
    _ = try GenericRequest.call(&request, "http_request.set_method", &.{.{ .string = "POST" }}, .empty, a);
    try testing.expectError(error.EvalError, request.addHeader("bad\nname", "value"));
    try testing.expectError(error.EvalError, request.addHeader("valid", "bad\r\nvalue"));
    try request.addHeader("x-device", "value");
    _ = try GenericRequest.call(&request, "http_request.reset", &.{}, .empty, a);
    try testing.expectEqualStrings("http://device/on", request.url);
    try testing.expectEqual(.GET, request.method);
    try testing.expectEqual(@as(usize, 0), request.headers.items.len);
    request.response = "on";
    request.sent = true;
    var marker: std.json.ObjectMap = .empty;
    try marker.put(a, "__native", .{ .string = "http_request" });
    var vars: std.json.ObjectMap = .empty;
    try vars.put(a, "http_request", .{ .object = marker });
    var template = try templates.Template.init(testing.allocator, "{ http_request.last_response().text }");
    defer template.deinit();
    try testing.expectEqualStrings("on", try template.renderText(a, vars, .{ .ctx = &request, .call = GenericRequest.call }));
}

test "request template method calls cannot retain more than the request memory budget" {
    var ctx = PowerCtx.init(testing.allocator, null);
    defer ctx.deinit();
    ctx.setIo(testing.io);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const target: [1024]u8 = @splat('x');
    const source = try std.fmt.allocPrint(a, "{{% for i in range(1000) %}}{{% do http_request.set_url('{s}') %}}{{% endfor %}}", .{target});
    try ctx.addDevice(.{ .name = "plug", .type_str = "http", .state = "off", .on_url = "invalid", .request_template = source, .response_template = "on" });
    try testing.expectError(error.OutOfMemory, ctx.genericRequest(a, "plug", "on"));
}

test "fuzz generic request wrapper rejects unsafe header bytes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var bytes: [64]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            var ctx = PowerCtx.init(testing.allocator, null);
            defer ctx.deinit();
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var request: GenericRequest = .{ .ctx = &ctx, .alloc = arena.allocator(), .url = "", .default_url = "" };
            const methods = [_][]const u8{ "http_request.set_url", "http_request.set_method", "http_request.set_body", "http_request.add_header", "http_request.set_headers", "http_request.reset", "http_request.last_response", "response.json", "response.text", "async_sleep" };
            const method = methods[bytes[0] % methods.len];
            _ = GenericRequest.call(&request, method, &.{ .{ .string = bytes[0..32] }, .{ .string = bytes[32..] } }, .empty, arena.allocator()) catch {};
            request.addHeader(bytes[0..32], bytes[32..]) catch return;
            try testing.expect(std.mem.indexOfAny(u8, request.headers.items[0].name, "\r\n") == null);
            try testing.expect(std.mem.indexOfAny(u8, request.headers.items[0].value, "\r\n") == null);
        }
    }.run, .{});
}

test "external status changes run services only when action processing is unrestricted" {
    const Actions = struct {
        calls: usize = 0,
        fn service(raw: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };
    const io = testing.io;
    for ([_]bool{ true, false }) |restrict| {
        var device = try DeviceDouble.bind(io, "HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: close\r\n\r\n{\"ison\":true}");
        defer device.server.deinit(io);
        var serving = try io.concurrent(DeviceDouble.serveOne, .{&device});
        defer serving.cancel(io);
        var ctx = PowerCtx.init(testing.allocator, null);
        defer ctx.deinit();
        ctx.setIo(io);
        var actions: Actions = .{};
        ctx.action_ctx = &actions;
        ctx.service_action = Actions.service;
        var url: [96]u8 = undefined;
        try ctx.addDevice(.{ .name = "plug", .type_str = "shelly", .state = "off", .status_url = try device.url(&url, "/status"), .restrict_action_processing = restrict, .bound_services = "klipper,klipper.service" });
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try testing.expectEqualStrings("on", try ctx.processDevice("plug", "status", false, arena.allocator()));
        try testing.expectEqual(@as(usize, if (restrict) 0 else 1), actions.calls);
    }
}

test "bound service validation normalizes names and rejects unavailable bindings" {
    const Validation = struct {
        calls: usize = 0,
        fn validate(raw: *anyopaque, _: std.mem.Allocator, name: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (!std.mem.eql(u8, name, "klipper")) return error.ServiceNotInstalled;
        }
    };
    var ctx = PowerCtx.init(testing.allocator, null);
    defer ctx.deinit();
    var validation: Validation = .{};
    ctx.action_ctx = &validation;
    ctx.service_validate = Validation.validate;
    try ctx.addDevice(.{ .name = "psu", .type_str = "gpio", .state = "off", .bound_services = " klipper.service,klipper" });
    try ctx.validateBoundServices(testing.allocator);
    try testing.expectEqual(@as(usize, 1), validation.calls);
    try ctx.addDevice(.{ .name = "psu", .type_str = "gpio", .state = "off", .bound_services = "unknown" });
    try testing.expectError(error.ServiceNotInstalled, ctx.validateBoundServices(testing.allocator));
}

test "fuzz power config validates numeric and template fields without leaking" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var bytes: [64]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var cfg = Config.init(testing.allocator);
            defer cfg.deinit();
            const source = try std.fmt.allocPrint(arena.allocator(), "[power test]\npin: gpio2\ntimer: {s}\nresponse_template: {s}\n", .{ bytes[0..16], bytes[16..] });
            cfg.parseString(source, "test") catch return;
            var ctx = PowerCtx.init(testing.allocator, null);
            defer ctx.deinit();
            ctx.configure(&cfg) catch {};
        }
    }.run, .{});
}

test "fuzz power timers and internal requests preserve valid states" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            const n = smith.valueRangeAtMostWithHash(u16, 0, 1000, 0);
            var ctx = PowerCtx.init(testing.allocator, null);
            defer ctx.deinit();
            try ctx.addDevice(.{ .name = "p", .type_str = "gpio", .state = "off", .on_when_job_queued = true, .off_when_shutdown = true, .timer = @as(f64, @floatFromInt(n)) + 1 });
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            ctx.onJobQueued();
            try ctx.tick(n, arena.allocator());
            ctx.onKlippyState("shutdown", n);
            try ctx.tick(@as(f64, @floatFromInt(n)) + 2, arena.allocator());
            try testing.expectEqualStrings("off", ctx.findDevice("p").?.state);
            var bytes: [32]u8 = undefined;
            smith.bytesWithHash(&bytes, 1);
            _ = handleRemotePower(&ctx, .{ .string = &bytes }, arena.allocator()) catch {};
            try ctx.addDevice(.{ .name = "bound", .type_str = "gpio", .state = "off", .bound_services = &bytes });
            const Validator = struct {
                fn validate(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !void {}
            };
            ctx.action_ctx = &ctx;
            ctx.service_validate = Validator.validate;
            try ctx.validateBoundServices(arena.allocator());
        }
    }.run, .{});
}
