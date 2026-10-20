//! server.mqtt.* API component and Moonraker's MQTT client transport.
//!
//! Mirrors `vendor/moonraker/moonraker/components/mqtt.py` (MQTTClient):
//!
//!   POST /server/mqtt/publish   → server.mqtt.publish
//!   POST /server/mqtt/subscribe → server.mqtt.subscribe
//!
//! Without an `[mqtt]` section both endpoints return the "MQTT not configured"
//! 503. With one, `start` runs a reconnect supervisor on a background task. It
//! connects (over TLS when `enable_tls` is set) with a retained
//! `{"server":"offline"}` Last Will on `{instance_name}/moonraker/status`,
//! publishes `{"server":"online"}` there retained, subscribes
//! `{instance_name}/moonraker/api/request` when `enable_moonraker_api` is set,
//! and sends PINGREQ every half keepalive interval. A background reader
//! dispatches inbound PUBLISH frames: API requests go through the JSON-RPC
//! dispatcher and the response is published to
//! `{instance_name}/moonraker/api/response`; other topics wake pending
//! subscribe requests and reach `on_message` (MQTT sensors). Shutdown publishes
//! `{"server":"offline"}` and sends DISCONNECT.
//!
//! publish sends one PUBLISH with paho's payload encoding: objects and arrays
//! as JSON, strings raw, booleans `true`/`false`, null as an empty payload.
//! QoS 0 or an absent qos means `default_qos` (`qos or self.qos` upstream).
//! subscribe subscribes on the broker and waits, off the Core lock, for the
//! first message on the topic, bounded by `timeout`; it returns the payload
//! JSON-decoded, or as a string when it is not JSON.
//!
//! Response shapes (mqtt.py): publish {"topic": t}, subscribe {"topic": t,
//! "payload": p}. Known gaps are listed in TODO.md ("Known Moonraker gaps").

const std = @import("std");
const webreq = @import("../json/params.zig");
const sleep = @import("../util/sleep.zig");
const jv = @import("../json/value.zig");
const registry = @import("../server/registry.zig");
const mqtt_client = @import("mqtt_client.zig");
const mqtt_proto = @import("mqtt_proto.zig");

const Registry = registry.Registry;
const Io = std.Io;
const MqttClient = mqtt_client.MqttClient;

/// CONNECT keepalive (paho's default). PINGREQ goes out every half interval.
const default_keepalive_s: u16 = 60;
/// Reconnect backoff: start at 500 ms, double per failure, cap at 30 s.
const initial_backoff_ms: i64 = 500;
const max_backoff_ms: i64 = 30_000;
/// Moonraker keeps the last 20 API request timestamps (`timestamp_deque`).
const max_timestamp_history = 20;
/// Concurrent `server.mqtt.subscribe` waits; more return 503.
const max_subscribe_waiters = 16;
/// JSON-RPC error code for a repeated `mqtt_timestamp` (mqtt.py DUP_API_REQ_CODE).
const duplicate_request_code: i64 = -10000;
/// Longest honoured subscribe `timeout`, keeping deadlines representable on 32-bit.
const max_timeout_s: f64 = std.time.s_per_day;

const online_payload = "{\"server\":\"online\"}";
const offline_payload = "{\"server\":\"offline\"}";

/// Moonraker `[mqtt]` options. Slices are borrowed; `setConfig` copies them.
pub const Options = struct {
    address: []const u8,
    port: u16 = 1883,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    /// Empty lets the broker assign an id (paho default).
    client_id: []const u8 = "",
    /// Moonraker defaults this to the host name.
    instance_name: []const u8,
    default_qos: i64 = 0,
    /// Null means `default_qos`.
    api_qos: ?i64 = null,
    enable_moonraker_api: bool = true,
    enable_tls: bool = false,
};

/// Validated broker configuration. Every string lives in `arena`.
pub const MqttConfig = struct {
    arena: std.heap.ArenaAllocator,
    address: []const u8,
    port: u16,
    username: ?[]const u8,
    password: ?[]const u8,
    client_id: []const u8,
    default_qos: u2,
    api_qos: u2,
    enable_moonraker_api: bool,
    enable_tls: bool,
    api_request_topic: []const u8,
    api_response_topic: []const u8,
    status_topic: []const u8,
    instance_name: []const u8,

    /// `qos or self.qos` in mqtt.py: 0 selects the default QoS.
    fn effectiveQos(self: *const MqttConfig, qos: u2) u2 {
        return if (qos == 0) self.default_qos else qos;
    }
};

/// A pending `server.mqtt.subscribe`. Lives on the handler's stack while it is
/// linked into `MqttCtx.waiters`.
const Waiter = struct {
    node: std.DoublyLinkedList.Node = .{},
    topic: []const u8,
    qos: u2,
    done: Io.Event = .unset,
    /// gpa-owned copy of the first message; null when woken by shutdown or OOM.
    payload: ?[]u8 = null,
};

