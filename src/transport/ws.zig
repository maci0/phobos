//! WebSocket transport.
//!
//! On an HTTP upgrade (`http_transport.serveConn` detects it and hands off
//! here), a per-connection record is allocated in the shared `Connections`
//! registry with a monotonic `u64` id (Moonraker's `sc.uid`). The connection
//! then loops reading masked client text frames, each a JSON-RPC request, and
//! replies with the JSON-RPC response over the same socket.
//!
//! Convergence: ordinary methods (e.g. `server.info`) go through the SAME
//! `Dispatcher` the HTTP transport uses, executed under the serialized `Core`,
//! so a request yields byte-identical results on either transport. Two methods
//! are WS-only because they need the *live* connection: `server.connection.identify`
//! and `server.websocket.id`. Those are handled here, bound to the in-scope
//! `*Connection`, before falling back to the shared dispatcher.
//!
//! Framing is std.http.Server.WebSocket — we never hand-roll RFC6455. `readSmallMessage`
//! requires each message fit the connection's input buffer, so the upgrade path
//! gives the HTTP reader a generously sized buffer (see http_transport).

const std = @import("std");
const Io = std.Io;

const Core = @import("../server/core.zig").Core;
const jsonrpc = @import("../jsonrpc.zig");
const jv = @import("../json/value.zig");
const connections = @import("../server/connections.zig");
const klippy_connection = @import("../components/klippy_connection.zig");

const Connections = connections.Connections;
const Connection = connections.Connection;

/// JSON-RPC method names handled directly in the WS layer (bound to the live
/// connection rather than a fixed registration context).
pub const identify_method = "server.connection.identify";
pub const websocket_id_method = "server.websocket.id";

/// Read a string field from a JSON-RPC params object, defaulting to "".
fn getStr(params: std.json.Value, key: []const u8) []const u8 {
    if (params != .object) return "";
    const v = params.object.get(key) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

/// Build `{"connection_id": <id>}` / `{"websocket_id": <id>}` style results.
fn idResult(alloc: std.mem.Allocator, key: []const u8, id: u64) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, key, .{ .integer = @intCast(id) });
    return .{ .object = obj };
}

/// Outcome of handling one WS request: owned response bytes (empty for
/// notifications). Caller frees with the same allocator passed to
/// `dispatchMessage`.
pub const Dispatch = struct {
    bytes: []u8,
};

/// Core WS request handling, independent of sockets so it is unit- and
/// fuzz-testable. Parses `request_json`; if the method is one of the
/// connection-bound WS methods it is serviced here against `conn` (updating
/// `conns` for identify); otherwise the request is forwarded verbatim to the
/// shared `dispatcher`, which takes the Core lock itself per-method. Returns
/// owned response bytes (empty slice for notifications / no-id requests).
///
/// `alloc` should be a per-request arena; the returned slice lives in it.
pub fn dispatchMessage(
    io: Io,
    conns: *Connections,
    conn: *Connection,
    dispatcher: *jsonrpc.Dispatcher,
    klippy: ?*klippy_connection.KlippyCtx,
    request_json: []const u8,
    alloc: std.mem.Allocator,
) error{OutOfMemory}![]u8 {
    // Parse the request ONCE. The connection-bound methods are serviced here off
    // the parsed root; everything else is forwarded to the shared dispatcher via
    // `handleParsedRoot`, which reuses this same parse instead of doing a second
    // one — WS is the hot client transport (every Mainsail/Fluidd RPC), so the
    // saved parse + arena allocations matter. `alloc` is the per-request arena, so
    // `parsed` lives for the whole call (the arena ignores the deinit's frees).
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, request_json, .{}) catch {
        // Malformed — let the dispatcher emit the canonical JSON-RPC parse error.
        return dispatcher.handle(request_json, alloc);
    };
    defer parsed.deinit();
    const root = parsed.value;

    const peek: ?struct { method: []const u8, id: std.json.Value, is_notification: bool } = blk: {
        if (root != .object) break :blk null;
        const obj = root.object;
        const method_v = obj.get("method") orelse break :blk null;
        if (method_v != .string) break :blk null;
        // jsonrpc version must be 2.0 to be a valid request; let the shared
        // dispatcher own that validation for everything except our methods.
        const jrpc = obj.get("jsonrpc") orelse break :blk null;
        if (jrpc != .string or !std.mem.eql(u8, jrpc.string, "2.0")) break :blk null;
        const id_v = obj.get("id");
        // No dup needed: `parsed` outlives the call (lives in the request arena).
        break :blk .{ .method = method_v.string, .id = id_v orelse .null, .is_notification = (id_v == null) };
    };

    if (peek) |p| {
        if (std.mem.eql(u8, p.method, websocket_id_method)) {
            if (p.is_notification) return alloc.dupe(u8, &.{});
            const result = idResult(alloc, "websocket_id", conn.id) catch return error.OutOfMemory;
            return jv.successResponse(alloc, p.id, result);
        }
        if (std.mem.eql(u8, p.method, identify_method)) {
            const params: std.json.Value = if (root == .object)
                (root.object.get("params") orelse .null)
            else
                .null;
            return handleIdentify(io, conns, conn, params, p.id, p.is_notification, alloc);
        }
        // printer.objects.subscribe is connection-scoped: register this
        // connection's object subscriptions so status pushes are fanned out to
        // it, add the objects to Klippy's aggregate subscription (re-subscribing
        // WITH the response_template so pushes keep flowing), and return the
        // current status. Handled here — NOT via the raw proxy, which would drop
        // the template and never register the connection.
        if (klippy != null and std.mem.eql(u8, p.method, "printer.objects.subscribe")) {
            return handleObjectsSubscribe(io, conns, conn, klippy.?, request_json, p.id, p.is_notification, alloc);
        }
    }

    // Everything else: the shared dispatcher, reusing the parse above. Takes the
    // Core lock per-method (skipping off_core reads) — identical convergence point
    // to the HTTP JSON-RPC bridge.
    return dispatcher.handleParsedRoot(root, alloc);
}

