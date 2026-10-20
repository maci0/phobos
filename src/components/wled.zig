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
//! plus `set_wled_state` and `set_wled` as client and Klippy remote methods.
//!
//! `type: http` strips POST WLED JSON state to `{protocol}://{address}:{port}/json`
//! within the strip `timeout`; `type: serial` strips write the same JSON to the
//! `serial` device at `baud`, retaining one port and a joined reply reader. A strip added without a transport keeps its state
//! in memory only. The state rules (wled_on, wled_off, wled_control, set_wled,
//! _set_initial_state) follow wled.py. A failed send sets `error` and fails the
//! request. An owned startup worker queries state and retries failed strips for
//! 120 seconds; each HTTP command makes up to three attempts.
//!
//! CORE LOCK. Handlers run under Core; a send releases it for the device I/O and
//! re-resolves the strip by name afterwards.
//!
//! STRIPS FROM CONFIG. Without `[wled <name>]` config sections (the spine
//! carries none), the strips map is empty and the list endpoint returns {}.
//! Strip-specific requests return a not-found error.

const std = @import("std");
const webreq = @import("../json/params.zig");
const jv = @import("../json/value.zig");
const registry = @import("../server/registry.zig");
const Core = @import("../server/core.zig").Core;
const power = @import("power.zig");
const serial_mod = @import("serial.zig");
const sleep = @import("../util/sleep.zig");
const jsonrpc = @import("../jsonrpc.zig");

const Registry = registry.Registry;

/// Moonraker StripHttp `timeout` default (wled.py).
pub const default_timeout: std.Io.Duration = .fromSeconds(2);
/// Moonraker StripSerial default `baud` (wled.py `from_config(config, 115200)`).
pub const default_baud: u32 = 115200;
/// Bound a verbose WLED state reply without retaining it after validation.
const max_reply_bytes = 16 * 1024;
const http_attempts = 3;
const http_retry_pause: std.Io.Duration = .fromMilliseconds(100);
const init_retry_pause: std.Io.Duration = .fromSeconds(2);
const init_retry_time: std.Io.Duration = .fromSeconds(120);
const serial_idle_pause: std.Io.Duration = .fromMilliseconds(10);

/// A stable, pinned serial port. Core protects strip state; this mutex protects
/// a command and its reply while Core is released.
const SerialLink = struct {
    gpa: std.mem.Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    mutex: std.Io.Mutex = .init,
    port: ?serial_mod.Serial = null,
    reader: ?std.Thread = null,
    stop: std.Io.Event = .unset,
    reply_ready: std.Io.Event = .unset,
    waiting: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    fn create(gpa: std.mem.Allocator) !*SerialLink {
        const self = try gpa.create(SerialLink);
        self.* = .{ .gpa = gpa };
        return self;
    }

    fn retain(self: *SerialLink) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    fn release(self: *SerialLink) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.closePort();
        self.gpa.destroy(self);
    }

    fn closePort(self: *SerialLink) void {
        const port = if (self.port) |*port| port else return;
        self.stop.set(port.io);
        if (self.reader) |reader| reader.join();
        self.reader = null;
        port.close();
        self.port = null;
    }

    fn readReplies(self: *SerialLink) void {
        const port = &self.port.?;
        var reply: [max_reply_bytes]u8 = undefined;
        var len: usize = 0;
        var dropping = false;
        while (!self.stop.isSet()) {
            const n = port.readSome(reply[len..]) catch {
                self.failed.store(true, .release);
                self.reply_ready.set(port.io);
                return;
            };
            if (n == 0 and sleep.untilStopped(port.io, serial_idle_pause, &self.stop)) return;
            len += n;
            while (std.mem.indexOfScalar(u8, reply[0..len], '\n')) |end| {
                const line = std.mem.trim(u8, reply[0..end], " \r\t");
                if (!dropping and self.waiting.load(.acquire)) {
                    var scratch: [4096]u8 = undefined;
                    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
                    if (std.json.validate(fixed.allocator(), line) catch false) self.reply_ready.set(port.io);
                }
                dropping = false;
                std.mem.copyForwards(u8, &reply, reply[end + 1 .. len]);
                len -= end + 1;
            }
            if (len == reply.len) {
                len = 0;
                dropping = true;
            }
        }
    }

    fn send(self: *SerialLink, io: std.Io, path: []const u8, baud: u32, timeout: std.Io.Duration, body: []const u8, query: bool) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        if (self.failed.load(.acquire)) self.closePort();
        if (self.port == null) {
            self.port = try serial_mod.Serial.open(io, path, baud);
            self.stop.reset();
            self.failed.store(false, .release);
            self.reader = std.Thread.spawn(.{ .stack_size = 1 << 20 }, readReplies, .{self}) catch |err| {
                self.closePort();
                return err;
            };
        }
        const port = &self.port.?;
        errdefer self.closePort();
        const deadline = (std.Io.Timeout{ .duration = .{ .raw = timeout, .clock = .awake } }).toDeadline(io);
        self.reply_ready.reset();
        self.waiting.store(query, .release);
        defer self.waiting.store(false, .release);
        try port.writeTimeout(body, deadline);
        if (!query) return;
        try self.reply_ready.waitTimeout(io, deadline);
        if (self.failed.load(.acquire)) return error.SerialDisconnected;
    }
};

pub const Error = error{ NotFound, OutOfMemory, DeviceRequestFailed };

/// How a strip's JSON state reaches the device.
pub const Transport = union(enum) {
    /// No device: state is kept in memory only.
    none,
    /// WLED JSON API URL, `{protocol}://{address}:{port}/json`.
    http: []const u8,
    serial: struct { path: []const u8, baud: u32 },
};

/// Strip configuration; `addStrip` copies every string.
pub const Config = struct {
    name: []const u8,
    chain_count: usize = 1,
    initial_preset: i64 = -1,
    /// initial_red, initial_green, initial_blue, initial_white.
    initial_color: [4]f64 = @splat(0.5),
    transport: Transport = .none,
    timeout: std.Io.Duration = default_timeout,
};

// ---------------------------------------------------------------------------
// Strip state
// ---------------------------------------------------------------------------

pub const Strip = struct {
    /// RGBW color size in bytes (matches Python _COLORSIZE = 4).
    pub const color_size: usize = 4;

    name: []const u8,
    on: bool = false,
    chain_count: usize,
    chain_data: []u8,
    preset: i64,
    initial_preset: i64,
    initial_color: [4]f64,
    brightness: i64 = 255,
    intensity: i64 = -1,
    speed: i64 = -1,
    error_state: ?[]const u8 = null,
    send_full_chain_data: bool = true,
    transport: Transport,
    timeout: std.Io.Duration,
    serial_link: ?*SerialLink = null,
    initialized: bool = false,

    fn deinit(self: *Strip, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.chain_data);
        if (self.error_state) |value| alloc.free(value);
        if (self.serial_link) |link| link.release();
        switch (self.transport) {
            .none => {},
            .http => |url| alloc.free(url),
            .serial => |s| alloc.free(s.path),
        }
    }

    /// Moonraker: _update_color_data(red, green, blue, white, index).
    /// Scales 0.0-1.0 to 0-255 into chain_data: the whole chain when `index`
    /// is null, else the 1-based pixel `index` (ignored when out of range).
    pub fn updateColorData(self: *Strip, color: [4]f64, index: ?usize) void {
        var led_data: [color_size]u8 = undefined;
        for (color, &led_data) |c, *byte| byte.* = @intFromFloat(@min(@max(c * 255.0 + 0.5, 0), 255));
        if (index) |idx| {
            if (idx >= 1 and idx <= self.chain_count) @memcpy(self.chain_data[(idx - 1) * color_size ..][0..color_size], &led_data);
        } else {
            for (0..self.chain_count) |i| @memcpy(self.chain_data[i * color_size ..][0..color_size], &led_data);
        }
    }

    /// Write 1-based pixel `index` as a JSON number array (wled.py `_wled_pixel`).
    fn writePixel(self: *const Strip, s: *std.json.Stringify, index: usize) std.Io.Writer.Error!void {
        try s.beginArray();
        for (self.chain_data[(index - 1) * color_size ..][0..color_size]) |byte| try s.write(byte);
        try s.endArray();
    }
};

