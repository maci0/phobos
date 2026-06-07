//! Klippy Unix-socket bridge.
//!
//! Connects to a Klippy process via its Unix-domain socket (default
//! `/tmp/klippy_uds`), performs the identification/subscription handshake, and
//! relays method calls and status updates between Klippy and phobos transports.
//!
//! Wire protocol: JSON-RPC 2.0 messages delimited by `\x03` (ASCII ETX).
//! Klippy sends JSON-RPC requests (with id) for registered remote methods;
//! Moonraker/phobos sends JSON-RPC requests to Klippy's endpoint registry.
//! Notifications are id-less in both directions.
//!
//! References:
//!   vendor/moonraker/moonraker/components/klippy_connection.py (853 lines)
//!   https://www.klipper3d.org/API_Server.html

const std = @import("std");
const net = std.Io.net;
const notify = @import("../server/notify.zig");
const methods = @import("../core/methods.zig");

// ---------------------------------------------------------------------------
// Framing: \x03-delimited JSON-RPC over a Unix stream
// ---------------------------------------------------------------------------

/// Maximum size of a single Klippy protocol frame. Moonraker uses a 20 MiB
/// Unix-buffer limit; we match that for the read buffer.
pub const frame_max: usize = 20 * 1024 * 1024;

const FrameEnd = 0x03;

/// Encode a JSON-RPC message for the Klippy wire: append `\x03`.
pub fn frameEncode(payload: []const u8, buf: []u8) []const u8 {
    std.debug.assert(buf.len >= payload.len + 1);
    @memcpy(buf[0..payload.len], payload);
    buf[payload.len] = FrameEnd;
    return buf[0 .. payload.len + 1];
}

/// Decode one `\x03`-delimited frame from accumulated data.
/// Returns the payload (before the `\x03`) and the number of bytes consumed
/// from `data` (payload + 1 for the delimiter). Returns null when a complete
/// frame is not yet available.
pub fn frameDecode(data: []const u8) ?struct { payload: []const u8, consumed: usize } {
    if (std.mem.indexOfScalar(u8, data, FrameEnd)) |pos| {
        return .{ .payload = data[0..pos], .consumed = pos + 1 };
    }
    return null;
}

// ---------------------------------------------------------------------------
// Klippy connection state
// ---------------------------------------------------------------------------

pub const State = enum {
    disconnected,
    connecting,
    startup, // Klippy identified, polling info until state != startup
    ready,
    shutdown,
};

/// Parsed result from a Klippy `server.info` response.
pub const KlippyInfo = struct {
    state: State,
    state_message: []const u8,
    version: []const u8,
    hostname: []const u8,
};

// ---------------------------------------------------------------------------
// JSON-RPC message construction (pure, testable)
// ---------------------------------------------------------------------------

/// Build a JSON-RPC 2.0 request into `buf`. Returns the formatted slice.
/// Caller must ensure `buf` is large enough (~256 bytes per request).
pub fn buildJsonRpcRequest(
    method: []const u8,
    id: []const u8,
    params_json: ?[]const u8,
    buf: []u8,
) ![]const u8 {
    if (params_json) |p| {
        if (p.len > 0) {
            return std.fmt.bufPrint(buf,
                "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"id\":\"{s}\",\"params\":{s}}}",
                .{ method, id, p },
            );
        }
    }
    return std.fmt.bufPrint(buf,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"id\":\"{s}\"}}",
        .{ method, id },
    );
}

/// Build the Klippy `info` request — the real handshake/identify step.
///
/// Klippy has no `server.connection.identify`; the Moonraker host identifies
/// itself by sending the `info` endpoint with a `client_info` object (see
/// klippy_apis.get_klippy_info, send_id=True). `id` is the request id; pass
/// `send_id=true` for the first (identifying) call and `false` for subsequent
/// state polls (which omit `client_info`).
pub fn buildInfoRequest(
    program: []const u8,
    version: []const u8,
    id: []const u8,
    send_id: bool,
    buf: []u8,
) ![]const u8 {
    if (send_id) {
        return std.fmt.bufPrint(buf,
            \\{{"jsonrpc":"2.0","method":"info","id":"{s}","params":{{"client_info":{{"program":"{s}","version":"{s}"}}}}}}
        ,
            .{ id, program, version },
        );
    }
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","method":"info","id":"{s}","params":{{}}}}
    ,
        .{id},
    );
}

/// Build an `objects/subscribe` request. Includes the `response_template`
/// naming the remote method (`process_status_update`) Klippy invokes on each
/// status update for this connection — without it Klippy returns the initial
/// status only and pushes no further updates (klippy_connection.py:644).
pub fn buildSubscribeRequest(objects: []const u8, id: []const u8, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"objects/subscribe\",\"id\":\"{s}\",\"params\":{{\"objects\":{s},\"response_template\":{{\"method\":\"process_status_update\"}}}}}}",
        .{ id, objects },
    );
}

/// Build a `gcode/subscribe_output` request. Carries the `response_template`
/// naming `process_gcode_response` (klippy_apis.subscribe_gcode_output).
pub fn buildSubscribeGcodeRequest(id: []const u8, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"gcode/subscribe_output\",\"id\":\"{s}\",\"params\":{{\"response_template\":{{\"method\":\"process_gcode_response\"}}}}}}",
        .{id},
    );
}

/// Build a `register_remote_method` request.
pub fn buildRegisterMethodRequest(method_name: []const u8, id: []const u8, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"register_remote_method\",\"id\":\"{s}\",\"params\":{{\"remote_method\":\"{s}\"}}}}",
        .{ id, method_name },
    );
}

// ---------------------------------------------------------------------------
// Response parsing (pure, testable)
// ---------------------------------------------------------------------------

/// Extract Klippy state from a `server.info` JSON-RPC response result.
/// Returns null if the result doesn't contain the expected fields.
pub fn parseKlippyInfoResponse(result: std.json.Value) ?KlippyInfo {
    switch (result) {
        .object => |obj| {
            const state_str = if (obj.get("state")) |s| switch (s) {
                .string => |str| str,
                else => return null,
            } else return null;
            const state_message = if (obj.get("state_message")) |s| switch (s) {
                .string => |str| str,
                else => "",
            } else "";
            // Real Klippy reports `software_version`; the sim historically used
            // `version`. Accept either.
            const version = if (obj.get("software_version") orelse obj.get("version")) |s| switch (s) {
                .string => |str| str,
                else => "",
            } else "";
            const hostname = if (obj.get("hostname")) |s| switch (s) {
                .string => |str| str,
                else => "",
            } else "";

            const state: State = if (std.mem.eql(u8, state_str, "ready"))
                .ready
            else if (std.mem.eql(u8, state_str, "shutdown"))
                .shutdown
            else if (std.mem.eql(u8, state_str, "startup"))
                .startup
            else
                .disconnected;

            return .{
                .state = state,
                .state_message = state_message,
                .version = version,
                .hostname = hostname,
            };
        },
        else => return null,
    }
}

/// Check if a JSON-RPC response contains an error; return the error message.
pub fn getJsonRpcError(response: std.json.Value) ?[]const u8 {
    switch (response) {
        .object => |obj| {
            if (obj.get("error")) |err| {
                switch (err) {
                    .object => |err_obj| {
                        if (err_obj.get("message")) |msg| {
                            switch (msg) {
                                .string => |s| return s,
                                else => return "unknown error",
                            }
                        }
                        return "unknown error";
                    },
                    else => return "unknown error",
                }
            }
            return null;
        },
        else => return null,
    }
}

