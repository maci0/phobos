//! Klippy Unix-socket bridge.
//!
//! Connects to Klippy's Unix socket (default `/tmp/klippy_uds`), performs the
//! identify/subscribe handshake, then runs one persistent reader that drains
//! the socket, dispatches Klippy's pushes under `Core` and routes responses to
//! per-id waiters. Each `/klippysocket` client gets its own Unix connection
//! (`serveBridge`), as Moonraker's `BridgeSocket` does.
//!
//! Wire protocol: JSON-RPC 2.0 messages delimited by `\x03` (ASCII ETX).
//! Klippy's `register_remote_method` stores `response_template` (the method
//! name) plus `remote_method`. `call_remote_method` then sends that template
//! merged with `params` and no id. Status and gcode pushes are the same shape.
//!
//! References:
//!   vendor/moonraker/moonraker/components/klippy_connection.py
//!   vendor/moonraker/moonraker/components/websockets.py (BridgeSocket)
//!   https://www.klipper3d.org/API_Server.html

const std = @import("std");
const sleep = @import("../util/sleep.zig");
const net = std.Io.net;
const framing = @import("../util/klippy_frame.zig");
const jv = @import("../json/value.zig");
const notify = @import("../server/notify.zig");
const methods = @import("../core/methods.zig");
const server_core = @import("../server/core.zig");
const clock = @import("../util/clock.zig");
const SocketDeadline = @import("../util/socket_deadline.zig").SocketDeadline;
const DeadlineWriter = @import("../util/deadline_writer.zig").DeadlineWriter;
const MessageBuffer = @import("../util/ws_message.zig").MessageBuffer;
const connections = @import("../server/connections.zig");

/// One in-flight request awaiting its response. The persistent reader routes
/// a matching response frame here and posts the semaphore.
const Waiter = struct {
    sem: std.Io.Semaphore = .{},
    /// gpa-owned response frame, set by the reader before posting.
    payload: ?[]u8 = null,
    /// Set when the connection drops while waiting.
    failed: bool = false,
};

// ---------------------------------------------------------------------------
// Klippy connection state
// ---------------------------------------------------------------------------

/// Moonraker's `KlippyState`, reported as `server.info` `klippy_state`.
pub const State = enum {
    disconnected,
    startup,
    ready,
    @"error",
    shutdown,
};

/// Klippy `state` strings (`info` results and `webhooks.state`).
const klippy_state_map = std.StaticStringMap(State).initComptime(.{
    .{ "startup", .startup },
    .{ "ready", .ready },
    .{ "error", .@"error" },
    .{ "shutdown", .shutdown },
});

/// Request params sent during the handshake.
const identify_params = "{\"client_info\":{\"program\":\"phobos\",\"version\":\"1.0.0\"}}";
const heaters_query_params = "{\"objects\":{\"heaters\":null}}";
const gcode_subscribe_params = "{\"response_template\":{\"method\":\"process_gcode_response\"}}";
/// Objects phobos always subscribes for its own state tracking.
const base_sub_objects = [_][]const u8{ "webhooks", "toolhead", "print_stats" };
/// Bounds on the client-extended subscription set.
const max_sub_objects = connections.max_subscription_objects;
const max_sub_object_name_len = connections.max_subscription_name_len;
/// `info` polls while Klippy reports `startup`, and the delay between them.
const startup_polls = 100;
const startup_poll_delay: std.Io.Duration = .fromMilliseconds(250);
const reconnect_delay: std.Io.Duration = .fromSeconds(1);
const write_timeout: std.Io.Duration = .fromSeconds(5);
/// Frames read while waiting for one handshake response.
const handshake_max_frames = 40;
/// WebSocket close sent to `/klippysocket` clients (BridgeSocket.close_socket).
const bridge_close_code = 1001;
const bridge_close_reason = "Klippy Disconnected";

/// Klippy state from an `info` result; null when `state` is absent or unknown.
pub fn parseKlippyState(result: std.json.Value) ?State {
    if (result != .object) return null;
    const s = result.object.get("state") orelse return null;
    if (s != .string) return null;
    return klippy_state_map.get(s.string);
}

/// A JSON-RPC request frame with the string id waiters are keyed by.
/// `method` is a phobos constant; `params_json` is serialized JSON, "" for `{}`.
fn formatRequest(alloc: std.mem.Allocator, method: []const u8, id: u64, params_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"id\":\"{d}\",\"params\":{s}}}", .{
        method,
        id,
        if (params_json.len == 0) "{}" else params_json,
    });
}

/// Copy `heaters.<field>` strings out of an `objects/query` result.
/// `available_monitors: null` and a missing heaters object yield nothing.
fn collectHeaterNames(result: std.json.Value, field: []const u8, alloc: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    if (result != .object) return;
    const status = result.object.get("status") orelse return;
    if (status != .object) return;
    const heaters = status.object.get("heaters") orelse return;
    if (heaters != .object) return;
    const arr_v = heaters.object.get(field) orelse return;
    if (arr_v != .array) return;
    for (arr_v.array.items) |item| {
        if (item != .string) continue;
        const name = item.string;
        if (name.len == 0) continue;
        var seen = false;
        for (out.items) |n| if (std.mem.eql(u8, n, name)) {
            seen = true;
            break;
        };
        if (seen) continue;
        try out.append(alloc, name);
    }
}

/// Handshake-only match of phobos's own string id in a raw frame.
fn frameIdMatches(alloc: std.mem.Allocator, payload: []const u8, id: u64) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const value = parsed.value.object.get("id") orelse return false;
    if (value != .string) return false;
    return (std.fmt.parseInt(u64, value.string, 10) catch return false) == id;
}

/// A JSON number (int or float) as f64; null for absent/non-numeric.
fn numField(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

/// Serialize client `params` to JSON in `alloc` ("" for null), rejecting
/// values nested deeper than std.json.Stringify's fixed 256-level stack.
fn serializeParams(alloc: std.mem.Allocator, params: std.json.Value) ![]const u8 {
    if (params == .null) return "";
    if (jv.exceedsDepth(params, jv.max_value_depth)) return error.InvalidParams;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try jw.write(params);
    return aw.toOwnedSlice();
}

/// Parse a Klippy response payload and extract `result`. `.alloc_always`
/// copies every string into `alloc`, so the result outlives `payload`.
fn parseKlippyResult(alloc: std.mem.Allocator, payload: []const u8) !std.json.Value {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, payload, .{ .allocate = .alloc_always });
    if (root != .object) return error.KlippyRequestFailed;
    if (jv.exceedsDepth(root, jv.max_value_depth)) return error.InvalidFrame;
    if (root.object.get("error")) |_| return error.KlippyRequestFailed;
    return root.object.get("result") orelse .null;
}

/// Close a `/klippysocket` WebSocket with 1001 "Klippy Disconnected".
fn closeBridge(ws: *std.http.Server.WebSocket, writer: ?*DeadlineWriter) void {
    if (writer) |out| out.beginFrame();
    var payload: [2 + bridge_close_reason.len]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], bridge_close_code, .big);
    @memcpy(payload[2..], bridge_close_reason);
    ws.writeMessage(&payload, .connection_close) catch {};
}

