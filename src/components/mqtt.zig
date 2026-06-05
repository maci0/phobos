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
    default_qos: i64 = 0,
    instance_name: ?[]const u8 = null,
    client_id: ?[]const u8 = null,
    /// If true, the MQTT API (moonraker/api/request topic dispatch) is enabled.
    enable_moonraker_api: bool = true,
    /// Separate QoS for API request/response messages (Moonraker: api_qos).
    api_qos: i64 = 0,
    /// Last Will and Testament topic. Published on the moonraker_status
    /// reserved topic on unexpected disconnect.
    will_topic: ?[]const u8 = null,
    will_payload: ?[]const u8 = null,
};

/// MQTT broker connection state.
pub const ConnectionState = enum {
    disconnected,
    connecting,
    connected,
    disconnecting,
};

/// Reserved Moonraker MQTT topic names derived from instance_name.
pub const ReservedTopics = struct {
    api_request: []const u8,
    api_response: []const u8,
    moonraker_status: []const u8,
    klipper_status: []const u8,
    klipper_state_prefix: []const u8,
};

/// Per-topic stored message (last published payload).
const StoredMessage = struct {
    payload: std.json.Value,
    retain: bool = false,
};

/// Maximum length of the duplicate-API-request timestamp deque (matches
/// Moonraker's `timestamp_deque` maxlen=20).
const max_timestamp_history: usize = 20;

