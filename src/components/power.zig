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
//! send real HTTP GET requests to the configured URLs via `std.http.Client`.
//! `tasmota` and `shelly` devices derive their on/off URLs from the configured
//! address (see tasmotaUrls/shellyUrls, wired in app.setConfig) and so also issue
//! real HTTP. `type: gpio` devices with a configured `gpio_pin` drive the line
//! via the sysfs GPIO driver (`gpio_sysfs.zig`), honouring active-low. The
//! remaining vendor types (tplink_smartplug, homeseer) still track state in
//! memory only — no device-specific protocol is implemented for them.
//!
//! DEVICES FROM CONFIG. Without `[power <name>]` config sections (the spine
//! carries none), the devices map is empty and the list endpoint returns [].
//! Device-specific requests return a device-not-found error matching Moonraker's
//! `"No valid device named <x>"` message.
//!
//! NOTIFICATIONS. State changes emit `notify_power_changed` with the per-device
//! info payload via `bus.emitLocked` — handlers run under the held Core lock.

const std = @import("std");
const registry = @import("../server/registry.zig");
const notify = @import("../server/notify.zig");
const NotifyBus = @import("../server/notify.zig").NotifyBus;
const gpio_sysfs = @import("gpio_sysfs.zig");

const Registry = registry.Registry;

// ---------------------------------------------------------------------------
// Device types (matches power.py dev_types)
// ---------------------------------------------------------------------------

