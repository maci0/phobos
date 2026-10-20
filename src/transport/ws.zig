//! WebSocket transport.
//!
//! On an HTTP upgrade (`http_transport.serveConn` detects it and hands off
//! here), a per-connection record is allocated in the shared `Connections`
//! registry with a monotonic `u64` id (Moonraker's `sc.uid`). The connection
//! then loops reading masked client text frames, each a JSON-RPC request, and
//! replies with the JSON-RPC response over the same socket.
//!
//! Authentication follows Moonraker's `WebSocket.prepare`: the upgrade request
//! runs the HTTP auth chain. A failure does not refuse the socket; it marks
//! the connection `need_auth`, so methods with `auth_required` answer -32602
//! "Unauthorized" until `server.connection.identify` supplies a valid
//! `access_token` or `api_key`.
//!
//! Convergence: ordinary methods (e.g. `server.info`) go through the SAME
//! `Dispatcher` the HTTP transport uses, executed under the serialized `Core`,
//! so a request yields byte-identical results on either transport. Two methods
//! are WS-only because they need the *live* connection: `server.connection.identify`
//! and `server.websocket.id`. Those are handled here, bound to the in-scope
//! `*Connection`, before falling back to the shared dispatcher.
//!
//! Native WebSocket framing uses a lazily grown input buffer capped at 10 MiB.
//! The original small buffer is restored after a large message is consumed.

const std = @import("std");
const Io = std.Io;

const jsonrpc = @import("../jsonrpc.zig");
const webreq = @import("../json/params.zig");
const jv = @import("../json/value.zig");
const connections = @import("../server/connections.zig");
const klippy_connection = @import("../components/klippy_connection.zig");
const authz = @import("../components/authorization.zig");
const DeadlineWriter = @import("../util/deadline_writer.zig").DeadlineWriter;
const MessageBuffer = @import("../util/ws_message.zig").MessageBuffer;
const ExtensionsCtx = @import("../components/extensions.zig").ExtensionsCtx;
const max_agent_request_tasks = 16;

const Connections = connections.Connections;
const Connection = connections.Connection;

/// JSON-RPC method names handled directly in the WS layer (bound to the live
/// connection rather than a fixed registration context).
pub const identify_method = "server.connection.identify";
pub const websocket_id_method = "server.websocket.id";
const subscribe_method = "printer.objects.subscribe";

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

/// The dispatcher's view of a connection's sender.
fn callerOf(conn: *const Connection) jsonrpc.Caller {
    const need_auth = conn.need_auth.load(.acquire);
    return .{ .transport = .WEBSOCKET, .user = if (need_auth) null else conn.user, .remote_ip = conn.remote_ip, .need_auth = need_auth, .connection_id = conn.id };
}

/// Core WS request handling, independent of sockets so it is unit- and
/// fuzz-testable. Parses `request_json`; the connection-bound methods are
/// serviced here against `conn`, everything else goes to the shared
/// dispatcher, which takes the Core lock itself per-method. Returns owned
/// response bytes, empty when there is nothing to send.
///
/// `alloc` should be a per-request arena; the returned slice lives in it.
pub fn dispatchMessage(
    srv: *WsServer,
    conn: *Connection,
    request_json: []const u8,
    alloc: std.mem.Allocator,
) error{OutOfMemory}![]u8 {
    // Parse once; `parsed` lives in the request arena for the whole call.
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, request_json, .{}) catch {
        return jv.errorResponse(alloc, .null, -32700, "Parse error");
    };
    defer parsed.deinit();
    return dispatchParsedRoot(srv, conn, parsed.value, alloc);
}