/// Service a connection-scoped `printer.objects.subscribe`: register the
/// requested objects on `conn` (fan-out gating), add them to Klippy's aggregate
/// subscription + resubscribe with the template, and return the live status.
fn handleObjectsSubscribe(
    io: Io,
    conns: *Connections,
    conn: *Connection,
    klippy: *klippy_connection.KlippyCtx,
    request_json: []const u8,
    id: std.json.Value,
    is_notification: bool,
    alloc: std.mem.Allocator,
) error{OutOfMemory}![]u8 {
    // Collect the requested object names from params.objects and register them.
    {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, request_json, .{}) catch null;
        defer if (parsed) |*pp| pp.deinit();
        if (parsed) |pp| {
            const params: std.json.Value = if (pp.value == .object) (pp.value.object.get("params") orelse .null) else .null;
            const objects: std.json.Value = if (params == .object) (params.object.get("objects") orelse .null) else .null;
            if (objects == .object) {
                var names: std.ArrayList([]const u8) = .empty;
                defer names.deinit(alloc);
                var it = objects.object.iterator();
                while (it.next()) |e| {
                    klippy.addSubscriptionObject(e.key_ptr.*) catch {};
                    names.append(alloc, e.key_ptr.*) catch {};
                }
                // Register on the connection (conns.subscribe dupes the topics).
                conns.subscribe(io, conn, names.items) catch {};
            }
        }
    }

    // Resubscribe Klippy to the aggregate set (with template) + get live status.
    const result = klippy.subscribeAggregate(alloc) catch |err| {
        if (is_notification) return alloc.dupe(u8, &.{});
        const msg = std.fmt.allocPrint(alloc, "objects.subscribe failed: {s}", .{@errorName(err)}) catch "subscribe failed";
        return jv.errorResponse(alloc, id, -32603, msg) catch error.OutOfMemory;
    };
    if (is_notification) return alloc.dupe(u8, &.{});
    return jv.successResponse(alloc, id, result);
}

fn handleIdentify(
    io: Io,
    conns: *Connections,
    conn: *Connection,
    params: std.json.Value,
    id: std.json.Value,
    is_notification: bool,
    alloc: std.mem.Allocator,
) error{OutOfMemory}![]u8 {
    conns.identify(io, conn, .{
        .name = getStr(params, "client_name"),
        .version = getStr(params, "version"),
        .type = getStr(params, "type"),
        .url = getStr(params, "url"),
    }) catch return error.OutOfMemory;
    if (is_notification) return alloc.dupe(u8, &.{});
    const result = idResult(alloc, "connection_id", conn.id) catch return error.OutOfMemory;
    return jv.successResponse(alloc, id, result);
}