/// Moonraker set_wled state body: `{"on":true,"tt":0,"bri":B,"seg":{"bri":B,"i":[...]}}`.
/// `i` is a range command for the whole chain when `index` is null, every
/// pixel when a full send is pending, else the single changed pixel.
/// Clears `send_full_chain_data` when it sends the whole chain.
fn setWledBody(alloc: std.mem.Allocator, strip: *Strip, index: ?usize) std.Io.Writer.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("on");
    try s.write(true);
    try s.objectField("tt");
    try s.write(0);
    try s.objectField("bri");
    try s.write(strip.brightness);
    try s.objectField("seg");
    try s.beginObject();
    try s.objectField("bri");
    try s.write(strip.brightness);
    try s.objectField("i");
    try s.beginArray();
    if (index) |idx| {
        if (strip.send_full_chain_data) {
            strip.send_full_chain_data = false;
            for (1..strip.chain_count + 1) |i| try strip.writePixel(&s, i);
        } else {
            try s.write(idx - 1);
            try strip.writePixel(&s, idx);
        }
    } else {
        strip.send_full_chain_data = false;
        try s.write(0);
        try s.write(strip.chain_count);
        try strip.writePixel(&s, 1);
    }
    try s.endArray();
    try s.endObject();
    try s.endObject();
    return out.written();
}

/// Send `body` over `transport`.
fn transmit(gpa: std.mem.Allocator, io: std.Io, transport: Transport, link: ?*SerialLink, timeout: std.Io.Duration, body: []const u8, query: bool) !void {
    switch (transport) {
        .none => {},
        .http => |url| {
            var reply: [max_reply_bytes]u8 = undefined;
            var last_error: anyerror = error.DeviceRequestFailed;
            for (0..http_attempts) |attempt| {
                if (attempt != 0) try std.Io.sleep(io, http_retry_pause, .awake);
                const result = power.deviceRequest(gpa, io, .POST, url, body, timeout, &reply) catch |err| {
                    if (err == error.Canceled) return err;
                    last_error = err;
                    continue;
                };
                if (query and !try std.json.validate(gpa, result)) return error.InvalidJson;
                return;
            }
            return last_error;
        },
        .serial => |s| {
            try link.?.send(io, s.path, s.baud, timeout, body, query);
        },
    }
}

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

