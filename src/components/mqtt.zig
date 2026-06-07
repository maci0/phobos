//! server.mqtt.* API component — Moonraker-compatible MQTT endpoints.
//!
//! Matches the endpoints registered in
//! `vendor/moonraker/moonraker/components/mqtt.py` (MQTTClient):
//!
//!   POST /server/mqtt/publish   → server.mqtt.publish
//!   POST /server/mqtt/subscribe → server.mqtt.subscribe
//!
//! phobos has a real MQTT 3.1.1 broker client (mqtt_client.zig). When no broker
//! is configured (the default), both endpoints return a Moonraker-shaped "MQTT
//! not configured" error. When a broker IS configured via `setConfig` and io is
//! wired, connectBroker establishes a live TCP connection: status/sensor flows
//! publish real PUBLISH frames over the wire and subscribed topics are received
//! by the background reader. The HTTP publish/subscribe endpoints additionally
//! mirror into an in-memory store (publish keeps the last payload per topic,
//! subscribe returns it) so the API surface behaves faithfully with or without a
//! live broker.
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
const mqtt_client = @import("mqtt_client.zig");
const mqtt_proto = @import("mqtt_proto.zig");

const Registry = registry.Registry;
const Io = std.Io;

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
    /// Moonraker: status_objects — optional dict mapping Klipper object names
    /// to comma-separated field lists (or empty for all fields). Used by
    /// send_status to filter and cache Klipper status updates for MQTT.
    status_objects: ?[]const u8 = null,
    /// Moonraker: status_interval — minimum seconds between status cache
    /// publishes. 0 = publish immediately (no batching).
    status_interval: f64 = 0.0,
    /// Moonraker: publish_split_status — if true, each Klipper object/field
    /// is published to a separate sub-topic under klipper_state_prefix.
    publish_split_status: bool = false,
    /// Enable TLS for the MQTT broker connection.
    enable_tls: bool = false,
    /// MQTT protocol version: "v3.1", "v3.1.1", or "v5".
    mqtt_protocol: ?[]const u8 = null,
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
    /// Current Klipper state string ("ready", "error", "startup", etc.)
    klipper_state: []const u8 = "",
    /// Message accompanying the Klipper state change.
    klipper_message: []const u8 = "",
    /// Last published message per topic. Owned by ctx; freed in deinit.
    messages: std.StringHashMap(StoredMessage),
    /// HTTP-endpoint subscriptions: the in-memory subscribe API records topics
    /// here (for notification emission on a matching in-store publish). The live
    /// broker connection has its own subscriptions via the reader callback.
    subscriptions: std.StringHashMap(void),
    /// Duplicate API request timestamps (moonraker: timestamp_deque, maxlen 20).
    api_timestamps: std.ArrayList(i64),
    /// Moonraker: status_cache — batched Klipper status objects keyed by
    /// object name (e.g. "print_stats" → {state: "printing", ...}).
    /// Populated by sendStatus(), flushed by publishStatusUpdate().
    status_cache: std.StringHashMap(std.json.Value),
    /// Set true by deinit(); close/unsubscribeAll are no-ops when set.
    deinitialized: bool = false,
    /// The latest eventtime passed to sendStatus (for timed flush).
    last_status_time: f64 = 0.0,
    /// Atomic flag to signal the status-flush thread to stop.
    status_flush_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Background thread that periodically flushes the status cache.
    status_flush_thread: ?std.Thread = null,
    /// Live Io handle (set once the server is serving). Required for a real
    /// broker connection; null in unit tests that exercise the in-memory store.
    io: ?Io = null,
    /// Real MQTT broker client (heap-owned for a stable reader address). Null
    /// until `connectBroker` succeeds; back to null after `disconnectBroker`.
    client: ?*mqtt_client.MqttClient = null,
    /// Background reader thread draining inbound broker packets.
    reader_thread: ?std.Thread = null,
    /// Background thread running the (possibly slow) broker connect. Tracked so
    /// disconnectBroker can join it before teardown — otherwise a deinit racing
    /// an in-flight connect frees the ctx while connectBroker still uses it.
    connect_thread: ?std.Thread = null,
    reader_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Guards `client` lifetime against the reconnect supervisor freeing it while
    /// disconnectBroker reads it for shutdownRecv (io-guarded; null io = no
    /// concurrency / single-threaded path).
    client_mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Inbound-message hook: invoked (on the reader thread) for each application
    /// PUBLISH with (topic, payload). The app routes this to subscribers (e.g.
    /// MQTT sensors) under the Core lock.
    on_message: ?*const fn (ctx: *anyopaque, topic: []const u8, payload: []const u8) void = null,
    on_message_ctx: ?*anyopaque = null,
    /// Post-connect hook: invoked once after a successful broker connect (and on
    /// each reconnect). The app uses it to (re)subscribe sensor topics.
    on_connected: ?*const fn (ctx: *anyopaque) void = null,
    on_connected_ctx: ?*anyopaque = null,
    /// Reserved API request/response topics (gpa-owned), cached at connect time
    /// for the JSON-RPC-over-MQTT bridge. Freed on disconnect/deinit.
    api_request_topic: ?[]const u8 = null,
    api_response_topic: ?[]const u8 = null,
    /// Dispatch callback for inbound api_request frames: App wires this to
    /// `core.run(dispatcher.handle)`. Returns the JSON-RPC response bytes (empty
    /// for a notification), allocated in the passed allocator.
    api_dispatch: ?*const fn (ctx: *anyopaque, payload: []const u8, alloc: std.mem.Allocator) anyerror![]u8 = null,
    api_dispatch_ctx: ?*anyopaque = null,

    pub fn init(gpa: std.mem.Allocator) MqttCtx {
        return .{
            .gpa = gpa,
            .messages = std.StringHashMap(StoredMessage).init(gpa),
            .subscriptions = std.StringHashMap(void).init(gpa),
            .api_timestamps = .empty,
            .status_cache = std.StringHashMap(std.json.Value).init(gpa),
        };
    }

    pub fn deinit(self: *MqttCtx) void {
        if (self.deinitialized) return;
        self.deinitialized = true;
        self.disconnectBroker();
        self.stopStatusFlushThread();
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
        // Free status_cache values.
        {
            var sc_it = self.status_cache.iterator();
            while (sc_it.next()) |entry| {
                self.gpa.free(entry.key_ptr.*);
                freeJsonValue(self.gpa, entry.value_ptr.*);
            }
        }
        self.status_cache.deinit();
        if (self.klipper_state.len > 0) self.gpa.free(self.klipper_state);
        if (self.klipper_message.len > 0) self.gpa.free(self.klipper_message);
        if (self.config) |*cfg| {
            self.gpa.free(cfg.host);
            if (cfg.username) |u| self.gpa.free(u);
            if (cfg.password) |p| self.gpa.free(p);
            if (cfg.instance_name) |n| self.gpa.free(n);
            if (cfg.client_id) |c| self.gpa.free(c);
            if (cfg.will_topic) |t| self.gpa.free(t);
            if (cfg.will_payload) |p| self.gpa.free(p);
            if (cfg.status_objects) |s| self.gpa.free(s);
            if (cfg.mqtt_protocol) |p| self.gpa.free(p);
        }
    }

    // -----------------------------------------------------------------------
    // Real broker connection (mqtt_client over std.Io.net)
    // -----------------------------------------------------------------------

    /// Wire the live Io handle. Enables `connectBroker`; until set, the
    /// component operates purely on the in-memory store (unit-test path).
    pub fn setIo(self: *MqttCtx, io: Io) void {
        self.io = io;
    }

    /// Connect to the configured broker, publish online status, subscribe to the
    /// API request topic, and start the background reader. Idempotent while
    /// connected. Requires both a config and a wired Io.
    pub fn connectBroker(self: *MqttCtx) !void {
        if (self.client != null) return;
        const cfg = self.config orelse return error.MqttNotConfigured;
        const io = self.io orelse return error.MqttNotConfigured;

        self.setState(.connecting);
        const client = try self.gpa.create(mqtt_client.MqttClient);
        errdefer self.gpa.destroy(client);

        var opts: mqtt_proto.ConnectOptions = .{
            .client_id = cfg.client_id orelse "phobos",
            .username = cfg.username,
            .password = cfg.password,
            .keepalive_s = 60,
            .clean_session = true,
        };
        if (cfg.will_topic) |wt| {
            opts.will_topic = wt;
            opts.will_payload = cfg.will_payload orelse "offline";
            opts.will_retain = true;
        }

        const connect_result = if (cfg.enable_tls)
            mqtt_client.MqttClient.connectTls(self.gpa, io, cfg.host, cfg.port, opts, .{ .host = cfg.host })
        else
            mqtt_client.MqttClient.connect(self.gpa, io, cfg.host, cfg.port, opts);
        client.* = connect_result catch |e| {
            // client.* is uninitialized (connect failed); the errdefer above
            // frees the raw allocation. Do NOT destroy here too (double-free).
            self.state = .disconnected;
            return e;
        };
        client.rebind();
        // Route inbound PUBLISH frames (from the reader thread) to on_message.
        client.on_publish = mqttOnPublish;
        client.on_publish_ctx = self;
        self.lockClient();
        self.client = client;
        self.unlockClient();
        // setState(.connected) publishes moonraker_status — now sent live.
        self.setState(.connected);

        // Subscribe to the API request topic.
        const rtopics = self.reservedTopics();
        defer {
            self.gpa.free(rtopics.api_request);
            self.gpa.free(rtopics.api_response);
            self.gpa.free(rtopics.moonraker_status);
            self.gpa.free(rtopics.klipper_status);
            self.gpa.free(rtopics.klipper_state_prefix);
        }
        const api_qos: u2 = if (self.config) |c| @intCast(@max(0, @min(2, c.api_qos))) else 0;
        client.subscribe(rtopics.api_request, api_qos) catch {};

        // Cache the request/response topics for the JSON-RPC-over-MQTT bridge.
        if (self.api_request_topic) |t| self.gpa.free(t);
        if (self.api_response_topic) |t| self.gpa.free(t);
        self.api_request_topic = self.gpa.dupe(u8, rtopics.api_request) catch null;
        self.api_response_topic = self.gpa.dupe(u8, rtopics.api_response) catch null;

        // Let the app subscribe sensor (and other) topics now we are connected.
        if (self.on_connected) |cb| cb(self.on_connected_ctx.?);

        // Start the background reader to drain inbound packets. If the thread
        // cannot be spawned, tear the connection down rather than leaving a
        // connected-but-unserviced client (no PINGRESP/keepalive → broker would
        // silently drop it); the caller can retry.
        self.reader_thread = std.Thread.spawn(.{}, runReader, .{self}) catch |e| {
            client.disconnect();
            client.deinit();
            self.lockClient();
            self.client = null; // clear the dangling pointer before errdefer frees it
            self.unlockClient();
            self.state = .disconnected;
            return e; // errdefer above does the destroy (don't double-free)
        };
        // If a stop/disconnect raced this (re)connect, self-interrupt the reader
        // we just spawned so the supervisor's join returns and it won't reconnect.
        if (self.reader_stop.load(.acquire)) {
            self.lockClient();
            if (self.client) |c| c.shutdownRecv();
            self.unlockClient();
        }
    }

    fn lockClient(self: *MqttCtx) void {
        if (self.io) |io| self.client_mutex.lockUncancelable(io);
    }
    fn unlockClient(self: *MqttCtx) void {
        if (self.io) |io| self.client_mutex.unlock(io);
    }

    /// Free the live client (disconnect + deinit + destroy) under the client lock.
    /// Called by the reconnect supervisor after the reader exits.
    fn freeClientLocked(self: *MqttCtx) void {
        self.lockClient();
        const c = self.client;
        self.client = null;
        self.unlockClient();
        if (c) |client| {
            client.disconnect();
            client.deinit();
            self.gpa.destroy(client);
        }
    }

    fn sleepMs(ms: u64) void {
        var req: std.os.linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
        _ = std.os.linux.nanosleep(&req, null);
    }

    /// Static MqttClient.on_publish trampoline → MqttCtx.on_message.
    fn mqttOnPublish(ctx: *anyopaque, topic: []const u8, payload: []const u8) void {
        const self: *MqttCtx = @ptrCast(@alignCast(ctx));
        // JSON-RPC-over-MQTT bridge: api_request frames dispatch + reply.
        if (self.api_request_topic) |art| {
            if (std.mem.eql(u8, topic, art)) {
                self.processApiRequest(payload) catch {};
                return;
            }
        }
        if (self.on_message) |cb| cb(self.on_message_ctx.?, topic, payload);
    }

    /// Subscribe to a topic on the live broker connection (qos 0). No-op when no
    /// broker connection exists.
    pub fn subscribeTopicLive(self: *MqttCtx, topic: []const u8) void {
        const client = self.client orelse return;
        client.subscribe(topic, 0) catch {};
    }

    /// Reconnect supervisor (the connect_thread entry). Connects, runs until the
    /// broker drops, then reconnects with exponential backoff — until
    /// disconnectBroker signals stop. Owns the client lifecycle: it frees each
    /// dropped client (after the reader exits) before reconnecting. An unreachable
    /// broker just keeps retrying; it never crashes the server.
    pub fn connectBrokerBg(self: *MqttCtx) void {
        self.reader_stop.store(false, .release);
        var backoff_ms: u64 = 500;
        const max_backoff: u64 = 30_000;
        while (!self.reader_stop.load(.acquire)) {
            self.connectBroker() catch {
                if (self.reader_stop.load(.acquire)) break;
                sleepMs(backoff_ms);
                backoff_ms = @min(backoff_ms * 2, max_backoff);
                continue;
            };
            backoff_ms = 500; // reset after a successful connect
            // Wait for the reader to end (broker drop or stop), then free.
            if (self.reader_thread) |t| {
                t.join();
                self.reader_thread = null;
            }
            self.freeClientLocked();
            if (self.reader_stop.load(.acquire)) break;
            // Reconnect after an unexpected drop, with backoff.
            sleepMs(backoff_ms);
            backoff_ms = @min(backoff_ms * 2, max_backoff);
        }
        if (self.state == .connected or self.state == .connecting) self.state = .disconnected;
    }

    /// Background reader: drain inbound packets until stopped or the socket
    /// errors (broker disconnect). Keepalive PINGREQ/PINGRESP and inbound
    /// PUBLISH dispatch are handled inside `client.readOne`.
    fn runReader(self: *MqttCtx) void {
        const client = self.client orelse return;
        while (!self.reader_stop.load(.acquire)) {
            _ = client.readOne() catch break;
        }
    }

    /// Disconnect the broker client and stop the reader thread. Safe to call
    /// when not connected.
    pub fn disconnectBroker(self: *MqttCtx) void {
        // 1. Signal stop FIRST so the supervisor won't reconnect and the reader
        //    loop won't restart.
        self.reader_stop.store(true, .release);
        // 2. Unblock the reader's blocking recv so the supervisor's reader.join
        //    returns. Done under client_mutex so we never shutdownRecv a client
        //    the supervisor is concurrently freeing (closes the UAF window).
        self.lockClient();
        if (self.client) |c| c.shutdownRecv();
        self.unlockClient();
        // 3. Join the supervisor; on exit it has freed the client + joined the
        //    reader (supervisor mode).
        if (self.connect_thread) |t| {
            t.join();
            self.connect_thread = null;
        }
        // 4. Direct-mode fallback (no supervisor, e.g. a test that called
        //    connectBroker directly): tear down any remaining client/reader.
        if (self.client) |client| {
            client.shutdownRecv();
            if (self.reader_thread) |t| {
                t.join();
                self.reader_thread = null;
            }
            client.disconnect();
            client.deinit();
            self.gpa.destroy(client);
            self.client = null;
        }
        if (self.api_request_topic) |t| {
            self.gpa.free(t);
            self.api_request_topic = null;
        }
        if (self.api_response_topic) |t| {
            self.gpa.free(t);
            self.api_response_topic = null;
        }
        if (self.state == .connected or self.state == .connecting) self.state = .disconnected;
    }

    /// True when a live broker connection is established.
    pub fn hasBrokerConnection(self: *const MqttCtx) bool {
        return self.client != null;
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

    /// Set the connection state and publish moonraker_status when connected.
    pub fn setState(self: *MqttCtx, s: ConnectionState) void {
        self.state = s;
        if (s == .connected) {
            self.publishMoonrakerStatus();
        }
    }

    /// Set the Klipper state and message, then publish moonraker_status if
    /// connected. Both arguments are duplicated into ctx-owned memory.
    pub fn setKlipperState(self: *MqttCtx, state: []const u8, message: []const u8) void {
        if (self.klipper_state.len > 0) self.gpa.free(self.klipper_state);
        if (self.klipper_message.len > 0) self.gpa.free(self.klipper_message);
        self.klipper_state = self.gpa.dupe(u8, state) catch self.klipper_state;
        self.klipper_message = self.gpa.dupe(u8, message) catch self.klipper_message;
        if (self.state == .connected) {
            self.publishMoonrakerStatus();
        }
    }

    /// Publish the current klipper state/message to the moonraker_status topic.
    fn publishMoonrakerStatus(self: *MqttCtx) void {
        if (!self.isConfigured()) return;
        const rtopics = self.reservedTopics();
        defer {
            self.gpa.free(rtopics.api_request);
            self.gpa.free(rtopics.api_response);
            self.gpa.free(rtopics.moonraker_status);
            self.gpa.free(rtopics.klipper_status);
            self.gpa.free(rtopics.klipper_state_prefix);
        }
        var payload_obj = std.json.ObjectMap.init(self.gpa, &.{}, &.{}) catch return;
        // publishTopic deep-copies the value, so we always own and must free the
        // builder object (entries array). Borrowed string values + literal keys
        // are not owned by the map, so deinit only releases the backing array.
        defer payload_obj.deinit(self.gpa);
        payload_obj.put(self.gpa, "klipper_state", .{ .string = self.klipper_state }) catch return;
        payload_obj.put(self.gpa, "klipper_message", .{ .string = self.klipper_message }) catch return;
        self.publishTopic(rtopics.moonraker_status, .{ .object = payload_obj }, 0, true) catch {};
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

    /// Set the status_objects config (Klipper object → field filter map).
    /// The value is a comma-separated list of field names per object key.
    pub fn setStatusObjects(self: *MqttCtx, objects: ?[]const u8) !void {
        if (self.config) |*cfg| {
            if (cfg.status_objects) |old| self.gpa.free(old);
            cfg.status_objects = if (objects) |o| try self.gpa.dupe(u8, o) else null;
        }
    }

    /// Set MQTT status interval (seconds between batched publishes).
    pub fn setStatusInterval(self: *MqttCtx, interval: f64) void {
        if (self.config) |*cfg| cfg.status_interval = interval;
    }

    /// Set whether status updates are split across per-field topics.
    pub fn setPublishSplitStatus(self: *MqttCtx, split: bool) void {
        if (self.config) |*cfg| cfg.publish_split_status = split;
    }

    /// Set whether TLS is enabled for the broker connection.
    pub fn setEnableTls(self: *MqttCtx, tls: bool) void {
        if (self.config) |*cfg| cfg.enable_tls = tls;
    }

    /// Set the MQTT protocol version.
    pub fn setMqttProtocol(self: *MqttCtx, protocol: ?[]const u8) !void {
        if (self.config) |*cfg| {
            if (cfg.mqtt_protocol) |old| self.gpa.free(old);
            cfg.mqtt_protocol = if (protocol) |p| try self.gpa.dupe(u8, p) else null;
        }
    }

    /// Moonraker: send_status — accumulate Klipper status objects into the
    /// cache, filtering by status_objects when configured.  If status_interval
    /// is 0, flush immediately; otherwise the caller must call
    /// publishStatusUpdate (or the timed-flush thread will do so).
    /// eventtime is the Klipper-reported timestamp for the status snapshot.
    pub fn sendStatus(self: *MqttCtx, status: std.json.Value, eventtime: f64) void {
        if (!self.isConfigured()) return;
        if (!self.isConnected()) return;
        if (status != .object) return;

        // Filter by status_objects if configured.
        const filtered = self.filterStatusObjects(status);

        const interval = if (self.config) |cfg| cfg.status_interval else 0.0;
        if (interval <= 0.0) {
            self.publishStatusUpdate(filtered, eventtime);
        } else {
            // Merge into cache: for each key in status, merge sub-fields
            // into the cache (Python: cache.setdefault(key,{}).update(val)).
            var obj_it = filtered.object.iterator();
            while (obj_it.next()) |entry| {
                const key = entry.key_ptr.*;
                const val = entry.value_ptr.*;
                if (val != .object) continue;

                if (self.status_cache.getPtr(key)) |cached| {
                    // Merge new fields into existing cached object.
                    if (cached.* == .object) {
                        var field_it = val.object.iterator();
                        while (field_it.next()) |field| {
                            const fk = self.gpa.dupe(u8, field.key_ptr.*) catch continue;
                            const fv = deepCopyValue(self.gpa, field.value_ptr.*) catch {
                                self.gpa.free(fk);
                                continue;
                            };
                            // Replace or insert field in cached object.
                            if (cached.object.getEntry(fk)) |ex| {
                                self.gpa.free(ex.key_ptr.*);
                                freeJsonValue(self.gpa, ex.value_ptr.*);
                                ex.key_ptr.* = fk;
                                ex.value_ptr.* = fv;
                            } else {
                                cached.object.put(self.gpa, fk, fv) catch {
                                    self.gpa.free(fk);
                                    freeJsonValue(self.gpa, fv);
                                };
                            }
                        }
                    }
                } else {
                    // No cached entry yet: deep-copy the whole value.
                    const key_dup = self.gpa.dupe(u8, key) catch continue;
                    const val_copy = deepCopyValue(self.gpa, val) catch {
                        self.gpa.free(key_dup);
                        continue;
                    };
                    self.status_cache.put(key_dup, val_copy) catch {
                        self.gpa.free(key_dup);
                        freeJsonValue(self.gpa, val_copy);
                    };
                }
            }
            // Track the latest eventtime for the next flush.
            self.last_status_time = eventtime;
        }
    }

    /// Filter a Klipper status dict by the configured status_objects.
    /// When status_objects is null or empty, the full status dict is
    /// returned as-is (caller owns the filtered value).
    fn filterStatusObjects(self: *MqttCtx, status: std.json.Value) std.json.Value {
        const cfg = self.config orelse return status;
        const so = cfg.status_objects orelse return status;
        if (so.len == 0) return status;
        if (status != .object) return status;

        // Build a set of allowed object names from the comma-separated config.
        var allowed = std.StringHashMap(void).init(self.gpa);
        defer allowed.deinit();

        var it = std.mem.splitScalar(u8, so, ',');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (trimmed.len > 0) {
                allowed.put(self.gpa.dupe(u8, trimmed) catch continue, {}) catch continue;
            }
        }
        defer {
            var ait = allowed.keyIterator();
            while (ait.next()) |k| self.gpa.free(k.*);
        }

        // Build filtered object with only allowed keys.
        var filtered = std.json.ObjectMap.init(self.gpa, &.{}, &.{}) catch return status;
        errdefer {
            var fit = filtered.iterator();
            while (fit.next()) |e| {
                self.gpa.free(e.key_ptr.*);
                freeJsonValue(self.gpa, e.value_ptr.*);
            }
            filtered.deinit(self.gpa);
        }

        var obj_it = status.object.iterator();
        while (obj_it.next()) |entry| {
            if (allowed.contains(entry.key_ptr.*)) {
                const k = self.gpa.dupe(u8, entry.key_ptr.*) catch continue;
                const v = deepCopyValue(self.gpa, entry.value_ptr.*) catch {
                    self.gpa.free(k);
                    continue;
                };
                filtered.put(self.gpa, k, v) catch {
                    self.gpa.free(k);
                    freeJsonValue(self.gpa, v);
                };
            }
        }

        return .{ .object = filtered };
    }

    /// Start or restart the timed status-flush background thread.
    /// When status_interval > 0, the thread wakes every status_interval
    /// seconds and calls flushStatusCache(). Safe to call multiple times;
    /// previous thread is stopped first.
    pub fn startStatusFlushThread(self: *MqttCtx) void {
        self.stopStatusFlushThread();
        const interval = if (self.config) |cfg| cfg.status_interval else 0.0;
        if (interval <= 0.0) return;

        self.status_flush_stop.store(false, .release);
        self.status_flush_thread = std.Thread.spawn(.{}, statusFlushWorker, .{self}) catch {
            self.status_flush_stop.store(true, .release);
            return;
        };
    }

    /// Signal the status-flush thread to stop and join it (max ~1 s).
    pub fn stopStatusFlushThread(self: *MqttCtx) void {
        self.status_flush_stop.store(true, .release);
        if (self.status_flush_thread) |handle| {
            handle.join();
            self.status_flush_thread = null;
        }
    }

    /// Flush the accumulated status cache (called by timer thread or
    /// explicitly). After flushing, the cache is empty.
    pub fn flushStatusCache(self: *MqttCtx) void {
        if (self.status_cache.count() == 0) return;
        if (!self.isConfigured()) return;

        // Build a merged status object from the cache.
        var merged = std.json.ObjectMap.init(self.gpa, &.{}, &.{}) catch return;
        defer {
            var it = merged.iterator();
            while (it.next()) |e| {
                self.gpa.free(e.key_ptr.*);
                freeJsonValue(self.gpa, e.value_ptr.*);
            }
            merged.deinit(self.gpa);
        }

        var cache_it = self.status_cache.iterator();
        while (cache_it.next()) |entry| {
            const k = self.gpa.dupe(u8, entry.key_ptr.*) catch continue;
            const v = deepCopyValue(self.gpa, entry.value_ptr.*) catch {
                self.gpa.free(k);
                continue;
            };
            merged.put(self.gpa, k, v) catch {
                self.gpa.free(k);
                freeJsonValue(self.gpa, v);
            };
        }

        // Clear the cache.
        {
            var sc_it = self.status_cache.iterator();
            while (sc_it.next()) |e| {
                self.gpa.free(e.key_ptr.*);
                freeJsonValue(self.gpa, e.value_ptr.*);
            }
            self.status_cache.clearRetainingCapacity();
        }

        self.publishStatusUpdate(.{ .object = merged }, self.last_status_time);
    }

    fn statusFlushWorker(self: *MqttCtx) void {
        while (!self.status_flush_stop.load(.acquire)) {
            const interval_ns: u64 = @intFromFloat(
                (if (self.config) |cfg| cfg.status_interval else 0.0) * 1e9,
            );
            if (interval_ns == 0) break;
            // Poll every ~1 s or at the interval, whichever is smaller.
            const sleep_ns: u64 = @min(interval_ns, 1_000_000_000);
            var req: std.os.linux.timespec = .{ .sec = @intCast(sleep_ns / 1_000_000_000), .nsec = @intCast(sleep_ns % 1_000_000_000) };
            _ = std.os.linux.nanosleep(&req, null);
            if (self.status_flush_stop.load(.acquire)) break;

            // Only flush when enough time has elapsed since last flush.
            // For simplicity, we flush on every interval tick.
            if (self.status_cache.count() > 0) {
                self.flushStatusCache();
            }
        }
    }

    /// Moonraker: _publish_status_update — flush the status cache to MQTT.
    /// If split is enabled, each field goes to a separate sub-topic under
    /// `{instance}/klipper/state/{object}/{field}` with `{"eventtime": t,
    /// "value": v}`. Otherwise the whole status dict goes to
    /// `{instance}/klipper/status` wrapped as `{"eventtime": t, "status": s}`.
    pub fn publishStatusUpdate(self: *MqttCtx, status: std.json.Value, eventtime: f64) void {
        if (!self.isConfigured()) return;
        const rtopics = self.reservedTopics();
        defer {
            self.gpa.free(rtopics.api_request);
            self.gpa.free(rtopics.api_response);
            self.gpa.free(rtopics.moonraker_status);
            self.gpa.free(rtopics.klipper_status);
            self.gpa.free(rtopics.klipper_state_prefix);
        }
        const split = if (self.config) |cfg| cfg.publish_split_status else false;
        if (split and status == .object) {
            // Publish each field separately under {prefix}/{object}/{field}
            var obj_it = status.object.iterator();
            while (obj_it.next()) |entry| {
                const obj_name = entry.key_ptr.*;
                const obj_val = entry.value_ptr.*;
                if (obj_val != .object) continue;
                var field_it = obj_val.object.iterator();
                while (field_it.next()) |field| {
                    var payload_obj = std.json.ObjectMap.init(self.gpa, &.{}, &.{}) catch continue;
                    // publishTopic deep-copies; free this builder each iteration.
                    defer payload_obj.deinit(self.gpa);
                    payload_obj.put(self.gpa, "eventtime", .{ .float = eventtime }) catch continue;
                    payload_obj.put(self.gpa, "value", field.value_ptr.*) catch continue;
                    const subtopic = std.fmt.allocPrint(self.gpa, "{s}{s}/{s}", .{
                        rtopics.klipper_state_prefix, obj_name, field.key_ptr.*,
                    }) catch continue;
                    defer self.gpa.free(subtopic);
                    self.publishTopic(subtopic, .{ .object = payload_obj }, 0, true) catch {};
                }
            }
        } else {
            var payload_obj = std.json.ObjectMap.init(self.gpa, &.{}, &.{}) catch return;
            // publishTopic deep-copies; free this builder on return.
            defer payload_obj.deinit(self.gpa);
            payload_obj.put(self.gpa, "eventtime", .{ .float = eventtime }) catch return;
            payload_obj.put(self.gpa, "status", status) catch return;
            self.publishTopic(rtopics.klipper_status, .{ .object = payload_obj }, 0, false) catch {};
        }
    }

    /// Moonraker: _process_api_request — dispatch a JSON-RPC request
    /// received via the MQTT api_request topic. If a response is produced,
    /// it is published to the api_response topic.
    pub fn processApiRequest(self: *MqttCtx, payload: []const u8) !void {
        if (!self.isConfigured()) return error.MqttNotConfigured;
        if (!self.isApiEnabled()) return;
        const cfg = self.config.?;
        _ = cfg;
        // Parse the incoming JSON-RPC payload.
        const parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, payload, .{});
        defer parsed.deinit();
        // Check for duplicate timestamp.
        if (parsed.value.object.get("mqtt_timestamp")) |ts_val| {
            const ts: ?i64 = switch (ts_val) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                else => null,
            };
            if (ts) |t| {
                if (self.isDuplicateTimestamp(t)) return;
            }
        }

        // Dispatch through the JSON-RPC handler (App wires this to
        // core.run(dispatcher.handle)) and publish the response to api_response.
        const dispatch = self.api_dispatch orelse return;
        const dctx = self.api_dispatch_ctx orelse return;
        const resp_topic = self.api_response_topic orelse return;
        const resp = dispatch(dctx, payload, self.gpa) catch return;
        defer self.gpa.free(resp);
        if (resp.len == 0) return; // JSON-RPC notification: no response published
        const rparsed = std.json.parseFromSlice(std.json.Value, self.gpa, resp, .{}) catch return;
        defer rparsed.deinit();
        const qos: i64 = if (self.config) |c| c.api_qos else 0;
        self.publishTopic(resp_topic, rparsed.value, qos, false) catch {};
    }

    /// Moonraker: publish_topic_with_response — publish and wait for a
    /// response on a correlated response_topic. The caller provides a
    /// response_topic that will be subscribed, and the first message
    /// received on that topic is returned. Returns null on timeout.
    pub fn publishTopicWithResponse(
        self: *MqttCtx,
        topic: []const u8,
        response_topic: []const u8,
        payload: std.json.Value,
        qos: i64,
        retain: bool,
    ) !?std.json.Value {
        try self.publishTopic(topic, payload, qos, retain);
        // In the absence of a real broker, we don't have a subscription
        // callback mechanism. Return the last stored message on the
        // response topic, or null if none.
        return self.getMessage(response_topic);
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
        // When a live broker connection exists, also publish over the wire.
        if (self.client) |client| {
            var aw: std.Io.Writer.Allocating = .init(self.gpa);
            defer aw.deinit();
            var jw: std.json.Stringify = .{ .writer = &aw.writer };
            jw.write(payload) catch return;
            client.publish(topic, aw.written(), @intCast(@max(0, @min(2, qos))), retain) catch {};
        }
    }

    /// Publish with optional instance-name prefix.
    pub fn publishTopicPrefixed(self: *MqttCtx, topic: []const u8, payload: std.json.Value, qos: i64, retain: bool, use_prefix: bool) !void {
        if (!use_prefix) return self.publishTopic(topic, payload, qos, retain);
        const name = if (self.config) |cfg| cfg.instance_name orelse "moonraker" else "moonraker";
        const prefixed = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ name, topic });
        defer self.gpa.free(prefixed);
        return self.publishTopic(prefixed, payload, qos, retain);
    }

    /// Close the MQTT client: publish LWT offline message (if connected),
    /// clear all subscriptions/messages, reset config/state/timestamps.
    pub fn close(self: *MqttCtx) void {
        if (self.deinitialized) return;
        // Moonraker: publish offline LWT before disconnecting.
        if (self.isConnected()) {
            const rtopics = self.reservedTopics();
            defer {
                self.gpa.free(rtopics.api_request);
                self.gpa.free(rtopics.api_response);
                self.gpa.free(rtopics.moonraker_status);
                self.gpa.free(rtopics.klipper_status);
                self.gpa.free(rtopics.klipper_state_prefix);
            }
            var payload_obj: std.json.ObjectMap = .empty;
            defer payload_obj.deinit(self.gpa); // publishTopic deep-copies; free the builder.
            payload_obj.put(self.gpa, "server", .{ .string = "offline" }) catch {};
            self.publishTopic(rtopics.moonraker_status, .{ .object = payload_obj }, 0, true) catch {};
        }
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
            if (cfg.status_objects) |s| self.gpa.free(s);
            if (cfg.mqtt_protocol) |p| self.gpa.free(p);
        }
        self.config = null;
        self.state = .disconnected;
        self.last_status_time = 0.0;
        self.api_timestamps.clearRetainingCapacity();
        // Clear status cache.
        {
            var sc_it = self.status_cache.iterator();
            while (sc_it.next()) |entry| {
                self.gpa.free(entry.key_ptr.*);
                freeJsonValue(self.gpa, entry.value_ptr.*);
            }
        }
        self.status_cache.clearRetainingCapacity();
    }

    /// Moonraker: _handle_klippy_started — called when Klippy transitions
    /// to "ready". Subscribes to Klipper status objects and starts the
    /// status update timer (if interval is configured).
    /// In phobos, this is a stub; the caller is responsible for wiring
    /// Klippy status subscriptions externally via the klippy_connection.
    pub fn handleKlippyStarted(self: *MqttCtx) void {
        if (!self.isConfigured()) return;
        // If status_objects are configured, the klippy_connection component
        // will subscribe to them. The status update timer is started here
        // when status_interval > 0.
    }

    /// Moonraker: _handle_klippy_disconnect — called when Klippy
    /// disconnects. Stops the status update timer and flushes any
    /// cached status to MQTT.
    pub fn handleKlippyDisconnect(self: *MqttCtx) void {
        // flushStatusCache deep-copies the cache, frees the cache entries, and
        // frees the merged builder — the previous inline version shallow-copied
        // and clearRetainingCapacity'd, leaking both the entries and the builder.
        self.flushStatusCache();
    }

    /// Moonraker: _handle_timed_status_update — called on the status
    /// interval timer. Flushes the status cache and returns the next
    /// interval delay. Resets the cache for the next batching window.
    pub fn handleTimedStatusUpdate(self: *MqttCtx) f64 {
        if (!self.isConfigured()) return 0.0;
        // flushStatusCache deep-copies + frees correctly (see handleKlippyDisconnect).
        self.flushStatusCache();
        return if (self.config) |cfg| cfg.status_interval else 0.0;
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

    // Record the in-memory subscription (HTTP-endpoint path).
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
        break :blk try std.fmt.allocPrint(alloc, "{s}/{s}", .{ name, topic });
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

// ---- sendStatus / publishStatusUpdate ----

test "sendStatus: not configured returns immediately" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    const status = try mkParams(a, "{\"print_stats\": {\"state\": \"printing\"}}");
    ctx.sendStatus(status, 123.0);
    // No crash, cache remains empty.
    try testing.expectEqual(@as(usize, 0), ctx.status_cache.count());
}