/// A configured power device. State is tracked in memory and, for HTTP and
/// `type: gpio` devices, mirrored to real hardware on on/off (see
/// processRequest); other vendor types are in-memory only.
pub const Device = struct {
    name: []const u8,
    type_str: []const u8,
    state: []const u8, // "on" | "off" | "init" | "error"
    locked_while_printing: bool,
    /// KlipperDevice-specific field; always false for other types.
    is_shutdown: bool,
    /// Power off device when Klippy enters shutdown state.
    off_when_shutdown: bool = false,
    /// Delay (seconds) before powering off on Klippy shutdown.
    off_when_shutdown_delay: f64 = 0.0,
    /// Power on device when a job is queued.
    on_when_queued: bool = false,
    /// Send FIRMWARE_RESTART to Klippy after power-on.
    klipper_restart: bool = false,
    /// Delay (seconds) before sending FIRMWARE_RESTART.
    restart_delay: f64 = 0.0,
    /// Systemd services bound to this device (start on power-on, stop on power-off).
    bound_services: ?[]const u8 = null,
    /// Desired initial state on startup ("on" | "off" | null).
    initial_state: ?[]const u8 = null,
    /// When set, suppresses bound-service/restart logic on external change.
    restrict_actions: bool = false,
    /// Auto-off timer: seconds before automatic power-off (0 = disabled).
    timer: f64 = 0.0,
    /// HTTP device URLs. When non-null and io is wired, real HTTP GET
    /// requests are sent. on_url / off_url are used for power state changes;
    /// status_url is used for status-refresh queries.
    on_url: ?[]const u8 = null,
    off_url: ?[]const u8 = null,
    status_url: ?[]const u8 = null,
    /// sysfs GPIO line number for `type: gpio` devices. When set and io is
    /// wired, on/off drives the line via `gpio_sysfs`.
    gpio_pin: ?u32 = null,
    /// Active-low line: "on" drives the physical level low (Moonraker "!pin").
    gpio_active_low: bool = false,

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
    /// Configured devices. Owned by the ctx; keys/values allocated with gpa.
    devices: std.StringHashMap(Device),
    /// Tracks whether the printer is currently printing. When true,
    /// power operations on devices with locked_while_printing=true are
    /// rejected with a "locked_while_printing" error matching Moonraker's
    /// `PrinterPowerLock` in power.py.
    printing_active: bool = false,
    /// sysfs GPIO controller root. Overridable so tests can target a temp dir.
    gpio_root: []const u8 = "/sys/class/gpio",

    pub fn init(alloc: std.mem.Allocator, bus: ?*NotifyBus) PowerCtx {
        return .{
            .gpa = alloc,
            .bus = bus,
            .io = null,
            .devices = std.StringHashMap(Device).init(alloc),
            .printing_active = false,
        };
    }

    pub fn deinit(self: *PowerCtx) void {
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

    /// Drive every device configured with an `initial_state` to that state at
    /// startup (Moonraker `_set_initial_state`). Hardware (HTTP/gpio) is driven
    /// when io is wired; the in-memory state is always updated. Does not emit a
    /// change notification (this is the boot baseline, not a user action).
    pub fn applyInitialStates(self: *PowerCtx) void {
        var it = self.devices.valueIterator();
        while (it.next()) |dev| {
            const target = dev.initial_state orelse continue;
            const on = std.mem.eql(u8, target, "on");
            if (!on and !std.mem.eql(u8, target, "off")) continue;
            if (on) {
                if (dev.on_url) |u| self.sendDeviceHttpGet(u);
            } else {
                if (dev.off_url) |u| self.sendDeviceHttpGet(u);
            }
            self.driveGpio(dev, on);
            self.setState(dev.name, target) catch {};
        }
    }

    /// Drive a `type: gpio` device's sysfs line on power on/off. No-op for
    /// non-gpio devices, devices without a configured pin, or when io is not
    /// wired (unit-test path). Best-effort: hardware errors are swallowed since
    /// the in-memory state has already been committed.
    fn driveGpio(self: *PowerCtx, dev: *const Device, on: bool) void {
        const io = self.io orelse return;
        const pin = dev.gpio_pin orelse return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const g = gpio_sysfs.SysfsGpio{ .io = io, .root = self.gpio_root };
        // active_low: "on" places a LOW level on the line.
        const physical_high = on != dev.gpio_active_low;
        g.setValue(arena.allocator(), pin, physical_high) catch |err|
            std.debug.print("phobos: warning: power device '{s}' gpio pin {d} drive failed: {} — reported state may not match hardware\n", .{ dev.name, pin, err });
    }

    /// Issue an HTTP GET to a device URL. Silently returns on any error
    /// (DNS, connect, timeout, non-200) — the in-memory state update is
    /// already committed, and we treat the HTTP part as best-effort.
    fn sendDeviceHttpGet(self: *PowerCtx, url: []const u8) void {
        const io = self.io orelse return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const aa = arena.allocator();

        var client: std.http.Client = .{ .allocator = aa, .io = io };
        defer client.deinit();

        var aw: std.Io.Writer.Allocating = .init(aa);
        defer aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &aw.writer,
        }) catch |err| {
            std.debug.print("phobos: warning: power device http GET {s} failed: {} — reported state may not match hardware\n", .{ url, err });
            return;
        };
        _ = result;
    }

    /// Try to read live device status via HTTP GET to the device's
    /// `status_url`. Returns the response body as a dupe'd string on
    /// success, null on failure or if status_url is not configured.
    fn fetchDeviceStatus(self: *PowerCtx, url: []const u8) ?[]const u8 {
        const io = self.io orelse return null;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const aa = arena.allocator();

        var client: std.http.Client = .{ .allocator = aa, .io = io };
        defer client.deinit();

        var aw: std.Io.Writer.Allocating = .init(aa);
        defer aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &aw.writer,
        }) catch return null;

        if (result.status != .ok) return null;
        const body = aw.written();
        return if (body.len > 0) self.gpa.dupe(u8, body) catch null else null;
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

    /// Set whether the printer is currently printing. When `true`, power
    /// operations on devices with `locked_while_printing=true` are rejected.
    pub fn setPrintingActive(self: *PowerCtx, active: bool) void {
        self.printing_active = active;
    }

    /// Check whether a device is locked due to an active print. Returns
    /// `error.PrinterLocked` when the device has `locked_while_printing=true`
    /// and printing is active, matching Moonraker's `PrinterPowerLock`.
    pub fn checkPrintingLock(self: *const PowerCtx, dev: *const Device) !void {
        if (dev.locked_while_printing and self.printing_active) return error.PrinterLocked;
    }

    /// Add a device (takes ownership of all slices).
    pub fn addDevice(
        self: *PowerCtx,
        name: []const u8,
        type_str: []const u8,
        initial_state: []const u8,
        locked_while_printing: bool,
    ) !void {
        return self.addDeviceFull(.{
            .name = name,
            .type_str = type_str,
            .state = initial_state,
            .locked_while_printing = locked_while_printing,
            .is_shutdown = false,
        });
    }

    /// Add or replace a device, copying all configuration strings.
    pub fn addDeviceFull(self: *PowerCtx, opts: Device) !void {
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

    /// Handle Klippy shutdown: power off all devices with off_when_shutdown=true.
    /// Called when notify_klippy_shutdown is emitted.
    pub fn handleKlippyShutdown(self: *PowerCtx, alloc: std.mem.Allocator) void {
        var it = self.devices.iterator();
        while (it.next()) |entry| {
            const dev = entry.value_ptr;
            if (dev.off_when_shutdown) {
                // setState already frees the old state and installs a fresh
                // "off"; do not free/re-dupe it again (redundant + fragile).
                self.setState(dev.name, "off") catch continue;
                dev.is_shutdown = true;
                emitPowerChanged(self, alloc, dev);
            }
        }
    }

    /// Handle job queued: power on all devices with on_when_queued=true.
    /// Called when notify_job_queue_changed with action="jobs_added" is emitted.
    pub fn handleJobQueued(self: *PowerCtx, alloc: std.mem.Allocator) void {
        var it = self.devices.iterator();
        while (it.next()) |entry| {
            const dev = entry.value_ptr;
            if (dev.on_when_queued) {
                // setState already frees+replaces dev.state; no extra free/dupe.
                self.setState(dev.name, "on") catch continue;
                emitPowerChanged(self, alloc, dev);
            }
        }
    }

    /// Set device power (remote method callable from Klippy macros).
    /// Accepts force parameter to bypass the printing lock.
    pub fn setDevicePower(
        self: *PowerCtx,
        device_name: []const u8,
        state: []const u8,
        force: bool,
        alloc: std.mem.Allocator,
    ) !void {
        const dev = self.findDevice(device_name) orelse return error.NotFound;
        if (!force) {
            try self.checkPrintingLock(dev);
        }
        // Normalize state: accept "true"/"false" strings as on/off.
        const action: []const u8 = if (std.mem.eql(u8, state, "true"))
            "on"
        else if (std.mem.eql(u8, state, "false"))
            "off"
        else
            state;
        _ = try processRequest(self, dev, action, alloc, force);
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
// State machine helpers
// ---------------------------------------------------------------------------

/// Apply a power request ("on" | "off" | "toggle" | "status") to a device.
/// HTTP-type devices with URLs configured send real HTTP GET requests via
/// std.http.Client; `type: gpio` devices drive the sysfs line; other non-HTTP
/// types update in-memory state only.
/// Returns the resulting state string (points into ctx-owned memory or a
/// literal — caller must not free).
/// on/off/status URLs for a protocol-specific HTTP power device. Strings are
/// allocated in `alloc` (caller owns all three).
pub const ProtoUrls = struct { on: []const u8, off: []const u8, status: []const u8 };

/// Tasmota HTTP command URLs (Moonraker tasmota.py): cmnd=Power<id>%20<ON|OFF|>.
/// `password` (with user "admin") is appended when set.
pub fn tasmotaUrls(alloc: std.mem.Allocator, address: []const u8, output_id: i64, password: ?[]const u8) !ProtoUrls {
    var auth_buf: [128]u8 = undefined;
    const auth: []const u8 = if (password) |p|
        try std.fmt.bufPrint(&auth_buf, "&user=admin&password={s}", .{p})
    else
        "";
    return .{
        .on = try std.fmt.allocPrint(alloc, "http://{s}/cm?cmnd=Power{d}%20ON{s}", .{ address, output_id, auth }),
        .off = try std.fmt.allocPrint(alloc, "http://{s}/cm?cmnd=Power{d}%20OFF{s}", .{ address, output_id, auth }),
        .status = try std.fmt.allocPrint(alloc, "http://{s}/cm?cmnd=Power{d}{s}", .{ address, output_id, auth }),
    };
}

/// Shelly Gen1 relay URLs (Moonraker shelly.py): /relay/<id>?turn=<on|off>.
pub fn shellyUrls(alloc: std.mem.Allocator, address: []const u8, output_id: i64) !ProtoUrls {
    return .{
        .on = try std.fmt.allocPrint(alloc, "http://{s}/relay/{d}?turn=on", .{ address, output_id }),
        .off = try std.fmt.allocPrint(alloc, "http://{s}/relay/{d}?turn=off", .{ address, output_id }),
        .status = try std.fmt.allocPrint(alloc, "http://{s}/relay/{d}", .{ address, output_id }),
    };
}

fn processRequest(ctx: *PowerCtx, dev: *Device, req: []const u8, alloc: std.mem.Allocator, force: bool) ![]const u8 {
    const cur = dev.state;
    if (std.mem.eql(u8, req, "status")) {
        // If a status_url is configured, try to read live state from the
        // hardware via HTTP GET. On failure, fall back to cached state.
        if (dev.status_url) |url| {
            if (ctx.fetchDeviceStatus(url)) |body| {
                defer ctx.gpa.free(body);
                // Moonraker's power types return various response formats;
                // we do a best-effort parse: if the body contains "on"
                // but not "off", treat as on; "off" but not "on", treat
                // as off. Otherwise keep the cached state.
                const has_on = std.mem.indexOf(u8, body, "\"on\"") != null or
                    std.mem.indexOf(u8, body, "ON") != null or
                    std.mem.indexOf(u8, body, "\"POWER\":\"ON\"") != null;
                const has_off = std.mem.indexOf(u8, body, "\"off\"") != null or
                    std.mem.indexOf(u8, body, "OFF") != null or
                    std.mem.indexOf(u8, body, "\"POWER\":\"OFF\"") != null;
                if (has_on and !has_off) {
                    ctx.setState(dev.name, "on") catch {};
                    const updated = ctx.findDevice(dev.name) orelse return "on";
                    return updated.state;
                } else if (has_off and !has_on) {
                    ctx.setState(dev.name, "off") catch {};
                    const updated = ctx.findDevice(dev.name) orelse return "off";
                    return updated.state;
                }
            }
        }
        return cur;
    }
    // Enforce the printing lock on mutating actions. Status queries (above)
    // are exempt. Matches Moonraker's `PrinterPowerLock` in power.py.
    if (!force) {
        try ctx.checkPrintingLock(dev);
    }
    // Resolve "toggle" to the opposite of the current state.
    const action: []const u8 = blk: {
        if (!std.mem.eql(u8, req, "toggle")) break :blk req;
        break :blk if (std.mem.eql(u8, cur, "off")) "on" else "off";
    };
    if (!std.mem.eql(u8, action, "on") and !std.mem.eql(u8, action, "off")) {
        return error.InvalidParams;
    }
    // Drive real hardware: HTTP GET for URL devices, sysfs GPIO for gpio pins.
    const turning_on = std.mem.eql(u8, action, "on");
    if (turning_on) {
        if (dev.on_url) |url| ctx.sendDeviceHttpGet(url);
    } else {
        if (dev.off_url) |url| ctx.sendDeviceHttpGet(url);
    }
    ctx.driveGpio(dev, turning_on);
    ctx.setState(dev.name, action) catch {};
    // Refresh pointer after setState (dupe may have reallocated).
    const updated = ctx.findDevice(dev.name) orelse return action;
    emitPowerChanged(ctx, alloc, updated);
    return updated.state;
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
    const dev_name = try getStr(params, "device");
    const dev = ctx.findDevice(dev_name) orelse {
        // Matches Moonraker: "No valid device named <x>"
        return error.NotFound;
    };
    // GET = status query; POST applies `action` (on/off/toggle). Key on the
    // transport's injected `_method`, NOT on whether `action` is present —
    // otherwise `GET ...?action=on` would power the device on (unsafe method).
    const is_post = if (getOptStr(params, "_method")) |m| std.mem.eql(u8, m, "POST") else false;
    const action: []const u8 = if (is_post) blk: {
        const a = getOptStr(params, "action") orelse return error.InvalidParams;
        const al = std.ascii.allocLowerString(alloc, a) catch a;
        if (!std.mem.eql(u8, al, "on") and !std.mem.eql(u8, al, "off") and !std.mem.eql(u8, al, "toggle")) {
            return error.InvalidParams;
        }
        break :blk al;
    } else "status";

    const result_state = try processRequest(ctx, dev, action, alloc, false);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, dev_name, .{ .string = result_state });
    return .{ .object = obj };
}

// ---------------------------------------------------------------------------
// GET  /machine/device_power/status   → batch status
// POST /machine/device_power/on       → batch on
// POST /machine/device_power/off      → batch off
// ---------------------------------------------------------------------------

/// Batch handler. The request names are inferred from the endpoint path last
/// segment: "status" | "on" | "off". Device names come from the query params
/// (each param key is a device name; values are ignored by Moonraker).
/// Returns `{ "<device>": "<state>" | "device_not_found" }`.
///
/// We route all three paths here; the actual action is passed via a param
/// `__batch_action` injected by the per-path wrappers below.
fn handleBatch(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator, action: []const u8) anyerror!std.json.Value {
    const ctx: *PowerCtx = @ptrCast(@alignCast(ctx_ptr));
    var out: std.json.ObjectMap = .empty;
    switch (params) {
        .object => |obj| {
            var it = obj.iterator();
            var device_count: usize = 0;
            while (it.next()) |entry| {
                const name = entry.key_ptr.*;
                // Skip internal keys injected by the transport (_method etc.)
                // and the per-path batch action discriminator.
                if (name[0] == '_') continue;
                device_count += 1;
                if (ctx.findDevice(name)) |dev| {
                    const state = processRequest(ctx, dev, action, alloc, false) catch "error";
                    try out.put(alloc, name, .{ .string = state });
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
    try ctx.addDevice("printer_psu", "gpio", "off", false);
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
    try ctx.addDevice("psu", "gpio", "off", false);
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
    try ctx.addDevice("psu", "gpio", "off", false);
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
    try ctx.addDevice("psu", "gpio", "off", false);
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
    try ctx.addDevice("psu", "gpio", "off", false);
    try testing.expectError(error.InvalidParams, handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"psu\",\"action\":\"banana\",\"_method\":\"POST\"}"), a));
}

test "handleSingleDevice: locked_while_printing blocks mutating actions while printing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addDevice("psu", "gpio", "off", true); // locked_while_printing=true
    ctx.setPrintingActive(true);

    try testing.expectError(error.PrinterLocked, handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"psu\",\"action\":\"on\",\"_method\":\"POST\"}"), a));
    try testing.expectError(error.PrinterLocked, handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"psu\",\"action\":\"off\",\"_method\":\"POST\"}"), a));
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
    try ctx.addDevice("psu", "gpio", "off", true); // locked_while_printing=true
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
    try ctx.addDevice("fan", "gpio", "off", false); // locked_while_printing=false
    ctx.setPrintingActive(true);
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
    try ctx.addDevice("psu", "gpio", "off", false);
    const v = try handleOn(@ptrCast(&ctx), try objParams(a, "{\"psu\":null}"), a);
    try testing.expectEqualStrings("on", v.object.get("psu").?.string);
}