/// One `/klippysocket` session: a WebSocket client and its own Klippy
/// connection.
const Bridge = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    ws: *std.http.Server.WebSocket,
    stream: net.Stream,
    client_stream: net.Stream,
    writer: ?*DeadlineWriter,
    /// Serializes WebSocket writes (relayed frames, pongs, close).
    ws_mutex: std.Io.Mutex = std.Io.Mutex.init,

    fn writeWs(self: *Bridge, data: []const u8, op: std.http.Server.WebSocket.Opcode) !void {
        self.ws_mutex.lockUncancelable(self.io);
        defer self.ws_mutex.unlock(self.io);
        if (self.writer) |writer| writer.beginFrame();
        try self.ws.writeMessage(data, op);
    }

    /// Klippy to client. On EOF, a read error or cancellation, closes the
    /// WebSocket with 1001.
    fn relayKlippy(self: *Bridge) void {
        defer self.client_stream.shutdown(self.io, .both) catch {};
        var buf: [4096]u8 = undefined;
        var reader = self.stream.reader(self.io, &buf);
        while (true) {
            const payload = framing.read(self.gpa, &reader.interface) catch break;
            defer self.gpa.free(payload);
            self.writeWs(payload, .text) catch break;
        }
        self.ws_mutex.lockUncancelable(self.io);
        defer self.ws_mutex.unlock(self.io);
        closeBridge(self.ws, self.writer);
    }

    /// Client to Klippy, on the calling task. Returns when the client closes
    /// or either socket fails.
    fn relayClient(self: *Bridge) void {
        var input = MessageBuffer.init(self.gpa, self.ws.input);
        defer input.deinit();
        var buf: [4096]u8 = undefined;
        var writer = self.stream.writer(self.io, &buf);
        while (true) {
            const msg = input.read(self.ws) catch return;
            switch (msg.opcode) {
                .text, .binary => {
                    framing.write(&writer.interface, msg.data) catch return;
                    writer.interface.flush() catch return;
                },
                .ping => self.writeWs(msg.data, .pong) catch return,
                else => return,
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

/// Feather and other components handle Klippy remote methods through this.
pub const RemoteHandler = *const fn (*anyopaque, std.mem.Allocator, []const u8, std.json.Value) anyerror!void;

pub const KlippyCtx = struct {
    gpa: std.mem.Allocator,
    io: ?std.Io = null,
    /// Its `core` serializes dispatch and is released by `request` waits.
    bus: *notify.NotifyBus,

    /// `server.info` state block mirrored by `setState`.
    server_info: ?*methods.ServerInfo = null,

    /// Path to the Klippy Unix socket. Default: /tmp/klippy_uds.
    uds_path: []const u8,

    /// Touched only by the Klippy task (status pushes run there under Core).
    state: State = .disconnected,
    /// True from handshake completion until the reader fails, in any Klippy
    /// state. Changed under `pending_mutex`, so a waiter can never register
    /// after `failAllWaiters`.
    connected: std.atomic.Value(bool) = .init(false),

    next_id: u64 = 0,
    next_id_mutex: std.Io.Mutex = std.Io.Mutex.init,

    /// In-flight request waiters keyed by request id; the reader routes responses.
    pending: std.AutoHashMapUnmanaged(u64, *Waiter) = .empty,
    /// Guards `pending` and transitions of `connected`.
    pending_mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Guards `stream` and serializes socket writes. Only the Klippy task reads.
    write_mutex: std.Io.Mutex = std.Io.Mutex.init,

    read_buffer: [4096]u8 = undefined,
    reader: ?net.Stream.Reader = null,
    /// Active Unix socket stream; null when disconnected.
    stream: ?net.Stream = null,

    /// Job state component (set by App). Fed print_stats; failed on disconnect.
    job_state: ?*@import("job_state.zig").JobStateCtx = null,
    /// History component (set by App). Finishes the job on disconnect/shutdown.
    history: ?*@import("history.zig").HistoryCtx = null,
    /// OctoPrint compat component (set by App). Fed print_stats.
    octoprint: ?*@import("octoprint_compat.zig").OctoPrintCtx = null,
    /// Temperature store (set by App). Fed a sample per temperature object.
    temp_store: ?*@import("data_store.zig").DataStoreCtx = null,

    /// Optional handler for remote methods other than status and gcode.
    remote_handler: ?RemoteHandler = null,
    remote_handler_ctx: ?*anyopaque = null,
    /// Called with Klippy's `klipper_path` while the info JSON is still alive.
    /// The slice is borrowed; the handler must copy it before returning.
    on_klipper_path: ?*const fn (*anyopaque, []const u8) void = null,
    on_klipper_path_ctx: ?*anyopaque = null,
    /// Borrowed callbacks run under Core. They copy or queue work; no round trips.
    event_ctx: ?*anyopaque = null,
    on_state: ?*const fn (*anyopaque, std.Io, State) void = null,
    on_status: ?*const fn (*anyopaque, std.Io, std.json.Value, std.json.Value) void = null,
    on_gcode: ?*const fn (*anyopaque, std.Io, std.json.Value) void = null,
    /// Registered with Klippy once it is ready.
    remote_methods: []const []const u8 = &.{},

    /// Set by stop() to signal the background klippyTask to exit.
    stopping: std.Io.Event = .unset,
    task: ?std.Io.Future(void) = null,

    /// Objects Klippy's heater list adds to the base subscription.
    /// Keys are gpa-owned; bounded by `max_sub_objects`. Guarded by `sub_mutex`.
    extra_sub_objects: std.StringHashMapUnmanaged(void) = .empty,
    sub_mutex: std.Io.Mutex = std.Io.Mutex.init,
    subscribe_mutex: std.Io.Mutex = .init,

    pub fn init(gpa: std.mem.Allocator, bus: *notify.NotifyBus) !KlippyCtx {
        return KlippyCtx{
            .gpa = gpa,
            .bus = bus,
            .uds_path = "/tmp/klippy_uds",
        };
    }

    pub fn setIo(self: *KlippyCtx, io: std.Io) void {
        self.io = io;
    }

    pub fn deinit(self: *KlippyCtx) void {
        if (self.io) |io| self.stop(io);
        var sit = self.extra_sub_objects.keyIterator();
        while (sit.next()) |k| self.gpa.free(k.*);
        self.extra_sub_objects.deinit(self.gpa);
        self.pending.deinit(self.gpa);
    }

    /// True once the handshake completed on the live connection, in any
    /// Klippy state (`printer.firmware_restart` must work after a shutdown).
    pub fn isConnected(self: *const KlippyCtx) bool {
        return self.connected.load(.acquire);
    }

    /// Add a Klipper object to the aggregate `objects/subscribe` set, sent at
    /// the next subscribe. Requires `setIo`.
    pub fn addSubscriptionObject(self: *KlippyCtx, name: []const u8) !void {
        if (name.len > max_sub_object_name_len) return error.InvalidParams;
        for (base_sub_objects) |base| if (std.mem.eql(u8, base, name)) return;
        const io = self.io orelse return error.NotReady;
        self.sub_mutex.lockUncancelable(io);
        defer self.sub_mutex.unlock(io);
        if (self.extra_sub_objects.contains(name)) return;
        if (self.extra_sub_objects.count() >= max_sub_objects) return error.TooManyObjects;
        const k = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(k);
        try self.extra_sub_objects.put(self.gpa, k, {});
    }

    /// `objects/subscribe` params: the base objects plus every registered
    /// extra, and the `response_template` without which Klippy pushes no
    /// updates (klippy_connection.py:644).
    fn buildSubscribeParams(self: *KlippyCtx, io: std.Io, alloc: std.mem.Allocator) ![]u8 {
        var objects: std.json.ObjectMap = .empty;
        defer jv.free(alloc, .{ .object = objects });
        for (base_sub_objects) |name| {
            const owned = try alloc.dupe(u8, name);
            errdefer alloc.free(owned);
            try objects.put(alloc, owned, .null);
        }
        {
            self.sub_mutex.lockUncancelable(io);
            defer self.sub_mutex.unlock(io);
            var it = self.extra_sub_objects.keyIterator();
            while (it.next()) |k| {
                const owned = try alloc.dupe(u8, k.*);
                errdefer alloc.free(owned);
                try objects.put(alloc, owned, .null);
            }
        }
        try self.bus.conns.appendSubscriptionObjects(io, alloc, &objects);
        return std.json.Stringify.valueAlloc(alloc, .{ .objects = std.json.Value{ .object = objects }, .response_template = .{ .method = "process_status_update" } }, .{});
    }

    /// Start the background Klippy connection task. Must be called after setIo().
    pub fn start(self: *KlippyCtx) !void {
        if (self.task != null) return;
        const io = self.io orelse return error.NotReady;
        self.stopping.reset();
        self.task = try io.concurrent(klippyTask, .{self});
    }

    /// Cancel and join the owned task before closing its stream. Idempotent.
    /// The task takes Core while exiting, so the caller must not hold it.
    pub fn stop(self: *KlippyCtx, io: std.Io) void {
        self.stopping.set(io);
        if (self.task) |*task| {
            task.cancel(io);
            self.task = null;
        }
        self.closeStream(io);
    }

    /// Serve one `/klippysocket` client (Moonraker `BridgeSocket`) on its own
    /// Klippy Unix connection, relaying ETX-framed payloads both ways until
    /// either side closes. Klippy keeps one subscription per connection, so a
    /// bridge client never replaces phobos's. Refused with close 1001 while
    /// phobos itself is not connected.
    pub fn serveBridge(self: *KlippyCtx, io: std.Io, ws: *std.http.Server.WebSocket, client_stream: net.Stream, writer: ?*DeadlineWriter) void {
        if (!self.isConnected()) return closeBridge(ws, writer);
        const addr = net.UnixAddress.init(self.uds_path) catch return closeBridge(ws, writer);
        const stream = addr.connect(io) catch return closeBridge(ws, writer);
        defer stream.close(io);
        // Send the upgrade response: Klippy says nothing until the client does.
        ws.flush() catch return;
        var bridge: Bridge = .{ .gpa = self.gpa, .io = io, .ws = ws, .stream = stream, .client_stream = client_stream, .writer = writer };
        var klippy_side = io.concurrent(Bridge.relayKlippy, .{&bridge}) catch return closeBridge(ws, writer);
        bridge.relayClient();
        klippy_side.cancel(io);
    }

    // -----------------------------------------------------------------------
    // Background task: connect, handshake, read, reconnect
    // -----------------------------------------------------------------------

    fn klippyTask(self: *KlippyCtx) void {
        const io = self.io.?;
        while (!self.stopping.isSet()) {
            if (self.openStream(io)) |_| {
                if (self.handshake(io)) |_| {
                    // Any error here means the connection ended.
                    self.readerLoop(io) catch {};
                } else |_| {}
                self.failAllWaiters(io);
                _ = self.setState(.disconnected);
                self.closeStream(io);
                self.bus.core.run(io, disconnectedLocked, .{ self, io });
            } else |_| {}
            if (sleep.untilStopped(io, reconnect_delay, &self.stopping)) break;
        }
    }

    fn openStream(self: *KlippyCtx, io: std.Io) !void {
        const addr = try net.UnixAddress.init(self.uds_path);
        const s = try addr.connect(io);
        self.write_mutex.lockUncancelable(io);
        self.stream = s;
        self.write_mutex.unlock(io);
        self.reader = s.reader(io, &self.read_buffer);
        _ = self.setState(.startup);
    }

    /// Null the stream under `write_mutex` (no write can be in flight on it),
    /// then close it. Only the caller that observes non-null closes.
    fn closeStream(self: *KlippyCtx, io: std.Io) void {
        self.write_mutex.lockUncancelable(io);
        const s = self.stream;
        self.stream = null;
        self.write_mutex.unlock(io);
        if (s) |sock| sock.close(io);
    }

    // -----------------------------------------------------------------------
    // Handshake
    // -----------------------------------------------------------------------

    /// Klippy handshake after the socket opens (Moonraker `_check_ready`):
    ///   1. `info` with `client_info` identifies phobos; poll `info` while
    ///      Klippy reports `startup`.
    ///   2. `objects/subscribe` with `response_template` for status pushes.
    ///   3. When ready: heater sensors for the temperature store.
    ///   4. `gcode/subscribe_output` for gcode responses.
    ///   5. When ready: register remote methods, then `notify_klippy_ready`.
    /// `shutdown` and `error` keep the connection, as in Moonraker. A Klippy
    /// error result does not abort the handshake; a socket error does.
    fn handshake(self: *KlippyCtx, io: std.Io) !void {
        try self.pollInfo(io);
        {
            const params = try self.buildSubscribeParams(io, self.gpa);
            defer self.gpa.free(params);
            const resp = try self.handshakeRequest(io, "objects/subscribe", params);
            defer self.gpa.free(resp);
            self.seedSubscribedStatus(io, resp);
        }
        if (self.state == .ready) try self.subscribeTemperatureSensors(io);
        self.gpa.free(try self.handshakeRequest(io, "gcode/subscribe_output", gcode_subscribe_params));
        if (self.state == .ready) {
            for (self.remote_methods) |name| {
                const params = try std.json.Stringify.valueAlloc(self.gpa, .{
                    .response_template = .{ .method = name },
                    .remote_method = name,
                }, .{});
                defer self.gpa.free(params);
                self.gpa.free(try self.handshakeRequest(io, "register_remote_method", params));
            }
        }
        {
            self.pending_mutex.lockUncancelable(io);
            defer self.pending_mutex.unlock(io);
            self.connected.store(true, .release);
        }
        self.bus.core.run(io, handshakeCompleteLocked, .{ self, io });
    }

    fn handshakeCompleteLocked(self: *KlippyCtx, io: std.Io) void {
        if (self.on_state) |callback| if (self.event_ctx) |ctx| callback(ctx, io, self.state);
        if (self.state == .ready) self.bus.emitLocked(io, notify.names.klippy_ready, .null) catch {};
    }

    /// Send `info` until Klippy leaves `startup`. The first successful
    /// response identifies phobos; later polls omit `client_info`.
    fn pollInfo(self: *KlippyCtx, io: std.Io) !void {
        var params: []const u8 = identify_params;
        for (0..startup_polls) |_| {
            const payload = try self.handshakeRequest(io, "info", params);
            defer self.gpa.free(payload);
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            if (parseKlippyResult(arena.allocator(), payload)) |result| {
                params = "{}";
                self.reportKlipperPath(result);
                const state = parseKlippyState(result) orelse return error.IdentifyFailed;
                _ = self.setState(state);
                if (state != .startup) return;
            } else |err| switch (err) {
                // Moonraker logs an info error and polls again.
                error.KlippyRequestFailed => {},
                else => |e| return e,
            }
            try std.Io.sleep(io, startup_poll_delay, .awake);
        }
        return error.KlippyStartupTimeout;
    }

    fn reportKlipperPath(self: *KlippyCtx, result: std.json.Value) void {
        if (result != .object) return;
        const kp = result.object.get("klipper_path") orelse return;
        if (kp != .string or kp.string.len == 0) return;
        const cb = self.on_klipper_path orelse return;
        cb(self.on_klipper_path_ctx orelse return, kp.string);
    }

    /// Send `method` and read until its response, dispatching frames in
    /// between. Handshake only: the persistent reader is not running yet.
    /// Returns the gpa-owned response frame.
    fn handshakeRequest(self: *KlippyCtx, io: std.Io, method: []const u8, params_json: []const u8) ![]u8 {
        const id = self.nextId(io);
        const frame = try formatRequest(self.gpa, method, id, params_json);
        defer self.gpa.free(frame);
        try self.writeFrame(io, frame);
        for (0..handshake_max_frames) |_| {
            const payload = try self.readFrame();
            if (frameIdMatches(self.gpa, payload, id)) return payload;
            defer self.gpa.free(payload);
            self.dispatchFrame(io, payload) catch {};
        }
        return error.KlippyRequestFailed;
    }

    /// `objects/query` `heaters`, then subscribe `available_sensors` and
    /// `available_monitors`. Moonraker does this on `klippy_ready` so
    /// `server.temperature_store` has the same keys. A Klippy error result is
    /// ignored (the frame was consumed).
    fn subscribeTemperatureSensors(self: *KlippyCtx, io: std.Io) !void {
        const qresp = try self.handshakeRequest(io, "objects/query", heaters_query_params);
        defer self.gpa.free(qresp);

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const result = parseKlippyResult(arena.allocator(), qresp) catch return;

        var sensors: std.ArrayList([]const u8) = .empty;
        defer sensors.deinit(self.gpa);
        var monitors: std.ArrayList([]const u8) = .empty;
        defer monitors.deinit(self.gpa);
        try collectHeaterNames(result, "available_sensors", self.gpa, &sensors);
        try collectHeaterNames(result, "available_monitors", self.gpa, &monitors);
        if (sensors.items.len == 0 and monitors.items.len == 0) return;

        for ([_][]const []const u8{ sensors.items, monitors.items }) |names| {
            for (names) |name| self.addSubscriptionObject(name) catch |err| switch (err) {
                error.OutOfMemory => return err,
                // A full set or an oversized name skips that sensor.
                else => {},
            };
        }
        const params = try self.buildSubscribeParams(io, self.gpa);
        defer self.gpa.free(params);
        const sresp = try self.handshakeRequest(io, "objects/subscribe", params);
        defer self.gpa.free(sresp);

        if (self.temp_store) |ts| {
            for (monitors.items) |n| ts.markTempMonitor(io, n);
        }
        self.seedSubscribedStatus(io, sresp);
    }

    /// Seed job state, OctoPrint state and the temperature store from an
    /// `objects/subscribe` response frame. Later pushes take the reader path.
    fn seedSubscribedStatus(self: *KlippyCtx, io: std.Io, payload: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const result = parseKlippyResult(arena.allocator(), payload) catch return;
        self.bus.core.run(io, seedSubscribedStatusLocked, .{ self, io, result });
    }

    fn seedSubscribedStatusLocked(self: *KlippyCtx, io: std.Io, result: std.json.Value) void {
        if (result != .object) return;
        const status = result.object.get("status") orelse return;
        if (status != .object) return;
        if (status.object.get("print_stats")) |ps| {
            if (self.job_state) |js| js.initialize(ps);
            if (self.octoprint) |oc| oc.statusUpdate(ps);
        }
        if (self.on_status) |callback| if (self.event_ctx) |ctx|
            callback(ctx, io, status, result.object.get("eventtime") orelse .{ .float = 0 });
        const ts = self.temp_store orelse return;
        var it = status.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .object) continue;
            const od = entry.value_ptr.object;
            if (numField(od, "temperature")) |temp| {
                ts.pushTemp(io, entry.key_ptr.*, temp, numField(od, "target"), numField(od, "power"), numField(od, "speed"));
            }
        }
    }

    // -----------------------------------------------------------------------
    // Read loop and dispatch
    // -----------------------------------------------------------------------

    /// Handle one frame from Klippy. Method frames (status and gcode pushes,
    /// `call_remote_method`) run under Core; Moonraker sends no reply to them.
    /// Responses go to the waiter registered under their string id.
    pub fn dispatchFrame(self: *KlippyCtx, io: std.Io, payload: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, payload, .{});
        defer parsed.deinit();

        const frame = parsed.value;
        if (frame != .object) return error.InvalidFrame;
        if (frame.object.get("method")) |method| {
            if (method != .string) return error.InvalidFrame;
            if (jv.exceedsDepth(frame, jv.max_value_depth)) return error.InvalidFrame;
            return self.bus.core.run(io, dispatchRemoteMethod, .{ self, io, method.string, frame });
        }
        const id = frame.object.get("id") orelse return;
        if (id != .string) return;
        const id_num = std.fmt.parseInt(u64, id.string, 10) catch return;
        self.pending_mutex.lockUncancelable(io);
        defer self.pending_mutex.unlock(io);
        const waiter = self.pending.get(id_num) orelse return;
        if (waiter.payload != null or waiter.failed) return;
        // On OOM the waiter wakes without a payload and reports it.
        waiter.payload = self.gpa.dupe(u8, payload) catch null;
        waiter.sem.post(io);
    }

    /// The sole reader once the handshake completes. Returns when the socket
    /// fails; a malformed frame is skipped, as Moonraker does.
    fn readerLoop(self: *KlippyCtx, io: std.Io) !void {
        while (!self.stopping.isSet()) {
            const payload = try self.readFrame();
            defer self.gpa.free(payload);
            self.dispatchFrame(io, payload) catch {};
        }
    }

    /// Close waiter registration and fail every in-flight waiter.
    fn failAllWaiters(self: *KlippyCtx, io: std.Io) void {
        self.pending_mutex.lockUncancelable(io);
        defer self.pending_mutex.unlock(io);
        self.connected.store(false, .release);
        var it = self.pending.valueIterator();
        while (it.next()) |wp| {
            wp.*.failed = true;
            wp.*.sem.post(io);
        }
    }

    /// Run one Klippy method frame. Caller holds Core.
    pub fn dispatchRemoteMethod(self: *KlippyCtx, io: std.Io, method: []const u8, frame: std.json.Value) !void {
        const params: std.json.Value = if (frame == .object) frame.object.get("params") orelse .null else .null;
        if (std.mem.eql(u8, method, "process_status_update") or std.mem.eql(u8, method, "notify_status_update")) {
            try self.processStatusUpdate(io, params);
        } else if (std.mem.eql(u8, method, "process_gcode_response") or std.mem.eql(u8, method, "notify_gcode_response")) {
            try self.emitGcodeResponse(io, params);
        } else if (self.remote_handler) |handler| {
            try handler(self.remote_handler_ctx orelse return, std.heap.smp_allocator, method, params);
        }
    }

    /// Process `process_status_update` params (Core held): track
    /// `webhooks.state`, fan out per object, feed job state, OctoPrint and the
    /// temperature store.
    fn processStatusUpdate(self: *KlippyCtx, io: std.Io, params: std.json.Value) !void {
        // Klippy sends params as an OBJECT: {"eventtime": t, "status": {obj:{..}}}.
        // Clients receive the array shape [status, eventtime] built below.
        if (params != .object) return;
        const eventtime: std.json.Value = params.object.get("eventtime") orelse .{ .float = 0 };
        const status_dict = params.object.get("status") orelse return;
        if (status_dict != .object) return;

        if (status_dict.object.get("webhooks")) |wh| {
            const st: std.json.Value = if (wh == .object) wh.object.get("state") orelse .null else .null;
            if (st == .string) {
                if (klippy_state_map.get(st.string)) |new_state| {
                    // Moonraker defers a shutdown seen during the handshake.
                    const changed = self.setState(new_state);
                    if (changed and self.isConnected()) {
                        if (new_state == .shutdown) {
                            self.shutdownLocked(io);
                        } else if (self.on_state) |callback| if (self.event_ctx) |ctx| callback(ctx, io, new_state);
                    }
                }
            }
        }

        if (self.on_status) |callback| if (self.event_ctx) |ctx| callback(ctx, io, status_dict, eventtime);

        // Reuse one map + array across objects: emit copies params into its
        // own frame, so the scaffolding can be recycled.
        const scratch = std.heap.smp_allocator;
        var per_obj_map: std.json.ObjectMap = .empty;
        defer per_obj_map.deinit(scratch);
        var params_arr: std.json.Array = .init(scratch);
        defer params_arr.deinit();

        var it = status_dict.object.iterator();
        while (it.next()) |entry| {
            const obj_name = entry.key_ptr.*;
            per_obj_map.clearRetainingCapacity();
            try per_obj_map.put(scratch, obj_name, entry.value_ptr.*);
            params_arr.clearRetainingCapacity();
            try params_arr.append(.{ .object = per_obj_map });
            try params_arr.append(eventtime);
            _ = self.bus.emitStatusLocked(io, notify.names.status_update, .{ .array = params_arr }, obj_name) catch {};

            // Any object with a numeric `temperature` is a heater, sensor or fan.
            if (self.temp_store) |ts| {
                if (entry.value_ptr.* == .object) {
                    const od = entry.value_ptr.object;
                    ts.pushTemp(io, obj_name, numField(od, "temperature"), numField(od, "target"), numField(od, "power"), numField(od, "speed"));
                }
            }
        }

        if (status_dict.object.get("print_stats")) |ps| {
            if (self.job_state) |js| js.statusUpdate(ps);
            if (self.octoprint) |oc| oc.statusUpdate(ps);
        }
    }

    /// Emit a `notify_gcode_response` (Core held). Klippy's params are the
    /// kwarg object `{"response": "..."}`; Moonraker forwards only the string,
    /// so clients get `[response]`. String responses also enter the gcode
    /// store (data_store.py `_update_gcode_store`).
    fn emitGcodeResponse(self: *KlippyCtx, io: std.Io, params: std.json.Value) !void {
        if (self.on_gcode) |callback| if (self.event_ctx) |ctx| callback(ctx, io, params);
        const resp: std.json.Value = switch (params) {
            .array => return self.bus.emitLocked(io, notify.names.gcode_response, params),
            .object => params.object.get("response") orelse return,
            .null => return,
            else => params,
        };
        if (resp == .string) {
            if (self.temp_store) |ts| try ts.pushGcodeResponse(resp.string, clock.wallSeconds(io));
        }
        var arr: std.json.Array = .init(std.heap.smp_allocator);
        defer arr.deinit();
        try arr.append(resp);
        try self.bus.emitLocked(io, notify.names.gcode_response, .{ .array = arr });
    }

    // -----------------------------------------------------------------------
    // I/O primitives
    // -----------------------------------------------------------------------

    /// Write a framed message to the Klippy socket.
    fn writeFrame(self: *KlippyCtx, io: std.Io, payload: []const u8) !void {
        self.write_mutex.lockUncancelable(io);
        defer self.write_mutex.unlock(io);
        const stream = self.stream orelse return error.KlippyDisconnected;
        var deadline: SocketDeadline = .{ .base_io = io, .timeout = .{ .deadline = .fromNow(io, .{ .raw = write_timeout, .clock = .awake }) } };
        var wbuf: [4096]u8 = undefined;
        var w = stream.writer(deadline.io(), &wbuf);
        try framing.write(&w.interface, payload);
        try w.interface.flush();
    }

    /// Read one framed payload (gpa-owned). Klippy task only.
    fn readFrame(self: *KlippyCtx) ![]u8 {
        const reader = if (self.reader) |*r| r else return error.KlippyDisconnected;
        return framing.read(self.gpa, &reader.interface);
    }

    fn nextId(self: *KlippyCtx, io: std.Io) u64 {
        self.next_id_mutex.lockUncancelable(io);
        defer self.next_id_mutex.unlock(io);
        self.next_id += 1;
        return self.next_id;
    }

    /// Send one request and wait for its response. `release` is the Core lock
    /// the caller holds: it is dropped for the write and wait so the reader can dispatch
    /// pushes, and retaken before returning. The result lives in `alloc`.
    fn call(
        self: *KlippyCtx,
        method: []const u8,
        params_json: []const u8,
        release: ?*server_core.Core,
        timeout: std.Io.Timeout,
        alloc: std.mem.Allocator,
    ) !std.json.Value {
        const io = self.io orelse return error.KlippyDisconnected;
        const deadline = timeout.toDeadline(io);
        const id = self.nextId(io);
        var waiter: Waiter = .{};
        {
            self.pending_mutex.lockUncancelable(io);
            defer self.pending_mutex.unlock(io);
            if (!self.connected.load(.acquire)) return error.KlippyDisconnected;
            try self.pending.put(self.gpa, id, &waiter);
        }
        defer {
            self.pending_mutex.lockUncancelable(io);
            _ = self.pending.remove(id);
            self.pending_mutex.unlock(io);
            if (waiter.payload) |p| self.gpa.free(p);
        }

        const frame = try formatRequest(alloc, method, id, params_json);
        defer alloc.free(frame);
        {
            if (release) |core| core.unlock(io);
            defer if (release) |core| core.lock(io);
            try self.writeFrame(io, frame);
            waiter.sem.waitTimeout(io, deadline) catch |err| switch (err) {
                error.Timeout => return error.KlippyRequestTimedOut,
                error.Canceled => return error.Canceled,
            };
        }
        if (waiter.payload) |payload| return parseKlippyResult(alloc, payload);
        return if (waiter.failed) error.KlippyDisconnected else error.OutOfMemory;
    }

    /// Send a request from a handler that holds Core and return the result.
    /// Core is released while waiting (see `call`).
    pub fn request(self: *KlippyCtx, method: []const u8, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
        try self.recordGcodeCommand(method, params);
        const params_json = try serializeParams(alloc, params);
        defer if (params_json.len > 0) alloc.free(params_json);
        return self.call(method, params_json, self.bus.core, .none, alloc);
    }

    /// `request` for callers that do NOT hold Core (off-Core proxies, the job
    /// queue worker).
    pub fn requestOffCore(self: *KlippyCtx, method: []const u8, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
        if (self.io) |io| try self.bus.core.run(io, recordGcodeCommand, .{ self, method, params });
        const params_json = try serializeParams(alloc, params);
        defer if (params_json.len > 0) alloc.free(params_json);
        return self.call(method, params_json, null, .none, alloc);
    }

    /// Store a non-empty `gcode/script` script as a gcode store command
    /// (klippy_connection.py `gcode_received`). Core held: the store is read
    /// under Core.
    fn recordGcodeCommand(self: *KlippyCtx, method: []const u8, params: std.json.Value) !void {
        if (!std.mem.eql(u8, method, "gcode/script") or params != .object) return;
        const ts = self.temp_store orelse return;
        const io = self.io orelse return;
        const script = params.object.get("script") orelse return;
        if (script == .string) try ts.pushGcodeCommand(script.string, clock.wallSeconds(io));
    }

    /// Replace one client's subscription and resubscribe Klippy to the active
    /// aggregate. Return only its requested fields. Called off Core; serialized
    /// with other subscription requests and bounded to Moonraker's 20 seconds.
    pub fn subscribe(self: *KlippyCtx, conn: *connections.Connection, objects: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
        const io = self.io orelse return error.KlippyDisconnected;
        try self.subscribe_mutex.lock(io);
        defer self.subscribe_mutex.unlock(io);
        if (!self.isConnected()) return error.KlippyDisconnected;
        try self.bus.conns.replaceSubscriptions(io, conn, objects);
        const params_json = try self.buildSubscribeParams(io, alloc);
        defer alloc.free(params_json);
        var result = try self.call("objects/subscribe", params_json, null, .{ .duration = .{ .raw = .fromSeconds(20), .clock = .awake } }, alloc);
        if (result == .object) if (result.object.getPtr("status")) |status| {
            status.* = try connections.filterStatus(alloc, objects.object, status.*, true);
        };
        return result;
    }

    /// Resubscribe after an internal component adds objects. Caller is off Core.
    pub fn refreshSubscriptions(self: *KlippyCtx, alloc: std.mem.Allocator) !void {
        const io = self.io orelse return error.KlippyDisconnected;
        try self.subscribe_mutex.lock(io);
        defer self.subscribe_mutex.unlock(io);
        const params = try self.buildSubscribeParams(io, alloc);
        defer alloc.free(params);
        const result = try self.call("objects/subscribe", params, null, .{ .duration = .{ .raw = .fromSeconds(20), .clock = .awake } }, alloc);
        self.bus.core.run(io, seedSubscribedStatusLocked, .{ self, io, result });
    }

    /// Send a request without waiting for its response. Used for Feather
    /// replies from inside the reader, where waiting would deadlock.
    pub fn postMethod(self: *KlippyCtx, method: []const u8, params: std.json.Value, alloc: std.mem.Allocator) !void {
        const io = self.io orelse return error.KlippyDisconnected;
        const params_json = try serializeParams(alloc, params);
        defer if (params_json.len > 0) alloc.free(params_json);
        const frame = try formatRequest(alloc, method, self.nextId(io), params_json);
        defer alloc.free(frame);
        try self.writeFrame(io, frame);
    }

    /// Set `state` and mirror it into `server.info`, where `klippy_connected`
    /// means the socket is open (Moonraker `is_connected`). Returns false when
    /// unchanged.
    fn setState(self: *KlippyCtx, new_state: State) bool {
        if (self.state == new_state) return false;
        self.state = new_state;
        if (self.server_info) |info| {
            if (self.io) |io| info.state_mutex.lockUncancelable(io);
            defer if (self.io) |io| info.state_mutex.unlock(io);
            info.klippy_connected = new_state != .disconnected;
            info.klippy_state = @tagName(new_state);
        }
        return true;
    }

    // -----------------------------------------------------------------------
    // Moonraker server events (Core held)
    // -----------------------------------------------------------------------

    /// `server:klippy_disconnect`: notify clients, mark the active job errored
    /// and finish it as `klippy_disconnect`.
    fn disconnectedLocked(self: *KlippyCtx, io: std.Io) void {
        if (self.on_state) |callback| if (self.event_ctx) |ctx| callback(ctx, io, .disconnected);
        self.bus.emitLocked(io, notify.names.klippy_disconnected, .null) catch {};
        if (self.job_state) |js| {
            js.handleDisconnect();
            if (self.history) |h| h.handleKlippyDisconnect(js.getLastStats());
        }
        if (self.octoprint) |oc| oc.setKlippyDisconnected();
    }

    /// `server:klippy_shutdown`: notify clients and finish the active job as
    /// `klippy_shutdown`.
    fn shutdownLocked(self: *KlippyCtx, io: std.Io) void {
        if (self.on_state) |callback| if (self.event_ctx) |ctx| callback(ctx, io, .shutdown);
        self.bus.emitLocked(io, notify.names.klippy_shutdown, .null) catch {};
        if (self.history) |h| {
            if (self.job_state) |js| h.handleKlippyShutdown(js.getLastStats());
        }
    }
};