pub const MqttCtx = struct {
    gpa: std.mem.Allocator,
    config: ?MqttConfig = null,
    keepalive_s: u16 = default_keepalive_s,
    /// Live Io handle; null in `--dump-api` and unit tests without a broker.
    io: ?Io = null,
    /// Live broker client. Users pin it with a shared `client_lock` across a
    /// write; the supervisor shuts the socket down first, so a pinned writer
    /// fails fast, then takes the lock exclusively to free it.
    client: ?*MqttClient = null,
    client_lock: Io.RwLock = .init,
    connect_thread: ?Io.Future(void) = null,
    reader_thread: ?Io.Future(void) = null,
    reader_stop: Io.Event = .unset,
    /// Set by the reader when it exits; ends the keepalive loop.
    reader_done: Io.Event = .unset,
    /// Pending subscribe requests, guarded by `waiters_mutex`.
    waiters: std.DoublyLinkedList = .{},
    waiter_count: usize = 0,
    waiters_closed: bool = false,
    waiters_mutex: Io.Mutex = .init,
    waiters_idle: Io.Condition = .init,
    /// Recent `mqtt_timestamp` values; touched only by the reader thread.
    api_timestamps: [max_timestamp_history]f64 = undefined,
    api_timestamp_len: usize = 0,
    api_timestamp_next: usize = 0,
    /// Inbound-message hook (reader thread). The app routes it to MQTT sensors
    /// under the Core lock.
    on_message: ?*const fn (ctx: *anyopaque, topic: []const u8, payload: []const u8) void = null,
    on_message_ctx: ?*anyopaque = null,
    /// Post-connect hook (supervisor thread), run after each (re)connect. The
    /// app uses it to subscribe sensor topics.
    on_connected: ?*const fn (ctx: *anyopaque) void = null,
    on_connected_ctx: ?*anyopaque = null,
    /// JSON-RPC dispatch for API requests. Returns the response bytes (empty
    /// for a notification) allocated in `alloc`.
    api_dispatch: ?*const fn (ctx: *anyopaque, request: std.json.Value, alloc: std.mem.Allocator) anyerror![]u8 = null,
    api_dispatch_ctx: ?*anyopaque = null,

    pub fn init(gpa: std.mem.Allocator) MqttCtx {
        return .{ .gpa = gpa };
    }

    /// Stop the supervisor, wake pending subscribers and free the config.
    pub fn deinit(self: *MqttCtx) void {
        if (self.io) |io| self.stop(io);
        if (self.config) |*cfg| cfg.arena.deinit();
        self.config = null;
    }

    /// Validate and copy `[mqtt]` options. Replaces the previous config only on
    /// success. Call before `start`.
    pub fn setConfig(self: *MqttCtx, opts: Options) !void {
        if (std.mem.indexOfAny(u8, opts.instance_name, "+#") != null) return error.InvalidInstanceName;
        const default_qos = try qosValue(opts.default_qos);
        const api_qos = try qosValue(opts.api_qos orelse opts.default_qos);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const name = try a.dupe(u8, opts.instance_name);
        const cfg: MqttConfig = .{
            .arena = undefined,
            .address = try a.dupe(u8, opts.address),
            .port = opts.port,
            .username = if (opts.username) |u| try a.dupe(u8, u) else null,
            .password = if (opts.password) |p| try a.dupe(u8, p) else null,
            .client_id = try a.dupe(u8, opts.client_id),
            .default_qos = default_qos,
            .api_qos = api_qos,
            .enable_moonraker_api = opts.enable_moonraker_api,
            .enable_tls = opts.enable_tls,
            .api_request_topic = try std.fmt.allocPrint(a, "{s}/moonraker/api/request", .{name}),
            .api_response_topic = try std.fmt.allocPrint(a, "{s}/moonraker/api/response", .{name}),
            .status_topic = try std.fmt.allocPrint(a, "{s}/moonraker/status", .{name}),
            .instance_name = name,
        };
        if (self.config) |*old| old.arena.deinit();
        self.config = cfg;
        self.config.?.arena = arena;
    }

    /// Start the reconnect supervisor when a broker is configured and io is wired.
    pub fn start(self: *MqttCtx) void {
        if (self.config == null) return;
        const io = self.io orelse return;
        self.reader_stop.reset();
        self.connect_thread = io.concurrent(supervise, .{self}) catch |err| {
            std.debug.print("phobos: warning: MQTT worker not started: {}\n", .{err});
            return;
        };
    }

    /// Publish offline status, disconnect, join the supervisor and release
    /// pending subscribers. Safe to call when not connected.
    fn stop(self: *MqttCtx, io: Io) void {
        self.reader_stop.set(io);
        self.client_lock.lockSharedUncancelable(io);
        if (self.client) |client| {
            if (self.config) |cfg| client.publish(cfg.status_topic, offline_payload, cfg.default_qos, true) catch {};
            client.disconnect();
            client.shutdownRecv();
        }
        self.client_lock.unlockShared(io);
        if (self.connect_thread) |*t| {
            t.cancel(io);
            self.connect_thread = null;
        }
        self.closeWaiters(io);
    }

    /// CONNECT options for `cfg`: the retained offline Last Will (mqtt.py
    /// `will_set`) and credentials.
    fn connectOptions(self: *const MqttCtx, cfg: *const MqttConfig) mqtt_proto.ConnectOptions {
        return .{
            .client_id = cfg.client_id,
            .username = cfg.username,
            .password = cfg.password,
            .keepalive_s = self.keepalive_s,
            .will_topic = cfg.status_topic,
            .will_payload = offline_payload,
            .will_qos = cfg.default_qos,
            .will_retain = true,
        };
    }

    /// Reconnect supervisor (the connect_thread entry): connect, keep alive
    /// until the reader ends, free the client, back off, repeat until stopped.
    fn supervise(self: *MqttCtx) void {
        const io = self.io.?;
        const cfg = &self.config.?;
        var backoff_ms = initial_backoff_ms;
        while (!self.reader_stop.isSet()) {
            if (self.connectBroker(io, cfg)) |client| {
                backoff_ms = initial_backoff_ms;
                self.keepAlive(io, client);
                self.freeClient(io, client);
            } else |_| {}
            if (sleep.untilStopped(io, .fromMilliseconds(backoff_ms), &self.reader_stop)) break;
            backoff_ms = @min(backoff_ms * 2, max_backoff_ms);
        }
    }

    /// Connect, announce online status, subscribe the API and pending
    /// subscribe topics, publish the client and start its reader.
    fn connectBroker(self: *MqttCtx, io: Io, cfg: *const MqttConfig) !*MqttClient {
        const client = try self.gpa.create(MqttClient);
        errdefer self.gpa.destroy(client);
        const opts = self.connectOptions(cfg);
        client.* = if (cfg.enable_tls)
            try MqttClient.connectTls(self.gpa, io, cfg.address, cfg.port, opts, .{ .host = cfg.address })
        else
            try MqttClient.connect(self.gpa, io, cfg.address, cfg.port, opts);
        errdefer client.deinit();
        client.on_publish = onPublish;
        client.on_publish_ctx = self;
        try client.publish(cfg.status_topic, online_payload, cfg.default_qos, true);
        if (cfg.enable_moonraker_api) try client.subscribe(cfg.api_request_topic, cfg.effectiveQos(cfg.api_qos));
        {
            self.waiters_mutex.lockUncancelable(io);
            defer self.waiters_mutex.unlock(io);
            var it = self.waiters.first;
            while (it) |node| : (it = node.next) {
                const waiter: *Waiter = @fieldParentPtr("node", node);
                try client.subscribe(waiter.topic, waiter.qos);
            }
        }
        self.setClient(io, client);
        self.reader_done.reset();
        self.reader_thread = io.concurrent(runReader, .{ self, client }) catch |err| {
            self.setClient(io, null);
            return err;
        };
        if (self.on_connected) |cb| cb(self.on_connected_ctx.?);
        // A stop that ran before the client was published missed it.
        if (self.reader_stop.isSet()) client.shutdownRecv();
        return client;
    }

    fn setClient(self: *MqttCtx, io: Io, client: ?*MqttClient) void {
        self.client_lock.lockUncancelable(io);
        defer self.client_lock.unlock(io);
        self.client = client;
    }

    /// Ping every half keepalive until the reader exits or the task is canceled.
    fn keepAlive(self: *MqttCtx, io: Io, client: *MqttClient) void {
        const interval: Io.Duration = .fromMilliseconds(@as(i64, self.keepalive_s) * (std.time.ms_per_s / 2));
        while (!sleep.untilStopped(io, interval, &self.reader_done)) {
            client.ping() catch return;
        }
    }

    /// Shut the socket down (failing any pinned writer), join the reader,
    /// unpublish and free the client.
    fn freeClient(self: *MqttCtx, io: Io, client: *MqttClient) void {
        client.shutdownRecv();
        if (self.reader_thread) |*t| {
            t.await(io);
            self.reader_thread = null;
        }
        self.setClient(io, null);
        client.deinit();
        self.gpa.destroy(client);
    }

    fn runReader(self: *MqttCtx, client: *MqttClient) void {
        defer self.reader_done.set(self.io.?);
        while (!self.reader_stop.isSet()) {
            _ = client.readOne() catch return;
        }
    }

    /// MqttClient.on_publish (reader thread).
    fn onPublish(ctx: *anyopaque, topic: []const u8, payload: []const u8) void {
        const self: *MqttCtx = @ptrCast(@alignCast(ctx));
        const cfg = &self.config.?;
        if (cfg.enable_moonraker_api and std.mem.eql(u8, topic, cfg.api_request_topic)) {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const response = (self.apiResponse(payload, arena.allocator()) catch return) orelse return;
            self.publishRaw(cfg.api_response_topic, response, cfg.effectiveQos(cfg.api_qos), false) catch {};
            return;
        }
        self.wakeWaiters(topic, payload);
        if (self.on_message) |cb| cb(self.on_message_ctx.?, topic, payload);
    }

    /// Moonraker `_process_api_request` with `screen_rpc_request`: pop
    /// `params.mqtt_timestamp`, reject a repeated one with -10000, dispatch the
    /// rest. Returns the response bytes in `alloc`, or null when there is none
    /// (notification or no dispatcher).
    fn apiResponse(self: *MqttCtx, payload: []const u8, alloc: std.mem.Allocator) !?[]const u8 {
        const dispatch = self.api_dispatch orelse return null;
        var root = std.json.parseFromSliceLeaky(std.json.Value, alloc, payload, .{}) catch
            return try jv.errorResponse(alloc, .null, -32700, "Parse error");
        if (jv.exceedsDepth(root, jv.max_value_depth)) return try jv.errorResponse(alloc, .null, -32600, "Invalid Request");
        if (root == .object) {
            if (root.object.getPtr("params")) |params| if (params.* == .object) {
                if (params.object.fetchOrderedRemove("mqtt_timestamp")) |entry| {
                    const ts: ?f64 = switch (entry.value) {
                        .integer => |i| @floatFromInt(i),
                        .float => |f| f,
                        else => null,
                    };
                    if (ts) |t| if (self.isDuplicateTimestamp(t)) {
                        const id = root.object.get("id") orelse return null;
                        return try jv.errorResponse(alloc, id, duplicate_request_code, "Duplicate MQTT Request");
                    };
                }
            };
        }
        const response = try dispatch(self.api_dispatch_ctx.?, root, alloc);
        return if (response.len == 0) null else response;
    }

    /// True when `ts` is among the last 20 timestamps; otherwise records it.
    fn isDuplicateTimestamp(self: *MqttCtx, ts: f64) bool {
        if (std.mem.indexOfScalar(f64, self.api_timestamps[0..self.api_timestamp_len], ts) != null) return true;
        self.api_timestamps[self.api_timestamp_next] = ts;
        self.api_timestamp_next = (self.api_timestamp_next + 1) % max_timestamp_history;
        self.api_timestamp_len = @min(self.api_timestamp_len + 1, max_timestamp_history);
        return false;
    }

    /// Send `bytes` on the live connection. 503 when disconnected.
    fn publishRaw(self: *MqttCtx, topic: []const u8, bytes: []const u8, qos: u2, retain: bool) !void {
        const io = self.io orelse return error.ServiceUnavailable;
        self.client_lock.lockSharedUncancelable(io);
        defer self.client_lock.unlockShared(io);
        const client = self.client orelse return error.ServiceUnavailable;
        client.publish(topic, bytes, qos, retain) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.StringTooLong, error.ValueTooLarge => error.InvalidParams,
            else => error.ServiceUnavailable,
        };
    }

    /// Subscribe `topic` on the live connection; `null` qos means
    /// `default_qos`. No-op while disconnected: the next connect subscribes
    /// pending subscribe requests and calls `on_connected`.
    pub fn subscribeTopicLive(self: *MqttCtx, topic: []const u8, qos: ?u2) void {
        const io = self.io orelse return;
        const cfg = &(self.config orelse return);
        self.client_lock.lockSharedUncancelable(io);
        defer self.client_lock.unlockShared(io);
        const client = self.client orelse return;
        // A failed write means the connection is dropping; the reconnect
        // resubscribes.
        client.subscribe(topic, qos orelse cfg.default_qos) catch {};
    }

    fn addWaiter(self: *MqttCtx, io: Io, waiter: *Waiter) !void {
        self.waiters_mutex.lockUncancelable(io);
        defer self.waiters_mutex.unlock(io);
        if (self.waiters_closed or self.waiter_count == max_subscribe_waiters) return error.ServiceUnavailable;
        self.waiters.append(&waiter.node);
        self.waiter_count += 1;
    }

    /// Unlink `waiter`; returns its gpa-owned payload for the caller to free.
    fn removeWaiter(self: *MqttCtx, io: Io, waiter: *Waiter) ?[]u8 {
        self.waiters_mutex.lockUncancelable(io);
        defer self.waiters_mutex.unlock(io);
        self.waiters.remove(&waiter.node);
        self.waiter_count -= 1;
        if (self.waiter_count == 0) self.waiters_idle.broadcast(io);
        return waiter.payload;
    }

    /// Hand a copy of `payload` to every unfinished waiter on `topic`.
    fn wakeWaiters(self: *MqttCtx, topic: []const u8, payload: []const u8) void {
        const io = self.io.?;
        self.waiters_mutex.lockUncancelable(io);
        defer self.waiters_mutex.unlock(io);
        var it = self.waiters.first;
        while (it) |node| : (it = node.next) {
            const waiter: *Waiter = @fieldParentPtr("node", node);
            if (waiter.done.isSet() or !std.mem.eql(u8, waiter.topic, topic)) continue;
            waiter.payload = self.gpa.dupe(u8, payload) catch null;
            waiter.done.set(io);
        }
    }

    /// Refuse new waiters, wake the pending ones and wait until they unlink.
    fn closeWaiters(self: *MqttCtx, io: Io) void {
        self.waiters_mutex.lockUncancelable(io);
        defer self.waiters_mutex.unlock(io);
        self.waiters_closed = true;
        var it = self.waiters.first;
        while (it) |node| : (it = node.next) {
            const waiter: *Waiter = @fieldParentPtr("node", node);
            waiter.done.set(io);
        }
        while (self.waiter_count != 0) self.waiters_idle.waitUncancelable(io, &self.waiters_mutex);
    }
};

