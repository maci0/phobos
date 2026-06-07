//! server.sensors.* API component — Moonraker-compatible generic sensor support.
//!
//! Matches the endpoints registered in
//! `vendor/moonraker/moonraker/components/sensor.py` (Sensors):
//!
//!   GET /server/sensors/list         → server.sensors.list
//!   GET /server/sensors/info         → server.sensors.info
//!   GET /server/sensors/measurements → server.sensors.measurements
//!
//! Sensor info shape (BaseSensor.get_sensor_info):
//!   id, friendly_name, type, values (dict)
//!   extended=true adds: parameter_info, history_fields
//!
//! Sensor measurements shape (BaseSensor.get_sensor_measurements):
//!   {"<parameter>": [...values]}
//!
//! Without configured sensors all endpoints return empty/correct shapes:
//!   list → {"sensors": {}}
//!   info (with sensor param) → 404 error
//!   measurements (no sensor param) → {}
//!   measurements (with sensor param) → 404 error
//!
//! MQTT source: `ingestMqttMessage(topic, payload)` feeds inbound MQTT messages
//! (JSON object → numeric measurements) into the matching sensor and emits
//! `notify_sensor_update`. The live path is MqttClient reader → MqttCtx.on_message
//! → app bridge → core.run → ingest (under the Core lock); topics are subscribed
//! on connect. (Moonraker's only built-in sensor type is MQTT; it renders a Jinja
//! state_response_template — phobos does direct JSON-field mapping instead.)

const std = @import("std");
const registry = @import("../server/registry.zig");
const notify = @import("../server/notify.zig");

const Registry = registry.Registry;
const NotifyBus = notify.NotifyBus;

// ---------------------------------------------------------------------------
// Sensor state
// ---------------------------------------------------------------------------

pub const MeasurementRing = struct {
    buf: []f64,
    head: usize,
    len: usize,

    pub fn init(alloc: std.mem.Allocator, capacity: usize) !MeasurementRing {
        // No @memset: the ring tracks head/len and never reads an unwritten slot
        // (toSlice copies only `len` entries). Skipping the memset avoids
        // committing every page of a large ring up front.
        const buf = try alloc.alloc(f64, capacity);
        return .{ .buf = buf, .head = 0, .len = 0 };
    }

    pub fn deinit(self: *MeasurementRing, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
    }

    pub fn push(self: *MeasurementRing, value: f64) void {
        if (self.buf.len == 0) return;
        self.buf[self.head] = value;
        self.head = (self.head + 1) % self.buf.len;
        if (self.len < self.buf.len) self.len += 1;
    }

    pub fn toSlice(self: *const MeasurementRing, alloc: std.mem.Allocator) ![]f64 {
        if (self.len == 0) return &.{};
        const out = try alloc.alloc(f64, self.len);
        const start = if (self.len < self.buf.len) @as(usize, 0) else self.head;
        if (self.len < self.buf.len) {
            @memcpy(out, self.buf[0..self.len]);
        } else {
            const tail = self.buf.len - start;
            @memcpy(out[0..tail], self.buf[start..]);
            @memcpy(out[tail..], self.buf[0..start]);
        }
        return out;
    }
};

pub const ParameterInfo = struct {
    name: []const u8,
    desc: []const u8,
    units: []const u8,

    pub fn deinit(self: *ParameterInfo, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.desc);
        alloc.free(self.units);
    }
};