test "handleOff: turns off named device" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addDevice("psu", "gpio", "on", false);
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
    try ctx.addDevice("psu", "gpio", "off", true); // locked_while_printing=true
    ctx.setPrintingActive(true);

    // Batch handlers catch errors from processRequest and return "error".
    const v_on = try handleOn(@ptrCast(&ctx), try objParams(a, "{\"psu\":null}"), a);
    try testing.expectEqualStrings("error", v_on.object.get("psu").?.string);
    const v_off = try handleOff(@ptrCast(&ctx), try objParams(a, "{\"psu\":null}"), a);
    try testing.expectEqualStrings("error", v_off.object.get("psu").?.string);
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
            ctx.addDevice("psu", "gpio", "off", false) catch {};

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
            ctx.addDevice("psu", "gpio", "off", false) catch {};
            ctx.addDevice("fan", "gpio", "on", true) catch {};

            // Alternate between known and unknown device names.
            const names = [_][]const u8{ "psu", "fan", "unknown", "" };
            const nm = names[buf[0] % names.len];
            const params_str = try std.fmt.allocPrint(a, "{{\"{s}\":null}}", .{nm});
            const pv = std.json.parseFromSlice(std.json.Value, a, params_str, .{}) catch return;
            _ = handleOn(@ptrCast(&ctx), pv.value, a) catch {};
            _ = handleOff(@ptrCast(&ctx), pv.value, a) catch {};
            _ = handleStatus(@ptrCast(&ctx), pv.value, a) catch {};
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
            ctx.addDevice("psu", "gpio", "off", false) catch {};
            ctx.addDevice("fan", "gpio", "on", true) catch {};
            _ = handleDevices(@ptrCast(&ctx), .null, a) catch {};
        }
    }.run, .{});
}

