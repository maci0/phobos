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
//! and sends PINGREQ every half keepalive interval while replies arrive.
//! An unanswered ping closes the connection after one keepalive interval. A background reader
//! dispatches inbound PUBLISH frames: API requests go through the JSON-RPC
//! dispatcher and the response is published to
//! `{instance_name}/moonraker/api/response`; other topics wake pending
//! subscribe requests and reach `on_message` (MQTT sensors). Shutdown publishes
//! `{"server":"offline"}` and sends DISCONNECT with a one-second write budget.
//!
//! publish sends one PUBLISH with paho's payload encoding: objects and arrays
//! as JSON, strings raw, booleans `true`/`false`, null as an empty payload.
//! QoS 0 or an absent qos means `default_qos` (`qos or self.qos` upstream).
//! subscribe subscribes on the broker and waits, off the Core lock, for the
//! first message on the topic, bounded by `timeout`; it returns the payload
//! JSON-decoded, or as a string when it is not JSON. Invalid UTF-8 is rejected.
//!
//! Response shapes (mqtt.py): publish {"topic": t}, subscribe {"topic": t,
//! "payload": p}. Configuration and protocol limits are in docs/MQTT.md.

const std = @import("std");
const webreq = @import("../json/params.zig");
const sleep = @import("../util/sleep.zig");
const jv = @import("../json/value.zig");
const registry = @import("../server/registry.zig");
const mqtt_client = @import("mqtt_client.zig");
const mqtt_proto = @import("mqtt_proto.zig");
const mqtt_status = @import("mqtt_status.zig");
const connections = @import("../server/connections.zig");

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
const max_permanent_topics = 128;
const max_permanent_topic_bytes = 64 * 1024;
/// Longest honoured subscribe `timeout`, keeping deadlines representable on 32-bit.
const max_timeout_s: f64 = std.time.s_per_day;
/// Best-effort offline publication must not delay shutdown behind broker I/O.
const shutdown_timeout: Io.Duration = .fromSeconds(1);
const subscription_timeout: Io.Duration = .fromSeconds(5);
const local_transports = [_]registry.TransportType{ .HTTP, .WEBSOCKET, .INTERNAL };
const scientific_min: f64 = 1e-4;
const scientific_max: f64 = 1e16;

const online_payload = "{\"server\":\"online\"}";
const offline_payload = "{\"server\":\"offline\"}";

