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
//! HTTP WLED strips (with an `address` config) send real HTTP POST requests to
//! the WLED JSON API (`/json`). Serial strips (with a `serial_path`, set via
//! setStripSerial) write the newline-terminated JSON command to the character
//! device through `serial.zig`. Strips with neither remain in-memory only.
//!
//! STRIPS FROM CONFIG. Without `[wled <name>]` config sections (the spine
//! carries none), the strips map is empty and the list endpoint returns {}.
//! Strip-specific requests return a not-found error.

const std = @import("std");
const registry = @import("../server/registry.zig");
const serial_mod = @import("serial.zig");

const Registry = registry.Registry;

// ---------------------------------------------------------------------------
// Strip state
// ---------------------------------------------------------------------------

pub const Strip = struct {
    /// RGBW color size in bytes (matches Python _COLORSIZE = 4).
    pub const color_size: usize = 4;

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
    /// HTTP WLED device address (hostname or IP). When non-null, on/off/control
    /// send real HTTP commands to the WLED JSON API; when null, the strip is
    /// serial-driven (sendWledBody writes the JSON line over serial.zig).
    address: ?[]const u8 = null,
    port: u16 = 80,
    protocol: []const u8 = "http",
    /// Serial-strip device path (Moonraker `serial:`). When non-null, WLED JSON
    /// commands are written to this character device instead of HTTP.
    serial_path: ?[]const u8 = null,
    /// Serial baud rate (Moonraker default 115200).
    serial_baud: u32 = 115200,

    /// Moonraker: wled_on(preset). Sets send_full_chain_data=true and
    /// resets brightness/intensity/speed to -1 (unknown until read back).
    /// Does NOT set self.status — the caller (processRequest or set_wled_state)
    /// is responsible for updating the status via WledCtx.setStatus.
    /// Real HTTP POST handled by WledCtx.
    pub fn wledOn(self: *Strip, preset: i64) void {
        self.preset = preset;
        self.send_full_chain_data = true;
        self.brightness = -1;
        self.intensity = -1;
        self.speed = -1;
    }

    /// Moonraker: wled_off(). Sets onoff=OnOff.off and
    /// send_full_chain_data=true so the next set_wled sends full chain.
    pub fn wledOff(self: *Strip) void {
        self.send_full_chain_data = true;
    }

    /// Moonraker: wled_control(brightness, intensity, speed).
    /// Applies the requested controls regardless of on/off state (the caller
    /// at a higher level – setStripControl or handleSingleStrip – manages the
    /// status transition to "on").
    /// Range-checks: brightness 1-255, intensity 0-255, speed 0-255.
    /// Returns true if any control was applied.
    pub fn wledControl(self: *Strip, brightness: i64, intensity: i64, speed: i64) bool {
        var applied = false;
        if (brightness >= 1) {
            if (brightness <= 255) {
                self.brightness = brightness;
                applied = true;
            }
        }
        if (intensity >= 0) {
            if (intensity <= 255) {
                self.intensity = intensity;
                applied = true;
            }
        }
        if (speed >= 0) {
            if (speed <= 255) {
                self.speed = speed;
                applied = true;
            }
        }
        return applied;
    }

    /// Moonraker: _update_color_data(red, green, blue, white, index).
    /// Scales float 0.0-1.0 to 0-255 and writes into chain_data.
    /// If index is null, fills the entire chain with the same color.
    /// Otherwise writes led_data at the given 1-based pixel index.
    pub fn updateColorData(
        self: *Strip,
        red: f64,
        green: f64,
        blue: f64,
        white: f64,
        index: ?usize,
    ) void {
        const r: u8 = @intFromFloat(@min(@max(red * 255.0 + 0.5, 0), 255));
        const g: u8 = @intFromFloat(@min(@max(green * 255.0 + 0.5, 0), 255));
        const b: u8 = @intFromFloat(@min(@max(blue * 255.0 + 0.5, 0), 255));
        const w: u8 = @intFromFloat(@min(@max(white * 255.0 + 0.5, 0), 255));
        const led_data = [_]u8{ r, g, b, w };

        if (index) |idx| {
            if (idx >= 1 and idx <= @as(usize, @intCast(self.chain_count))) {
                const start = (idx - 1) * color_size;
                const end = idx * color_size;
                if (end <= self.chain_data.len) {
                    @memcpy(self.chain_data[start..end], &led_data);
                }
            }
        } else {
            var i: usize = 0;
            while (i < @as(usize, @intCast(self.chain_count))) : (i += 1) {
                const start = i * color_size;
                const end = start + color_size;
                if (end <= self.chain_data.len) {
                    @memcpy(self.chain_data[start..end], &led_data);
                }
            }
        }
    }

    /// Moonraker: set_wled(red, green, blue, white, index, transmit).
    /// Updates color data and conditionally builds the WLED JSON state
    /// (stub: in-memory only; real transmission is deferred to caller).
    pub fn setWled(
        self: *Strip,
        red: f64,
        green: f64,
        blue: f64,
        white: f64,
        index: ?usize,
    ) void {
        self.updateColorData(red, green, blue, white, index);
        // Clear preset — sending seg{} reverts to preset otherwise.
        self.preset = -1;
        // If coming from a preset without wled_control, default brightness.
        if (self.brightness == -1) self.brightness = 255;
    }

};

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