// ===========================================================================
// Test helpers
// ===========================================================================

// NullBus must not be moved after init (contains self-referential pointers).
const NullBus = struct {
    core: server_core.Core,
    conns_obj: @import("../server/connections.zig").Connections,
    bus: notify.NotifyBus,

    /// Heap-allocated so internal pointers (bus → conns_obj) stay valid
    /// after the struct leaves this function's stack frame.
    fn init(alloc: std.mem.Allocator) !*NullBus {
        const nb = try alloc.create(NullBus);
        errdefer alloc.destroy(nb);
        nb.core = server_core.Core.init();
        nb.conns_obj = @import("../server/connections.zig").Connections.init(alloc, &nb.core);
        nb.bus = notify.NotifyBus.init(&nb.core, &nb.conns_obj);
        return nb;
    }

    fn deinit(self: *NullBus, alloc: std.mem.Allocator) void {
        self.conns_obj.list.deinit(self.conns_obj.alloc);
        alloc.destroy(self);
    }
};

/// `name` inside `tmp`, relative to the cwd (short enough for `sun_path`).
fn tmpSocketPath(buf: []u8, tmp: *const std.testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path, name });
}

/// Counts notification frames containing `needle` written to one connection.
const NotifyCounter = struct {
    needle: []const u8,
    count: std.atomic.Value(u32) = .init(0),
    fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *NotifyCounter = @ptrCast(@alignCast(ctx));
        if (std.mem.indexOf(u8, bytes, self.needle) != null) _ = self.count.fetchAdd(1, .monotonic);
    }
};