test "registerPower: wires expected routes and JSON-RPC methods" {
    const jsonrpc = @import("../jsonrpc.zig");
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

// ---- addDeviceFull + new device fields ----

test "addDeviceFull: accepts full Device opts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.addDeviceFull(.{
        .name = "printer",
        .type_str = "gpio",
        .state = "off",
        .locked_while_printing = true,
        .is_shutdown = false,
        .off_when_shutdown = true,
        .off_when_shutdown_delay = 1.5,
        .on_when_queued = true,
        .klipper_restart = true,
        .restart_delay = 2.0,
        .bound_services = "klipper,moonraker",
        .initial_state = "on",
        .restrict_actions = true,
        .timer = 30.0,
    });

    const dev = ctx.findDevice("printer").?;
    try testing.expectEqual(true, dev.locked_while_printing);
    try testing.expectEqual(true, dev.off_when_shutdown);
    try testing.expectEqual(1.5, dev.off_when_shutdown_delay);
    try testing.expectEqual(true, dev.on_when_queued);
    try testing.expectEqual(true, dev.klipper_restart);
    try testing.expectEqual(2.0, dev.restart_delay);
    try testing.expectEqualStrings("klipper,moonraker", dev.bound_services.?);
    try testing.expectEqualStrings("on", dev.initial_state.?);
    try testing.expectEqual(true, dev.restrict_actions);
    try testing.expectEqual(30.0, dev.timer);
}