fn dispatchParsedRoot(srv: *WsServer, conn: *Connection, root: std.json.Value, alloc: std.mem.Allocator) error{OutOfMemory}![]u8 {
    const caller = blk: {
        srv.conns.mutex.lockUncancelable(srv.io);
        defer srv.conns.mutex.unlock(srv.io);
        var snapshot = callerOf(conn);
        if (snapshot.user) |user| snapshot.user = try alloc.dupe(u8, user);
        break :blk snapshot;
    };
    defer if (caller.user) |user| alloc.free(user);
    // The dispatcher refuses over-deep input before any id is echoed.
    if (jv.exceedsDepth(root, jv.max_value_depth)) return srv.dispatcher.handleParsedRoot(caller, root, alloc);
    if (root == .array) {
        var out: Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        for (root.array.items) |item| {
            const response = if (item == .object)
                try dispatchParsedRoot(srv, conn, item, alloc)
            else
                try jv.errorResponse(alloc, .null, -32600, "Invalid Request");
            defer alloc.free(response);
            if (response.len == 0) continue;
            out.writer.writeByte(if (out.written().len == 0) '[' else ',') catch return error.OutOfMemory;
            out.writer.writeAll(response) catch return error.OutOfMemory;
        }
        if (out.written().len != 0) out.writer.writeByte(']') catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }
    if (root != .object) return srv.dispatcher.handleParsedRoot(caller, root, alloc);
    const obj = root.object;
    const jrpc = obj.get("jsonrpc") orelse .null;
    const method_v = obj.get("method") orelse .null;
    if (jrpc != .string or !std.mem.eql(u8, jrpc.string, "2.0") or method_v != .string) {
        return srv.dispatcher.handleParsedRoot(caller, root, alloc);
    }
    const method = method_v.string;
    const bound = std.mem.eql(u8, method, websocket_id_method) or std.mem.eql(u8, method, identify_method) or
        (srv.klippy != null and std.mem.eql(u8, method, subscribe_method));
    if (!bound) return srv.dispatcher.handleParsedRoot(caller, root, alloc);

    const id = obj.get("id") orelse .null;
    const params = obj.get("params") orelse std.json.Value{ .object = .empty };
    if (params != .object) return jv.errorResponse(alloc, id, -32602, "Invalid params:");
    if (conn.need_auth.load(.acquire)) {
        const entry = srv.dispatcher.methods.get(method);
        if (entry == null or entry.?.auth_required) return jv.errorResponse(alloc, id, -32602, "Unauthorized");
    }

    const result = (if (std.mem.eql(u8, method, websocket_id_method))
        idResult(alloc, "websocket_id", conn.id)
    else if (std.mem.eql(u8, method, identify_method))
        handleIdentify(srv, conn, params, alloc)
    else
        handleObjectsSubscribe(srv, conn, params, alloc)) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const reply = try jsonrpc.errorReply(err, params, alloc);
        return jv.errorResponse(alloc, id, reply.rpc_code, reply.message);
    };
    if (id == .null) return alloc.dupe(u8, &.{});
    return jv.successResponse(alloc, id, result);
}

/// Service a connection-scoped `printer.objects.subscribe`: register the
/// requested objects on `conn` (fan-out gating), add them to Klippy's aggregate
/// subscription + resubscribe with the template, and return the live status.
fn handleObjectsSubscribe(srv: *WsServer, conn: *Connection, params: std.json.Value, alloc: std.mem.Allocator) !std.json.Value {
    const objects = params.object.get("objects") orelse std.json.Value{ .object = .empty };
    return srv.klippy.?.subscribe(conn, objects, alloc);
}

/// Moonraker `_handle_identify` with `BaseRemoteConnection.authenticate`: an
/// `access_token` must be a valid JWT, else an `api_key` (when no user is set
/// yet) must match; a connection still needing auth without either fails.
fn handleIdentify(srv: *WsServer, conn: *Connection, params: std.json.Value, alloc: std.mem.Allocator) !std.json.Value {
    // Logout cannot run between credential validation and identity publication.
    srv.conns.core.lock(srv.io);
    defer srv.conns.core.unlock(srv.io);
    if (std.mem.eql(u8, conn.client.type, "agent") and conn.identified) return error.AgentDuplicate;
    if (srv.auth) |auth| {
        const token = params.object.get("access_token");
        const api_key = params.object.get("api_key");
        if (token) |t| {
            if (t != .string) return error.Unauthorized;
            const user = authz.validateJwt(auth, alloc, t.string) orelse return error.Unauthorized;
            try srv.conns.setUser(srv.io, conn, user);
        } else if (api_key != null and (conn.user == null or conn.need_auth.load(.acquire))) {
            if (api_key.? != .string or !authz.validateApiKey(auth, api_key.?.string)) return error.Unauthorized;
            try srv.conns.setUser(srv.io, conn, authz.api_user);
        } else if (conn.need_auth.load(.acquire)) return error.Unauthorized;
    }
    const client_type = try std.ascii.allocLowerString(alloc, getStr(params, "type"));
    defer alloc.free(client_type);
    if (std.mem.eql(u8, client_type, "agent")) if (srv.extensions) |extensions| {
        _ = try webreq.required([]const u8, params, "client_name");
        _ = try webreq.required([]const u8, params, "version");
        _ = try webreq.required([]const u8, params, "url");
        if (extensions.agents.contains(getStr(params, "client_name"))) return error.AgentDuplicate;
    };
    try srv.conns.identify(srv.io, conn, .{
        .name = getStr(params, "client_name"),
        .version = getStr(params, "version"),
        .type = client_type,
        .url = getStr(params, "url"),
    });
    if (std.mem.eql(u8, client_type, "agent")) if (srv.extensions) |extensions| try extensions.registerAgent(conn, alloc);
    return idResult(alloc, "connection_id", conn.id);
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
    /// Validates identify credentials. Null in bare unit tests.
    auth: ?*authz.AuthCtx = null,
    /// Socket frame deadline. Null for in-memory codec tests.
    writer: ?*DeadlineWriter = null,
    extensions: ?*ExtensionsCtx = null,
};