// ---------------------------------------------------------------------------
// Parameter helpers
// ---------------------------------------------------------------------------

/// Validate a QoS value: 0, 1 or 2 (mqtt.py raises otherwise).
fn qosValue(qos: i64) error{InvalidParams}!u2 {
    if (qos < 0 or qos > 2) return error.InvalidParams;
    return @intCast(qos);
}

/// The request's `qos` (default `default_qos`), with 0 meaning `default_qos`.
fn requestQos(cfg: *const MqttConfig, params: std.json.Value) error{InvalidParams}!u2 {
    const raw = (try webreq.optional(i64, params, "qos")) orelse cfg.default_qos;
    return cfg.effectiveQos(try qosValue(raw));
}

/// paho's payload encoding: JSON for objects and arrays, raw strings,
/// `true`/`false`, numbers in decimal, nothing for null.
fn encodePayload(w: *std.Io.Writer, payload: std.json.Value) !void {
    switch (payload) {
        .null => {},
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .string, .number_string => |s| try w.writeAll(s),
        .object, .array => {
            if (jv.exceedsDepth(payload, jv.max_value_depth)) return error.InvalidParams;
            var jw: std.json.Stringify = .{ .writer = w };
            try jw.write(payload);
        },
    }
}

/// Validate a subscription topic: Moonraker rejects the wildcards `#` and `+`.
fn validateTopic(topic: []const u8) error{InvalidParams}!void {
    if (std.mem.indexOfAny(u8, topic, "#+") != null) return error.InvalidParams;
}

