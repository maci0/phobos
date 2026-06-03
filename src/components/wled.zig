//! machine.wled.* API component — Moonraker-compatible WLED neopixel control.
//!
//! Mirrors the endpoints registered in
//! `vendor/moonraker/moonraker/components/wled.py`:
//!
//!   GET  /machine/wled/strips  → machine.wled.strips
//!   GET  /machine/wled/status  → machine.wled.status   (batch)
//!   POST /machine/wled/on      → machine.wled.on        (batch)
//!   POST /machine/wled/off     → machine.wled.off       (batch)
//!   POST /machine/wled/toggle  → machine.wled.toggle    (batch)
//!   GET  /machine/wled/strip   → machine.wled.get_strip (single)
//!   POST /machine/wled/strip   → machine.wled.post_strip (single)
//!
//! REAL WLED HTTP/SERIAL CONTROL IS STUBBED. State is tracked in memory within
//! WledCtx.strips. No HTTP requests are sent to any WLED device, no serial
//! commands are transmitted. Each stub is noted at the relevant handler.
//!
//! STRIPS FROM CONFIG. Without `[wled <name>]` config sections (the spine
//! carries none), the strips map is empty and the list endpoint returns {}.
//! Strip-specific requests return a not-found error.

const std = @import("std");
const registry = @import("../server/registry.zig");

const Registry = registry.Registry;

// ---------------------------------------------------------------------------
// Strip state
// ---------------------------------------------------------------------------

pub const Strip = struct {
    name: []const u8,
    status: []const u8, // "on" | "off"
    chain_count: i64,
    chain_data: []u8,
    preset: i64,
    initial_preset: i64,
    initial_colors: ?[]const u8,
    brightness: i64,
    intensity: i64,
    speed: i64,
    error_state: ?[]const u8,
    send_full_chain_data: bool,

    /// STUB: Turn on the WLED strip with the given preset. In a real
    /// implementation this would send an HTTP POST to the WLED JSON API
    /// (preset={p}) or a serial command. phobos only updates in-memory state.
    pub fn wledOn(self: *Strip, preset: i64) void {
        self.preset = preset;
    }

    /// STUB: Turn off the WLED strip. A real implementation would send an
    /// HTTP POST with {"on": false} or a serial off command.
    pub fn wledOff(self: *Strip) void {
        _ = self; // no-op in stub
    }

    /// STUB: Apply brightness, intensity, and speed control values. A real
    /// implementation would send these over the serial connection to the WLED
    /// controller. phobos only caches the values in memory.
    pub fn wledControl(self: *Strip, brightness: i64, intensity: i64, speed: i64) void {
        if (brightness >= 0) self.brightness = brightness;
        if (intensity >= 0) self.intensity = intensity;
        if (speed >= 0) self.speed = speed;
    }
};

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