pub const WledCtx = struct {
    gpa: std.mem.Allocator,
    strips: std.StringHashMap(Strip),
    io: ?std.Io = null,
    /// Held by the caller of every handler once wired; released for device I/O.
    core: ?*Core = null,
    init_thread: ?std.Thread = null,
    init_stop: std.Io.Event = .unset,

    pub fn init(alloc: std.mem.Allocator) WledCtx {
        return .{
            .gpa = alloc,
            .strips = std.StringHashMap(Strip).init(alloc),
        };
    }

    pub fn deinit(self: *WledCtx) void {
        self.stopInitialization();
        var it = self.strips.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.gpa);
        }
        self.strips.deinit();
    }

    /// Set the Io handle used for device I/O.
    pub fn setIo(self: *WledCtx, io: std.Io) void {
        self.io = io;
    }

    pub fn findStrip(self: *WledCtx, name: []const u8) ?*Strip {
        return self.strips.getPtr(name);
    }

    /// Add or replace a strip, copying all configuration strings.
    pub fn addStrip(self: *WledCtx, config: Config) !void {
        const k = try self.gpa.dupe(u8, config.name);
        errdefer self.gpa.free(k);
        var strip: Strip = .{
            .name = "",
            .chain_count = config.chain_count,
            .chain_data = &.{},
            .preset = config.initial_preset,
            .initial_preset = config.initial_preset,
            .initial_color = config.initial_color,
            .transport = .none,
            .timeout = config.timeout,
        };
        errdefer strip.deinit(self.gpa);
        strip.name = try self.gpa.dupe(u8, config.name);
        strip.chain_data = try self.gpa.alloc(u8, try std.math.mul(usize, config.chain_count, Strip.color_size));
        @memset(strip.chain_data, 0);
        // Copy into a local first: assigning the union directly would set the
        // tag before a failed dupe, and the errdefer would free garbage.
        const transport: Transport = switch (config.transport) {
            .none => .none,
            .http => |url| .{ .http = try self.gpa.dupe(u8, url) },
            .serial => |s| .{ .serial = .{ .path = try self.gpa.dupe(u8, s.path), .baud = s.baud } },
        };
        strip.transport = transport;
        if (transport == .serial) strip.serial_link = try SerialLink.create(self.gpa);
        if (try self.strips.fetchPut(k, strip)) |prior| {
            self.gpa.free(k); // Replacements retain the map's existing key.
            var old = prior.value;
            old.deinit(self.gpa);
        }
    }

    /// One initialization pass. Core must be held when wired. Failed strips
    /// retain their error and are retried by the startup worker.
    pub fn applyInitialStates(self: *WledCtx) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var names: std.ArrayList([]const u8) = .empty;
        var it = self.strips.keyIterator();
        while (it.next()) |k| names.append(a, a.dupe(u8, k.*) catch return) catch return;
        for (names.items) |name| {
            if (self.init_stop.isSet()) return;
            const strip = self.findStrip(name) orelse continue;
            if (strip.initialized) continue;
            _ = self.commandQuery(a, name, "{\"v\":true}", true) catch continue;
            self.setInitialState(a, name) catch continue;
            if (self.findStrip(name)) |fresh| fresh.initialized = true;
        }
    }

    pub fn startInitialization(self: *WledCtx) !void {
        if (self.init_thread != null or self.io == null or self.core == null or self.strips.count() == 0) return;
        self.init_stop.reset();
        self.init_thread = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, initializationLoop, .{self});
    }

    pub fn stopInitialization(self: *WledCtx) void {
        if (self.io) |io| self.init_stop.set(io);
        if (self.init_thread) |thread| thread.join();
        self.init_thread = null;
    }

    fn initializationLoop(self: *WledCtx) void {
        const io = self.io.?;
        const core = self.core.?;
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        while (!self.init_stop.isSet() and start.untilNow(io).raw.nanoseconds < init_retry_time.nanoseconds) {
            core.run(io, applyInitialStates, .{self});
            const complete = core.run(io, initializationComplete, .{self});
            if (complete or sleep.untilStopped(io, init_retry_pause, &self.init_stop)) return;
        }
    }

    fn initializationComplete(self: *WledCtx) bool {
        var it = self.strips.valueIterator();
        while (it.next()) |strip| if (!strip.initialized) return false;
        return true;
    }

    /// Send `body` to strip `name` with Core released, record the outcome in
    /// `error` (Moonraker `_send_wled_command`) and return the re-resolved
    /// strip. `name` must not borrow from a strip. Without io nothing is sent.
    fn command(self: *WledCtx, alloc: std.mem.Allocator, name: []const u8, body: []const u8) Error!*Strip {
        return self.commandQuery(alloc, name, body, false);
    }

    fn commandQuery(self: *WledCtx, alloc: std.mem.Allocator, name: []const u8, body: []const u8, query: bool) Error!*Strip {
        const strip = self.findStrip(name) orelse return error.NotFound;
        const io = self.io orelse return strip;
        const transport: Transport = switch (strip.transport) {
            .none => return strip,
            .http => |url| .{ .http = try alloc.dupe(u8, url) },
            .serial => |s| .{ .serial = .{ .path = try alloc.dupe(u8, s.path), .baud = s.baud } },
        };
        const timeout = strip.timeout;
        const link = strip.serial_link;
        if (link) |pinned| pinned.retain();
        defer if (link) |pinned| pinned.release();
        const result = blk: {
            if (self.core) |core| core.unlock(io);
            defer if (self.core) |core| core.lock(io);
            break :blk transmit(self.gpa, io, transport, link, timeout, body, query);
        };
        const fresh = self.findStrip(name) orelse return error.NotFound;
        if (fresh.error_state) |e| self.gpa.free(e);
        fresh.error_state = null;
        result catch |err| {
            fresh.error_state = try std.fmt.allocPrint(self.gpa, "WLED: Error {s}", .{@errorName(err)});
            return error.DeviceRequestFailed;
        };
        return fresh;
    }

    fn requestError(self: *WledCtx, alloc: std.mem.Allocator, params: std.json.Value, name: []const u8, err: anyerror) anyerror {
        if (err != error.DeviceRequestFailed or params != .object or !params.object.contains("_method")) return err;
        const strip = self.findStrip(name) orelse return err;
        const message = strip.error_state orelse return err;
        jsonrpc.setErrorReply(alloc, params, .bad_request, message) catch |failure| return failure;
        return error.UpstreamRequestFailed;
    }

    /// Moonraker wled_on(preset): a negative preset restores the initial state.
    fn wledOn(self: *WledCtx, alloc: std.mem.Allocator, name: []const u8, preset: i64) Error!void {
        const strip = self.findStrip(name) orelse return error.NotFound;
        strip.on = true;
        if (preset < 0) return self.setInitialState(alloc, name);
        strip.send_full_chain_data = true;
        strip.preset = preset;
        // Without reading the data back from wled the values are unknown.
        strip.brightness = -1;
        strip.intensity = -1;
        strip.speed = -1;
        _ = try self.command(alloc, name, try std.fmt.allocPrint(alloc, "{{\"on\":true,\"ps\":{d}}}", .{preset}));
    }

    /// Moonraker wled_off().
    fn wledOff(self: *WledCtx, alloc: std.mem.Allocator, name: []const u8) Error!void {
        const strip = self.findStrip(name) orelse return error.NotFound;
        strip.on = false;
        // Without this a SET_WLED for one pixel after WLED_OFF sends only that pixel.
        strip.send_full_chain_data = true;
        _ = try self.command(alloc, name, "{\"on\":false}");
    }

    /// Moonraker _set_initial_state().
    fn setInitialState(self: *WledCtx, alloc: std.mem.Allocator, name: []const u8) Error!void {
        const strip = self.findStrip(name) orelse return error.NotFound;
        strip.send_full_chain_data = true;
        strip.on = true;
        strip.preset = strip.initial_preset;
        strip.brightness = 255;
        strip.intensity = -1;
        strip.speed = -1;
        if (strip.initial_preset >= 0) {
            strip.updateColorData(strip.initial_color, null);
            return self.wledOn(alloc, name, strip.initial_preset);
        }
        return self.setWled(alloc, name, strip.initial_color, null, true);
    }

    /// Moonraker wled_control(brightness, intensity, speed): only on a lit
    /// strip; `bri` for 1..255, segment `ix`/`sx` for 0..255 with a preset.
    fn wledControl(self: *WledCtx, alloc: std.mem.Allocator, name: []const u8, brightness: i64, intensity: i64, speed: i64) Error!void {
        const strip = self.findStrip(name) orelse return error.NotFound;
        if (!strip.on) return;
        const with_preset = strip.preset != -1;
        const set_bri = brightness > 0 and brightness <= 255;
        const set_ix = with_preset and intensity > -1 and intensity <= 255;
        const set_sx = with_preset and speed > -1 and speed <= 255;
        if (!set_bri and !set_ix and !set_sx) return;
        if (set_bri) strip.brightness = brightness;
        if (set_ix) strip.intensity = intensity;
        if (set_sx) strip.speed = speed;
        var out: std.Io.Writer.Allocating = .init(alloc);
        var s: std.json.Stringify = .{ .writer = &out.writer };
        controlBody(&s, strip, set_bri, set_ix, set_sx) catch return error.OutOfMemory;
        _ = try self.command(alloc, name, out.written());
    }

    fn controlBody(s: *std.json.Stringify, strip: *const Strip, set_bri: bool, set_ix: bool, set_sx: bool) std.Io.Writer.Error!void {
        try s.beginObject();
        try s.objectField("tt");
        try s.write(0);
        // Even without an active preset, sending seg {} turns it back on.
        if (strip.preset != -1) {
            try s.objectField("seg");
            try s.beginObject();
            if (set_bri) {
                try s.objectField("bri");
                try s.write(strip.brightness);
            }
            if (set_ix) {
                try s.objectField("ix");
                try s.write(strip.intensity);
            }
            if (set_sx) {
                try s.objectField("sx");
                try s.write(strip.speed);
            }
            try s.endObject();
        }
        if (set_bri) {
            try s.objectField("bri");
            try s.write(strip.brightness);
        }
        try s.endObject();
    }

    /// Moonraker set_wled(red, green, blue, white, index, transmit).
    fn setWled(self: *WledCtx, alloc: std.mem.Allocator, name: []const u8, color: [4]f64, index: ?usize, transmit_now: bool) Error!void {
        const strip = self.findStrip(name) orelse return error.NotFound;
        strip.updateColorData(color, index);
        if (!transmit_now) {
            // Send all data on the next transmit.
            strip.send_full_chain_data = true;
            return;
        }
        // Clear the preset: sending seg {} would revert to it.
        strip.preset = -1;
        if (strip.brightness == -1) strip.brightness = 255;
        const body = setWledBody(alloc, strip, index) catch return error.OutOfMemory;
        const fresh = try self.command(alloc, name, body);
        if (!fresh.on) {
            // WLED needs a repeated command to light an off strip.
            fresh.on = true;
            _ = try self.command(alloc, name, body);
        }
    }
};

// ---------------------------------------------------------------------------
// Param helpers
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Strip info shape
// ---------------------------------------------------------------------------

