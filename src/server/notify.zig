//! Notification bus: server → client JSON-RPC notification fan-out.
//!
//! Moonraker pushes events to websocket clients as JSON-RPC *notifications*
//! (requests with no `id`). The wire shape, lifted verbatim from
//! `websockets.py::WebsocketManager.notify_clients`:
//!
//!     msg = {'jsonrpc': "2.0", 'method': "notify_" + name}
//!     if data:                       # data is the *args tuple from the event
//!         msg['params'] = data       # => params is always a JSON ARRAY
//!
//! so a notification with payload looks like:
//!
//!     {"jsonrpc":"2.0","method":"notify_status_update","params":[{...},123.4]}
//!
//! and one with no payload omits `params` entirely:
//!
//!     {"jsonrpc":"2.0","method":"notify_klippy_ready"}
//!
//! `emit` takes the FULL method name (already including the `notify_` prefix —
//! see `names` below) and a `params` value that must be a JSON array (matching
//! Moonraker's `data` tuple). A `.null` params is treated as "no payload" and
//! the `params` key is omitted, exactly like Moonraker's falsy-`data` check.
//!
//! Fan-out ordering: every emission is serialized through the shared `Core`
//! lock, so concurrent emitters produce one deterministic total order (FIFO),
//! matching Moonraker's single event-loop parity. Within an emission frames are
//! delivered to each connection under that connection's own write mutex (see
//! `Connections.writeFrame`), so a notification can never interleave with a
//! JSON-RPC response on the same socket.
//!
//! Subscription gating: `notify_status_update` is delivered only to connections
//! subscribed to the relevant topics (Moonraker masks unsubscribed uids); every
//! other notification broadcasts to all live connections. `emitStatus` applies
//! the per-topic gate; `emit` broadcasts.
//!
//! Backpressure / slow clients: Moonraker's per-connection `message_buf` is an
//! UNBOUNDED list (websockets.py / common.py — no maxlen); it never drops or
//! closes a client for being slow, it only marks a connection closed when a
//! write raises `WebSocketClosedError`. We replicate that: writes go straight to
//! the socket under the write mutex (the blocked-reader model gives us natural
//! backpressure), and a failed write flags the connection `dead` (mirroring
//! `is_closed = True`) so its serve loop tears it down. No artificial queue
//! bound is imposed, to stay faithful to upstream behaviour.

const std = @import("std");
const Io = std.Io;

const Core = @import("core.zig").Core;
const connections = @import("connections.zig");
const Connections = connections.Connections;
const Connection = connections.Connection;

/// The 27 known Moonraker notification method names (authoritative list from
/// `api_scanner scan --source vendor/moonraker/moonraker` → `notifications[]`).
/// Components emit by symbol so the wire name lives in exactly one place.
pub const names = struct {
    pub const active_spool_set = "notify_active_spool_set";
    pub const agent_event = "notify_agent_event";
    pub const announcement_dismissed = "notify_announcement_dismissed";
    pub const announcement_update = "notify_announcement_update";
    pub const announcement_wake = "notify_announcement_wake";
    pub const button_event = "notify_button_event";
    pub const cpu_throttled = "notify_cpu_throttled";
    pub const filelist_changed = "notify_filelist_changed";
    pub const gcode_response = "notify_gcode_response";
    pub const history_changed = "notify_history_changed";
    pub const job_queue_changed = "notify_job_queue_changed";
    pub const klippy_disconnected = "notify_klippy_disconnected";
    pub const klippy_ready = "notify_klippy_ready";
    pub const klippy_shutdown = "notify_klippy_shutdown";
    pub const power_changed = "notify_power_changed";
    pub const proc_stat_update = "notify_proc_stat_update";
    pub const sensor_update = "notify_sensor_update";
    pub const service_state_changed = "notify_service_state_changed";
    pub const spoolman_status_changed = "notify_spoolman_status_changed";
    pub const status_update = "notify_status_update";
    pub const sudo_alert = "notify_sudo_alert";
    pub const update_refreshed = "notify_update_refreshed";
    pub const update_response = "notify_update_response";
    pub const user_created = "notify_user_created";
    pub const user_deleted = "notify_user_deleted";
    pub const user_logged_out = "notify_user_logged_out";
    pub const webcams_changed = "notify_webcams_changed";
};

