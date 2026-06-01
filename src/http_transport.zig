//! HTTP transport over `std.http.Server` (driven on top of an `std.Io.net`
//! stream — no hand-rolled HTTP).
//!
//! A single `Registry` + `Dispatcher` back both transports:
//!   * REST: look up the route by (method, path), run the handler under the
//!     serialized `Core`, then respond — wrapping the result as
//!     `{"result": <r>}` unless the endpoint sets `wrap_result = false`.
//!   * JSON-RPC: `POST /server/jsonrpc` feeds the raw body to `Dispatcher.handle`
//!     and returns the JSON-RPC envelope verbatim.
//!
//! Unknown route -> 404 with Moonraker's `{"error":{"code","message"}}` shape.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

const Core = @import("server/core.zig").Core;
const registry = @import("server/registry.zig");
const jsonrpc = @import("jsonrpc.zig");
const jv = @import("json/value.zig");
const connections = @import("server/connections.zig");
const ws = @import("transport/ws.zig");
const authz = @import("components/authorization.zig");

const Registry = registry.Registry;
const RequestType = registry.RequestType;
const TransportType = registry.TransportType;
const Route = registry.Route;

/// The JSON-RPC bridge path. POSTs here are dispatched as JSON-RPC.
pub const jsonrpc_path = "/server/jsonrpc";

/// Transport-aware auth hook. Returns true if the request is permitted.
/// `auth_required` is the endpoint's own flag; the hook may still bypass auth
/// for trusted transports (INTERNAL is always allowed).
pub const AuthHook = *const fn (transport: TransportType, auth_required: bool) bool;

/// Default hook: INTERNAL bypasses; everything else is allowed for now (real
/// token/trusted-client checks land in a later task). Endpoints with
/// `auth_required = false` skip the hook entirely (see `authorize`).
pub fn defaultAuthHook(transport: TransportType, auth_required: bool) bool {
    if (transport == .INTERNAL) return true;
    _ = auth_required;
    return true;
}

/// Apply the auth policy for a route. `auth_required = false` short-circuits to
/// allowed without consulting the hook.
pub fn authorize(hook: AuthHook, transport: TransportType, route: *const Route) bool {
    if (!route.auth_required) return true;
    return hook(transport, route.auth_required);
}

/// A built HTTP response: status + JSON body. The body is owned by the caller's
/// allocator (typically a per-request arena).
pub const Response = struct {
    status: std.http.Status,
    body: []const u8,
};

/// Context bundling the shared state a connection needs.
pub const Server = struct {
    io: Io,
    core: *Core,
    reg: *Registry,
    dispatcher: *jsonrpc.Dispatcher,
    hook: AuthHook = defaultAuthHook,
    /// Active WebSocket connection registry. Optional so non-WS callers/tests
    /// can construct a Server without it; when null, upgrade requests are
    /// rejected (400) instead of handed off.
    conns: ?*connections.Connections = null,
    /// Authorization component backing the auth hook. When set, requests are
    /// authenticated via the JWT → oneshot → API key → trusted chain; the
    /// resolved user is injected into the handler params under the reserved
    /// keys so access.* handlers can identify the caller. When null, the
    /// transport falls back to `hook` (spine default = allow).
    auth: ?*authz.AuthCtx = null,
};

/// Credentials carried by an HTTP request, extracted from headers and query.
pub const HttpCreds = struct {
    jwt: ?[]const u8 = null,
    oneshot: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    remote_ip: ?[]const u8 = null,
};

/// Comptime-known trampoline so a runtime handler pointer can be invoked inside
/// `Core.run` (which requires its function argument be comptime-known).
fn callHandler(
    handler: registry.HandlerFn,
    ctx: *anyopaque,
    params: std.json.Value,
    alloc: std.mem.Allocator,
) anyerror!std.json.Value {
    return handler(ctx, params, alloc);
}