/// Moonraker `[mqtt]` options. Slices are borrowed; `setConfig` copies them.
pub const Options = struct {
    address: []const u8,
    protocol: mqtt_proto.Protocol = .v311,
    clock_io: ?Io = null,
    status_objects: std.json.Value = .{ .object = .empty },
    status_interval: f64 = 0,
    publish_split_status: bool = false,
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
    protocol: mqtt_proto.Protocol,
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
    home_directory: ?[]const u8 = null,
    status: ?mqtt_status.StatusCtx = null,
    klippy_connected: bool = false,
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
    /// Sensor subscriptions survive individual subscribe requests.
    permanent_topics: std.StringHashMapUnmanaged(u2) = .empty,
    permanent_topic_bytes: usize = 0,
    /// Fixed-size fingerprints avoid retaining arbitrary request-owned JSON.
    api_timestamps: [max_timestamp_history][32]u8 = undefined,
    api_timestamp_len: usize = 0,
    api_timestamp_next: usize = 0,
    api_timestamp_mutex: Io.Mutex = .init,
    /// Inbound-message hook (reader thread). The app routes it to MQTT sensors
    /// under the Core lock.
    on_message: ?*const fn (ctx: *anyopaque, topic: []const u8, payload: []const u8) void = null,
    on_message_ctx: ?*anyopaque = null,
    /// Post-connect hook (supervisor thread), run after each (re)connect. The
    /// app uses it to subscribe sensor topics.
    on_connected: ?*const fn (ctx: *anyopaque) void = null,
    on_connected_ctx: ?*anyopaque = null,
    /// Connection transitions run outside Core; the app serializes consumers.
    on_connection: ?*const fn (ctx: *anyopaque, connected: bool) void = null,
    on_connection_ctx: ?*anyopaque = null,
    /// JSON-RPC dispatch for API requests. Returns the response bytes (empty
    /// for a notification) allocated in `alloc`.
    api_dispatch: ?*const fn (ctx: *anyopaque, request: std.json.Value, alloc: std.mem.Allocator) anyerror![]u8 = null,
    api_dispatch_ctx: ?*anyopaque = null,

    pub fn init(gpa: std.mem.Allocator) MqttCtx {
        return .{ .gpa = gpa };
    }

    /// Startup HOME copy for credential file expansion, independent of environment lifetime.
    pub fn setHomeDirectory(self: *MqttCtx, home: ?[]const u8) !void {
        const replacement = if (home) |path| try self.gpa.dupe(u8, path) else null;
        if (self.home_directory) |previous| self.gpa.free(previous);
        self.home_directory = replacement;
    }

    /// Stop the supervisor, wake pending subscribers and free the config.
    pub fn deinit(self: *MqttCtx) void {
        if (self.status) |*status| status.stop();
        if (self.io) |io| self.stop(io);
        if (self.status) |*status| status.deinit();
        self.status = null;
        if (self.config) |*cfg| cfg.arena.deinit();
        self.config = null;
        if (self.home_directory) |home| self.gpa.free(home);
        self.home_directory = null;
        var topics = self.permanent_topics.keyIterator();
        while (topics.next()) |topic| self.gpa.free(topic.*);
        self.permanent_topics.deinit(self.gpa);
    }

    /// Validate and copy `[mqtt]` options. Replaces the previous config only on
    /// success. Call before `start`.
    pub fn setConfig(self: *MqttCtx, opts: Options) !void {
        if (opts.instance_name.len != 0) mqtt_proto.validateTopicName(opts.instance_name) catch return error.InvalidInstanceName;
        const longest_suffix = "/moonraker/api/response";
        if (opts.instance_name.len > std.math.maxInt(u16) - longest_suffix.len) return error.InvalidInstanceName;
        if (self.connect_thread != null) return error.AlreadyStarted;
        const default_qos = try qosValue(opts.default_qos);
        const api_qos = try qosValue(opts.api_qos orelse opts.default_qos);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const name = try a.dupe(u8, opts.instance_name);
        const cfg: MqttConfig = .{
            .arena = undefined,
            .address = try a.dupe(u8, opts.address),
            .protocol = opts.protocol,
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
        const connect_packet = try mqtt_proto.encodeConnect(self.gpa, self.connectOptions(&cfg));
        defer self.gpa.free(connect_packet);
        var status: ?mqtt_status.StatusCtx = null;
        errdefer if (status) |*owned| owned.deinit();
        if (opts.status_objects != .object) return error.InvalidStatusObjects;
        if (!std.math.isFinite(opts.status_interval) or (opts.status_interval != 0 and opts.status_interval <= 0.25)) return error.InvalidStatusInterval;
        if (opts.status_objects.object.count() != 0) {
            status = mqtt_status.StatusCtx.init(self.gpa, opts.clock_io orelse self.io orelse return error.MissingIo);
            try status.?.setConfig(.{ .instance_name = name, .default_qos = default_qos, .status_objects = opts.status_objects, .status_interval = opts.status_interval, .publish_split_status = opts.publish_split_status });
        }
        if (self.status) |*old| old.deinit();
        self.status = status;
        self.klippy_connected = false;
        if (self.config) |*old| old.arena.deinit();
        self.config = cfg;
        self.config.?.arena = arena;
    }

    /// Start the reconnect supervisor when a broker is configured and io is wired.
    pub fn start(self: *MqttCtx) void {
        if (self.config == null or self.connect_thread != null) return;
        const io = self.io orelse return;
        if (self.status) |*status| status.start(publishStatus, self) catch |err| {
            std.debug.print("phobos: warning: MQTT status worker not started: {}\n", .{err});
            return;
        };
        self.reader_stop.reset();
        self.connect_thread = io.concurrent(supervise, .{self}) catch |err| {
            if (self.status) |*status| status.stop();
            std.debug.print("phobos: warning: MQTT worker not started: {}\n", .{err});
            return;
        };
    }

    /// Wake subscribers, bound the offline write, then join all workers.
    fn stop(self: *MqttCtx, io: Io) void {
        self.reader_stop.set(io);
        self.client_lock.lockSharedUncancelable(io);
        if (self.client) |client| {
            var done: Io.Event = .unset;
            if (io.concurrent(disconnect, .{ self, client, &done })) |future| {
                var closing = future;
                const deadline = Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = shutdown_timeout, .clock = .awake });
                done.waitTimeout(io, .{ .deadline = deadline }) catch {};
                client.cancelPending();
                client.shutdownRecv();
                closing.cancel(io);
            } else |_| {}
            client.cancelPending();
            client.shutdownRecv();
        }
        self.client_lock.unlockShared(io);
        self.closeWaiters(io);
        if (self.connect_thread) |*t| {
            t.cancel(io);
            self.connect_thread = null;
        }
        self.waiters_mutex.lockUncancelable(io);
        defer self.waiters_mutex.unlock(io);
        while (self.waiter_count != 0) self.waiters_idle.waitUncancelable(io, &self.waiters_mutex);
    }

    fn disconnect(self: *MqttCtx, client: *MqttClient, done: *Io.Event) void {
        defer done.set(self.io.?);
        if (self.config) |cfg| client.publishAwait(cfg.status_topic, offline_payload, cfg.default_qos, true, shutdown_timeout) catch return;
        client.disconnect();
    }

    /// CONNECT options for `cfg`: the retained offline Last Will (mqtt.py
    /// `will_set`) and credentials.
    fn connectOptions(self: *const MqttCtx, cfg: *const MqttConfig) mqtt_proto.ConnectOptions {
        return .{
            .protocol = cfg.protocol,
            .client_id = cfg.client_id,
            .username = cfg.username,
            .password = if (cfg.username != null) cfg.password else null,
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
        var subscriptions = std.heap.ArenaAllocator.init(self.gpa);
        defer subscriptions.deinit();
        const a = subscriptions.allocator();
        var topics: std.ArrayList([]const u8) = .empty;
        {
            self.waiters_mutex.lockUncancelable(io);
            defer self.waiters_mutex.unlock(io);
            var permanent = self.permanent_topics.keyIterator();
            while (permanent.next()) |topic| try topics.append(a, try a.dupe(u8, topic.*));
            var it = self.waiters.first;
            while (it) |node| : (it = node.next) {
                const waiter: *Waiter = @fieldParentPtr("node", node);
                try topics.append(a, try a.dupe(u8, waiter.topic));
            }
            self.reader_done.reset();
            self.reader_thread = try io.concurrent(runReader, .{ self, client });
            self.setClient(io, client);
        }
        errdefer {
            client.shutdownRecv();
            self.reader_thread.?.await(io);
            self.reader_thread = null;
            self.setClient(io, null);
        }
        // The reader must drain SUBACKs before a bounded window can be refilled.
        try client.publish(cfg.status_topic, online_payload, cfg.default_qos, true);
        if (cfg.enable_moonraker_api) try self.changeSubscription(io, cfg.api_request_topic, true);
        for (topics.items) |topic| try self.changeSubscription(io, topic, true);
        if (self.status) |*status| status.setBrokerConnected(true);
        if (self.on_connection) |cb| cb(self.on_connection_ctx.?, true);
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
        const keepalive = client.limits.server_keepalive orelse self.keepalive_s;
        if (keepalive == 0) {
            self.reader_done.wait(io) catch {};
            return;
        }
        const interval: Io.Duration = .fromMilliseconds(@as(i64, keepalive) * (std.time.ms_per_s / 2));
        var missed: u2 = 0;
        while (!sleep.untilStopped(io, interval, &self.reader_done)) {
            if (client.ping_pending.load(.acquire)) {
                missed += 1;
                if (missed == 2) return;
            } else {
                missed = 0;
                client.ping() catch return;
            }
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
        if (self.status) |*status| status.setBrokerConnected(false);
        if (self.on_connection) |cb| cb(self.on_connection_ctx.?, false);
        client.deinit();
        self.gpa.destroy(client);
    }

    fn runReader(self: *MqttCtx, client: *MqttClient) void {
        defer self.reader_done.set(self.io.?);
        while (true) _ = client.readOne() catch return;
    }

    /// MqttClient.on_publish (reader thread).
    fn onPublish(ctx: *anyopaque, topic: []const u8, payload: []const u8) void {
        const self: *MqttCtx = @ptrCast(@alignCast(ctx));
        if (self.reader_stop.isSet()) return;
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

    /// Dispatch parsed MQTT requests. The dispatcher screens each validated
    /// request, including batch entries. Returns response bytes in `alloc`.
    fn apiResponse(self: *MqttCtx, payload: []const u8, alloc: std.mem.Allocator) !?[]const u8 {
        const dispatch = self.api_dispatch orelse return null;
        const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, payload, .{}) catch
            return try jv.errorResponse(alloc, .null, -32700, "Parse error");
        if (jv.exceedsDepth(root, jv.max_value_depth)) return try jv.errorResponse(alloc, .null, -32600, "Invalid Request");
        const response = try dispatch(self.api_dispatch_ctx.?, root, alloc);
        return if (response.len == 0) null else response;
    }

    /// Caller owns the configured object/field selector tree.
    pub fn statusSubscription(self: *const MqttCtx, alloc: std.mem.Allocator) !std.json.Value {
        return if (self.status) |*status| status.subscription(alloc) else .{ .object = .empty };
    }

    /// Called under Core; status transport work is queued for its own worker.
    pub fn klippyState(self: *MqttCtx, connected: bool) !void {
        if (self.klippy_connected == connected) return;
        const status = if (self.status) |*status| status else return;
        if (connected) try status.klippyStarted(.{ .object = .empty }, 0) else try status.klippyDisconnected();
        self.klippy_connected = connected;
    }

    pub fn klippyStatus(self: *MqttCtx, status: std.json.Value, eventtime: std.json.Value) !void {
        const owner = if (self.status) |*owner| owner else return;
        const timestamp: f64 = switch (eventtime) {
            .integer => |number| @floatFromInt(number),
            .float => |number| number,
            else => return error.InvalidStatus,
        };
        try owner.ingest(status, timestamp);
    }

    fn publishStatus(ctx: *anyopaque, topic: []const u8, payload: []const u8, qos: u2, retain: bool) !void {
        const self: *MqttCtx = @ptrCast(@alignCast(ctx));
        try self.publishAwait(topic, payload, qos, retain, null);
    }

    /// Called after method lookup so invalid requests do not consume timestamps.
    pub fn screenRequest(ctx: *anyopaque, params: *std.json.Value, _: std.mem.Allocator) !void {
        const self: *MqttCtx = @ptrCast(@alignCast(ctx));
        const entry = params.object.fetchOrderedRemove("mqtt_timestamp") orelse return;
        if (entry.value == .null) return;
        if (jv.exceedsDepth(entry.value, jv.max_value_depth)) return error.InvalidParams;
        const digest = timestampDigest(entry.value);
        const io = self.io orelse return error.ServiceUnavailable;
        self.api_timestamp_mutex.lockUncancelable(io);
        defer self.api_timestamp_mutex.unlock(io);
        for (self.api_timestamps[0..self.api_timestamp_len]) |previous| {
            if (std.mem.eql(u8, &previous, &digest)) return error.DuplicateMqttRequest;
        }
        self.api_timestamps[self.api_timestamp_next] = digest;
        self.api_timestamp_next = (self.api_timestamp_next + 1) % max_timestamp_history;
        self.api_timestamp_len = @min(self.api_timestamp_len + 1, max_timestamp_history);
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

    fn publishAwait(self: *MqttCtx, topic: []const u8, bytes: []const u8, qos: u2, retain: bool, timeout: ?Io.Duration) !void {
        const io = self.io orelse return error.ServiceUnavailable;
        try self.client_lock.lockShared(io);
        defer self.client_lock.unlockShared(io);
        const client = self.client orelse return error.ServiceUnavailable;
        client.publishAwait(topic, bytes, qos, retain, timeout) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.PublishTimeout => error.MqttPublishTimeout,
            error.InvalidTopic, error.InvalidUtf8, error.StringTooLong, error.ValueTooLarge => error.InvalidParams,
            else => error.ServiceUnavailable,
        };
    }

    /// Register a persistent sensor filter and subscribe when connected. Off Core.
    pub fn subscribeTopicLive(self: *MqttCtx, topic: []const u8, qos: ?u2) void {
        const io = self.io orelse return;
        const cfg = &(self.config orelse return);
        mqtt_proto.validateTopicFilter(topic) catch return;
        const requested = qos orelse cfg.default_qos;
        self.waiters_mutex.lockUncancelable(io);
        if (self.permanent_topics.getPtr(topic)) |existing| {
            if (existing.* >= requested) {
                self.waiters_mutex.unlock(io);
                return;
            }
            existing.* = requested;
        } else {
            if (self.permanent_topics.count() == max_permanent_topics or topic.len > max_permanent_topic_bytes - self.permanent_topic_bytes) {
                self.waiters_mutex.unlock(io);
                std.debug.print("phobos: warning: MQTT sensor subscription limit exceeded\n", .{});
                return;
            }
            const owned = self.gpa.dupe(u8, topic) catch {
                self.waiters_mutex.unlock(io);
                return;
            };
            self.permanent_topics.put(self.gpa, owned, requested) catch {
                self.gpa.free(owned);
                self.waiters_mutex.unlock(io);
                return;
            };
            self.permanent_topic_bytes += owned.len;
        }
        self.waiters_mutex.unlock(io);
        self.changeSubscription(io, topic, true) catch {}; // Reconnect retries registered filters.
    }

    fn subscriptionQosLocked(self: *MqttCtx, topic: []const u8) ?u2 {
        var qos = self.permanent_topics.get(topic);
        if (self.config) |cfg| if (cfg.enable_moonraker_api and std.mem.eql(u8, topic, cfg.api_request_topic)) {
            qos = @max(qos orelse 0, cfg.effectiveQos(cfg.api_qos));
        };
        var it = self.waiters.first;
        while (it) |node| : (it = node.next) {
            const waiter: *Waiter = @fieldParentPtr("node", node);
            if (std.mem.eql(u8, topic, waiter.topic)) qos = @max(qos orelse 0, waiter.qos);
        }
        return qos;
    }

    /// Serialize topic changes, releasing locks while waiting for ACK capacity.
    fn changeSubscription(self: *MqttCtx, io: Io, topic: []const u8, subscribe: bool) !void {
        const deadline = Io.Clock.Timestamp.fromNow(io, .{ .raw = subscription_timeout, .clock = .awake });
        while (true) {
            self.waiters_mutex.lockUncancelable(io);
            const qos = self.subscriptionQosLocked(topic);
            if (subscribe != (qos != null)) {
                self.waiters_mutex.unlock(io);
                return;
            }
            self.client_lock.lockSharedUncancelable(io);
            const result: anyerror!void = if (self.client) |client|
                if (subscribe) client.subscribe(topic, qos.?) else client.unsubscribe(topic)
            else
                error.ServiceUnavailable;
            self.client_lock.unlockShared(io);
            self.waiters_mutex.unlock(io);
            result catch |err| {
                if (err != error.MessageQueueFull) {
                    if (err != error.ServiceUnavailable) self.shutdownClient(io);
                    return err;
                }
                if (Io.Clock.Timestamp.now(io, .awake).compare(.gte, deadline)) {
                    self.shutdownClient(io);
                    return error.SubscriptionTimeout;
                }
                if (sleep.untilStopped(io, .fromMilliseconds(1), &self.reader_stop)) return error.Canceled;
                continue;
            };
            return;
        }
    }

    fn shutdownClient(self: *MqttCtx, io: Io) void {
        self.client_lock.lockSharedUncancelable(io);
        defer self.client_lock.unlockShared(io);
        if (self.client) |client| client.shutdownRecv();
    }

    fn addWaiter(self: *MqttCtx, io: Io, waiter: *Waiter) !void {
        self.waiters_mutex.lockUncancelable(io);
        if (self.waiters_closed or self.waiter_count == max_subscribe_waiters) {
            self.waiters_mutex.unlock(io);
            return error.ServiceUnavailable;
        }
        self.waiters.append(&waiter.node);
        self.waiter_count += 1;
        self.waiters_mutex.unlock(io);
        self.changeSubscription(io, waiter.topic, true) catch {}; // Reconnect retries linked waiters.
    }

    /// Remove a one-shot subscription only after its last waiter exits.
    fn removeWaiter(self: *MqttCtx, io: Io, waiter: *Waiter) ?[]u8 {
        self.waiters_mutex.lockUncancelable(io);
        self.waiters.remove(&waiter.node);
        const last = self.subscriptionQosLocked(waiter.topic) == null;
        self.waiters_mutex.unlock(io);
        if (last) self.changeSubscription(io, waiter.topic, false) catch {}; // Disconnect removes this clean-session subscription.
        self.waiters_mutex.lockUncancelable(io);
        defer self.waiters_mutex.unlock(io);
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

    /// Refuse new waiters and wake pending ones before joining the reader.
    fn closeWaiters(self: *MqttCtx, io: Io) void {
        self.waiters_mutex.lockUncancelable(io);
        defer self.waiters_mutex.unlock(io);
        self.waiters_closed = true;
        var it = self.waiters.first;
        while (it) |node| : (it = node.next) {
            const waiter: *Waiter = @fieldParentPtr("node", node);
            waiter.done.set(io);
        }
    }
};

/// Python equality treats object order as irrelevant and bools as numbers.
/// SHA-256 bounds the 20-entry history to 640 bytes regardless of JSON size.
fn timestampDigest(value: std.json.Value) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    switch (value) {
        .null => hash.update("null"),
        .string => |s| {
            hash.update("string");
            hash.update(s);
        },
        .bool => |b| return timestampDigest(.{ .integer = @intFromBool(b) }),
        .integer => |n| {
            var buf: [21]u8 = undefined;
            hash.update("number");
            hash.update(std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable);
        },
        .number_string => |s| {
            if (!std.json.isNumberFormattedLikeAnInteger(s)) return timestampDigest(.{ .float = std.fmt.parseFloat(f64, s) catch unreachable });
            hash.update("number");
            hash.update(s);
        },
        .float => |f| {
            if (std.math.isFinite(f) and @trunc(f) == f) {
                const limb_count = comptime std.math.big.int.calcLimbLen(std.math.floatMax(f64));
                var limbs: [limb_count]std.math.big.Limb = undefined;
                var n = std.math.big.int.Mutable.init(&limbs, 0);
                std.debug.assert(n.setFloat(f, .trunc) == .exact);
                var workspace: [std.math.big.int.calcToStringLimbsBufferLen(limb_count, 10)]std.math.big.Limb = undefined;
                var buf: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
                const len = n.toConst().toString(&buf, 10, .lower, &workspace);
                hash.update("number");
                hash.update(buf[0..len]);
            } else {
                var bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &bytes, @bitCast(f), .big);
                hash.update("float");
                hash.update(&bytes);
            }
        },
        .array => |array| {
            hash.update("array");
            for (array.items) |item| hash.update(&timestampDigest(item));
        },
        .object => |obj| {
            var combined: [32]u8 = @splat(0);
            var entries = obj.iterator();
            while (entries.next()) |entry| {
                var item_hash = std.crypto.hash.sha2.Sha256.init(.{});
                var key_len: [8]u8 = undefined;
                std.mem.writeInt(u64, &key_len, entry.key_ptr.len, .big);
                item_hash.update(&key_len);
                item_hash.update(entry.key_ptr.*);
                item_hash.update(&timestampDigest(entry.value_ptr.*));
                const digest = item_hash.finalResult();
                for (&combined, digest) |*byte, other| byte.* ^= other;
            }
            var count: [8]u8 = undefined;
            std.mem.writeInt(u64, &count, obj.count(), .big);
            hash.update("object");
            hash.update(&count);
            hash.update(&combined);
        },
    }
    return hash.finalResult();
}

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