pub const Sensor = struct {
    id: []const u8,
    type_str: []const u8,
    name: []const u8,
    last_measurements: std.StringHashMap(f64),
    last_value: std.StringHashMap(f64),
    history: std.StringHashMap(MeasurementRing),
    param_info: std.ArrayList(ParameterInfo),
    error_state: ?[]const u8,
    store_size: usize,
    /// MQTT state topic (Moonraker `[sensor] type: mqtt`, `state_topic:`). When
    /// set, inbound MQTT messages on this topic feed measurements.
    state_topic: ?[]const u8 = null,

    pub fn init(alloc: std.mem.Allocator, sensor_id: []const u8, sensor_type: []const u8) !Sensor {
        return .{
            .id = try alloc.dupe(u8, sensor_id),
            .type_str = try alloc.dupe(u8, sensor_type),
            .name = try alloc.dupe(u8, sensor_id),
            .last_measurements = std.StringHashMap(f64).init(alloc),
            .last_value = std.StringHashMap(f64).init(alloc),
            .history = std.StringHashMap(MeasurementRing).init(alloc),
            .param_info = .empty,
            .error_state = null,
            .store_size = 1200,
            .state_topic = null,
        };
    }

    pub fn deinit(self: *Sensor, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.type_str);
        alloc.free(self.name);
        if (self.error_state) |e| alloc.free(e);
        if (self.state_topic) |t| alloc.free(t);
        {
            var it = self.last_measurements.iterator();
            while (it.next()) |entry| {
                alloc.free(entry.key_ptr.*);
            }
            self.last_measurements.deinit();
        }
        {
            var it = self.last_value.iterator();
            while (it.next()) |entry| {
                alloc.free(entry.key_ptr.*);
            }
            self.last_value.deinit();
        }
        {
            var it = self.history.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(alloc);
                alloc.free(entry.key_ptr.*);
            }
            self.history.deinit();
        }
        for (self.param_info.items) |*pi| {
            pi.deinit(alloc);
        }
        self.param_info.deinit(alloc);
    }

    pub fn setMeasurement(self: *Sensor, alloc: std.mem.Allocator, param: []const u8, value: f64) !void {
        const gop = try self.history.getOrPut(param);
        if (!gop.found_existing) {
            // Build the ring + key first; if either fails, remove the
            // half-initialized entry so deinit never frees an uninitialized ring.
            const ring = MeasurementRing.init(alloc, self.store_size) catch |e| {
                _ = self.history.remove(param);
                return e;
            };
            gop.key_ptr.* = alloc.dupe(u8, param) catch |e| {
                var r = ring;
                r.deinit(alloc);
                _ = self.history.remove(param);
                return e;
            };
            gop.value_ptr.* = ring;
        }
        gop.value_ptr.push(value);

        const lm = try self.last_measurements.getOrPut(param);
        if (!lm.found_existing) {
            lm.key_ptr.* = try alloc.dupe(u8, param);
        }
        lm.value_ptr.* = value;
    }

    pub fn hasChanges(self: *const Sensor) bool {
        if (self.last_measurements.count() != self.last_value.count()) return true;
        var it = self.last_measurements.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const v = self.last_value.get(key) orelse return true;
            if (v != entry.value_ptr.*) return true;
        }
        return false;
    }

    pub fn snapshotValues(self: *Sensor, alloc: std.mem.Allocator) !void {
        {
            var it = self.last_value.iterator();
            while (it.next()) |entry| {
                alloc.free(entry.key_ptr.*);
            }
            self.last_value.clearAndFree();
        }
        var it = self.last_measurements.iterator();
        while (it.next()) |entry| {
            const key = try alloc.dupe(u8, entry.key_ptr.*);
            errdefer alloc.free(key);
            try self.last_value.put(key, entry.value_ptr.*);
        }
    }

    pub fn getSensorInfo(self: *const Sensor, alloc: std.mem.Allocator, extended: bool) !std.json.Value {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(alloc, "id", .{ .string = self.id });
        try obj.put(alloc, "friendly_name", .{ .string = self.name });
        try obj.put(alloc, "type", .{ .string = self.type_str });
        var vals: std.json.ObjectMap = .empty;
        var it = self.last_measurements.iterator();
        while (it.next()) |entry| {
            try vals.put(alloc, entry.key_ptr.*, .{ .float = entry.value_ptr.* });
        }
        try obj.put(alloc, "values", .{ .object = vals });
        if (extended and self.param_info.items.len > 0) {
            var pi_arr: std.json.Array = .init(alloc);
            for (self.param_info.items) |pi| {
                var pi_obj: std.json.ObjectMap = .empty;
                try pi_obj.put(alloc, "name", .{ .string = pi.name });
                try pi_obj.put(alloc, "description", .{ .string = pi.desc });
                try pi_obj.put(alloc, "units", .{ .string = pi.units });
                try pi_arr.append(.{ .object = pi_obj });
            }
            try obj.put(alloc, "parameter_info", .{ .array = pi_arr });
        }
        return .{ .object = obj };
    }

    pub fn getSensorMeasurements(self: *const Sensor, alloc: std.mem.Allocator) !std.json.Value {
        var obj: std.json.ObjectMap = .empty;
        var it = self.history.iterator();
        while (it.next()) |entry| {
            const slice = try entry.value_ptr.toSlice(alloc);
            var arr: std.json.Array = .init(alloc);
            for (slice) |v| {
                try arr.append(.{ .float = v });
            }
            try obj.put(alloc, entry.key_ptr.*, .{ .array = arr });
        }
        return .{ .object = obj };
    }
};

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

