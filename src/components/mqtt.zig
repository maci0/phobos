//! server.mqtt.* API component — Moonraker-compatible MQTT endpoints.
//!
//! Matches the endpoints registered in
//! `vendor/moonraker/moonraker/components/mqtt.py` (MQTTClient):
//!
//!   POST /server/mqtt/publish   → server.mqtt.publish
//!   POST /server/mqtt/subscribe → server.mqtt.subscribe
//!
//! phobos has no MQTT broker client; no real broker connection is made.
//! When a broker is not configured (the default), both endpoints return a
//! Moonraker-shaped "MQTT not configured" error. When a broker IS configured
//! via `setConfig` (host/port), the publish/subscribe endpoints operate on an
//! in-memory message store: publish stores the last payload per topic,
//! subscribe returns the last stored payload. No real MQTT frames are
//! exchanged, but the API surface behaves faithfully.
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
// Context
// ---------------------------------------------------------------------------

/// Configuration for connecting to an MQTT broker.
pub const MqttConfig = struct {
    host: []const u8 = "",
    port: u16 = 1883,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

/// Per-topic stored message (last published payload).
const StoredMessage = struct {
    payload: std.json.Value,
};

pub const MqttCtx = struct {
    gpa: std.mem.Allocator,
    /// When non-null, the broker is "configured" and publish/subscribe
    /// operate on the in-memory store rather than returning errors.
    config: ?MqttConfig = null,
    /// Last published message per topic. Owned by ctx; freed in deinit.
    messages: std.StringHashMap(StoredMessage),
    /// Active subscriptions (tracked for notification emission when a message
    /// arrives for a subscribed topic). phobos has no broker client, so
    /// subscriptions are only stored; no callback is invoked.
    subscriptions: std.StringHashMap(void),

    pub fn init(gpa: std.mem.Allocator) MqttCtx {
        return .{
            .gpa = gpa,
            .messages = std.StringHashMap(StoredMessage).init(gpa),
            .subscriptions = std.StringHashMap(void).init(gpa),
        };
    }

    pub fn deinit(self: *MqttCtx) void {
        var it = self.messages.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
        }
        self.messages.deinit();
        var sit = self.subscriptions.iterator();
        while (sit.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
        }
        self.subscriptions.deinit();
        if (self.config) |*cfg| {
            self.gpa.free(cfg.host);
            if (cfg.username) |u| self.gpa.free(u);
            if (cfg.password) |p| self.gpa.free(p);
        }
    }

    /// Configure broker connection settings. Takes ownership of slices.
    pub fn setConfig(self: *MqttCtx, host: []const u8, port: u16, username: ?[]const u8, password: ?[]const u8) !void {
        const host_dup = try self.gpa.dupe(u8, host);
        errdefer self.gpa.free(host_dup);
        const user_dup: ?[]const u8 = if (username) |u| try self.gpa.dupe(u8, u) else null;
        errdefer if (user_dup) |u| self.gpa.free(u);
        const pass_dup: ?[]const u8 = if (password) |p| try self.gpa.dupe(u8, p) else null;
        errdefer if (pass_dup) |p| self.gpa.free(p);

        // Free old config if present.
        if (self.config) |*old| {
            self.gpa.free(old.host);
            if (old.username) |u| self.gpa.free(u);
            if (old.password) |p| self.gpa.free(p);
        }
        self.config = .{
            .host = host_dup,
            .port = port,
            .username = user_dup,
            .password = pass_dup,
        };
    }

    /// Returns true if a broker has been configured.
    pub fn isConfigured(self: *const MqttCtx) bool {
        return self.config != null;
    }

    /// Store a message for a topic. Called by handlePublish when broker is
    /// configured.
    fn storeMessage(self: *MqttCtx, topic: []const u8, payload: std.json.Value) !void {
        if (self.messages.getPtr(topic)) |existing| {
            existing.payload = payload;
            return;
        }
        const k = try self.gpa.dupe(u8, topic);
        errdefer self.gpa.free(k);
        try self.messages.put(k, .{ .payload = payload });
    }

    /// Get the last stored message for a topic (null if none).
    fn getMessage(self: *const MqttCtx, topic: []const u8) ?std.json.Value {
        return if (self.messages.get(topic)) |m| m.payload else null;
    }

    /// Add an active subscription. No-op if already subscribed.
    fn addSubscription(self: *MqttCtx, topic: []const u8) !void {
        if (self.subscriptions.contains(topic)) return;
        const k = try self.gpa.dupe(u8, topic);
        errdefer self.gpa.free(k);
        try self.subscriptions.put(k, {});
    }

    /// Check whether a topic has an active subscription.
    pub fn hasSubscription(self: *const MqttCtx, topic: []const u8) bool {
        return self.subscriptions.contains(topic);
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

fn getOptAny(params: std.json.Value, field: []const u8) ?std.json.Value {
    return switch (params) {
        .object => |obj| obj.get(field),
        else => null,
    };
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
/// When a broker is configured, stores the payload in the in-memory message
/// store and returns `{"topic": <topic>}`. When no broker is configured,
/// returns MqttNotConfigured (mapped to 503 by the transport).
/// Response shape on success: {"topic": <topic>}
pub fn handlePublish(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *MqttCtx = @ptrCast(@alignCast(ctx_ptr));
    const topic = try getStr(params, "topic");
    const qos = getOptInt(params, "qos", 0);
    try validateQos(qos);

    if (!ctx.isConfigured()) return error.MqttNotConfigured;

    // Store the payload (defaults to null if not provided — matches
    // Moonraker's `params.get('payload', None)`).
    const payload = getOptAny(params, "payload") orelse .null;
    try ctx.storeMessage(topic, payload);

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "topic", .{ .string = topic });
    return .{ .object = obj };
}

/// POST /server/mqtt/subscribe
///
/// When a broker is configured, subscribes to the topic (tracked in-memory)
/// and returns the last published message, if any. When no broker is
/// configured, returns MqttNotConfigured.
/// Response shape on success: {"topic": <topic>, "payload": <any>}
pub fn handleSubscribe(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *MqttCtx = @ptrCast(@alignCast(ctx_ptr));
    const topic = try getStr(params, "topic");
    const qos = getOptInt(params, "qos", 0);
    try validateQos(qos);

    if (!ctx.isConfigured()) return error.MqttNotConfigured;

    // Track the subscription (always successful in stub mode).
    try ctx.addSubscription(topic);

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "topic", .{ .string = topic });
    if (ctx.getMessage(topic)) |payload| {
        try obj.put(alloc, "payload", payload);
    } else {
        try obj.put(alloc, "payload", .null);
    }
    return .{ .object = obj };
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

fn testCtx(alloc: std.mem.Allocator) MqttCtx {
    return MqttCtx.init(alloc);
}

// ---- handlePublish (no broker) ----

test "handlePublish: missing topic → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = testCtx(a);
    defer ctx.deinit();
    try testing.expectError(error.InvalidParams, handlePublish(@ptrCast(&ctx), .null, a));
}

test "handlePublish: invalid qos → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = testCtx(a);
    defer ctx.deinit();
    const params = try mkParams(a, "{\"topic\": \"test\", \"qos\": 5}");
    try testing.expectError(error.InvalidParams, handlePublish(@ptrCast(&ctx), params, a));
}