/// Check if a JSON-RPC frame is a notification (has method, no id or null id).
pub fn isNotification(frame: std.json.Value) bool {
    switch (frame) {
        .object => |obj| {
            if (obj.get("method") != null) {
                if (obj.get("id")) |id| {
                    return id == .null;
                }
                return true;
            }
            return false;
        },
        else => return false,
    }
}

// ---------------------------------------------------------------------------
// Read buffer: accumulate bytes, yield complete \x03-delimited frames
// ---------------------------------------------------------------------------

pub const ReadBuf = struct {
    gpa: std.mem.Allocator,
    buf: []u8,
    len: usize,
    /// Hard upper bound; the buffer grows on demand up to this and never beyond.
    max: usize,

    /// Allocate a read buffer that grows lazily up to `max_size`. Starts small
    /// (16 KiB or `max_size`, whichever is less) so a 20 MiB frame ceiling does
    /// not commit 20 MiB up front — real Klippy frames are a few KB.
    pub fn init(alloc: std.mem.Allocator, max_size: usize) !ReadBuf {
        const initial = @min(max_size, 16 * 1024);
        const buf = try alloc.alloc(u8, initial);
        return .{ .gpa = alloc, .buf = buf, .len = 0, .max = max_size };
    }

    pub fn deinit(self: *ReadBuf, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
        self.len = 0;
        self.buf = &.{};
    }

    /// Grow `buf` (doubling, capped at `max`) so it can hold `need` bytes.
    fn ensureCapacity(self: *ReadBuf, need: usize) !void {
        if (need <= self.buf.len) return;
        if (need > self.max) return error.BufferOverflow;
        var new_cap = self.buf.len;
        while (new_cap < need) new_cap = @min(self.max, new_cap *| 2);
        self.buf = try self.gpa.realloc(self.buf, new_cap);
    }

    /// Append bytes from a stream read. Returns the payload of the next complete
    /// frame (without \x03) if one is available. Call `consume` after processing.
    pub fn append(self: *ReadBuf, data: []const u8) ![]const u8 {
        try self.ensureCapacity(self.len + data.len);
        @memcpy(self.buf[self.len..][0..data.len], data);
        self.len += data.len;
        if (std.mem.indexOfScalar(u8, self.buf[0..self.len], FrameEnd)) |pos| {
            return self.buf[0..pos];
        }
        return error.NeedMoreData;
    }

    /// Remove `consumed` bytes from the front of the buffer.
    pub fn consume(self: *ReadBuf, consumed: usize) void {
        std.debug.assert(consumed <= self.len);
        const remaining = self.len - consumed;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[consumed..self.len]);
        }
        self.len = remaining;
    }

    pub fn reset(self: *ReadBuf) void {
        self.len = 0;
    }
};

/// Recursively copy a JSON value into `alloc`. Used to lift a request result out
/// of the parse buffer (which references the soon-freed `payload`) in a single
/// pass — cheaper than the former serialize-to-text + re-parse round-trip.
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
            for (arr.items) |item| try new_arr.append(try deepCopyValue(alloc, item));
            return .{ .array = new_arr };
        },
    };
}

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

/// Callback signature for a /klippysocket bridge to receive raw frames from
/// Klippy. The function must serialize its own access to the target WebSocket.
pub const BridgeWriteFn = *const fn (ctx: *anyopaque, payload: []const u8) anyerror!void;

/// A registered bridge client. KlippyCtx forwards every received frame to all
/// bridges so that /klippysocket WS clients see the raw Klippy stream.
pub const Bridge = struct {
    ctx: *anyopaque,
    write_fn: BridgeWriteFn,
};