/// Flat list of every notification name, for validation / iteration.
pub const all_names = [_][]const u8{
    names.active_spool_set,        names.agent_event,
    names.announcement_dismissed,  names.announcement_update,
    names.announcement_wake,       names.button_event,
    names.cpu_throttled,           names.filelist_changed,
    names.gcode_response,          names.history_changed,
    names.job_queue_changed,       names.klippy_disconnected,
    names.klippy_ready,            names.klippy_shutdown,
    names.power_changed,           names.proc_stat_update,
    names.sensor_update,           names.service_state_changed,
    names.spoolman_status_changed, names.status_update,
    names.sudo_alert,              names.update_refreshed,
    names.update_response,         names.user_created,
    names.user_deleted,            names.user_logged_out,
    names.webcams_changed,
};

/// True if `name` is one of the known notification method names.
pub fn isKnown(name: []const u8) bool {
    for (all_names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Build the JSON-RPC notification wire bytes for `method` + `params`.
///
/// `params` must be a JSON array value (Moonraker's `data` tuple); when it is
/// `.null` (or an empty array — matching Python's falsy check) the `params` key
/// is omitted entirely. Returns owned bytes allocated with `alloc`.
pub fn buildFrame(
    alloc: std.mem.Allocator,
    method: []const u8,
    params: std.json.Value,
) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    jw.beginObject() catch return error.OutOfMemory;
    jw.objectField("jsonrpc") catch return error.OutOfMemory;
    jw.write("2.0") catch return error.OutOfMemory;
    jw.objectField("method") catch return error.OutOfMemory;
    jw.write(method) catch return error.OutOfMemory;
    if (hasPayload(params)) {
        jw.objectField("params") catch return error.OutOfMemory;
        jw.write(params) catch return error.OutOfMemory;
    }
    jw.endObject() catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// Mirror Moonraker's `if data:` truthiness: omit `params` for null / empty
/// array (an empty object is still a payload, matching Python where `{}` is
/// falsy too — but Moonraker only ever passes list/tuple `data`, so we gate on
/// null and empty array).
fn hasPayload(params: std.json.Value) bool {
    return switch (params) {
        .null => false,
        .array => |a| a.items.len != 0,
        else => true,
    };
}

/// The notification bus. Holds borrowed references to the connection registry
/// and the serialized core; owns nothing else.
pub const NotifyBus = struct {
    core: *Core,
    conns: *Connections,

    pub fn init(core: *Core, conns: *Connections) NotifyBus {
        return .{ .core = core, .conns = conns };
    }

    /// Broadcast a notification to ALL live connections in FIFO total order.
    /// `params` must be a JSON array (or `.null` for no payload). Frames are
    /// built once and fanned out; dead connections are skipped (their serve
    /// loop reaps them). The whole emission runs under the `Core` lock so
    /// concurrent emits have one deterministic order.
    pub fn emit(
        self: *NotifyBus,
        io: Io,
        method: []const u8,
        params: std.json.Value,
    ) !void {
        self.core.lock(io);
        defer self.core.unlock(io);
        return self.fanout(io, method, params, null);
    }

    /// Like `emit`, but for status updates: deliver only to connections
    /// subscribed to `topic`. Matches Moonraker masking unsubscribed uids for
    /// `notify_status_update`.
    pub fn emitStatus(
        self: *NotifyBus,
        io: Io,
        method: []const u8,
        params: std.json.Value,
        topic: []const u8,
    ) !void {
        self.core.lock(io);
        defer self.core.unlock(io);
        return self.fanout(io, method, params, topic);
    }

    /// Core fan-out. Assumes the Core lock is held. Builds the frame once and
    /// writes it to every (optionally subscription-gated) connection. The
    /// registry is snapshotted first so per-connection write mutexes are never
    /// taken while holding the registry mutex.
    fn fanout(
        self: *NotifyBus,
        io: Io,
        method: []const u8,
        params: std.json.Value,
        topic: ?[]const u8,
    ) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const frame = try buildFrame(a, method, params);
        const snap = try self.conns.snapshot(io, a);
        for (snap) |conn| {
            if (topic) |t| {
                if (!self.conns.isSubscribed(io, conn, t)) continue;
            }
            // A failed write flags the connection dead; we swallow the error so
            // one dead client never stalls the broadcast to the rest.
            self.conns.writeFrame(io, conn, frame) catch {};
        }
    }
};

// === tests ================================================================

test "buildFrame: payload present => params is an array, no id" {
    const alloc = std.testing.allocator;
    var arr: std.json.Array = .init(alloc);
    defer arr.deinit();
    try arr.append(.{ .string = "hello" });
    try arr.append(.{ .integer = 42 });
    const params: std.json.Value = .{ .array = arr };

    const out = try buildFrame(alloc, names.gcode_response, params);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","method":"notify_gcode_response","params":["hello",42]}
    , out);
}

