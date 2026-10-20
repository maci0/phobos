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
//!   id, friendly_name, type, values (dict). `extended` adds nothing yet:
//!   `parameter_*` and `history_field_*` options are not read (TODO.md).
//!
//! Sensor measurements shape (BaseSensor.get_sensor_measurements):
//!   {"<parameter>": [...values]}, at most `sensor_store_size` values each.
//!
//! An unknown sensor name is a 400 error, as Moonraker's plain ServerError:
//!   list → {"sensors": {}}
//!   measurements (no sensor param) → {}
//!
//! MQTT source: `ingestMqttMessage(topic, payload)` feeds inbound MQTT messages
//! into the matching sensor and emits `notify_sensor_update`. The live path is
//! MqttClient reader → MqttCtx.on_message → app bridge → core.run → ingest
//! (under the Core lock); topics are subscribed on connect. A sensor's
//! `state_response_template` is parsed once at configuration and rendered per
//! message (`set_result(name, value)` records measurements). Without a
//! template, each numeric field of a JSON object payload becomes a
//! measurement; Moonraker requires the template.

const std = @import("std");
const registry = @import("../server/registry.zig");
const notify = @import("../server/notify.zig");
const database = @import("database.zig");
const sensor_template = @import("sensor_template.zig");

const Registry = registry.Registry;
const NotifyBus = notify.NotifyBus;

/// Moonraker's `sensor_store_size` default.
pub const default_store_size: usize = 1200;
/// Distinct measurement names kept per sensor. A payload naming more is
/// truncated: every name holds a `store_size` ring, so the bound caps memory
/// a publisher can claim.
pub const max_parameters: usize = 64;

// ---------------------------------------------------------------------------
// Sensor state
// ---------------------------------------------------------------------------

/// `[sensor <id>]` options. Strings are borrowed for the `addSensor` call.
pub const SensorConfig = struct {
    type: []const u8,
    /// `name`, the friendly name; defaults to the id.
    name: ?[]const u8 = null,
    store_size: usize = default_store_size,
    state_topic: ?[]const u8 = null,
    state_response_template: ?[]const u8 = null,
};