pub const SensorCtx = struct {
    gpa: std.mem.Allocator,
    bus: ?*NotifyBus,
    io: ?std.Io,
    sensors: std.StringHashMap(Sensor),

    pub fn init(alloc: std.mem.Allocator, bus: ?*NotifyBus) SensorCtx {
        return .{
            .gpa = alloc,
            .bus = bus,
            .io = null,
            .sensors = std.StringHashMap(Sensor).init(alloc),
        };
    }

    pub fn deinit(self: *SensorCtx) void {
        var it = self.sensors.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.gpa);
            self.gpa.free(entry.key_ptr.*);
        }
        self.sensors.deinit();
    }

    pub fn setIo(self: *SensorCtx, io: std.Io) void {
        self.io = io;
    }

    pub fn findSensor(self: *SensorCtx, id: []const u8) ?*Sensor {
        return self.sensors.getPtr(id);
    }

    pub fn addSensor(self: *SensorCtx, sensor_id: []const u8, sensor_type: []const u8) !*Sensor {
        var s = try Sensor.init(self.gpa, sensor_id, sensor_type);
        errdefer s.deinit(self.gpa);
        const key = try self.gpa.dupe(u8, sensor_id);
        errdefer self.gpa.free(key);
        try self.sensors.put(key, s);
        return self.sensors.getPtr(sensor_id).?;
    }

    pub fn addParameterInfo(self: *SensorCtx, sensor_id: []const u8, param_name: []const u8, desc: []const u8, units: []const u8) !void {
        const s = self.findSensor(sensor_id) orelse return error.NotFound;
        const pi: ParameterInfo = .{
            .name = try self.gpa.dupe(u8, param_name),
            .desc = try self.gpa.dupe(u8, desc),
            .units = try self.gpa.dupe(u8, units),
        };
        errdefer {
            self.gpa.free(@constCast(pi.name));
            self.gpa.free(@constCast(pi.desc));
            self.gpa.free(@constCast(pi.units));
        }
        try s.param_info.append(self.gpa, pi);
    }

    /// Configure a sensor's MQTT state topic (gpa-owned; replaces any previous).
    pub fn setSensorTopic(self: *SensorCtx, sensor_id: []const u8, topic: []const u8) !void {
        const s = self.findSensor(sensor_id) orelse return error.NotFound;
        const dup = try self.gpa.dupe(u8, topic);
        if (s.state_topic) |old| self.gpa.free(old);
        s.state_topic = dup;
    }

    /// Feed an inbound MQTT message to every sensor subscribed to `topic`.
    ///
    /// phobos models the payload as a JSON object: each numeric field becomes a
    /// measurement keyed by the field name. (Moonraker renders a Jinja
    /// `state_response_template` calling `set_result(name, value)`; phobos does
    /// not embed a template engine — direct JSON-field mapping covers the
    /// common case.) Emits `notify_sensor_update` once if any value changed.
    ///
    /// MUST be called under the Core lock (it emits notifications); the MQTT
    /// reader path wraps it via `core.run`.
    pub fn ingestMqttMessage(self: *SensorCtx, topic: []const u8, payload: []const u8, a: std.mem.Allocator) void {
        var matched = false;
        var it = self.sensors.iterator();
        while (it.next()) |entry| {
            const s = entry.value_ptr;
            const st = s.state_topic orelse continue;
            if (!std.mem.eql(u8, st, topic)) continue;
            matched = true;

            const parsed = std.json.parseFromSlice(std.json.Value, a, payload, .{}) catch {
                self.setSensorError(s, "sensor: invalid JSON payload");
                continue;
            };
            defer parsed.deinit();
            if (parsed.value != .object) continue;

            if (s.error_state) |e| {
                self.gpa.free(e);
                s.error_state = null;
            }
            var fit = parsed.value.object.iterator();
            while (fit.next()) |f| {
                const v: f64 = switch (f.value_ptr.*) {
                    .float => |x| x,
                    .integer => |x| @floatFromInt(x),
                    else => continue,
                };
                // key duped into gpa by setMeasurement.
                s.setMeasurement(self.gpa, f.key_ptr.*, v) catch {};
            }
        }
        if (matched) self.emitSensorUpdate(a);
    }

    fn setSensorError(self: *SensorCtx, s: *Sensor, msg: []const u8) void {
        if (s.error_state) |e| self.gpa.free(e);
        s.error_state = self.gpa.dupe(u8, msg) catch null;
    }

    pub fn emitSensorUpdate(self: *SensorCtx, a: std.mem.Allocator) void {
        const bus = self.bus orelse return;
        const io = self.io orelse return;

        // Build payload: { "<sensor_id>": { "<param>": value, ... }, ... }
        var payload: std.json.ObjectMap = .empty;
        var changed = false;
        var it = self.sensors.iterator();
        while (it.next()) |entry| {
            const s = entry.value_ptr;
            if (!s.hasChanges()) continue;
            var svals: std.json.ObjectMap = .empty;
            var mit = s.last_measurements.iterator();
            while (mit.next()) |mentry| {
                svals.put(a, mentry.key_ptr.*, .{ .float = mentry.value_ptr.* }) catch continue;
            }
            payload.put(a, entry.key_ptr.*, .{ .object = svals }) catch continue;
            // Snapshot into the STABLE ctx allocator, not `a`: `last_value`
            // outlives this call (the live MQTT path passes a per-message arena
            // that is freed on return). Keys must be gpa-owned to match
            // last_measurements + Sensor.deinit, else UAF / cross-allocator free.
            s.snapshotValues(self.gpa) catch continue;
            changed = true;
        }
        if (!changed) return;
        bus.emitLocked(io, notify.names.sensor_update, .{ .object = payload }) catch {};
    }
};