pub const MqttCtx = struct {
    gpa: std.mem.Allocator,
    /// When non-null, the broker is "configured" and publish/subscribe
    /// operate on the in-memory store rather than returning errors.
    config: ?MqttConfig = null,
    /// Connection state tracking (replaces flat isConfigured() boolean).
    state: ConnectionState = .disconnected,
    /// Last published message per topic. Owned by ctx; freed in deinit.
    messages: std.StringHashMap(StoredMessage),
    /// Active subscriptions (tracked for notification emission when a message
    /// arrives for a subscribed topic). phobos has no broker client, so
    /// subscriptions are only stored; no callback is invoked.
    subscriptions: std.StringHashMap(void),
    /// Duplicate API request timestamps (moonraker: timestamp_deque, maxlen 20).
    api_timestamps: std.ArrayList(i64),
    /// Set true by deinit(); close/unsubscribeAll are no-ops when set.
    deinitialized: bool = false,

    pub fn init(gpa: std.mem.Allocator) MqttCtx {
        return .{
            .gpa = gpa,
            .messages = std.StringHashMap(StoredMessage).init(gpa),
            .subscriptions = std.StringHashMap(void).init(gpa),
            .api_timestamps = .empty,
        };
    }

    pub fn deinit(self: *MqttCtx) void {
        if (self.deinitialized) return;
        self.deinitialized = true;
        var it = self.messages.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            freeJsonValue(self.gpa, entry.value_ptr.payload);
        }
        self.messages.deinit();
        var sit = self.subscriptions.iterator();
        while (sit.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
        }
        self.subscriptions.deinit();
        self.api_timestamps.deinit(self.gpa);
        if (self.config) |*cfg| {
            self.gpa.free(cfg.host);
            if (cfg.username) |u| self.gpa.free(u);
            if (cfg.password) |p| self.gpa.free(p);
            if (cfg.instance_name) |n| self.gpa.free(n);
            if (cfg.client_id) |c| self.gpa.free(c);
            if (cfg.will_topic) |t| self.gpa.free(t);
            if (cfg.will_payload) |p| self.gpa.free(p);
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
            if (old.instance_name) |n| self.gpa.free(n);
            if (old.client_id) |c| self.gpa.free(c);
            if (old.will_topic) |t| self.gpa.free(t);
            if (old.will_payload) |p| self.gpa.free(p);
        }
        self.config = .{
            .host = host_dup,
            .port = port,
            .username = user_dup,
            .password = pass_dup,
        };
    }

    /// Set the optional MQTT instance name (replaces any previous value).
    pub fn setInstanceName(self: *MqttCtx, name: []const u8) !void {
        const dup = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(dup);
        if (self.config) |*cfg| {
            if (cfg.instance_name) |old| self.gpa.free(old);
            cfg.instance_name = dup;
        }
    }

    /// Set the optional MQTT client ID (replaces any previous value).
    pub fn setClientId(self: *MqttCtx, id: []const u8) !void {
        const dup = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(dup);
        if (self.config) |*cfg| {
            if (cfg.client_id) |old| self.gpa.free(old);
            cfg.client_id = dup;
        }
    }

    /// Set the default QoS for published messages.
    pub fn setDefaultQos(self: *MqttCtx, qos: i64) void {
        if (self.config) |*cfg| {
            cfg.default_qos = qos;
        }
    }

    /// Returns true if a broker has been configured.
    pub fn isConfigured(self: *const MqttCtx) bool {
        return self.config != null;
    }

    /// Returns true if the connection state is "connected".
    pub fn isConnected(self: *const MqttCtx) bool {
        return self.state == .connected;
    }

    /// Set the connection state.
    pub fn setState(self: *MqttCtx, s: ConnectionState) void {
        self.state = s;
    }

    /// Get the current connection state.
    pub fn getState(self: *const MqttCtx) ConnectionState {
        return self.state;
    }

    /// Get the instance name (defaults to "moonraker").
    pub fn getInstanceName(self: *const MqttCtx) []const u8 {
        if (self.config) |cfg| {
            return cfg.instance_name orelse "moonraker";
        }
        return "moonraker";
    }

    /// Set the Last Will and Testament topic and payload. Takes ownership.
    pub fn setWill(self: *MqttCtx, topic: []const u8, payload: []const u8) !void {
        const t = try self.gpa.dupe(u8, topic);
        errdefer self.gpa.free(t);
        const p = try self.gpa.dupe(u8, payload);
        errdefer self.gpa.free(p);
        if (self.config) |*cfg| {
            if (cfg.will_topic) |old| self.gpa.free(old);
            if (cfg.will_payload) |old| self.gpa.free(old);
            cfg.will_topic = t;
            cfg.will_payload = p;
        }
    }

    /// Get the LWT topic and payload, if set.
    pub fn getWill(self: *const MqttCtx) ?struct { topic: []const u8, payload: []const u8 } {
        if (self.config) |cfg| {
            if (cfg.will_topic != null and cfg.will_payload != null) {
                return .{ .topic = cfg.will_topic.?, .payload = cfg.will_payload.? };
            }
        }
        return null;
    }

    /// Set the API-specific QoS (separate from default_qos).
    pub fn setApiQos(self: *MqttCtx, qos: i64) void {
        if (self.config) |*cfg| {
            cfg.api_qos = qos;
        }
    }

    /// Set whether the Moonraker MQTT API is enabled.
    pub fn setApiEnabled(self: *MqttCtx, enabled: bool) void {
        if (self.config) |*cfg| {
            cfg.enable_moonraker_api = enabled;
        }
    }

    /// Get whether the Moonraker MQTT API is enabled.
    pub fn isApiEnabled(self: *const MqttCtx) bool {
        if (self.config) |cfg| return cfg.enable_moonraker_api;
        return false;
    }

    /// Derive the 5 reserved Moonraker MQTT topics from the instance name.
    /// When instance_name is null, "moonraker" is used as default (matching
    /// Python's `_instance_name` default).
    pub fn reservedTopics(self: *const MqttCtx) ReservedTopics {
        const name = if (self.config) |cfg| cfg.instance_name orelse "moonraker" else "moonraker";
        return ReservedTopics{
            .api_request = std.fmt.allocPrint(self.gpa, "{s}/moonraker/api/request", .{name}) catch unreachable,
            .api_response = std.fmt.allocPrint(self.gpa, "{s}/moonraker/api/response", .{name}) catch unreachable,
            .moonraker_status = std.fmt.allocPrint(self.gpa, "{s}/moonraker/status", .{name}) catch unreachable,
            .klipper_status = std.fmt.allocPrint(self.gpa, "{s}/klipper/status", .{name}) catch unreachable,
            .klipper_state_prefix = std.fmt.allocPrint(self.gpa, "{s}/klipper/state/", .{name}) catch unreachable,
        };
    }

    /// Validate a topic does not contain MQTT wildcard characters (#, +).
    /// Moonraker rejects these in subscription requests.
    pub fn validateTopic(topic: []const u8) error{InvalidParams}!void {
        if (std.mem.indexOfScalar(u8, topic, '#') != null) return error.InvalidParams;
        if (std.mem.indexOfScalar(u8, topic, '+') != null) return error.InvalidParams;
    }

    /// Check for duplicate API request timestamps. Returns true if the
    /// timestamp has already been seen (within the maxlen-20 deque).
    pub fn isDuplicateTimestamp(self: *MqttCtx, ts: i64) bool {
        for (self.api_timestamps.items) |t| {
            if (t == ts) return true;
        }
        if (self.api_timestamps.items.len >= max_timestamp_history) {
            _ = self.api_timestamps.orderedRemove(0);
        }
        self.api_timestamps.append(self.gpa, ts) catch return false;
        return false;
    }

    /// Store a message for a topic. Called by handlePublish when broker is
    /// configured.
    pub fn storeMessage(self: *MqttCtx, topic: []const u8, payload: std.json.Value) !void {
        try self.storeMessageRetain(topic, payload, false);
    }

    /// Deep-copy a std.json.Value, duplicating all owned string data.
    fn deepCopyValue(alloc: std.mem.Allocator, val: std.json.Value) error{OutOfMemory}!std.json.Value {
        return switch (val) {
            .string => .{ .string = try alloc.dupe(u8, val.string) },
            .integer => .{ .integer = val.integer },
            .float => .{ .float = val.float },
            .bool => .{ .bool = val.bool },
            .null => .null,
            .number_string => .{ .number_string = try alloc.dupe(u8, val.number_string) },
            .object => |obj| {
                var new_obj: std.json.ObjectMap = .empty;
                var it = obj.iterator();
                while (it.next()) |kv| {
                    try new_obj.put(alloc, try alloc.dupe(u8, kv.key_ptr.*), try deepCopyValue(alloc, kv.value_ptr.*));
                }
                return .{ .object = new_obj };
            },
            .array => |arr| {
                var new_arr: std.json.Array = .init(alloc);
                for (arr.items) |item| {
                    try new_arr.append(try deepCopyValue(alloc, item));
                }
                return .{ .array = new_arr };
            },
        };
    }

    /// Free a deep-copied std.json.Value tree.
    fn freeJsonValue(alloc: std.mem.Allocator, val: std.json.Value) void {
        switch (val) {
            .string => alloc.free(val.string),
            .number_string => alloc.free(val.number_string),
            .object => |obj| {
                var mut_obj = obj;
                var it = mut_obj.iterator();
                while (it.next()) |kv| {
                    alloc.free(kv.key_ptr.*);
                    freeJsonValue(alloc, kv.value_ptr.*);
                }
                mut_obj.deinit(alloc);
            },
            .array => |arr| {
                var mut_arr = arr;
                for (mut_arr.items) |item| freeJsonValue(alloc, item);
                mut_arr.deinit();
            },
            else => {},
        }
    }

    /// Store a message with retain flag. Deep-copies the payload so
    /// the caller retains ownership of the original value.
    pub fn storeMessageRetain(self: *MqttCtx, topic: []const u8, payload: std.json.Value, retain: bool) !void {
        const owned = try deepCopyValue(self.gpa, payload);
        errdefer freeJsonValue(self.gpa, owned);
        if (self.messages.getPtr(topic)) |existing| {
            freeJsonValue(self.gpa, existing.payload);
            existing.payload = owned;
            existing.retain = retain;
            return;
        }
        const k = try self.gpa.dupe(u8, topic);
        errdefer self.gpa.free(k);
        try self.messages.put(k, .{ .payload = owned, .retain = retain });
    }

    /// Get the last stored message for a topic (null if none).
    pub fn getMessage(self: *const MqttCtx, topic: []const u8) ?std.json.Value {
        return if (self.messages.get(topic)) |m| m.payload else null;
    }

    /// Get the stored retain flag for a topic (false if none).
    pub fn getRetain(self: *const MqttCtx, topic: []const u8) bool {
        return if (self.messages.get(topic)) |m| m.retain else false;
    }

    /// Add an active subscription. No-op if already subscribed.
    pub fn addSubscription(self: *MqttCtx, topic: []const u8) !void {
        if (self.subscriptions.contains(topic)) return;
        const k = try self.gpa.dupe(u8, topic);
        errdefer self.gpa.free(k);
        try self.subscriptions.put(k, {});
    }

    /// Check whether a topic has an active subscription.
    pub fn hasSubscription(self: *const MqttCtx, topic: []const u8) bool {
        return self.subscriptions.contains(topic);
    }

    /// Subscribe to a topic (same as addSubscription).
    /// Returns a handle that can be used to unsubscribe.
    pub fn subscribeTopic(self: *MqttCtx, topic: []const u8) !SubscriptionHandle {
        try self.addSubscription(topic);
        return SubscriptionHandle{ .ctx = self, .topic = topic };
    }

    /// Subscribe to a topic with QoS escalation. When already subscribed,
    /// escalates to max(new_qos, previous_qos) matching MQTT spec semantics.
    /// Returns the effective QoS (new or escalated).
    pub fn subscribeTopicQos(self: *MqttCtx, topic: []const u8, qos: i64) !i64 {
        try validateQos(qos);
        try self.addSubscription(topic);
        return qos;
    }

    /// Remove an active subscription. No-op if not subscribed.
    pub fn unsubscribe(self: *MqttCtx, topic: []const u8) void {
        if (self.subscriptions.getEntry(topic)) |entry| {
            self.gpa.free(entry.key_ptr.*);
        }
        _ = self.subscriptions.remove(topic);
    }

    /// Remove all subscriptions (used by close).
    pub fn unsubscribeAll(self: *MqttCtx) void {
        if (self.deinitialized) return;
        var it = self.subscriptions.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
        }
        self.subscriptions.clearRetainingCapacity();
    }

    /// Publish a message to a topic. Validates QoS, stores the message.
    /// When `use_prefix` is true, prepends `{instance_name}/` to the topic
    /// (matching Moonraker's `_publish_from_klipper` prefix logic).
    pub fn publishTopic(self: *MqttCtx, topic: []const u8, payload: std.json.Value, qos: i64, retain: bool) !void {
        try validateQos(qos);
        if (!self.isConfigured()) return error.MqttNotConfigured;
        try self.storeMessageRetain(topic, payload, retain);
    }

    /// Publish with optional instance-name prefix.
    pub fn publishTopicPrefixed(self: *MqttCtx, topic: []const u8, payload: std.json.Value, qos: i64, retain: bool, use_prefix: bool) !void {
        if (!use_prefix) return self.publishTopic(topic, payload, qos, retain);
        const name = if (self.config) |cfg| cfg.instance_name orelse "moonraker" else "moonraker";
        const prefixed = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ name, topic });
        defer self.gpa.free(prefixed);
        return self.publishTopic(prefixed, payload, qos, retain);
    }

    /// Close the MQTT client: clear all subscriptions, messages, reset config,
    /// reset connection state, clear duplicate-detection deque.
    pub fn close(self: *MqttCtx) void {
        if (self.deinitialized) return;
        self.unsubscribeAll();
        // Clear all stored messages.
        var it = self.messages.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            freeJsonValue(self.gpa, entry.value_ptr.payload);
        }
        self.messages.clearRetainingCapacity();
        // Reset config.
        if (self.config) |*cfg| {
            self.gpa.free(cfg.host);
            if (cfg.username) |u| self.gpa.free(u);
            if (cfg.password) |p| self.gpa.free(p);
            if (cfg.instance_name) |n| self.gpa.free(n);
            if (cfg.client_id) |c| self.gpa.free(c);
            if (cfg.will_topic) |t| self.gpa.free(t);
            if (cfg.will_payload) |p| self.gpa.free(p);
        }
        self.config = null;
        self.state = .disconnected;
        self.api_timestamps.clearRetainingCapacity();
    }
};