// ===========================================================================
// Tests: context lifecycle and subscriptions
// ===========================================================================

test "KlippyCtx.init: starts disconnected" {
    const alloc = std.testing.allocator;
    const nb = try NullBus.init(alloc);
    defer nb.deinit(alloc);
    var ctx = try KlippyCtx.init(alloc, &nb.bus);
    defer ctx.deinit();
    try std.testing.expect(!ctx.isConnected());
    try std.testing.expectEqual(State.disconnected, ctx.state);
}

test "buildSubscribeParams: base set, deduped extras and response_template" {
    const alloc = std.testing.allocator;
    const nb = try NullBus.init(alloc);
    defer nb.deinit(alloc);
    var ctx = try KlippyCtx.init(alloc, &nb.bus);
    defer ctx.deinit();
    ctx.io = std.testing.io;

    try ctx.addSubscriptionObject("extruder");
    try ctx.addSubscriptionObject("extruder");
    try ctx.addSubscriptionObject("heater_bed");
    try ctx.addSubscriptionObject("print_stats");

    const raw = try ctx.buildSubscribeParams(std.testing.io, alloc);
    defer alloc.free(raw);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    const objects = parsed.value.object.get("objects").?.object;
    try std.testing.expectEqual(@as(usize, 5), objects.count());
    for ([_][]const u8{ "webhooks", "toolhead", "print_stats", "extruder", "heater_bed" }) |name| {
        try std.testing.expect(objects.get(name).? == .null);
    }
    try std.testing.expectEqualStrings("process_status_update", parsed.value.object.get("response_template").?.object.get("method").?.string);
}

