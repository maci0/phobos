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
//! NOTE: No MQTT or Klippy sensor integration. This component exposes faithful
//! endpoint shapes; sensor data accumulation is stubbed out.

const std = @import("std");
const registry = @import("../server/registry.zig");

const Registry = registry.Registry;

// ---------------------------------------------------------------------------
// Context (no configured sensors)
// ---------------------------------------------------------------------------

pub const SensorCtx = struct {};

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

/// GET /server/sensors/list → {"sensors": {}}
/// With no configured sensors, returns an empty object.
/// extended param accepted but has no effect (no sensors to extend).
pub fn handleSensorList(_: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    _ = getOptBool(params, "extended", false); // param accepted, no-op
    var result: std.json.ObjectMap = .empty;
    try result.put(alloc, "sensors", .{ .object = .empty });
    return .{ .object = result };
}

/// GET /server/sensors/info → sensor info for a named sensor
/// Without sensors, always returns NotFound.
/// sensor param required; extended param optional.
pub fn handleSensorInfo(_: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    _ = alloc;
    const sensor_name = getOptStr(params, "sensor") orelse return error.InvalidParams;
    // No sensors configured in phobos without external integration
    _ = sensor_name;
    return error.NotFound;
}

/// GET /server/sensors/measurements → measurement history
/// With no sensor param: returns empty object (all sensors, none configured).
/// With sensor param: returns NotFound (no such sensor).
pub fn handleSensorMeasurements(_: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    _ = alloc;
    const sensor_name = getOptStr(params, "sensor") orelse "";
    if (sensor_name.len > 0) {
        return error.NotFound;
    }
    // Return empty object: all sensors → none
    return .{ .object = .empty };
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

test "handleSensorList: returns empty sensors object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = SensorCtx{};
    const result = try handleSensorList(@ptrCast(&ctx), .null, arena.allocator());
    const sensors = result.object.get("sensors").?;
    try testing.expect(sensors == .object);
    try testing.expectEqual(@as(usize, 0), sensors.object.count());
}

test "handleSensorList: extended param accepted without error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = SensorCtx{};
    const params = try mkParams(a, "{\"extended\":true}");
    const result = try handleSensorList(@ptrCast(&ctx), params, a);
    try testing.expect(result.object.get("sensors") != null);
}

test "handleSensorInfo: missing sensor param → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = SensorCtx{};
    try testing.expectError(error.InvalidParams, handleSensorInfo(@ptrCast(&ctx), .null, a));
    const params = try mkParams(a, "{}");
    try testing.expectError(error.InvalidParams, handleSensorInfo(@ptrCast(&ctx), params, a));
}

test "handleSensorInfo: named sensor → NotFound (no sensors)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = SensorCtx{};
    const params = try mkParams(a, "{\"sensor\":\"my_sensor\"}");
    try testing.expectError(error.NotFound, handleSensorInfo(@ptrCast(&ctx), params, a));
}

test "handleSensorMeasurements: no param → empty object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = SensorCtx{};
    const result = try handleSensorMeasurements(@ptrCast(&ctx), .null, a);
    try testing.expect(result == .object);
    try testing.expectEqual(@as(usize, 0), result.object.count());
}

test "handleSensorMeasurements: named sensor → NotFound (no sensors)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = SensorCtx{};
    const params = try mkParams(a, "{\"sensor\":\"my_sensor\"}");
    try testing.expectError(error.NotFound, handleSensorMeasurements(@ptrCast(&ctx), params, a));
}

test "handleSensorMeasurements: empty sensor string → all sensors (empty object)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = SensorCtx{};
    const params = try mkParams(a, "{\"sensor\":\"\"}");
    const result = try handleSensorMeasurements(@ptrCast(&ctx), params, a);
    try testing.expect(result == .object);
}

test "registerSensor: wires routes and JSON-RPC methods" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");

    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var ctx = SensorCtx{};
    try registerSensor(&reg, &ctx);

    try testing.expect(reg.lookup(.GET, "/server/sensors/list") != null);
    try testing.expect(reg.lookup(.GET, "/server/sensors/info") != null);
    try testing.expect(reg.lookup(.GET, "/server/sensors/measurements") != null);
    try testing.expect(d.methods.get("server.sensors.list") != null);
    try testing.expect(d.methods.get("server.sensors.info") != null);
    try testing.expect(d.methods.get("server.sensors.measurements") != null);
}

// --- Fuzz tests ---

test "fuzz handleSensorList: never crashes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var ctx = SensorCtx{};
            var buf: [4]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = handleSensorList(@ptrCast(&ctx), .null, arena.allocator()) catch {};
        }
    }.run, .{});
}

test "fuzz handleSensorInfo: arbitrary params never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = SensorCtx{};

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);

            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"sensor\":\"x\"}",
                "{\"sensor\":\"\"}",
                "{\"sensor\":null}",
                "{\"sensor\":42}",
                "1",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
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
            var ctx = SensorCtx{};

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);

            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"sensor\":\"x\"}",
                "{\"sensor\":\"\"}",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            _ = handleSensorMeasurements(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}
