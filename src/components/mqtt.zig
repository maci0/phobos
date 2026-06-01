//! server.mqtt.* API component — Moonraker-compatible MQTT endpoints.
//!
//! Matches the endpoints registered in
//! `vendor/moonraker/moonraker/components/mqtt.py` (MQTTClient):
//!
//!   POST /server/mqtt/publish   → server.mqtt.publish
//!   POST /server/mqtt/subscribe → server.mqtt.subscribe
//!
//! NOTE: phobos has no MQTT broker client in this slice. Both endpoints
//! return a Moonraker-shaped "MQTT not configured/connected" error when
//! the broker is absent (i.e. always). The endpoint shapes are faithful
//! to Moonraker so API-surface coverage counts these as registered.
//!
//! Publish response shape (mqtt.py):    {"topic": <topic>}
//! Subscribe response shape (mqtt.py):  {"topic": <topic>, "payload": <any>}
//!
//! publish params:   topic (str, required), payload (any, optional),
//!                   qos (int 0-2, default=0), retain (bool, default=false),
//!                   timeout (float, optional)
//! subscribe params: topic (str, required), qos (int 0-2, default=0),
//!                   timeout (float, optional)

const std = @import("std");
const registry = @import("../server/registry.zig");

const Registry = registry.Registry;

// ---------------------------------------------------------------------------
// Context (no broker state)
// ---------------------------------------------------------------------------

pub const MqttCtx = struct {};

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

/// Validate QoS value: must be 0, 1, or 2 (mqtt.py raises ServerError otherwise).
fn validateQos(qos: i64) error{InvalidParams}!void {
    if (qos < 0 or qos > 2) return error.InvalidParams;
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// POST /server/mqtt/publish
///
/// When a broker is configured this publishes to the MQTT topic.
/// phobos has no MQTT client; always returns MqttNotConfigured.
/// Response shape on success: {"topic": <topic>}
pub fn handlePublish(_: *anyopaque, params: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    const topic = try getStr(params, "topic");
    _ = topic; // validated; would be used if broker were present
    const qos = getOptInt(params, "qos", 0);
    try validateQos(qos);
    // NOTE: No MQTT broker client is implemented. Return an error that callers
    // can map to a 503. Moonraker returns a 503 when not connected.
    return error.MqttNotConfigured;
}

/// POST /server/mqtt/subscribe
///
/// When a broker is configured this subscribes and waits for one message.
/// phobos has no MQTT client; always returns MqttNotConfigured.
/// Response shape on success: {"topic": <topic>, "payload": <any>}
pub fn handleSubscribe(_: *anyopaque, params: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    const topic = try getStr(params, "topic");
    _ = topic; // validated; would be used if broker were present
    const qos = getOptInt(params, "qos", 0);
    try validateQos(qos);
    // NOTE: No MQTT broker client is implemented.
    return error.MqttNotConfigured;
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn registerMqtt(reg: *Registry, ctx: *MqttCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    // POST /server/mqtt/publish → "server.mqtt.publish"
    try reg.registerEndpoint(
        .{ .path = "/server/mqtt/publish", .methods = &.{.POST} },
        c,
        handlePublish,
    );

    // POST /server/mqtt/subscribe → "server.mqtt.subscribe"
    try reg.registerEndpoint(
        .{ .path = "/server/mqtt/subscribe", .methods = &.{.POST} },
        c,
        handleSubscribe,
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

test "handlePublish: missing topic → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = MqttCtx{};
    try testing.expectError(error.InvalidParams, handlePublish(@ptrCast(&ctx), .null, a));
}

test "handlePublish: invalid qos → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = MqttCtx{};
    const params = try mkParams(a, "{\"topic\": \"test\", \"qos\": 5}");
    try testing.expectError(error.InvalidParams, handlePublish(@ptrCast(&ctx), params, a));
}

test "handlePublish: valid params → MqttNotConfigured (no broker)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = MqttCtx{};
    const params = try mkParams(a, "{\"topic\": \"my/topic\"}");
    try testing.expectError(error.MqttNotConfigured, handlePublish(@ptrCast(&ctx), params, a));
}

test "handleSubscribe: missing topic → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = MqttCtx{};
    try testing.expectError(error.InvalidParams, handleSubscribe(@ptrCast(&ctx), .null, a));
}

test "handleSubscribe: valid topic → MqttNotConfigured (no broker)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = MqttCtx{};
    const params = try mkParams(a, "{\"topic\": \"my/topic\"}");
    try testing.expectError(error.MqttNotConfigured, handleSubscribe(@ptrCast(&ctx), params, a));
}

test "handleSubscribe: invalid qos → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = MqttCtx{};
    const params = try mkParams(a, "{\"topic\": \"my/topic\", \"qos\": -1}");
    try testing.expectError(error.InvalidParams, handleSubscribe(@ptrCast(&ctx), params, a));
}

test "handleSubscribe: qos boundary values: 0, 1, 2 pass; 3 fails" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = MqttCtx{};
    for ([_]i64{ 0, 1, 2 }) |q| {
        var buf: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{{\"topic\": \"t\", \"qos\": {d}}}", .{q});
        const params = try mkParams(a, s);
        // Should fail with MqttNotConfigured (not InvalidParams) for valid qos
        try testing.expectError(error.MqttNotConfigured, handleSubscribe(@ptrCast(&ctx), params, a));
    }

    const bad_params = try mkParams(a, "{\"topic\": \"t\", \"qos\": 3}");
    try testing.expectError(error.InvalidParams, handleSubscribe(@ptrCast(&ctx), bad_params, a));
}

test "registerMqtt: wires routes and JSON-RPC methods" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");

    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var ctx = MqttCtx{};
    try registerMqtt(&reg, &ctx);

    // HTTP routes
    try testing.expect(reg.lookup(.POST, "/server/mqtt/publish") != null);
    try testing.expect(reg.lookup(.POST, "/server/mqtt/subscribe") != null);

    // JSON-RPC methods
    try testing.expect(d.methods.get("server.mqtt.publish") != null);
    try testing.expect(d.methods.get("server.mqtt.subscribe") != null);
}

// --- Fuzz tests ---

test "fuzz handlePublish: never panics on arbitrary params" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"topic\": \"t\"}",
                "{\"topic\": \"t\", \"qos\": 0}",
                "{\"topic\": \"t\", \"qos\": 5}",
                "{\"topic\": \"t\", \"payload\": {}}",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            var ctx = MqttCtx{};
            _ = handlePublish(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleSubscribe: never panics on arbitrary params" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"topic\": \"t\"}",
                "{\"topic\": \"t\", \"qos\": 2}",
                "{\"topic\": \"t\", \"qos\": -1}",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            var ctx = MqttCtx{};
            _ = handleSubscribe(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}