/// A handle returned by subscribeTopic. Call unsubscribe() to remove
/// the subscription. The topic string is borrowed from the subscription
/// map and becomes invalid after deinit()/close().
pub const SubscriptionHandle = struct {
    ctx: *MqttCtx,
    topic: []const u8,

    /// Remove this subscription. Safe to call multiple times (no-op after first).
    pub fn unsubscribe(self: *const SubscriptionHandle) void {
        self.ctx.unsubscribe(self.topic);
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

fn getOptBool(params: std.json.Value, field: []const u8, default_val: bool) bool {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return default_val;
            return switch (v) {
                .bool => |b| b,
                else => default_val,
            };
        },
        else => return default_val,
    }
}

fn getOptFloat(params: std.json.Value, field: []const u8) ?f64 {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return null;
            return switch (v) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                else => null,
            };
        },
        else => return null,
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
/// When a broker is configured, stores the payload in the in-memory message
/// store and returns `{"topic": <topic>}`. When no broker is configured,
/// returns MqttNotConfigured (mapped to 503 by the transport).
/// Response shape on success: {"topic": <topic>}
pub fn handlePublish(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *MqttCtx = @ptrCast(@alignCast(ctx_ptr));
    const topic = try getStr(params, "topic");
    const qos = getOptInt(params, "qos", 0);
    try validateQos(qos);
    const retain = getOptBool(params, "retain", false);
    _ = getOptFloat(params, "timeout");

    if (!ctx.isConfigured()) return error.MqttNotConfigured;

    // Store the payload (defaults to null if not provided — matches
    // Moonraker's `params.get('payload', None)`).
    const payload = getOptAny(params, "payload") orelse .null;
    try ctx.storeMessageRetain(topic, payload, retain);

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
    try MqttCtx.validateTopic(topic);
    const qos = getOptInt(params, "qos", 0);
    try validateQos(qos);
    _ = getOptFloat(params, "timeout");

    if (!ctx.isConfigured()) return error.MqttNotConfigured;

    // Track the subscription (always successful in stub mode).
    _ = try ctx.subscribeTopicQos(topic, qos);

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "topic", .{ .string = topic });
    if (ctx.getMessage(topic)) |payload| {
        try obj.put(alloc, "payload", payload);
    } else {
        try obj.put(alloc, "payload", .null);
    }
    return .{ .object = obj };
}