pub const KlippyCtx = struct {
    gpa: std.mem.Allocator,
    io: ?std.Io = null,
    bus: *notify.NotifyBus,

    /// Back-pointer to the server.info state block so that server.info
    /// responses reflect live Klippy connection state.
    server_info: ?*methods.ServerInfo = null,

    /// Path to the Klippy Unix socket. Default: /tmp/klippy_uds.
    uds_path: []const u8,

    state: State = .disconnected,
    /// The last parsed KlippyInfo, if identified.
    klippy_info: ?KlippyInfo = null,

    /// True once the identify handshake has completed.
    klippy_identified: bool = false,
    /// True once Klippy has exited the startup state.
    klippy_started: bool = false,

    /// Monotonic request id counter.
    next_id: u64 = 0,

    /// Read buffer for accumulating incoming stream data.
    read_buf: ReadBuf,

    /// Active Unix socket stream; null when disconnected.
    stream: ?net.Stream = null,

    /// Mutex serialising access to the Unix socket. Held during writes and
    /// reads so that the background read-loop and handler request() calls do
    /// not interleave. Never held while emitting notifications (avoids
    /// deadlock with the Core lock: handler holds Core → acquires stream_mutex;
    /// background holds stream_mutex → releases → acquires Core for emit).
    stream_mutex: std.Io.Mutex = std.Io.Mutex.init,

    /// Registered /klippysocket bridge WebSocket connections. Every frame
    /// received from Klippy is forwarded to every registered bridge writer.
    bridges: std.ArrayListUnmanaged(Bridge) = .empty,
    /// Guards `bridges` — mutated from /klippysocket WS threads (add/remove) and
    /// read from the frame-forwarding path. Locked via `self.io`; the
    /// `if (self.io)` guard is sound (not a mixed-state hazard) because every
    /// bridge access happens AFTER `setIo`: `addBridge`/`removeBridge` run only
    /// for live WS sessions (ws.serveBridge) and `forwardToBridges` runs from the
    /// request/dispatch paths — all post-setIo. `setIo` is called once at startup
    /// before any thread starts, so io never transitions while a caller races.
    /// The null branch is the single-threaded pre-serve / unit-test path.
    bridges_mutex: std.Io.Mutex = std.Io.Mutex.init,

    /// Job state component (set by App after init). Called on status updates
    /// to detect print state transitions.
    job_state: ?*@import("job_state.zig").JobStateCtx = null,

    /// History component (set by App after init). Called on disconnect/shutdown
    /// to finish the current job with the appropriate status.
    history: ?*@import("history.zig").HistoryCtx = null,

    /// OctoPrint compat component (set by App after init). Called on status
    /// updates and Klippy state changes for /api/ state reporting.
    octoprint: ?*@import("octoprint_compat.zig").OctoPrintCtx = null,

    /// Set by stop() to signal the background klippyTask to exit.
    stopping: bool = false,

    pub fn init(
        gpa: std.mem.Allocator,
        bus: *notify.NotifyBus,
    ) !KlippyCtx {
        return KlippyCtx{
            .gpa = gpa,
            .bus = bus,
            .uds_path = "/tmp/klippy_uds",
            .read_buf = try ReadBuf.init(gpa, frame_max),
        };
    }

    pub fn setIo(self: *KlippyCtx, io: std.Io) void {
        self.io = io;
    }

    pub fn deinit(self: *KlippyCtx) void {
        self.read_buf.deinit(self.gpa);
        self.state = .disconnected;
        self.klippy_info = null;
        // Null out cross-component pointers so any late emitDisconnected
        // calls from a still-running task become no-ops.
        self.octoprint = null;
        self.job_state = null;
        self.history = null;
    }

    /// True when Klippy is connected and ready for requests.
    pub fn isConnected(self: *const KlippyCtx) bool {
        return self.state == .ready;
    }

    /// Register a bridge client that will receive every frame from Klippy.
    /// The caller owns `ctx` and must ensure it outlives the registration.
    pub fn addBridge(self: *KlippyCtx, bridge: Bridge) !void {
        if (self.io) |io| self.bridges_mutex.lockUncancelable(io);
        defer if (self.io) |io| self.bridges_mutex.unlock(io);
        try self.bridges.append(self.gpa, bridge);
    }

    /// Remove a previously registered bridge client.
    pub fn removeBridge(self: *KlippyCtx, bridge: Bridge) void {
        if (self.io) |io| self.bridges_mutex.lockUncancelable(io);
        defer if (self.io) |io| self.bridges_mutex.unlock(io);
        for (self.bridges.items, 0..) |b, i| {
            if (b.ctx == bridge.ctx and b.write_fn == bridge.write_fn) {
                _ = self.bridges.swapRemove(i);
                return;
            }
        }
    }

    /// Forward a raw frame (without the \\x03 delimiter) to every registered bridge.
    fn forwardToBridges(self: *KlippyCtx, raw_payload: []const u8) void {
        if (self.io) |io| self.bridges_mutex.lockUncancelable(io);
        defer if (self.io) |io| self.bridges_mutex.unlock(io);
        for (self.bridges.items) |b| {
            b.write_fn(b.ctx, raw_payload) catch {};
        }
    }

    /// Send a raw payload (without \\x03 framing) to the Klippy Unix socket.
    /// Acquires stream_mutex for the duration. For use by /klippysocket bridges.
    pub fn sendRaw(self: *KlippyCtx, payload: []const u8) !void {
        if (!self.isConnected()) return error.KlippyDisconnected;
        const io = self.io.?;
        try self.stream_mutex.lock(io);
        defer self.stream_mutex.unlock(io);
        try self.writeFrame(io, payload);
    }

    /// Start the background Klippy connection task. Must be called after setIo().
    /// Spawns a task on the thread pool that connects, handshakes, and enters
    /// the read loop, with automatic reconnection on failure.
    pub fn start(self: *KlippyCtx) void {
        const io = self.io orelse return;
        _ = io.async(klippyTask, .{self});
    }

    /// Signal the background klippyTask to exit and close any active stream.
    /// Safe to call multiple times. After this returns, the background task
    /// will exit its loop at the next sleep/error boundary; call
    /// `threaded.deinit()` to join it.
    pub fn stop(self: *KlippyCtx, io: std.Io) void {
        self.stopping = true;
        // Read self.stream WITHOUT stream_mutex on purpose: the background task
        // may hold stream_mutex while blocked in readv, so acquiring it here
        // first would deadlock. shutdown(.recv) interrupts that blocked read so
        // it releases the mutex; closeStream then takes the mutex and closes.
        // Worst case this shutdown hits an already-closed/stale fd → harmless
        // (caught). Only do this from stop(), never from the klippyTask
        // reconnect error path.
        if (self.stream) |*s| {
            s.shutdown(io, .recv) catch {};
        }
        self.closeStream(io);
    }

    // -----------------------------------------------------------------------
    // Background task: connect → handshake → read loop → reconnect
    // -----------------------------------------------------------------------

    fn klippyTask(self: *KlippyCtx) void {
        const io = self.io.?;
        while (!self.stopping) {
            _ = self.setState(.connecting);
            self.connectAndHandshake() catch {
                _ = self.setState(.disconnected);
                self.emitDisconnected(io);
                self.closeStream(io);
                // Check stopping before reconnect sleep.
                if (self.stopping) break;
                // Sleep ~1s between reconnect attempts.
                const delay: std.Io.Duration = .{ .nanoseconds = 1_000_000_000 };
                std.Io.sleep(self.io.?, delay, .real) catch {};
                if (self.stopping) break;
                continue;
            };
            // Handshake succeeded — the connection is ready for request().
            // We deliberately do NOT run a persistent readLoop here: holding
            // stream_mutex across a blocking readFrame would deadlock with
            // request(), which also needs stream_mutex to send requests and
            // read responses. Spontaneous Klippy notifications (status
            // updates, gcode responses) are drained inline by request().
            return;
        }
    }

    fn closeStream(self: *KlippyCtx, io: std.Io) void {
        // Take the stream under the mutex, null it, release, THEN close — so we
        // never close the fd out from under an in-flight `request()` that holds
        // `stream_mutex` (use-after-close), and two concurrent closeStream calls
        // (stop() + the reconnect error path) can't double-close (only the one
        // that observes non-null closes). stop() issues shutdown(.recv) first to
        // unblock a request blocked in readFrame so it releases the mutex.
        // lockUncancelable: a teardown path must not skip the lock on
        // cancellation (which `lock(io) catch {}` would, then mutate + unlock
        // without holding it).
        self.stream_mutex.lockUncancelable(io);
        const s = self.stream;
        self.stream = null;
        self.stream_mutex.unlock(io);
        if (s) |sock| {
            var local = sock;
            local.close(io);
        }
    }

    // -----------------------------------------------------------------------
    // Connect + handshake
    // -----------------------------------------------------------------------

    /// Open the Unix socket and perform the real Klippy handshake:
    ///   1. `info` (with client_info) to identify, then poll `info` until
    ///      Klippy leaves the `startup` state (mirrors Moonraker's _check_ready).
    ///   2. `objects/subscribe` (with response_template) for status updates.
    ///   3. `gcode/subscribe_output` (with response_template) for gcode output.
    /// Klippy has NO `server.connection.identify` — the `info` request is the
    /// identify step. Status/gcode pushes arrive as `process_status_update` /
    /// `process_gcode_response` remote-method calls named in the templates.
    fn connectAndHandshake(self: *KlippyCtx) !void {
        const io = self.io.?;
        const addr = try net.UnixAddress.init(self.uds_path);
        const s = try addr.connect(io);
        self.stream = s;

        // Phase 1: identify + poll `info` until Klippy is out of startup.
        _ = self.setState(.connecting);
        try self.pollServerInfo(io);
        self.klippy_identified = true;

        // Phase 2: subscribe to printer objects for status updates. Tolerate a
        // subscribe error (Moonraker logs and continues) so a missing object on
        // a bare config never aborts the handshake.
        var sub_buf: [512]u8 = undefined;
        var rid_buf: [32]u8 = undefined;
        {
            const sub_id = self.nextReqId(&rid_buf);
            const sub_frame = try buildSubscribeRequest(
                \\{"webhooks":null,"toolhead":null,"print_stats":null}
            , sub_id, &sub_buf);
            try self.writeFrame(io, sub_frame);
            const sub_resp = try self.readFrame(io);
            self.gpa.free(sub_resp);
        }

        // Phase 3: subscribe to gcode output.
        {
            const gc_id = self.nextReqId(&rid_buf);
            const gc_frame = try buildSubscribeGcodeRequest(gc_id, &sub_buf);
            try self.writeFrame(io, gc_frame);
            const gc_resp = try self.readFrame(io);
            self.gpa.free(gc_resp);
        }

        // Handshake fully complete — mark ready so isConnected() gates open.
        _ = self.setState(.ready);
    }

    /// Poll the Klippy `info` endpoint every 250ms up to 100 times until Klippy
    /// exits the startup state. The first request carries `client_info`
    /// (identify); subsequent polls omit it.
    fn pollServerInfo(self: *KlippyCtx, io: std.Io) !void {
        var poll_count: u8 = 0;
        while (poll_count < 100) : (poll_count += 1) {
            var info_buf: [256]u8 = undefined;
            var rid: [32]u8 = undefined;
            const info_id = self.nextReqId(&rid);
            const info_frame = try buildInfoRequest("phobos", "1.0.0", info_id, poll_count == 0, &info_buf);
            try self.writeFrame(io, info_frame);

            const info_payload = try self.readFrame(io);
            defer self.gpa.free(info_payload);
            const parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, info_payload, .{});
            defer parsed.deinit();

            const result = parsed.value.object.get("result") orelse return error.IdentifyFailed;
            if (parseKlippyInfoResponse(result)) |info| {
                self.klippy_info = info;
                switch (info.state) {
                    .ready => {
                        self.klippy_started = true;
                        return;
                    },
                    .shutdown => {
                        _ = self.setState(.shutdown);
                        self.emitShutdown(io);
                        return error.KlippyShutdown;
                    },
                    .startup => {
                        _ = self.setState(.startup);
                        // Sleep 250ms before next poll.
                        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(250), .real) catch {};
                        continue;
                    },
                    else => return error.KlippyDisconnected,
                }
            }
            return error.IdentifyFailed;
        }
        return error.KlippyStartupTimeout;
    }

    // -----------------------------------------------------------------------
    // Read loop
    // -----------------------------------------------------------------------

    /// Continuously read frames from Klippy and dispatch them.
    /// Holds `stream_mutex` only during the socket read; releases it before
    /// dispatching to avoid deadlock with the Core lock.
    fn readLoop(self: *KlippyCtx) !void {
        const io = self.io.?;
        while (!self.stopping) {
            const payload = blk: {
                try self.stream_mutex.lock(io);
                defer {
                    self.stream_mutex.unlock(io);
                }
                break :blk try self.readFrame(io);
            };
            defer self.gpa.free(payload);
            // Dispatch outside stream_mutex so notification emission can
            // acquire the Core lock without risk of deadlock.
            try self.dispatchFrame(io, payload);
        }
    }

    /// Dispatch a received JSON-RPC frame from the background readLoop.
    /// Handles three kinds of frames:
    /// 1. Notifications (method, no id) — Klippy pushes spontaneous data.
    /// 2. Remote-method calls (method + id) — Klippy calls a Moonraker handler
    ///    (process_status_update, process_gcode_response). We process and ack.
    /// 3. Responses (result/error + id, no method) — consumed by `request()`,
    ///    which holds `stream_mutex`; they never reach here.
    fn dispatchFrame(self: *KlippyCtx, io: std.Io, payload: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, payload, .{});
        defer parsed.deinit();

        const frame = parsed.value;

        // Remote-method call: has both method AND a non-null id.
        if (frame.object.get("method")) |method_val| {
            const method_str = method_val.string;
            const has_id = if (frame.object.get("id")) |id_val| id_val != .null else false;

            if (has_id) {
                // Klippy is calling a remote method on us. Dispatch and ack.
                const id = frame.object.get("id").?;
                try self.dispatchRemoteMethod(io, method_str, frame);
                try self.sendAck(io, id);
            } else {
                // Notification — no id or null id.
                try self.dispatchNotification(io, method_str, frame);
            }
            self.forwardToBridges(payload);
            return;
        }

        // Response frame (result/error + id, no method) — consumed by request().
        self.forwardToBridges(payload);
    }

    /// Send an empty acknowledgment response for a remote-method call.
    /// Caller MUST hold stream_mutex.
    fn sendAck(self: *KlippyCtx, io: std.Io, id: std.json.Value) !void {
        var ack_buf: [128]u8 = undefined;
        const id_str = if (id == .string) id.string else "0";
        const ack = try std.fmt.bufPrint(&ack_buf,
            "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"result\":null}}", .{id_str});
        try self.writeFrame(io, ack);
    }

    /// Dispatch a Klippy-initiated remote method call (has both method and id).
    fn dispatchRemoteMethod(self: *KlippyCtx, io: std.Io, method: []const u8, frame: std.json.Value) !void {
        if (std.mem.eql(u8, method, "process_status_update")) {
            try self.processStatusUpdate(io, frame);
        } else if (std.mem.eql(u8, method, "process_gcode_response")) {
            try self.processGcodeResponse(io, frame);
        }
    }

    /// Dispatch a notification frame from the background read loop.
    /// Uses `emit` (acquires Core lock) since the background task does not
    /// hold the Core lock.
    fn dispatchNotification(self: *KlippyCtx, io: std.Io, method: []const u8, frame: std.json.Value) !void {
        if (std.mem.eql(u8, method, "notify_status_update")) {
            try self.processStatusUpdate(io, frame);
        } else if (std.mem.eql(u8, method, "notify_gcode_response")) {
            try self.processGcodeResponse(io, frame);
        }
    }

    /// Dispatch a remote-method call or notification from within a `request()`
    /// call that already holds the Core lock. Uses `emitLocked` variants.
    fn dispatchInlineLocked(self: *KlippyCtx, io: std.Io, method: []const u8, frame: std.json.Value) !void {
        if (std.mem.eql(u8, method, "process_status_update")) {
            try self.processStatusUpdateLocked(io, frame);
        } else if (std.mem.eql(u8, method, "process_gcode_response")) {
            try self.processGcodeResponseLocked(io, frame);
        } else if (std.mem.eql(u8, method, "notify_status_update")) {
            try self.processStatusUpdateLocked(io, frame);
        } else if (std.mem.eql(u8, method, "notify_gcode_response")) {
            try self.processGcodeResponseLocked(io, frame);
        }
    }

    /// Process a notify_status_update or process_status_update from Klippy.
    /// Parses the status dict, checks webhooks for state transitions, and fans
    /// out per-object to subscribed connections.
    fn processStatusUpdate(self: *KlippyCtx, io: std.Io, frame: std.json.Value) !void {
        const params = frame.object.get("params") orelse return;
        try self.processStatusUpdateInner(io, params, false);
    }

    /// Locked variant — caller holds Core lock.
    fn processStatusUpdateLocked(self: *KlippyCtx, io: std.Io, frame: std.json.Value) !void {
        const params = frame.object.get("params") orelse return;
        try self.processStatusUpdateInner(io, params, true);
    }

    /// Core status-update processing: parse params, check webhooks, fan out
    /// per-object. `locked` selects emit vs emitLocked.
    fn processStatusUpdateInner(self: *KlippyCtx, io: std.Io, params: std.json.Value, locked: bool) !void {
        // Params is a JSON-RPC array: [eventtime, status_dict].
        if (params != .array) return;
        const arr = params.array;
        if (arr.items.len < 2) return;

        const status_dict = arr.items[1];
        if (status_dict != .object) return;

        // Check webhooks for state transitions.
        if (status_dict.object.get("webhooks")) |wh_val| {
            if (wh_val == .object) {
                if (wh_val.object.get("state")) |state_val| {
                    if (state_val == .string) {
                        const st = state_val.string;
                        if (std.mem.eql(u8, st, "shutdown")) {
                            if (self.state != .shutdown) {
                                _ = self.setState(.shutdown);
                                if (locked) {
                                    self.bus.emitLocked(io, notify.names.klippy_shutdown, .null) catch {};
                                } else {
                                    self.bus.emit(io, notify.names.klippy_shutdown, .null) catch {};
                                }
                            }
                        } else if (std.mem.eql(u8, st, "ready")) {
                            if (self.state != .ready) {
                                _ = self.setState(.ready);
                            }
                        }
                    }
                }
            }
        }

        // Fan out each object to connections subscribed to that object name.
        // Reuse one map + array across the loop (clearRetainingCapacity) so the
        // backing stores are allocated at most once per tick, not per object —
        // emit copies params into its own frame, so the scaffolding is safe to
        // recycle. Freed once at the end (defer).
        const scratch = std.heap.smp_allocator;
        var per_obj_map: std.json.ObjectMap = .empty;
        defer per_obj_map.deinit(scratch);
        var params_arr: std.json.Array = .init(scratch);
        defer params_arr.deinit();

        var it = status_dict.object.iterator();
        while (it.next()) |entry| {
            const obj_name = entry.key_ptr.*;
            // Build per-object status params: [eventtime, {obj_name: obj_data}].
            per_obj_map.clearRetainingCapacity();
            try per_obj_map.put(scratch, obj_name, entry.value_ptr.*);
            const per_obj_val = std.json.Value{ .object = per_obj_map };

            params_arr.clearRetainingCapacity();
            try params_arr.append(arr.items[0]);
            try params_arr.append(per_obj_val);
            const params_array = std.json.Value{ .array = params_arr };

            if (locked) {
                _ = self.bus.emitStatusLocked(io, notify.names.status_update, params_array, obj_name) catch {};
            } else {
                _ = self.bus.emitStatus(io, notify.names.status_update, params_array, obj_name) catch {};
            }
        }

        // Feed print_stats into the job state machine (job_state component).
        if (self.job_state) |js| {
            if (status_dict.object.get("print_stats")) |ps| {
                js.statusUpdate(ps);
            }
        }

        // Feed print_stats into the octoprint compat state tracker.
        if (self.octoprint) |oc| {
            if (status_dict.object.get("print_stats")) |ps| {
                oc.statusUpdate(ps);
            }
        }
    }

    /// Process a notify_gcode_response or process_gcode_response from Klippy.
    fn processGcodeResponse(self: *KlippyCtx, io: std.Io, frame: std.json.Value) !void {
        const params = frame.object.get("params") orelse return;
        // Moonraker sends "server:gcode_response" event; match it via notify bus.
        _ = try self.bus.emit(io, notify.names.gcode_response, params);
    }

    /// Locked variant — caller holds Core lock.
    fn processGcodeResponseLocked(self: *KlippyCtx, io: std.Io, frame: std.json.Value) !void {
        const params = frame.object.get("params") orelse return;
        _ = try self.bus.emitLocked(io, notify.names.gcode_response, params);
    }

    // -----------------------------------------------------------------------
    // I/O primitives
    // -----------------------------------------------------------------------

    /// Write a framed message to the Klippy socket.
    fn writeFrame(self: *KlippyCtx, io: std.Io, payload: []const u8) !void {
        // Use a small stack buffer for the common case; fall back to the
        // heap for oversized payloads. The 20 MiB frame_max is the read
        // buffer limit, not a typical write size.
        var frame_buf: [4096]u8 = undefined;
        const frame: []const u8 = if (payload.len + 1 <= frame_buf.len) blk: {
            @memcpy(frame_buf[0..payload.len], payload);
            frame_buf[payload.len] = FrameEnd;
            break :blk frame_buf[0 .. payload.len + 1];
        } else blk: {
            if (payload.len + 1 > frame_max) return error.FrameTooLarge;
            const f = try self.gpa.alloc(u8, payload.len + 1);
            errdefer self.gpa.free(f);
            @memcpy(f[0..payload.len], payload);
            f[payload.len] = FrameEnd;
            break :blk f;
        };
        defer if (frame.ptr != &frame_buf) self.gpa.free(frame);

        var wbuf: [4096]u8 = undefined;
        var w = self.stream.?.writer(io, &wbuf);
        try w.interface.writeAll(frame);
        try w.interface.flush();
    }

    /// Read one complete framed payload from the Klippy socket.
    /// Blocks until a full \x03-delimited frame is available.
    fn readFrame(self: *KlippyCtx, io: std.Io) ![]const u8 {
        var rbuf: [4096]u8 = undefined;
        var r = self.stream.?.reader(io, &rbuf);
        while (true) {
            try r.interface.fillMore();
            const chunk = r.interface.buffer[r.interface.seek..r.interface.end];
            if (chunk.len == 0) return error.ConnectionClosed;

            const payload = self.read_buf.append(chunk) catch |err| switch (err) {
                error.BufferOverflow => {
                    self.read_buf.reset();
                    r.interface.tossBuffered();
                    continue;
                },
                error.NeedMoreData => {
                    r.interface.tossBuffered();
                    continue;
                },
                else => |e| return e,
            };
            // Copy payload before consume() shifts the underlying buffer.
            const owned = try self.gpa.dupe(u8, payload);
            r.interface.tossBuffered();
            self.read_buf.consume(payload.len + 1);
            return owned;
        }
    }

    /// Send a JSON-RPC request to Klippy and return the response result.
    /// Only valid when `isConnected()`. Acquires `stream_mutex` for the
    /// duration so the background read-loop cannot interleave. Notifications
    /// that arrive while waiting for the response are dispatched inline via
    /// `dispatchNotificationLocked` (assumes the caller holds the Core lock).
    pub fn request(
        self: *KlippyCtx,
        method: []const u8,
        params: std.json.Value,
        alloc: std.mem.Allocator,
    ) anyerror!std.json.Value {
        if (!self.isConnected()) return error.KlippyDisconnected;
        const io = self.io.?;

        try self.stream_mutex.lock(io);
        defer self.stream_mutex.unlock(io);

        // Build and send the request frame.
        var rid_buf: [32]u8 = undefined;
        const rid = self.nextReqId(&rid_buf);

        // Serialize params to JSON for embedding in the request. Built on the
        // caller's arena so arbitrarily large params (e.g. an objects/query
        // listing every printer object) are never truncated.
        var params_json: []const u8 = "";
        var params_owned: ?[]u8 = null;
        defer if (params_owned) |p| alloc.free(p);
        if (params != .null) {
            var aw: std.Io.Writer.Allocating = .init(alloc);
            defer aw.deinit();
            var jw: std.json.Stringify = .{ .writer = &aw.writer };
            try jw.write(params);
            params_owned = try aw.toOwnedSlice();
            params_json = params_owned.?;
        }

        // Frame buffer sized to fit method + id + params with envelope overhead.
        const req_buf = try alloc.alloc(u8, method.len + rid.len + params_json.len + 64);
        defer alloc.free(req_buf);
        const req_frame = try buildJsonRpcRequest(method, rid, params_json, req_buf);
        try self.writeFrame(io, req_frame);

        // Read frames until the matching response arrives.
        while (true) {
            const payload = try self.readFrame(io);
            defer self.gpa.free(payload);
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch |e| {
                return e;
            };

            // Check whether this is our response (matching id).
            if (parsed.value.object.get("id")) |id_val| {
                if (id_val == .string and std.mem.eql(u8, id_val.string, rid)) {
                    // Our response. Forward to bridges before returning.
                    self.forwardToBridges(payload);
                    if (parsed.value.object.get("error")) |_| {
                        return error.KlippyRequestFailed;
                    }
                    const result = parsed.value.object.get("result") orelse .null;
                    // Copy into `alloc` (the caller's request arena): the parse
                    // references `payload`, which is freed on return. One-pass
                    // deepCopyValue replaces the old serialize+re-parse round-trip.
                    return deepCopyValue(alloc, result);
                }
                // Different id — silently consume (should not happen in single-
                // request-in-flight model, but be safe).
            }

            // Not our response — dispatch inline (caller holds Core lock).
            if (parsed.value.object.get("method")) |method_val| {
                try self.dispatchInlineLocked(io, method_val.string, parsed.value);
                // If the frame has an id it is a Klippy-initiated remote method
                // call (not a notification); ack it so Klippy does not retransmit.
                if (parsed.value.object.get("id")) |id_val| {
                    if (id_val != .null) {
                        try self.sendAck(io, id_val);
                    }
                }
            }

            // Forward every frame to bridge clients so /klippysocket sees
            // responses and notifications alike.
            self.forwardToBridges(payload);
        }
    }

    /// Construct the next request id string (monotonic integer as string).
    fn nextReqId(self: *KlippyCtx, buf: []u8) []const u8 {
        self.next_id += 1;
        return std.fmt.bufPrint(buf, "{}", .{self.next_id}) catch "0";
    }

    /// Transition state and return true if state actually changed.
    pub fn setState(self: *KlippyCtx, new_state: State) bool {
        if (self.state == new_state) return false;
        self.state = new_state;
        if (new_state == .shutdown) {
            self.klippy_identified = false;
            self.klippy_started = false;
        }
        // Push to server.info so it reflects live Klippy state.
        if (self.server_info) |info| {
            info.klippy_connected = self.isConnected();
            info.klippy_state = @tagName(self.state);
            info.klippy_path = self.uds_path;
        }
        return true;
    }

    // -----------------------------------------------------------------------
    // Notification emission helpers
    // -----------------------------------------------------------------------

    fn emitReady(self: *KlippyCtx, io: std.Io) void {
        self.bus.emit(io, notify.names.klippy_ready, .null) catch {};
        if (self.octoprint) |oc| oc.setKlippyReady();
    }

    fn emitDisconnected(self: *KlippyCtx, io: std.Io) void {
        self.bus.emit(io, notify.names.klippy_disconnected, .null) catch {};
        // Notify job_state to update internal state to error.
        if (self.job_state) |js| js.handleDisconnect();
        // Finish the current job as klippy_disconnect.
        if (self.history) |h| {
            if (self.job_state) |js| {
                h.handleKlippyDisconnect(js.getLastStats());
            }
        }
        if (self.octoprint) |oc| oc.setKlippyDisconnected();
    }

    fn emitShutdown(self: *KlippyCtx, io: std.Io) void {
        self.bus.emit(io, notify.names.klippy_shutdown, .null) catch {};
        // Finish the current job as klippy_shutdown.
        if (self.history) |h| {
            if (self.job_state) |js| {
                h.handleKlippyShutdown(js.getLastStats());
            }
        }
        if (self.octoprint) |oc| oc.setKlippyDisconnected();
    }
};