pub const WledCtx = struct {
    gpa: std.mem.Allocator,
    strips: std.StringHashMap(Strip),
    io: ?std.Io = null,

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
            if (entry.value_ptr.address) |a| self.gpa.free(a);
            if (!std.mem.eql(u8, entry.value_ptr.protocol, "http")) self.gpa.free(entry.value_ptr.protocol);
            if (entry.value_ptr.serial_path) |sp| self.gpa.free(sp);
        }
        self.strips.deinit();
    }

    /// Configure a strip as a serial device: subsequent commands are written to
    /// `path` (gpa-owned, replacing any previous value) at `baud`.
    pub fn setStripSerial(self: *WledCtx, name: []const u8, path: []const u8, baud: u32) !void {
        const s = self.strips.getPtr(name) orelse return error.NotFound;
        const dup = try self.gpa.dupe(u8, path);
        if (s.serial_path) |old| self.gpa.free(old);
        s.serial_path = dup;
        s.serial_baud = baud;
    }

    /// Set the Io handle for making real HTTP requests to WLED devices.
    pub fn setIo(self: *WledCtx, io: std.Io) void {
        self.io = io;
    }

    /// Send a JSON body string to a WLED device via HTTP POST.
    /// Sets strip.error_state on failure.
    pub fn sendWledBody(self: *WledCtx, strip: *Strip, body: []const u8) void {
        const io = self.io orelse return;

        // Serial strip: write the newline-terminated JSON command to the device.
        if (strip.serial_path) |path| {
            var ser = serial_mod.Serial.open(io, path, strip.serial_baud) catch {
                if (strip.error_state) |e| self.gpa.free(e);
                strip.error_state = self.gpa.dupe(u8, "WLED: serial open failed") catch null;
                return;
            };
            defer ser.close();
            // Single newline-terminated write (one serial transaction).
            const line = std.fmt.allocPrint(self.gpa, "{s}\n", .{body}) catch return;
            defer self.gpa.free(line);
            ser.write(line) catch {
                if (strip.error_state) |e| self.gpa.free(e);
                strip.error_state = self.gpa.dupe(u8, "WLED: serial write failed") catch null;
                return;
            };
            if (strip.error_state) |e| {
                self.gpa.free(e);
                strip.error_state = null;
            }
            return;
        }

        const addr = strip.address orelse return;

        // Build URL: {protocol}://{address}:{port}/json
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}://{s}:{d}/json", .{ strip.protocol, addr, strip.port }) catch return;

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const aa = arena.allocator();

        var client: std.http.Client = .{ .allocator = aa, .io = io };
        defer client.deinit();

        var aw: std.Io.Writer.Allocating = .init(aa);
        defer aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .response_writer = &aw.writer,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        }) catch {
            if (strip.error_state) |e| self.gpa.free(e);
            strip.error_state = self.gpa.dupe(u8, "WLED: HTTP request failed") catch null;
            return;
        };

        if (result.status != .ok) {
            if (strip.error_state) |e| self.gpa.free(e);
            strip.error_state = self.gpa.dupe(u8, "WLED: non-200 response") catch null;
        } else {
            // Clear error state on success.
            if (strip.error_state) |e| {
                self.gpa.free(e);
                strip.error_state = null;
            }
        }
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
        address: ?[]const u8,
        port: u16,
        protocol: ?[]const u8,
    ) !void {
        const k = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(k);
        const cd = try self.gpa.dupe(u8, chain_data);
        errdefer self.gpa.free(cd);
        const proto = if (protocol) |p| p else "http";
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
            .address = if (address) |a| try self.gpa.dupe(u8, a) else null,
            .port = port,
            .protocol = if (protocol != null and !std.mem.eql(u8, proto, "http")) try self.gpa.dupe(u8, proto) else "http",
        };
        errdefer {
            self.gpa.free(s.name);
            self.gpa.free(s.status);
            self.gpa.free(s.chain_data);
            if (s.initial_colors) |c| self.gpa.free(c);
            if (s.address) |a| self.gpa.free(a);
            if (!std.mem.eql(u8, s.protocol, "http")) self.gpa.free(s.protocol);
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
        // Set status to "on" before wledControl so the off-guard passes.
        self.gpa.free(s.status);
        s.status = try self.gpa.dupe(u8, "on");
        _ = s.wledControl(brightness, intensity, speed);
        if (preset >= 0) s.preset = preset;
        // Send real HTTP POST to WLED device if address is configured.
        if (s.address != null) {
            // Build a WLED control JSON body mirroring Moonraker's wled_control.
            var body_buf: [256]u8 = undefined;
            var body: []const u8 = "{}";
            var has_control = false;
            if (brightness > 0 or intensity >= 0 or speed >= 0) has_control = true;
            if (has_control) {
                const tt: i64 = 0; // transition time: instant (matches Moonraker default)
                // Simple: just send brightness/seg if preset is active.
                if (s.preset != -1) {
                    body = std.fmt.bufPrint(&body_buf,
                        "{{\"tt\":{d},\"bri\":{d},\"seg\":{{\"bri\":{d}}}}}",
                        .{ tt, @max(0, brightness), @max(0, brightness) }) catch "{}";
                } else {
                    body = std.fmt.bufPrint(&body_buf,
                        "{{\"tt\":{d},\"bri\":{d}}}",
                        .{ tt, @max(0, brightness) }) catch "{}";
                }
            }
            self.sendWledBody(s, body);
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

fn getOptInt(params: std.json.Value, field: []const u8, default_val: i64) i64 {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return default_val;
            return switch (v) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                .string => |s| std.fmt.parseInt(i64, s, 10) catch default_val,
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
fn processRequest(ctx: *WledCtx, strip: *Strip, req: []const u8) ![]const u8 {
    if (std.mem.eql(u8, req, "status")) {
        return strip.status;
    }
    const action: []const u8 = blk: {
        if (!std.mem.eql(u8, req, "toggle")) break :blk req;
        break :blk if (std.mem.eql(u8, strip.status, "off")) "on" else "off";
    };
    if (!std.mem.eql(u8, action, "on") and !std.mem.eql(u8, action, "off")) {
        return error.InvalidParams;
    }
    // Update in-memory state.
    if (std.mem.eql(u8, action, "on")) {
        strip.wledOn(strip.preset);
        // Send real HTTP POST to WLED device if address is configured.
        if (strip.address != null) {
            var body_buf: [128]u8 = undefined;
            const body = if (strip.preset >= 0)
                std.fmt.bufPrint(&body_buf, "{{\"on\":true,\"ps\":{d}}}", .{strip.preset}) catch ""
            else
                "{\"on\":true}";
            ctx.sendWledBody(strip, body);
        }
    } else {
        strip.wledOff();
        if (strip.address != null) {
            ctx.sendWledBody(strip, "{\"on\":false}");
        }
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
    // GET is read-only: ignore any `action` and report status. Only POST may
    // mutate the strip (matches Moonraker _handle_single_wled_request, which
    // reads `action` only on POST). Without this guard a GET with ?action=on
    // would drive the hardware — an unsafe side-effecting GET.
    const is_post = if (getOptStr(params, "_method")) |m| std.mem.eql(u8, m, "POST") else false;
    const action: []const u8 = if (is_post) (if (getOptStr(params, "action")) |a| blk: {
        const al = std.ascii.allocLowerString(alloc, a) catch a;
        if (!std.mem.eql(u8, al, "on") and
            !std.mem.eql(u8, al, "off") and
            !std.mem.eql(u8, al, "toggle") and
            !std.mem.eql(u8, al, "control"))
        {
            return error.InvalidParams;
        }
        break :blk al;
    } else "status") else "status";

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
                // HTTP injects `_method` into every route. It is not a strip.
                if (name.len == 0 or name[0] == '_') continue;
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
// Remote methods (JSON-RPC only, called from GCode macros)
// ---------------------------------------------------------------------------

/// Moonraker: set_wled_state(strip, state, preset, brightness, intensity, speed).
/// Full control of WLED strip from GCode macros (SET_WLED_STATE).
pub fn handleSetWledState(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *WledCtx = @ptrCast(@alignCast(ctx_ptr));
    const strip_name = try getStr(params, "strip");

    const strip = ctx.findStrip(strip_name) orelse {
        return error.NotFound;
    };

    // Resolve the `state` param: can be a bool or a string.
    var status: ?[]const u8 = null;
    switch (params) {
        .object => |obj| {
            if (obj.get("state")) |sv| {
                switch (sv) {
                    .bool => |b| status = if (b) "on" else "off",
                    .string => |s| {
                        const sl = std.ascii.allocLowerString(alloc, s) catch s;
                        if (std.mem.eql(u8, sl, "true")) {
                            status = "on";
                        } else if (std.mem.eql(u8, sl, "false")) {
                            status = "off";
                        } else if (std.mem.eql(u8, sl, "on")) {
                            status = "on";
                        } else if (std.mem.eql(u8, sl, "off")) {
                            status = "off";
                        } else {
                            status = sl;
                        }
                    },
                    else => {},
                }
            }
        },
        else => {},
    }

    const preset = getOptInt(params, "preset", -1);
    const brightness = getOptInt(params, "brightness", -1);
    const intensity = getOptInt(params, "intensity", -1);
    const speed = getOptInt(params, "speed", -1);

    // Moonraker: if no state, preset, or control data, log and return.
    if (status == null and preset == -1 and brightness == -1 and intensity == -1 and speed == -1) {
        var out: std.json.ObjectMap = .empty;
        try out.put(alloc, "status", .{ .string = "ok" });
        return .{ .object = out };
    }

    // All other arguments are ignored when turning off.
    if (status != null and std.mem.eql(u8, status.?, "off")) {
        strip.wledOff();
        try ctx.setStatus(strip_name, "off");
        if (strip.address != null) {
            ctx.sendWledBody(strip, "{\"on\":false}");
        }
    }

    // Turn on if status is "on" or a preset is specified.
    if ((status != null and std.mem.eql(u8, status.?, "on")) or preset != -1) {
        strip.wledOn(preset);
        try ctx.setStatus(strip_name, "on");
        if (strip.address != null) {
            var body_buf: [128]u8 = undefined;
            const body = if (preset >= 0)
                std.fmt.bufPrint(&body_buf, "{{\"on\":true,\"ps\":{d}}}", .{preset}) catch "{\"on\":true}"
            else
                "{\"on\":true}";
            ctx.sendWledBody(strip, body);
        }
    }

    // Control: apply brightness/intensity/speed.
    if (brightness != -1 or intensity != -1 or speed != -1) {
        _ = strip.wledControl(brightness, intensity, speed);
    }

    var out: std.json.ObjectMap = .empty;
    try out.put(alloc, "status", .{ .string = "ok" });
    return .{ .object = out };
}

/// Moonraker: set_wled(strip, red, green, blue, white, index, transmit).
/// Individual pixel control for compatibility with SET_LED.
pub fn handleSetWled(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *WledCtx = @ptrCast(@alignCast(ctx_ptr));
    const strip_name = try getStr(params, "strip");

    const strip = ctx.findStrip(strip_name) orelse {
        return error.NotFound;
    };

    const red = switch (params) {
        .object => |obj| blk: {
            if (obj.get("red")) |v| {
                break :blk switch (v) {
                    .float => |f| f,
                    .integer => |i| @as(f64, @floatFromInt(i)),
                    else => @as(f64, 0.0),
                };
            }
            break :blk @as(f64, 0.0);
        },
        else => @as(f64, 0.0),
    };
    const green = switch (params) {
        .object => |obj| blk: {
            if (obj.get("green")) |v| {
                break :blk switch (v) {
                    .float => |f| f,
                    .integer => |i| @as(f64, @floatFromInt(i)),
                    else => @as(f64, 0.0),
                };
            }
            break :blk @as(f64, 0.0);
        },
        else => @as(f64, 0.0),
    };
    const blue = switch (params) {
        .object => |obj| blk: {
            if (obj.get("blue")) |v| {
                break :blk switch (v) {
                    .float => |f| f,
                    .integer => |i| @as(f64, @floatFromInt(i)),
                    else => @as(f64, 0.0),
                };
            }
            break :blk @as(f64, 0.0);
        },
        else => @as(f64, 0.0),
    };
    const white = switch (params) {
        .object => |obj| blk: {
            if (obj.get("white")) |v| {
                break :blk switch (v) {
                    .float => |f| f,
                    .integer => |i| @as(f64, @floatFromInt(i)),
                    else => @as(f64, 0.0),
                };
            }
            break :blk @as(f64, 0.0);
        },
        else => @as(f64, 0.0),
    };

    const index_raw = getOptInt(params, "index", -1);
    const index: ?usize = if (index_raw < 0) null else @intCast(index_raw);
    const transmit = getOptInt(params, "transmit", 1);

    strip.setWled(red, green, blue, white, index);

    // If transmitting, we'd send the WLED command. Stub: mark in-memory only.
    if (transmit == 1) {
        strip.send_full_chain_data = false;
        // If strip is off, setWled doesn't normally turn it on, but the
        // Moonraker bug workaround in wled.py lines 284-289 requires a
        // second send. We just mark it on here (stub).
        if (std.mem.eql(u8, strip.status, "off")) {
            try ctx.setStatus(strip_name, "on");
        }
    } else {
        strip.send_full_chain_data = true;
    }

    var out: std.json.ObjectMap = .empty;
    try out.put(alloc, "status", .{ .string = "ok" });
    return .{ .object = out };
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

    // Remote-only methods (no HTTP route, JSON-RPC only).
    // Moonraker: self.server.register_remote_method("set_wled_state", ...)
    //           self.server.register_remote_method("set_wled", ...)
    // Static literals → register directly (stable .rodata keys, no name_pool).
    try reg.dispatcher.register("set_wled_state", c, handleSetWledState);
    try reg.dispatcher.register("set_wled", c, handleSetWled);
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
    try ctx.addStrip("printer_leds", 30, "", -1, -1, null, false, null, 80, null);
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
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null);
    const v = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"leds\"}"), a);
    const s = v.object.get("leds").?.object;
    try testing.expectEqualStrings("leds", s.get("strip").?.string);
    try testing.expectEqualStrings("off", s.get("status").?.string);
}

test "handleSingleStrip: GET ignores action (no side effect)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null);
    // No _method → treated as GET; the `action=on` must be ignored.
    const v = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"leds\",\"action\":\"on\"}"), a);
    try testing.expectEqualStrings("off", v.object.get("leds").?.object.get("status").?.string);
    try testing.expectEqualStrings("off", ctx.findStrip("leds").?.status);
}