pub const WledCtx = struct {
    gpa: std.mem.Allocator,
    strips: std.StringHashMap(Strip),

    pub fn init(alloc: std.mem.Allocator) WledCtx {
        return .{
            .gpa = alloc,
            .strips = std.StringHashMap(Strip).init(alloc),
        };
    }

    pub fn deinit(self: *WledCtx) void {
        var it = self.strips.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.name);
            self.gpa.free(entry.value_ptr.status);
            self.gpa.free(entry.value_ptr.chain_data);
            if (entry.value_ptr.initial_colors) |c| self.gpa.free(c);
            if (entry.value_ptr.error_state) |e| self.gpa.free(e);
        }
        self.strips.deinit();
    }

    pub fn findStrip(self: *WledCtx, name: []const u8) ?*Strip {
        return self.strips.getPtr(name);
    }

    /// Add a strip (takes ownership of all slices passed by copy).
    pub fn addStrip(
        self: *WledCtx,
        name: []const u8,
        chain_count: i64,
        chain_data: []const u8,
        preset: i64,
        initial_preset: i64,
        initial_colors: ?[]const u8,
        send_full_chain_data: bool,
    ) !void {
        const k = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(k);
        const cd = try self.gpa.dupe(u8, chain_data);
        errdefer self.gpa.free(cd);
        const s: Strip = .{
            .name = try self.gpa.dupe(u8, name),
            .status = try self.gpa.dupe(u8, "off"),
            .chain_count = chain_count,
            .chain_data = cd,
            .preset = preset,
            .initial_preset = initial_preset,
            .initial_colors = if (initial_colors) |c| try self.gpa.dupe(u8, c) else null,
            .brightness = 255,
            .intensity = -1,
            .speed = -1,
            .error_state = null,
            .send_full_chain_data = send_full_chain_data,
        };
        errdefer {
            self.gpa.free(s.name);
            self.gpa.free(s.status);
            self.gpa.free(s.chain_data);
            if (s.initial_colors) |c| self.gpa.free(c);
        }
        try self.strips.put(k, s);
    }

    pub fn setStatus(self: *WledCtx, name: []const u8, new_status: []const u8) !void {
        const s = self.strips.getPtr(name) orelse return error.NotFound;
        self.gpa.free(s.status);
        s.status = try self.gpa.dupe(u8, new_status);
    }

    /// Apply control parameters to a strip (brightness, preset, intensity,
    /// speed). Any param set to a non-negative value is applied; -1 means
    /// "keep current". Turns the strip on.
    pub fn setStripControl(
        self: *WledCtx,
        name: []const u8,
        brightness: i64,
        preset: i64,
        intensity: i64,
        speed: i64,
    ) !void {
        const s = self.strips.getPtr(name) orelse return error.NotFound;
        // STUB: wledControl only caches values in memory. A real
        // implementation would send them over the serial connection.
        s.wledControl(brightness, intensity, speed);
        if (preset >= 0) s.preset = preset;
        self.gpa.free(s.status);
        s.status = try self.gpa.dupe(u8, "on");
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

fn getOptInt(params: std.json.Value, field: []const u8, default_val: i64) i64 {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return default_val;
            return switch (v) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                else => default_val,
            };
        },
        else => return default_val,
    }
}

// ---------------------------------------------------------------------------
// Strip info shape
// ---------------------------------------------------------------------------

/// Build the per-strip info object matching Strip.get_strip_info():
///   { strip, status, chain_count, chain_data, preset, brightness, intensity, speed, error, send_full_chain_data }
/// chain_data is encoded as a base-16 hex string ("" when empty or send_full_chain_data is false).
pub fn buildStripInfo(alloc: std.mem.Allocator, s: *const Strip) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "strip", .{ .string = s.name });
    try obj.put(alloc, "status", .{ .string = s.status });
    try obj.put(alloc, "chain_count", .{ .integer = s.chain_count });
    // Match Moonraker: only include chain_data in strip info when
    // send_full_chain_data is true; otherwise emit an empty string.
    const cd: []const u8 = if (s.send_full_chain_data and s.chain_data.len > 0) blk: {
        const buf = try alloc.alloc(u8, s.chain_data.len * 2);
        const hex_chars = "0123456789abcdef";
        for (s.chain_data, 0..) |byte, i| {
            buf[i * 2] = hex_chars[byte >> 4];
            buf[i * 2 + 1] = hex_chars[byte & 0x0f];
        }
        break :blk buf;
    } else "";
    try obj.put(alloc, "chain_data", .{ .string = cd });
    try obj.put(alloc, "preset", .{ .integer = s.preset });
    try obj.put(alloc, "brightness", .{ .integer = s.brightness });
    try obj.put(alloc, "intensity", .{ .integer = s.intensity });
    try obj.put(alloc, "speed", .{ .integer = s.speed });
    if (s.error_state) |e| {
        try obj.put(alloc, "error", .{ .string = e });
    } else {
        try obj.put(alloc, "error", .null);
    }
    return .{ .object = obj };
}