// ===========================================================================
// Tests: framing
// ===========================================================================

test "frameEncode: appends \\x03" {
    var buf: [64]u8 = undefined;
    const got = frameEncode("hello", &buf);
    try std.testing.expectEqualStrings("hello\x03", got);
}

test "frameEncode: empty payload still gets \\x03" {
    var buf: [64]u8 = undefined;
    const got = frameEncode("", &buf);
    try std.testing.expectEqualStrings("\x03", got);
}

test "frameDecode: extracts payload before \\x03" {
    const data = "{\"id\":1}\x03more";
    const frame = frameDecode(data).?;
    try std.testing.expectEqualStrings("{\"id\":1}", frame.payload);
    try std.testing.expectEqual(@as(usize, 9), frame.consumed); // 8 + 1
}

test "frameDecode: null when no delimiter" {
    try std.testing.expect(frameDecode("no-delimiter") == null);
}

test "frameDecode: null on empty input" {
    try std.testing.expect(frameDecode("") == null);
}

test "frameDecode: handles only delimiter" {
    const data = "\x03";
    const frame = frameDecode(data).?;
    try std.testing.expectEqualStrings("", frame.payload);
    try std.testing.expectEqual(@as(usize, 1), frame.consumed);
}

test "frameEncode + frameDecode: round-trip preserves JSON-RPC" {
    var buf: [1024]u8 = undefined;
    const msg =
        \\{"jsonrpc":"2.0","method":"server.info","id":42}
    ;
    const framed = frameEncode(msg, &buf);
    const decoded = frameDecode(framed).?;
    try std.testing.expectEqualStrings(msg, decoded.payload);
}