/// Serve an upgraded connection prepared by the HTTP transport. The caller
/// owns the registry entry and removes it after this function returns.
///
/// `ws` is an already-handshaked `std.http.Server.WebSocket`. Its input buffer
/// (the HTTP reader buffer) bounds the largest message accepted; oversize
/// frames terminate the connection.
pub fn serveWebSocket(srv: *WsServer, ws: *std.http.Server.WebSocket, conn: *Connection) void {
    // Bind the live socket as the connection's frame writer so the notification
    // bus can push notifications to it (under the per-connection write mutex)
    // while this loop is blocked in readSmallMessage. Detach on exit.
    var fw = FrameWriter{ .ws = ws, .writer = srv.writer };
    srv.conns.attachWriter(srv.io, conn, &fw, FrameWriter.write);
    defer srv.conns.detachWriter(srv.io, conn);
    defer if (srv.extensions) |extensions| {
        srv.conns.core.run(srv.io, ExtensionsCtx.removeAgent, .{ extensions, conn }) catch |err|
            std.debug.print("phobos: agent disconnect notification failed: {}\n", .{err});
    };

    serveLoop(srv, ws, conn);
}

/// Adapter exposing a `std.http.Server.WebSocket` as a `connections.WriteFn`.
/// The write mutex that serializes frames is the connection's, taken inside
/// `Connections.writeFrame`; this adapter just performs the raw send.
const FrameWriter = struct {
    ws: *std.http.Server.WebSocket,
    writer: ?*DeadlineWriter,

    fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *FrameWriter = @ptrCast(@alignCast(ctx));
        if (self.writer) |writer| writer.beginFrame();
        try self.ws.writeMessage(bytes, .text);
    }
};

/// Read and answer messages until the client closes or a read or write fails.
fn serveLoop(srv: *WsServer, ws: *std.http.Server.WebSocket, conn: *Connection) void {
    var input = MessageBuffer.init(std.heap.smp_allocator, ws.input);
    defer input.deinit();
    var tasks: Io.Group = .init;
    defer tasks.cancel(srv.io);
    var active_tasks: std.atomic.Value(u32) = .init(0);
    while (true) {
        const msg = input.read(ws) catch return;
        switch (msg.opcode) {
            .ping => {
                // Pongs are control frames; they still go under the write
                // mutex so they cannot split a data frame mid-flight.
                conn.write_mutex.lockUncancelable(srv.io);
                defer conn.write_mutex.unlock(srv.io);
                if (srv.writer) |writer| writer.beginFrame();
                ws.writeMessage(msg.data, .pong) catch return;
            },
            .text, .binary => {
                var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
                defer arena.deinit();
                var parsed = std.json.parseFromSlice(std.json.Value, std.heap.smp_allocator, msg.data, .{ .allocate = .alloc_always }) catch {
                    const response = jv.errorResponse(arena.allocator(), .null, -32700, "Parse error") catch return;
                    srv.conns.writeFrame(srv.io, conn, response) catch return;
                    continue;
                };
                if (srv.extensions) |extensions| consumeResponses(extensions, conn, parsed.value);
                if (needsAgentTask(parsed.value)) {
                    if (active_tasks.fetchAdd(1, .acq_rel) >= max_agent_request_tasks) {
                        _ = active_tasks.fetchSub(1, .acq_rel);
                        parsed.deinit();
                        return;
                    }
                    tasks.concurrent(srv.io, runAgentRequest, .{ srv, conn, parsed, &active_tasks }) catch {
                        _ = active_tasks.fetchSub(1, .acq_rel);
                        parsed.deinit();
                        return;
                    };
                    continue;
                }
                defer parsed.deinit();
                const resp = dispatchParsedRoot(srv, conn, parsed.value, arena.allocator()) catch return;
                if (resp.len == 0) continue;
                // Responses go through the per-connection write mutex so a
                // concurrently emitted notification cannot interleave.
                srv.conns.writeFrame(srv.io, conn, resp) catch return;
            },
            // continuation/connection_close/pong are not surfaced as messages.
            else => return,
        }
    }
}