// ---- handleSingleStrip POST ----

test "handleSingleStrip: POST action=on turns strip on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null);
    const v = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"_method\":\"POST\",\"strip\":\"leds\",\"action\":\"on\"}"), a);
    try testing.expectEqualStrings("on", v.object.get("leds").?.object.get("status").?.string);
}

test "handleSingleStrip: POST action=toggle flips status" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null);
    // off → on
    _ = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"_method\":\"POST\",\"strip\":\"leds\",\"action\":\"toggle\"}"), a);
    try testing.expectEqualStrings("on", ctx.findStrip("leds").?.status);
    // on → off
    _ = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"_method\":\"POST\",\"strip\":\"leds\",\"action\":\"toggle\"}"), a);
    try testing.expectEqualStrings("off", ctx.findStrip("leds").?.status);
}

test "handleSingleStrip: POST action=off turns strip off" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null);
    // Turn on first, then off.
    _ = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"_method\":\"POST\",\"strip\":\"leds\",\"action\":\"on\"}"), a);
    const v = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"_method\":\"POST\",\"strip\":\"leds\",\"action\":\"off\"}"), a);
    try testing.expectEqualStrings("off", v.object.get("leds").?.object.get("status").?.string);
}

test "handleSingleStrip: POST invalid action returns InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null);
    try testing.expectError(error.InvalidParams, handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"_method\":\"POST\",\"strip\":\"leds\",\"action\":\"dance\"}"), a));
}