pub const Sensor = struct {
    id: []const u8,
    type_str: []const u8,
    name: []const u8,
    last_measurements: std.StringHashMap(f64),
    last_value: std.StringHashMap(f64),
    /// Per-parameter history, oldest first, at most `store_size` each.
    history: std.StringHashMap(std.Deque(f64)),
    store_size: usize,
    error_state: ?[]const u8,
    /// MQTT state topic (Moonraker `[sensor] type: mqtt`, `state_topic:`). When
    /// set, inbound MQTT messages on this topic feed measurements.
    state_topic: ?[]const u8 = null,
    /// Parsed `state_response_template`; when set, payloads are rendered through
    /// it instead of the direct JSON-field mapping.
    state_response_template: ?sensor_template.Template = null,

    pub fn init(alloc: std.mem.Allocator, sensor_id: []const u8, cfg: SensorConfig) !Sensor {
        var tmpl: ?sensor_template.Template = if (cfg.state_response_template) |src| try .init(alloc, src) else null;
        errdefer if (tmpl) |*t| t.deinit();
        const id = try alloc.dupe(u8, sensor_id);
        errdefer alloc.free(id);
        const type_str = try alloc.dupe(u8, cfg.type);
        errdefer alloc.free(type_str);
        const name = try alloc.dupe(u8, cfg.name orelse sensor_id);
        errdefer alloc.free(name);
        const topic = if (cfg.state_topic) |t| try alloc.dupe(u8, t) else null;
        return .{
            .id = id,
            .type_str = type_str,
            .name = name,
            .last_measurements = std.StringHashMap(f64).init(alloc),
            .last_value = std.StringHashMap(f64).init(alloc),
            .history = std.StringHashMap(std.Deque(f64)).init(alloc),
            .store_size = cfg.store_size,
            .error_state = null,
            .state_topic = topic,
            .state_response_template = tmpl,
        };
    }

    pub fn deinit(self: *Sensor, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.type_str);
        alloc.free(self.name);
        if (self.error_state) |e| alloc.free(e);
        if (self.state_topic) |t| alloc.free(t);
        if (self.state_response_template) |*t| t.deinit();
        freeKeys(alloc, &self.last_measurements);
        freeKeys(alloc, &self.last_value);
        var it = self.history.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(alloc);
            alloc.free(entry.key_ptr.*);
        }
        self.history.deinit();
    }

    fn freeKeys(alloc: std.mem.Allocator, map: *std.StringHashMap(f64)) void {
        var it = map.keyIterator();
        while (it.next()) |key| alloc.free(key.*);
        map.deinit();
    }

    /// Record one value. Non-finite values are dropped (they have no JSON
    /// form), as are new names beyond `max_parameters`.
    pub fn setMeasurement(self: *Sensor, alloc: std.mem.Allocator, param: []const u8, value: f64) !void {
        if (!std.math.isFinite(value)) return;
        if (!self.history.contains(param) and self.history.count() >= max_parameters) return;
        try self.history.ensureUnusedCapacity(1);
        try self.last_measurements.ensureUnusedCapacity(1);
        const gop = self.history.getOrPutAssumeCapacity(param);
        if (!gop.found_existing) {
            // Build the ring + key first; if either fails, remove the
            // half-initialized entry so deinit never frees an uninitialized ring.
            var ring = std.Deque(f64).initCapacity(alloc, self.store_size) catch |e| {
                _ = self.history.remove(param);
                return e;
            };
            gop.key_ptr.* = alloc.dupe(u8, param) catch |e| {
                ring.deinit(alloc);
                _ = self.history.remove(param);
                return e;
            };
            gop.value_ptr.* = ring;
        }
        const ring = gop.value_ptr;
        if (ring.buffer.len > 0) {
            if (ring.len == ring.buffer.len) _ = ring.popFront();
            ring.pushBackAssumeCapacity(value);
        }

        const lm = self.last_measurements.getOrPutAssumeCapacity(param);
        if (!lm.found_existing) {
            lm.key_ptr.* = alloc.dupe(u8, param) catch |err| {
                _ = self.last_measurements.remove(param);
                return err;
            };
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

    pub fn getSensorInfo(self: *const Sensor, alloc: std.mem.Allocator) !std.json.Value {
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
        return .{ .object = obj };
    }

    pub fn getSensorMeasurements(self: *const Sensor, alloc: std.mem.Allocator) !std.json.Value {
        var obj: std.json.ObjectMap = .empty;
        var it = self.history.iterator();
        while (it.next()) |entry| {
            var arr: std.json.Array = try .initCapacity(alloc, entry.value_ptr.len);
            var values = entry.value_ptr.iterator();
            while (values.next()) |v| arr.appendAssumeCapacity(.{ .float = v });
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
    /// Optional history component for auxiliary-field value reporting (set by App).
    history_ctx: ?*@import("history.zig").HistoryCtx = null,

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

    /// Add or replace a sensor. A malformed `state_response_template` fails
    /// here (`error.ParseError`) and adds nothing, like Moonraker skipping a
    /// sensor whose configuration raises.
    pub fn addSensor(self: *SensorCtx, sensor_id: []const u8, cfg: SensorConfig) !*Sensor {
        var s = try Sensor.init(self.gpa, sensor_id, cfg);
        errdefer s.deinit(self.gpa);
        const key = try self.gpa.dupe(u8, sensor_id);
        errdefer self.gpa.free(key);
        if (try self.sensors.fetchPut(key, s)) |prior| {
            self.gpa.free(key); // Replacements retain the map's existing key.
            var old = prior.value;
            old.deinit(self.gpa);
        }
        return self.sensors.getPtr(s.id).?;
    }

    /// Feed an inbound MQTT message to every sensor subscribed to `topic`.
    ///
    /// With a `state_response_template`, the payload is rendered and each
    /// `set_result(name, value)` records a measurement. Without one, each
    /// numeric field of a JSON object payload becomes a measurement. Emits
    /// `notify_sensor_update` once if any value changed.
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

            var values: std.json.ObjectMap = .empty;
            if (s.state_response_template) |*tmpl| {
                tmpl.render(a, payload, &values) catch {
                    self.setSensorError(s, "sensor: template render error");
                    continue;
                };
            } else {
                const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, payload, .{}) catch {
                    self.setSensorError(s, "sensor: invalid JSON payload");
                    continue;
                };
                if (parsed != .object) continue;
                values = parsed.object;
            }
            if (s.error_state) |e| {
                self.gpa.free(e);
                s.error_state = null;
            }
            var vit = values.iterator();
            while (vit.next()) |m| {
                const v: f64 = switch (m.value_ptr.*) {
                    .float => |x| x,
                    .integer => |x| @floatFromInt(x),
                    else => continue,
                };
                // key duped into gpa by setMeasurement.
                s.setMeasurement(self.gpa, m.key_ptr.*, v) catch |err| {
                    std.debug.print("phobos: warning: sensor '{s}' dropped '{s}': {}\n", .{ s.id, m.key_ptr.*, err });
                    continue;
                };
                // Report to history auxiliary fields (provider = sensor id).
                if (self.history_ctx) |h| h.recordAuxValue(s.id, m.key_ptr.*, v);
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
        // Moonraker send_event(SENSOR_EVENT_NAME, changed_data) → params is the
        // single-element data tuple [changed_data]; emit requires a JSON array.
        var arr: std.json.Array = .init(a);
        arr.append(.{ .object = payload }) catch return;
        bus.emitLocked(io, notify.names.sensor_update, .{ .array = arr }) catch {};
    }
};

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /server/sensors/list → {"sensors": {<id>: {sensor_info}, ...}}
pub fn handleSensorList(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *SensorCtx = @ptrCast(@alignCast(ctx_ptr));
    var sensors_obj: std.json.ObjectMap = .empty;
    var it = ctx.sensors.iterator();
    while (it.next()) |entry| {
        const info = try entry.value_ptr.getSensorInfo(alloc);
        try sensors_obj.put(alloc, entry.key_ptr.*, info);
    }
    var out: std.json.ObjectMap = .empty;
    try out.put(alloc, "sensors", .{ .object = sensors_obj });
    return .{ .object = out };
}

/// GET /server/sensors/info → sensor info for a named sensor
pub fn handleSensorInfo(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *SensorCtx = @ptrCast(@alignCast(ctx_ptr));
    const sensor_name = try database.getStr(params, "sensor");
    const s = ctx.findSensor(sensor_name) orelse return error.InvalidParams;
    return s.getSensorInfo(alloc);
}

/// GET /server/sensors/measurements → measurement history
pub fn handleSensorMeasurements(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *SensorCtx = @ptrCast(@alignCast(ctx_ptr));
    const sensor_name = (try database.getOptStr(params, "sensor")) orelse "";
    if (sensor_name.len > 0) {
        const s = ctx.findSensor(sensor_name) orelse return error.InvalidParams;
        // Moonraker wraps the result under the sensor name (sensor.py:331).
        const m = try s.getSensorMeasurements(alloc);
        var out: std.json.ObjectMap = .empty;
        try out.put(alloc, sensor_name, m);
        return .{ .object = out };
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

test "addSensor: stores sensor with friendly name, topic and store size" {
    var ctx = testCtx(testing.allocator);
    defer ctx.deinit();
    const s = try ctx.addSensor("temp_sensor", .{ .type = "mqtt", .name = "Chamber", .state_topic = "t", .store_size = 2 });
    try testing.expectEqual(@as(usize, 1), ctx.sensors.count());
    try testing.expectEqualStrings("temp_sensor", s.id);
    try testing.expectEqualStrings("mqtt", s.type_str);
    try testing.expectEqualStrings("Chamber", s.name);
    try testing.expectEqualStrings("t", s.state_topic.?);
    for (0..5) |i| try s.setMeasurement(testing.allocator, "v", @floatFromInt(i));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = try s.getSensorMeasurements(arena.allocator());
    const arr = m.object.get("v").?.array.items;
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expectEqual(@as(f64, 3), arr[0].float);
    try testing.expectEqual(@as(f64, 4), arr[1].float);
}

test "addSensor: a malformed template fails and adds nothing" {
    var ctx = testCtx(testing.allocator);
    defer ctx.deinit();
    try testing.expectError(error.ParseError, ctx.addSensor("bad", .{ .type = "mqtt", .state_topic = "t", .state_response_template = "{% if x %}" }));
    try testing.expectEqual(@as(usize, 0), ctx.sensors.count());
}

test "Sensor.setMeasurement: stores value and history" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sensor.init(a, "s1", .{ .type = "test" });
    defer s.deinit(a);
    try s.setMeasurement(a, "temperature", 25.5);
    try testing.expectEqual(@as(f64, 25.5), s.last_measurements.get("temperature").?);
    try testing.expectEqual(@as(usize, 1), s.history.get("temperature").?.len);
}

test "Sensor.setMeasurement: drops non-finite values and names past the cap" {
    var s = try Sensor.init(testing.allocator, "s1", .{ .type = "test", .store_size = 4 });
    defer s.deinit(testing.allocator);
    try s.setMeasurement(testing.allocator, "inf", std.math.inf(f64));
    try s.setMeasurement(testing.allocator, "nan", std.math.nan(f64));
    try testing.expectEqual(@as(usize, 0), s.last_measurements.count());

    var name_buf: [16]u8 = undefined;
    for (0..max_parameters + 10) |i| {
        try s.setMeasurement(testing.allocator, try std.fmt.bufPrint(&name_buf, "p{d}", .{i}), 1);
    }
    try testing.expectEqual(max_parameters, s.history.count());
    try testing.expectEqual(max_parameters, s.last_measurements.count());
    // Known names still update.
    try s.setMeasurement(testing.allocator, "p0", 2);
    try testing.expectEqual(@as(f64, 2), s.last_measurements.get("p0").?);
}

test "fuzz setMeasurement: arbitrary names, values and store sizes stay bounded" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const store_size = smith.valueRangeAtMostWithHash(u8, 0, 8, 0);
            var s = try Sensor.init(testing.allocator, "s", .{ .type = "t", .store_size = store_size });
            defer s.deinit(testing.allocator);
            const n = smith.valueRangeAtMostWithHash(u8, 0, 200, 1);
            for (0..n) |i| {
                var name: [2]u8 = undefined;
                smith.bytesWithHash(&name, @intCast(2 + i));
                var bits: [8]u8 = undefined;
                smith.bytesWithHash(&bits, 3);
                try s.setMeasurement(testing.allocator, &name, @bitCast(bits));
            }
            try testing.expect(s.history.count() <= max_parameters);
            var it = s.history.valueIterator();
            while (it.next()) |ring| {
                try testing.expect(ring.len <= store_size);
                var values = ring.iterator();
                while (values.next()) |v| try testing.expect(std.math.isFinite(v));
            }
        }
    }.run, .{});
}