// ===========================================================================
// Test helpers
// ===========================================================================

// NullBus must not be moved after init (contains self-referential pointers).
const NullBus = struct {
    core: @import("../server/core.zig").Core,
    conns_obj: @import("../server/connections.zig").Connections,
    bus: notify.NotifyBus,

    /// Heap-allocated so internal pointers (bus → conns_obj) stay valid
    /// after the struct leaves this function's stack frame.
    fn init(alloc: std.mem.Allocator) !*NullBus {
        const nb = try alloc.create(NullBus);
        errdefer alloc.destroy(nb);
        nb.core = @import("../server/core.zig").Core.init();
        nb.conns_obj = @import("../server/connections.zig").Connections.init(alloc, &nb.core);
        nb.bus = notify.NotifyBus.init(&nb.core, &nb.conns_obj);
        return nb;
    }

    fn deinit(self: *NullBus, alloc: std.mem.Allocator) void {
        self.conns_obj.list.deinit(self.conns_obj.alloc);
        alloc.destroy(self);
    }
};

// ===========================================================================
// Tests: context lifecycle
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

test "KlippyCtx.setIo: stores io handle" {
    const alloc = std.testing.allocator;
    const nb = try NullBus.init(alloc);
    defer nb.deinit(alloc);
    var ctx = try KlippyCtx.init(alloc, &nb.bus);
    defer ctx.deinit();

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    ctx.setIo(io);
    try std.testing.expect(ctx.io != null);
}