fn publishParams(ctx: *MqttCtx, topic: []const u8, params: std.json.Value) !void {
    const cfg = &(ctx.config orelse return error.MqttNotConfigured);
    const qos = try requestQos(cfg, params);
    const retain = ((try webreq.optional(bool, params, "retain")) orelse false);
    const payload = if (params == .object) params.object.get("payload") orelse .null else .null;
    var aw: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer aw.deinit();
    encodePayload(&aw.writer, payload) catch |err| return switch (err) {
        error.InvalidParams => error.InvalidParams,
        error.WriteFailed => error.OutOfMemory,
    };
    try ctx.publishRaw(topic, aw.written(), qos, retain);
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// POST /server/mqtt/publish → {"topic": <topic>}. Runs off the Core lock.
/// `timeout` is accepted; the reply follows the socket write, not the broker
/// acknowledgement.
pub fn handlePublish(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *MqttCtx = @ptrCast(@alignCast(ctx_ptr));
    const topic = try webreq.required([]const u8, params, "topic");
    try publishParams(ctx, topic, params);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "topic", .{ .string = topic });
    return .{ .object = obj };
}

/// POST /server/mqtt/subscribe → {"topic": <topic>, "payload": <any>}. Runs
/// off the Core lock and waits for the first message on `topic`; `timeout`
/// expiry returns error.MqttTimeout.
pub fn handleSubscribe(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *MqttCtx = @ptrCast(@alignCast(ctx_ptr));
    const topic = try webreq.required([]const u8, params, "topic");
    try validateTopic(topic);
    const cfg = &(ctx.config orelse return error.MqttNotConfigured);
    const qos = try requestQos(cfg, params);
    const timeout = (try webreq.optional(f64, params, "timeout"));
    const io = ctx.io orelse return error.ServiceUnavailable;

    var waiter: Waiter = .{ .topic = topic, .qos = qos };
    try ctx.addWaiter(io, &waiter);
    ctx.subscribeTopicLive(topic, qos);
    const woken = if (timeout) |t|
        sleep.untilStopped(io, .fromNanoseconds(std.math.lossyCast(i96, @min(t, max_timeout_s) * std.time.ns_per_s)), &waiter.done)
    else blk: {
        waiter.done.wait(io) catch {};
        break :blk true;
    };
    const message = ctx.removeWaiter(io, &waiter);
    defer if (message) |m| ctx.gpa.free(m);
    const bytes = message orelse return if (woken) error.ServiceUnavailable else error.MqttTimeout;

    var payload = std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{}) catch
        std.json.Value{ .string = try alloc.dupe(u8, bytes) };
    if (jv.exceedsDepth(payload, jv.max_value_depth)) payload = .{ .string = try alloc.dupe(u8, bytes) };
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "topic", .{ .string = topic });
    try obj.put(alloc, "payload", payload);
    return .{ .object = obj };
}