/// Strip an optional query string and fragment from an HTTP target, returning
/// just the path component used for route matching.
pub fn pathOf(target: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const h = std.mem.indexOfScalar(u8, target, '#') orelse target.len;
    return target[0..@min(q, h)];
}

/// Parse a target's query string ("...?a=1&b=two") into a JSON object with
/// string values. Returns `.null` when there is no query string. Keys/values
/// are borrowed from `target` (no percent-decoding for the spine — values are
/// already raw). Allocates the ObjectMap in `alloc`.
pub fn queryParams(alloc: std.mem.Allocator, target: []const u8) !std.json.Value {
    const q_idx = std.mem.indexOfScalar(u8, target, '?') orelse return .null;
    var query = target[q_idx + 1 ..];
    // Drop a trailing fragment if present.
    if (std.mem.indexOfScalar(u8, query, '#')) |h| query = query[0..h];
    if (query.len == 0) return .null;

    var obj: std.json.ObjectMap = .empty;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const key = if (eq) |e| pair[0..e] else pair;
        const value = if (eq) |e| pair[e + 1 ..] else "";
        if (key.len == 0) continue;
        try obj.put(alloc, key, .{ .string = value });
    }
    if (obj.count() == 0) return .null;
    return .{ .object = obj };
}

/// Build a Moonraker-shaped error body `{"error":{"code":<code>,"message":<m>}}`.
fn errorBody(alloc: std.mem.Allocator, code: i64, message: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var w: std.json.Stringify = .{ .writer = &aw.writer };
    try w.beginObject();
    try w.objectField("error");
    try w.beginObject();
    try w.objectField("code");
    try w.write(code);
    try w.objectField("message");
    try w.write(message);
    try w.endObject();
    try w.endObject();
    return aw.toOwnedSlice();
}

/// Wrap a handler result as `{"result": <r>}`.
fn wrapResult(alloc: std.mem.Allocator, result: std.json.Value) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var w: std.json.Stringify = .{ .writer = &aw.writer };
    try w.beginObject();
    try w.objectField("result");
    try w.write(result);
    try w.endObject();
    return aw.toOwnedSlice();
}

/// Core request handling, independent of sockets, so it can be unit- and
/// fuzz-tested directly. Produces the response body + status for a parsed
/// request. `alloc` should be a per-request arena.
///
/// `transport` is the channel the request arrived on (HTTP for real sockets).
pub fn handleParsed(
    srv: *Server,
    transport: TransportType,
    method: ?RequestType,
    target: []const u8,
    body: []const u8,
    alloc: std.mem.Allocator,
) !Response {
    return handleParsedAuth(srv, transport, method, target, body, .{}, alloc);
}