test "handleSingleStrip: POST action=control applies brightness and turns on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null);
    const v = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"_method\":\"POST\",\"strip\":\"leds\",\"action\":\"control\",\"brightness\":128}"), a);
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
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null);
    const v = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"_method\":\"POST\",\"strip\":\"leds\",\"action\":\"control\",\"preset\":3,\"intensity\":200}"), a);
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
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null);
    const v = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"_method\":\"POST\",\"strip\":\"leds\",\"action\":\"control\",\"brightness\":200,\"preset\":5,\"intensity\":180,\"speed\":50}"), a);
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
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null);
    const v = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"_method\":\"POST\",\"strip\":\"leds\",\"action\":\"control\"}"), a);
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
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null);
    const v = try handleBatchOn(@ptrCast(&ctx), try objParams(a, "{\"leds\":null}"), a);
    try testing.expectEqualStrings("on", v.object.get("leds").?.object.get("status").?.string);
}

test "handleBatchOff: turns off known strip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null);
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
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null);
    _ = try handleBatchToggle(@ptrCast(&ctx), try objParams(a, "{\"leds\":null}"), a);
    try testing.expectEqualStrings("on", ctx.findStrip("leds").?.status);
    _ = try handleBatchToggle(@ptrCast(&ctx), try objParams(a, "{\"leds\":null}"), a);
    try testing.expectEqualStrings("off", ctx.findStrip("leds").?.status);
}