test "addSubscriptionObject escapes client names and bounds the set" {
    const alloc = std.testing.allocator;
    const nb = try NullBus.init(alloc);
    defer nb.deinit(alloc);
    var ctx = try KlippyCtx.init(alloc, &nb.bus);
    defer ctx.deinit();
    ctx.io = std.testing.io;

    const hostile = "x\":null},\"response_template\":{\"method\":\"evil";
    try ctx.addSubscriptionObject(hostile);
    try ctx.addSubscriptionObject("back\\slash\n");
    const raw = try ctx.buildSubscribeParams(std.testing.io, alloc);
    defer alloc.free(raw);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    const objects = parsed.value.object.get("objects").?.object;
    try std.testing.expect(objects.contains(hostile));
    try std.testing.expect(objects.contains("back\\slash\n"));
    try std.testing.expectEqualStrings("process_status_update", parsed.value.object.get("response_template").?.object.get("method").?.string);

    const long: [max_sub_object_name_len + 1]u8 = @splat('a');
    try std.testing.expectError(error.InvalidParams, ctx.addSubscriptionObject(&long));
    var buf: [16]u8 = undefined;
    var i: usize = ctx.extra_sub_objects.count();
    while (i < max_sub_objects) : (i += 1) {
        try ctx.addSubscriptionObject(try std.fmt.bufPrint(&buf, "obj{d}", .{i}));
    }
    try std.testing.expectError(error.TooManyObjects, ctx.addSubscriptionObject("one_more"));
    // Already-present names stay accepted when the set is full.
    try ctx.addSubscriptionObject("obj5");
}

test "fuzz addSubscriptionObject + buildSubscribeParams: valid JSON, names round-trip" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const alloc = std.testing.allocator;
            const nb = try NullBus.init(alloc);
            defer nb.deinit(alloc);
            var ctx = try KlippyCtx.init(alloc, &nb.bus);
            defer ctx.deinit();
            ctx.io = std.testing.io;
            var name: [12]u8 = undefined;
            smith.bytesWithHash(&name, 0);
            // Client names come from parsed JSON keys, so they are valid UTF-8.
            if (!std.unicode.utf8ValidateSlice(&name)) return;
            try ctx.addSubscriptionObject(&name);
            const j = try ctx.buildSubscribeParams(std.testing.io, alloc);
            defer alloc.free(j);
            const p = try std.json.parseFromSlice(std.json.Value, alloc, j, .{});
            defer p.deinit();
            try std.testing.expect(p.value.object.get("objects").?.object.contains(&name));
        }
    }.run, .{});
}

test "KlippyCtx.nextId: monotonic" {
    const alloc = std.testing.allocator;
    const nb = try NullBus.init(alloc);
    defer nb.deinit(alloc);
    var ctx = try KlippyCtx.init(alloc, &nb.bus);
    defer ctx.deinit();
    try std.testing.expectEqual(@as(u64, 1), ctx.nextId(std.testing.io));
    try std.testing.expectEqual(@as(u64, 2), ctx.nextId(std.testing.io));
}

// ===========================================================================
// Tests: builders and parsing
// ===========================================================================

test "formatRequest: string id and params" {
    const alloc = std.testing.allocator;
    const got = try formatRequest(alloc, "objects/list", 1, "[\"gcode\"]");
    defer alloc.free(got);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"objects/list\",\"id\":\"1\",\"params\":[\"gcode\"]}", got);
    const empty = try formatRequest(alloc, "info", 42, "");
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"info\",\"id\":\"42\",\"params\":{}}", empty);
}

test "fuzz formatRequest: valid JSON for any JSON params and id" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const alloc = std.testing.allocator;
            var raw: [8]u8 = undefined;
            smith.bytesWithHash(&raw, 0);
            const id = std.mem.readInt(u64, &raw, .little);
            const params = [_][]const u8{ "", "{}", "[1,2]", "{\"a\":\"\\\"\"}", "null" };
            const got = try formatRequest(alloc, "gcode/script", id, params[raw[0] % params.len]);
            defer alloc.free(got);
            const p = try std.json.parseFromSlice(std.json.Value, alloc, got, .{});
            defer p.deinit();
            try std.testing.expect(frameIdMatches(alloc, got, id));
        }
    }.run, .{});
}

test "collectHeaterNames reads sensors and ignores null monitors" {
    const alloc = std.testing.allocator;
    const raw =
        \\{"eventtime":1,"status":{"heaters":{"available_sensors":["extruder","heater_bed","temperature_sensor weightValue"],"available_monitors":null}}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    var sensors: std.ArrayList([]const u8) = .empty;
    defer sensors.deinit(alloc);
    var monitors: std.ArrayList([]const u8) = .empty;
    defer monitors.deinit(alloc);
    try collectHeaterNames(parsed.value, "available_sensors", alloc, &sensors);
    try collectHeaterNames(parsed.value, "available_monitors", alloc, &monitors);
    try std.testing.expectEqual(@as(usize, 3), sensors.items.len);
    try std.testing.expectEqualStrings("temperature_sensor weightValue", sensors.items[2]);
    try std.testing.expectEqual(@as(usize, 0), monitors.items.len);
}

test "frameIdMatches does not accept a longer id" {
    const a = std.testing.allocator;
    try std.testing.expect(frameIdMatches(a, "{\"id\":\"12\",\"result\":1}", 12));
    try std.testing.expect(!frameIdMatches(a, "{\"id\":\"12\",\"result\":1}", 1));
    try std.testing.expect(frameIdMatches(a, "{\"id\" : \"12\",\"result\":1}", 12));
    try std.testing.expect(!frameIdMatches(a, "{\"result\":{\"id\":\"12\"}}", 12));
    try std.testing.expect(!frameIdMatches(a, "{\"id\":12}", 12));
}

test "fuzz frameIdMatches reads only the root JSON string id" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            const a = std.testing.allocator;
            const id = smith.valueRangeAtMostWithHash(u64, 0, std.math.maxInt(u64), 0);
            const root = try std.fmt.allocPrint(a, "{{\"id\" : \"{d}\"}}", .{id});
            defer a.free(root);
            try std.testing.expect(frameIdMatches(a, root, id));
            const nested = try std.fmt.allocPrint(a, "{{\"params\":{{\"id\":\"{d}\"}}}}", .{id});
            defer a.free(nested);
            try std.testing.expect(!frameIdMatches(a, nested, id));
        }
    }.run, .{});
}