/// JSON-RPC `server.mqtt.publish_mqtt_topic`, Moonraker's `publish_mqtt_topic`
/// remote method (`_publish_from_klipper`): `use_prefix` prepends
/// `{instance_name}/` to the topic with leading slashes removed.
/// Response: {"topic": <published topic>}.
pub fn handlePublishPrefixed(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *MqttCtx = @ptrCast(@alignCast(ctx_ptr));
    const raw_topic = try webreq.required([]const u8, params, "topic");
    const cfg = &(ctx.config orelse return error.MqttNotConfigured);
    const topic = if (((try webreq.optional(bool, params, "use_prefix")) orelse false))
        try std.fmt.allocPrint(alloc, "{s}/{s}", .{ cfg.instance_name, std.mem.trimStart(u8, raw_topic, "/") })
    else
        raw_topic;
    try publishParams(ctx, topic, params);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "topic", .{ .string = topic });
    return .{ .object = obj };
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn registerMqtt(reg: *Registry, ctx: *MqttCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);
    // Broker I/O blocks, so every MQTT handler runs off the Core lock. They
    // touch only MqttCtx state guarded by its own locks.
    try reg.registerEndpoint(.{ .path = "/server/mqtt/publish", .methods = &.{.POST}, .off_core = true }, c, handlePublish);
    try reg.registerEndpoint(.{ .path = "/server/mqtt/subscribe", .methods = &.{.POST}, .off_core = true }, c, handleSubscribe);
    try reg.dispatcher.registerEntry("server.mqtt.publish_mqtt_topic", .{ .ctx = c, .handler = handlePublishPrefixed, .off_core = true });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn mkParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, json_str, .{});
}

const test_options: Options = .{ .address = "127.0.0.1", .instance_name = "phobos" };