// ---------------------------------------------------------------------------
// Action helpers
// ---------------------------------------------------------------------------

/// Apply an action ("on" | "off" | "toggle" | "status") to a strip.
/// STUB: no real WLED commands are sent; state is updated in memory only.
fn processRequest(ctx: *WledCtx, strip: *Strip, req: []const u8) ![]const u8 {
    if (std.mem.eql(u8, req, "status")) {
        // STUB: Moonraker calls strip.get_strip_info() which reflects live WLED
        // state. phobos returns the cached in-memory status.
        return strip.status;
    }
    const action: []const u8 = blk: {
        if (!std.mem.eql(u8, req, "toggle")) break :blk req;
        break :blk if (std.mem.eql(u8, strip.status, "off")) "on" else "off";
    };
    if (!std.mem.eql(u8, action, "on") and !std.mem.eql(u8, action, "off")) {
        return error.InvalidParams;
    }
    // STUB: a real implementation would call strip.wled_on(preset) or
    // strip.wled_off(), sending an HTTP POST to the WLED JSON API or a serial
    // command. phobos only updates in-memory state via the stub methods.
    if (std.mem.eql(u8, action, "on")) {
        strip.wledOn(strip.preset);
    } else {
        strip.wledOff();
    }
    ctx.setStatus(strip.name, action) catch {};
    return ctx.findStrip(strip.name).?.status;
}

// ---------------------------------------------------------------------------
// GET /machine/wled/strips → machine.wled.strips
// ---------------------------------------------------------------------------

/// Returns `{ "strips": { "<name>": { strip_info }, ... } }`.
/// Without configured strips, the inner map is empty.
pub fn handleStrips(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *WledCtx = @ptrCast(@alignCast(ctx_ptr));
    var strips_obj: std.json.ObjectMap = .empty;
    var it = ctx.strips.valueIterator();
    while (it.next()) |s| {
        try strips_obj.put(alloc, s.name, try buildStripInfo(alloc, s));
    }
    var out: std.json.ObjectMap = .empty;
    try out.put(alloc, "strips", .{ .object = strips_obj });
    return .{ .object = out };
}

// ---------------------------------------------------------------------------
// GET  /machine/wled/strip?strip= → machine.wled.get_strip
// POST /machine/wled/strip?strip=&action= → machine.wled.post_strip
// ---------------------------------------------------------------------------

/// Shared single-strip handler.
/// GET → returns { "<strip>": strip_info }.
/// POST → requires `action` in [on|off|toggle|control]; returns { "<strip>": strip_info }.
pub fn handleSingleStrip(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *WledCtx = @ptrCast(@alignCast(ctx_ptr));
    const strip_name = try getStr(params, "strip");
    const strip = ctx.findStrip(strip_name) orelse {
        // Matches Moonraker: "No valid strip named <x>"
        return error.NotFound;
    };
    const action: []const u8 = if (getOptStr(params, "action")) |a| blk: {
        const al = std.ascii.allocLowerString(alloc, a) catch a;
        if (!std.mem.eql(u8, al, "on") and
            !std.mem.eql(u8, al, "off") and
            !std.mem.eql(u8, al, "toggle") and
            !std.mem.eql(u8, al, "control"))
        {
            return error.InvalidParams;
        }
        break :blk al;
    } else "status";

    if (std.mem.eql(u8, action, "control")) {
        const brightness = getOptInt(params, "brightness", -1);
        const preset = getOptInt(params, "preset", -1);
        const intensity = getOptInt(params, "intensity", -1);
        const speed = getOptInt(params, "speed", -1);
        try ctx.setStripControl(strip_name, brightness, preset, intensity, speed);
    } else {
        _ = try processRequest(ctx, strip, action);
    }
    // Re-fetch after potential state change.
    const updated = ctx.findStrip(strip_name) orelse strip;
    var out: std.json.ObjectMap = .empty;
    try out.put(alloc, strip_name, try buildStripInfo(alloc, updated));
    return .{ .object = out };
}