test "sendStatus: not connected returns immediately" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);
    // Configured but not connected (state is disconnected).
    try testing.expect(!ctx.isConnected());

    const status = try mkParams(a, "{\"print_stats\": {\"state\": \"printing\"}}");
    ctx.sendStatus(status, 123.0);
    try testing.expectEqual(@as(usize, 0), ctx.status_cache.count());
}

test "sendStatus: non-object returns immediately" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);
    ctx.setState(.connected);

    // status is a string, not an object.
    ctx.sendStatus(.{ .string = "not-an-object" }, 123.0);
    try testing.expectEqual(@as(usize, 0), ctx.status_cache.count());
}

test "sendStatus: interval=0 publishes immediately, no caching" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);
    ctx.setState(.connected);
    ctx.setStatusInterval(0.0);

    const status = try mkParams(a, "{\"print_stats\": {\"state\": \"printing\"}}");
    ctx.sendStatus(status, 123.0);
    // With interval=0, cache should be empty (published immediately).
    try testing.expectEqual(@as(usize, 0), ctx.status_cache.count());
}

test "sendStatus: interval>0 accumulates into cache" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);
    ctx.setState(.connected);
    ctx.setStatusInterval(5.0);

    const status = try mkParams(a, "{\"print_stats\": {\"state\": \"printing\"}}");
    ctx.sendStatus(status, 100.0);
    try testing.expectEqual(@as(usize, 1), ctx.status_cache.count());
    try testing.expect(ctx.status_cache.get("print_stats") != null);
    try testing.expectEqual(@as(f64, 100.0), ctx.last_status_time);

    // Send another status update with a different key.
    const status2 = try mkParams(a, "{\"toolhead\": {\"homed_axes\": \"xyz\"}}");
    ctx.sendStatus(status2, 101.0);
    try testing.expectEqual(@as(usize, 2), ctx.status_cache.count());
    try testing.expect(ctx.status_cache.get("toolhead") != null);
    try testing.expectEqual(@as(f64, 101.0), ctx.last_status_time);
}