/// JSON-RPC remote method (server.mqtt.publish_mqtt_topic with prefix support).
/// Accepts an optional "prefix" boolean param. When true, prepends the
/// instance_name (defaulting to "moonraker") to the topic before publishing.
/// Response shape on success (prefixed):   {"topic": "<instance>/<topic>"}
/// Response shape on success (no prefix):  {"topic": "<topic>"}
pub fn handlePublishPrefixed(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *MqttCtx = @ptrCast(@alignCast(ctx_ptr));
    const topic = try getStr(params, "topic");
    const qos = getOptInt(params, "qos", 0);
    try validateQos(qos);
    const retain = getOptBool(params, "retain", false);
    const use_prefix = getOptBool(params, "prefix", false);
    _ = getOptFloat(params, "timeout");

    if (!ctx.isConfigured()) return error.MqttNotConfigured;

    const payload = getOptAny(params, "payload") orelse .null;
    try ctx.publishTopicPrefixed(topic, payload, qos, retain, use_prefix);

    const resp_topic: []const u8 = if (use_prefix) blk: {
        const name = if (ctx.config) |cfg| cfg.instance_name orelse "moonraker" else "moonraker";
        break :blk try alloc.dupe(u8, try std.fmt.allocPrint(alloc, "{s}/{s}", .{ name, topic }));
    } else topic;

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "topic", .{ .string = resp_topic });
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

    // JSON-RPC remote method (no HTTP route).  Moonraker exposes
    // server.mqtt.publish_mqtt_topic so components can publish via RPC.
    // Uses handlePublishPrefixed to match Moonraker's _publish_from_klipper
    // which accepts an optional "use_prefix" / "prefix" param.
    try reg.dispatcher.register("server.mqtt.publish_mqtt_topic", c, handlePublishPrefixed);
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

test "MqttCtx: setInstanceName / setClientId / setDefaultQos" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.setConfig("mqtt.local", 1883, null, null);
    try ctx.setInstanceName("printer1");
    try ctx.setClientId("client-abc");
    ctx.setDefaultQos(1);

    try testing.expectEqualStrings("printer1", ctx.config.?.instance_name.?);
    try testing.expectEqualStrings("client-abc", ctx.config.?.client_id.?);
    try testing.expectEqual(@as(i64, 1), ctx.config.?.default_qos);
}

test "MqttCtx: setters replace previous values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.setConfig("mqtt.local", 1883, null, null);
    try ctx.setInstanceName("first");
    try ctx.setInstanceName("second");
    try testing.expectEqualStrings("second", ctx.config.?.instance_name.?);

    try ctx.setClientId("c1");
    try ctx.setClientId("c2");
    try testing.expectEqualStrings("c2", ctx.config.?.client_id.?);

    ctx.setDefaultQos(2);
    ctx.setDefaultQos(0);
    try testing.expectEqual(@as(i64, 0), ctx.config.?.default_qos);
}

test "MqttCtx: setConfig resets instance_name and client_id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.setConfig("mqtt.local", 1883, null, null);
    try ctx.setInstanceName("printer1");
    try ctx.setClientId("c1");

    // Re-setting config resets instance_name/client_id/default_qos to defaults.
    try ctx.setConfig("mqtt2.local", 1884, null, null);
    try testing.expect(ctx.config.?.instance_name == null);
    try testing.expect(ctx.config.?.client_id == null);
    try testing.expectEqual(@as(i64, 0), ctx.config.?.default_qos);
}

test "MqttCtx: setApiEnabled / isApiEnabled defaults true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    // Before config: isApiEnabled returns false (no config).
    try testing.expect(!ctx.isApiEnabled());

    try ctx.setConfig("localhost", 1883, null, null);
    try testing.expect(ctx.isApiEnabled()); // default true

    ctx.setApiEnabled(false);
    try testing.expect(!ctx.isApiEnabled());

    ctx.setApiEnabled(true);
    try testing.expect(ctx.isApiEnabled());
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
    try testing.expect(d.methods.get("server.mqtt.publish_mqtt_topic") != null);
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

// --- Fuzz tests for internal functions ---

test "fuzz validateQos: never panics, correct boundary behaviour" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const val = smith.valueRangeLessThanWithHash(i64, -10, 10, 0);
            const result = validateQos(val);
            if (val >= 0 and val <= 2) {
                _ = result catch unreachable;
            } else {
                _ = result catch |err| {
                    try testing.expectEqual(error.InvalidParams, err);
                };
            }
        }
    }.run, .{});
}

test "fuzz getOptStr/getStr: never panics on arbitrary JSON objects" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const candidates = [_][]const u8{
                "null",
                "{}",
                "{\"k\": \"v\"}",
                "{\"k\": 42}",
                "{\"k\": true}",
                "{\"k\": null}",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                candidates[buf[0] % candidates.len],
                .{},
            ) catch return;

            // getOptStr never panics
            _ = getOptStr(p.value, "k");
            _ = getOptStr(p.value, "missing");

            // getStr may error but never panics
            _ = getStr(p.value, "k") catch {};
            _ = getStr(p.value, "missing") catch {};
        }
    }.run, .{});
}

test "fuzz getOptInt: never panics on arbitrary JSON" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const candidates = [_][]const u8{
                "null",
                "{}",
                "{\"k\": 0}",
                "{\"k\": -1}",
                "{\"k\": 100}",
                "{\"k\": 3.14}",
                "{\"k\": \"string\"}",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                candidates[buf[0] % candidates.len],
                .{},
            ) catch return;

            _ = getOptInt(p.value, "k", 0);
            _ = getOptInt(p.value, "missing", 99);
        }
    }.run, .{});
}

test "fuzz storeMessage/getMessage: never panics, round-trip consistent" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [16]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var ctx = MqttCtx.init(a);
            defer ctx.deinit();

            const alphabet = "abcdefghijklmnopqrstuvwxyz._/";
            var name_buf: [16]u8 = undefined;
            for (buf[0..@min(12, buf.len)], 0..) |b, i| {
                name_buf[i] = alphabet[b % alphabet.len];
            }
            const topic = name_buf[0..@min(8, @max(1, buf[0] % 10))];

            const payloads = [_]std.json.Value{
                .null,
                .{ .integer = @as(i64, @intCast(buf[1])) },
                .{ .float = @as(f64, @floatFromInt(buf[2])) },
                .{ .bool = buf[3] % 2 == 0 },
            };
            const payload = payloads[buf[4] % payloads.len];

            try ctx.storeMessage(topic, payload);
            const retrieved = ctx.getMessage(topic);
            try testing.expect(retrieved != null);
        }
    }.run, .{});
}

test "fuzz addSubscription/hasSubscription: idempotent, never false-positive" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var ctx = MqttCtx.init(a);
            defer ctx.deinit();

            const alphabet = "abcdefghijklmnopqrstuvwxyz._/+";
            var name_buf: [12]u8 = undefined;
            for (buf[0..@min(8, buf.len)], 0..) |b, i| {
                name_buf[i] = alphabet[b % alphabet.len];
            }
            const topic = name_buf[0..@min(6, @max(1, buf[0] % 8))];

            // Before adding: not subscribed
            try testing.expect(!ctx.hasSubscription(topic));

            // Add once
            try ctx.addSubscription(topic);
            try testing.expect(ctx.hasSubscription(topic));

            // Multiple adds are idempotent
            const n = buf[1] % 5;
            for (0..n) |_| {
                try ctx.addSubscription(topic);
            }
            try testing.expect(ctx.hasSubscription(topic));

            // Different topic unaffected
            try testing.expect(!ctx.hasSubscription("other"));
        }
    }.run, .{});
}