test "Sensor.hasChanges: detects new measurements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sensor.init(a, "s1", .{ .type = "test" });
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
    var s = try Sensor.init(a, "sensor_a", .{ .type = "temperature_sensor" });
    defer s.deinit(a);
    try s.setMeasurement(a, "temperature", 22.3);
    try s.setMeasurement(a, "humidity", 55.0);

    const info = try s.getSensorInfo(a);
    try testing.expectEqualStrings("sensor_a", info.object.get("id").?.string);
    try testing.expectEqualStrings("sensor_a", info.object.get("friendly_name").?.string);
    try testing.expectEqualStrings("temperature_sensor", info.object.get("type").?.string);
    const vals = info.object.get("values").?.object;
    try testing.expectEqual(@as(f64, 22.3), vals.get("temperature").?.float);
    try testing.expectEqual(@as(f64, 55.0), vals.get("humidity").?.float);
    try testing.expectEqual(@as(usize, 4), info.object.count());
}

test "Sensor.getSensorMeasurements: returns history array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sensor.init(a, "s1", .{ .type = "test" });
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
    const s = try ctx.addSensor("s1", .{ .type = "temp" });
    try s.setMeasurement(a, "temp", 25.0);
    const result = try handleSensorList(@ptrCast(&ctx), .null, a);
    const sensors = result.object.get("sensors").?.object;
    try testing.expectEqual(@as(usize, 1), sensors.count());
    try testing.expect(sensors.get("s1") != null);
}