/// Bundle of shared state a WS connection needs. Mirrors `http_transport.Server`
/// but adds the `Connections` registry.
pub const WsServer = struct {
    io: Io,
    dispatcher: *jsonrpc.Dispatcher,
    conns: *Connections,
    /// Klippy bridge, so connection-scoped `printer.objects.subscribe` can
    /// register the connection + resubscribe Klippy. Null in bare unit tests.
    klippy: ?*klippy_connection.KlippyCtx = null,
};

/// Serve a single upgraded WebSocket connection to completion: register the
/// connection, loop reading text frames and replying with JSON-RPC responses,
/// and on close/error remove the connection from the registry.
///
/// `ws` is an already-handshaked `std.http.Server.WebSocket`. Its input buffer
/// (the HTTP reader buffer) bounds the largest message accepted; oversize
/// frames terminate the connection.
pub fn serveWebSocket(srv: *WsServer, ws: *std.http.Server.WebSocket) void {
    const conn = srv.conns.add(srv.io) catch return;
    defer srv.conns.remove(srv.io, conn);

    // Bind the live socket as the connection's frame writer so the notification
    // bus can push notifications to it (under the per-connection write mutex)
    // while this loop is blocked in readSmallMessage. Detach on exit.
    var fw = FrameWriter{ .ws = ws };
    srv.conns.attachWriter(srv.io, conn, &fw, FrameWriter.write);
    defer srv.conns.detachWriter(srv.io, conn);

    serveLoop(srv, ws, conn) catch {};
}

/// Serve the `/klippysocket` bridge socket (Moonraker's `BridgeSocket`).
/// Relays raw \\x03-delimited JSON-RPC frames between the WebSocket client and
/// the Klippy Unix-domain socket.
///
/// When Klippy is not connected the socket is closed with code 1001 + reason
/// "Klippy Disconnected", matching Moonraker's `BridgeSocket.close_socket`.
pub fn serveBridge(io: Io, ws: *std.http.Server.WebSocket, klippy: *klippy_connection.KlippyCtx) void {
    // When no Klippy connection, close immediately (Moonraker-compatible).
    if (!klippy.isConnected()) {
        var payload: [2 + 19]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], 1001, .big);
        const reason = "Klippy Disconnected";
        @memcpy(payload[2..][0..reason.len], reason);
        ws.writeMessage(payload[0 .. 2 + reason.len], .connection_close) catch {};
        ws.flush() catch {};
        return;
    }

    var bw = BridgeWsWriter{
        .ws = ws,
        .io = io,
        .write_mutex = std.Io.Mutex.init,
    };
    const bridge = klippy_connection.Bridge{
        .ctx = @ptrCast(&bw),
        .write_fn = BridgeWsWriter.writeBridge,
    };

    klippy.addBridge(bridge) catch {
        // Failed to register — close the socket.
        ws.writeMessage(&.{}, .connection_close) catch {};
        ws.flush() catch {};
        return;
    };
    defer klippy.removeBridge(bridge);

    // Relay WS text/binary messages to Klippy.
    while (true) {
        const msg = ws.readSmallMessage() catch |err| switch (err) {
            error.ConnectionClose => return,
            else => return,
        };
        switch (msg.opcode) {
            .text, .binary => {
                klippy.sendRaw(msg.data) catch |err| switch (err) {
                    error.KlippyDisconnected => {
                        ws.writeMessage(&.{}, .connection_close) catch {};
                        ws.flush() catch {};
                        return;
                    },
                    else => continue,
                };
            },
            .ping => {
                bw.write_mutex.lockUncancelable(io);
                defer bw.write_mutex.unlock(io);
                ws.writeMessage(msg.data, .pong) catch return;
            },
            else => return,
        }
    }
}

/// Per-bridge write adapter. Serialises writes from KlippyCtx's background
/// thread and handler threads so WS frames never interleave.
const BridgeWsWriter = struct {
    ws: *std.http.Server.WebSocket,
    io: Io,
    write_mutex: std.Io.Mutex,

    fn writeBridge(ctx: *anyopaque, payload: []const u8) anyerror!void {
        const self: *BridgeWsWriter = @ptrCast(@alignCast(ctx));
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        try self.ws.writeMessage(payload, .text);
    }
};

/// Adapter exposing a `std.http.Server.WebSocket` as a `connections.WriteFn`.
/// The write mutex that serializes frames is the connection's, taken inside
/// `Connections.writeFrame`; this adapter just performs the raw send.
const FrameWriter = struct {
    ws: *std.http.Server.WebSocket,

    fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *FrameWriter = @ptrCast(@alignCast(ctx));
        try self.ws.writeMessage(bytes, .text);
    }
};