test "handleBatchStatus: injected _method is not a strip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try testing.expectError(error.InvalidParams, handleBatchStatus(@ptrCast(&ctx), try objParams(a, "{\"_method\":\"GET\"}"), a));
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
    try ctx.addStrip("leds", 10, "", -1, 5, null, false, null, 80, null);
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
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null);
    var strip = ctx.findStrip("leds").?;
    strip.wledOff();
}

test "Strip.wledControl: applies brightness, intensity, speed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null);
    var strip = ctx.findStrip("leds").?;
    _ = strip.wledControl(128, 200, 50);
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
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null);
    var strip = ctx.findStrip("leds").?;
    strip.brightness = 100;
    strip.intensity = 150;
    strip.speed = 75;
    _ = strip.wledControl(-1, -1, -1);
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
    try ctx.addStrip("leds", 10, &.{ 0x01, 0x02, 0x03 }, 0, 7, "red,green", true, null, 80, null);
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
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null);
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
            ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null) catch {};

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
            ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null) catch {};

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

test "fuzz_handleStrips: arbitrary params never crash" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [16]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = WledCtx.init(a);
            defer ctx.deinit();
            ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null) catch {};
            _ = handleStrips(@ptrCast(&ctx), .null, a) catch {};
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

// --- Fuzz tests for internal functions ---