/// Like `handleParsed` but with the request credentials extracted by the
/// socket layer (headers + query). When `srv.auth` is set these drive the real
/// authentication chain; otherwise they are ignored and the legacy `hook`
/// applies.
pub fn handleParsedAuth(
    srv: *Server,
    transport: TransportType,
    method: ?RequestType,
    target: []const u8,
    body: []const u8,
    creds: HttpCreds,
    alloc: std.mem.Allocator,
) !Response {
    const path = pathOf(target);

    // JSON-RPC bridge: POST /server/jsonrpc.
    if (method == .POST and std.mem.eql(u8, path, jsonrpc_path)) {
        const bytes = try srv.core.run(srv.io, jsonrpc.Dispatcher.handle, .{ srv.dispatcher, body, alloc });
        // A JSON-RPC notification yields empty bytes; respond 204-style with an
        // empty object to keep the body valid JSON.
        const out = if (bytes.len == 0) try alloc.dupe(u8, "{}") else bytes;
        return .{ .status = .ok, .body = out };
    }

    // Unsupported HTTP verb -> 404 (no route can match).
    const verb = method orelse {
        const b = try errorBody(alloc, 404, "Not Found");
        return .{ .status = .not_found, .body = b };
    };

    const route = srv.reg.lookup(verb, path) orelse {
        // Distinguish wrong-verb (405) from genuinely-unknown path (404).
        if (srv.reg.pathExists(path)) {
            const b = try errorBody(alloc, 405, "Method Not Allowed");
            return .{ .status = .method_not_allowed, .body = b };
        }
        const b = try errorBody(alloc, 404, "Not Found");
        return .{ .status = .not_found, .body = b };
    };

    // Auth gate. When the authorization component is wired, run the real
    // JWT → oneshot → API key → trusted chain; otherwise fall back to the
    // legacy hook (spine default = allow). INTERNAL always bypasses.
    var resolved_user: ?[]const u8 = null;
    if (srv.auth) |auth_ctx| {
        if (transport != .INTERNAL) {
            const outcome = authz.authenticateRequest(auth_ctx, alloc, transport, .{
                .jwt = creds.jwt,
                .oneshot = creds.oneshot,
                .api_key = creds.api_key,
                .remote_ip = creds.remote_ip,
            }, route.auth_required);
            switch (outcome) {
                .user => |u| resolved_user = u,
                .anonymous => {},
                .unauthorized => {
                    const b = try errorBody(alloc, 401, "Unauthorized");
                    return .{ .status = .unauthorized, .body = b };
                },
            }
        }
    } else if (!authorize(srv.hook, transport, route)) {
        const b = try errorBody(alloc, 401, "Unauthorized");
        return .{ .status = .unauthorized, .body = b };
    }

    // Assemble params. REST requests carry params two ways:
    //   * query string ("?raw=true&...") for GET/DELETE
    //   * a JSON object body for POST
    // Query params take object form with string values, matching Moonraker's
    // `WebRequest` arg coercion (handlers coerce strings to bool/int as needed).
    var params: std.json.Value = .null;
    var parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed) |*p| p.deinit();

    if (body.len > 0) {
        parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch null;
        if (parsed) |p| params = p.value;
    }

    if (params == .null) {
        params = try queryParams(alloc, target);
    }

    // Inject the resolved user, remote IP and HTTP method into the params so the
    // access.* handlers can identify the caller (mirrors Moonraker injecting the
    // current user / ip into the WebRequest). Only for access.* routes to avoid
    // polluting unrelated handlers.
    if (std.mem.startsWith(u8, path, "/access/")) {
        var obj: std.json.ObjectMap = switch (params) {
            .object => |o| o,
            else => .empty,
        };
        if (resolved_user) |u| {
            try obj.put(alloc, authz.current_user_key, .{ .string = u });
        }
        if (creds.remote_ip) |ip| {
            try obj.put(alloc, authz.current_ip_key, .{ .string = ip });
        }
        try obj.put(alloc, "_method", .{ .string = @tagName(verb) });
        params = .{ .object = obj };
    }

    // Run the handler under the serialized core. `Core.run` needs a
    // comptime-known function, so dispatch the runtime handler pointer through a
    // fixed trampoline.
    const result = srv.core.run(srv.io, callHandler, .{ route.handler, route.ctx, params, alloc }) catch |err| {
        const code: i64 = switch (err) {
            error.InvalidParams => 400,
            error.Forbidden => 403,
            error.NotFound => 404,
            else => 500,
        };
        const msg: []const u8 = switch (err) {
            error.InvalidParams => "Bad Request",
            error.Forbidden => "Forbidden",
            error.NotFound => "Not Found",
            else => "Internal Server Error",
        };
        const status: std.http.Status = switch (err) {
            error.InvalidParams => .bad_request,
            error.Forbidden => .forbidden,
            error.NotFound => .not_found,
            else => .internal_server_error,
        };
        const b = try errorBody(alloc, code, msg);
        return .{ .status = status, .body = b };
    };

    const out = if (route.wrap_result)
        try wrapResult(alloc, result)
    else
        try jv.serializeAlloc(alloc, result);

    return .{ .status = .ok, .body = out };
}

/// Adapter matching `io.CtxHandler` so `serveConn` can be wired straight into
/// `Listener.serveWith`. The opaque context is the `*Server`.
pub fn connHandler(ctx: *anyopaque, _: Io, stream: net.Stream) void {
    const srv: *Server = @ptrCast(@alignCast(ctx));
    serveConn(srv, stream);
}