fn consumeResponses(extensions: *ExtensionsCtx, conn: *Connection, root: std.json.Value) void {
    if (root == .array) {
        for (root.array.items) |item| if (item == .object) extensions.resolveResponse(conn, item);
    } else extensions.resolveResponse(conn, root);
}

fn needsAgentTask(root: std.json.Value) bool {
    if (root == .array) {
        for (root.array.items) |item| if (item == .object and needsAgentTask(item)) return true;
        return false;
    }
    if (root != .object) return false;
    const method = root.object.get("method") orelse return false;
    return method == .string and std.mem.eql(u8, method.string, "server.extensions.request");
}

fn runAgentRequest(srv: *WsServer, conn: *Connection, request: std.json.Parsed(std.json.Value), active: *std.atomic.Value(u32)) void {
    var owned = request;
    defer owned.deinit();
    defer _ = active.fetchSub(1, .acq_rel);
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const response = dispatchParsedRoot(srv, conn, owned.value, arena.allocator()) catch return;
    if (response.len != 0) srv.conns.writeFrame(srv.io, conn, response) catch return;
}

// --- tests ---------------------------------------------------------------

const methods = @import("../core/methods.zig");
const registry = @import("../server/registry.zig");
const Core = @import("../server/core.zig").Core;

const Fixture = struct {
    threaded: std.Io.Threaded,
    core: Core,
    dispatcher: jsonrpc.Dispatcher,
    reg: registry.Registry,
    info: methods.ServerInfo,
    conns: Connections,
    srv: WsServer,

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
    try f.reg.registerEndpoint(.{ .path = "/server/connection/identify", .methods = &.{.POST}, .transports = &.{.WEBSOCKET}, .auth_required = false }, @ptrCast(&f.info), wsOnlyStub);
    try f.reg.registerEndpoint(.{ .path = "/server/websocket/id", .methods = &.{.GET}, .transports = &.{.WEBSOCKET} }, @ptrCast(&f.info), wsOnlyStub);
    f.conns = Connections.init(alloc, &f.core);
    f.srv = .{ .io = f.threaded.io(), .dispatcher = &f.dispatcher, .conns = &f.conns };
}

fn wsOnlyStub(_: *anyopaque, _: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    return error.NotFound;
}

test "a connection that failed upgrade auth runs only auth-free methods" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try initFixture(&f, alloc);
    defer deinitFixture(&f);
    try f.reg.registerEndpoint(.{ .path = "/server/connection/identify", .methods = &.{.POST}, .transports = &.{.WEBSOCKET}, .auth_required = false }, @ptrCast(&f.info), wsOnlyStub);
    try f.reg.registerEndpoint(.{ .path = "/server/websocket/id", .methods = &.{.GET}, .transports = &.{.WEBSOCKET} }, @ptrCast(&f.info), wsOnlyStub);
    const conn = try f.conns.add(f.io(), false);
    conn.need_auth.store(true, .release);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    for ([_][]const u8{
        \\{"jsonrpc":"2.0","method":"server.info","id":1}
        ,
        \\{"jsonrpc":"2.0","method":"server.websocket.id","id":1}
    }) |req| {
        const resp = try dispatchMessage(&f.srv, conn, req, a);
        try std.testing.expectEqualStrings(
            \\{"jsonrpc":"2.0","error":{"code":-32602,"message":"Unauthorized"},"id":1}
        , resp);
    }
    // identify is auth_required=false; without an auth component it succeeds.
    const ok = try dispatchMessage(&f.srv, conn,
        \\{"jsonrpc":"2.0","method":"server.connection.identify","params":{"client_name":"x","version":"1","type":"web","url":"u"},"id":2}
    , a);
    try std.testing.expect(std.mem.indexOf(u8, ok, "\"connection_id\"") != null);
}