/// Build the per-strip info object matching Strip.get_strip_info():
///   { strip, status, chain_count, preset, brightness, intensity, speed, error }
pub fn buildStripInfo(alloc: std.mem.Allocator, s: *const Strip) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "strip", .{ .string = try alloc.dupe(u8, s.name) });
    try obj.put(alloc, "status", .{ .string = if (s.on) "on" else "off" });
    // chain_data holds chain_count * 4 bytes, so the count fits in i64.
    try obj.put(alloc, "chain_count", .{ .integer = @intCast(s.chain_count) });
    try obj.put(alloc, "preset", .{ .integer = s.preset });
    try obj.put(alloc, "brightness", .{ .integer = s.brightness });
    try obj.put(alloc, "intensity", .{ .integer = s.intensity });
    try obj.put(alloc, "speed", .{ .integer = s.speed });
    try obj.put(alloc, "error", if (s.error_state) |e| .{ .string = try alloc.dupe(u8, e) } else .null);
    return .{ .object = obj };
}

// ---------------------------------------------------------------------------
// Action helpers
// ---------------------------------------------------------------------------

/// Moonraker _process_request: apply "status" | "on" | "off" | "toggle" |
/// "control" to strip `name` (not borrowed from a strip).
fn processRequest(
    ctx: *WledCtx,
    alloc: std.mem.Allocator,
    name: []const u8,
    req: []const u8,
    preset: i64,
    brightness: i64,
    intensity: i64,
    speed: i64,
) (Error || error{InvalidParams})!void {
    const strip = ctx.findStrip(name) orelse return error.NotFound;
    if (std.mem.eql(u8, req, "status")) return;
    const action: []const u8 = if (std.mem.eql(u8, req, "toggle")) (if (strip.on) "off" else "on") else req;
    if (std.mem.eql(u8, action, "off")) return ctx.wledOff(alloc, name);
    const is_on = std.mem.eql(u8, action, "on");
    if (!is_on and !std.mem.eql(u8, action, "control")) return error.InvalidParams;
    if (is_on) try ctx.wledOn(alloc, name, preset);
    if (brightness != -1 or intensity != -1 or speed != -1) try ctx.wledControl(alloc, name, brightness, intensity, speed);
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
/// POST → requires `action` in [on|off|toggle|control] and applies the
/// request's preset/brightness/intensity/speed; returns { "<strip>": strip_info }.
pub fn handleSingleStrip(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *WledCtx = @ptrCast(@alignCast(ctx_ptr));
    const strip_name = try webreq.required([]const u8, params, "strip");
    // Matches Moonraker: "No valid strip named <x>"
    if (ctx.findStrip(strip_name) == null) return error.NotFound;
    // GET is read-only: only POST reads `action` (Moonraker
    // _handle_single_wled_request), so GET ?action=on cannot drive hardware.
    const is_post = if ((try webreq.optional([]const u8, params, "_method"))) |m| std.mem.eql(u8, m, "POST") else false;
    if (is_post) {
        const a = (try webreq.optional([]const u8, params, "action")) orelse return error.InvalidParams;
        const action = try std.ascii.allocLowerString(alloc, a);
        if (!std.mem.eql(u8, action, "on") and
            !std.mem.eql(u8, action, "off") and
            !std.mem.eql(u8, action, "toggle") and
            !std.mem.eql(u8, action, "control"))
        {
            return error.InvalidParams;
        }
        processRequest(
            ctx,
            alloc,
            strip_name,
            action,
            ((try webreq.optional(i64, params, "preset")) orelse -1),
            ((try webreq.optional(i64, params, "brightness")) orelse -1),
            ((try webreq.optional(i64, params, "intensity")) orelse -1),
            ((try webreq.optional(i64, params, "speed")) orelse -1),
        ) catch |err| return ctx.requestError(alloc, params, strip_name, err);
    }
    const strip = ctx.findStrip(strip_name) orelse return error.NotFound;
    var out: std.json.ObjectMap = .empty;
    try out.put(alloc, strip_name, try buildStripInfo(alloc, strip));
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
            var it = obj.iterator();
            while (it.next()) |entry| {
                const name = entry.key_ptr.*;
                // HTTP injects `_method` into every route. It is not a strip.
                if (std.mem.startsWith(u8, name, "_")) continue;
                if (ctx.findStrip(name) != null) {
                    processRequest(ctx, alloc, name, action, -1, -1, -1, -1) catch |err|
                        return ctx.requestError(alloc, params, name, err);
                    const strip = ctx.findStrip(name) orelse return error.NotFound;
                    try out.put(alloc, name, try buildStripInfo(alloc, strip));
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
    const strip_name = try webreq.required([]const u8, params, "strip");
    if (ctx.findStrip(strip_name) == null) return error.NotFound;

    // `state` may be a bool or a string; "true"/"false" map to on/off.
    var status: ?[]const u8 = null;
    if (params == .object) if (params.object.get("state")) |sv| switch (sv) {
        .bool => |b| status = if (b) "on" else "off",
        .string => |s| {
            const sl = try std.ascii.allocLowerString(alloc, s);
            status = if (std.mem.eql(u8, sl, "true")) "on" else if (std.mem.eql(u8, sl, "false")) "off" else sl;
        },
        else => {},
    };

    const preset = ((try webreq.optional(i64, params, "preset")) orelse -1);
    const brightness = ((try webreq.optional(i64, params, "brightness")) orelse -1);
    const intensity = ((try webreq.optional(i64, params, "intensity")) orelse -1);
    const speed = ((try webreq.optional(i64, params, "speed")) orelse -1);

    var out: std.json.ObjectMap = .empty;
    try out.put(alloc, "status", .{ .string = "ok" });
    // Moonraker: nothing to do without a state, preset or control data.
    if (status == null and preset == -1 and brightness == -1 and intensity == -1 and speed == -1) {
        return .{ .object = out };
    }
    const s = status orelse "";
    // All other arguments are ignored when turning off.
    if (std.mem.eql(u8, s, "off")) ctx.wledOff(alloc, strip_name) catch |err| return ctx.requestError(alloc, params, strip_name, err);
    // Turn on if status is "on" or a preset is specified.
    if (std.mem.eql(u8, s, "on") or preset != -1) ctx.wledOn(alloc, strip_name, preset) catch |err| return ctx.requestError(alloc, params, strip_name, err);
    if (brightness != -1 or intensity != -1 or speed != -1) ctx.wledControl(alloc, strip_name, brightness, intensity, speed) catch |err| return ctx.requestError(alloc, params, strip_name, err);
    return .{ .object = out };
}

/// Moonraker: set_wled(strip, red, green, blue, white, index, transmit).
/// Individual pixel control for compatibility with SET_LED. `index` is
/// 1-based; a negative index means the whole chain, any other index outside
/// the chain is rejected.
pub fn handleSetWled(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *WledCtx = @ptrCast(@alignCast(ctx_ptr));
    const strip_name = try webreq.required([]const u8, params, "strip");
    const strip = ctx.findStrip(strip_name) orelse return error.NotFound;

    const index_raw = ((try webreq.optional(i64, params, "index")) orelse -1);
    const index: ?usize = if (index_raw < 0) null else std.math.cast(usize, index_raw) orelse return error.InvalidParams;
    if (index) |i| if (i == 0 or i > strip.chain_count) return error.InvalidParams;
    const color = [4]f64{
        ((try webreq.optional(f64, params, "red")) orelse 0),
        ((try webreq.optional(f64, params, "green")) orelse 0),
        ((try webreq.optional(f64, params, "blue")) orelse 0),
        ((try webreq.optional(f64, params, "white")) orelse 0),
    };
    ctx.setWled(alloc, strip_name, color, index, ((try webreq.optional(i64, params, "transmit")) orelse 1) == 1) catch |err|
        return ctx.requestError(alloc, params, strip_name, err);

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

    // Moonraker registers these as Klippy remote methods; phobos exposes them as
    // client JSON-RPC methods. Static literals → stable .rodata keys.
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

/// A serial strip backed by a regular file in a temp dir. Each send reopens the
/// file and writes from offset 0, so `take` returns the latest send (over any
/// longer earlier one) and clears the file.
const Capture = struct {
    tmp: testing.TmpDir,
    path: [:0]u8,
    offset: u64 = 0,

    fn init() !Capture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "wled", .data = "" });
        return .{ .tmp = tmp, .path = try tmp.dir.realPathFileAlloc(testing.io, "wled", testing.allocator) };
    }

    fn deinit(self: *Capture) void {
        testing.allocator.free(self.path);
        self.tmp.cleanup();
    }

    fn take(self: *Capture, buf: []u8) ![]const u8 {
        const file = try self.tmp.dir.openFile(testing.io, "wled", .{});
        defer file.close(testing.io);
        const n = try file.readPositional(testing.io, &.{buf}, self.offset);
        self.offset += n;
        const data = buf[0..n];
        // Tests below inspect the last command; the PTY test counts every send.
        const start = if (std.mem.lastIndexOf(u8, data, "}{")) |at| at + 1 else 0;
        return data[start..];
    }

    fn strip(self: *const Capture, name: []const u8, chain_count: usize, initial_preset: i64) Config {
        return .{ .name = name, .chain_count = chain_count, .initial_preset = initial_preset, .transport = .{ .serial = .{ .path = self.path, .baud = default_baud } } };
    }
};

test "handleStrips: empty map, then the Moonraker strip info keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = WledCtx.init(testing.allocator);
    defer ctx.deinit();
    const empty = try handleStrips(@ptrCast(&ctx), .null, a);
    try testing.expectEqual(@as(usize, 0), empty.object.get("strips").?.object.count());

    try ctx.addStrip(.{ .name = "desk", .chain_count = 3, .initial_preset = 2 });
    const v = try handleStrips(@ptrCast(&ctx), .null, a);
    const info = v.object.get("strips").?.object.get("desk").?.object;
    const keys = [_][]const u8{ "strip", "status", "chain_count", "preset", "brightness", "intensity", "speed", "error" };
    try testing.expectEqual(keys.len, info.count());
    for (keys) |k| try testing.expect(info.get(k) != null);
    try testing.expectEqualStrings("off", info.get("status").?.string);
    try testing.expectEqual(@as(i64, 3), info.get("chain_count").?.integer);
    try testing.expectEqual(@as(i64, 2), info.get("preset").?.integer);
}