/// Serve a single HTTP connection: build the std.http.Server over the stream,
/// receive the head, dispatch, and respond. Keeps the connection alive for
/// subsequent requests until the client closes or an error occurs.
pub fn serveConn(srv: *Server, stream: net.Stream) void {
    serveConnInner(srv, stream) catch {};
}

fn serveConnInner(srv: *Server, stream: net.Stream) !void {
    const io = srv.io;
    // 64KB reader buffer: this same buffer backs the WebSocket input after an
    // upgrade (std.http.WebSocket.input == server.reader.in), and
    // `readSmallMessage` requires each WS message fit it (else MessageOversize).
    // A generous size keeps ordinary JSON-RPC frames comfortably in-bounds.
    var sbuf: [64 * 1024]u8 = undefined;
    var s_r = stream.reader(io, &sbuf);
    var wbuf: [64 * 1024]u8 = undefined;
    var s_w = stream.writer(io, &wbuf);

    var http_server = std.http.Server.init(&s_r.interface, &s_w.interface);

    while (true) {
        var req = http_server.receiveHead() catch return;

        // WebSocket upgrade: hand the connection off to the WS transport. The
        // returned WebSocket borrows the HTTP reader/writer buffers above.
        switch (req.upgradeRequested()) {
            .websocket => |key| {
                const conns = srv.conns orelse {
                    req.respond("{\"error\":{\"code\":400,\"message\":\"WebSocket unsupported\"}}", .{
                        .status = .bad_request,
                        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
                    }) catch return;
                    return;
                };
                var web_socket = req.respondWebSocket(.{ .key = key orelse "" }) catch return;
                web_socket.flush() catch return;
                var ws_srv = ws.WsServer{
                    .io = io,
                    .core = srv.core,
                    .dispatcher = srv.dispatcher,
                    .conns = conns,
                };
                ws.serveWebSocket(&ws_srv, &web_socket);
                return; // connection consumed by the WS session
            },
            .other, .none => {},
        }

        // Read the body (if any) into the request arena.
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Capture head fields BEFORE reading the body: `readerExpectNone`
        // invalidates the string memory backing `req.head` (target etc.).
        const verb = RequestType.fromHttp(req.head.method);
        const target = alloc.dupe(u8, req.head.target) catch req.head.target;

        // Extract auth credentials from headers + query (duped into the arena,
        // since the header backing memory is invalidated once the body reader
        // runs). Only meaningful when the authorization component is wired.
        const creds = extractCreds(&req, target, alloc);

        const body: []const u8 = readBody(&req, alloc) catch &.{};

        const resp = handleParsedAuth(srv, .HTTP, verb, target, body, creds, alloc) catch
            Response{ .status = .internal_server_error, .body = "{\"error\":{\"code\":500,\"message\":\"Internal Server Error\"}}" };

        req.respond(resp.body, .{
            .status = resp.status,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        }) catch return;

        if (!req.head.keep_alive) return;
    }
}

/// Extract the auth credentials Moonraker recognizes from the request:
///   * JWT: "Authorization: Bearer <t>" / "X-Access-Token" / "?access_token="
///   * Oneshot: "?token="
///   * API key: "X-Api-Key"
/// All returned slices are duped into `alloc` so they survive the body read.
fn extractCreds(req: *std.http.Server.Request, target: []const u8, alloc: std.mem.Allocator) HttpCreds {
    var creds = HttpCreds{};

    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
            creds.jwt = alloc.dupe(u8, h.value) catch null;
        } else if (std.ascii.eqlIgnoreCase(h.name, "x-access-token")) {
            if (creds.jwt == null) creds.jwt = alloc.dupe(u8, h.value) catch null;
        } else if (std.ascii.eqlIgnoreCase(h.name, "x-api-key")) {
            creds.api_key = alloc.dupe(u8, h.value) catch null;
        }
    }

    // Query params: access_token (JWT) and token (oneshot).
    const qp = queryParams(alloc, target) catch std.json.Value{ .null = {} };
    if (qp == .object) {
        if (qp.object.get("access_token")) |v| switch (v) {
            .string => |s| if (creds.jwt == null) {
                creds.jwt = alloc.dupe(u8, s) catch null;
            },
            else => {},
        };
        if (qp.object.get("token")) |v| switch (v) {
            .string => |s| {
                creds.oneshot = alloc.dupe(u8, s) catch null;
            },
            else => {},
        };
    }

    return creds;
}