// ---------------------------------------------------------------------------
// Parameter helpers
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

fn getOptBool(params: std.json.Value, field: []const u8, default_val: bool) bool {
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
// Handlers
// ---------------------------------------------------------------------------

/// GET /server/sensors/list → {"sensors": {<id>: {sensor_info}, ...}}
pub fn handleSensorList(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *SensorCtx = @ptrCast(@alignCast(ctx_ptr));
    const extended = getOptBool(params, "extended", false);
    var sensors_obj: std.json.ObjectMap = .empty;
    var it = ctx.sensors.iterator();
    while (it.next()) |entry| {
        const info = try entry.value_ptr.getSensorInfo(alloc, extended);
        try sensors_obj.put(alloc, entry.key_ptr.*, info);
    }
    var out: std.json.ObjectMap = .empty;
    try out.put(alloc, "sensors", .{ .object = sensors_obj });
    return .{ .object = out };
}

/// GET /server/sensors/info → sensor info for a named sensor
pub fn handleSensorInfo(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *SensorCtx = @ptrCast(@alignCast(ctx_ptr));
    const sensor_name = getOptStr(params, "sensor") orelse return error.InvalidParams;
    const s = ctx.findSensor(sensor_name) orelse return error.NotFound;
    const extended = getOptBool(params, "extended", false);
    return s.getSensorInfo(alloc, extended);
}

/// GET /server/sensors/measurements → measurement history
pub fn handleSensorMeasurements(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *SensorCtx = @ptrCast(@alignCast(ctx_ptr));
    const sensor_name = getOptStr(params, "sensor") orelse "";
    if (sensor_name.len > 0) {
        const s = ctx.findSensor(sensor_name) orelse return error.NotFound;
        return s.getSensorMeasurements(alloc);
    }
    // All sensors.
    var out: std.json.ObjectMap = .empty;
    var it = ctx.sensors.iterator();
    while (it.next()) |entry| {
        const m = try entry.value_ptr.getSensorMeasurements(alloc);
        try out.put(alloc, entry.key_ptr.*, m);
    }
    return .{ .object = out };
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn registerSensor(reg: *Registry, ctx: *SensorCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    try reg.registerEndpoint(
        .{ .path = "/server/sensors/list", .methods = &.{.GET} },
        c,
        handleSensorList,
    );
    try reg.registerEndpoint(
        .{ .path = "/server/sensors/info", .methods = &.{.GET} },
        c,
        handleSensorInfo,
    );
    try reg.registerEndpoint(
        .{ .path = "/server/sensors/measurements", .methods = &.{.GET} },
        c,
        handleSensorMeasurements,
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn mkParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    return p.value;
}

fn testCtx(alloc: std.mem.Allocator) SensorCtx {
    return SensorCtx.init(alloc, null);
}

test "SensorCtx: init/deinit no leak" {
    var ctx = testCtx(testing.allocator);
    defer ctx.deinit();
    try testing.expectEqual(@as(usize, 0), ctx.sensors.count());
}

test "addSensor: stores sensor" {
    var ctx = testCtx(testing.allocator);
    defer ctx.deinit();
    const s = try ctx.addSensor("temp_sensor", "generic");
    try testing.expectEqual(@as(usize, 1), ctx.sensors.count());
    try testing.expectEqualStrings("temp_sensor", s.id);
    try testing.expectEqualStrings("generic", s.type_str);
}

test "Sensor.setMeasurement: stores value and history" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sensor.init(a, "s1", "test");
    defer s.deinit(a);
    try s.setMeasurement(a, "temperature", 25.5);
    try testing.expectEqual(@as(f64, 25.5), s.last_measurements.get("temperature").?);
    // History should have 1 entry.
    const h = s.history.get("temperature").?;
    try testing.expectEqual(@as(usize, 1), h.len);
}

test "Sensor.hasChanges: detects new measurements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sensor.init(a, "s1", "test");
    defer s.deinit(a);
    try s.setMeasurement(a, "temp", 20.0);
    try testing.expect(s.hasChanges()); // not yet snapshotted
    try s.snapshotValues(a);
    try testing.expect(!s.hasChanges()); // snapshotted, no new measurements
    try s.setMeasurement(a, "temp", 21.0);
    try testing.expect(s.hasChanges()); // value changed
}

test "Sensor.getSensorInfo: correct shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sensor.init(a, "sensor_a", "temperature_sensor");
    defer s.deinit(a);
    try s.setMeasurement(a, "temperature", 22.3);
    try s.setMeasurement(a, "humidity", 55.0);

    const info = try s.getSensorInfo(a, false);
    try testing.expectEqualStrings("sensor_a", info.object.get("id").?.string);
    try testing.expectEqualStrings("sensor_a", info.object.get("friendly_name").?.string);
    try testing.expectEqualStrings("temperature_sensor", info.object.get("type").?.string);
    const vals = info.object.get("values").?.object;
    try testing.expectEqual(@as(f64, 22.3), vals.get("temperature").?.float);
    try testing.expectEqual(@as(f64, 55.0), vals.get("humidity").?.float);
    // extended=false → no parameter_info
    try testing.expect(info.object.get("parameter_info") == null);
}