test "applyInitialStates: drives configured devices to their initial_state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.addDeviceFull(.{ .name = "lamp", .type_str = "gpio", .state = "off", .locked_while_printing = false, .is_shutdown = false, .initial_state = "on" });
    try ctx.addDeviceFull(.{ .name = "fan", .type_str = "gpio", .state = "on", .locked_while_printing = false, .is_shutdown = false, .initial_state = "off" });
    try ctx.addDeviceFull(.{ .name = "keep", .type_str = "gpio", .state = "off", .locked_while_printing = false, .is_shutdown = false }); // no initial_state

    ctx.applyInitialStates();
    try testing.expectEqualStrings("on", ctx.findDevice("lamp").?.state);
    try testing.expectEqualStrings("off", ctx.findDevice("fan").?.state);
    try testing.expectEqualStrings("off", ctx.findDevice("keep").?.state); // untouched
}

test "addDeviceFull: optional fields default to null/false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.addDeviceFull(.{
        .name = "simple",
        .type_str = "gpio",
        .state = "off",
        .locked_while_printing = false,
        .is_shutdown = false,
    });

    const dev = ctx.findDevice("simple").?;
    try testing.expectEqual(false, dev.off_when_shutdown);
    try testing.expectEqual(false, dev.on_when_queued);
    try testing.expectEqual(null, dev.bound_services);
    try testing.expectEqual(null, dev.initial_state);
    try testing.expectEqual(null, dev.on_url);
    try testing.expectEqual(null, dev.off_url);
    try testing.expectEqual(null, dev.status_url);
}