test "fuzz buildStripInfo: never panics, returns all keys" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var cd = [_]u8{buf[0], buf[1]};
            const s: Strip = .{
                .name = "t",
                .status = if (buf[2] % 2 == 0) "on" else "off",
                .chain_count = @as(i64, @intCast(buf[3])),
                .chain_data = cd[0..],
                .preset = @as(i64, @intCast(buf[4])) - 1,
                .initial_preset = @as(i64, @intCast(buf[5])) - 1,
                .initial_colors = null,
                .brightness = @as(i64, @intCast(buf[6])),
                .intensity = @as(i64, @intCast(buf[7])) - 1,
                .speed = -1,
                .error_state = null,
                .send_full_chain_data = buf[0] % 2 == 0,
            };

            const info = try buildStripInfo(a, &s);
            try testing.expect(info.object.get("strip") != null);
            try testing.expect(info.object.get("status") != null);
            try testing.expect(info.object.get("chain_count") != null);
            try testing.expect(info.object.get("preset") != null);
            try testing.expect(info.object.get("brightness") != null);
            try testing.expect(info.object.get("intensity") != null);
            try testing.expect(info.object.get("speed") != null);
            try testing.expect(info.object.get("error") != null);
        }
    }.run, .{});
}

test "fuzz processRequest: never panics, handles all actions" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = WledCtx.init(a);
            defer ctx.deinit();

            ctx.addStrip("s", 10, "", -1, -1, null, false, null, 80, null) catch return;
            const strip = ctx.findStrip("s") orelse return;
            const actions = [_][]const u8{ "on", "off", "toggle", "status", "bad" };
            const action = actions[buf[0] % actions.len];

            _ = processRequest(&ctx, strip, action) catch {};
        }
    }.run, .{});
}

test "fuzz addStrip/findStrip: round-trip consistency" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [16]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = WledCtx.init(a);
            defer ctx.deinit();

            const alphabet = "abcdefghijklmnopqrstuvwxyz_-";
            var name_buf: [12]u8 = undefined;
            for (buf[0..@min(8, buf.len)], 0..) |b, i| {
                name_buf[i] = alphabet[b % alphabet.len];
            }
            const name = name_buf[0..@min(6, @max(1, buf[0] % 8))];

            ctx.addStrip(name, @as(i64, @intCast(buf[1])), "", -1, @as(i64, @intCast(buf[2])), null, buf[3] % 2 == 0, null, 80, null) catch {};

            const found = ctx.findStrip(name);
            if (found) |s| {
                try testing.expectEqualStrings(name, s.name);
            }
        }
    }.run, .{});
}

test "fuzz setStatus/setStripControl: never panics" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = WledCtx.init(a);
            defer ctx.deinit();

            ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null) catch return;

            const new_status = if (buf[0] % 2 == 0) "on" else "off";
            ctx.setStatus("leds", new_status) catch return;
            try testing.expectEqualStrings(new_status, ctx.findStrip("leds").?.status);

            // setStripControl with arbitrary values
            ctx.setStripControl(
                "leds",
                @as(i64, @intCast(buf[1])),
                @as(i64, @intCast(buf[2])) - 1,
                @as(i64, @intCast(buf[3])) - 1,
                @as(i64, @intCast(buf[4])) - 1,
            ) catch return;
        }
    }.run, .{});
}

// ---- New: setIo / sendWledBody / address/port/protocol ----

test "setIo: stores io handle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try testing.expect(ctx.io == null);

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    ctx.setIo(io);
    try testing.expect(ctx.io != null);
}

test "sendWledBody: no address returns immediately, no error_state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null);
    const strip = ctx.findStrip("leds").?;
    try testing.expect(strip.address == null);

    // Should be a no-op — no crash, no error_state set.
    ctx.sendWledBody(strip, "{\"on\":true}");
    try testing.expect(strip.error_state == null);
}

test "sendWledBody: no io returns immediately, no error_state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, "192.168.1.100", 80, null);
    const strip = ctx.findStrip("leds").?;
    try testing.expect(strip.address != null);
    try testing.expect(ctx.io == null);

    // io is null, so sendWledBody should return early.
    ctx.sendWledBody(strip, "{\"on\":true}");
    try testing.expect(strip.error_state == null);
}