test "parseKlippyState maps every Klippy state" {
    const cases = [_]struct { json: []const u8, state: ?State }{
        .{ .json = "{\"state\":\"ready\"}", .state = .ready },
        .{ .json = "{\"state\":\"startup\"}", .state = .startup },
        .{ .json = "{\"state\":\"shutdown\"}", .state = .shutdown },
        .{ .json = "{\"state\":\"error\"}", .state = .@"error" },
        .{ .json = "{\"state\":\"bogus\"}", .state = null },
        .{ .json = "{\"state\":1}", .state = null },
        .{ .json = "{}", .state = null },
        .{ .json = "\"ready\"", .state = null },
    };
    for (cases) |c| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, c.json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(c.state, parseKlippyState(parsed.value));
    }
}

test "fuzz parseKlippyState: never crashes on arbitrary JSON" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var json_bytes: [256]u8 = undefined;
            smith.bytesWithHash(&json_bytes, 0);
            const parsed = std.json.parseFromSlice(std.json.Value, std.testing.allocator, &json_bytes, .{}) catch return;
            defer parsed.deinit();
            _ = parseKlippyState(parsed.value);
        }
    }.run, .{});
}

test "parseKlippyResult copies strings (no use-after-free on the freed payload)" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const payload = try a.dupe(u8, "{\"result\":{\"msg\":\"hello world\",\"state\":\"ready\"}}");
    defer a.free(payload);
    const result = try parseKlippyResult(arena.allocator(), payload);
    @memset(payload, 'X'); // would corrupt an aliasing result
    try std.testing.expectEqualStrings("hello world", result.object.get("msg").?.string);
    try std.testing.expectEqualStrings("ready", result.object.get("state").?.string);
}

test "Klippy frames reject values deeper than the serialization bound" {
    const depth = jv.max_value_depth + 1;
    const nested = @as([depth]u8, @splat('[')) ++ "0" ++ @as([depth]u8, @splat(']'));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidFrame, parseKlippyResult(arena.allocator(), "{\"result\":" ++ nested ++ "}"));
    const nb = try NullBus.init(std.testing.allocator);
    defer nb.deinit(std.testing.allocator);
    var ctx = try KlippyCtx.init(std.testing.allocator, &nb.bus);
    defer ctx.deinit();
    try std.testing.expectError(error.InvalidFrame, ctx.dispatchFrame(std.testing.io, "{\"method\":\"process_gcode_response\",\"params\":" ++ nested ++ "}"));
}

test "serializeParams rejects pathologically deep params (guards the Stringify nesting stack)" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();
    var v: std.json.Value = .{ .integer = 1 };
    for (0..400) |_| {
        var arr: std.json.Array = .init(al);
        try arr.append(v);
        v = .{ .array = arr };
    }
    try std.testing.expectError(error.InvalidParams, serializeParams(al, v));
    var o: std.json.ObjectMap = .empty;
    try o.put(al, "x", .{ .integer = 1 });
    try std.testing.expectEqualStrings("{\"x\":1}", try serializeParams(al, .{ .object = o }));
}

// ===========================================================================
// Tests: state and dispatch
// ===========================================================================

test "setState mirrors Moonraker klippy_connected and klippy_state" {
    const alloc = std.testing.allocator;
    const nb = try NullBus.init(alloc);
    defer nb.deinit(alloc);
    var ctx = try KlippyCtx.init(alloc, &nb.bus);
    defer ctx.deinit();
    var info: methods.ServerInfo = .{};
    ctx.server_info = &info;

    try std.testing.expect(ctx.setState(.shutdown));
    try std.testing.expect(!ctx.setState(.shutdown));
    try std.testing.expect(info.klippy_connected);
    try std.testing.expectEqualStrings("shutdown", info.klippy_state);
    try std.testing.expect(ctx.setState(.@"error"));
    try std.testing.expectEqualStrings("error", info.klippy_state);
    try std.testing.expect(ctx.setState(.disconnected));
    try std.testing.expect(!info.klippy_connected);
}

fn statusParams(a: std.mem.Allocator, webhooks_state: []const u8) !std.json.Value {
    var sd: std.json.ObjectMap = .empty;
    var wh: std.json.ObjectMap = .empty;
    try wh.put(a, "state", .{ .string = webhooks_state });
    try sd.put(a, "webhooks", .{ .object = wh });
    var pobj: std.json.ObjectMap = .empty;
    try pobj.put(a, "eventtime", .{ .float = 0.0 });
    try pobj.put(a, "status", .{ .object = sd });
    return .{ .object = pobj };
}

test "processStatusUpdate: live shutdown sets state and emits once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nb = try NullBus.init(a);
    defer nb.deinit(a);
    var ctx = try KlippyCtx.init(a, &nb.bus);
    defer ctx.deinit();
    const io = std.testing.io;
    var counter = NotifyCounter{ .needle = "notify_klippy_shutdown" };
    const conn = try nb.conns_obj.add(io, false);
    nb.conns_obj.attachWriter(io, conn, &counter, NotifyCounter.write);

    _ = ctx.setState(.ready);
    ctx.connected.store(true, .release);
    const params = try statusParams(a, "shutdown");
    try ctx.processStatusUpdate(io, params);
    try ctx.processStatusUpdate(io, params);
    try std.testing.expectEqual(State.shutdown, ctx.state);
    try std.testing.expectEqual(@as(u32, 1), counter.count.load(.monotonic));

    try ctx.processStatusUpdate(io, try statusParams(a, "ready"));
    try std.testing.expectEqual(State.ready, ctx.state);
}

test "Klippy component hooks see initial status, pushes, state and gcode" {
    const Capture = struct {
        status_count: usize = 0,
        shutdown_count: usize = 0,
        disconnected_count: usize = 0,
        gcode_count: usize = 0,
        fn state(raw: *anyopaque, _: std.Io, value: State) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (value == .shutdown) self.shutdown_count += 1;
            if (value == .disconnected) self.disconnected_count += 1;
        }
        fn status(raw: *anyopaque, _: std.Io, value: std.json.Value, time: std.json.Value) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(value == .object and time == .float);
            self.status_count += 1;
        }
        fn gcode(raw: *anyopaque, _: std.Io, value: std.json.Value) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(value == .object);
            self.gcode_count += 1;
        }
    };
    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const a = req_arena.allocator();
    const nb = try NullBus.init(a);
    defer nb.deinit(a);
    var ctx = try KlippyCtx.init(a, &nb.bus);
    defer ctx.deinit();
    var capture = Capture{};
    ctx.event_ctx = &capture;
    ctx.on_state = Capture.state;
    ctx.on_status = Capture.status;
    ctx.on_gcode = Capture.gcode;
    ctx.seedSubscribedStatus(std.testing.io, "{\"result\":{\"status\":{\"toolhead\":{\"position\":[0,0,0,2]}},\"eventtime\":1.5}}");
    _ = ctx.setState(.ready);
    ctx.connected.store(true, .release);
    const params = try statusParams(a, "shutdown");
    try ctx.processStatusUpdate(std.testing.io, params);
    try ctx.processStatusUpdate(std.testing.io, params);
    try ctx.dispatchRemoteMethod(std.testing.io, "process_gcode_response", try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"params\":{\"response\":\"ok\"}}", .{}));
    ctx.disconnectedLocked(std.testing.io);
    try std.testing.expectEqual(@as(usize, 3), capture.status_count);
    try std.testing.expectEqual(@as(usize, 1), capture.shutdown_count);
    try std.testing.expectEqual(@as(usize, 1), capture.disconnected_count);
    try std.testing.expectEqual(@as(usize, 1), capture.gcode_count);
}

test "gcode scripts and responses enter the gcode store like data_store.py" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nb = try NullBus.init(a);
    defer nb.deinit(a);
    var ctx = try KlippyCtx.init(a, &nb.bus);
    defer ctx.deinit();
    var store = try @import("data_store.zig").DataStoreCtx.init(std.testing.allocator);
    defer store.deinit();
    const io = std.testing.io;
    ctx.io = io;
    ctx.temp_store = &store;

    var params: std.json.ObjectMap = .empty;
    try params.put(a, "script", .{ .string = "G28" });
    try ctx.recordGcodeCommand("gcode/script", .{ .object = params });
    // Blank scripts and other methods are not stored.
    var blank: std.json.ObjectMap = .empty;
    try blank.put(a, "script", .{ .string = "  " });
    try ctx.recordGcodeCommand("gcode/script", .{ .object = blank });
    try ctx.recordGcodeCommand("info", .{ .object = params });
    var resp: std.json.ObjectMap = .empty;
    try resp.put(a, "response", .{ .string = "ok" });
    try ctx.emitGcodeResponse(io, .{ .object = resp });

    var out: [4]@import("data_store.zig").GcodeEntry = undefined;
    const n = store.gcode_ring.copyAll(&out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("G28", out[0].message);
    try std.testing.expectEqual(.command, out[0].type);
    try std.testing.expectEqualStrings("ok", out[1].message);
    try std.testing.expectEqual(.response, out[1].type);
}

test "processStatusUpdate: malformed params return early" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nb = try NullBus.init(a);
    defer nb.deinit(a);
    var ctx = try KlippyCtx.init(a, &nb.bus);
    defer ctx.deinit();
    const io = std.testing.io;

    var arr = std.json.Array.init(a);
    try arr.append(.{ .float = 0.0 });
    try arr.append(.{ .string = "not-an-object" });
    try ctx.processStatusUpdate(io, .{ .array = arr });
    try ctx.processStatusUpdate(io, .{ .object = .empty });
    try ctx.processStatusUpdate(io, try statusParams(a, "bogus"));
    try std.testing.expectEqual(State.disconnected, ctx.state);
}

// Capturing connection sink: records the last notification bytes written.
const GcodeCapture = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,
    fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *GcodeCapture = @ptrCast(@alignCast(ctx));
        const n = @min(bytes.len, self.buf.len);
        @memcpy(self.buf[0..n], bytes[0..n]);
        self.len = n;
    }
    fn slice(self: *const GcodeCapture) []const u8 {
        return self.buf[0..self.len];
    }
};