/// Poll `flag` for up to two seconds.
fn waitFor(io: Io, flag: *const std.atomic.Value(u32), at_least: u32) bool {
    for (0..400) |_| {
        if (flag.load(.acquire) >= at_least) return true;
        io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    return false;
}

test "setConfig derives reserved topics and Moonraker defaults" {
    var ctx = MqttCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.setConfig(.{ .address = "broker.lan", .instance_name = "printer", .default_qos = 1 });
    const cfg = ctx.config.?;
    try testing.expectEqualStrings("broker.lan", cfg.address);
    try testing.expectEqual(@as(u16, 1883), cfg.port);
    try testing.expectEqualStrings("", cfg.client_id);
    try testing.expectEqual(@as(u2, 1), cfg.api_qos);
    try testing.expectEqualStrings("printer/moonraker/api/request", cfg.api_request_topic);
    try testing.expectEqualStrings("printer/moonraker/api/response", cfg.api_response_topic);
    try testing.expectEqualStrings("printer/moonraker/status", cfg.status_topic);

    // Replacing frees the previous arena (testing.allocator checks).
    try ctx.setConfig(.{ .address = "other", .instance_name = "x", .api_qos = 2, .username = "u", .password = "p" });
    try testing.expectEqual(@as(u2, 2), ctx.config.?.api_qos);
    try testing.expectEqualStrings("u", ctx.config.?.username.?);
}

test "setConfig rejects wildcard instance names and out-of-range QoS, keeping the old config" {
    var ctx = MqttCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.setConfig(test_options);
    try testing.expectError(error.InvalidInstanceName, ctx.setConfig(.{ .address = "a", .instance_name = "a/#" }));
    try testing.expectError(error.InvalidParams, ctx.setConfig(.{ .address = "a", .instance_name = "a", .default_qos = 3 }));
    try testing.expectError(error.InvalidParams, ctx.setConfig(.{ .address = "a", .instance_name = "a", .api_qos = -1 }));
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    ctx.gpa = failing.allocator();
    try testing.expectError(error.OutOfMemory, ctx.setConfig(.{ .address = "new", .instance_name = "new" }));
    ctx.gpa = testing.allocator;
    try testing.expectEqualStrings("phobos/moonraker/status", ctx.config.?.status_topic);
}

test "fuzz setConfig: arbitrary options never leak and topics embed the instance name" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [32]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const split = @as(usize, buf[0]) % buf.len;
            var ctx = MqttCtx.init(testing.allocator);
            defer ctx.deinit();
            ctx.setConfig(.{ .address = buf[0..split], .instance_name = buf[split..], .default_qos = @as(i8, @bitCast(buf[1])) }) catch return;
            try testing.expect(std.mem.startsWith(u8, ctx.config.?.status_topic, buf[split..]));
        }
    }.run, .{});
}

test "connectOptions arms a retained offline will at default_qos" {
    var ctx = MqttCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.setConfig(.{ .address = "a", .instance_name = "p", .default_qos = 2, .client_id = "id" });
    const opts = ctx.connectOptions(&ctx.config.?);
    try testing.expectEqualStrings("p/moonraker/status", opts.will_topic.?);
    try testing.expectEqualStrings("{\"server\":\"offline\"}", opts.will_payload.?);
    try testing.expectEqual(@as(u2, 2), opts.will_qos);
    try testing.expect(opts.will_retain);
    try testing.expectEqualStrings("id", opts.client_id);
    try testing.expectEqual(default_keepalive_s, opts.keepalive_s);
}

test "encodePayload follows paho: raw strings, JSON containers, empty null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "\"hello\"", .out = "hello" },
        .{ .in = "null", .out = "" },
        .{ .in = "true", .out = "true" },
        .{ .in = "false", .out = "false" },
        .{ .in = "42", .out = "42" },
        .{ .in = "1.5", .out = "1.5" },
        .{ .in = "{\"a\":[1,2]}", .out = "{\"a\":[1,2]}" },
    };
    for (cases) |case| {
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try encodePayload(&aw.writer, try mkParams(a, case.in));
        try testing.expectEqualStrings(case.out, aw.written());
    }
}

test "fuzz encodePayload: any JSON value encodes without error" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [32]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const value = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), &buf, .{}) catch return;
            var aw: std.Io.Writer.Allocating = .init(testing.allocator);
            defer aw.deinit();
            try encodePayload(&aw.writer, value);
        }
    }.run, .{});
}

test "handlers: not configured, bad params and disconnected publish" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = MqttCtx.init(testing.allocator);
    defer ctx.deinit();
    const c: *anyopaque = @ptrCast(&ctx);
    try testing.expectError(error.InvalidParams, handlePublish(c, try mkParams(a, "{}"), a));
    try testing.expectError(error.MqttNotConfigured, handlePublish(c, try mkParams(a, "{\"topic\":\"t\"}"), a));
    try testing.expectError(error.MqttNotConfigured, handleSubscribe(c, try mkParams(a, "{\"topic\":\"t\"}"), a));
    try testing.expectError(error.MqttNotConfigured, handlePublishPrefixed(c, try mkParams(a, "{\"topic\":\"t\"}"), a));
    try ctx.setConfig(test_options);
    try testing.expectError(error.InvalidParams, handlePublish(c, try mkParams(a, "{\"topic\":\"t\",\"qos\":3}"), a));
    try testing.expectError(error.InvalidParams, handleSubscribe(c, try mkParams(a, "{\"topic\":\"a/#\"}"), a));
    try testing.expectError(error.InvalidParams, handleSubscribe(c, try mkParams(a, "{\"topic\":\"a/+/b\"}"), a));
    try testing.expectError(error.ServiceUnavailable, handlePublish(c, try mkParams(a, "{\"topic\":\"t\",\"payload\":1}"), a));
}

test "fuzz handlers: arbitrary params never crash without a broker" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [48]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = MqttCtx.init(testing.allocator);
            defer ctx.deinit();
            try ctx.setConfig(test_options);
            const params = std.json.parseFromSliceLeaky(std.json.Value, a, &buf, .{}) catch return;
            const c: *anyopaque = @ptrCast(&ctx);
            _ = handlePublish(c, params, a) catch {};
            _ = handlePublishPrefixed(c, params, a) catch {};
            _ = handleSubscribe(c, params, a) catch {};
        }
    }.run, .{});
}