test "Sensor.getSensorInfo: extended includes parameter_info" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sensor.init(a, "s1", "test");
    defer s.deinit(a);
    try s.param_info.append(a, .{ .name = try a.dupe(u8, "temp"), .desc = try a.dupe(u8, "Temperature"), .units = try a.dupe(u8, "C") });
    const info = try s.getSensorInfo(a, true);
    const pi = info.object.get("parameter_info").?.array;
    try testing.expectEqual(@as(usize, 1), pi.items.len);
    try testing.expectEqualStrings("temp", pi.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("Temperature", pi.items[0].object.get("description").?.string);
    try testing.expectEqualStrings("C", pi.items[0].object.get("units").?.string);
}

test "Sensor.getSensorMeasurements: returns history array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sensor.init(a, "s1", "test");
    defer s.deinit(a);
    try s.setMeasurement(a, "temp", 10.0);
    try s.setMeasurement(a, "temp", 11.0);
    try s.setMeasurement(a, "temp", 12.0);

    const m = try s.getSensorMeasurements(a);
    const arr = m.object.get("temp").?.array;
    try testing.expectEqual(@as(usize, 3), arr.items.len);
    try testing.expectEqual(@as(f64, 10.0), arr.items[0].float);
    try testing.expectEqual(@as(f64, 11.0), arr.items[1].float);
    try testing.expectEqual(@as(f64, 12.0), arr.items[2].float);
}