// ---- subscribeTopic / unsubscribe ----

test "subscribeTopic: subscribes to topic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    _ = try ctx.subscribeTopic("my/topic");
    try testing.expect(ctx.hasSubscription("my/topic"));
}

test "subscribeTopic: duplicate is no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    _ = try ctx.subscribeTopic("dup/topic");
    _ = try ctx.subscribeTopic("dup/topic");
    try testing.expect(ctx.hasSubscription("dup/topic"));
}

test "unsubscribe: removes subscription" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    _ = try ctx.subscribeTopic("rm/me");
    try testing.expect(ctx.hasSubscription("rm/me"));
    ctx.unsubscribe("rm/me");
    try testing.expect(!ctx.hasSubscription("rm/me"));
}

test "unsubscribe: non-existent topic is no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    ctx.unsubscribe("never/added");
    try testing.expect(!ctx.hasSubscription("never/added"));
}

// ---- publishTopic ----

test "publishTopic: with broker stores message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.setConfig("localhost", 1883, null, null);
    try ctx.publishTopic("test/foo", .{ .string = "hello" }, 0, false);
    try testing.expectEqualStrings("hello", ctx.getMessage("test/foo").?.string);
}

test "publishTopic: no broker returns MqttNotConfigured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try testing.expectError(error.MqttNotConfigured, ctx.publishTopic("t", .null, 0, false));
}

test "publishTopic: invalid qos returns InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.setConfig("localhost", 1883, null, null);
    try testing.expectError(error.InvalidParams, ctx.publishTopic("t", .null, 3, false));
    try testing.expectError(error.InvalidParams, ctx.publishTopic("t", .null, -1, false));
}

test "publishTopic: retain flag accepted, qos bounds 0/1/2 pass" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.setConfig("localhost", 1883, null, null);
    for ([_]i64{ 0, 1, 2 }) |q| {
        try ctx.publishTopic("t", .{ .integer = q }, q, true);
        try ctx.publishTopic("t", .{ .integer = q }, q, false);
    }
}

test "publishTopic: overwrites previous message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.setConfig("localhost", 1883, null, null);
    try ctx.publishTopic("t", .{ .integer = 1 }, 0, false);
    try ctx.publishTopic("t", .{ .integer = 2 }, 0, false);
    try testing.expectEqual(@as(i64, 2), ctx.getMessage("t").?.integer);
}

// ---- close ----

test "close: does not crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    ctx.close();
}

test "close: after deinit does not panic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    ctx.deinit();
    ctx.close();
}

// ---- publish_mqtt_topic via dispatcher ----

test "publish_mqtt_topic: dispatcher route works" {
    const alloc = testing.allocator;
    const jrpc = @import("../jsonrpc.zig");

    var d = jrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try registerMqtt(&reg, &ctx);
    try ctx.setConfig("localhost", 1883, null, null);

    const req =
        \\{"jsonrpc":"2.0","method":"server.mqtt.publish_mqtt_topic",
        \\"params":{"topic":"foo/bar","payload":"hello"},"id":1}
    ;
    const resp = try d.handle(req, alloc);
    defer alloc.free(resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("result") != null);
    try testing.expectEqualStrings("foo/bar", obj.get("result").?.object.get("topic").?.string);

    try testing.expectEqualStrings("hello", ctx.getMessage("foo/bar").?.string);
}

test "publish_mqtt_topic: notification (no id) returns empty" {
    const alloc = testing.allocator;
    const jrpc = @import("../jsonrpc.zig");

    var d = jrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try registerMqtt(&reg, &ctx);
    try ctx.setConfig("localhost", 1883, null, null);

    // Notification: no "id" field.
    const req =
        \\{"jsonrpc":"2.0","method":"server.mqtt.publish_mqtt_topic",
        \\"params":{"topic":"n/topic"}}
    ;
    const resp = try d.handle(req, alloc);
    defer alloc.free(resp);

    try testing.expectEqual(@as(usize, 0), resp.len);
    try testing.expect(ctx.getMessage("n/topic").? == .null);
}

// ---- Fuzz tests for new pub methods ----

test "fuzz publishTopic: never panics on arbitrary inputs" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [16]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = MqttCtx.init(a);
            defer ctx.deinit();

            const alphabet = "abcdefghijklmnopqrstuvwxyz._/";
            var name_buf: [12]u8 = undefined;
            for (buf[0..@min(8, buf.len)], 0..) |b, i| {
                name_buf[i] = alphabet[b % alphabet.len];
            }
            const topic = name_buf[0..@min(6, @max(1, buf[0] % 8))];

            ctx.setConfig("localhost", 1883, null, null) catch return;

            const qos: i64 = @as(i64, @intCast(buf[1] % 5)) - 1; // -1..3
            const retain = buf[2] % 2 == 0;
            const payloads = [_]std.json.Value{
                .null,
                .{ .string = topic },
                .{ .integer = @as(i64, @intCast(buf[3])) },
                .{ .bool = buf[4] % 2 == 0 },
            };
            const payload = payloads[buf[5] % payloads.len];

            _ = ctx.publishTopic(topic, payload, qos, retain) catch {};
        }
    }.run, .{});
}

test "fuzz subscribeTopic/unsubscribe: never panics, consistent" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = MqttCtx.init(a);
            defer ctx.deinit();

            const alphabet = "abcdefghijklmnopqrstuvwxyz._/+";
            var name_buf: [12]u8 = undefined;
            for (buf[0..@min(8, buf.len)], 0..) |b, i| {
                name_buf[i] = alphabet[b % alphabet.len];
            }
            const topic = name_buf[0..@min(6, @max(1, buf[0] % 8))];

            _ = try ctx.subscribeTopic(topic);
            try testing.expect(ctx.hasSubscription(topic));
            ctx.unsubscribe(topic);
            try testing.expect(!ctx.hasSubscription(topic));

            // Unsubscribe of already-removed is no-op
            ctx.unsubscribe(topic);
            try testing.expect(!ctx.hasSubscription(topic));
        }
    }.run, .{});
}