test "addDeviceFull: http device with URLs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.addDeviceFull(.{
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

// ---- handleKlippyShutdown ----

test "handleKlippyShutdown: powers off devices with off_when_shutdown" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.addDeviceFull(.{ .name = "psu", .type_str = "gpio", .state = "on", .locked_while_printing = false, .is_shutdown = false, .off_when_shutdown = true });
    try ctx.addDeviceFull(.{ .name = "fan", .type_str = "gpio", .state = "on", .locked_while_printing = false, .is_shutdown = false, .off_when_shutdown = false });

    ctx.handleKlippyShutdown(a);

    try testing.expectEqualStrings("off", ctx.findDevice("psu").?.state);
    try testing.expectEqual(true, ctx.findDevice("psu").?.is_shutdown);
    try testing.expectEqualStrings("on", ctx.findDevice("fan").?.state);
}

// ---- handleJobQueued ----

test "handleJobQueued: powers on devices with on_when_queued" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.addDeviceFull(.{ .name = "psu", .type_str = "gpio", .state = "off", .locked_while_printing = false, .is_shutdown = false, .on_when_queued = true });
    try ctx.addDeviceFull(.{ .name = "fan", .type_str = "gpio", .state = "off", .locked_while_printing = false, .is_shutdown = false, .on_when_queued = false });

    ctx.handleJobQueued(a);

    try testing.expectEqualStrings("on", ctx.findDevice("psu").?.state);
    try testing.expectEqualStrings("off", ctx.findDevice("fan").?.state);
}

// ---- setDevicePower (remote method) ----

test "setDevicePower: changes state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.addDevice("psu", "gpio", "off", false);
    try ctx.setDevicePower("psu", "on", false, a);
    try testing.expectEqualStrings("on", ctx.findDevice("psu").?.state);
}

test "setDevicePower: accepts true/false strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.addDevice("psu", "gpio", "off", false);
    try ctx.setDevicePower("psu", "true", false, a);
    try testing.expectEqualStrings("on", ctx.findDevice("psu").?.state);
    try ctx.setDevicePower("psu", "false", false, a);
    try testing.expectEqualStrings("off", ctx.findDevice("psu").?.state);
}