test "handlePublish: valid params no broker → MqttNotConfigured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = testCtx(a);
    defer ctx.deinit();
    const params = try mkParams(a, "{\"topic\": \"my/topic\"}");
    try testing.expectError(error.MqttNotConfigured, handlePublish(@ptrCast(&ctx), params, a));
}

// ---- handleSubscribe (no broker) ----

test "handleSubscribe: missing topic → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = testCtx(a);
    defer ctx.deinit();
    try testing.expectError(error.InvalidParams, handleSubscribe(@ptrCast(&ctx), .null, a));
}

test "handleSubscribe: valid topic no broker → MqttNotConfigured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = testCtx(a);
    defer ctx.deinit();
    const params = try mkParams(a, "{\"topic\": \"my/topic\"}");
    try testing.expectError(error.MqttNotConfigured, handleSubscribe(@ptrCast(&ctx), params, a));
}

test "handleSubscribe: invalid qos → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = testCtx(a);
    defer ctx.deinit();
    const params = try mkParams(a, "{\"topic\": \"my/topic\", \"qos\": -1}");
    try testing.expectError(error.InvalidParams, handleSubscribe(@ptrCast(&ctx), params, a));
}

test "handleSubscribe: qos boundary values: 0, 1, 2 pass; 3 fails" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = testCtx(a);
    defer ctx.deinit();
    for ([_]i64{ 0, 1, 2 }) |q| {
        var buf: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{{\"topic\": \"t\", \"qos\": {d}}}", .{q});
        const params = try mkParams(a, s);
        try testing.expectError(error.MqttNotConfigured, handleSubscribe(@ptrCast(&ctx), params, a));
    }

    const bad_params = try mkParams(a, "{\"topic\": \"t\", \"qos\": 3}");
    try testing.expectError(error.InvalidParams, handleSubscribe(@ptrCast(&ctx), bad_params, a));
}