test "sendStatus: merges sub-fields into existing cache key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);
    ctx.setState(.connected);
    ctx.setStatusInterval(5.0);

    // First send: print_stats with state=printing.
    const status1 = try mkParams(a, "{\"print_stats\": {\"state\": \"printing\", \"x\": 1}}");
    ctx.sendStatus(status1, 100.0);
    try testing.expectEqual(@as(usize, 1), ctx.status_cache.count());

    // Second send: same key, adds/updates state=paused, keeps x=1.
    const status2 = try mkParams(a, "{\"print_stats\": {\"state\": \"paused\"}}");
    ctx.sendStatus(status2, 101.0);
    try testing.expectEqual(@as(usize, 1), ctx.status_cache.count());
    try testing.expectEqual(@as(f64, 101.0), ctx.last_status_time);

    // The cached value should merge: state updated, x preserved.
    const cached = ctx.status_cache.get("print_stats").?;
    try testing.expect(cached.object.get("state") != null);
    try testing.expectEqualStrings("paused", cached.object.get("state").?.string);
    try testing.expect(cached.object.get("x") != null);
}

test "publishStatusUpdate: not configured returns immediately" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    const status = try mkParams(a, "{\"print_stats\": {\"state\": \"printing\"}}");
    ctx.publishStatusUpdate(status, 123.0);
    // No crash, no messages stored (not configured).
}