fn serveLoop(srv: *WsServer, ws: *std.http.Server.WebSocket, conn: *Connection) !void {
    while (true) {
        const msg = ws.readSmallMessage() catch |err| switch (err) {
            // Clean client close or any framing/read failure: end the session.
            error.ConnectionClose => return,
            else => return,
        };

        switch (msg.opcode) {
            .ping => {
                // Reply with a pong carrying the ping payload (pongs are skipped
                // automatically by readSmallMessage on the read side). Pongs are
                // control frames, not data; they still go under the write mutex
                // so they cannot split a data frame mid-flight.
                conn.write_mutex.lockUncancelable(srv.io);
                defer conn.write_mutex.unlock(srv.io);
                ws.writeMessage(msg.data, .pong) catch return;
                continue;
            },
            .text, .binary => {
                var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
                defer arena.deinit();
                const alloc = arena.allocator();

                const resp = dispatchMessage(
                    srv.io,
                    srv.conns,
                    conn,
                    srv.dispatcher,
                    srv.klippy,
                    msg.data,
                    alloc,
                ) catch return;

                // Notifications (and no-id requests) produce no response bytes.
                if (resp.len == 0) continue;
                // Route the response through the per-connection write mutex so a
                // concurrently-emitted notification can never interleave with it.
                srv.conns.writeFrame(srv.io, conn, resp) catch return;
            },
            // continuation/connection_close/pong are not surfaced as messages.
            else => return,
        }
    }
}

// --- tests ---------------------------------------------------------------

const methods = @import("../core/methods.zig");
const registry = @import("../server/registry.zig");

const Fixture = struct {
    threaded: std.Io.Threaded,
    core: Core,
    dispatcher: jsonrpc.Dispatcher,
    reg: registry.Registry,
    info: methods.ServerInfo,
    conns: Connections,

    fn io(self: *Fixture) Io {
        return self.threaded.io();
    }
};

fn initFixture(f: *Fixture, alloc: std.mem.Allocator) !void {
    f.threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    f.core = Core.init();
    f.dispatcher = jsonrpc.Dispatcher.init(alloc);
    f.reg = registry.Registry.init(alloc, &f.dispatcher);
    f.info = .{};
    try methods.registerCore(&f.reg, &f.info);
    f.conns = Connections.init(alloc, &f.core);
}

fn deinitFixture(f: *Fixture) void {
    f.conns.deinit(f.io());
    f.reg.deinit();
    f.dispatcher.deinit();
    f.threaded.deinit();
}

test "server.websocket.id returns the connection's id" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try initFixture(&f, alloc);
    defer deinitFixture(&f);
    const io = f.io();

    const conn = try f.conns.add(io);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const resp = try dispatchMessage(io, &f.conns, conn, &f.dispatcher, null,
        \\{"jsonrpc":"2.0","method":"server.websocket.id","id":7}
    , arena.allocator());

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), resp, .{});
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqual(@as(i64, @intCast(conn.id)), result.get("websocket_id").?.integer);
    try std.testing.expectEqual(@as(i64, 7), parsed.value.object.get("id").?.integer);
}

test "server.connection.identify returns connection_id and stores client data" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try initFixture(&f, alloc);
    defer deinitFixture(&f);
    const io = f.io();

    const conn = try f.conns.add(io);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const resp = try dispatchMessage(io, &f.conns, conn, &f.dispatcher, null,
        \\{"jsonrpc":"2.0","method":"server.connection.identify","params":{"client_name":"mainsail","version":"1.2","type":"web","url":"http://h"},"id":3}
    , arena.allocator());

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), resp, .{});
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqual(@as(i64, @intCast(conn.id)), result.get("connection_id").?.integer);

    try std.testing.expect(conn.identified);
    try std.testing.expectEqualStrings("mainsail", conn.client.name);
    try std.testing.expectEqualStrings("web", conn.client.type);
}