test "handleSingleStrip: unknown strip, GET is read-only, invalid action" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = WledCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.addStrip(.{ .name = "s" });
    try testing.expectError(error.NotFound, handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"ghost\"}"), a));
    const v = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"s\",\"action\":\"on\",\"_method\":\"GET\"}"), a);
    try testing.expectEqualStrings("off", v.object.get("s").?.object.get("status").?.string);
    try testing.expectError(error.InvalidParams, handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"s\",\"action\":\"dance\",\"_method\":\"POST\"}"), a));
}

test "POST on with a preset sends ps; on without one restores the initial colours" {
    var cap = try Capture.init();
    defer cap.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = WledCtx.init(testing.allocator);
    defer ctx.deinit();
    ctx.setIo(testing.io);
    try ctx.addStrip(cap.strip("s", 2, -1));
    var buf: [256]u8 = undefined;

    const v = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"s\",\"action\":\"on\",\"preset\":3,\"_method\":\"POST\"}"), a);
    try testing.expectEqualStrings("{\"on\":true,\"ps\":3}", try cap.take(&buf));
    const info = v.object.get("s").?.object;
    try testing.expectEqualStrings("on", info.get("status").?.string);
    try testing.expectEqual(@as(i64, 3), info.get("preset").?.integer);
    try testing.expectEqual(@as(i64, -1), info.get("brightness").?.integer);

    _ = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"s\",\"action\":\"on\",\"_method\":\"POST\"}"), a);
    try testing.expectEqualStrings("{\"on\":true,\"tt\":0,\"bri\":255,\"seg\":{\"bri\":255,\"i\":[0,2,[128,128,128,128]]}}", try cap.take(&buf));
    try testing.expectEqual(@as(i64, -1), ctx.findStrip("s").?.preset);
}

test "control: skipped when off, bri only without a preset, seg ix/sx with one" {
    var cap = try Capture.init();
    defer cap.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = WledCtx.init(testing.allocator);
    defer ctx.deinit();
    ctx.setIo(testing.io);
    try ctx.addStrip(cap.strip("s", 1, -1));
    var buf: [256]u8 = undefined;

    // Off strip: control does nothing and the strip stays off.
    const off = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"s\",\"action\":\"control\",\"intensity\":40,\"_method\":\"POST\"}"), a);
    try testing.expectEqualStrings("off", off.object.get("s").?.object.get("status").?.string);
    try testing.expectEqualStrings("", try cap.take(&buf));

    try ctx.setInitialState(a, "s");
    _ = try cap.take(&buf);
    // No preset: intensity/speed are not sent, brightness is.
    _ = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"s\",\"action\":\"control\",\"intensity\":40,\"_method\":\"POST\"}"), a);
    try testing.expectEqualStrings("", try cap.take(&buf));
    _ = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"s\",\"action\":\"control\",\"brightness\":90,\"_method\":\"POST\"}"), a);
    try testing.expectEqualStrings("{\"tt\":0,\"bri\":90}", try cap.take(&buf));

    try ctx.wledOn(a, "s", 4);
    _ = try cap.take(&buf);
    _ = try handleSingleStrip(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"s\",\"action\":\"control\",\"intensity\":40,\"speed\":300,\"_method\":\"POST\"}"), a);
    try testing.expectEqualStrings("{\"tt\":0,\"seg\":{\"ix\":40}}", try cap.take(&buf));
    try testing.expectEqual(@as(i64, 40), ctx.findStrip("s").?.intensity);
    try testing.expectEqual(@as(i64, -1), ctx.findStrip("s").?.speed);
}