// ---------------------------------------------------------------------------
// Batch handlers
// ---------------------------------------------------------------------------

fn handleBatch(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator, action: []const u8) anyerror!std.json.Value {
    const ctx: *WledCtx = @ptrCast(@alignCast(ctx_ptr));
    var out: std.json.ObjectMap = .empty;
    switch (params) {
        .object => |obj| {
            if (obj.count() == 0) return error.InvalidParams;
            var it = obj.iterator();
            while (it.next()) |entry| {
                const name = entry.key_ptr.*;
                if (ctx.findStrip(name)) |strip| {
                    _ = processRequest(ctx, strip, action) catch {};
                    const updated = ctx.findStrip(name) orelse strip;
                    const info = buildStripInfo(alloc, updated) catch continue;
                    try out.put(alloc, name, info);
                } else {
                    // Matches Moonraker's result[name] = {"error": "strip_not_found"}
                    var err_obj: std.json.ObjectMap = .empty;
                    try err_obj.put(alloc, "error", .{ .string = "strip_not_found" });
                    try out.put(alloc, name, .{ .object = err_obj });
                }
            }
        },
        else => return error.InvalidParams,
    }
    if (out.count() == 0) return error.InvalidParams;
    return .{ .object = out };
}

pub fn handleBatchStatus(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    return handleBatch(ctx_ptr, params, alloc, "status");
}

pub fn handleBatchOn(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    return handleBatch(ctx_ptr, params, alloc, "on");
}

pub fn handleBatchOff(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    return handleBatch(ctx_ptr, params, alloc, "off");
}

pub fn handleBatchToggle(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    return handleBatch(ctx_ptr, params, alloc, "toggle");
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn registerWled(reg: *Registry, ctx: *WledCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    try reg.registerEndpoint(.{ .path = "/machine/wled/strips", .methods = &.{.GET} }, c, handleStrips);
    try reg.registerEndpoint(.{ .path = "/machine/wled/status", .methods = &.{.GET} }, c, handleBatchStatus);
    try reg.registerEndpoint(.{ .path = "/machine/wled/on", .methods = &.{.POST} }, c, handleBatchOn);
    try reg.registerEndpoint(.{ .path = "/machine/wled/off", .methods = &.{.POST} }, c, handleBatchOff);
    try reg.registerEndpoint(.{ .path = "/machine/wled/toggle", .methods = &.{.POST} }, c, handleBatchToggle);
    try reg.registerEndpoint(.{ .path = "/machine/wled/strip", .methods = &.{ .GET, .POST } }, c, handleSingleStrip);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn objParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    return p.value;
}

fn testCtx(alloc: std.mem.Allocator) WledCtx {
    return WledCtx.init(alloc);
}

// ---- handleStrips ----

test "handleStrips: empty map when no strips configured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    const v = try handleStrips(@ptrCast(&ctx), .null, a);
    const strips = v.object.get("strips").?.object;
    try testing.expectEqual(@as(usize, 0), strips.count());
}

test "handleStrips: returns strip info when strip configured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("printer_leds", 30, "", -1, -1, null, false);
    const v = try handleStrips(@ptrCast(&ctx), .null, a);
    const strips = v.object.get("strips").?.object;
    try testing.expectEqual(@as(usize, 1), strips.count());
    const s = strips.get("printer_leds").?.object;
    try testing.expectEqualStrings("printer_leds", s.get("strip").?.string);
    try testing.expectEqualStrings("off", s.get("status").?.string);
    try testing.expectEqual(@as(i64, 30), s.get("chain_count").?.integer);
    try testing.expectEqual(@as(i64, -1), s.get("preset").?.integer);
}

// ---- handleSingleStrip GET ----

test "handleSingleStrip: GET unknown strip returns NotFound" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try testing.expectError(error.NotFound, handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"ghost\"}"), a));
}