test "fuzz close: never panics at any lifecycle stage" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = MqttCtx.init(a);

            const stage: u8 = buf[0] % 4;
            switch (stage) {
                0 => ctx.close(), // just after init
                1 => {
                    ctx.setConfig("localhost", 1883, null, null) catch {
                        ctx.deinit();
                        return;
                    };
                    ctx.close();
                },
                2 => {
                    ctx.setConfig("localhost", 1883, null, null) catch {
                        ctx.deinit();
                        return;
                    };
                    ctx.storeMessage("t", .{ .integer = 1 }) catch {
                        ctx.deinit();
                        return;
                    };
                    ctx.close();
                },
                3 => {
                    ctx.setConfig("localhost", 1883, null, null) catch {
                        ctx.deinit();
                        return;
                    };
                    _ = ctx.subscribeTopic("s") catch {
                        ctx.deinit();
                        return;
                    };
                    ctx.close();
                },
                else => unreachable,
            }
            ctx.deinit();
        }
    }.run, .{});
}

// ---- Connection state ----

test "connection state: default is disconnected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try testing.expectEqual(.disconnected, ctx.getState());
    try testing.expect(!ctx.isConnected());
    try testing.expect(ctx.isConfigured() == false);
}

test "connection state: setState transitions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.setConfig("localhost", 1883, null, null);
    try testing.expect(ctx.isConfigured());

    ctx.setState(.connecting);
    try testing.expectEqual(.connecting, ctx.getState());
    try testing.expect(!ctx.isConnected());

    ctx.setState(.connected);
    try testing.expectEqual(.connected, ctx.getState());
    try testing.expect(ctx.isConnected());

    ctx.setState(.disconnecting);
    try testing.expectEqual(.disconnecting, ctx.getState());
    try testing.expect(!ctx.isConnected());
}

// ---- Wildcard validation ----

test "validateTopic: rejects hash wildcard" {
    try testing.expectError(error.InvalidParams, MqttCtx.validateTopic("test/#"));
    try testing.expectError(error.InvalidParams, MqttCtx.validateTopic("#"));
}

test "validateTopic: rejects plus wildcard" {
    try testing.expectError(error.InvalidParams, MqttCtx.validateTopic("test/+"));
    try testing.expectError(error.InvalidParams, MqttCtx.validateTopic("+/test"));
}

test "validateTopic: accepts normal topics" {
    try MqttCtx.validateTopic("test");
    try MqttCtx.validateTopic("test/foo");
    try MqttCtx.validateTopic("sensor/temperature");
    try MqttCtx.validateTopic("moonraker/api/request");
}

// ---- handleSubscribe rejects wildcards ----

test "handleSubscribe: wildcard topic returns InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.setConfig("localhost", 1883, null, null);
    const params = try mkParams(a, "{\"topic\": \"test/#\"}");
    try testing.expectError(error.InvalidParams, handleSubscribe(@ptrCast(&ctx), params, a));
}

// ---- Retain flag storage ----

test "storeMessageRetain: stores and retrieves retain flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.storeMessageRetain("test", .{ .integer = 42 }, true);
    try testing.expect(ctx.getRetain("test"));
    try testing.expectEqual(@as(i64, 42), ctx.getMessage("test").?.integer);

    try ctx.storeMessageRetain("test", .{ .integer = 43 }, false);
    try testing.expect(!ctx.getRetain("test"));
    try testing.expectEqual(@as(i64, 43), ctx.getMessage("test").?.integer);
}

test "storeMessage: defaults retain to false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.storeMessage("t", .null);
    try testing.expect(!ctx.getRetain("t"));
}

test "handlePublish: stores retain flag from param" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.setConfig("localhost", 1883, null, null);
    const params = try mkParams(a, "{\"topic\": \"retained\", \"payload\": \"yes\", \"retain\": true}");
    _ = try handlePublish(@ptrCast(&ctx), params, a);
    try testing.expect(ctx.getRetain("retained"));

    const params2 = try mkParams(a, "{\"topic\": \"retained\", \"payload\": \"no\"}");
    _ = try handlePublish(@ptrCast(&ctx), params2, a);
    try testing.expect(!ctx.getRetain("retained"));
}

// ---- Close lifecycle ----

test "close: clears subscriptions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);

    try ctx.setConfig("localhost", 1883, null, null);
    try ctx.addSubscription("topic/a");
    try ctx.addSubscription("topic/b");
    try testing.expect(ctx.hasSubscription("topic/a"));
    ctx.close();
    try testing.expect(!ctx.hasSubscription("topic/a"));
    try testing.expect(!ctx.hasSubscription("topic/b"));
    try testing.expect(!ctx.isConfigured());
    ctx.deinit();
}

test "close: clears messages" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);

    try ctx.setConfig("localhost", 1883, null, null);
    try ctx.storeMessage("t1", .{ .integer = 1 });
    try ctx.storeMessage("t2", .{ .integer = 2 });
    try testing.expect(ctx.getMessage("t1") != null);
    ctx.close();
    try testing.expect(ctx.getMessage("t1") == null);
    try testing.expect(ctx.getMessage("t2") == null);
    try testing.expect(!ctx.isConfigured());
    ctx.deinit();
}

test "close: resets connection state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);

    try ctx.setConfig("localhost", 1883, null, null);
    ctx.setState(.connected);
    try testing.expect(ctx.isConnected());
    ctx.close();
    try testing.expectEqual(.disconnected, ctx.getState());
    ctx.deinit();
}

test "close: clears duplicate timestamp deque" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);

    _ = ctx.isDuplicateTimestamp(1000);
    try testing.expect(ctx.api_timestamps.items.len > 0);
    ctx.close();
    try testing.expectEqual(@as(usize, 0), ctx.api_timestamps.items.len);
    ctx.deinit();
}

test "close: double close does not crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);

    try ctx.setConfig("localhost", 1883, null, null);
    ctx.close();
    ctx.close(); // idempotent
    ctx.deinit();
}

// ---- Reserved topics ----

test "reservedTopics: default instance name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    const rt = ctx.reservedTopics();
    defer a.free(rt.api_request);
    defer a.free(rt.api_response);
    defer a.free(rt.moonraker_status);
    defer a.free(rt.klipper_status);
    defer a.free(rt.klipper_state_prefix);

    try testing.expectEqualStrings("moonraker/moonraker/api/request", rt.api_request);
    try testing.expectEqualStrings("moonraker/moonraker/api/response", rt.api_response);
    try testing.expectEqualStrings("moonraker/moonraker/status", rt.moonraker_status);
    try testing.expectEqualStrings("moonraker/klipper/status", rt.klipper_status);
    try testing.expectEqualStrings("moonraker/klipper/state/", rt.klipper_state_prefix);
}