test "set_wled: pixel then full chain after off, and a second send from off" {
    var cap = try Capture.init();
    defer cap.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = WledCtx.init(testing.allocator);
    defer ctx.deinit();
    ctx.setIo(testing.io);
    try ctx.addStrip(cap.strip("s", 2, -1));
    var buf: [512]u8 = undefined;

    // From off with a pending full send: the whole chain, and the strip is lit.
    _ = try handleSetWled(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"s\",\"red\":1,\"index\":2}"), a);
    const full = "{\"on\":true,\"tt\":0,\"bri\":255,\"seg\":{\"bri\":255,\"i\":[[0,0,0,0],[255,0,0,0]]}}";
    try testing.expectEqualStrings(full, try cap.take(&buf));
    try testing.expect(ctx.findStrip("s").?.on);
    // Lit strip: only the changed pixel.
    _ = try handleSetWled(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"s\",\"blue\":1.0,\"index\":1}"), a);
    try testing.expectEqualStrings("{\"on\":true,\"tt\":0,\"bri\":255,\"seg\":{\"bri\":255,\"i\":[0,[0,0,255,0]]}}", try cap.take(&buf));
    // transmit=0 stores colours only and forces a full send next time.
    _ = try handleSetWled(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"s\",\"green\":1,\"index\":1,\"transmit\":0}"), a);
    try testing.expectEqualStrings("", try cap.take(&buf));
    try testing.expect(ctx.findStrip("s").?.send_full_chain_data);
}

test "set_wled: index outside the chain is rejected, including 2^32" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = WledCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.addStrip(.{ .name = "s", .chain_count = 2 });
    try testing.expectError(error.InvalidParams, handleSetWled(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"s\",\"index\":0}"), a));
    try testing.expectError(error.InvalidParams, handleSetWled(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"s\",\"index\":3}"), a));
    try testing.expectError(error.InvalidParams, handleSetWled(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"s\",\"index\":4294967297}"), a));
    _ = try handleSetWled(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"s\",\"index\":-5}"), a);
}

test "set_wled_state: off, preset on and control in Moonraker order" {
    var cap = try Capture.init();
    defer cap.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = WledCtx.init(testing.allocator);
    defer ctx.deinit();
    ctx.setIo(testing.io);
    try ctx.addStrip(cap.strip("s", 1, -1));
    var buf: [256]u8 = undefined;

    _ = try handleSetWledState(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"s\",\"preset\":5,\"brightness\":20}"), a);
    try testing.expectEqualStrings("{\"tt\":0,\"seg\":{\"bri\":20},\"bri\":20}", try cap.take(&buf));
    try testing.expectEqual(@as(i64, 5), ctx.findStrip("s").?.preset);
    _ = try handleSetWledState(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"s\",\"state\":false,\"preset\":7}"), a);
    try testing.expectEqualStrings("{\"on\":true,\"ps\":7}", try cap.take(&buf));
    try testing.expect(ctx.findStrip("s").?.on);
    // Nothing requested: no send.
    _ = try handleSetWledState(@ptrCast(&ctx), try objParams(a, "{\"strip\":\"s\"}"), a);
    try testing.expectEqualStrings("", try cap.take(&buf));
}

test "batch: toggle, injected keys, strip_not_found and empty params" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = WledCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.addStrip(.{ .name = "s" });
    const v = try handleBatchToggle(@ptrCast(&ctx), try objParams(a, "{\"s\":null,\"_method\":\"POST\",\"\":null}"), a);
    try testing.expectEqualStrings("on", v.object.get("s").?.object.get("status").?.string);
    try testing.expectEqualStrings("strip_not_found", v.object.get("").?.object.get("error").?.string);
    try testing.expect(v.object.get("_method") == null);
    const off = try handleBatchOff(@ptrCast(&ctx), try objParams(a, "{\"s\":null}"), a);
    try testing.expectEqualStrings("off", off.object.get("s").?.object.get("status").?.string);
    try testing.expectError(error.InvalidParams, handleBatchStatus(@ptrCast(&ctx), try objParams(a, "{\"_method\":\"GET\"}"), a));
    try testing.expectError(error.InvalidParams, handleBatchOn(@ptrCast(&ctx), .null, a));
}

test "a failed send sets error and fails the request" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [96]u8 = undefined;
    const missing = try std.fmt.bufPrint(&path_buf, "{s}/{s}/missing", .{ testing.TmpDir.parent_dir_path, &tmp.sub_path });
    var ctx = WledCtx.init(testing.allocator);
    defer ctx.deinit();
    ctx.setIo(testing.io);
    try ctx.addStrip(.{ .name = "s", .transport = .{ .serial = .{ .path = missing, .baud = default_baud } } });
    const params = try objParams(a, "{\"strip\":\"s\",\"action\":\"off\",\"_method\":\"POST\"}");
    try testing.expectError(error.UpstreamRequestFailed, handleSingleStrip(@ptrCast(&ctx), params, a));
    try testing.expectEqualStrings("WLED: Error FileNotFound", ctx.findStrip("s").?.error_state.?);
    const reply = try jsonrpc.errorReply(error.UpstreamRequestFailed, params, a);
    try testing.expectEqual(std.http.Status.bad_request, reply.status);
    try testing.expectEqualStrings("WLED: Error FileNotFound", reply.message);
}

test "http strip: POSTs JSON with Core released" {
    const DeviceDouble = power.DeviceDouble;
    const io = testing.io;
    var core = Core.init();
    var device = try DeviceDouble.bind(io, "HTTP/1.1 200 OK\r\nContent-Length: 16\r\nConnection: close\r\n\r\n{\"success\":true}");
    defer device.server.deinit(io);
    device.core = &core;
    var serving = try io.concurrent(DeviceDouble.serveOne, .{&device});
    defer serving.cancel(io);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = WledCtx.init(testing.allocator);
    defer ctx.deinit();
    ctx.setIo(io);
    ctx.core = &core;
    var url_buf: [64]u8 = undefined;
    try ctx.addStrip(.{ .name = "s", .transport = .{ .http = try device.url(&url_buf, "/json") } });
    const params = try objParams(a, "{\"strip\":\"s\",\"action\":\"off\",\"_method\":\"POST\"}");
    _ = try core.run(io, handleSingleStrip, .{ @as(*anyopaque, @ptrCast(&ctx)), params, a });
    try testing.expectEqualStrings("POST /json HTTP/1.1\r\n", device.request_line[0..device.request_len]);
    try testing.expect(ctx.findStrip("s").?.error_state == null);
}

test "setInitialState: initial preset or colours, strip lit" {
    var cap = try Capture.init();
    defer cap.deinit();
    var ctx = WledCtx.init(testing.allocator);
    defer ctx.deinit();
    ctx.setIo(testing.io);
    try ctx.addStrip(cap.strip("s", 1, 6));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try ctx.setInitialState(arena.allocator(), "s");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("{\"on\":true,\"ps\":6}", try cap.take(&buf));
    const strip = ctx.findStrip("s").?;
    try testing.expect(strip.on);
    try testing.expectEqual(@as(i64, 6), strip.preset);
    try testing.expectEqualSlices(u8, &.{ 128, 128, 128, 128 }, strip.chain_data);
}