test "handleSubscribe times out without a broker and releases its waiter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = MqttCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.setConfig(test_options);
    ctx.io = testing.io;
    try testing.expectError(error.MqttTimeout, handleSubscribe(@ptrCast(&ctx), try mkParams(a, "{\"topic\":\"t\",\"timeout\":0.02}"), a));
    try testing.expectEqual(@as(usize, 0), ctx.waiter_count);
}

test "subscribe waiters are bounded and released by shutdown" {
    var ctx = MqttCtx.init(testing.allocator);
    try ctx.setConfig(test_options);
    ctx.io = testing.io;
    var waiters: [max_subscribe_waiters]Waiter = undefined;
    for (&waiters) |*w| {
        w.* = .{ .topic = "t", .qos = 0 };
        try ctx.addWaiter(testing.io, w);
    }
    var extra: Waiter = .{ .topic = "t", .qos = 0 };
    try testing.expectError(error.ServiceUnavailable, ctx.addWaiter(testing.io, &extra));
    ctx.wakeWaiters("t", "msg");
    for (&waiters) |*w| {
        const payload = ctx.removeWaiter(testing.io, w).?;
        defer testing.allocator.free(payload);
        try testing.expectEqualStrings("msg", payload);
    }
    ctx.deinit();
    try testing.expectError(error.ServiceUnavailable, ctx.addWaiter(testing.io, &extra));
}

const TestDispatch = struct {
    saw_timestamp: bool = false,
    fn cb(ctx: *anyopaque, request: std.json.Value, alloc: std.mem.Allocator) anyerror![]u8 {
        const self: *TestDispatch = @ptrCast(@alignCast(ctx));
        if (request.object.get("params")) |p| self.saw_timestamp = p.object.contains("mqtt_timestamp");
        if (request.object.get("id") == null) return alloc.dupe(u8, "");
        return alloc.dupe(u8, "{\"jsonrpc\":\"2.0\",\"result\":\"ok\",\"id\":1}");
    }
};

test "apiResponse strips mqtt_timestamp, rejects duplicates with -10000 and skips notifications" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = MqttCtx.init(testing.allocator);
    defer ctx.deinit();
    var dispatch: TestDispatch = .{};
    ctx.api_dispatch = TestDispatch.cb;
    ctx.api_dispatch_ctx = &dispatch;

    const request = "{\"jsonrpc\":\"2.0\",\"method\":\"server.info\",\"params\":{\"mqtt_timestamp\":1.5},\"id\":1}";
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"result\":\"ok\",\"id\":1}", (try ctx.apiResponse(request, a)).?);
    try testing.expect(!dispatch.saw_timestamp);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-10000,\"message\":\"Duplicate MQTT Request\"},\"id\":1}",
        (try ctx.apiResponse(request, a)).?,
    );
    // A different timestamp in the same second is not a duplicate.
    _ = (try ctx.apiResponse("{\"jsonrpc\":\"2.0\",\"method\":\"m\",\"params\":{\"mqtt_timestamp\":1.75},\"id\":2}", a)).?;
    try testing.expect((try ctx.apiResponse("{\"jsonrpc\":\"2.0\",\"method\":\"m\"}", a)) == null);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32700,\"message\":\"Parse error\"},\"id\":null}",
        (try ctx.apiResponse("{", a)).?,
    );
}

test "isDuplicateTimestamp keeps only the last 20 values" {
    var ctx = MqttCtx.init(testing.allocator);
    defer ctx.deinit();
    for (0..max_timestamp_history + 1) |i| try testing.expect(!ctx.isDuplicateTimestamp(@floatFromInt(i)));
    try testing.expect(!ctx.isDuplicateTimestamp(0));
    try testing.expect(ctx.isDuplicateTimestamp(max_timestamp_history));
}

test "fuzz apiResponse: arbitrary payloads never crash the bridge" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var ctx = MqttCtx.init(testing.allocator);
            defer ctx.deinit();
            var dispatch: TestDispatch = .{};
            ctx.api_dispatch = struct {
                fn cb(_: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror![]u8 {
                    return alloc.dupe(u8, "{}");
                }
            }.cb;
            ctx.api_dispatch_ctx = &dispatch;
            _ = try ctx.apiResponse(&buf, arena.allocator());
        }
    }.run, .{});
}

test "registerMqtt wires off-Core routes and the JSON-RPC method" {
    const jsonrpc = @import("../jsonrpc.zig");
    var d = jsonrpc.Dispatcher.init(testing.allocator);
    defer d.deinit();
    var reg = Registry.init(testing.allocator, &d);
    defer reg.deinit();
    var ctx = MqttCtx.init(testing.allocator);
    defer ctx.deinit();
    try registerMqtt(&reg, &ctx);
    try testing.expect(reg.lookup(.POST, "/server/mqtt/publish").?.off_core);
    try testing.expect(reg.lookup(.POST, "/server/mqtt/subscribe").?.off_core);
    try testing.expect(d.methods.get("server.mqtt.publish").?.off_core);
    try testing.expect(d.methods.get("server.mqtt.publish_mqtt_topic").?.off_core);
}

// ---------------------------------------------------------------------------
// Live broker (mqtt_client.TestBroker over loopback TCP).
// ---------------------------------------------------------------------------