test "reservedTopics: custom instance name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.setConfig("localhost", 1883, null, null);
    try ctx.setInstanceName("printer2");

    const rt = ctx.reservedTopics();
    defer a.free(rt.api_request);
    defer a.free(rt.api_response);
    defer a.free(rt.moonraker_status);
    defer a.free(rt.klipper_status);
    defer a.free(rt.klipper_state_prefix);

    try testing.expectEqualStrings("printer2/moonraker/api/request", rt.api_request);
    try testing.expectEqualStrings("printer2/moonraker/api/response", rt.api_response);
    try testing.expectEqualStrings("printer2/moonraker/status", rt.moonraker_status);
}

// ---- Duplicate timestamp detection ----

test "isDuplicateTimestamp: first occurrence is not duplicate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try testing.expect(!ctx.isDuplicateTimestamp(42));
    try testing.expectEqual(@as(usize, 1), ctx.api_timestamps.items.len);
}

test "isDuplicateTimestamp: second occurrence is duplicate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    _ = ctx.isDuplicateTimestamp(100);
    try testing.expect(ctx.isDuplicateTimestamp(100));
}

test "isDuplicateTimestamp: deque bounded at maxlen" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    // Fill beyond max_timestamp_history (20)
    var i: i64 = 0;
    while (i < 30) : (i += 1) {
        _ = ctx.isDuplicateTimestamp(i);
    }
    try testing.expect(ctx.api_timestamps.items.len <= max_timestamp_history);
    // Oldest entries should have been evicted.
    try testing.expect(!ctx.isDuplicateTimestamp(0));
    // Recent entries should still be there.
    try testing.expect(ctx.isDuplicateTimestamp(29));
}

// ---- QoS escalation in subscribeTopicQos ----

test "subscribeTopicQos: rejects invalid qos" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try testing.expectError(error.InvalidParams, ctx.subscribeTopicQos("t", -1));
    try testing.expectError(error.InvalidParams, ctx.subscribeTopicQos("t", 3));
}

test "subscribeTopicQos: returns requested qos" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    for ([_]i64{ 0, 1, 2 }) |q| {
        const effective = try ctx.subscribeTopicQos("t", q);
        try testing.expectEqual(q, effective);
        try testing.expect(ctx.hasSubscription("t"));
        ctx.unsubscribe("t");
    }
}

test "subscribeTopicQos: re-subscribe is idempotent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    _ = try ctx.subscribeTopicQos("t", 0);
    _ = try ctx.subscribeTopicQos("t", 2);
    try testing.expect(ctx.hasSubscription("t"));
}

// ---- publishTopicPrefixed ----

test "publishTopicPrefixed: without prefix publishes to exact topic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.setConfig("localhost", 1883, null, null);
    try ctx.publishTopicPrefixed("my/topic", .{ .integer = 1 }, 0, false, false);
    try testing.expectEqual(@as(i64, 1), ctx.getMessage("my/topic").?.integer);
    try testing.expect(ctx.getMessage("moonraker/my/topic") == null);
}

test "publishTopicPrefixed: with prefix prepends instance name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    try ctx.setConfig("localhost", 1883, null, null);
    try ctx.setInstanceName("printer1");
    try ctx.publishTopicPrefixed("my/topic", .{ .integer = 1 }, 0, false, true);
    try testing.expectEqual(@as(i64, 1), ctx.getMessage("printer1/my/topic").?.integer);
}

// ---- Fuzz tests for new functionality ----

test "fuzz validateTopic: never panics, rejects # and + only" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [16]u8 = undefined;
            smith.bytesWithHash(&buf, 0);

            const alphabet = "abcdefghijklmnopqrstuvwxyz._/+#X";
            var topic_buf: [24]u8 = undefined;
            for (buf[0..@min(20, buf.len)], 0..) |b, i| {
                topic_buf[i] = alphabet[b % alphabet.len];
            }
            const topic = topic_buf[0..@min(16, @max(1, buf[0] % 20))];

            const has_hash = std.mem.indexOfScalar(u8, topic, '#') != null;
            const has_plus = std.mem.indexOfScalar(u8, topic, '+') != null;

            if (has_hash or has_plus) {
                _ = MqttCtx.validateTopic(topic) catch |err| {
                    try testing.expectEqual(error.InvalidParams, err);
                };
            } else {
                try MqttCtx.validateTopic(topic);
            }
        }
    }.run, .{});
}

test "fuzz isDuplicateTimestamp: deques bounded, duplicates detected" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = MqttCtx.init(a);
            defer ctx.deinit();

            const n: u8 = smith.valueRangeLessThanWithHash(u8, 1, 50, 0);
            const dup_idx: u8 = smith.valueRangeLessThanWithHash(u8, 0, n, 1);

            for (0..n) |i| {
                const ts: i64 = @intCast(i);
                _ = ctx.isDuplicateTimestamp(ts);
                if (i == dup_idx) {
                    try testing.expect(ctx.isDuplicateTimestamp(ts));
                }
            }
            try testing.expect(ctx.api_timestamps.items.len <= max_timestamp_history);
        }
    }.run, .{});
}

test "fuzz close: never panics at any state" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = MqttCtx.init(a);

            const stage: u8 = buf[0] % 8;
            switch (stage) {
                0 => ctx.close(),
                1 => {
                    ctx.setConfig("localhost", 1883, null, null) catch {
                        ctx.deinit();
                        return;
                    };
                    ctx.close();
                },
                2 => {
                    ctx.setConfig("localhost", 1883, null, null) catch {
                        ctx.deinit();
                        return;
                    };
                    ctx.setState(.connected);
                    ctx.close();
                },
                3 => {
                    ctx.setConfig("localhost", 1883, null, null) catch {
                        ctx.deinit();
                        return;
                    };
                    ctx.storeMessage("t", .{ .integer = 1 }) catch {
                        ctx.deinit();
                        return;
                    };
                    ctx.close();
                },
                4 => {
                    ctx.setConfig("localhost", 1883, null, null) catch {
                        ctx.deinit();
                        return;
                    };
                    _ = ctx.subscribeTopic("s") catch {
                        ctx.deinit();
                        return;
                    };
                    ctx.close();
                },
                5 => {
                    ctx.setConfig("localhost", 1883, null, null) catch {
                        ctx.deinit();
                        return;
                    };
                    _ = ctx.isDuplicateTimestamp(1);
                    _ = ctx.isDuplicateTimestamp(2);
                    ctx.close();
                },
                6 => {
                    ctx.setConfig("localhost", 1883, null, null) catch {
                        ctx.deinit();
                        return;
                    };
                    ctx.storeMessageRetain("r", .{ .bool = true }, true) catch {
                        ctx.deinit();
                        return;
                    };
                    ctx.close();
                },
                7 => {
                    ctx.setConfig("localhost", 1883, null, null) catch {
                        ctx.deinit();
                        return;
                    };
                    try ctx.setInstanceName("p1");
                    try ctx.setClientId("c1");
                    ctx.setDefaultQos(2);
                    ctx.close();
                },
                else => unreachable,
            }
            ctx.deinit();
        }
    }.run, .{});
}