test "process_gcode_response: forwards the response STRING as a [response] array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nb = try NullBus.init(a);
    defer nb.deinit(a);
    var ctx = try KlippyCtx.init(a, &nb.bus);
    defer ctx.deinit();
    const io = std.testing.io;

    var cap = GcodeCapture{};
    const conn = try nb.conns_obj.add(io, false);
    nb.conns_obj.attachWriter(io, conn, &cap, GcodeCapture.write);

    var pobj: std.json.ObjectMap = .empty;
    try pobj.put(a, "response", .{ .string = "// ok" });
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "params", .{ .object = pobj });
    try ctx.dispatchRemoteMethod(io, "process_gcode_response", .{ .object = obj });

    try std.testing.expect(std.mem.indexOf(u8, cap.slice(), "\"method\":\"notify_gcode_response\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.slice(), "\"params\":[\"// ok\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.slice(), "\"response\"") == null);

    // Missing params and a non-object frame emit nothing and do not crash.
    cap.len = 0;
    try ctx.dispatchRemoteMethod(io, "process_gcode_response", .{ .object = .empty });
    try ctx.dispatchRemoteMethod(io, "process_gcode_response", .null);
    try std.testing.expectEqual(@as(usize, 0), cap.len);
}

test "dispatchFrame rejects non-object roots and non-string methods" {
    const alloc = std.testing.allocator;
    const nb = try NullBus.init(alloc);
    defer nb.deinit(alloc);
    var ctx = try KlippyCtx.init(alloc, &nb.bus);
    defer ctx.deinit();
    for ([_][]const u8{ "[]", "null", "42", "{\"method\":4}", "{\"method\":null}" }) |wire| {
        try std.testing.expectError(error.InvalidFrame, ctx.dispatchFrame(std.testing.io, wire));
    }
    // Responses nobody waits for are dropped.
    try ctx.dispatchFrame(std.testing.io, "{\"id\":\"7\",\"result\":{}}");
    try ctx.dispatchFrame(std.testing.io, "{\"id\":7,\"result\":{}}");
}

test "fuzz dispatchFrame: arbitrary frames never crash" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const alloc = std.testing.allocator;
            const nb = try NullBus.init(alloc);
            defer nb.deinit(alloc);
            var ctx = try KlippyCtx.init(alloc, &nb.bus);
            defer ctx.deinit();
            const frames = [_][]const u8{
                "{\"method\":\"process_status_update\",\"params\":{\"eventtime\":1,\"status\":{\"webhooks\":{\"state\":\"shutdown\"}}}}",
                "{\"method\":\"process_status_update\",\"params\":[1,{}]}",
                "{\"method\":\"process_gcode_response\",\"params\":{\"response\":7}}",
                "{\"method\":\"unknown\",\"id\":\"3\"}",
                "{\"id\":\"18446744073709551616\",\"result\":null}",
            };
            var b: [1]u8 = undefined;
            smith.bytesWithHash(&b, 0);
            ctx.dispatchFrame(std.testing.io, frames[b[0] % frames.len]) catch {};
        }
    }.run, .{});
}

test "subscription snapshots seed owned print state" {
    const alloc = std.testing.allocator;
    const nb = try NullBus.init(alloc);
    defer nb.deinit(alloc);
    var js = @import("job_state.zig").JobStateCtx.init(alloc);
    defer js.deinit();
    var ctx = try KlippyCtx.init(alloc, &nb.bus);
    defer ctx.deinit();
    ctx.job_state = &js;
    ctx.seedSubscribedStatus(std.testing.io,
        \\{"id":"2","result":{"status":{"print_stats":{"state":"printing","filename":"benchy.gcode"}}}}
    );
    try std.testing.expect(js.isActive());
    try std.testing.expectEqualStrings("benchy.gcode", js.getLastStats().get("filename").?.string);
    try std.testing.expectEqual(@import("job_state.zig").JobEvent.standby, js.getLastEvent());
}

// ===========================================================================
// Tests: sockets
// ===========================================================================

test "postMethod sends a frame without waiting for a reply" {
    const aio = std.testing.io;
    var server = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(aio, .{});
    defer server.deinit(aio);
    const stream = try server.socket.address.connect(aio, .{ .mode = .stream });
    const peer = try server.accept(aio);
    defer peer.close(aio);
    const nb = try NullBus.init(std.testing.allocator);
    defer nb.deinit(std.testing.allocator);
    var ctx = try KlippyCtx.init(std.testing.allocator, &nb.bus);
    defer ctx.deinit();
    ctx.io = aio;
    ctx.stream = stream;
    try ctx.postMethod("feather/update_status", .null, std.testing.allocator);
    var buf: [512]u8 = undefined;
    var reader = peer.reader(aio, &buf);
    const wire = try reader.interface.takeDelimiterInclusive(framing.delimiter);
    const frame = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, wire[0 .. wire.len - 1], .{});
    defer frame.deinit();
    try std.testing.expectEqualStrings("feather/update_status", frame.value.object.get("method").?.string);
}

test "requests are refused once waiters are failed, without writing" {
    const aio = std.testing.io;
    var server = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(aio, .{});
    defer server.deinit(aio);
    const stream = try server.socket.address.connect(aio, .{ .mode = .stream });
    const peer = try server.accept(aio);
    defer peer.close(aio);
    const nb = try NullBus.init(std.testing.allocator);
    defer nb.deinit(std.testing.allocator);
    var ctx = try KlippyCtx.init(std.testing.allocator, &nb.bus);
    defer ctx.deinit();
    ctx.io = aio;
    ctx.stream = stream;
    ctx.connected.store(true, .release);
    ctx.failAllWaiters(aio);
    try std.testing.expect(!ctx.isConnected());
    try std.testing.expectError(error.KlippyDisconnected, ctx.requestOffCore("info", .null, std.testing.allocator));
    try std.testing.expectEqual(@as(u32, 0), ctx.pending.count());
}

test "request releases Core before a socket write needs the reader to drain" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const nb = try NullBus.init(alloc);
    defer nb.deinit(alloc);
    var ctx = try KlippyCtx.init(std.heap.smp_allocator, &nb.bus);
    defer ctx.deinit();
    ctx.setIo(io);
    var listener = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer listener.deinit(io);
    ctx.stream = try listener.socket.address.connect(io, .{ .mode = .stream });
    const peer = try listener.accept(io);
    defer peer.close(io);
    ctx.connected.store(true, .release);
    const Peer = struct {
        fn run(k: *KlippyCtx, stream: net.Stream) void {
            const aio = k.io.?;
            k.bus.core.lock(aio);
            k.bus.core.unlock(aio);
            var deadline: SocketDeadline = .{ .base_io = aio, .timeout = .{ .deadline = .fromNow(aio, .{ .raw = .fromSeconds(2), .clock = .awake }) } };
            var buffer: [4096]u8 = undefined;
            var reader = stream.reader(deadline.io(), &buffer);
            const frame = framing.read(std.heap.smp_allocator, &reader.interface) catch return;
            defer std.heap.smp_allocator.free(frame);
            k.dispatchFrame(aio, "{\"id\":\"1\",\"result\":\"ok\"}") catch {};
        }
    };
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const large = try a.alloc(u8, 8 * 1024 * 1024);
    @memset(large, 'x');
    var params: std.json.ObjectMap = .empty;
    try params.put(a, "data", .{ .string = large });
    nb.core.lock(io);
    var peer_task = try io.concurrent(Peer.run, .{ &ctx, peer });
    const result = ctx.request("info", .{ .object = params }, a);
    nb.core.unlock(io);
    // Wake a reader on a partial request when testing a failed write.
    if (result) |_| {} else |_| ctx.stream.?.shutdown(io, .both) catch {};
    peer_task.cancel(io);
    try std.testing.expectEqualStrings("ok", (try result).string);
}

test "subscribe returns requested fields and replaces the aggregate client set" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const nb = try NullBus.init(alloc);
    defer nb.deinit(alloc);
    const conn = try nb.conns_obj.add(io, false);
    defer nb.conns_obj.remove(io, conn);
    var ctx = try KlippyCtx.init(std.heap.smp_allocator, &nb.bus);
    defer ctx.deinit();
    ctx.setIo(io);
    var listener = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer listener.deinit(io);
    ctx.stream = try listener.socket.address.connect(io, .{ .mode = .stream });
    ctx.reader = ctx.stream.?.reader(io, &ctx.read_buffer);
    ctx.connected.store(true, .release);
    const peer = try listener.accept(io);
    defer peer.close(io);
    const Peer = struct {
        fn run(aio: std.Io, stream: net.Stream) !void {
            var deadline: SocketDeadline = .{ .base_io = aio, .timeout = .{ .deadline = .fromNow(aio, .{ .raw = .fromSeconds(2), .clock = .awake }) } };
            var buffer: [4096]u8 = undefined;
            var reader = stream.reader(deadline.io(), &buffer);
            var writer = stream.writer(deadline.io(), &.{});
            for (0..3) |iteration| {
                var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
                defer arena.deinit();
                const a = arena.allocator();
                const frame = try framing.read(a, &reader.interface);
                const request = try std.json.parseFromSliceLeaky(std.json.Value, a, frame, .{});
                const objects = request.object.get("params").?.object.get("objects").?.object;
                try std.testing.expectEqual(iteration == 0, objects.contains("extruder"));
                try std.testing.expectEqual(iteration >= 1, objects.contains("gcode_move"));
                try std.testing.expectEqual(iteration == 2, objects.contains("motion_report"));
                try std.testing.expect(objects.contains("webhooks"));
                const response = try std.fmt.allocPrint(
                    a,
                    "{{\"id\":\"{s}\",\"result\":{{\"eventtime\":1,\"status\":{{\"webhooks\":{{\"state\":\"ready\"}},\"toolhead\":{{\"position\":[1,2,3],\"velocity\":20}},\"extruder\":{{\"temperature\":21}},\"gcode_move\":{{\"speed_factor\":1}}}}}}}}",
                    .{request.object.get("id").?.string},
                );
                try framing.write(&writer.interface, response);
                try writer.interface.flush();
            }
        }
    };
    var peer_task = try io.concurrent(Peer.run, .{ io, peer });
    defer peer_task.cancel(io) catch {};
    var reader_task = try io.concurrent(KlippyCtx.readerLoop, .{ &ctx, io });
    defer reader_task.cancel(io) catch {};
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try ctx.subscribe(conn, try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"toolhead\":[\"position\"],\"extruder\":[]}", .{}), a);
    const status = first.object.get("status").?.object;
    try std.testing.expectEqual(@as(usize, 2), status.count());
    try std.testing.expectEqual(@as(usize, 1), status.get("toolhead").?.object.count());
    try std.testing.expect(status.get("toolhead").?.object.contains("position"));
    try std.testing.expectEqual(@as(usize, 0), status.get("extruder").?.object.count());
    const second = try ctx.subscribe(conn, try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"gcode_move\":null}", .{}), a);
    try std.testing.expectEqual(@as(usize, 1), second.object.get("status").?.object.count());
    try std.testing.expect(second.object.get("status").?.object.contains("gcode_move"));
    try std.testing.expectEqual(@as(usize, 0), ctx.extra_sub_objects.count());
    try ctx.addSubscriptionObject("motion_report");
    try ctx.refreshSubscriptions(a);
    try peer_task.await(io);
}