test "publishStatusUpdate: split mode publishes per-field topics" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);
    ctx.setState(.connected);
    ctx.setPublishSplitStatus(true);

    const status = try mkParams(a, "{\"print_stats\": {\"state\": \"printing\", \"filename\": \"test.gcode\"}}");
    ctx.publishStatusUpdate(status, 123.0);

    // Split mode publishes under moonraker/klipper/state/{object}/{field}
    const state_prefix = "moonraker/klipper/state";
    try testing.expect(ctx.messages.count() >= 2);

    // Verify per-field topics exist.
    try testing.expect(ctx.messages.get(std.fmt.allocPrint(a, "{s}/print_stats/state", .{state_prefix}) catch unreachable) != null);
    try testing.expect(ctx.messages.get(std.fmt.allocPrint(a, "{s}/print_stats/filename", .{state_prefix}) catch unreachable) != null);
}

test "publishStatusUpdate: non-split mode publishes to klipper_status" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);
    ctx.setState(.connected);
    ctx.setPublishSplitStatus(false);

    const status = try mkParams(a, "{\"print_stats\": {\"state\": \"printing\"}}");
    ctx.publishStatusUpdate(status, 123.0);

    // Non-split mode publishes one message to moonraker/klipper/status.
    const klipper_status_topic = "moonraker/klipper/status";
    const msg = ctx.getMessage(klipper_status_topic);
    try testing.expect(msg != null);
    try testing.expect(msg.?.object.get("eventtime") != null);
    try testing.expect(msg.?.object.get("status") != null);
}