test "handleSensorInfo: missing or non-string sensor param → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try testing.expectError(error.InvalidParams, handleSensorInfo(@ptrCast(&ctx), .null, a));
    try testing.expectError(error.InvalidParams, handleSensorInfo(@ptrCast(&ctx), try mkParams(a, "{\"sensor\":5}"), a));
}

test "handleSensorInfo: unknown sensor → InvalidParams (Moonraker 400)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    const params = try mkParams(a, "{\"sensor\":\"ghost\"}");
    try testing.expectError(error.InvalidParams, handleSensorInfo(@ptrCast(&ctx), params, a));
}

test "handleSensorInfo: returns sensor info for existing sensor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    const s = try ctx.addSensor("s1", .{ .type = "temp" });
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

test "handleSensorMeasurements: unknown sensor → InvalidParams (Moonraker 400)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    const params = try mkParams(a, "{\"sensor\":\"ghost\"}");
    try testing.expectError(error.InvalidParams, handleSensorMeasurements(@ptrCast(&ctx), params, a));
}

test "handleSensorMeasurements: returns measurement history" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    const s = try ctx.addSensor("s1", .{ .type = "test" });
    try s.setMeasurement(a, "temp", 10.0);
    try s.setMeasurement(a, "temp", 20.0);
    const params = try mkParams(a, "{\"sensor\":\"s1\"}");
    const result = try handleSensorMeasurements(@ptrCast(&ctx), params, a);
    // Moonraker wraps the result under the sensor name (sensor.py:331).
    const meas = result.object.get("s1").?.object;
    const arr = meas.get("temp").?.array;
    try testing.expectEqual(@as(usize, 2), arr.items.len);
}