test "two connections get distinct monotonic ids via identify" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try initFixture(&f, alloc);
    defer deinitFixture(&f);
    const io = f.io();

    const c1 = try f.conns.add(io);
    const c2 = try f.conns.add(io);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const req =
        \\{"jsonrpc":"2.0","method":"server.connection.identify","params":{"client_name":"a","version":"1","type":"web","url":"u"},"id":1}
    ;
    const r1 = try dispatchMessage(io, &f.conns, c1, &f.dispatcher, null, req, arena.allocator());
    const r2 = try dispatchMessage(io, &f.conns, c2, &f.dispatcher, null, req, arena.allocator());

    const p1 = try std.json.parseFromSlice(std.json.Value, arena.allocator(), r1, .{});
    const p2 = try std.json.parseFromSlice(std.json.Value, arena.allocator(), r2, .{});
    const id1 = p1.value.object.get("result").?.object.get("connection_id").?.integer;
    const id2 = p2.value.object.get("result").?.object.get("connection_id").?.integer;
    try std.testing.expect(id2 > id1);
}

test "server.info over WS dispatch equals HTTP result payload" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try initFixture(&f, alloc);
    defer deinitFixture(&f);
    const io = f.io();

    const conn = try f.conns.add(io);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ws_resp = try dispatchMessage(io, &f.conns, conn, &f.dispatcher, null,
        \\{"jsonrpc":"2.0","method":"server.info","id":1}
    , a);

    // Direct dispatcher call models the HTTP JSON-RPC bridge.
    const http_resp = try f.dispatcher.handle(
        \\{"jsonrpc":"2.0","method":"server.info","id":1}
    , a);

    const ws_parsed = try std.json.parseFromSlice(std.json.Value, a, ws_resp, .{});
    const http_parsed = try std.json.parseFromSlice(std.json.Value, a, http_resp, .{});
    const ws_result = ws_parsed.value.object.get("result").?;
    const http_result = http_parsed.value.object.get("result").?;
    const ws_s = try std.json.Stringify.valueAlloc(a, ws_result, .{});
    const http_s = try std.json.Stringify.valueAlloc(a, http_result, .{});
    try std.testing.expectEqualStrings(http_s, ws_s);
}

test "unknown method over WS returns -32601" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try initFixture(&f, alloc);
    defer deinitFixture(&f);
    const io = f.io();

    const conn = try f.conns.add(io);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const resp = try dispatchMessage(io, &f.conns, conn, &f.dispatcher, null,
        \\{"jsonrpc":"2.0","method":"does.not.exist","id":9}
    , arena.allocator());

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), resp, .{});
    const err = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32601), err.get("code").?.integer);
    try std.testing.expectEqual(@as(i64, 9), parsed.value.object.get("id").?.integer);
}

test "notification (no id) over WS produces no response bytes" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try initFixture(&f, alloc);
    defer deinitFixture(&f);
    const io = f.io();

    const conn = try f.conns.add(io);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    // server.websocket.id as a notification: ran, but no bytes.
    const resp = try dispatchMessage(io, &f.conns, conn, &f.dispatcher, null,
        \\{"jsonrpc":"2.0","method":"server.websocket.id"}
    , arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), resp.len);
}

test "fuzz_ws: random bytes through dispatchMessage never crash, valid JSON or empty" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try initFixture(&f, alloc);
    defer deinitFixture(&f);
    const io = f.io();
    const conn = try f.conns.add(io);

    const Ctx = struct { f: *Fixture, conn: *Connection, io: Io };
    var ctx = Ctx{ .f = &f, .conn = conn, .io = io };

    try std.testing.fuzz(&ctx, struct {
        fn run(c: *Ctx, smith: *std.testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const len = @as(usize, buf[0]) % buf.len;
            const input = buf[0..len];

            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const resp = try dispatchMessage(c.io, &c.f.conns, c.conn, &c.f.dispatcher, null, input, a);
            if (resp.len == 0) return;

            const parsed = std.json.parseFromSlice(std.json.Value, a, resp, .{}) catch {
                return error.FuzzResponseNotValidJson;
            };
            const obj = parsed.value.object;
            if (obj.get("result") == null and obj.get("error") == null) {
                return error.FuzzNoResultOrError;
            }
        }
    }.run, .{});
}

test "fuzz_ws_getstr: getStr never crashes on arbitrary params" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [128]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const n = @as(usize, buf[0]) % buf.len;

            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            // Build a params object with a random string value under "type".
            var obj: std.json.ObjectMap = .empty;
            try obj.put(a, "type", .{ .string = buf[0..n] });
            const params: std.json.Value = .{ .object = obj };
            _ = getStr(params, "type");
            _ = getStr(params, "missing");
            _ = getStr(.null, "type");
        }
    }.run, .{});
}