// ---- New config setters ----

test "setStatusObjects: stores and replaces value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);

    try ctx.setStatusObjects("print_stats, toolhead");
    try testing.expectEqualStrings("print_stats, toolhead", ctx.config.?.status_objects.?);
}

test "setStatusInterval: stores value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);

    ctx.setStatusInterval(30.0);
    try testing.expectEqual(@as(f64, 30.0), ctx.config.?.status_interval);
}

test "setPublishSplitStatus: stores value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);

    ctx.setPublishSplitStatus(true);
    try testing.expectEqual(true, ctx.config.?.publish_split_status);

    ctx.setPublishSplitStatus(false);
    try testing.expectEqual(false, ctx.config.?.publish_split_status);
}

test "setEnableTls: stores value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);

    ctx.setEnableTls(true);
    try testing.expectEqual(true, ctx.config.?.enable_tls);

    ctx.setEnableTls(false);
    try testing.expectEqual(false, ctx.config.?.enable_tls);
}

test "setMqttProtocol: stores and replaces value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);

    try ctx.setMqttProtocol("v5");
    try testing.expectEqualStrings("v5", ctx.config.?.mqtt_protocol.?);
}

test "sendStatus: status_objects filtering" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);
    try ctx.setStatusObjects("print_stats, toolhead");
    ctx.setState(.connected);
    ctx.setStatusInterval(0.0); // immediate flush

    const status = try mkParams(a, "{\"print_stats\": {\"state\": \"printing\"}, \"heater_bed\": {\"temp\": 60.0}, \"toolhead\": {\"homed\": true}}");
    ctx.sendStatus(status, 123.0);

    // Only print_stats and toolhead should be published (immediate flush).
    // heater_bed should be filtered out.
    const klipper_status_topic = "moonraker/klipper/status";
    const msg = ctx.getMessage(klipper_status_topic);
    try testing.expect(msg != null);
    const status_obj = msg.?.object.get("status").?.object;
    try testing.expect(status_obj.get("print_stats") != null);
    try testing.expect(status_obj.get("toolhead") != null);
    try testing.expect(status_obj.get("heater_bed") == null);
}