fn requestTimeout(params: std.json.Value) error{InvalidParams}!?f64 {
    const seconds = (try webreq.optional(f64, params, "timeout")) orelse return null;
    if (!std.math.isFinite(seconds)) return error.InvalidParams;
    return seconds;
}

/// paho's payload encoding: JSON for objects and arrays, raw strings,
/// `true`/`false`, numbers in decimal, nothing for null.
fn encodePayload(w: *std.Io.Writer, payload: std.json.Value) !void {
    switch (payload) {
        .null => {},
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try encodeFloat(w, f),
        .string, .number_string => |s| try w.writeAll(s),
        .object, .array => {
            if (jv.exceedsDepth(payload, jv.max_value_depth)) return error.InvalidParams;
            var jw: std.json.Stringify = .{ .writer = w };
            try jw.write(payload);
        },
    }
}

/// paho uses Python's shortest float spelling, including `.0` and signed exponents.
fn encodeFloat(w: *std.Io.Writer, value: f64) std.Io.Writer.Error!void {
    var buf: [std.fmt.float.min_buffer_size]u8 = undefined;
    if (!std.math.isFinite(value)) return w.writeAll(std.fmt.float.render(&buf, value, .{}) catch unreachable);
    const absolute = @abs(value);
    if (absolute >= scientific_max or (absolute != 0 and absolute < scientific_min)) {
        const text = std.fmt.float.render(&buf, value, .{}) catch unreachable;
        const e = std.mem.indexOfScalar(u8, text, 'e').?;
        const exponent = std.fmt.parseInt(i16, text[e + 1 ..], 10) catch unreachable;
        try w.writeAll(text[0 .. e + 1]);
        try w.writeByte(if (exponent < 0) '-' else '+');
        try w.print("{d:0>2}", .{@abs(exponent)});
    } else {
        const text = std.fmt.float.render(&buf, value, .{ .mode = .decimal }) catch unreachable;
        try w.writeAll(text);
        if (std.mem.indexOfScalar(u8, text, '.') == null) try w.writeAll(".0");
    }
}