test "handleSensorList: returns empty sensors object when empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = testCtx(arena.allocator());
    defer ctx.deinit();
    const result = try handleSensorList(@ptrCast(&ctx), .null, arena.allocator());
    const sensors = result.object.get("sensors").?.object;
    try testing.expectEqual(@as(usize, 0), sensors.count());
}

test "handleSensorList: returns sensor info when sensors present" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    const s = try ctx.addSensor("s1", "temp");
    try s.setMeasurement(a, "temp", 25.0);
    const result = try handleSensorList(@ptrCast(&ctx), .null, a);
    const sensors = result.object.get("sensors").?.object;
    try testing.expectEqual(@as(usize, 1), sensors.count());
    try testing.expect(sensors.get("s1") != null);
}

test "handleSensorInfo: missing sensor param → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try testing.expectError(error.InvalidParams, handleSensorInfo(@ptrCast(&ctx), .null, a));
}

test "handleSensorInfo: named sensor → NotFound (no sensors)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    const params = try mkParams(a, "{\"sensor\":\"ghost\"}");
    try testing.expectError(error.NotFound, handleSensorInfo(@ptrCast(&ctx), params, a));
}

test "handleSensorInfo: returns sensor info for existing sensor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    const s = try ctx.addSensor("s1", "temp");
    try s.setMeasurement(a, "temperature", 30.0);
    const params = try mkParams(a, "{\"sensor\":\"s1\"}");
    const info = try handleSensorInfo(@ptrCast(&ctx), params, a);
    try testing.expectEqualStrings("s1", info.object.get("id").?.string);
}

test "handleSensorMeasurements: no param → empty object when no sensors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    const result = try handleSensorMeasurements(@ptrCast(&ctx), .null, a);
    try testing.expectEqual(@as(usize, 0), result.object.count());
}

test "handleSensorMeasurements: named sensor → NotFound (no sensors)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    const params = try mkParams(a, "{\"sensor\":\"ghost\"}");
    try testing.expectError(error.NotFound, handleSensorMeasurements(@ptrCast(&ctx), params, a));
}

test "handleSensorMeasurements: returns measurement history" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    const s = try ctx.addSensor("s1", "test");
    try s.setMeasurement(a, "temp", 10.0);
    try s.setMeasurement(a, "temp", 20.0);
    const params = try mkParams(a, "{\"sensor\":\"s1\"}");
    const result = try handleSensorMeasurements(@ptrCast(&ctx), params, a);
    const arr = result.object.get("temp").?.array;
    try testing.expectEqual(@as(usize, 2), arr.items.len);
}

test "emitSensorUpdate: no-op without bus/io" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    const s = try ctx.addSensor("s1", "test");
    try s.setMeasurement(a, "temp", 25.0);
    // Should not panic even without bus/io.
    ctx.emitSensorUpdate(a);
    // hasChanges still true since we never snapshotted
    try testing.expect(s.hasChanges());
}

test "registerSensor: wires routes and JSON-RPC methods" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");

    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var ctx = testCtx(alloc);
    defer ctx.deinit();
    try registerSensor(&reg, &ctx);

    try testing.expect(reg.lookup(.GET, "/server/sensors/list") != null);
    try testing.expect(reg.lookup(.GET, "/server/sensors/info") != null);
    try testing.expect(reg.lookup(.GET, "/server/sensors/measurements") != null);
}

// --- Fuzz tests ---