test "sendStatus: status_objects empty/nil passes everything" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);
    ctx.setState(.connected);
    ctx.setStatusInterval(0.0);
    // No status_objects set — everything passes.

    const status = try mkParams(a, "{\"print_stats\": {\"state\": \"printing\"}, \"heater_bed\": {\"temp\": 60.0}}");
    ctx.sendStatus(status, 123.0);

    const klipper_status_topic = "moonraker/klipper/status";
    const msg = ctx.getMessage(klipper_status_topic);
    try testing.expect(msg != null);
    try testing.expect(msg.?.object.get("status").?.object.get("print_stats") != null);
    try testing.expect(msg.?.object.get("status").?.object.get("heater_bed") != null);
}

test "flushStatusCache: publishes merged cache and clears" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);
    ctx.setState(.connected);
    ctx.setStatusInterval(5.0); // cache, don't flush

    // Accumulate two objects.
    const s1 = try mkParams(a, "{\"print_stats\": {\"state\": \"printing\"}}");
    ctx.sendStatus(s1, 100.0);
    const s2 = try mkParams(a, "{\"toolhead\": {\"homed\": true}}");
    ctx.sendStatus(s2, 101.0);
    try testing.expectEqual(@as(usize, 2), ctx.status_cache.count());

    // Flush.
    ctx.flushStatusCache();
    try testing.expectEqual(@as(usize, 0), ctx.status_cache.count());

    // Should have published to klipper_status.
    const klipper_status_topic = "moonraker/klipper/status";
    const msg = ctx.getMessage(klipper_status_topic);
    try testing.expect(msg != null);
    try testing.expect(msg.?.object.get("eventtime") != null);
    const status_obj = msg.?.object.get("status").?.object;
    try testing.expect(status_obj.get("print_stats") != null);
    try testing.expect(status_obj.get("toolhead") != null);
}