test "emitSensorUpdate: no-op without bus/io" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    const s = try ctx.addSensor("s1", .{ .type = "test" });
    try s.setMeasurement(a, "temp", 25.0);
    ctx.emitSensorUpdate(a);
    // hasChanges still true since we never snapshotted
    try testing.expect(s.hasChanges());
}

test "ingestMqttMessage: notify_sensor_update params is [{id: {param: value}}], only on change" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const Recorder = struct {
        frames: std.ArrayList([]const u8) = .empty,
        arena: std.mem.Allocator,
        fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.frames.append(self.arena, try self.arena.dupe(u8, bytes));
        }
    };
    var core = @import("../server/core.zig").Core.init();
    var conns = @import("../server/connections.zig").Connections.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var rec: Recorder = .{ .arena = a };
    conns.attachWriter(io, try conns.add(io), &rec, Recorder.write);

    var ctx = SensorCtx.init(testing.allocator, &bus);
    defer ctx.deinit();
    ctx.setIo(io);
    _ = try ctx.addSensor("c", .{ .type = "mqtt", .state_topic = "t" });
    ctx.ingestMqttMessage("t", "{\"temp\":1.5,\"label\":\"x\"}", a);
    ctx.ingestMqttMessage("t", "{\"temp\":1.5}", a); // unchanged: no frame

    try testing.expectEqual(@as(usize, 1), rec.frames.items.len);
    const frame = try std.json.parseFromSliceLeaky(std.json.Value, a, rec.frames.items[0], .{});
    try testing.expectEqualStrings(notify.names.sensor_update, frame.object.get("method").?.string);
    const params = frame.object.get("params").?.array;
    try testing.expectEqual(@as(usize, 1), params.items.len);
    const values = params.items[0].object.get("c").?.object;
    try testing.expectEqual(@as(usize, 1), values.count());
    try testing.expectEqual(@as(f64, 1.5), values.get("temp").?.float);
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
            const s = try ctx.addSensor("s1", .{ .type = "test" });
            try s.setMeasurement(a, "t", 1.0);
            var buf: [4]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{ "null", "{}", "{\"extended\":true}" };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            const result = try handleSensorList(@ptrCast(&ctx), p.value, a);
            try testing.expectEqual(@as(usize, 1), result.object.get("sensors").?.object.count());
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
            _ = try ctx.addSensor("s1", .{ .type = "test" });

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null",                   "{}",                "{\"sensor\":\"s1\"}",
                "{\"sensor\":\"ghost\"}", "{\"sensor\":\"\"}", "{\"sensor\":[1]}",
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
            _ = try ctx.addSensor("s1", .{ .type = "test" });

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null",                   "{}",                "{\"sensor\":\"s1\"}",
                "{\"sensor\":\"ghost\"}", "{\"sensor\":\"\"}", "{\"sensor\":7}",
            };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            _ = handleSensorMeasurements(@ptrCast(&ctx), p.value, a) catch {};
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
    _ = try ctx.addSensor("chamber", .{ .type = "mqtt", .state_topic = "printer/chamber/state" });

    ctx.ingestMqttMessage("printer/chamber/state", "{\"temperature\":42.5,\"humidity\":60,\"far\":1e999}", a);

    const s = ctx.findSensor("chamber").?;
    try std.testing.expectEqual(@as(f64, 42.5), s.last_measurements.get("temperature").?);
    try std.testing.expectEqual(@as(f64, 60.0), s.last_measurements.get("humidity").?);
    // A non-finite value has no JSON form and is dropped.
    try std.testing.expect(s.last_measurements.get("far") == null);
    try std.testing.expect(s.error_state == null);
    // History ring captured the value too.
    try std.testing.expectEqual(@as(usize, 1), s.history.get("temperature").?.len);
}

