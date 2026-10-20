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
const registry = @import("../server/registry.zig");
const notify = @import("../server/notify.zig");
const NotifyBus = @import("../server/notify.zig").NotifyBus;
const Core = @import("../server/core.zig").Core;
const gpio_sysfs = @import("gpio_sysfs.zig");

const Registry = registry.Registry;

/// Request timeout of Moonraker's HTTP power devices (power.py `_send_http_command`).
const http_timeout: std.Io.Duration = .fromSeconds(20);
/// Largest device response body kept. Status replies are a few hundred bytes.
const max_response_bytes = 4096;

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
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var writer: std.Io.Writer = .fixed(body);
    const json_header = [_]std.http.Header{.{ .name = "content-type", .value = "application/json" }};
    const Outcome = union(enum) {
        fetched: std.http.Client.FetchError!std.http.Client.FetchResult,
        expired: std.Io.Cancelable!void,
    };
    var outcomes: [2]Outcome = undefined;
    var select: std.Io.Select(Outcome) = .init(io, &outcomes);
    defer select.cancelDiscard();
    try select.concurrent(.fetched, std.http.Client.fetch, .{ &client, .{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .response_writer = &writer,
        .keep_alive = false,
        .extra_headers = if (payload != null) &json_header else &.{},
    } });
    try select.concurrent(.expired, std.Io.sleep, .{ io, timeout, .awake });
    switch (try select.await()) {
        .expired => |result| {
            try result;
            return error.Timeout;
        },
        .fetched => |result| {
            if ((try result).status.class() != .success) return error.HttpStatus;
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

    pub fn init(alloc: std.mem.Allocator, bus: ?*NotifyBus) PowerCtx {
        return .{
            .gpa = alloc,
            .bus = bus,
            .io = null,
            .devices = std.StringHashMap(Device).init(alloc),
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
        const url: ?[]const u8 = if (on) dev.on_url else dev.off_url;
        const owned_url = if (url) |u| try alloc.dupe(u8, u) else null;
        const ok = blk: {
            self.driveGpio(dev, on) catch |err| {
                std.debug.print("phobos: warning: power device '{s}' gpio drive failed: {}\n", .{ name, err });
                break :blk false;
            };
            if (owned_url) |u| _ = self.deviceGet(alloc, u) catch |err| {
                std.debug.print("phobos: warning: power device '{s}' http request failed: {}\n", .{ name, err });
                break :blk false;
            };
            break :blk true;
        };
        try self.setState(name, if (!ok) "error" else if (on) "on" else "off");
        if (!ok) return error.DeviceRequestFailed;
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
// Protocol helpers
// ---------------------------------------------------------------------------

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
    if (std.mem.eql(u8, req, "status")) {
        const url = try alloc.dupe(u8, dev.status_url orelse return dev.state);
        const type_str = try alloc.dupe(u8, dev.type_str);
        const before = try alloc.dupe(u8, dev.state);
        const body = ctx.deviceGet(alloc, url) catch null;
        const after = ctx.findDevice(name) orelse return error.NotFound;
        if (body == null and ctx.io == null) return after.state;
        const on = if (body) |b| parseStatus(alloc, type_str, b) else null;
        try ctx.setState(name, if (on) |v| (if (v) "on" else "off") else "error");
        const updated = ctx.findDevice(name) orelse return error.NotFound;
        if (!std.mem.eql(u8, before, updated.state)) emitPowerChanged(ctx, alloc, updated);
        return updated.state;
    }
    // Enforce the printing lock on mutating actions (Moonraker `process_request`).
    if (!force) try ctx.checkPrintingLock(dev);
    // Resolve "toggle" to the opposite of the current state.
    const action: []const u8 = blk: {
        if (!std.mem.eql(u8, req, "toggle")) break :blk req;
        break :blk if (std.mem.eql(u8, dev.state, "off")) "on" else "off";
    };
    if (!std.mem.eql(u8, action, "on") and !std.mem.eql(u8, action, "off")) {
        return error.InvalidParams;
    }
    try ctx.setPower(alloc, name, std.mem.eql(u8, action, "on"));
    const updated = ctx.findDevice(name) orelse return error.NotFound;
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
    const params = try objParams(a, "{\"device\":\"psu\",\"action\":\"on\",\"_method\":\"POST\"}");
    try testing.expectError(error.DeviceRequestFailed, handleSingleDevice(@ptrCast(&ctx), params, a));
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
            ctx.addDevice(.{ .name = "psu", .type_str = "gpio", .state = "off", .locked_while_printing = false }) catch {};
            ctx.addDevice(.{ .name = "fan", .type_str = "gpio", .state = "on", .locked_while_printing = true }) catch {};
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