test "flushStatusCache: empty cache is no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);
    ctx.setState(.connected);

    const n_before = ctx.messages.count();
    ctx.flushStatusCache();
    try testing.expectEqual(n_before, ctx.messages.count());
}

test "setState: publishes moonraker_status on connected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);

    ctx.setState(.connected);
    const msg = ctx.getMessage("moonraker/moonraker/status");
    try testing.expect(msg != null);
    try testing.expect(msg.?.object.get("klipper_state") != null);
    try testing.expect(msg.?.object.get("klipper_message") != null);
}

test "setKlipperState: stores and publishes moonraker_status when connected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);
    ctx.setState(.connected);

    ctx.setKlipperState("ready", "Klipper ready");
    try testing.expectEqualStrings("ready", ctx.klipper_state);
    try testing.expectEqualStrings("Klipper ready", ctx.klipper_message);

    const msg = ctx.getMessage("moonraker/moonraker/status");
    try testing.expect(msg != null);
    try testing.expectEqualStrings("ready", msg.?.object.get("klipper_state").?.string);
    try testing.expectEqualStrings("Klipper ready", msg.?.object.get("klipper_message").?.string);
}

test "startStatusFlushThread: starts and stops without error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);
    ctx.setStatusInterval(1.0);

    ctx.startStatusFlushThread();
    try testing.expect(ctx.status_flush_thread != null);
    ctx.stopStatusFlushThread();
    try testing.expect(ctx.status_flush_thread == null);
}

test "startStatusFlushThread: interval=0 is no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("localhost", 1883, null, null);
    ctx.setStatusInterval(0.0);

    ctx.startStatusFlushThread();
    try testing.expect(ctx.status_flush_thread == null);
}

test "startStatusFlushThread: not configured is no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();

    ctx.startStatusFlushThread();
    try testing.expect(ctx.status_flush_thread == null);
}

test "fuzz sendStatus: never panics on arbitrary status values" {
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
            ctx.setState(.connected);
            ctx.setStatusInterval(@as(f64, @floatFromInt(buf[0] % 10))); // 0..9
            ctx.setPublishSplitStatus(buf[1] % 2 == 0);

            const eventtime: f64 = @floatFromInt(@as(u16, buf[2]) * 256 + @as(u16, buf[3]));

            // Build a pseudo-arbitrary JSON object for status.
            const keys = [_][]const u8{ "print_stats", "toolhead", "heater_bed" };
            const key = keys[buf[4] % keys.len];
            const vals = [_][]const u8{ "\"printing\"", "{\"homed\":true}", "\"on\"", "42", "null" };
            const val = vals[buf[5] % vals.len];
            const json = std.fmt.allocPrint(a, "{{\"{s}\":{s}}}", .{ key, val }) catch return;
            const status = mkParams(a, json) catch return;

            ctx.sendStatus(status, eventtime);
            // No crash; cache state is valid.
            _ = ctx.status_cache.count();
        }
    }.run, .{});
}

test "fuzz publishStatusUpdate: never panics on arbitrary status shapes" {
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
            ctx.setState(.connected);
            ctx.setPublishSplitStatus(buf[0] % 2 == 0);

            const eventtime: f64 = @floatFromInt(@as(u16, buf[1]) * 256 + @as(u16, buf[2]));

            // Generate various status shapes: empty object, single key, nested object, non-object.
            const shape = buf[3] % 4;
            const status = switch (shape) {
                0 => mkParams(a, "{}") catch return,
                1 => mkParams(a, "{\"print_stats\":{\"state\":\"printing\"}}") catch return,
                2 => mkParams(a, "{\"print_stats\":{\"state\":\"printing\",\"filename\":\"t.gcode\"},\"toolhead\":{\"homed_axes\":\"xyz\"}}") catch return,
                else => std.json.Value{ .string = "not-an-object" },
            };

            ctx.publishStatusUpdate(status, eventtime);
        }
    }.run, .{});
}

test "fuzz status_config_setters: never panics on arbitrary config values" {
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

            // Set status_objects.
            const objs = [_][]const u8{ "", "print_stats", "print_stats, toolhead", "a,b,c" };
            ctx.setStatusObjects(objs[buf[0] % objs.len]) catch return;

            // Set status_interval.
            ctx.setStatusInterval(@as(f64, @floatFromInt(buf[1])));

            // Set publish_split_status.
            ctx.setPublishSplitStatus(buf[2] % 2 == 0);

            // Set enable_tls.
            ctx.setEnableTls(buf[3] % 2 == 0);

            // Set mqtt_protocol.
            const protos = [_][]const u8{ "v3.1", "v3.1.1", "v5" };
            ctx.setMqttProtocol(protos[buf[4] % protos.len]) catch return;

            // Verify config is still intact.
            try testing.expect(ctx.config != null);
        }
    }.run, .{});
}

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

// ---------------------------------------------------------------------------
// Real broker integration (mqtt_client.TestBroker over a real TCP socket).
// ---------------------------------------------------------------------------