test "setDevicePower: force bypasses printing lock" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.addDevice("psu", "gpio", "off", true); // locked_while_printing=true
    ctx.setPrintingActive(true);

    // Without force — would fail through normal path.
    try testing.expectError(error.PrinterLocked, ctx.setDevicePower("psu", "on", false, a));
    // With force — bypasses the lock.
    try ctx.setDevicePower("psu", "on", true, a);
    try testing.expectEqualStrings("on", ctx.findDevice("psu").?.state);
}

test "setDevicePower: unknown device returns NotFound" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try testing.expectError(error.NotFound, ctx.setDevicePower("ghost", "on", false, a));
}

// ---- fuzz: new features ----

test "fuzz_setDevicePower: never crashes on arbitrary device/state" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [32]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = PowerCtx.init(a, null);
            defer ctx.deinit();
            ctx.addDevice("psu", "gpio", "off", false) catch {};

            const states = [_][]const u8{ "on", "off", "toggle", "true", "false", "status", "" };
            const state = states[buf[0] % states.len];
            const force = buf[1] % 2 == 0;
            _ = ctx.setDevicePower("psu", state, force, a) catch {};
        }
    }.run, .{});
}

test "fuzz_handleKlippyShutdown: never crashes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [32]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = PowerCtx.init(a, null);
            defer ctx.deinit();

            const count = buf[0] % 10;
            for (0..count) |i| {
                const name = try std.fmt.allocPrint(a, "dev{d}", .{i});
                ctx.addDeviceFull(.{
                    .name = name,
                    .type_str = "gpio",
                    .state = if (buf[1 + i] % 2 == 0) "on" else "off",
                    .locked_while_printing = false,
                    .is_shutdown = false,
                    .off_when_shutdown = buf[1 + i] % 3 == 0,
                }) catch continue;
            }
            ctx.handleKlippyShutdown(a);
        }
    }.run, .{});
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
            ctx.addDevice(name, "gpio", if (buf[1] % 2 == 0) "on" else "off", false) catch return;

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
            ctx.addDevice(name, t, state, buf[3] % 2 == 0) catch {};

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
            ctx.setPrintingActive(false);
            try ctx.checkPrintingLock(&dev);

            // Printing active, only locked if locked_while_printing
            ctx.setPrintingActive(true);
            const result = ctx.checkPrintingLock(&dev);
            if (val) {
                try testing.expectError(error.PrinterLocked, result);
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

            ctx.addDevice("d", "gpio", "off", false) catch return;
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
    try ctx.addDeviceFull(.{ .name = "psu", .type_str = "gpio", .state = "off", .locked_while_printing = false, .is_shutdown = false, .gpio_pin = 23 });
    const dev = ctx.findDevice("psu").?;

    ctx.driveGpio(dev, true);
    {
        const v = try readVal(io, tmp.dir);
        defer testing.allocator.free(v);
        try testing.expectEqualStrings("1", v);
    }
    ctx.driveGpio(dev, false);
    {
        const v = try readVal(io, tmp.dir);
        defer testing.allocator.free(v);
        try testing.expectEqualStrings("0", v);
    }

    // Active-low: on → physical 0.
    dev.gpio_active_low = true;
    ctx.driveGpio(dev, true);
    {
        const v = try readVal(io, tmp.dir);
        defer testing.allocator.free(v);
        try testing.expectEqualStrings("0", v);
    }
}

test "driveGpio: no-op without pin or io (no crash)" {
    var ctx = PowerCtx.init(testing.allocator, null);
    defer ctx.deinit();
    // No io, no pin → must not crash.
    try ctx.addDeviceFull(.{ .name = "d", .type_str = "gpio", .state = "off", .locked_while_printing = false, .is_shutdown = false });
    ctx.driveGpio(ctx.findDevice("d").?, true);
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
                .bound_services = "service",
                .initial_state = "off",
                .on_url = "on",
                .off_url = "off",
                .status_url = "status",
            };
            try ctx.addDeviceFull(device);
            try ctx.addDeviceFull(ctx.findDevice("test").?.*);
            try ctx.setState("test", ctx.findDevice("test").?.state);
            try std.testing.expectEqualStrings("off", ctx.findDevice("test").?.state);
        }
    }.check, .{});
}
