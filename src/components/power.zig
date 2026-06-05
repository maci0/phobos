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
//! store HTTP URLs in the Device struct. Real HTTP GET requests via `std.http.Client`
//! are not yet wired; the URL fields are parsed from config and stored for future
//! integration. GPIO and other non-HTTP device types track state in memory only
//! (stubbed) unless a future platform-specific GPIO driver is integrated.
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

const Registry = registry.Registry;

// ---------------------------------------------------------------------------
// Device types (matches power.py dev_types)
// ---------------------------------------------------------------------------

/// All supported device types from Moonraker's power.py.
pub const DeviceType = enum {
    gpio,
    klipper_device,
    tplink_smartplug,
    tasmota,
    shelly,
    homeseer,
    homeassistant,
    loxonev1,
    rf,
    mqtt,
    smartthings,
    hue,
    http,
    uhubctl,
};

/// A configured power device. State is tracked in memory; real hardware control
/// is STUBBED (noted at processRequest).
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
            const dev = entry.value_ptr;
            self.gpa.free(dev.name);
            self.gpa.free(dev.type_str);
            self.gpa.free(dev.state);
            if (dev.bound_services) |bs| self.gpa.free(bs);
            if (dev.initial_state) |is| self.gpa.free(is);
            if (dev.on_url) |u| self.gpa.free(u);
            if (dev.off_url) |u| self.gpa.free(u);
            if (dev.status_url) |u| self.gpa.free(u);
        }
        self.devices.deinit();
    }

    pub fn setIo(self: *PowerCtx, io: std.Io) void {
        self.io = io;
    }

    /// Get a device by name (borrowed pointer into the map).
    pub fn findDevice(self: *PowerCtx, name: []const u8) ?*Device {
        return self.devices.getPtr(name);
    }

    /// Update a device's state in-place.
    pub fn setState(self: *PowerCtx, name: []const u8, new_state: []const u8) !void {
        const dev = self.devices.getPtr(name) orelse return error.NotFound;
        self.gpa.free(dev.state);
        dev.state = try self.gpa.dupe(u8, new_state);
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

    /// Add a device with full configuration (takes ownership of all slices).
    pub fn addDeviceFull(self: *PowerCtx, opts: Device) !void {
        const k = try self.gpa.dupe(u8, opts.name);
        errdefer self.gpa.free(k);
        const dev: Device = .{
            .name = try self.gpa.dupe(u8, opts.name),
            .type_str = try self.gpa.dupe(u8, opts.type_str),
            .state = try self.gpa.dupe(u8, opts.state),
            .locked_while_printing = opts.locked_while_printing,
            .is_shutdown = opts.is_shutdown,
            .off_when_shutdown = opts.off_when_shutdown,
            .off_when_shutdown_delay = opts.off_when_shutdown_delay,
            .on_when_queued = opts.on_when_queued,
            .klipper_restart = opts.klipper_restart,
            .restart_delay = opts.restart_delay,
            .bound_services = if (opts.bound_services) |bs| try self.gpa.dupe(u8, bs) else null,
            .initial_state = if (opts.initial_state) |is| try self.gpa.dupe(u8, is) else null,
            .restrict_actions = opts.restrict_actions,
            .timer = opts.timer,
            .on_url = if (opts.on_url) |u| try self.gpa.dupe(u8, u) else null,
            .off_url = if (opts.off_url) |u| try self.gpa.dupe(u8, u) else null,
            .status_url = if (opts.status_url) |u| try self.gpa.dupe(u8, u) else null,
        };
        errdefer {
            self.gpa.free(dev.name);
            self.gpa.free(dev.type_str);
            self.gpa.free(dev.state);
            if (dev.bound_services) |bs| self.gpa.free(bs);
            if (dev.initial_state) |is| self.gpa.free(is);
            if (dev.on_url) |u| self.gpa.free(u);
            if (dev.off_url) |u| self.gpa.free(u);
            if (dev.status_url) |u| self.gpa.free(u);
        }
        try self.devices.put(k, dev);
    }

    /// Handle Klippy shutdown: power off all devices with off_when_shutdown=true.
    /// Called when notify_klippy_shutdown is emitted.
    pub fn handleKlippyShutdown(self: *PowerCtx, alloc: std.mem.Allocator) void {
        var it = self.devices.iterator();
        while (it.next()) |entry| {
            const dev = entry.value_ptr;
            if (dev.off_when_shutdown) {
                self.setState(dev.name, "off") catch {};
                dev.is_shutdown = true;
                self.gpa.free(dev.state);
                dev.state = self.gpa.dupe(u8, "off") catch continue;
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
                self.setState(dev.name, "on") catch {};
                self.gpa.free(dev.state);
                dev.state = self.gpa.dupe(u8, "on") catch continue;
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
/// STUB: no real GPIO/network control is performed. State is updated in memory.
/// Returns the resulting state string (points into ctx-owned memory or a
/// literal — caller must not free).
fn processRequest(ctx: *PowerCtx, dev: *Device, req: []const u8, alloc: std.mem.Allocator, force: bool) ![]const u8 {
    const cur = dev.state;
    if (std.mem.eql(u8, req, "status")) {
        // STUB: in Moonraker this calls refresh_status() on the device to read
        // live state from the hardware. phobos returns the cached in-memory
        // state without touching any hardware.
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
    // STUB: a real implementation would call device.set_power(action) which
    // writes a GPIO pin, sends an HTTP request, publishes an MQTT topic, etc.
    // phobos only updates the in-memory state and emits the notification.
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
    // Determine the action: if `action` param is present → POST semantics;
    // otherwise → GET semantics (status query).
    const action: []const u8 = if (getOptStr(params, "action")) |a| blk: {
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
    const v = try handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"psu\",\"action\":\"on\"}"), a);
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
    const v1 = try handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"psu\",\"action\":\"toggle\"}"), a);
    try testing.expectEqualStrings("on", v1.object.get("psu").?.string);
    const v2 = try handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"psu\",\"action\":\"toggle\"}"), a);
    try testing.expectEqualStrings("off", v2.object.get("psu").?.string);
}

test "handleSingleDevice: POST action=invalid returns InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addDevice("psu", "gpio", "off", false);
    try testing.expectError(error.InvalidParams, handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"psu\",\"action\":\"banana\"}"), a));
}

test "handleSingleDevice: locked_while_printing blocks mutating actions while printing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addDevice("psu", "gpio", "off", true); // locked_while_printing=true
    ctx.setPrintingActive(true);

    try testing.expectError(error.PrinterLocked, handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"psu\",\"action\":\"on\"}"), a));
    try testing.expectError(error.PrinterLocked, handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"psu\",\"action\":\"off\"}"), a));
    try testing.expectError(error.PrinterLocked, handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"psu\",\"action\":\"toggle\"}"), a));
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
    const v = try handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"psu\",\"action\":\"on\"}"), a);
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
    const v = try handleSingleDevice(@ptrCast(&ctx), try objParams(a, "{\"device\":\"fan\",\"action\":\"on\"}"), a);
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