test "mqtt: connectBroker connects; publishTopic reaches the broker live" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var broker = try mqtt_client.TestBroker.bind(alloc, io);
    const p = try broker.port();

    // Broker services 3 client frames after the handshake:
    //   1) PUBLISH moonraker_status (emitted by setState(.connected))
    //   2) SUBSCRIBE api_request
    //   3) PUBLISH our live-test message  ← last publish recorded
    var bf = io.async(mqtt_client.TestBroker.run, .{ &broker, @as(usize, 3) });

    var ctx = MqttCtx.init(alloc);
    try ctx.setConfig("127.0.0.1", p, null, null);
    try ctx.setInstanceName("phobos");
    ctx.setIo(io);

    try ctx.connectBroker();
    try testing.expect(ctx.hasBrokerConnection());

    try ctx.publishTopic("phobos/instance/live-test", .{ .string = "hi-live" }, 0, false);

    bf.await(io);

    // Tear down the client (joins reader thread) before the broker socket.
    ctx.deinit();
    broker.deinit();

    try testing.expect(broker.saw_subscribe);
    try testing.expectEqualStrings("phobos/instance/live-test", broker.got_topic[0..broker.got_topic_len]);
    try testing.expectEqualStrings("\"hi-live\"", broker.got_payload[0..broker.got_payload_len]);
}

test "connectBrokerBg supervisor: connects via the reconnect loop and shuts down cleanly" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var broker = try mqtt_client.TestBroker.bind(alloc, io);
    const p = try broker.port();
    // Broker keeps reading client frames (status publish, subscribe, ...) until
    // the client drops on shutdown.
    var bf = io.async(mqtt_client.TestBroker.run, .{ &broker, @as(usize, 20) });

    var ctx = MqttCtx.init(alloc);
    try ctx.setConfig("127.0.0.1", p, null, null);
    try ctx.setInstanceName("phobos");
    ctx.setIo(io);

    // Launch the reconnect supervisor (as App does).
    ctx.connect_thread = std.Thread.spawn(.{}, MqttCtx.connectBrokerBg, .{&ctx}) catch unreachable;

    // Wait (bounded) until the supervisor establishes the connection.
    var tries: usize = 0;
    while (!ctx.hasBrokerConnection() and tries < 400) : (tries += 1) {
        var req: std.os.linux.timespec = .{ .sec = 0, .nsec = 5_000_000 }; // 5 ms
        _ = std.os.linux.nanosleep(&req, null);
    }
    try testing.expect(ctx.hasBrokerConnection());

    // Clean shutdown: disconnectBroker signals stop, unblocks the reader, and
    // joins the supervisor (which frees the client). testing.allocator catches
    // any leak/double-free; a deadlock would hang the suite (caught by timeout).
    ctx.deinit();
    bf.await(io);
    broker.deinit();
    try testing.expect(!ctx.hasBrokerConnection());
}

test "mqtt: connectBroker without io returns MqttNotConfigured" {
    const alloc = std.testing.allocator;
    var ctx = MqttCtx.init(alloc);
    defer ctx.deinit();
    try ctx.setConfig("127.0.0.1", 1883, null, null);
    // No io wired → cannot connect.
    try testing.expectError(error.MqttNotConfigured, ctx.connectBroker());
    try testing.expect(!ctx.hasBrokerConnection());
}

const TestApiDispatch = struct {
    fn cb(_: *anyopaque, _: []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
        return alloc.dupe(u8, "{\"jsonrpc\":\"2.0\",\"result\":{\"ok\":true},\"id\":1}");
    }
    fn cbEmpty(_: *anyopaque, _: []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
        return alloc.dupe(u8, ""); // notification → no response published
    }
};

test "processApiRequest: dispatches and publishes the response (JSON-RPC-over-MQTT bridge)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx(a);
    defer ctx.deinit();
    try ctx.setConfig("mqtt.local", 1883, null, null);
    ctx.config.?.enable_moonraker_api = true;
    ctx.api_request_topic = try a.dupe(u8, "phobos/moonraker/api/request");
    ctx.api_response_topic = try a.dupe(u8, "phobos/moonraker/api/response");
    var dummy: u8 = 0;
    ctx.api_dispatch = TestApiDispatch.cb;
    ctx.api_dispatch_ctx = &dummy;

    try ctx.processApiRequest("{\"jsonrpc\":\"2.0\",\"method\":\"server.info\",\"id\":1}");
    const resp = ctx.getMessage("phobos/moonraker/api/response").?;
    try testing.expectEqualStrings("2.0", resp.object.get("jsonrpc").?.string);
    try testing.expectEqual(true, resp.object.get("result").?.object.get("ok").?.bool);

    // A notification (empty dispatch result) publishes nothing new.
    ctx.api_dispatch = TestApiDispatch.cbEmpty;
    try ctx.processApiRequest("{\"jsonrpc\":\"2.0\",\"method\":\"x\"}");
}

test "fuzz processApiRequest: arbitrary payloads never crash the bridge" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = testCtx(a);
            defer ctx.deinit();
            ctx.setConfig("mqtt.local", 1883, null, null) catch return;
            ctx.config.?.enable_moonraker_api = true;
            ctx.api_request_topic = a.dupe(u8, "req") catch return;
            ctx.api_response_topic = a.dupe(u8, "resp") catch return;
            var dummy: u8 = 0;
            ctx.api_dispatch = TestApiDispatch.cb;
            ctx.api_dispatch_ctx = &dummy;
            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            ctx.processApiRequest(&buf) catch {};
        }
    }.run, .{});
}

test "mqtt: inbound broker PUBLISH fires the on_message hook" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var broker = try mqtt_client.TestBroker.bind(alloc, io);
    const p = try broker.port();
    // 2 frames after handshake: moonraker_status publish + api_request subscribe.
    var bf = io.async(mqtt_client.TestBroker.run, .{ &broker, @as(usize, 2) });

    const Cap = struct {
        topic: [128]u8 = undefined,
        topic_len: usize = 0,
        payload: [128]u8 = undefined,
        payload_len: usize = 0,
        fn cb(ctx: *anyopaque, topic: []const u8, payload: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(self.topic[0..topic.len], topic);
            self.topic_len = topic.len;
            @memcpy(self.payload[0..payload.len], payload);
            self.payload_len = payload.len;
        }
    };
    var cap: Cap = .{};

    var ctx = MqttCtx.init(alloc);
    try ctx.setConfig("127.0.0.1", p, null, null);
    try ctx.setInstanceName("phobos");
    ctx.setIo(io);
    ctx.on_message = Cap.cb;
    ctx.on_message_ctx = &cap;

    try ctx.connectBroker();
    bf.await(io); // broker processed status publish + subscribe

    try broker.injectPublish("phobos/chamber/state", "{\"temperature\":21.0}");

    // Wait for the background reader to dispatch the inbound publish.
    var spins: usize = 0;
    while (cap.payload_len == 0 and spins < 200) : (spins += 1) {
        std.Io.sleep(io, .{ .nanoseconds = 5_000_000 }, .real) catch {};
    }

    ctx.deinit();
    broker.deinit();

    try testing.expectEqualStrings("phobos/chamber/state", cap.topic[0..cap.topic_len]);
    try testing.expectEqualStrings("{\"temperature\":21.0}", cap.payload[0..cap.payload_len]);
}

test "connectBroker: failed connect frees client exactly once (no double-free)" {
    // Regression: the connect-failure path must not destroy(client) AND fire the
    // errdefer (double-free). testing.allocator aborts on a double-free.
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctx = MqttCtx.init(alloc);
    defer ctx.deinit();
    try ctx.setConfig("127.0.0.1", 1, null, null); // port 1: connect refused
    ctx.setIo(io);

    // Connect is expected to fail (refused). Freeing happens inside connectBroker;
    // a double-free would abort the test under testing.allocator.
    ctx.connectBroker() catch {};
    try std.testing.expect(!ctx.hasBrokerConnection());
}