test "serial initialization queries state and retains the same connection for later commands" {
    const Pty = @import("../testutil/pty.zig").Pty;
    const Peer = struct {
        pty: *Pty,
        commands: [3][256]u8 = undefined,
        lengths: [3]usize = @splat(0),
        done: std.Io.Event = .unset,
        initial_received: std.Io.Event = .unset,

        fn run(self: *@This()) !void {
            defer self.done.set(self.pty.master.io);
            const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } };
            for (&self.commands, &self.lengths, 0..) |*buf, *len, index| {
                const deadline = timeout.toDeadline(self.pty.master.io);
                while (len.* < buf.len) {
                    len.* += try self.pty.master.readSomeTimeout(buf[len.*..], deadline);
                    if (try std.json.validate(std.heap.smp_allocator, buf[0..len.*])) break;
                }
                if (index == 0) try self.pty.master.writeTimeout("booting\n{\"on\":false}\n", deadline);
                if (index == 1) {
                    const ack = "{\"success\":true}\n";
                    var replies: [ack.len * 2048]u8 = undefined;
                    for (0..2048) |i| @memcpy(replies[i * ack.len ..][0..ack.len], ack);
                    try self.pty.master.writeTimeout(&replies, deadline);
                    self.initial_received.set(self.pty.master.io);
                }
            }
        }
    };
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();
    var pty = try Pty.init(aio);
    defer pty.deinit();
    var keepalive = try serial_mod.Serial.open(aio, pty.path(), default_baud);
    defer keepalive.close();
    var peer: Peer = .{ .pty = &pty };
    var serving = try aio.concurrent(Peer.run, .{&peer});
    defer _ = serving.cancel(aio) catch {};
    var ctx = WledCtx.init(std.heap.smp_allocator);
    defer ctx.deinit();
    ctx.setIo(aio);
    try ctx.addStrip(.{ .name = "serial", .initial_preset = 6, .transport = .{ .serial = .{ .path = pty.path(), .baud = default_baud } } });
    ctx.applyInitialStates();
    try testing.expect(ctx.findStrip("serial").?.initialized);
    try peer.initial_received.waitTimeout(aio, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    const handle = ctx.findStrip("serial").?.serial_link.?.port.?.file.handle;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try ctx.wledOff(arena.allocator(), "serial");
    try testing.expectEqual(handle, ctx.findStrip("serial").?.serial_link.?.port.?.file.handle);
    try peer.done.waitTimeout(aio, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    try serving.await(aio);
    try testing.expectEqualStrings("{\"v\":true}", peer.commands[0][0..peer.lengths[0]]);
    try testing.expectEqualStrings("{\"on\":true,\"ps\":6}", peer.commands[1][0..peer.lengths[1]]);
    try testing.expectEqualStrings("{\"on\":false}", peer.commands[2][0..peer.lengths[2]]);
}

test "HTTP initialization retries twice then queries before the initial command" {
    const Peer = struct {
        device: power.DeviceDouble,
        count: usize = 0,
        bodies: [4][128]u8 = undefined,
        lengths: [4]usize = @splat(0),
        done: std.Io.Event = .unset,

        fn run(self: *@This()) !void {
            defer self.done.set(self.device.io);
            for (0..4) |index| {
                const stream = try self.device.server.accept(self.device.io);
                defer stream.close(self.device.io);
                var rbuf: [1024]u8 = undefined;
                var reader = stream.reader(self.device.io, &rbuf);
                _ = try reader.interface.takeDelimiterInclusive('\n');
                var len: usize = 0;
                while (true) {
                    const line = try reader.interface.takeDelimiterInclusive('\n');
                    if (line.len <= 2) break;
                    if (std.ascii.startsWithIgnoreCase(line, "Content-Length:"))
                        len = try std.fmt.parseInt(usize, std.mem.trim(u8, line["Content-Length:".len..], " \r\n"), 10);
                }
                if (len > self.bodies[index].len) return error.BodyTooLong;
                try reader.interface.readSliceAll(self.bodies[index][0..len]);
                self.lengths[index] = len;
                var wbuf: [256]u8 = undefined;
                var writer = stream.writer(self.device.io, &wbuf);
                try writer.interface.writeAll(if (index < 2)
                    "HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                else
                    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}");
                try writer.interface.flush();
                self.count += 1;
            }
        }
    };
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();
    var peer: Peer = .{ .device = try power.DeviceDouble.bind(aio, null) };
    defer peer.device.server.deinit(aio);
    var serving = try aio.concurrent(Peer.run, .{&peer});
    defer _ = serving.cancel(aio) catch {};
    var ctx = WledCtx.init(std.heap.smp_allocator);
    defer ctx.deinit();
    ctx.setIo(aio);
    var url: [96]u8 = undefined;
    try ctx.addStrip(.{ .name = "http", .initial_preset = 4, .transport = .{ .http = try peer.device.url(&url, "/json") } });
    ctx.applyInitialStates();
    try peer.done.waitTimeout(aio, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    try serving.await(aio);
    try testing.expectEqual(@as(usize, 4), peer.count);
    for (0..3) |index| try testing.expectEqualStrings("{\"v\":true}", peer.bodies[index][0..peer.lengths[index]]);
    try testing.expectEqualStrings("{\"on\":true,\"ps\":4}", peer.bodies[3][0..peer.lengths[3]]);
    try testing.expect(ctx.findStrip("http").?.initialized);
}

test "failed startup strips remain pending and successful strips are not reset" {
    var ctx = WledCtx.init(testing.allocator);
    defer ctx.deinit();
    ctx.setIo(testing.io);
    try ctx.addStrip(.{ .name = "bad", .transport = .{ .serial = .{ .path = "", .baud = default_baud } } });
    try ctx.addStrip(.{ .name = "good" });
    ctx.applyInitialStates();
    try testing.expect(!ctx.initializationComplete());
    try testing.expect(!ctx.findStrip("bad").?.initialized);
    try testing.expect(ctx.findStrip("bad").?.error_state != null);
    ctx.findStrip("good").?.on = false;
    try ctx.addStrip(.{ .name = "bad" });
    ctx.applyInitialStates();
    try testing.expect(ctx.initializationComplete());
    try testing.expect(!ctx.findStrip("good").?.on);
    ctx.stopInitialization();
    ctx.applyInitialStates();
}

test "startup retries pending strips every two seconds for 120 seconds" {
    const Fake = struct {
        elapsed: i96 = 0,
        attempts: usize = 0,
        fn now(raw: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return .{ .nanoseconds = self.elapsed };
        }
        fn wait(raw: ?*anyopaque, _: *const u32, _: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.elapsed = timeout.deadline.raw.nanoseconds;
        }
        fn open(raw: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.attempts += 1;
            return error.FileNotFound;
        }
    };
    var fake: Fake = .{};
    var vtable = std.Io.failing.vtable.*;
    vtable.now = Fake.now;
    vtable.futexWait = Fake.wait;
    vtable.dirOpenFile = Fake.open;
    const aio: std.Io = .{ .userdata = &fake, .vtable = &vtable };
    var core = Core.init();
    var ctx = WledCtx.init(testing.allocator);
    defer ctx.deinit();
    ctx.io = aio;
    ctx.core = &core;
    try ctx.addStrip(.{ .name = "pending", .transport = .{ .serial = .{ .path = "mock", .baud = default_baud } } });
    ctx.initializationLoop();
    try testing.expectEqual(@as(usize, 60), fake.attempts);
    try testing.expectEqual(init_retry_time.nanoseconds, fake.elapsed);
    ctx.init_stop.set(aio);
    ctx.initializationLoop();
    try testing.expectEqual(@as(usize, 60), fake.attempts);
}

test "startup worker applies initial states and joins before context teardown" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();
    var core = Core.init();
    var ctx = WledCtx.init(std.heap.smp_allocator);
    defer ctx.deinit();
    ctx.io = aio;
    ctx.core = &core;
    try ctx.addStrip(.{ .name = "startup", .initial_preset = 7 });
    try ctx.startInitialization();
    const start = std.Io.Clock.Timestamp.now(aio, .awake);
    while (!core.run(aio, WledCtx.initializationComplete, .{&ctx})) {
        if (start.untilNow(aio).raw.nanoseconds >= std.time.ns_per_s) return error.Timeout;
        try std.Io.sleep(aio, .fromMilliseconds(1), .awake);
    }
    ctx.stopInitialization();
    try testing.expect(ctx.init_thread == null);
    const strip = ctx.findStrip("startup").?;
    try testing.expectEqual(@as(i64, 7), strip.preset);
    try testing.expect(strip.on);
}

test "fuzz serial query discards arbitrary startup lines before a JSON reply" {
    const Pty = @import("../testutil/pty.zig").Pty;
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            const Peer = struct {
                pty: *Pty,
                bytes: []const u8,
                fn run(self: *@This()) !void {
                    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } };
                    var query: [32]u8 = undefined;
                    _ = try self.pty.master.readSomeTimeout(&query, timeout);
                    try self.pty.master.writeTimeout(self.bytes, timeout);
                    try self.pty.master.writeTimeout("\n{}\n", timeout);
                }
            };
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const aio = threaded.io();
            var pty = try Pty.init(aio);
            defer pty.deinit();
            var serial = try serial_mod.Serial.open(aio, pty.path(), default_baud);
            defer serial.close();
            var bytes: [64]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            var peer: Peer = .{ .pty = &pty, .bytes = &bytes };
            var serving = try aio.concurrent(Peer.run, .{&peer});
            defer _ = serving.cancel(aio) catch {};
            const link = try SerialLink.create(testing.allocator);
            defer link.release();
            try link.send(aio, pty.path(), default_baud, .fromSeconds(2), "{\"v\":true}", true);
            try serving.await(aio);
        }
    }.run, .{});
}