/// Validate a subscription topic: Moonraker rejects the wildcards `#` and `+`.
fn validateTopic(topic: []const u8) error{InvalidParams}!void {
    mqtt_proto.validateTopicName(topic) catch return error.InvalidParams;
}

fn publishParams(ctx: *MqttCtx, topic: []const u8, params: std.json.Value) !void {
    const cfg = &(ctx.config orelse return error.MqttNotConfigured);
    try validateTopic(topic);
    const qos = try requestQos(cfg, params);
    const retain = ((try webreq.optional(bool, params, "retain")) orelse false);
    const payload = if (params == .object) params.object.get("payload") orelse .null else .null;
    var aw: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer aw.deinit();
    encodePayload(&aw.writer, payload) catch |err| return switch (err) {
        error.InvalidParams => error.InvalidParams,
        error.WriteFailed => error.OutOfMemory,
    };
    const timeout = try requestTimeout(params);
    if (timeout) |seconds| if (seconds <= 0) return error.MqttPublishTimeout;
    try ctx.publishAwait(topic, aw.written(), qos, retain, if (timeout) |seconds| .fromNanoseconds(std.math.lossyCast(i96, @min(seconds, max_timeout_s) * std.time.ns_per_s)) else null);
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// POST /server/mqtt/publish → {"topic": <topic>}. Runs off the Core lock.
/// QoS 1 and 2 wait for PUBACK/PUBCOMP within the optional timeout.
pub fn handlePublish(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *MqttCtx = @ptrCast(@alignCast(ctx_ptr));
    const topic = try webreq.required([]const u8, params, "topic");
    _ = try requestTimeout(params);
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
    const timeout = try requestTimeout(params);
    const io = ctx.io orelse return error.ServiceUnavailable;

    var waiter: Waiter = .{ .topic = topic, .qos = qos };
    try ctx.addWaiter(io, &waiter);
    const woken = if (timeout) |t|
        sleep.untilStopped(io, .fromNanoseconds(std.math.lossyCast(i96, @min(t, max_timeout_s) * std.time.ns_per_s)), &waiter.done)
    else blk: {
        waiter.done.wait(io) catch {};
        break :blk true;
    };
    const message = ctx.removeWaiter(io, &waiter);
    defer if (message) |m| ctx.gpa.free(m);
    const bytes = message orelse return if (woken) error.ServiceUnavailable else error.MqttTimeout;

    const payload = try decodePayload(alloc, bytes);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "topic", .{ .string = topic });
    try obj.put(alloc, "payload", payload);
    return .{ .object = obj };
}

/// Decode one UTF-8 payload; returned strings and containers belong to alloc.
fn decodePayload(alloc: std.mem.Allocator, bytes: []const u8) error{ OutOfMemory, InvalidUtf8 }!std.json.Value {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .string = try alloc.dupe(u8, bytes) },
    };
    return if (jv.exceedsDepth(parsed, jv.max_value_depth)) .{ .string = try alloc.dupe(u8, bytes) } else parsed;
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
    try reg.registerEndpoint(.{ .path = "/server/mqtt/publish", .methods = &.{.POST}, .transports = &local_transports, .off_core = true }, c, handlePublish);
    try reg.registerEndpoint(.{ .path = "/server/mqtt/subscribe", .methods = &.{.POST}, .transports = &local_transports, .off_core = true }, c, handleSubscribe);
    try reg.dispatcher.registerEntry("server.mqtt.publish_mqtt_topic", .{ .ctx = c, .handler = handlePublishPrefixed, .transports = &local_transports, .off_core = true });
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
        .{ .in = "1.0", .out = "1.0" },
        .{ .in = "-0.0", .out = "-0.0" },
        .{ .in = "1e20", .out = "1e+20" },
        .{ .in = "1e-5", .out = "1e-05" },
        .{ .in = "1e-4", .out = "0.0001" },
        .{ .in = "1e15", .out = "1000000000000000.0" },
        .{ .in = "1e16", .out = "1e+16" },
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

test "fuzz encodeFloat preserves every finite f64 value and signed zero" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var bytes: [8]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const value: f64 = @bitCast(std.mem.readInt(u64, &bytes, .little));
            var writer: std.Io.Writer.Allocating = .init(testing.allocator);
            defer writer.deinit();
            try encodeFloat(&writer.writer, value);
            const parsed = try std.fmt.parseFloat(f64, writer.written());
            if (std.math.isNan(value)) {
                try testing.expect(std.math.isNan(parsed));
            } else {
                try testing.expectEqual(@as(u64, @bitCast(value)), @as(u64, @bitCast(parsed)));
            }
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

test "MQTT handlers reject invalid topics before creating waiters or touching the broker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = MqttCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.setConfig(test_options);
    ctx.io = testing.io;
    const long = try a.alloc(u8, std.math.maxInt(u16) + 1);
    @memset(long, 'a');
    for ([_][]const u8{ "", "a/#", "a/+/b", "\x00", "\xff", long }) |topic| {
        var params: std.json.ObjectMap = .empty;
        try params.put(a, "topic", .{ .string = topic });
        try testing.expectError(error.InvalidParams, handlePublish(@ptrCast(&ctx), .{ .object = params }, a));
        try testing.expectError(error.InvalidParams, handleSubscribe(@ptrCast(&ctx), .{ .object = params }, a));
        try testing.expectError(error.InvalidParams, handlePublishPrefixed(@ptrCast(&ctx), .{ .object = params }, a));
        try testing.expectEqual(@as(usize, 0), ctx.waiter_count);
    }
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

test "handleSubscribe serializes numeric payloads and rejects binary text" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = MqttCtx.init(std.heap.smp_allocator);
    defer ctx.deinit();
    try ctx.setConfig(test_options);
    ctx.io = io;
    const Publisher = struct {
        fn run(c: *MqttCtx, bytes: []const u8) !void {
            const aio = c.io.?;
            const deadline = Io.Clock.Timestamp.fromNow(aio, .{ .raw = .fromSeconds(1), .clock = .awake });
            while (Io.Clock.Timestamp.now(aio, .awake).compare(.lt, deadline)) {
                c.waiters_mutex.lockUncancelable(aio);
                const ready = c.waiter_count > 0;
                c.waiters_mutex.unlock(aio);
                if (ready) {
                    c.wakeWaiters("test/payload", bytes);
                    return;
                }
                try aio.sleep(.fromMilliseconds(1), .awake);
            }
            return error.NoWaiter;
        }
    };
    for ([_][]const u8{ "{\"v\":[1.25,-2,{\"huge\":[1e500,-1e500]}]}", "not JSON", "\xff" }) |bytes| {
        var publish = try io.concurrent(Publisher.run, .{ &ctx, bytes });
        defer publish.cancel(io) catch {};
        const response = handleSubscribe(@ptrCast(&ctx), try mkParams(a, "{\"topic\":\"test/payload\",\"timeout\":2}"), a);
        if (!std.unicode.utf8ValidateSlice(bytes)) {
            try testing.expectError(error.InvalidUtf8, response);
        } else {
            const wire = try std.json.Stringify.valueAlloc(a, try response, .{});
            const decoded = try std.json.parseFromSliceLeaky(std.json.Value, a, wire, .{});
            const payload = decoded.object.get("payload").?;
            if (std.mem.eql(u8, bytes, "not JSON")) {
                try testing.expectEqualStrings(bytes, payload.string);
            } else {
                const values = payload.object.get("v").?.array.items;
                try testing.expectEqual(@as(f64, 1.25), values[0].float);
                try testing.expectEqual(@as(i64, -2), values[1].integer);
                const huge = values[2].object.get("huge").?.array.items;
                try testing.expectEqualStrings("1e500", huge[0].number_string);
                try testing.expectEqualStrings("-1e500", huge[1].number_string);
            }
        }
        try publish.await(io);
        try testing.expectEqual(@as(usize, 0), ctx.waiter_count);
    }
}