test "a timed request removes its waiter when Klippy never responds" {
    const io = std.testing.io;
    const nb = try NullBus.init(std.testing.allocator);
    defer nb.deinit(std.testing.allocator);
    var ctx = try KlippyCtx.init(std.testing.allocator, &nb.bus);
    defer ctx.deinit();
    ctx.setIo(io);
    var listener = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer listener.deinit(io);
    ctx.stream = try listener.socket.address.connect(io, .{ .mode = .stream });
    const peer = try listener.accept(io);
    defer peer.close(io);
    ctx.connected.store(true, .release);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.KlippyRequestTimedOut, ctx.call("info", "{}", null, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }, arena.allocator()));
    try std.testing.expectEqual(@as(u32, 0), ctx.pending.count());
}

/// Test-local Klippy: accepts one connection, answers `info` with `state`,
/// `objects/subscribe` with an empty status and anything else with `{}`,
/// records methods, and closes after `gcode/script`.
const FakeKlippy = struct {
    server: net.Server,
    state: []const u8,
    seen: [16][32]u8 = undefined,
    seen_len: [16]usize = @splat(0),
    seen_count: usize = 0,

    fn saw(self: *const FakeKlippy, method: []const u8) bool {
        for (0..self.seen_count) |i| {
            if (std.mem.eql(u8, self.seen[i][0..self.seen_len[i]], method)) return true;
        }
        return false;
    }

    fn run(self: *FakeKlippy, io: std.Io) !void {
        const stream = try self.server.accept(io);
        defer stream.close(io);
        var rbuf: [4096]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        var wbuf: [512]u8 = undefined;
        var writer = stream.writer(io, &wbuf);
        while (true) {
            const payload = try framing.read(std.testing.allocator, &reader.interface);
            defer std.testing.allocator.free(payload);
            const req = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
            defer req.deinit();
            const method = req.value.object.get("method").?.string;
            const id = req.value.object.get("id").?.string;
            if (self.seen_count < self.seen.len) {
                const n = @min(method.len, self.seen[0].len);
                @memcpy(self.seen[self.seen_count][0..n], method[0..n]);
                self.seen_len[self.seen_count] = n;
                self.seen_count += 1;
            }
            var out: [256]u8 = undefined;
            const resp = if (std.mem.eql(u8, method, "info"))
                try std.fmt.bufPrint(&out, "{{\"id\":\"{s}\",\"result\":{{\"state\":\"{s}\"}}}}", .{ id, self.state })
            else if (std.mem.eql(u8, method, "objects/subscribe"))
                try std.fmt.bufPrint(&out, "{{\"id\":\"{s}\",\"result\":{{\"eventtime\":1,\"status\":{{}}}}}}", .{id})
            else
                try std.fmt.bufPrint(&out, "{{\"id\":\"{s}\",\"result\":{{}}}}", .{id});
            try framing.write(&writer.interface, resp);
            try writer.interface.flush();
            if (std.mem.eql(u8, method, "gcode/script")) return;
        }
    }
};

test "Klippy shutdown keeps the connection, allows FIRMWARE_RESTART and disconnects once" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try tmpSocketPath(&path_buf, &tmp, "klippy.sock");

    const nb = try NullBus.init(alloc);
    defer nb.deinit(alloc);
    var counter = NotifyCounter{ .needle = "notify_klippy_disconnected" };
    const conn = try nb.conns_obj.add(io, false);
    defer nb.conns_obj.remove(io, conn);
    nb.conns_obj.attachWriter(io, conn, &counter, NotifyCounter.write);
    var info: methods.ServerInfo = .{};
    var ctx = try KlippyCtx.init(alloc, &nb.bus);
    defer ctx.deinit();
    ctx.setIo(io);
    ctx.uds_path = path;
    ctx.server_info = &info;
    ctx.remote_methods = &.{"feather_x"};

    const addr = try net.UnixAddress.init(path);
    var fake = FakeKlippy{ .server = try addr.listen(io, .{}), .state = "shutdown" };
    var fake_task = try io.concurrent(FakeKlippy.run, .{ &fake, io });
    try ctx.start();

    var waited: usize = 0;
    while (!ctx.isConnected() and waited < 500) : (waited += 1) try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    try std.testing.expect(ctx.isConnected());
    try std.testing.expectEqual(State.shutdown, ctx.state);
    try std.testing.expect(info.klippy_connected);
    try std.testing.expectEqualStrings("shutdown", info.klippy_state);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var params: std.json.ObjectMap = .empty;
    try params.put(arena.allocator(), "script", .{ .string = "FIRMWARE_RESTART" });
    const result = try ctx.requestOffCore("gcode/script", .{ .object = params }, arena.allocator());
    try std.testing.expect(result == .object);
    try fake_task.await(io);
    fake.server.deinit(io);
    try std.Io.Dir.cwd().deleteFile(io, path);

    // Methods are registered and heaters queried only when Klippy is ready.
    try std.testing.expect(fake.saw("gcode/subscribe_output"));
    try std.testing.expect(!fake.saw("register_remote_method"));
    try std.testing.expect(!fake.saw("objects/query"));

    // The closed connection is reported once; failed reconnects are silent.
    while (ctx.isConnected() and waited < 1000) : (waited += 1) try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    try std.Io.sleep(io, .fromMilliseconds(2500), .awake);
    try std.testing.expectEqual(@as(u32, 1), counter.count.load(.monotonic));
    try std.testing.expect(!info.klippy_connected);
    ctx.stop(io);
}

test "serveBridge relays over a dedicated Klippy connection" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try tmpSocketPath(&path_buf, &tmp, "klippy.sock");
    const addr = try net.UnixAddress.init(path);
    var klippy_server = try addr.listen(io, .{});
    defer klippy_server.deinit(io);

    const nb = try NullBus.init(alloc);
    defer nb.deinit(alloc);
    var ctx = try KlippyCtx.init(alloc, &nb.bus);
    defer ctx.deinit();
    ctx.setIo(io);
    ctx.uds_path = path;
    ctx.connected.store(true, .release);

    // WebSocket over a loopback TCP pair; the test plays the client.
    var tcp = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer tcp.deinit(io);
    const client = try tcp.socket.address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    const server_side = try tcp.accept(io);
    defer server_side.close(io);
    var srbuf: [4096]u8 = undefined;
    var sr = server_side.reader(io, &srbuf);
    var swbuf: [4096]u8 = undefined;
    var sw = server_side.writer(io, &swbuf);
    var ws: std.http.Server.WebSocket = .{ .key = "", .input = &sr.interface, .output = &sw.interface };
    var bridge_task = try io.concurrent(KlippyCtx.serveBridge, .{ &ctx, io, &ws, server_side, null });

    const klippy_side = try klippy_server.accept(io);
    var krbuf: [512]u8 = undefined;
    var kr = klippy_side.reader(io, &krbuf);
    var kwbuf: [512]u8 = undefined;
    var kw = klippy_side.writer(io, &kwbuf);
    var cwbuf: [256]u8 = undefined;
    var cw = client.writer(io, &cwbuf);
    var crbuf: [512]u8 = undefined;
    var cr = client.reader(io, &crbuf);

    // Client text frame (zero mask key) reaches Klippy as one ETX frame.
    const request = "{\"id\":\"17\",\"method\":\"info\"}";
    try cw.interface.writeAll(&.{ 0x81, 0x80 | request.len, 0, 0, 0, 0 });
    try cw.interface.writeAll(request);
    try cw.interface.flush();
    const got = try framing.read(alloc, &kr.interface);
    defer alloc.free(got);
    try std.testing.expectEqualStrings(request, got);

    // Klippy's reply reaches the client as one text frame.
    const reply = "{\"id\":\"17\",\"result\":{}}";
    try framing.write(&kw.interface, reply);
    try kw.interface.flush();
    const head = try cr.interface.takeArray(2);
    try std.testing.expectEqual(@as(u8, 0x81), head[0]);
    try std.testing.expectEqualStrings(reply, try cr.interface.take(head[1]));

    // Klippy closing the socket closes the WebSocket with 1001.
    klippy_side.close(io);
    const close_head = try cr.interface.takeArray(2);
    try std.testing.expectEqual(@as(u8, 0x88), close_head[0]);
    const close_body = try cr.interface.take(close_head[1]);
    try std.testing.expectEqual(@as(u16, bridge_close_code), std.mem.readInt(u16, close_body[0..2], .big));
    try std.testing.expectEqualStrings(bridge_close_reason, close_body[2..]);
    // The bridge must end even when the client never answers the close frame.
    bridge_task.await(io);
}

test "serveBridge refuses while Klippy is not connected" {
    const alloc = std.testing.allocator;
    const nb = try NullBus.init(alloc);
    defer nb.deinit(alloc);
    var ctx = try KlippyCtx.init(alloc, &nb.bus);
    defer ctx.deinit();
    var in: std.Io.Reader = .fixed("");
    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var ws: std.http.Server.WebSocket = .{ .key = "", .input = &in, .output = &out };
    ctx.serveBridge(std.testing.io, &ws, undefined, null);
    const frame = out.buffered();
    try std.testing.expectEqual(@as(u8, 0x88), frame[0]);
    try std.testing.expectEqualStrings(bridge_close_reason, frame[4..]);
}