test "fuzz handleSensorList: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = SensorCtx.init(a, null);
            defer ctx.deinit();
            _ = ctx.addSensor("s1", "test") catch {};
            _ = ctx.findSensor("s1").?.setMeasurement(a, "t", 1.0) catch {};
            var buf: [4]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{ "null", "{}", "{\"extended\":true}" };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            _ = handleSensorList(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleSensorInfo: arbitrary params never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = SensorCtx.init(a, null);
            defer ctx.deinit();
            _ = ctx.addSensor("s1", "test") catch {};

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null", "{}", "{\"sensor\":\"s1\"}",
                "{\"sensor\":\"ghost\"}", "{\"sensor\":\"\"}",
            };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            _ = handleSensorInfo(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleSensorMeasurements: arbitrary params never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = SensorCtx.init(a, null);
            defer ctx.deinit();
            _ = ctx.addSensor("s1", "test") catch {};

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null", "{}", "{\"sensor\":\"s1\"}",
                "{\"sensor\":\"ghost\"}", "{\"sensor\":\"\"}",
            };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            _ = handleSensorMeasurements(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz SensorRing: push and read back" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var buf: [32]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const cap: usize = @max(1, @as(usize, buf[0]) + 1);
            var ring = MeasurementRing.init(a, cap) catch return;
            defer ring.deinit(a);
            const n: usize = @as(usize, buf[1]) % 50;
            for (0..n) |i| {
                ring.push(@floatFromInt(i));
            }
            const slice = ring.toSlice(a) catch return;
            defer a.free(slice);
            const expected_len = @min(n, cap);
            if (slice.len != expected_len) return;
        }
    }.run, .{});
}

// --- MQTT sensor source ---

test "ingestMqttMessage: JSON numeric fields become measurements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = testCtx(std.testing.allocator);
    defer ctx.deinit();
    _ = try ctx.addSensor("chamber", "mqtt");
    try ctx.setSensorTopic("chamber", "printer/chamber/state");

    ctx.ingestMqttMessage("printer/chamber/state", "{\"temperature\":42.5,\"humidity\":60}", a);

    const s = ctx.findSensor("chamber").?;
    try std.testing.expectEqual(@as(f64, 42.5), s.last_measurements.get("temperature").?);
    try std.testing.expectEqual(@as(f64, 60.0), s.last_measurements.get("humidity").?);
    try std.testing.expect(s.error_state == null);
    // History ring captured the value too.
    try std.testing.expectEqual(@as(usize, 1), s.history.get("temperature").?.len);
}

test "ingestMqttMessage: non-matching topic is ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = testCtx(std.testing.allocator);
    defer ctx.deinit();
    _ = try ctx.addSensor("chamber", "mqtt");
    try ctx.setSensorTopic("chamber", "printer/chamber/state");

    ctx.ingestMqttMessage("some/other/topic", "{\"temperature\":99}", arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), ctx.findSensor("chamber").?.last_measurements.count());
}

test "ingestMqttMessage: invalid JSON sets error_state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = testCtx(std.testing.allocator);
    defer ctx.deinit();
    _ = try ctx.addSensor("c", "mqtt");
    try ctx.setSensorTopic("c", "t");

    ctx.ingestMqttMessage("t", "not json{", arena.allocator());
    try std.testing.expect(ctx.findSensor("c").?.error_state != null);
}

test "fuzz ingestMqttMessage: arbitrary payloads never crash" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var ctx = testCtx(std.testing.allocator);
            defer ctx.deinit();
            _ = ctx.addSensor("c", "mqtt") catch return;
            ctx.setSensorTopic("c", "t") catch return;
            var buf: [48]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            ctx.ingestMqttMessage("t", &buf, arena.allocator());
        }
    }.run, .{});
}

test "ingestMqttMessage: last_value snapshot is gpa-stable across per-message arenas" {
    // Regression for the snapshotValues cross-allocator/UAF: each message uses
    // its own arena that is freed on return; last_value keys must be gpa-owned.
    // Requires bus+io set (emitSensorUpdate early-returns otherwise, which is
    // why the single-arena tests missed this). testing.allocator flags a
    // cross-allocator free if regressed.
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = @import("../server/core.zig").Core{};
    var conns = @import("../server/connections.zig").Connections.init(alloc, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);

    var ctx = SensorCtx.init(alloc, &bus);
    defer ctx.deinit();
    ctx.setIo(io);
    _ = try ctx.addSensor("c", "mqtt");
    try ctx.setSensorTopic("c", "t");

    {
        var a1 = std.heap.ArenaAllocator.init(alloc);
        defer a1.deinit();
        ctx.ingestMqttMessage("t", "{\"temp\":1.0}", a1.allocator());
    }
    {
        var a2 = std.heap.ArenaAllocator.init(alloc);
        defer a2.deinit();
        ctx.ingestMqttMessage("t", "{\"temp\":2.0}", a2.allocator());
    }
    try testing.expectEqual(@as(f64, 2.0), ctx.findSensor("c").?.last_measurements.get("temp").?);
}