test "ingestMqttMessage: state_response_template renders measurements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = testCtx(std.testing.allocator);
    defer ctx.deinit();
    _ = try ctx.addSensor("env", .{
        .type = "mqtt",
        .state_topic = "tele/env",
        .state_response_template =
        \\{% set d = payload|fromjson %}
        \\{% set _ = set_result("temperature", d.DHT.Temperature|float) %}
        \\{% set _ = set_result("humidity", d.DHT.Humidity|int) %}
        ,
    });

    ctx.ingestMqttMessage("tele/env", "{\"DHT\":{\"Temperature\":23.4,\"Humidity\":51}}", a);

    const s = ctx.findSensor("env").?;
    try std.testing.expectEqual(@as(f64, 23.4), s.last_measurements.get("temperature").?);
    try std.testing.expectEqual(@as(f64, 51.0), s.last_measurements.get("humidity").?);
    try std.testing.expect(s.error_state == null);
}

test "ingestMqttMessage: template render error sets error_state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = testCtx(std.testing.allocator);
    defer ctx.deinit();
    _ = try ctx.addSensor("env", .{ .type = "mqtt", .state_topic = "t", .state_response_template = "{% set d = payload|fromjson %}{% set _ = set_result(\"x\", d.missing.deep) %}" });

    ctx.ingestMqttMessage("t", "{}", a); // d.missing → null, .deep on null → EvalError
    const s = ctx.findSensor("env").?;
    try std.testing.expect(s.error_state != null);
}

test "ingestMqttMessage: non-matching topic is ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = testCtx(std.testing.allocator);
    defer ctx.deinit();
    _ = try ctx.addSensor("chamber", .{ .type = "mqtt", .state_topic = "printer/chamber/state" });

    ctx.ingestMqttMessage("some/other/topic", "{\"temperature\":99}", arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), ctx.findSensor("chamber").?.last_measurements.count());
}

test "ingestMqttMessage: invalid JSON sets error_state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = testCtx(std.testing.allocator);
    defer ctx.deinit();
    _ = try ctx.addSensor("c", .{ .type = "mqtt", .state_topic = "t" });

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
            _ = try ctx.addSensor("c", .{ .type = "mqtt", .state_topic = "t" });
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
    _ = try ctx.addSensor("c", .{ .type = "mqtt", .state_topic = "t" });

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

test "sensors free partial fields and replaced records on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(alloc: std.mem.Allocator) !void {
            var core = @import("../server/core.zig").Core.init();
            var conns = @import("../server/connections.zig").Connections.init(alloc, &core);
            defer conns.deinit(std.testing.io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = SensorCtx.init(alloc, &bus);
            defer ctx.deinit();
            const first = try ctx.addSensor("test", .{ .type = "mqtt", .name = "T", .state_topic = "t", .state_response_template = "{ set_result(\"a\", 1) }" });
            try first.setMeasurement(alloc, "temperature", 20);
            try first.snapshotValues(alloc);
            try first.setMeasurement(alloc, "temperature", 21);
            const second = try ctx.addSensor(first.id, .{ .type = first.type_str });
            try std.testing.expectEqualStrings("test", second.id);
        }
    }.check, .{});
}