test "fuzz MQTT payload decoding only produces valid JSON" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var bytes: [256]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const nested = bytes[0] % 2 == 0;
            const depth: usize = bytes[1] % 128;
            if (nested) {
                @memset(bytes[0..depth], '[');
                @memset(bytes[depth .. depth * 2], ']');
            }
            const source = if (nested) bytes[0 .. depth * 2] else &bytes;
            const parsed = decodePayload(a, source) catch |err| switch (err) {
                error.InvalidUtf8 => {
                    try testing.expect(!std.unicode.utf8ValidateSlice(source));
                    return;
                },
                else => return err,
            };
            try testing.expect(!jv.exceedsDepth(parsed, jv.max_value_depth));
            const wire = try std.json.Stringify.valueAlloc(a, parsed, .{});
            try testing.expect(std.unicode.utf8ValidateSlice(wire));
            _ = try std.json.parseFromSliceLeaky(std.json.Value, a, wire, .{});
        }
    }.run, .{});
}

test "MQTT payload decoding releases partial allocations" {
    const Allocation = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const parsed = try decodePayload(a, "{\"items\":[1,{\"value\":\"test\"}]}");
            const wire = try std.json.Stringify.valueAlloc(a, parsed, .{});
            try testing.expectEqualStrings("{\"items\":[1,{\"value\":\"test\"}]}", wire);
            try testing.expectEqualStrings("plain text", (try decodePayload(a, "plain text")).string);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Allocation.run, .{});
}

test "MQTT handlers reject invalid timeout before network I/O" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = MqttCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.setConfig(test_options);
    for ([_][]const u8{ "null", "\"nan\"", "\"inf\"", "\"bad\"", "1e400", "{}", "[]" }) |value| {
        const json = try std.fmt.allocPrint(a, "{{\"topic\":\"t\",\"timeout\":{s}}}", .{value});
        const params = try mkParams(a, json);
        try testing.expectError(error.InvalidParams, handlePublish(@ptrCast(&ctx), params, a));
        try testing.expectError(error.InvalidParams, handleSubscribe(@ptrCast(&ctx), params, a));
        try testing.expectEqual(@as(usize, 0), ctx.waiter_count);
    }
    try testing.expectEqual(@as(?f64, null), try requestTimeout(.null));
    try testing.expectEqual(@as(?f64, -0.5), try requestTimeout(try mkParams(a, "{\"timeout\":\"-0.5\"}")));
}

test "fuzz MQTT timeout accepts only finite converted values" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var params: std.json.ObjectMap = .empty;
            const seconds = smith.value(f64);
            try params.put(arena.allocator(), "timeout", .{ .float = seconds });
            const result = requestTimeout(.{ .object = params });
            if (std.math.isFinite(seconds)) {
                try testing.expectEqual(seconds, (try result).?);
            } else {
                try testing.expectError(error.InvalidParams, result);
            }
        }
    }.run, .{});
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
    mqtt: *MqttCtx,
    dispatcher: @import("../jsonrpc.zig").Dispatcher,
    saw_timestamp: bool = false,
    calls: usize = 0,
    fn cb(ctx: *anyopaque, request: std.json.Value, alloc: std.mem.Allocator) anyerror![]u8 {
        const self: *TestDispatch = @ptrCast(@alignCast(ctx));
        return self.dispatcher.handleParsedRoot(.{ .transport = .MQTT, .screen = .{ .ctx = self.mqtt, .run = MqttCtx.screenRequest } }, request, alloc);
    }
    fn handler(ctx: *anyopaque, params: std.json.Value, _: std.mem.Allocator) !std.json.Value {
        const self: *TestDispatch = @ptrCast(@alignCast(ctx));
        self.saw_timestamp = self.saw_timestamp or params.object.contains("mqtt_timestamp");
        self.calls += 1;
        return .{ .string = "ok" };
    }
};

test "apiResponse strips mqtt_timestamp, rejects duplicates with -10000 and skips notifications" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = MqttCtx.init(testing.allocator);
    defer ctx.deinit();
    ctx.io = testing.io;
    var dispatch: TestDispatch = .{ .mqtt = &ctx, .dispatcher = .init(testing.allocator) };
    defer dispatch.dispatcher.deinit();
    try dispatch.dispatcher.register("server.info", &dispatch, TestDispatch.handler);
    try dispatch.dispatcher.register("m", &dispatch, TestDispatch.handler);
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

test "screenRequest keeps only the last 20 values" {
    var ctx = MqttCtx.init(testing.allocator);
    defer ctx.deinit();
    ctx.io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..max_timestamp_history + 1) |i| {
        var params = try mkParams(a, try std.fmt.allocPrint(a, "{{\"mqtt_timestamp\":{d}}}", .{i}));
        try MqttCtx.screenRequest(&ctx, &params, a);
    }
    var old = try mkParams(a, "{\"mqtt_timestamp\":0}");
    try MqttCtx.screenRequest(&ctx, &old, a);
    var recent = try mkParams(a, "{\"mqtt_timestamp\":20}");
    try testing.expectError(error.DuplicateMqttRequest, MqttCtx.screenRequest(&ctx, &recent, a));
}

test "apiResponse screens string timestamps in batches after method lookup" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = MqttCtx.init(testing.allocator);
    defer ctx.deinit();
    ctx.io = testing.io;
    var dispatch: TestDispatch = .{ .mqtt = &ctx, .dispatcher = .init(testing.allocator) };
    defer dispatch.dispatcher.deinit();
    try dispatch.dispatcher.register("known", &dispatch, TestDispatch.handler);
    ctx.api_dispatch = TestDispatch.cb;
    ctx.api_dispatch_ctx = &dispatch;
    const response = (try ctx.apiResponse(
        "[" ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"unknown\",\"params\":{\"mqtt_timestamp\":\"retry\"},\"id\":1}," ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"known\",\"params\":{\"mqtt_timestamp\":\"retry\"},\"id\":2}," ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"known\",\"params\":{\"mqtt_timestamp\":\"retry\"},\"id\":3}," ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"known\",\"params\":{\"mqtt_timestamp\":null},\"id\":4}," ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"known\",\"params\":{\"mqtt_timestamp\":null},\"id\":5}" ++
            "]",
        a,
    )).?;
    const items = (try mkParams(a, response)).array.items;
    try testing.expectEqual(@as(i64, -32601), items[0].object.get("error").?.object.get("code").?.integer);
    try testing.expectEqualStrings("ok", items[1].object.get("result").?.string);
    try testing.expectEqual(@as(i64, -10000), items[2].object.get("error").?.object.get("code").?.integer);
    try testing.expectEqual(@as(usize, 3), dispatch.calls);
    try testing.expect(!dispatch.saw_timestamp);
}