// ---- MqttCtx: config and message store ----

test "MqttCtx: setConfig and isConfigured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try testing.expect(!ctx.isConfigured());
    try ctx.setConfig("mqtt.local", 1883, null, null);
    try testing.expect(ctx.isConfigured());
    try testing.expectEqualStrings("mqtt.local", ctx.config.?.host);
    try testing.expectEqual(@as(u16, 1883), ctx.config.?.port);
}

test "MqttCtx: setConfig with credentials" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.setConfig("broker.local", 8883, "user", "pass");
    try testing.expectEqualStrings("user", ctx.config.?.username.?);
    try testing.expectEqualStrings("pass", ctx.config.?.password.?);
}

test "MqttCtx: store and retrieve messages" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.storeMessage("sensor/temp", .{ .float = 23.5 });
    const msg = ctx.getMessage("sensor/temp").?;
    try testing.expectEqual(@as(f64, 23.5), msg.float);

    // Unknown topic returns null.
    try testing.expect(ctx.getMessage("unknown") == null);
}

test "MqttCtx: store overwrites previous message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.storeMessage("test", .{ .integer = 1 });
    try ctx.storeMessage("test", .{ .integer = 2 });
    try testing.expectEqual(@as(i64, 2), ctx.getMessage("test").?.integer);
}

test "MqttCtx: subscriptions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try testing.expect(!ctx.hasSubscription("a"));
    try ctx.addSubscription("a");
    try testing.expect(ctx.hasSubscription("a"));
    // Double subscribe is a no-op.
    try ctx.addSubscription("a");
    try testing.expect(ctx.hasSubscription("a"));
    try testing.expect(!ctx.hasSubscription("b"));
}

// ---- handlePublish with broker configured ----

test "handlePublish: with broker stores message and returns topic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.setConfig("localhost", 1883, null, null);
    const params = try mkParams(a, "{\"topic\": \"test/foo\", \"payload\": \"hello\"}");
    const result = try handlePublish(@ptrCast(&ctx), params, a);
    try testing.expectEqualStrings("test/foo", result.object.get("topic").?.string);

    // Verify message was stored.
    try testing.expectEqualStrings("hello", ctx.getMessage("test/foo").?.string);
}

test "handlePublish: with broker, null payload stored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.setConfig("localhost", 1883, null, null);
    const params = try mkParams(a, "{\"topic\": \"no/payload\"}");
    _ = try handlePublish(@ptrCast(&ctx), params, a);
    try testing.expect(ctx.getMessage("no/payload").? == .null);
}

test "handlePublish: with broker, qos 0/1/2 all accepted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.setConfig("localhost", 1883, null, null);
    for ([_]i64{ 0, 1, 2 }) |q| {
        var buf: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{{\"topic\": \"t\", \"qos\": {d}}}", .{q});
        const params = try mkParams(a, s);
        const result = try handlePublish(@ptrCast(&ctx), params, a);
        try testing.expectEqualStrings("t", result.object.get("topic").?.string);
    }
}

// ---- handleSubscribe with broker configured ----

test "handleSubscribe: with broker, no prior message returns null payload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.setConfig("localhost", 1883, null, null);
    const params = try mkParams(a, "{\"topic\": \"fresh/topic\"}");
    const result = try handleSubscribe(@ptrCast(&ctx), params, a);
    try testing.expectEqualStrings("fresh/topic", result.object.get("topic").?.string);
    try testing.expect(result.object.get("payload").? == .null);

    // Subscription is now tracked.
    try testing.expect(ctx.hasSubscription("fresh/topic"));
}

test "handleSubscribe: with broker, returns last published message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.setConfig("localhost", 1883, null, null);

    _ = try handlePublish(@ptrCast(&ctx), try mkParams(a, "{\"topic\": \"sensor\", \"payload\": {\"temp\": 42}}"), a);

    const result = try handleSubscribe(@ptrCast(&ctx), try mkParams(a, "{\"topic\": \"sensor\"}"), a);
    try testing.expectEqualStrings("sensor", result.object.get("topic").?.string);
    const payload = result.object.get("payload").?.object;
    try testing.expectEqual(@as(i64, 42), payload.get("temp").?.integer);
}