/// Read the full request body into `alloc`. Returns an empty slice when there
/// is no body.
fn readBody(req: *std.http.Server.Request, alloc: std.mem.Allocator) ![]const u8 {
    if (req.head.content_length == null or req.head.content_length.? == 0) return &.{};
    var rbuf: [16 * 1024]u8 = undefined;
    const reader = req.readerExpectNone(&rbuf);
    return reader.allocRemaining(alloc, .unlimited);
}

// --- tests ---------------------------------------------------------------

const methods = @import("core/methods.zig");

fn buildTestServer(alloc: std.mem.Allocator, io: Io, core: *Core, d: *jsonrpc.Dispatcher, reg: *Registry, info: *methods.ServerInfo) !Server {
    d.* = jsonrpc.Dispatcher.init(alloc);
    reg.* = Registry.init(alloc, d);
    info.* = .{};
    try methods.registerCore(reg, info);
    return Server{ .io = io, .core = core, .reg = reg, .dispatcher = d };
}

test "pathOf strips query and fragment" {
    try std.testing.expectEqualStrings("/server/info", pathOf("/server/info"));
    try std.testing.expectEqualStrings("/server/info", pathOf("/server/info?raw=true"));
    try std.testing.expectEqualStrings("/server/info", pathOf("/server/info#frag"));
}

test "queryParams parses key/value pairs into a string-valued object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expect((try queryParams(a, "/server/info")) == .null);

    const v = try queryParams(a, "/server/info?raw=true&n=2");
    const o = v.object;
    try std.testing.expectEqualStrings("true", o.get("raw").?.string);
    try std.testing.expectEqualStrings("2", o.get("n").?.string);
}

test "handleParsed: GET /server/info wraps result with klippy_connected false" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var d: jsonrpc.Dispatcher = undefined;
    var reg: Registry = undefined;
    var info: methods.ServerInfo = undefined;
    var srv = try buildTestServer(alloc, io, &core, &d, &reg, &info);
    defer d.deinit();
    defer reg.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const resp = try handleParsed(&srv, .HTTP, .GET, "/server/info", "", arena.allocator());
    try std.testing.expectEqual(std.http.Status.ok, resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"klippy_connected\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"api_version_string\":\"1.5.0\"") != null);
}

test "handleParsed: GET /server/config present" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var d: jsonrpc.Dispatcher = undefined;
    var reg: Registry = undefined;
    var info: methods.ServerInfo = undefined;
    var srv = try buildTestServer(alloc, io, &core, &d, &reg, &info);
    defer d.deinit();
    defer reg.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const resp = try handleParsed(&srv, .HTTP, .GET, "/server/config", "", arena.allocator());
    try std.testing.expectEqual(std.http.Status.ok, resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"config\"") != null);
}