test "timestampDigest preserves Python numeric and container equality" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pairs = [_]struct { lhs: []const u8, rhs: []const u8, equal: bool }{
        .{ .lhs = "true", .rhs = "1", .equal = true },
        .{ .lhs = "1", .rhs = "1.0", .equal = true },
        .{ .lhs = "false", .rhs = "-0.0", .equal = true },
        .{ .lhs = "9007199254740993", .rhs = "9007199254740992", .equal = false },
        .{ .lhs = "9007199254740993", .rhs = "9007199254740992.0", .equal = false },
        .{ .lhs = "9223372036854775808", .rhs = "9223372036854775808.0", .equal = true },
        .{ .lhs = "1e500", .rhs = "2e500", .equal = true },
        .{ .lhs = "[1,2]", .rhs = "[2,1]", .equal = false },
        .{ .lhs = "[true,2]", .rhs = "[1.0,2.0]", .equal = true },
        .{ .lhs = "{\"a\":1,\"b\":[true]}", .rhs = "{\"b\":[1],\"a\":1.0}", .equal = true },
        .{ .lhs = "{\"a\":1,\"b\":2}", .rhs = "{\"a\":2,\"b\":1}", .equal = false },
        .{ .lhs = "\"1\"", .rhs = "1", .equal = false },
    };
    for (pairs) |pair| {
        const lhs = timestampDigest(try mkParams(a, pair.lhs));
        const rhs = timestampDigest(try mkParams(a, pair.rhs));
        try testing.expectEqual(pair.equal, std.mem.eql(u8, &lhs, &rhs));
    }
    _ = timestampDigest(.{ .float = std.math.floatMax(f64) });
}

test "fuzz timestampDigest and screening retain no request-owned memory" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var bytes: [64]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const f: f64 = @bitCast(std.mem.readInt(u64, bytes[0..8], .little));
            _ = timestampDigest(.{ .float = f });
            var ctx = MqttCtx.init(testing.allocator);
            defer ctx.deinit();
            ctx.io = testing.io;
            var value: std.json.Value = undefined;
            {
                var arena = std.heap.ArenaAllocator.init(testing.allocator);
                defer arena.deinit();
                const a = arena.allocator();
                const text = try std.fmt.allocPrint(a, "{{\"mqtt_timestamp\":{d}}}", .{std.mem.readInt(i64, bytes[0..8], .little)});
                value = try mkParams(a, text);
                try MqttCtx.screenRequest(&ctx, &value, a);
                try testing.expect(!value.object.contains("mqtt_timestamp"));
                if (std.json.parseFromSliceLeaky(std.json.Value, a, bytes[8..], .{})) |parsed| {
                    const digest = timestampDigest(parsed);
                    try testing.expectEqualSlices(u8, &digest, &timestampDigest(parsed));
                } else |_| {}
            }
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            value = try mkParams(a, try std.fmt.allocPrint(a, "{{\"mqtt_timestamp\":{d}}}", .{std.mem.readInt(i64, bytes[0..8], .little)}));
            try testing.expectError(error.DuplicateMqttRequest, MqttCtx.screenRequest(&ctx, &value, a));
        }
    }.run, .{});
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
            var dispatch: u8 = 0;
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "server.mqtt.publish", "server.mqtt.subscribe", "server.mqtt.publish_mqtt_topic" }) |method| {
        const request = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{{\"topic\":\"t\"}},\"id\":1}}", .{method});
        const response = try d.handleParsedRoot(.{ .transport = .MQTT }, try mkParams(a, request), a);
        const value = try mkParams(a, response);
        try testing.expectEqual(@as(i64, -32601), value.object.get("error").?.object.get("code").?.integer);
    }
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

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = MqttCtx.init(std.heap.smp_allocator);
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

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = MqttCtx.init(std.heap.smp_allocator);
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
    var ctx = MqttCtx.init(std.heap.smp_allocator);
    defer ctx.deinit();
    try ctx.setConfig(test_options);
    ctx.config.?.port = broker.port();
    ctx.keepalive_s = 1;
    ctx.io = io;
    ctx.start();
    try waitConnected(&ctx, io);
    try testing.expect(waitFor(io, &broker.pings, 1));
}

test "live broker: missing PINGRESP ends the connection within keepalive" {
    var threaded = Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var broker = try mqtt_client.TestBroker.bind(io);
    defer broker.deinit();
    broker.reply_pings = false;
    var peer = try io.concurrent(mqtt_client.TestBroker.run, .{ &broker, @as(usize, 16) });
    defer peer.cancel(io);
    var ctx = MqttCtx.init(std.heap.smp_allocator);
    defer ctx.deinit();
    try ctx.setConfig(.{ .address = "127.0.0.1", .port = broker.port(), .instance_name = "phobos" });
    ctx.keepalive_s = 1;
    ctx.io = io;
    ctx.start();
    try waitConnected(&ctx, io);
    try testing.expect(waitFor(io, &broker.pings, 1));
    try ctx.reader_done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    try testing.expectEqual(@as(u32, 1), broker.pings.load(.acquire));
}

test "stop wakes an untimed subscription before joining workers" {
    var threaded = Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = MqttCtx.init(std.heap.smp_allocator);
    defer ctx.deinit();
    try ctx.setConfig(test_options);
    ctx.io = io;
    const Subscriber = struct {
        fn run(c: *MqttCtx) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            try testing.expectError(error.ServiceUnavailable, handleSubscribe(@ptrCast(c), try mkParams(a, "{\"topic\":\"pending\"}"), a));
        }
    };
    var subscriber = try io.concurrent(Subscriber.run, .{&ctx});
    defer if (subscriber.cancel(io)) |_| {} else |_| {};
    var waiting = false;
    for (0..400) |_| {
        ctx.waiters_mutex.lockUncancelable(io);
        waiting = ctx.waiter_count == 1;
        ctx.waiters_mutex.unlock(io);
        if (waiting) break;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try testing.expect(waiting);
    ctx.stop(io);
    try subscriber.await(io);
    try testing.expectEqual(@as(usize, 0), ctx.waiter_count);
}

test "stop bounds offline writes behind a broker that stops reading" {
    var threaded = Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var broker = try mqtt_client.TestBroker.bind(io);
    defer broker.deinit();
    var peer = try io.concurrent(mqtt_client.TestBroker.run, .{ &broker, @as(usize, 2) });
    defer peer.cancel(io);
    var ctx = MqttCtx.init(std.heap.smp_allocator);
    defer ctx.deinit();
    try ctx.setConfig(.{ .address = "127.0.0.1", .port = broker.port(), .instance_name = "phobos" });
    ctx.io = io;
    ctx.start();
    try waitConnected(&ctx, io);
    peer.await(io);
    const payload = try std.heap.smp_allocator.alloc(u8, mqtt_client.max_packet_len);
    defer std.heap.smp_allocator.free(payload);
    @memset(payload, 'p');
    var done: Io.Event = .unset;
    const Publisher = struct {
        fn run(c: *MqttCtx, bytes: []const u8, finished: *Io.Event) void {
            defer finished.set(c.io.?);
            c.publishRaw("blocked", bytes, 0, false) catch {};
        }
    };
    var publisher = try io.concurrent(Publisher.run, .{ &ctx, payload, &done });
    defer publisher.cancel(io);
    try io.sleep(.fromMilliseconds(100), .awake);
    try testing.expect(!done.isSet());
    const start = Io.Clock.Timestamp.now(io, .awake);
    ctx.stop(io);
    try testing.expect(start.untilNow(io).raw.toMilliseconds() < 2000);
    publisher.await(io);
    try testing.expect(done.isSet());
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
    var ctx = MqttCtx.init(std.heap.smp_allocator);
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
    var threaded = Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer server.deinit(io);
    var attempts: std.atomic.Value(u32) = .init(0);
    const Peer = struct {
        fn run(s: *Io.net.Server, aio: Io, counter: *std.atomic.Value(u32)) void {
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(std.heap.smp_allocator);
            for ([_]u8{ 5, 0 }) |code| {
                const stream = s.accept(aio) catch return;
                defer stream.close(aio);
                var buf: [512]u8 = undefined;
                var reader = stream.reader(aio, &buf);
                _ = mqtt_proto.readPacket(&reader.interface, std.heap.smp_allocator, &body, 512) catch return;
                var writer = stream.writer(aio, &.{});
                writer.interface.writeAll(&.{ 0x20, 0x02, 0x00, code }) catch return;
                writer.interface.flush() catch return;
                _ = counter.fetchAdd(1, .release);
                if (code == 0) {
                    while (true) _ = reader.interface.takeByte() catch break;
                }
            }
        }
    };
    var peer = try io.concurrent(Peer.run, .{ &server, io, &attempts });
    defer peer.cancel(io);
    var ctx = MqttCtx.init(std.heap.smp_allocator);
    defer ctx.deinit();
    try ctx.setConfig(.{ .address = "127.0.0.1", .port = server.socket.address.getPort(), .instance_name = "phobos" });
    ctx.io = io;
    ctx.start();
    try waitConnected(&ctx, io);
    try testing.expectEqual(@as(u32, 2), attempts.load(.acquire));
}