test "handleSingleStrip: GET returns strip info" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false);
    const v = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"leds\"}"), a);
    const s = v.object.get("leds").?.object;
    try testing.expectEqualStrings("leds", s.get("strip").?.string);
    try testing.expectEqualStrings("off", s.get("status").?.string);
}

// ---- handleSingleStrip POST ----

test "handleSingleStrip: POST action=on turns strip on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false);
    const v = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"leds\",\"action\":\"on\"}"), a);
    try testing.expectEqualStrings("on", v.object.get("leds").?.object.get("status").?.string);
}

test "handleSingleStrip: POST action=toggle flips status" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false);
    // off → on
    _ = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"leds\",\"action\":\"toggle\"}"), a);
    try testing.expectEqualStrings("on", ctx.findStrip("leds").?.status);
    // on → off
    _ = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"leds\",\"action\":\"toggle\"}"), a);
    try testing.expectEqualStrings("off", ctx.findStrip("leds").?.status);
}

test "handleSingleStrip: POST action=off turns strip off" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false);
    // Turn on first, then off.
    _ = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"leds\",\"action\":\"on\"}"), a);
    const v = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"leds\",\"action\":\"off\"}"), a);
    try testing.expectEqualStrings("off", v.object.get("leds").?.object.get("status").?.string);
}

test "handleSingleStrip: POST invalid action returns InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false);
    try testing.expectError(error.InvalidParams, handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"leds\",\"action\":\"dance\"}"), a));
}

test "handleSingleStrip: POST action=control applies brightness and turns on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false);
    const v = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"leds\",\"action\":\"control\",\"brightness\":128}"), a);
    const s = v.object.get("leds").?.object;
    try testing.expectEqualStrings("on", s.get("status").?.string);
    try testing.expectEqual(@as(i64, 128), s.get("brightness").?.integer);
    // Other params unchanged.
    try testing.expectEqual(@as(i64, -1), s.get("preset").?.integer);
    try testing.expectEqual(@as(i64, -1), s.get("intensity").?.integer);
    try testing.expectEqual(@as(i64, -1), s.get("speed").?.integer);
}

test "handleSingleStrip: POST action=control with preset and intensity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false);
    const v = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"leds\",\"action\":\"control\",\"preset\":3,\"intensity\":200}"), a);
    const s = v.object.get("leds").?.object;
    try testing.expectEqualStrings("on", s.get("status").?.string);
    try testing.expectEqual(@as(i64, 3), s.get("preset").?.integer);
    try testing.expectEqual(@as(i64, 200), s.get("intensity").?.integer);
}

test "handleSingleStrip: POST action=control with all params" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false);
    const v = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"leds\",\"action\":\"control\",\"brightness\":200,\"preset\":5,\"intensity\":180,\"speed\":50}"), a);
    const s = v.object.get("leds").?.object;
    try testing.expectEqualStrings("on", s.get("status").?.string);
    try testing.expectEqual(@as(i64, 200), s.get("brightness").?.integer);
    try testing.expectEqual(@as(i64, 5), s.get("preset").?.integer);
    try testing.expectEqual(@as(i64, 180), s.get("intensity").?.integer);
    try testing.expectEqual(@as(i64, 50), s.get("speed").?.integer);
}

test "handleSingleStrip: POST action=control with no params still turns on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false);
    const v = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"leds\",\"action\":\"control\"}"), a);
    const s = v.object.get("leds").?.object;
    try testing.expectEqualStrings("on", s.get("status").?.string);
    // Default values preserved (no params applied).
    try testing.expectEqual(@as(i64, 255), s.get("brightness").?.integer);
    try testing.expectEqual(@as(i64, -1), s.get("preset").?.integer);
}

// ---- batch handlers ----

test "handleBatchOn: turns on known strip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false);
    const v = try handleBatchOn(@ptrCast(&ctx), try objParams(a, "{\"leds\":null}"), a);
    try testing.expectEqualStrings("on", v.object.get("leds").?.object.get("status").?.string);
}