test "KlippyCtx.nextReqId: monotonic" {
    const alloc = std.testing.allocator;
    const nb = try NullBus.init(alloc);
    defer nb.deinit(alloc);
    var ctx = try KlippyCtx.init(alloc, &nb.bus);
    defer ctx.deinit();

    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    const id1 = ctx.nextReqId(&b1);
    const id2 = ctx.nextReqId(&b2);
    try std.testing.expectEqualStrings("1", id1);
    try std.testing.expectEqualStrings("2", id2);
    try std.testing.expect(ctx.next_id == 2);
}

// ===========================================================================
// Tests: JSON-RPC builders
// ===========================================================================

test "buildJsonRpcRequest: minimal request" {
    var buf: [256]u8 = undefined;
    const got = try buildJsonRpcRequest("server.info", "42", null, &buf);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"server.info\",\"id\":\"42\"}",
        got,
    );
}

test "buildJsonRpcRequest: with params" {
    var buf: [256]u8 = undefined;
    const got = try buildJsonRpcRequest("objects/list", "1", "[\"gcode\"]", &buf);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"objects/list\",\"id\":\"1\",\"params\":[\"gcode\"]}",
        got,
    );
}

test "buildJsonRpcRequest: empty params omitted" {
    var buf: [256]u8 = undefined;
    const got = try buildJsonRpcRequest("test", "x", "", &buf);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"test\",\"id\":\"x\"}",
        got,
    );
}

test "buildInfoRequest: identify form carries client_info" {
    var buf: [512]u8 = undefined;
    const got = try buildInfoRequest("phobos", "1.0.0", "identify", true, &buf);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"method\":\"info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"id\":\"identify\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"client_info\":{\"program\":\"phobos\",\"version\":\"1.0.0\"}") != null);
    // No legacy moonraker identify shape.
    try std.testing.expect(std.mem.indexOf(u8, got, "server.connection.identify") == null);
}

test "buildInfoRequest: poll form omits client_info" {
    var buf: [256]u8 = undefined;
    const got = try buildInfoRequest("phobos", "1.0.0", "7", false, &buf);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"info\",\"id\":\"7\",\"params\":{}}",
        got,
    );
}

test "buildSubscribeRequest: includes objects and response_template" {
    var buf: [256]u8 = undefined;
    const got = try buildSubscribeRequest("{\"toolhead\":null}", "2", &buf);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"objects/subscribe\",\"id\":\"2\",\"params\":{\"objects\":{\"toolhead\":null},\"response_template\":{\"method\":\"process_status_update\"}}}",
        got,
    );
}

test "buildRegisterMethodRequest" {
    var buf: [256]u8 = undefined;
    const got = try buildRegisterMethodRequest("process_status_update", "3", &buf);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"register_remote_method\",\"id\":\"3\",\"params\":{\"remote_method\":\"process_status_update\"}}",
        got,
    );
}