test "MQTT home directory owns replacement and preserves it on allocation failure" {
    var ctx = MqttCtx.init(testing.allocator);
    defer ctx.deinit();
    var home = [_]u8{ 'h', 'o', 'm', 'e' };
    try ctx.setHomeDirectory(&home);
    home[0] = 'x';
    try testing.expectEqualStrings("home", ctx.home_directory.?);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    ctx.gpa = failing.allocator();
    try testing.expectError(error.OutOfMemory, ctx.setHomeDirectory("new"));
    ctx.gpa = testing.allocator;
    try testing.expectEqualStrings("home", ctx.home_directory.?);
    try ctx.setHomeDirectory("replaced");
    try testing.expectEqualStrings("replaced", ctx.home_directory.?);
    try ctx.setHomeDirectory(null);
    try testing.expect(ctx.home_directory == null);
}

/// Parse Moonraker getdict status objects, one `object = field, field` per line.
pub fn parseStatusObjects(alloc: std.mem.Allocator, text: []const u8) !std.json.Value {
    var objects: std.json.ObjectMap = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        const separator = std.mem.indexOfScalar(u8, trimmed, '=');
        const name = std.mem.trim(u8, trimmed[0 .. separator orelse trimmed.len], &std.ascii.whitespace);
        if (name.len == 0 or name.len > connections.max_subscription_name_len) return error.InvalidStatusObjects;
        if (!objects.contains(name) and objects.count() == connections.max_subscription_objects) return error.InvalidStatusObjects;
        var fields: std.json.Array = .init(alloc);
        if (separator) |index| {
            var values = std.mem.splitScalar(u8, trimmed[index + 1 ..], ',');
            while (values.next()) |value| {
                const field = std.mem.trim(u8, value, &std.ascii.whitespace);
                if (field.len == 0) continue;
                if (fields.items.len == connections.max_subscription_objects or field.len > connections.max_subscription_name_len) return error.InvalidStatusObjects;
                try fields.append(.{ .string = try alloc.dupe(u8, field) });
            }
        }
        try objects.put(alloc, try alloc.dupe(u8, name), if (separator != null) .{ .array = fields } else .null);
    }
    return .{ .object = objects };
}

test "MQTT status config parses all fields, field lists, empty selections, and replacement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const value = try parseStatusObjects(arena.allocator(), "extruder\nheater_bed = temperature, target, \nprint_stats=\nextruder=temperature\n");
    try testing.expectEqual(@as(usize, 3), value.object.count());
    try testing.expectEqualStrings("temperature", value.object.get("extruder").?.array.items[0].string);
    try testing.expectEqual(@as(usize, 2), value.object.get("heater_bed").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), value.object.get("print_stats").?.array.items.len);
    const all = try parseStatusObjects(arena.allocator(), "extruder");
    try testing.expect(all.object.get("extruder").? == .null);
}

test "fuzz MQTT status config parsing is bounded" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var text: [256]u8 = undefined;
            smith.bytesWithHash(&text, 0);
            const value = parseStatusObjects(arena.allocator(), &text) catch return;
            try testing.expect(value.object.count() <= connections.max_subscription_objects);
        }
    }.run, .{});
}

test "MQTT status integration owns selectors and follows connected lifecycle" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = MqttCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.setConfig(.{ .address = "local", .instance_name = "p", .clock_io = io, .status_objects = try parseStatusObjects(a, "extruder=temperature"), .status_interval = 0.5 });
    const selectors = try ctx.statusSubscription(a);
    try testing.expectEqualStrings("temperature", selectors.object.get("extruder").?.array.items[0].string);
    ctx.status.?.setBrokerConnected(true);
    try ctx.klippyState(true);
    try ctx.klippyStatus(try mkParams(a, "{\"extruder\":{\"temperature\":22,\"target\":0}}"), .{ .float = 5 });
    try testing.expectEqual(@as(usize, 2), ctx.status.?.pending.len);
    try ctx.klippyState(true);
    try testing.expectEqual(@as(usize, 2), ctx.status.?.pending.len);
    try ctx.klippyState(false);
    try testing.expectEqual(@as(usize, 3), ctx.status.?.pending.len);
    try ctx.klippyState(false);
    try testing.expectEqual(@as(usize, 3), ctx.status.?.pending.len);
    try testing.expectError(error.InvalidStatus, ctx.klippyStatus(.{ .object = .empty }, .null));
    try testing.expectError(error.InvalidStatusObjects, ctx.setConfig(.{ .address = "other", .instance_name = "x", .status_objects = .null }));
    try testing.expectEqualStrings("p", ctx.config.?.instance_name);
}

test "live MQTT requests await acknowledgements and unsubscribe one-shot filters across versions" {
    const io = testing.io;
    for ([_]mqtt_proto.Protocol{ .v31, .v311, .v5 }) |protocol| {
        var broker = try mqtt_client.TestBroker.bind(io);
        defer broker.deinit();
        var peer = try io.concurrent(mqtt_client.TestBroker.run, .{ &broker, @as(usize, 64) });
        defer peer.cancel(io);
        var ctx = MqttCtx.init(std.heap.smp_allocator);
        defer ctx.deinit();
        try ctx.setConfig(.{ .address = "127.0.0.1", .port = broker.port(), .instance_name = "p", .client_id = "phobosTest", .protocol = protocol, .enable_moonraker_api = false });
        ctx.io = io;
        ctx.start();
        try waitConnected(&ctx, io);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        for ([_][]const u8{ "{\"topic\":\"out\",\"payload\":1,\"qos\":1,\"timeout\":1}", "{\"topic\":\"out\",\"payload\":2,\"qos\":2,\"timeout\":1}" }) |request| {
            const response = try handlePublish(@ptrCast(&ctx), try mkParams(a, request), a);
            try testing.expectEqualStrings("out", response.object.get("topic").?.string);
        }
        try testing.expectError(error.MqttTimeout, handleSubscribe(@ptrCast(&ctx), try mkParams(a, "{\"topic\":\"one-shot\",\"timeout\":0.01}"), a));
        try testing.expect(waitFor(io, &broker.unsubscribes, 1));
        try testing.expectEqualStrings("one-shot", broker.last_unsubscribe[0..broker.last_unsubscribe_len]);
        ctx.subscribeTopicLive("sensor", null);
        try testing.expectError(error.MqttTimeout, handleSubscribe(@ptrCast(&ctx), try mkParams(a, "{\"topic\":\"sensor\",\"timeout\":0.01}"), a));
        try testing.expectEqual(@as(u32, 1), broker.unsubscribes.load(.acquire));
    }
}

test "live MQTT publish timeout disconnects and connection hooks observe both transitions" {
    const io = testing.io;
    var broker = try mqtt_client.TestBroker.bind(io);
    defer broker.deinit();
    broker.reply_publishes = false;
    var peer = try io.concurrent(mqtt_client.TestBroker.run, .{ &broker, @as(usize, 64) });
    defer peer.cancel(io);
    const Observed = struct {
        connected: std.atomic.Value(u32) = .init(0),
        disconnected: std.atomic.Value(u32) = .init(0),
        fn connection(ctx: *anyopaque, up: bool) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = if (up) self.connected.fetchAdd(1, .release) else self.disconnected.fetchAdd(1, .release);
        }
    };
    var observed: Observed = .{};
    var ctx = MqttCtx.init(std.heap.smp_allocator);
    defer ctx.deinit();
    try ctx.setConfig(.{ .address = "127.0.0.1", .port = broker.port(), .instance_name = "p" });
    ctx.on_connection = Observed.connection;
    ctx.on_connection_ctx = &observed;
    ctx.io = io;
    ctx.start();
    try testing.expect(waitFor(io, &observed.connected, 1));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.MqttPublishTimeout, handlePublish(@ptrCast(&ctx), try mkParams(a, "{\"topic\":\"out\",\"qos\":1,\"timeout\":0.02}"), a));
    try testing.expect(waitFor(io, &observed.disconnected, 1));
    try testing.expectError(error.MqttPublishTimeout, handlePublish(@ptrCast(&ctx), try mkParams(a, "{\"topic\":\"out\",\"timeout\":0}"), a));
}