test "WS refuses a request whose id nests past max_value_depth" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try initFixture(&f, alloc);
    defer deinitFixture(&f);
    const conn = try f.conns.add(f.io(), false);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const depth = 300;
    const req = "{\"jsonrpc\":\"2.0\",\"method\":\"server.websocket.id\",\"id\":" ++ @as([depth]u8, @splat('[')) ++ @as([depth]u8, @splat(']')) ++ "}";
    const resp = try dispatchMessage(&f.srv, conn, req, arena.allocator());
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid Request"},"id":null}
    , resp);
}

test "WS batches retain connection-bound methods and notification semantics" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try initFixture(&f, alloc);
    defer deinitFixture(&f);
    const conn = try f.conns.add(f.io(), false);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const response = try dispatchMessage(&f.srv, conn,
        \\[{"jsonrpc":"2.0","method":"server.connection.identify","params":{"client_name":"batch"},"id":1},{"jsonrpc":"2.0","method":"server.websocket.id","id":2},{"jsonrpc":"2.0","method":"server.websocket.id"},[],{"jsonrpc":"2.0","method":"server.info","id":3}]
    , a);
    const result = try std.json.parseFromSliceLeaky(std.json.Value, a, response, .{});
    try std.testing.expectEqual(@as(usize, 4), result.array.items.len);
    try std.testing.expectEqualStrings("batch", conn.client.name);
    try std.testing.expectEqual(conn.id, @as(u64, @intCast(result.array.items[0].object.get("result").?.object.get("connection_id").?.integer)));
    try std.testing.expectEqual(conn.id, @as(u64, @intCast(result.array.items[1].object.get("result").?.object.get("websocket_id").?.integer)));
    try std.testing.expectEqual(@as(i64, -32600), result.array.items[2].object.get("error").?.object.get("code").?.integer);
    try std.testing.expect(result.array.items[3].object.get("result") != null);
}

test "revoked callers expose no authenticated user to auth-free handlers" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try initFixture(&f, alloc);
    defer deinitFixture(&f);
    const conn = try f.conns.add(f.io(), false);
    try f.conns.setUser(f.io(), conn, "alice");
    try std.testing.expectEqualStrings("alice", callerOf(conn).user.?);
    f.conns.invalidateUser(f.io(), "alice");
    try std.testing.expect(callerOf(conn).need_auth);
    try std.testing.expect(callerOf(conn).user == null);
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

    const conn = try f.conns.add(io, false);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const resp = try dispatchMessage(&f.srv, conn,
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

    const conn = try f.conns.add(io, false);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const resp = try dispatchMessage(&f.srv, conn,
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

    const c1 = try f.conns.add(io, false);
    const c2 = try f.conns.add(io, false);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const req =
        \\{"jsonrpc":"2.0","method":"server.connection.identify","params":{"client_name":"a","version":"1","type":"web","url":"u"},"id":1}
    ;
    const r1 = try dispatchMessage(&f.srv, c1, req, arena.allocator());
    const r2 = try dispatchMessage(&f.srv, c2, req, arena.allocator());

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

    const conn = try f.conns.add(io, false);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ws_resp = try dispatchMessage(&f.srv, conn,
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

    const conn = try f.conns.add(io, false);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const resp = try dispatchMessage(&f.srv, conn,
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

    const conn = try f.conns.add(io, false);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    // server.websocket.id as a notification: ran, but no bytes.
    const resp = try dispatchMessage(&f.srv, conn,
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
    const conn = try f.conns.add(io, false);

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

            const resp = try dispatchMessage(&c.f.srv, c.conn, input, a);
            if (resp.len == 0) return;

            const parsed = std.json.parseFromSlice(std.json.Value, a, resp, .{}) catch {
                return error.FuzzResponseNotValidJson;
            };
            // A batch answers with an array of responses.
            const items: []const std.json.Value = switch (parsed.value) {
                .array => |arr| arr.items,
                else => &.{parsed.value},
            };
            for (items) |item| {
                const obj = item.object;
                if (obj.get("result") == null and obj.get("error") == null) {
                    return error.FuzzNoResultOrError;
                }
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