test "registerWled: wires expected routes and JSON-RPC methods" {
    var d = jsonrpc.Dispatcher.init(testing.allocator);
    defer d.deinit();
    var reg = Registry.init(testing.allocator, &d);
    defer reg.deinit();
    var ctx = WledCtx.init(testing.allocator);
    defer ctx.deinit();
    try registerWled(&reg, &ctx);
    try testing.expect(reg.lookup(.GET, "/machine/wled/strips") != null);
    try testing.expect(reg.lookup(.GET, "/machine/wled/status") != null);
    try testing.expect(reg.lookup(.GET, "/machine/wled/strip") != null);
    try testing.expect(reg.lookup(.POST, "/machine/wled/on") != null);
    try testing.expect(reg.lookup(.POST, "/machine/wled/off") != null);
    try testing.expect(reg.lookup(.POST, "/machine/wled/toggle") != null);
    try testing.expect(reg.lookup(.POST, "/machine/wled/strip") != null);
    try testing.expect(d.methods.get("set_wled_state") != null);
    try testing.expect(d.methods.get("set_wled") != null);
}

test "WLED strips free partial and replaced records on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn check(alloc: std.mem.Allocator) !void {
            var ctx = WledCtx.init(alloc);
            defer ctx.deinit();
            try ctx.addStrip(.{ .name = "s", .chain_count = 2, .transport = .{ .http = "http://h:80/json" } });
            try ctx.addStrip(.{ .name = "s", .transport = .{ .serial = .{ .path = "/dev/x", .baud = default_baud } } });
            try testing.expectEqual(@as(usize, 1), ctx.findStrip("s").?.chain_count);
        }
    }.check, .{});
}

test "updateColorData: whole chain, one pixel, out-of-range index ignored" {
    var ctx = WledCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.addStrip(.{ .name = "s", .chain_count = 2 });
    const strip = ctx.findStrip("s").?;
    strip.updateColorData(.{ 1, 0, 0, 0 }, null);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 255, 0, 0, 0 }, strip.chain_data);
    strip.updateColorData(.{ 0, 0, 2.0, -1 }, 2);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 0, 0, 255, 0 }, strip.chain_data);
    strip.updateColorData(.{ 0, 1, 0, 0 }, 3);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 0, 0, 255, 0 }, strip.chain_data);
}

test "request floats accept numbers, numeric strings and booleans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try objParams(arena.allocator(), "{\"a\":0.25,\"b\":1,\"c\":\"0.5\",\"d\":true}");
    try testing.expectEqual(@as(f64, 0.25), ((try webreq.optional(f64, p, "a")) orelse 0));
    try testing.expectEqual(@as(f64, 1), ((try webreq.optional(f64, p, "b")) orelse 0));
    try testing.expectEqual(@as(f64, 0.5), ((try webreq.optional(f64, p, "c")) orelse 0));
    try testing.expectEqual(@as(f64, 1), ((try webreq.optional(f64, p, "d")) orelse 0));
    try testing.expectEqual(@as(f64, 0), ((try webreq.optional(f64, p, "missing")) orelse 0));
}

test "fuzz WLED handlers: arbitrary actions and params never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = WledCtx.init(testing.allocator);
            defer ctx.deinit();
            try ctx.addStrip(.{ .name = "s", .chain_count = smith.valueRangeAtMostWithHash(u8, 1, 8, 0), .initial_preset = smith.valueRangeAtMostWithHash(i8, -1, 3, 1) });
            const actions = [_][]const u8{ "on", "off", "toggle", "control", "status", "x" };
            for (0..4) |round| {
                const action = actions[smith.valueRangeLessThanWithHash(u8, 0, actions.len, 2)];
                const ints = [_]i64{ -1, 0, 1, 128, 255, 256, std.math.minInt(i64) };
                const json = try std.fmt.allocPrint(a, "{{\"strip\":\"s\",\"action\":\"{s}\",\"_method\":\"POST\",\"preset\":{d},\"brightness\":{d},\"intensity\":{d},\"speed\":{d},\"index\":{d},\"red\":{d},\"transmit\":{d}}}", .{
                    action,
                    ints[smith.valueRangeLessThanWithHash(u8, 0, ints.len, 3)],
                    ints[smith.valueRangeLessThanWithHash(u8, 0, ints.len, 4)],
                    ints[smith.valueRangeLessThanWithHash(u8, 0, ints.len, 5)],
                    ints[smith.valueRangeLessThanWithHash(u8, 0, ints.len, 6)],
                    ints[smith.valueRangeLessThanWithHash(u8, 0, ints.len, 7)],
                    ints[smith.valueRangeLessThanWithHash(u8, 0, ints.len, 8)],
                    round % 2,
                });
                const params = try objParams(a, json);
                _ = handleSingleStrip(@ptrCast(&ctx), params, a) catch {};
                _ = handleSetWledState(@ptrCast(&ctx), params, a) catch {};
                _ = handleSetWled(@ptrCast(&ctx), params, a) catch {};
                _ = try handleBatchStatus(@ptrCast(&ctx), try objParams(a, "{\"s\":null}"), a);
            }
            const strip = ctx.findStrip("s").?;
            try testing.expect(strip.brightness >= -1 and strip.brightness <= 255);
            try testing.expect(strip.intensity >= -1 and strip.intensity <= 255);
            try testing.expect(strip.speed >= -1 and strip.speed <= 255);
        }
    }.run, .{});
}