test "buildFrame: status_update params shape [status, eventtime]" {
    const alloc = std.testing.allocator;
    var status: std.json.ObjectMap = .empty;
    defer status.deinit(alloc);
    try status.put(alloc, "toolhead", .{ .string = "x" });

    var arr: std.json.Array = .init(alloc);
    defer arr.deinit();
    try arr.append(.{ .object = status });
    try arr.append(.{ .float = 123.4 });

    const out = try buildFrame(alloc, names.status_update, .{ .array = arr });
    defer alloc.free(out);
    // Exact Moonraker wire shape for notify_status_update.
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","method":"notify_status_update","params":[{"toolhead":"x"},123.4]}
    , out);
}

test "buildFrame: null params omits the params key" {
    const alloc = std.testing.allocator;
    const out = try buildFrame(alloc, names.klippy_ready, .null);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","method":"notify_klippy_ready"}
    , out);
}

test "buildFrame: empty array params omits the params key (falsy data)" {
    const alloc = std.testing.allocator;
    var arr: std.json.Array = .init(alloc);
    defer arr.deinit();
    const out = try buildFrame(alloc, names.klippy_shutdown, .{ .array = arr });
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","method":"notify_klippy_shutdown"}
    , out);
}

test "all_names has 27 entries and isKnown agrees" {
    try std.testing.expectEqual(@as(usize, 27), all_names.len);
    try std.testing.expect(isKnown(names.status_update));
    try std.testing.expect(isKnown("notify_gcode_response"));
    try std.testing.expect(!isKnown("notify_bogus"));
    try std.testing.expect(!isKnown(""));
    // Every symbol begins with the notify_ prefix.
    for (all_names) |n| try std.testing.expect(std.mem.startsWith(u8, n, "notify_"));
}

const RecordWriter = struct {
    alloc: std.mem.Allocator,
    frames: std.ArrayList([]u8) = .empty,

    fn deinit(self: *RecordWriter) void {
        for (self.frames.items) |f| self.alloc.free(f);
        self.frames.deinit(self.alloc);
    }

    fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *RecordWriter = @ptrCast(@alignCast(ctx));
        const dup = try self.alloc.dupe(u8, bytes);
        errdefer self.alloc.free(dup);
        try self.frames.append(self.alloc, dup);
    }
};

fn paramsArray(alloc: std.mem.Allocator, s: []const u8) !std.json.Value {
    var arr: std.json.Array = .init(alloc);
    try arr.append(.{ .string = s });
    return .{ .array = arr };
}

test "emit broadcasts to all connections in FIFO order" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var conns = Connections.init(alloc, &core);
    defer conns.deinit(io);

    const c1 = try conns.add(io);
    const c2 = try conns.add(io);
    var r1 = RecordWriter{ .alloc = alloc };
    defer r1.deinit();
    var r2 = RecordWriter{ .alloc = alloc };
    defer r2.deinit();
    conns.attachWriter(io, c1, &r1, RecordWriter.write);
    conns.attachWriter(io, c2, &r2, RecordWriter.write);

    var bus = NotifyBus.init(&core, &conns);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    try bus.emit(io, names.gcode_response, try paramsArray(aa, "first"));
    try bus.emit(io, names.gcode_response, try paramsArray(aa, "second"));

    // Both clients received both notifications, in emit order.
    for ([_]*RecordWriter{ &r1, &r2 }) |r| {
        try std.testing.expectEqual(@as(usize, 2), r.frames.items.len);
        try std.testing.expect(std.mem.indexOf(u8, r.frames.items[0], "first") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.frames.items[1], "second") != null);
    }
}

test "emitStatus delivers only to subscribed connections" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var conns = Connections.init(alloc, &core);
    defer conns.deinit(io);

    const sub = try conns.add(io);
    const unsub = try conns.add(io);
    var rs = RecordWriter{ .alloc = alloc };
    defer rs.deinit();
    var ru = RecordWriter{ .alloc = alloc };
    defer ru.deinit();
    conns.attachWriter(io, sub, &rs, RecordWriter.write);
    conns.attachWriter(io, unsub, &ru, RecordWriter.write);
    try conns.subscribe(io, sub, &.{"toolhead"});

    var bus = NotifyBus.init(&core, &conns);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try bus.emitStatus(io, names.status_update, try paramsArray(arena.allocator(), "s"), "toolhead");

    try std.testing.expectEqual(@as(usize, 1), rs.frames.items.len);
    try std.testing.expectEqual(@as(usize, 0), ru.frames.items.len);
}