test "buildSubscribeGcodeRequest" {
    var buf: [256]u8 = undefined;
    const got = try buildSubscribeGcodeRequest("4", &buf);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"gcode/subscribe_output\",\"id\":\"4\",\"params\":{\"response_template\":{\"method\":\"process_gcode_response\"}}}",
        got,
    );
}

// ===========================================================================
// Tests: response parsing
// ===========================================================================

test "parseKlippyInfoResponse: ready state" {
    const json =
        \\{"state":"ready","state_message":"Printer is ready","version":"v0.12.0","hostname":"mainsailos"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const info = parseKlippyInfoResponse(parsed.value).?;
    try std.testing.expectEqual(State.ready, info.state);
    try std.testing.expectEqualStrings("Printer is ready", info.state_message);
    try std.testing.expectEqualStrings("v0.12.0", info.version);
}

test "parseKlippyInfoResponse: startup state" {
    const json =
        \\{"state":"startup","state_message":"Initializing..."}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const info = parseKlippyInfoResponse(parsed.value).?;
    try std.testing.expectEqual(State.startup, info.state);
    try std.testing.expectEqualStrings("Initializing...", info.state_message);
}

test "parseKlippyInfoResponse: shutdown state" {
    const json =
        \\{"state":"shutdown","state_message":"MCU shutdown"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const info = parseKlippyInfoResponse(parsed.value).?;
    try std.testing.expectEqual(State.shutdown, info.state);
}

test "parseKlippyInfoResponse: null on non-object" {
    const json = "\"just a string\"";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parseKlippyInfoResponse(parsed.value) == null);
}

test "parseKlippyInfoResponse: null on missing state" {
    const json = "{}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parseKlippyInfoResponse(parsed.value) == null);
}

test "getJsonRpcError: extracts error message" {
    const json =
        \\{"error":{"code":-32600,"message":"Invalid Request"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const err = getJsonRpcError(parsed.value).?;
    try std.testing.expectEqualStrings("Invalid Request", err);
}

test "getJsonRpcError: null on success response" {
    const json =
        \\{"id":"1","result":{"state":"ready"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(getJsonRpcError(parsed.value) == null);
}

test "isNotification: true for method without id" {
    const json =
        \\{"jsonrpc":"2.0","method":"notify_status_update"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(isNotification(parsed.value));
}

test "isNotification: true for method with null id" {
    const json =
        \\{"jsonrpc":"2.0","method":"notify_status_update","id":null}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(isNotification(parsed.value));
}

test "isNotification: false for request with id" {
    const json =
        \\{"jsonrpc":"2.0","method":"server.info","id":"1"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(!isNotification(parsed.value));
}

test "isNotification: false for response" {
    const json =
        \\{"jsonrpc":"2.0","id":"1","result":{}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(!isNotification(parsed.value));
}

// ===========================================================================
// Tests: ReadBuf
// ===========================================================================

test "ReadBuf: append extracts frame" {
    const alloc = std.testing.allocator;
    var rb = try ReadBuf.init(alloc, 256);
    defer rb.deinit(alloc);
    const payload = try rb.append("{\"id\":1}\x03");
    try std.testing.expectEqualStrings("{\"id\":1}", payload);
}

test "ReadBuf: consume advances buffer" {
    const alloc = std.testing.allocator;
    var rb = try ReadBuf.init(alloc, 256);
    defer rb.deinit(alloc);
    _ = try rb.append("hello\x03world\x03");
    try std.testing.expectEqual(@as(usize, 12), rb.len);
    rb.consume(6); // "hello" + \x03
    try std.testing.expectEqual(@as(usize, 6), rb.len); // "world\x03" remains
    const payload = try rb.append("");
    try std.testing.expectEqualStrings("world", payload);
}

test "ReadBuf: error.NeedMoreData when incomplete" {
    const alloc = std.testing.allocator;
    var rb = try ReadBuf.init(alloc, 256);
    defer rb.deinit(alloc);
    try std.testing.expectError(error.NeedMoreData, rb.append("partial"));
    // Second append of empty data also returns NeedMoreData (no \x03 yet).
    try std.testing.expectError(error.NeedMoreData, rb.append(""));
}

test "ReadBuf: reset clears buffer" {
    const alloc = std.testing.allocator;
    var rb = try ReadBuf.init(alloc, 256);
    defer rb.deinit(alloc);
    _ = try rb.append("data\x03");
    rb.consume(5);
    rb.reset();
    try std.testing.expectEqual(@as(usize, 0), rb.len);
}

test "ReadBuf: multiple appends accumulate" {
    const alloc = std.testing.allocator;
    var rb = try ReadBuf.init(alloc, 256);
    defer rb.deinit(alloc);
    // "hel" has no \x03 → NeedMoreData
    _ = rb.append("hel") catch |err| switch (err) {
        error.NeedMoreData => {},
        else => |e| return e,
    };
    try std.testing.expectError(error.NeedMoreData, rb.append(""));
    // "lo\x03" completes the frame → returns "hello"
    const payload = try rb.append("lo\x03");
    try std.testing.expectEqualStrings("hello", payload);
}

test "ReadBuf: error.BufferOverflow" {
    const alloc = std.testing.allocator;
    var rb = try ReadBuf.init(alloc, 256);
    defer rb.deinit(alloc);
    // Fill buffer to cap - 1 using no-\x03 chunks.
    const chunk: [64]u8 = [_]u8{0x41} ** 64;
    const full_chunks = (rb.buf.len - 1) / chunk.len;
    for (0..full_chunks) |_| {
        _ = rb.append(&chunk) catch |err| switch (err) {
            error.NeedMoreData => {},
            else => |e| return e,
        };
    }
    const rem = (rb.buf.len - 1) - (full_chunks * chunk.len);
    if (rem > 0) {
        _ = rb.append(chunk[0..rem]) catch |err| switch (err) {
            error.NeedMoreData => {},
            else => |e| return e,
        };
    }
    // Now len == buf.len - 1. Append 2 bytes → overflow.
    try std.testing.expectError(error.BufferOverflow, rb.append("xx"));
}

// ===========================================================================
// Tests: setState
// ===========================================================================

test "KlippyCtx.setState: transition" {
    const alloc = std.testing.allocator;
    const nb = try NullBus.init(alloc);
    defer nb.deinit(alloc);
    var ctx = try KlippyCtx.init(alloc, &nb.bus);
    defer ctx.deinit();

    try std.testing.expect(ctx.setState(.connecting));
    try std.testing.expectEqual(State.connecting, ctx.state);
    try std.testing.expect(ctx.setState(.startup));
    try std.testing.expectEqual(State.startup, ctx.state);
    try std.testing.expect(ctx.setState(.ready));
    try std.testing.expectEqual(State.ready, ctx.state);
}

test "KlippyCtx.setState: false when already in state" {
    const alloc = std.testing.allocator;
    const nb = try NullBus.init(alloc);
    defer nb.deinit(alloc);
    var ctx = try KlippyCtx.init(alloc, &nb.bus);
    defer ctx.deinit();

    try std.testing.expect(ctx.setState(.connecting));
    try std.testing.expect(!ctx.setState(.connecting));
}

test "KlippyCtx.setState: shutdown resets flags" {
    const alloc = std.testing.allocator;
    const nb = try NullBus.init(alloc);
    defer nb.deinit(alloc);
    var ctx = try KlippyCtx.init(alloc, &nb.bus);
    defer ctx.deinit();

    ctx.klippy_identified = true;
    ctx.klippy_started = true;
    try std.testing.expect(ctx.setState(.shutdown));
    try std.testing.expect(!ctx.klippy_identified);
    try std.testing.expect(!ctx.klippy_started);
}

// ---------------------------------------------------------------------------
// Tests: processStatusUpdateInner / processGcodeResponse
// ---------------------------------------------------------------------------

test "processStatusUpdateInner: shutdown webhook sets state and emits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nb = try NullBus.init(a);
    defer nb.deinit(a);
    var ctx = try KlippyCtx.init(a, &nb.bus);
    defer ctx.deinit();
    _ = ctx.setState(.ready);
    try std.testing.expectEqual(State.ready, ctx.state);

    // Build params: [0.0, {webhooks: {state: "shutdown"}}].
    var sd: std.json.ObjectMap = .empty;
    var wh: std.json.ObjectMap = .empty;
    try wh.put(a, "state", .{ .string = "shutdown" });
    try sd.put(a, "webhooks", .{ .object = wh });
    var arr = std.json.Array.init(a);
    try arr.append(.{ .float = 0.0 });
    try arr.append(.{ .object = sd });
    const params = std.json.Value{ .array = arr };

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try ctx.processStatusUpdateInner(io, params, true);
    try std.testing.expectEqual(State.shutdown, ctx.state);
}

test "processStatusUpdateInner: ready webhook sets state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nb = try NullBus.init(a);
    defer nb.deinit(a);
    var ctx = try KlippyCtx.init(a, &nb.bus);
    defer ctx.deinit();

    var sd: std.json.ObjectMap = .empty;
    var wh: std.json.ObjectMap = .empty;
    try wh.put(a, "state", .{ .string = "ready" });
    try sd.put(a, "webhooks", .{ .object = wh });
    var arr = std.json.Array.init(a);
    try arr.append(.{ .float = 0.0 });
    try arr.append(.{ .object = sd });
    const params = std.json.Value{ .array = arr };

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try ctx.processStatusUpdateInner(io, params, true);
    try std.testing.expectEqual(State.ready, ctx.state);
}

test "processStatusUpdateInner: no webhooks — no crash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nb = try NullBus.init(a);
    defer nb.deinit(a);
    var ctx = try KlippyCtx.init(a, &nb.bus);
    defer ctx.deinit();

    var sd: std.json.ObjectMap = .empty;
    try sd.put(a, "toolhead", .{ .object = .empty });
    var arr = std.json.Array.init(a);
    try arr.append(.{ .float = 0.0 });
    try arr.append(.{ .object = sd });
    const params = std.json.Value{ .array = arr };

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try ctx.processStatusUpdateInner(io, params, true);
}

test "processStatusUpdateInner: non-array returns early" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nb = try NullBus.init(a);
    defer nb.deinit(a);
    var ctx = try KlippyCtx.init(a, &nb.bus);
    defer ctx.deinit();

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try ctx.processStatusUpdateInner(io, .{ .object = .empty }, true);
}

test "processStatusUpdateInner: too-short array returns early" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nb = try NullBus.init(a);
    defer nb.deinit(a);
    var ctx = try KlippyCtx.init(a, &nb.bus);
    defer ctx.deinit();

    var arr = std.json.Array.init(a);
    try arr.append(.{ .float = 0.0 });

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try ctx.processStatusUpdateInner(io, .{ .array = arr }, true);
}

test "processStatusUpdateInner: non-object status_dict returns early" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nb = try NullBus.init(a);
    defer nb.deinit(a);
    var ctx = try KlippyCtx.init(a, &nb.bus);
    defer ctx.deinit();

    var arr = std.json.Array.init(a);
    try arr.append(.{ .float = 0.0 });
    try arr.append(.{ .string = "not-an-object" });

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try ctx.processStatusUpdateInner(io, .{ .array = arr }, true);
}

test "processGcodeResponse: emits server:gcode_response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nb = try NullBus.init(a);
    defer nb.deinit(a);
    var ctx = try KlippyCtx.init(a, &nb.bus);
    defer ctx.deinit();

    // Build frame: {"params": "gcode response text"}.
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "params", .{ .string = "ok" });
    const frame = std.json.Value{ .object = obj };

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try ctx.processGcodeResponse(io, frame);
}