fn waitConnected(ctx: *MqttCtx, io: Io) !void {
    for (0..400) |_| {
        ctx.client_lock.lockSharedUncancelable(io);
        const connected = ctx.client != null;
        ctx.client_lock.unlockShared(io);
        if (connected) return;
        io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    return error.NotConnected;
}

test "live broker: online status, raw publish, offline status on shutdown" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var broker = try mqtt_client.TestBroker.bind(io);
    defer broker.deinit();
    // Online status, API subscribe, handler publish, offline status, DISCONNECT.
    var bf = io.async(mqtt_client.TestBroker.run, .{ &broker, @as(usize, 5) });
    defer bf.cancel(io);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = MqttCtx.init(testing.allocator);
    try ctx.setConfig(.{ .address = "127.0.0.1", .port = broker.port(), .instance_name = "phobos" });
    ctx.io = io;
    ctx.start();
    errdefer ctx.deinit();
    try waitConnected(&ctx, io);
    try testing.expect(waitFor(io, &broker.subscribes, 1));
    try testing.expectEqualStrings("phobos/moonraker/api/request", broker.last_subscribe[0..broker.last_subscribe_len]);
    try testing.expectEqualStrings("phobos/moonraker/status", broker.got_topic[0..broker.got_topic_len]);
    try testing.expectEqualStrings("{\"server\":\"online\"}", broker.got_payload[0..broker.got_payload_len]);
    try testing.expect(broker.got_retain);

    const result = try handlePublish(@ptrCast(&ctx), try mkParams(a, "{\"topic\":\"t/x\",\"payload\":\"hello\"}"), a);
    try testing.expectEqualStrings("t/x", result.object.get("topic").?.string);
    try testing.expect(waitFor(io, &broker.publishes, 2));
    try testing.expectEqualStrings("t/x", broker.got_topic[0..broker.got_topic_len]);
    try testing.expectEqualStrings("hello", broker.got_payload[0..broker.got_payload_len]);

    ctx.deinit();
    bf.await(io);
    try testing.expectEqualStrings("phobos/moonraker/status", broker.got_topic[0..broker.got_topic_len]);
    try testing.expectEqualStrings("{\"server\":\"offline\"}", broker.got_payload[0..broker.got_payload_len]);
}

test "live broker: subscribe returns the first message and api requests stay unsubscribed when disabled" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var broker = try mqtt_client.TestBroker.bind(io);
    defer broker.deinit();
    var bf = io.async(mqtt_client.TestBroker.run, .{ &broker, @as(usize, 16) });
    defer bf.cancel(io);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = MqttCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.setConfig(.{ .address = "127.0.0.1", .port = broker.port(), .instance_name = "phobos", .enable_moonraker_api = false });
    ctx.io = io;
    ctx.start();
    try waitConnected(&ctx, io);

    const Sub = struct {
        fn run(c: *MqttCtx, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
            return handleSubscribe(@ptrCast(c), params, alloc);
        }
    };
    var sub = try io.concurrent(Sub.run, .{ &ctx, try mkParams(a, "{\"topic\":\"sensor/t\",\"timeout\":5}"), a });
    defer if (sub.cancel(io)) |_| {} else |_| {};
    // The only SUBSCRIBE is the request's; the API topic is not subscribed.
    try testing.expect(waitFor(io, &broker.subscribes, 1));
    try testing.expectEqualStrings("sensor/t", broker.last_subscribe[0..broker.last_subscribe_len]);
    try broker.injectPublish("sensor/t", "{\"t\":21}");
    const result = try sub.await(io);
    try testing.expectEqual(@as(i64, 21), result.object.get("payload").?.object.get("t").?.integer);
    try testing.expectEqual(@as(u32, 1), broker.subscribes.load(.acquire));
}

test "live broker: keepalive sends PINGREQ every half interval" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var broker = try mqtt_client.TestBroker.bind(io);
    defer broker.deinit();
    var bf = io.async(mqtt_client.TestBroker.run, .{ &broker, @as(usize, 16) });
    defer bf.cancel(io);
    var ctx = MqttCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.setConfig(test_options);
    ctx.config.?.port = broker.port();
    ctx.keepalive_s = 1;
    ctx.io = io;
    ctx.start();
    try waitConnected(&ctx, io);
    try testing.expect(waitFor(io, &broker.pings, 1));
}

test "stop cancels a broker stalled before CONNACK" {
    const io = testing.io;
    var server = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer server.deinit(io);
    var accepted: std.Io.Event = .unset;
    const Peer = struct {
        fn run(s: *std.Io.net.Server, ready: *std.Io.Event, aio: std.Io) void {
            const stream = s.accept(aio) catch return;
            defer stream.close(aio);
            ready.set(aio);
            var buf: [512]u8 = undefined;
            var reader = stream.reader(aio, &buf);
            while (true) _ = reader.interface.takeByte() catch break;
        }
    };
    var peer = try io.concurrent(Peer.run, .{ &server, &accepted, io });
    defer peer.cancel(io);
    var ctx = MqttCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.setConfig(test_options);
    ctx.config.?.port = server.socket.address.getPort();
    ctx.io = io;
    ctx.start();
    try accepted.wait(io);
    const start_ts = std.Io.Clock.Timestamp.now(io, .awake);
    ctx.stop(io);
    try testing.expect(start_ts.untilNow(io).raw.toMilliseconds() < 1000);
    try testing.expect(ctx.connect_thread == null);
    try testing.expect(ctx.client == null);
}

test "refused connects retry and free each attempt" {
    var ctx = MqttCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.setConfig(test_options);
    ctx.config.?.port = 1; // refused
    ctx.io = testing.io;
    ctx.start();
    testing.io.sleep(.fromMilliseconds(50), .awake) catch {};
    try testing.expect(ctx.client == null);
}