test "handleBatchOff: turns off known strip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false);
    try ctx.setStatus("leds", "on");
    const v = try handleBatchOff(@ptrCast(&ctx), try objParams(a, "{\"leds\":null}"), a);
    try testing.expectEqualStrings("off", v.object.get("leds").?.object.get("status").?.string);
}

test "handleBatchToggle: toggles strip status" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false);
    _ = try handleBatchToggle(@ptrCast(&ctx), try objParams(a, "{\"leds\":null}"), a);
    try testing.expectEqualStrings("on", ctx.findStrip("leds").?.status);
    _ = try handleBatchToggle(@ptrCast(&ctx), try objParams(a, "{\"leds\":null}"), a);
    try testing.expectEqualStrings("off", ctx.findStrip("leds").?.status);
}

test "handleBatchStatus: unknown strip returns strip_not_found shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    const v = try handleBatchStatus(@ptrCast(&ctx), try objParams(a, "{\"ghost\":null}"), a);
    const r = v.object.get("ghost").?.object;
    try testing.expectEqualStrings("strip_not_found", r.get("error").?.string);
}

// ---- buildStripInfo ----

test "buildStripInfo: full key set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var chain_data = [_]u8{ 0xff, 0x00, 0xab };
    const s: Strip = .{ .name = "t", .status = "on", .chain_count = 5, .chain_data = &chain_data, .preset = 2, .initial_preset = 3, .initial_colors = null, .brightness = 200, .intensity = 100, .speed = 50, .error_state = null, .send_full_chain_data = true };
    const v = try buildStripInfo(a, &s);
    const o = v.object;
    try testing.expectEqualStrings("t", o.get("strip").?.string);
    try testing.expectEqualStrings("on", o.get("status").?.string);
    try testing.expectEqual(@as(i64, 5), o.get("chain_count").?.integer);
    try testing.expectEqual(@as(i64, 2), o.get("preset").?.integer);
    try testing.expectEqual(@as(i64, 200), o.get("brightness").?.integer);
    try testing.expectEqual(@as(i64, 100), o.get("intensity").?.integer);
    try testing.expectEqual(@as(i64, 50), o.get("speed").?.integer);
    try testing.expect(o.get("error").? == .null);
    try testing.expectEqualStrings("ff00ab", o.get("chain_data").?.string);
}

test "buildStripInfo: chain_data empty when send_full_chain_data is false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var chain_data2 = [_]u8{ 0xde, 0xad };
    const s: Strip = .{ .name = "t", .status = "off", .chain_count = 3, .chain_data = &chain_data2, .preset = 0, .initial_preset = 0, .initial_colors = null, .brightness = 255, .intensity = -1, .speed = -1, .error_state = null, .send_full_chain_data = false };
    const v = try buildStripInfo(a, &s);
    try testing.expectEqualStrings("", v.object.get("chain_data").?.string);
}

// ---- Strip methods ----

test "Strip.wledOn: sets preset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, 5, null, false);
    var strip = ctx.findStrip("leds").?;
    strip.wledOn(3);
    try testing.expectEqual(@as(i64, 3), strip.preset);
}

test "Strip.wledOff: does not crash (no-op stub)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false);
    var strip = ctx.findStrip("leds").?;
    strip.wledOff();
}

test "Strip.wledControl: applies brightness, intensity, speed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false);
    var strip = ctx.findStrip("leds").?;
    strip.wledControl(128, 200, 50);
    try testing.expectEqual(@as(i64, 128), strip.brightness);
    try testing.expectEqual(@as(i64, 200), strip.intensity);
    try testing.expectEqual(@as(i64, 50), strip.speed);
}

test "Strip.wledControl: negative values are not applied (keep current)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false);
    var strip = ctx.findStrip("leds").?;
    strip.brightness = 100;
    strip.intensity = 150;
    strip.speed = 75;
    strip.wledControl(-1, -1, -1);
    try testing.expectEqual(@as(i64, 100), strip.brightness);
    try testing.expectEqual(@as(i64, 150), strip.intensity);
    try testing.expectEqual(@as(i64, 75), strip.speed);
}