test "handleSubscribe: publish-subscribe round-trip with multiple topics" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.setConfig("localhost", 1883, null, null);

    _ = try handlePublish(@ptrCast(&ctx), try mkParams(a, "{\"topic\": \"a\", \"payload\": \"val_a\"}"), a);
    _ = try handlePublish(@ptrCast(&ctx), try mkParams(a, "{\"topic\": \"b\", \"payload\": 99}"), a);

    const ra = try handleSubscribe(@ptrCast(&ctx), try mkParams(a, "{\"topic\": \"a\"}"), a);
    try testing.expectEqualStrings("val_a", ra.object.get("payload").?.string);

    const rb = try handleSubscribe(@ptrCast(&ctx), try mkParams(a, "{\"topic\": \"b\"}"), a);
    try testing.expectEqual(@as(i64, 99), rb.object.get("payload").?.integer);
}

// ---- registerMqtt ----

test "registerMqtt: wires routes and JSON-RPC methods" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");

    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var ctx = testCtx(alloc);
    defer ctx.deinit();
    try registerMqtt(&reg, &ctx);

    try testing.expect(reg.lookup(.POST, "/server/mqtt/publish") != null);
    try testing.expect(reg.lookup(.POST, "/server/mqtt/subscribe") != null);

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
            var ctx = MqttCtx.init(a);
            defer ctx.deinit();
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
            var ctx = MqttCtx.init(a);
            defer ctx.deinit();
            _ = handleSubscribe(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz publish-subscribe round-trip: arbitrary topics and payloads" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [32]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = MqttCtx.init(a);
            defer ctx.deinit();

            ctx.setConfig("localhost", 1883, null, null) catch return;

            const alphabet = "abcdefghijklmnopqrstuvwxyz/._";
            var topic_buf: [24]u8 = undefined;
            for (buf[0..@min(20, buf.len)], 0..) |b, i| {
                topic_buf[i] = alphabet[b % alphabet.len];
            }
            const topic = topic_buf[0..@min(16, @max(1, buf[0] % 20))];

            const pub_str = try std.fmt.allocPrint(a, "{{\"topic\":\"{s}\"}}", .{topic});
            const pub_pv = std.json.parseFromSlice(std.json.Value, a, pub_str, .{}) catch return;
            _ = handlePublish(@ptrCast(&ctx), pub_pv.value, a) catch {};

            const sub_str = try std.fmt.allocPrint(a, "{{\"topic\":\"{s}\"}}", .{topic});
            const sub_pv = std.json.parseFromSlice(std.json.Value, a, sub_str, .{}) catch return;
            _ = handleSubscribe(@ptrCast(&ctx), sub_pv.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz setConfig: never panics on arbitrary config values" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [32]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = MqttCtx.init(a);
            defer ctx.deinit();

            const alphabet = "abcdefghijklmnopqrstuvwxyz._-";
            var host_buf: [20]u8 = undefined;
            for (buf[0..@min(16, buf.len)], 0..) |b, i| {
                host_buf[i] = alphabet[b % alphabet.len];
            }
            const host = host_buf[0..@max(1, buf[0] % 16)];

            const port: u16 = @as(u16, buf[1]) * 256 + buf[2];
            ctx.setConfig(host, port, null, null) catch return;

            const pub_pv = std.json.parseFromSlice(std.json.Value, a, "{\"topic\":\"t\"}", .{}) catch return;
            _ = handlePublish(@ptrCast(&ctx), pub_pv.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz registerMqtt: never panics with registered routes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const alloc = std.heap.smp_allocator;
            const jsonrpc = @import("../jsonrpc.zig");

            var d = jsonrpc.Dispatcher.init(alloc);
            defer d.deinit();
            var reg = Registry.init(alloc, &d);
            defer reg.deinit();

            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = MqttCtx.init(a);
            defer ctx.deinit();

            registerMqtt(&reg, &ctx) catch return;

            _ = reg.lookup(.POST, "/server/mqtt/publish");
            _ = reg.lookup(.POST, "/server/mqtt/subscribe");
        }
    }.run, .{});
}