test "handleParsed: POST /server/jsonrpc returns raw envelope matching REST" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var d: jsonrpc.Dispatcher = undefined;
    var reg: Registry = undefined;
    var info: methods.ServerInfo = undefined;
    var srv = try buildTestServer(alloc, io, &core, &d, &reg, &info);
    defer d.deinit();
    defer reg.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const rpc = try handleParsed(&srv, .HTTP, .POST, jsonrpc_path,
        \\{"jsonrpc":"2.0","method":"server.info","id":1}
    , a);
    try std.testing.expectEqual(std.http.Status.ok, rpc.status);

    // The JSON-RPC result payload must equal the REST result payload.
    const rest = try handleParsed(&srv, .HTTP, .GET, "/server/info", "", a);

    const rpc_parsed = try std.json.parseFromSlice(std.json.Value, a, rpc.body, .{});
    const rest_parsed = try std.json.parseFromSlice(std.json.Value, a, rest.body, .{});
    const rpc_result = rpc_parsed.value.object.get("result").?;
    const rest_result = rest_parsed.value.object.get("result").?;

    const rpc_s = try std.json.Stringify.valueAlloc(a, rpc_result, .{});
    const rest_s = try std.json.Stringify.valueAlloc(a, rest_result, .{});
    try std.testing.expectEqualStrings(rest_s, rpc_s);
}

test "handleParsed: unknown route is 404 with Moonraker error shape" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var d: jsonrpc.Dispatcher = undefined;
    var reg: Registry = undefined;
    var info: methods.ServerInfo = undefined;
    var srv = try buildTestServer(alloc, io, &core, &d, &reg, &info);
    defer d.deinit();
    defer reg.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const resp = try handleParsed(&srv, .HTTP, .GET, "/does/not/exist", "", arena.allocator());
    try std.testing.expectEqual(std.http.Status.not_found, resp.status);

    const p = try std.json.parseFromSlice(std.json.Value, arena.allocator(), resp.body, .{});
    const err = p.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, 404), err.get("code").?.integer);
    try std.testing.expectEqualStrings("Not Found", err.get("message").?.string);
}

test "authorize: auth_required=false skips the hook" {
    const route = Route{
        .path = "/x",
        .method = .GET,
        .wrap_result = true,
        .auth_required = false,
        .transports = &.{.HTTP},
        .ctx = undefined,
        .handler = undefined,
    };
    // A hook that always denies; with auth_required=false it must be bypassed.
    const denyHook = struct {
        fn f(_: TransportType, _: bool) bool {
            return false;
        }
    }.f;
    try std.testing.expect(authorize(denyHook, .HTTP, &route));
}

test "authorize: INTERNAL transport bypasses default hook" {
    const route = Route{
        .path = "/x",
        .method = .GET,
        .wrap_result = true,
        .auth_required = true,
        .transports = &.{.INTERNAL},
        .ctx = undefined,
        .handler = undefined,
    };
    // Default hook always allows INTERNAL even when auth is required.
    try std.testing.expect(authorize(defaultAuthHook, .INTERNAL, &route));
}

test "fuzz_http_transport: random request bytes never crash, always a well-formed response" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var d: jsonrpc.Dispatcher = undefined;
    var reg: Registry = undefined;
    var info: methods.ServerInfo = undefined;
    var srv = try buildTestServer(alloc, io, &core, &d, &reg, &info);
    defer d.deinit();
    defer reg.deinit();

    try std.testing.fuzz(&srv, struct {
        fn run(s: *Server, smith: *std.testing.Smith) anyerror!void {
            var raw: [256]u8 = undefined;
            smith.bytesWithHash(&raw, 0);
            const n = @as(usize, raw[0]) % raw.len;

            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            // Random verb, random target/body drawn from fuzz bytes.
            const verb: ?RequestType = switch (raw[0] % 4) {
                0 => .GET,
                1 => .POST,
                2 => .DELETE,
                else => null,
            };
            const split = if (n > 0) raw[1] % @as(u8, @intCast(@min(n, 255))) else 0;
            const target = raw[0..split];
            const body = raw[split..n];

            const resp = try handleParsed(s, .HTTP, verb, target, body, a);

            // Body must always be valid JSON (result/error envelope or {} ).
            const parsed = std.json.parseFromSlice(std.json.Value, a, resp.body, .{}) catch {
                return error.FuzzResponseNotValidJson;
            };
            _ = parsed;
            // Status must be a sane HTTP status.
            try std.testing.expect(@intFromEnum(resp.status) >= 200);
        }
    }.run, .{});
}