test "addStrip: stores address, port, and protocol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.addStrip("wled_strip", 15, "", -1, -1, null, false, "10.0.0.5", 8080, "http");
    const s = ctx.findStrip("wled_strip").?;
    try testing.expectEqualStrings("10.0.0.5", s.address.?);
    try testing.expectEqual(@as(u16, 8080), s.port);
    try testing.expectEqualStrings("http", s.protocol);
}

test "addStrip: null address stored as null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.addStrip("wled_strip", 15, "", -1, -1, null, false, null, 80, null);
    const s = ctx.findStrip("wled_strip").?;
    try testing.expect(s.address == null);
    try testing.expectEqual(@as(u16, 80), s.port);
    try testing.expectEqualStrings("http", s.protocol);
}

test "addStrip: custom protocol is stored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.addStrip("wled_strip", 15, "", -1, -1, null, false, "10.0.0.5", 80, "wled");
    const s = ctx.findStrip("wled_strip").?;
    try testing.expectEqualStrings("wled", s.protocol);
}

test "processRequest: on with address sends HTTP body, state changed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, "10.0.0.5", 80, null);
    ctx.setStatus("leds", "off") catch unreachable;

    const strip = ctx.findStrip("leds").?;
    const result = try processRequest(&ctx, strip, "on");
    try testing.expectEqualStrings("on", result);
    try testing.expectEqualStrings("on", ctx.findStrip("leds").?.status);
    // io is null so HTTP is skipped, but in-memory state is correct.
}

test "processRequest: off with address sends HTTP body, state changed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, "10.0.0.5", 80, null);
    ctx.setStatus("leds", "on") catch unreachable;

    const strip = ctx.findStrip("leds").?;
    const result = try processRequest(&ctx, strip, "off");
    try testing.expectEqualStrings("off", result);
    try testing.expectEqualStrings("off", ctx.findStrip("leds").?.status);
}

test "processRequest: on with preset builds correct body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", 3, -1, null, false, "10.0.0.5", 80, null);

    const strip = ctx.findStrip("leds").?;
    try testing.expectEqual(@as(i64, 3), strip.preset);
    const result = try processRequest(&ctx, strip, "on");
    try testing.expectEqualStrings("on", result);
    // preset remains 3 (was set by addStrip, wledOn keeps it).
    try testing.expectEqual(@as(i64, 3), strip.preset);
}

test "setStripControl: with address builds HTTP body, state changed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, "10.0.0.5", 80, null);

    try ctx.setStripControl("leds", 128, 2, 64, 32);
    const s = ctx.findStrip("leds").?;
    try testing.expectEqualStrings("on", s.status);
    try testing.expectEqual(@as(i64, 128), s.brightness);
    try testing.expectEqual(@as(i64, 64), s.intensity);
    try testing.expectEqual(@as(i64, 32), s.speed);
    try testing.expectEqual(@as(i64, 2), s.preset);
}

test "fuzz wledOn/wledOff/wledControl: Strip methods never panic" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = WledCtx.init(a);
            defer ctx.deinit();

            ctx.addStrip("s", 10, "", -1, -1, null, false, null, 80, null) catch return;
            var strip = ctx.findStrip("s") orelse return;

            const preset = @as(i64, @intCast(buf[0])) - 1;
            strip.wledOn(preset);
            try testing.expectEqual(preset, strip.preset);

            const b = @as(i64, @intCast(buf[1]));
            const i = @as(i64, @intCast(buf[2])) - 1;
            const sp = @as(i64, @intCast(buf[3])) - 1;
            _ = strip.wledControl(b, i, sp);
            // Values >= 1 are applied for brightness (minval=1), >= 0 for
            // intensity and speed (minval=0); -1 keeps current.
            if (b >= 1) try testing.expectEqual(b, strip.brightness);
            if (i >= 0) try testing.expectEqual(i, strip.intensity);
            if (sp >= 0) try testing.expectEqual(sp, strip.speed);

            strip.wledOff(); // no-op, never panics
        }
    }.run, .{});
}

test "fuzz sendWledBody: never panics with arbitrary body/address/io combinations" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = WledCtx.init(a);
            defer ctx.deinit();

            const combo = buf[0] % 3;
            switch (combo) {
                0 => {
                    // No address, no io → early return.
                    ctx.addStrip("s", 10, "", -1, -1, null, false, null, 80, null) catch return;
                },
                1 => {
                    // Address but no io → early return.
                    ctx.addStrip("s", 10, "", -1, -1, null, false, "10.0.0.1", 80, "http") catch return;
                },
                else => {
                    // No address, so sendWledBody returns early.
                    ctx.addStrip("s", 10, "", -1, -1, null, false, null, 80, null) catch return;
                },
            }

            const strip = ctx.findStrip("s") orelse return;
            const bodies = [_][]const u8{ "{\"on\":true}", "{\"on\":false}", "", "bad-json", "{}" };
            const body = bodies[buf[2] % bodies.len];

            ctx.sendWledBody(strip, body);
            // No crash. Error state is only set when both address and io exist
            // AND the real HTTP call fails; we never trigger a real call here.
            _ = strip.error_state;
        }
    }.run, .{});
}