test "live MQTT shared subscribe waiters unsubscribe only after the last exits" {
    const io = testing.io;
    var broker = try mqtt_client.TestBroker.bind(io);
    defer broker.deinit();
    var peer = try io.concurrent(mqtt_client.TestBroker.run, .{ &broker, @as(usize, 64) });
    defer peer.cancel(io);
    var ctx = MqttCtx.init(std.heap.smp_allocator);
    defer ctx.deinit();
    try ctx.setConfig(.{ .address = "127.0.0.1", .port = broker.port(), .instance_name = "p", .enable_moonraker_api = false });
    ctx.io = io;
    ctx.start();
    try waitConnected(&ctx, io);
    const Subscriber = struct {
        fn run(owner: *MqttCtx) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const response = try handleSubscribe(@ptrCast(owner), try mkParams(a, "{\"topic\":\"shared\",\"timeout\":2}"), a);
            try testing.expectEqualStrings("reply", response.object.get("payload").?.string);
        }
    };
    var first = try io.concurrent(Subscriber.run, .{&ctx});
    defer first.cancel(io) catch {};
    var second = try io.concurrent(Subscriber.run, .{&ctx});
    defer second.cancel(io) catch {};
    try testing.expect(waitFor(io, &broker.subscribes, 2));
    try broker.injectPublish("shared", "reply");
    try first.await(io);
    try second.await(io);
    try testing.expect(waitFor(io, &broker.unsubscribes, 1));
    try testing.expectEqual(@as(u32, 1), broker.unsubscribes.load(.acquire));
}

test "live MQTT lifecycle publishes selected Klippy snapshots through the joined worker" {
    const io = testing.io;
    for ([_]bool{ false, true }) |split| {
        var broker = try mqtt_client.TestBroker.bind(io);
        defer broker.deinit();
        var peer = try io.concurrent(mqtt_client.TestBroker.run, .{ &broker, @as(usize, 64) });
        defer peer.cancel(io);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var ctx = MqttCtx.init(std.heap.smp_allocator);
        defer ctx.deinit();
        try ctx.setConfig(.{ .address = "127.0.0.1", .port = broker.port(), .instance_name = "p", .clock_io = io, .status_objects = try parseStatusObjects(a, "extruder=temperature"), .publish_split_status = split, .default_qos = 1 });
        ctx.io = io;
        ctx.start();
        try waitConnected(&ctx, io);
        var connected = false;
        for (0..400) |_| {
            ctx.status.?.mutex.lockUncancelable(io);
            connected = ctx.status.?.broker_connected;
            ctx.status.?.mutex.unlock(io);
            if (connected) break;
            try io.sleep(.fromMilliseconds(5), .awake);
        }
        try testing.expect(connected);
        try ctx.klippyState(true);
        try ctx.klippyStatus(try mkParams(a, "{\"extruder\":{\"temperature\":22,\"target\":0}}"), .{ .float = 5.25 });
        try testing.expect(waitFor(io, &broker.publishes, 2));
        const payload = try mkParams(a, broker.got_payload[0..broker.got_payload_len]);
        try testing.expectEqual(@as(f64, 5.25), payload.object.get("eventtime").?.float);
        if (split) {
            try testing.expectEqualStrings("p/klipper/state/extruder/temperature", broker.got_topic[0..broker.got_topic_len]);
            try testing.expect(broker.got_retain);
            try testing.expectEqual(@as(i64, 22), payload.object.get("value").?.integer);
        } else {
            try testing.expectEqualStrings("p/klipper/status", broker.got_topic[0..broker.got_topic_len]);
            try testing.expect(!broker.got_retain);
            const fields = payload.object.get("status").?.object.get("extruder").?.object;
            try testing.expectEqual(@as(i64, 22), fields.get("temperature").?.integer);
            try testing.expect(fields.get("target") == null);
        }
    }
}

test "live MQTT graceful shutdown acknowledges retained offline status at QoS2" {
    const io = testing.io;
    var broker = try mqtt_client.TestBroker.bind(io);
    defer broker.deinit();
    var peer = try io.concurrent(mqtt_client.TestBroker.run, .{ &broker, @as(usize, 64) });
    defer peer.cancel(io);
    var ctx = MqttCtx.init(std.heap.smp_allocator);
    try ctx.setConfig(.{ .address = "127.0.0.1", .port = broker.port(), .instance_name = "p", .default_qos = 2 });
    ctx.io = io;
    ctx.start();
    errdefer ctx.deinit();
    try waitConnected(&ctx, io);
    ctx.deinit();
    try testing.expect(waitFor(io, &broker.publishes, 2));
    try testing.expectEqualStrings("p/moonraker/status", broker.got_topic[0..broker.got_topic_len]);
    try testing.expectEqualStrings(offline_payload, broker.got_payload[0..broker.got_payload_len]);
    try testing.expect(broker.got_retain);
}

test "live MQTT reconnect drains subscription acknowledgements beyond the packet window" {
    const io = testing.io;
    var broker = try mqtt_client.TestBroker.bind(io);
    defer broker.deinit();
    const filter_count = 65;
    var first_peer = try io.concurrent(mqtt_client.TestBroker.run, .{ &broker, @as(usize, filter_count + 1) });
    defer first_peer.cancel(io);
    const Observed = struct {
        connected: std.atomic.Value(u32) = .init(0),
        fn connection(ctx: *anyopaque, up: bool) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (up) _ = self.connected.fetchAdd(1, .release);
        }
    };
    var observed: Observed = .{};
    var ctx = MqttCtx.init(std.heap.smp_allocator);
    defer ctx.deinit();
    try ctx.setConfig(.{ .address = "127.0.0.1", .port = broker.port(), .instance_name = "p", .enable_moonraker_api = false });
    ctx.io = io;
    ctx.on_connection = Observed.connection;
    ctx.on_connection_ctx = &observed;
    for (0..filter_count) |index| {
        var name: [32]u8 = undefined;
        ctx.subscribeTopicLive(try std.fmt.bufPrint(&name, "sensor/{d}", .{index}), null);
    }
    ctx.start();
    try testing.expect(waitFor(io, &observed.connected, 1));
    first_peer.await(io);
    try testing.expectEqual(@as(u32, filter_count), broker.subscribes.load(.acquire));
    const stream = broker.stream.?;
    stream.shutdown(io, .both) catch {};
    stream.close(io);
    broker.stream = null;
    var second_peer = try io.concurrent(mqtt_client.TestBroker.run, .{ &broker, @as(usize, 256) });
    defer second_peer.cancel(io);
    try testing.expect(waitFor(io, &observed.connected, 2));
    // The connection hook follows queued writes, not broker receipt.
    try testing.expect(waitFor(io, &broker.subscribes, filter_count * 2));
    try testing.expectEqual(@as(u32, filter_count * 2), broker.subscribes.load(.acquire));
}

test "live MQTT cancelled subscribe removes its filter or closes the clean session" {
    const io = testing.io;
    var broker = try mqtt_client.TestBroker.bind(io);
    defer broker.deinit();
    var peer = try io.concurrent(mqtt_client.TestBroker.run, .{ &broker, @as(usize, 64) });
    defer peer.cancel(io);
    var ctx = MqttCtx.init(std.heap.smp_allocator);
    defer ctx.deinit();
    try ctx.setConfig(.{ .address = "127.0.0.1", .port = broker.port(), .instance_name = "p", .enable_moonraker_api = false });
    ctx.io = io;
    ctx.start();
    try waitConnected(&ctx, io);
    const Subscriber = struct {
        fn run(owner: *MqttCtx) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            _ = try handleSubscribe(@ptrCast(owner), try mkParams(a, "{\"topic\":\"cancelled\"}"), a);
        }
    };
    var subscriber = try io.concurrent(Subscriber.run, .{&ctx});
    defer subscriber.cancel(io) catch {};
    try testing.expect(waitFor(io, &broker.subscribes, 1));
    try testing.expectError(error.ServiceUnavailable, subscriber.cancel(io));
    var cleaned = false;
    for (0..400) |_| {
        cleaned = broker.unsubscribes.load(.acquire) != 0 or ctx.reader_done.isSet();
        if (cleaned) break;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try testing.expect(cleaned);
    try testing.expectEqual(@as(usize, 0), ctx.waiter_count);
}