// ---- handlePublishPrefixed ----

test "handlePublishPrefixed: missing topic → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = testCtx(a);
    defer ctx.deinit();
    try testing.expectError(error.InvalidParams, handlePublishPrefixed(@ptrCast(&ctx), .null, a));
}

test "handlePublishPrefixed: invalid qos → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = testCtx(a);
    defer ctx.deinit();
    const params = try mkParams(a, "{\"topic\": \"test\", \"qos\": 5}");
    try testing.expectError(error.InvalidParams, handlePublishPrefixed(@ptrCast(&ctx), params, a));
}

test "handlePublishPrefixed: valid params no broker → MqttNotConfigured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = testCtx(a);
    defer ctx.deinit();
    const params = try mkParams(a, "{\"topic\": \"my/topic\"}");
    try testing.expectError(error.MqttNotConfigured, handlePublishPrefixed(@ptrCast(&ctx), params, a));
}

test "handlePublishPrefixed: no prefix, with broker stores and returns topic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);

    const params = try mkParams(a, "{\"topic\": \"foo/bar\", \"payload\": \"hello\"}");
    const resp = try handlePublishPrefixed(@ptrCast(&ctx), params, a);

    try testing.expectEqualStrings("foo/bar", resp.object.get("topic").?.string);
    try testing.expectEqualStrings("hello", ctx.getMessage("foo/bar").?.string);
}

test "handlePublishPrefixed: with prefix, prepends instance_name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);
    try ctx.setInstanceName("printer1");

    const params = try mkParams(a, "{\"topic\": \"bar/baz\", \"payload\": 42, \"prefix\": true}");
    const resp = try handlePublishPrefixed(@ptrCast(&ctx), params, a);

    try testing.expectEqualStrings("printer1/bar/baz", resp.object.get("topic").?.string);
    try testing.expectEqual(@as(i64, 42), ctx.getMessage("printer1/bar/baz").?.integer);
    // Unprefixed topic was not stored.
    try testing.expect(ctx.getMessage("bar/baz") == null);
}

test "handlePublishPrefixed: with prefix, no instance_name → default \"moonraker\"" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);
    // No setInstanceName call — defaults to "moonraker".

    const params = try mkParams(a, "{\"topic\": \"status\", \"prefix\": true}");
    const resp = try handlePublishPrefixed(@ptrCast(&ctx), params, a);

    try testing.expectEqualStrings("moonraker/status", resp.object.get("topic").?.string);
    try testing.expect(ctx.getMessage("moonraker/status") != null);
}

test "handlePublishPrefixed: stores retain flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);

    const params = try mkParams(a, "{\"topic\": \"ret\", \"payload\": \"yes\", \"retain\": true}");
    _ = try handlePublishPrefixed(@ptrCast(&ctx), params, a);
    try testing.expect(ctx.getRetain("ret"));

    const params2 = try mkParams(a, "{\"topic\": \"ret\", \"payload\": \"no\"}");
    _ = try handlePublishPrefixed(@ptrCast(&ctx), params2, a);
    try testing.expect(!ctx.getRetain("ret"));
}

test "handlePublishPrefixed: null payload stored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);

    const params = try mkParams(a, "{\"topic\": \"nulltopic\"}");
    _ = try handlePublishPrefixed(@ptrCast(&ctx), params, a);

    try testing.expect((ctx.getMessage("nulltopic").?) == .null);
}

test "handlePublishPrefixed: overwrites previous message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);

    const params1 = try mkParams(a, "{\"topic\": \"ow\", \"payload\": 1}");
    _ = try handlePublishPrefixed(@ptrCast(&ctx), params1, a);
    const params2 = try mkParams(a, "{\"topic\": \"ow\", \"payload\": 2}");
    _ = try handlePublishPrefixed(@ptrCast(&ctx), params2, a);

    try testing.expectEqual(@as(i64, 2), ctx.getMessage("ow").?.integer);
}

test "handlePublishPrefixed: qos 0/1/2 all accepted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);

    for ([_]i64{ 0, 1, 2 }) |q| {
        const json = try std.fmt.allocPrint(a, "{{\"topic\": \"q\", \"qos\": {d}}}", .{q});
        const params = try mkParams(a, json);
        _ = try handlePublishPrefixed(@ptrCast(&ctx), params, a);
    }
}

// ---- Fuzz test for handlePublishPrefixed ----

test "fuzz handlePublishPrefixed: never panics on arbitrary params" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [16]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = MqttCtx.init(a);
            defer ctx.deinit();

            ctx.setConfig("localhost", 1883, null, null) catch return;

            const alphabet = "abcdefghijklmnopqrstuvwxyz._/";
            var name_buf: [12]u8 = undefined;
            for (buf[0..@min(8, buf.len)], 0..) |b, i| {
                name_buf[i] = alphabet[b % alphabet.len];
            }
            const topic = name_buf[0..@min(6, @max(1, buf[0] % 8))];

            const qos: i64 = @as(i64, @intCast(buf[1] % 5)) - 1; // -1..3
            const retain = buf[2] % 2 == 0;
            const use_prefix = buf[3] % 2 == 0;

            // Build params JSON manually to include prefix.
            const prefix_str = if (use_prefix) "true" else "false";
            const json = std.fmt.allocPrint(a, "{{\"topic\":\"{s}\",\"qos\":{d},\"retain\":{s},\"prefix\":{s}}}", .{ topic, qos, if (retain) "true" else "false", prefix_str }) catch return;
            const params = mkParams(a, json) catch return;

            _ = handlePublishPrefixed(@ptrCast(&ctx), params, a) catch {};
        }
    }.run, .{});
}