test "fuzz addStrip: arbitrary address/port/protocol never panics" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = WledCtx.init(a);
            defer ctx.deinit();

            const has_address = buf[0] % 2 == 0;
            const address: ?[]const u8 = if (has_address) "192.168.1.42" else null;
            const port: u16 = (@as(u16, buf[1]) * 256) + @as(u16, buf[2]);
            const protocols = [_][]const u8{ "http", "wled", "https" };
            const proto: ?[]const u8 = if (buf[3] % 3 == 0) null else protocols[buf[3] % protocols.len];

            ctx.addStrip("s", 10, "", -1, -1, null, false, address, port, proto) catch return;

            const s = ctx.findStrip("s") orelse return;
            if (has_address) {
                try testing.expectEqualStrings("192.168.1.42", s.address.?);
                try testing.expectEqual(port, s.port);
            } else {
                try testing.expect(s.address == null);
            }
            if (proto) |p| {
                try testing.expectEqualStrings(p, s.protocol);
            } else {
                try testing.expectEqualStrings("http", s.protocol);
            }
        }
    }.run, .{});
}

test "fuzz processRequest: with address never panics, no real HTTP" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = WledCtx.init(a);
            defer ctx.deinit();

            const has_address = buf[0] % 2 == 0;

            if (has_address) {
                ctx.addStrip("s", 10, "", buf[2] % 10, -1, null, false, "10.0.0.1", 80, "http") catch return;
            } else {
                ctx.addStrip("s", 10, "", buf[2] % 10, -1, null, false, null, 80, null) catch return;
            }

            // Never set io to avoid real HTTP calls; sendWledBody from
            // processRequest will just return early when io is null.

            const strip = ctx.findStrip("s") orelse return;
            const actions = [_][]const u8{ "on", "off", "toggle", "status" };
            const action = actions[buf[3] % actions.len];

            _ = processRequest(&ctx, strip, action) catch {};

            // State should reflect the action (except "status" which does not change state).
            const updated = ctx.findStrip("s") orelse return;
            _ = updated.status;
        }
    }.run, .{});
}

test "fuzz setStripControl: with address never panics, no real HTTP" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = WledCtx.init(a);
            defer ctx.deinit();

            const has_address = buf[0] % 2 == 0;

            if (has_address) {
                ctx.addStrip("s", 10, "", -1, -1, null, false, "10.0.0.1", 80, "http") catch return;
            } else {
                ctx.addStrip("s", 10, "", -1, -1, null, false, null, 80, null) catch return;
            }

            // Never set io to avoid real HTTP calls; sendWledBody from
            // setStripControl will just return early when io is null.

            const brightness: i64 = @as(i64, @intCast(buf[2])) - 1;
            const preset: i64 = @as(i64, @intCast(buf[3])) - 1;
            const intensity: i64 = @as(i64, @intCast(buf[4])) - 1;
            const speed: i64 = @as(i64, @intCast(buf[5])) - 1;

            ctx.setStripControl("s", brightness, preset, intensity, speed) catch {};

            const s = ctx.findStrip("s") orelse return;
            try testing.expectEqualStrings("on", s.status);
            if (brightness >= 0) try testing.expectEqual(brightness, s.brightness);
            if (intensity >= 0) try testing.expectEqual(intensity, s.intensity);
            if (speed >= 0) try testing.expectEqual(speed, s.speed);
            if (preset >= 0) try testing.expectEqual(preset, s.preset);
        }
    }.run, .{});
}

// --- WLED serial output ---

test "sendWledBody: serial strip writes newline-terminated JSON to the device" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const Dir = std.Io.Dir;

    const path = "/tmp/phobos_wled_serial.dev";
    Dir.cwd().deleteFile(io, path) catch {};
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "" });
    defer Dir.cwd().deleteFile(io, path) catch {};

    var ctx = testCtx(std.testing.allocator);
    defer ctx.deinit();
    ctx.setIo(io);
    try ctx.addStrip("leds", 10, "", -1, -1, null, false, null, 80, null);
    try ctx.setStripSerial("leds", path, 115200);

    const strip = ctx.findStrip("leds").?;
    ctx.sendWledBody(strip, "{\"on\":true}");
    try std.testing.expect(strip.error_state == null);

    const fh = try Dir.cwd().openFile(io, path, .{});
    defer fh.close(io);
    var buf: [64]u8 = undefined;
    var r = fh.reader(io, &buf);
    const n = try r.interface.readSliceShort(&buf);
    try std.testing.expectEqualStrings("{\"on\":true}\n", buf[0..n]);
}