test "processGcodeResponse: missing params — no crash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nb = try NullBus.init(a);
    defer nb.deinit(a);
    var ctx = try KlippyCtx.init(a, &nb.bus);
    defer ctx.deinit();

    const frame = std.json.Value{ .object = .empty };

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try ctx.processGcodeResponse(io, frame);
}

// ===========================================================================
// Fuzz tests
// ===========================================================================

test "fuzz frameDecode: never crashes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            smith.bytesWithHash(&buf, 0);

            if (frameDecode(&buf)) |f| {
                // If we got a frame, payload must not exceed consumed.
                std.debug.assert(f.payload.len < f.consumed);
                std.debug.assert(f.payload.len + 1 == f.consumed);
                // consumed must be within input
                std.debug.assert(f.consumed <= buf.len);
            }
        }
    }.run, .{});
}

test "fuzz frameEncode: round-trips through decode" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var payload: [256]u8 = undefined;
            smith.bytesWithHash(&payload, 0);

            // Ensure no embedded \x03 in payload (invalid for this protocol).
            // frameEncode must still not crash.
            var frame_buf: [512]u8 = undefined;
            if (payload.len + 1 > frame_buf.len) return;
            const framed = frameEncode(payload[0..@min(payload.len, frame_buf.len - 1)], &frame_buf);
            // The result ends with \x03.
            std.debug.assert(framed.len > 0);
            std.debug.assert(framed[framed.len - 1] == FrameEnd);

            // Decode must recover the original (up to embedded \x03).
            if (frameDecode(framed)) |dec| {
                std.debug.assert(dec.payload.len + 1 == dec.consumed);
            }
        }
    }.run, .{});
}

test "fuzz buildJsonRpcRequest: never crashes, always valid JSON" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var method: [64]u8 = undefined;
            var id: [32]u8 = undefined;
            var params: [128]u8 = undefined;
            smith.bytesWithHash(&method, 0);
            smith.bytesWithHash(&id, 1);
            smith.bytesWithHash(&params, 2);

            var buf: [512]u8 = undefined;
            const result = buildJsonRpcRequest(method[0..@min(63, method.len)], id[0..@min(31, id.len)], params[0..@min(127, params.len)], &buf) catch return;
            // Must start with { and end with }.
            if (result.len > 0) {
                std.debug.assert(result[0] == '{');
                std.debug.assert(result[result.len - 1] == '}');
            }
        }
    }.run, .{});
}

test "fuzz parseKlippyInfoResponse: never crashes on arbitrary JSON" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var json_bytes: [1024]u8 = undefined;
            smith.bytesWithHash(&json_bytes, 0);

            const parsed = std.json.parseFromSlice(
                std.json.Value,
                std.heap.smp_allocator,
                &json_bytes,
                .{ .allocate = .alloc_always },
            ) catch return;
            defer parsed.deinit();
            _ = parseKlippyInfoResponse(parsed.value);
            _ = getJsonRpcError(parsed.value);
            _ = isNotification(parsed.value);
        }
    }.run, .{});
}

test "fuzz ReadBuf.append: never crashes on arbitrary bytes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var data: [4096]u8 = undefined;
            smith.bytesWithHash(&data, 0);

            var rb = ReadBuf.init(std.heap.smp_allocator, 4096) catch return;
            defer rb.deinit(std.heap.smp_allocator);

            // Feed chunks until we get a frame or run out of space.
            var offset: usize = 0;
            while (offset < data.len) {
                const chunk = data[offset..@min(offset + 256, data.len)];
                const result = rb.append(chunk);
                if (result) |payload| {
                    // Frame extracted — consume and continue.
                    rb.consume(payload.len + 1);
                } else |err| {
                    if (err == error.BufferOverflow) break;
                    // error.NeedMoreData is fine — keep feeding.
                }
                offset += chunk.len;
            }
        }
    }.run, .{});
}