test "emit skips a dead connection without stalling others" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var conns = Connections.init(alloc, &core);
    defer conns.deinit(io);

    const FailWriter = struct {
        fn write(_: *anyopaque, _: []const u8) anyerror!void {
            return error.WriteFailed;
        }
    };

    const dead = try conns.add(io);
    const live = try conns.add(io);
    var dummy: u8 = 0;
    var rl = RecordWriter{ .alloc = alloc };
    defer rl.deinit();
    conns.attachWriter(io, dead, &dummy, FailWriter.write);
    conns.attachWriter(io, live, &rl, RecordWriter.write);

    var bus = NotifyBus.init(&core, &conns);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try bus.emit(io, names.klippy_ready, try paramsArray(arena.allocator(), "x"));

    try std.testing.expect(conns.isDead(io, dead));
    try std.testing.expectEqual(@as(usize, 1), rl.frames.items.len);
}

const EmitCtx = struct {
    io: Io,
    bus: *NotifyBus,
    producer: u32,
    count: u32,
    alloc: std.mem.Allocator,
};

fn emitWorker(ctx: *EmitCtx) void {
    var i: u32 = 0;
    while (i < ctx.count) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(ctx.alloc);
        defer arena.deinit();
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}:{d}", .{ ctx.producer, i }) catch return;
        const p = paramsArray(arena.allocator(), s) catch return;
        ctx.bus.emit(ctx.io, names.gcode_response, p) catch return;
    }
}

test "fuzz_notify: concurrent emitters keep per-producer order, never lose a frame" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var seed: [2]u8 = undefined;
            smith.bytesWithHash(&seed, 0);
            const producers: u32 = 2 + (@as(u32, seed[0]) % 4); // 2..5
            const per: u32 = 1 + (@as(u32, seed[1]) % 32); // 1..32

            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();

            var core = Core.init();
            var conns = Connections.init(std.heap.smp_allocator, &core);
            defer conns.deinit(io);

            const c = try conns.add(io);
            var rec = RecordWriter{ .alloc = std.heap.smp_allocator };
            defer rec.deinit();
            conns.attachWriter(io, c, &rec, RecordWriter.write);

            var bus = NotifyBus.init(&core, &conns);

            const ctxs = try std.heap.smp_allocator.alloc(EmitCtx, producers);
            defer std.heap.smp_allocator.free(ctxs);
            for (ctxs, 0..) |*cx, p| cx.* = .{
                .io = io,
                .bus = &bus,
                .producer = @intCast(p),
                .count = per,
                .alloc = std.heap.smp_allocator,
            };

            const FutT = @TypeOf(io.async(emitWorker, .{&ctxs[0]}));
            const futs = try std.heap.smp_allocator.alloc(FutT, producers);
            defer std.heap.smp_allocator.free(futs);
            for (futs, 0..) |*f, p| f.* = io.async(emitWorker, .{&ctxs[p]});
            for (futs) |*f| f.await(io);

            // No loss.
            try std.testing.expectEqual(@as(usize, producers * per), rec.frames.items.len);

            // Per-producer relative order preserved: parse "<producer>:<seq>".
            const last = try std.heap.smp_allocator.alloc(?u32, producers);
            defer std.heap.smp_allocator.free(last);
            @memset(last, null);
            for (rec.frames.items) |f| {
                const ps = std.mem.indexOf(u8, f, "[\"").? + 2;
                const pe = std.mem.indexOfScalarPos(u8, f, ps, '"').?;
                const tok = f[ps..pe];
                const colon = std.mem.indexOfScalar(u8, tok, ':').?;
                const prod = try std.fmt.parseInt(u32, tok[0..colon], 10);
                const seq = try std.fmt.parseInt(u32, tok[colon + 1 ..], 10);
                if (last[prod]) |prev| try std.testing.expect(seq > prev);
                last[prod] = seq;
            }
        }
    }.run, .{});
}

test "fuzz_buildframe: arbitrary method/params never crash, always valid JSON" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const n = @as(usize, buf[0]) % buf.len;

            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            // Random method name (safe ascii) and a 1-element array payload.
            var name_buf: [32]u8 = undefined;
            var nlen: usize = 0;
            for (buf[0..@min(n, 16)]) |b| {
                name_buf[nlen] = 'a' + (b % 26);
                nlen += 1;
            }
            const method = if (nlen == 0) "notify_x" else name_buf[0..nlen];

            var arr: std.json.Array = .init(a);
            try arr.append(.{ .integer = @intCast(n) });
            const params: std.json.Value = if (n & 1 == 0) .{ .array = arr } else .null;

            const frame = try buildFrame(a, method, params);
            const parsed = std.json.parseFromSlice(std.json.Value, a, frame, .{}) catch
                return error.FuzzFrameNotJson;
            const obj = parsed.value.object;
            // Must be a notification: jsonrpc 2.0, method present, NO id.
            try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
            try std.testing.expect(obj.get("method") != null);
            try std.testing.expect(obj.get("id") == null);
        }
    }.run, .{});
}