// ---- addStrip: new fields ----

test "addStrip: stores chain_data and initial_preset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, &.{ 0x01, 0x02, 0x03 }, 0, 7, "red,green", true);
    const s = ctx.findStrip("leds").?;
    try testing.expectEqual(@as(i64, 7), s.initial_preset);
    try testing.expectEqualStrings("red,green", s.initial_colors.?);
    try testing.expectEqual(true, s.send_full_chain_data);
    try testing.expectEqual(@as(usize, 3), s.chain_data.len);
    try testing.expectEqual(@as(u8, 0x01), s.chain_data[0]);
    try testing.expectEqual(@as(u8, 0x02), s.chain_data[1]);
    try testing.expectEqual(@as(u8, 0x03), s.chain_data[2]);
}

test "addStrip: null initial_colors stored as null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false);
    try testing.expect(ctx.findStrip("leds").?.initial_colors == null);
}

// ---- fuzz: new fields ----

test "fuzz_single_strip: arbitrary params never crash handleSingleStrip" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [32]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = WledCtx.init(a);
            defer ctx.deinit();
            ctx.addStrip("leds", 10, "", -1, -1, null, false) catch {};

            const names = [_][]const u8{ "leds", "ghost", "" };
            const nm = names[buf[0] % names.len];
            const actions = [_][]const u8{ "on", "off", "toggle", "control", "status", "bad" };
            const act = actions[buf[1] % actions.len];
            const params_str = std.fmt.allocPrint(a, "{{\"strip\":\"{s}\",\"action\":\"{s}\"}}", .{ nm, act }) catch return;
            const pv = std.json.parseFromSlice(std.json.Value, a, params_str, .{}) catch return;
            _ = handleSingleStrip(@ptrCast(&ctx), pv.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz_batch_wled: arbitrary params never crash batch handlers" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [16]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = WledCtx.init(a);
            defer ctx.deinit();
            ctx.addStrip("leds", 10, "", -1, -1, null, false) catch {};

            const names = [_][]const u8{ "leds", "ghost", "another" };
            const nm = names[buf[0] % names.len];
            const params_str = std.fmt.allocPrint(a, "{{\"{s}\":null}}", .{nm}) catch return;
            const pv = std.json.parseFromSlice(std.json.Value, a, params_str, .{}) catch return;
            _ = handleBatchOn(@ptrCast(&ctx), pv.value, a) catch {};
            _ = handleBatchOff(@ptrCast(&ctx), pv.value, a) catch {};
            _ = handleBatchToggle(@ptrCast(&ctx), pv.value, a) catch {};
            _ = handleBatchStatus(@ptrCast(&ctx), pv.value, a) catch {};
        }
    }.run, .{});
}

test "registerWled: wires expected routes and JSON-RPC methods" {
    const jsonrpc = @import("../jsonrpc.zig");
    var d = jsonrpc.Dispatcher.init(testing.allocator);
    defer d.deinit();
    var reg = Registry.init(testing.allocator, &d);
    defer reg.deinit();

    var ctx = testCtx(testing.allocator);
    defer ctx.deinit();
    try registerWled(&reg, &ctx);

    try testing.expect(reg.lookup(.GET, "/machine/wled/strips") != null);
    try testing.expect(reg.lookup(.GET, "/machine/wled/status") != null);
    try testing.expect(reg.lookup(.GET, "/machine/wled/strip") != null);
    try testing.expect(reg.lookup(.POST, "/machine/wled/on") != null);
    try testing.expect(reg.lookup(.POST, "/machine/wled/off") != null);
    try testing.expect(reg.lookup(.POST, "/machine/wled/toggle") != null);
    try testing.expect(reg.lookup(.POST, "/machine/wled/strip") != null);
}
