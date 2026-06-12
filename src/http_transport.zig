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
const file_manager = @import("components/file_manager.zig");
const klippy_connection = @import("components/klippy_connection.zig");

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

/// Fallback hook used only when no authorization component is wired (e.g. unit
/// tests that build a bare Server). The real daemon path sets `Server.auth` to
/// the AuthCtx, and request auth then runs the full JWT → oneshot → API key →
/// trusted-client chain in `handleParsedAuth` (this hook is not consulted).
/// INTERNAL always bypasses; `auth_required = false` skips auth (see `authorize`).
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
    /// When set, the transport streams this file from disk in fixed-size chunks
    /// instead of sending `body` — so large gcode downloads use constant memory
    /// rather than buffering the whole file in the request arena. `body` is
    /// ignored when this is non-null.
    file_path: ?[]const u8 = null,
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
    /// File manager context backing upload/download + the
    /// GET/DELETE /server/files/<root>/<path> routes. Optional so tests can
    /// build a Server without it.
    file_ctx: ?*file_manager.FileCtx = null,
    /// Absolute datadir; used only for diagnostics around the file routes.
    datadir: ?[]const u8 = null,
    /// Klippy Unix-socket bridge context. When set, /klippysocket WebSocket
    /// connections relay frames to/from the live Klippy process.
    klippy_ctx: ?*klippy_connection.KlippyCtx = null,
    /// Allowed CORS origins from `[authorization] cors_domains`. An entry of `*`
    /// matches any origin; `*.example.com` matches subdomains; otherwise an exact
    /// match. Empty = no CORS (same-origin only, like Moonraker's default).
    cors_domains: []const []const u8 = &.{},
};

/// Credentials carried by an HTTP request, extracted from headers and query.
pub const HttpCreds = struct {
    jwt: ?[]const u8 = null,
    oneshot: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    remote_ip: ?[]const u8 = null,
    /// Request `Origin` header (for CORS), duped into the arena.
    origin: ?[]const u8 = null,
};

/// Shared dispatch trampoline (see jsonrpc.callHandlerTramp) — one definition
/// for both transports.
const callHandler = jsonrpc.callHandlerTramp;

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

/// Handle GET /server/redirect. Mirrors Moonraker's RedirectHandler under the
/// default configuration (no CORS domains): the URL is taken from `?url=` or a
/// JSON body `{"url": ...}`, and — because no origin can pass the CORS check —
/// the request is always rejected with a 400 error envelope. The two distinct
/// messages ("No url argument provided" vs "Unauthorized URL redirect: <url>")
/// match Moonraker exactly so clients see identical behavior.
pub fn handleRedirect(target: []const u8, body: []const u8, alloc: std.mem.Allocator) !Response {
    // Resolve the url: query string takes precedence, then JSON body.
    var url: ?[]const u8 = null;
    const qp = try queryParams(alloc, target);
    if (qp == .object) {
        if (qp.object.get("url")) |v| switch (v) {
            .string => |s| url = s,
            else => {},
        };
    }
    if (url == null and body.len > 0) {
        if (std.json.parseFromSlice(std.json.Value, alloc, body, .{})) |p| {
            if (p.value == .object) {
                if (p.value.object.get("url")) |v| switch (v) {
                    .string => |s| url = try alloc.dupe(u8, s),
                    else => {},
                };
            }
        } else |_| {}
    }

    if (url) |u| {
        const msg = try std.fmt.allocPrint(alloc, "Unauthorized URL redirect: {s}", .{u});
        const b = try errorBody(alloc, 400, msg);
        return .{ .status = .bad_request, .body = b };
    }
    const b = try errorBody(alloc, 400, "No url argument provided");
    return .{ .status = .bad_request, .body = b };
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

    // JSON-RPC bridge: POST /server/jsonrpc. `Dispatcher.handle` now takes the
    // Core lock itself, per-method (skipping it for off_core read methods).
    if (method == .POST and std.mem.eql(u8, path, jsonrpc_path)) {
        const bytes = try srv.dispatcher.handle(body, alloc);
        // A JSON-RPC notification yields empty bytes; reply with the literal `{}`
        // (a []const u8, no allocation) so the body stays valid JSON.
        const out: []const u8 = if (bytes.len == 0) "{}" else bytes;
        return .{ .status = .ok, .body = out };
    }

    // CORS redirect: GET /server/redirect (a Tornado router route, not a
    // register_endpoint). Moonraker's RedirectHandler reads `?url=` (or a JSON
    // body `url`), validates the origin via the authorization component's CORS
    // check, then issues an HTTP redirect to it. With no CORS domains configured
    // (phobos's default — there is no cors check wired) every candidate URL is
    // rejected, so the faithful behavior is:
    //   * missing url       → 400 "No url argument provided"
    //   * url present        → 400 "Unauthorized URL redirect: <url>"
    if (method == .GET and std.mem.eql(u8, path, "/server/redirect")) {
        return handleRedirect(target, body, alloc);
    }

    // File manager upload: POST /server/files/upload (multipart form body).
    if (method == .POST and std.mem.eql(u8, path, "/server/files/upload")) {
        if (srv.file_ctx) |fctx| {
            return handleUpload(srv, fctx, target, body, alloc);
        }
    }

    // File manager download / delete: /server/files/<root>/<path...>. Matched by
    // prefix so the dynamic tail is captured. Skips the named sub-routes above
    // (list, roots, directory, ...) which the registry already owns.
    if ((method == .GET or method == .DELETE) and isFileServePath(path)) {
        if (srv.file_ctx) |fctx| {
            return handleFileServe(srv, fctx, method.?, path, alloc);
        }
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
    // current user / ip into the WebRequest). User/ip are access.* only; _method
    // is injected for every route so multi-verb handlers can dispatch correctly.
    {
        var obj: std.json.ObjectMap = switch (params) {
            .object => |o| o,
            else => .empty,
        };
        try obj.put(alloc, "_method", .{ .string = @tagName(verb) });
        if (std.mem.startsWith(u8, path, "/access/")) {
            if (resolved_user) |u| {
                try obj.put(alloc, authz.current_user_key, .{ .string = u });
            }
            if (creds.remote_ip) |ip| {
                try obj.put(alloc, authz.current_ip_key, .{ .string = ip });
            }
        }
        params = .{ .object = obj };
    }

    // Run the handler under the serialized core. `Core.run` needs a
    // comptime-known function, so dispatch the runtime handler pointer through a
    // fixed trampoline. `off_core` read routes skip the lock and run in parallel
    // (same decision the JSON-RPC dispatcher makes, so both transports agree).
    const result = (if (route.off_core)
        callHandler(route.handler, route.ctx, params, alloc)
    else
        srv.core.run(srv.io, callHandler, .{ route.handler, route.ctx, params, alloc })) catch |err| {
        // `error.KlippyDisconnected` mirrors Moonraker's
        // ServerError("Klippy Host not connected", 503): a 503 whose body carries
        // both the 503 code and the exact message (AuthorizedRequestHandler
        // .write_error → {"code": status, "message": reason}).
        const code: i64 = switch (err) {
            error.InvalidParams => 400,
            error.Forbidden => 403,
            error.NotFound => 404,
            error.KlippyDisconnected => 503,
            error.MqttNotConfigured => 503,
            error.ServiceUnavailable => 503,
            error.UpdateRefusedPrinting => 503,
            else => 500,
        };
        const msg: []const u8 = switch (err) {
            error.InvalidParams => "Bad Request",
            error.Forbidden => "Forbidden",
            error.NotFound => "Not Found",
            error.KlippyDisconnected => @import("components/printer.zig").klippy_disconnected_message,
            error.MqttNotConfigured => "MQTT not configured",
            error.ServiceUnavailable => "Service Unavailable",
            error.UpdateRefusedPrinting => "Update Refused: Klippy is printing",
            else => "Internal Server Error",
        };
        const status: std.http.Status = switch (err) {
            error.InvalidParams => .bad_request,
            error.Forbidden => .forbidden,
            error.NotFound => .not_found,
            error.KlippyDisconnected => .service_unavailable,
            error.MqttNotConfigured => .service_unavailable,
            error.ServiceUnavailable => .service_unavailable,
            error.UpdateRefusedPrinting => .service_unavailable,
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

    // Extract the socket peer IP once per connection for trusted-client auth.
    var peer_ip_buf: [16]u8 = undefined;
    const peer_ip: ?[]const u8 = blk: {
        var sa: std.os.linux.sockaddr.in = undefined;
        var slen: std.os.linux.socklen_t = @sizeOf(@TypeOf(sa));
        const rc = std.os.linux.getpeername(stream.socket.handle, @ptrCast(&sa), &slen);
        if (std.os.linux.errno(rc) != .SUCCESS) break :blk null;
        const addr_n = std.mem.bigToNative(u32, sa.addr);
        break :blk std.fmt.bufPrint(&peer_ip_buf, "{d}.{d}.{d}.{d}", .{
            @as(u8, @truncate(addr_n & 0xff)),
            @as(u8, @truncate((addr_n >> 8) & 0xff)),
            @as(u8, @truncate((addr_n >> 16) & 0xff)),
            @as(u8, @truncate((addr_n >> 24) & 0xff)),
        }) catch null;
    };

    // Reader buffer also backs WebSocket input after upgrade
    // (std.http.WebSocket.input == server.reader.in), and `readSmallMessage`
    // requires each INBOUND WS message fit it. Inbound is JSON-RPC requests only
    // (the largest being objects/subscribe|query with a big object list) — 16 KB
    // is ample. The writer streams responses/notifications, so 8 KB suffices.
    // These live for the whole connection; 64+64 KB × the WS-connection ceiling
    // (default 50) was ~6.4 MB of stack — far over the RSS budget.
    var sbuf: [16 * 1024]u8 = undefined;
    var s_r = stream.reader(io, &sbuf);
    var wbuf: [8 * 1024]u8 = undefined;
    var s_w = stream.writer(io, &wbuf);

    var http_server = std.http.Server.init(&s_r.interface, &s_w.interface);

    while (true) {
        var req = http_server.receiveHead() catch return;

        // WebSocket upgrade: hand the connection off to the WS transport. The
        // returned WebSocket borrows the HTTP reader/writer buffers above.
        switch (req.upgradeRequested()) {
            .websocket => |key| {
                const upgrade_path = pathOf(req.head.target);

                // /klippysocket = Moonraker's BridgeSocket. Relay frames between
                // the WS client and the live Klippy Unix socket.
                if (std.mem.eql(u8, upgrade_path, "/klippysocket")) {
                    var bridge = req.respondWebSocket(.{ .key = key orelse "" }) catch return;
                    const kc = srv.klippy_ctx orelse {
                        // No KlippyCtx wired — close with 1001.
                        var payload: [2 + 19]u8 = undefined;
                        std.mem.writeInt(u16, payload[0..2], 1001, .big);
                        @memcpy(payload[2..][0..19], "Klippy Disconnected");
                        bridge.writeMessage(&payload, .connection_close) catch {};
                        bridge.flush() catch {};
                        return;
                    };
                    ws.serveBridge(io, &bridge, kc);
                    return;
                }

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
                    .klippy = srv.klippy_ctx,
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
        var creds = extractCreds(&req, target, alloc);
        // Plumb the socket peer IP (extracted once per connection above) so
        // the authorization layer can match trusted-client CIDRs.
        if (peer_ip) |ip| {
            creds.remote_ip = alloc.dupe(u8, ip) catch null;
        }

        // Streaming upload: handle POST /server/files/upload before reading the
        // body, so a large gcode streams to disk in constant memory instead of
        // buffering the whole multipart blob in the request arena.
        if (req.head.method == .POST and std.mem.eql(u8, pathOf(target), "/server/files/upload")) {
            if (srv.file_ctx) |fctx| {
                const up_headers = buildResponseHeaders(alloc, srv.cors_domains, creds.origin);
                handleUploadStreaming(srv, fctx, &req, alloc, up_headers) catch {};
                // The streaming parser consumes the body only up to the closing
                // boundary (and on a rejected upload, not at all), so the request
                // body is not fully drained — the connection is no longer
                // byte-synced for the next request. Close it rather than risk
                // parsing leftover body bytes as the next request (desync /
                // request smuggling). Clients reconnect for the next request.
                return;
            }
        }

        const body: []const u8 = readBody(&req, alloc) catch &.{};

        // CORS preflight: answer OPTIONS directly with the allow headers, no auth.
        if (req.head.method == .OPTIONS) {
            req.respond("", .{
                .status = .no_content,
                .extra_headers = buildResponseHeaders(alloc, srv.cors_domains, creds.origin),
            }) catch return;
            if (!req.head.keep_alive) return;
            continue;
        }

        const resp = handleParsedAuth(srv, .HTTP, verb, target, body, creds, alloc) catch
            Response{ .status = .internal_server_error, .body = "{\"error\":{\"code\":500,\"message\":\"Internal Server Error\"}}" };

        const headers = buildResponseHeaders(alloc, srv.cors_domains, creds.origin);
        if (resp.file_path) |fpath| {
            // Stream the file from disk in 64 KB chunks — constant memory
            // regardless of file size. Falls back to a 404 on open failure.
            sendFileStreaming(io, &req, fpath, headers) catch return;
        } else {
            req.respond(resp.body, .{
                .status = resp.status,
                .extra_headers = headers,
            }) catch return;
        }

        if (!req.head.keep_alive) return;
    }
}

/// Stream a file from disk to the HTTP response in 64 KB chunks, with
/// content-length set from the file size, so a download uses constant memory
/// regardless of file size (large gcode would otherwise buffer whole-file in the
/// request arena). Replies 404 if the file can't be opened.
fn sendFileStreaming(io: Io, req: *std.http.Server.Request, abs: []const u8, headers: []const std.http.Header) !void {
    const f = std.Io.Dir.cwd().openFile(io, abs, .{}) catch {
        return req.respond("{\"error\":{\"code\":404,\"message\":\"File not found\"}}", .{
            .status = .not_found,
            .extra_headers = headers,
        });
    };
    defer f.close(io);
    const st = f.stat(io) catch {
        return req.respond("{\"error\":{\"code\":500,\"message\":\"Read error\"}}", .{
            .status = .internal_server_error,
            .extra_headers = headers,
        });
    };

    var rbuf: [64 * 1024]u8 = undefined;
    var fr = f.reader(io, &rbuf);
    var send_buf: [16 * 1024]u8 = undefined;
    var bw = try req.respondStreaming(&send_buf, .{
        .content_length = st.size,
        .respond_options = .{ .status = .ok, .extra_headers = headers },
    });
    // Copy file -> response body. `bw.end()` with content-length framing asserts
    // that exactly `st.size` bytes were written, so a file truncated/appended
    // between stat and read (a re-upload during download) would panic. Guard it:
    // only end() cleanly on an exact-size copy; on a short/over/aborted stream the
    // framing is already broken, so return an error and let the caller close the
    // connection (it won't be byte-synced for keep-alive).
    const written = std.Io.Reader.streamRemaining(&fr.interface, &bw.writer) catch
        return error.DownloadAborted;
    if (written != st.size) return error.DownloadAborted;
    try bw.end();
}

/// Extract the auth credentials Moonraker recognizes from the request:
///   * JWT: "Authorization: Bearer <t>" / "X-Access-Token" / "?access_token="
///   * Oneshot: "?token="
///   * API key: "X-Api-Key"
/// All returned slices are duped into `alloc` so they survive the body read.
/// True if `origin` is permitted by `cors_domains` (Moonraker rules): `*` allows
/// any; `*.example.com` matches subdomains; otherwise an exact origin or host match.
fn corsOriginAllowed(cors_domains: []const []const u8, origin: []const u8) bool {
    if (origin.len == 0) return false;
    const host = if (std.mem.indexOf(u8, origin, "://")) |i| origin[i + 3 ..] else origin;
    for (cors_domains) |d| {
        if (std.mem.eql(u8, d, "*")) return true;
        if (std.mem.eql(u8, d, origin)) return true;
        if (std.mem.eql(u8, d, host)) return true;
        if (std.mem.startsWith(u8, d, "*.") and std.mem.endsWith(u8, host, d[1..])) return true;
    }
    return false;
}

/// Build the response header list: always content-type; plus the CORS allow
/// headers (echoing `origin`) when it is permitted. Arena-allocated.
fn buildResponseHeaders(alloc: std.mem.Allocator, cors_domains: []const []const u8, origin: ?[]const u8) []const std.http.Header {
    var list: std.ArrayList(std.http.Header) = .empty;
    list.append(alloc, .{ .name = "content-type", .value = "application/json" }) catch return &.{};
    if (origin) |o| {
        if (corsOriginAllowed(cors_domains, o)) {
            list.append(alloc, .{ .name = "Access-Control-Allow-Origin", .value = o }) catch {};
            list.append(alloc, .{ .name = "Access-Control-Allow-Credentials", .value = "true" }) catch {};
            list.append(alloc, .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, PUT, DELETE, OPTIONS" }) catch {};
            list.append(alloc, .{ .name = "Access-Control-Allow-Headers", .value = "Origin, Accept, Content-Type, X-Requested-With, X-CRSF-Token, Authorization, X-Access-Token, X-Api-Key" }) catch {};
        }
    }
    return list.items;
}

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
        } else if (std.ascii.eqlIgnoreCase(h.name, "origin")) {
            creds.origin = alloc.dupe(u8, h.value) catch null;
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

// ---------------------------------------------------------------------------
// File manager upload / download / delete wiring
// ---------------------------------------------------------------------------

/// The reserved named sub-routes under /server/files/ that are handled by the
/// registry, NOT by the dynamic file-serve handler.
const reserved_file_subpaths = [_][]const u8{
    "list", "roots", "directory", "metadata", "metascan",
    "thumbnails", "move", "copy", "zip", "upload", "delete_file",
};

/// True if `path` is a `/server/files/<root>/<...>` path that should be served
/// as a file (download/delete), i.e. not one of the reserved named sub-routes.
pub fn isFileServePath(path: []const u8) bool {
    const prefix = "/server/files/";
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    const rest = path[prefix.len..];
    if (rest.len == 0) return false;
    // First segment is the root; if there's no '/', it's just "/server/files/x"
    // which must still not collide with a reserved single-segment name.
    const first = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
    for (reserved_file_subpaths) |r| {
        if (std.mem.eql(u8, r, first)) return false;
    }
    return true;
}

/// Serve GET (download) / DELETE for /server/files/<root>/<path...>.
fn handleFileServe(
    srv: *Server,
    fctx: *file_manager.FileCtx,
    verb: RequestType,
    path: []const u8,
    alloc: std.mem.Allocator,
) !Response {
    const prefix = "/server/files/";
    const request_path = path[prefix.len..];

    if (verb == .DELETE) {
        // Delete via the file_manager (runs under the serialized core).
        const result = srv.core.run(srv.io, file_manager.deleteFileImpl, .{ fctx, alloc, request_path }) catch |err| {
            return fileErrResponse(alloc, err);
        };
        const b = try wrapResult(alloc, result);
        return .{ .status = .ok, .body = b };
    }

    // GET: resolve the path and hand it to the transport to stream from disk in
    // fixed-size chunks (constant memory), rather than buffering the whole file
    // in the request arena — large gcode files would otherwise spike RSS by their
    // full size. The streamed body is HTTP-only (serveConnInner); non-streaming
    // consumers of the Response (tests / INTERNAL transport) see an empty body.
    const resolved = file_manager.resolveRequestPath(fctx, alloc, request_path) catch |err| {
        return fileErrResponse(alloc, mapResolveErr(err));
    };
    // Verify the file exists here so the 404 is correct for ALL consumers, not
    // only the streaming HTTP path (which opens it again — a tiny benign re-open).
    const probe = std.Io.Dir.cwd().openFile(srv.io, resolved.abs, .{}) catch {
        const b = try errorBody(alloc, 404, "File not found");
        return .{ .status = .not_found, .body = b };
    };
    probe.close(srv.io);
    return .{ .status = .ok, .body = "", .file_path = resolved.abs };
}

fn mapResolveErr(err: file_manager.ResolveError) anyerror {
    return switch (err) {
        error.InvalidParams => error.InvalidParams,
        error.Forbidden => error.Forbidden,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn fileErrResponse(alloc: std.mem.Allocator, err: anyerror) !Response {
    const code: i64 = switch (err) {
        error.InvalidParams => 400,
        error.Forbidden => 403,
        error.NotFound => 404,
        else => 500,
    };
    const status: std.http.Status = switch (err) {
        error.InvalidParams => .bad_request,
        error.Forbidden => .forbidden,
        error.NotFound => .not_found,
        else => .internal_server_error,
    };
    const msg: []const u8 = switch (err) {
        error.InvalidParams => "Bad Request",
        error.Forbidden => "Forbidden",
        error.NotFound => "Not Found",
        else => "Internal Server Error",
    };
    const b = try errorBody(alloc, code, msg);
    return .{ .status = status, .body = b };
}

/// Handle POST /server/files/upload with a multipart/form-data body. Extracts
/// the file part and the `root` / `path` / `filename` form fields, writes the
/// file, emits notify_filelist_changed, and returns Moonraker's response shape:
///   { "item": {path, root, size, modified, permissions}, "print_started": false,
///     "print_queued": false, "action": "create_file" }
fn handleUpload(
    srv: *Server,
    fctx: *file_manager.FileCtx,
    target: []const u8,
    body: []const u8,
    alloc: std.mem.Allocator,
) !Response {
    _ = target;
    const form = parseMultipart(alloc, body) catch {
        const b = try errorBody(alloc, 400, "Invalid upload form");
        return .{ .status = .bad_request, .body = b };
    };
    const filename = form.filename orelse {
        const b = try errorBody(alloc, 400, "No file name specified in upload form");
        return .{ .status = .bad_request, .body = b };
    };
    const root_name = form.root orelse "gcodes";

    // Build the request path: <root>/[<path>/]<filename>.
    const req_path = if (form.path) |p|
        try std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ root_name, std.mem.trim(u8, p, "/"), filename })
    else
        try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root_name, filename });

    // Run the actual write + notify under the serialized core.
    const io = srv.io;
    const result = srv.core.run(srv.io, uploadWrite, .{ fctx, io, alloc, req_path, form.content }) catch |err| {
        return fileErrResponse(alloc, err);
    };
    const b = try wrapResult(alloc, result);
    return .{ .status = .ok, .body = b };
}

/// Read from `r` into `out` (or discard, when null) until `sep` is found,
/// consuming `sep`. Holds back at most `sep.len - 1` bytes between reads, so it
/// works in bounded memory regardless of the part size (the whole point — a
/// gcode upload streams to disk instead of buffering). Errors if the stream ends
/// before `sep` (a malformed body).
fn streamUntilSeparator(r: *std.Io.Reader, out: ?*std.Io.Writer, sep: []const u8) !void {
    while (true) {
        const win = r.peekGreedy(sep.len) catch return error.MalformedUpload;
        if (std.mem.indexOf(u8, win, sep)) |idx| {
            if (out) |w| try w.writeAll(win[0..idx]);
            r.toss(idx + sep.len);
            return;
        }
        // No full match in the window; the tail might be a partial `sep`, so keep
        // the last sep.len-1 bytes and flush the rest, then pull more.
        const flush = win.len - (sep.len - 1);
        if (out) |w| try w.writeAll(win[0..flush]);
        r.toss(flush);
        r.fillMore() catch return error.MalformedUpload;
    }
}

/// Stream a multipart/form-data upload straight from the socket to disk, so a
/// large gcode upload runs in constant memory instead of buffering the whole body
/// in the request arena. Relies on the small form fields (root/path) preceding
/// the file part — true for every Moonraker client (Mainsail, Fluidd, curl -F).
/// Responds to `req` directly. Auth matches the non-streaming path (unchanged).
fn handleUploadStreaming(
    srv: *Server,
    fctx: *file_manager.FileCtx,
    req: *std.http.Server.Request,
    alloc: std.mem.Allocator,
    headers: []const std.http.Header,
) !void {
    const io = srv.io;
    var rbuf: [64 * 1024]u8 = undefined;
    const r = req.readerExpectNone(&rbuf);
    const bad = struct {
        fn f(rq: *std.http.Server.Request, a: std.mem.Allocator, h: []const std.http.Header, msg: []const u8) !void {
            const b = try errorBody(a, 400, msg);
            try rq.respond(b, .{ .status = .bad_request, .extra_headers = h });
        }
    }.f;

    // First line is "--<boundary>\r\n"; the inter-part separator is "\r\n--<boundary>".
    const first = r.takeDelimiterInclusive('\n') catch return bad(req, alloc, headers, "Invalid upload form");
    const boundary_line = std.mem.trimEnd(u8, first, "\r\n");
    if (!std.mem.startsWith(u8, boundary_line, "--")) return bad(req, alloc, headers, "Invalid upload form");
    const part_sep = try std.fmt.allocPrint(alloc, "\r\n{s}", .{boundary_line});

    var root_field: ?[]const u8 = null;
    var path_field: ?[]const u8 = null;
    var resolved: ?file_manager.Resolved = null;

    parts: while (true) {
        // Part headers: lines until a blank line.
        var disp: ?[]const u8 = null;
        while (true) {
            const line = r.takeDelimiterInclusive('\n') catch return bad(req, alloc, headers, "Invalid upload form");
            const l = std.mem.trimEnd(u8, line, "\r\n");
            if (l.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(l, "content-disposition:")) disp = try alloc.dupe(u8, l);
        }
        const cd = disp orelse return bad(req, alloc, headers, "Invalid upload form");

        if (extractDispositionField(cd, "filename")) |filename| {
            // File part: resolve the destination from the fields seen so far and
            // stream its content straight to disk.
            const root_name = root_field orelse "gcodes";
            const req_path = if (path_field) |p|
                try std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ root_name, std.mem.trim(u8, p, "/"), filename })
            else
                try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root_name, filename });
            const res = file_manager.resolveRequestPath(fctx, alloc, req_path) catch
                return bad(req, alloc, headers, "Invalid upload path");
            if (!res.root.full_access or res.rel.len == 0) return bad(req, alloc, headers, "Invalid upload path");
            const dir = std.Io.Dir.cwd();
            if (std.fs.path.dirname(res.abs)) |d| dir.createDirPath(io, d) catch {};
            const file = dir.createFile(io, res.abs, .{}) catch return bad(req, alloc, headers, "Write error");
            {
                defer file.close(io);
                var wbuf2: [32 * 1024]u8 = undefined;
                var fw = file.writer(io, &wbuf2);
                streamUntilSeparator(r, &fw.interface, part_sep) catch return bad(req, alloc, headers, "Invalid upload form");
                fw.interface.flush() catch return bad(req, alloc, headers, "Write error");
            }
            resolved = res;
        } else if (extractDispositionField(cd, "name")) |n| {
            // Small field value — buffer it (root / path).
            var vb: std.Io.Writer.Allocating = .init(alloc);
            streamUntilSeparator(r, &vb.writer, part_sep) catch return bad(req, alloc, headers, "Invalid upload form");
            if (std.mem.eql(u8, n, "root")) root_field = vb.written() else if (std.mem.eql(u8, n, "path")) path_field = vb.written();
        } else {
            streamUntilSeparator(r, null, part_sep) catch return bad(req, alloc, headers, "Invalid upload form");
        }

        // After the separator: "--" terminates the body; otherwise "\r\n" then the next part.
        const lead = r.peek(2) catch break :parts;
        if (lead[0] == '-' and lead[1] == '-') break :parts;
        r.toss(2);
    }

    const res = resolved orelse return bad(req, alloc, headers, "No file name specified in upload form");
    // notify_filelist_changed + result build run under Core (emitLocked assumes it).
    const result = srv.core.run(io, file_manager.buildUploadResult, .{ fctx, alloc, res }) catch
        return bad(req, alloc, headers, "Write error");
    const b = try wrapResult(alloc, result);
    try req.respond(b, .{ .status = .ok, .extra_headers = headers });
}

/// Perform the upload write + notify. Separated so it runs inside Core.run with
/// a comptime-known function. Returns the upload response object.
fn uploadWrite(
    fctx: *file_manager.FileCtx,
    io: Io,
    alloc: std.mem.Allocator,
    req_path: []const u8,
    content: []const u8,
) anyerror!std.json.Value {
    const resolved = file_manager.resolveRequestPath(fctx, alloc, req_path) catch |err| return mapResolveErr(err);
    if (!resolved.root.full_access) return error.Forbidden;
    if (resolved.rel.len == 0) return error.InvalidParams;

    const dir = std.Io.Dir.cwd();
    // Ensure parent directories exist.
    if (std.fs.path.dirname(resolved.abs)) |d| dir.createDirPath(io, d) catch {};
    dir.writeFile(io, .{ .sub_path = resolved.abs, .data = content }) catch return error.InvalidParams;

    return file_manager.buildUploadResult(fctx, alloc, resolved);
}

/// Parsed multipart form fields relevant to an upload.
const MultipartForm = struct {
    root: ?[]const u8 = null,
    path: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    content: []const u8 = "",
};

/// Minimal multipart/form-data parser: scans for `--<boundary>` delimited parts,
/// reads each part's `Content-Disposition` to find the field `name` (and
/// `filename` for the file part), and captures the bytes after the blank line.
/// The boundary is inferred from the body (first `--` line). This is a pragmatic
/// parser sufficient for the spine; it does not handle nested multipart.
fn parseMultipart(alloc: std.mem.Allocator, body: []const u8) !MultipartForm {
    var form = MultipartForm{};
    if (body.len < 3) return error.Invalid;

    // The boundary delimiter is the first line (up to CRLF or LF).
    const first_nl = std.mem.indexOfScalar(u8, body, '\n') orelse return error.Invalid;
    var boundary_line = body[0..first_nl];
    boundary_line = std.mem.trimEnd(u8, boundary_line, "\r");
    if (!std.mem.startsWith(u8, boundary_line, "--")) return error.Invalid;
    const delim = try std.fmt.allocPrint(alloc, "\n{s}", .{boundary_line});

    // Split the body on the boundary delimiter.
    var it = std.mem.splitSequence(u8, body, delim);
    // First chunk is the leading boundary line (already the delimiter w/o the
    // leading newline) — skip parts that are not real form sections.
    while (it.next()) |raw_part| {
        var part = raw_part;
        // Skip the opening boundary token and the trailing "--" terminator.
        if (std.mem.startsWith(u8, part, boundary_line)) {
            part = part[boundary_line.len..];
        }
        part = std.mem.trimStart(u8, part, "\r\n");
        if (part.len == 0 or std.mem.startsWith(u8, part, "--")) continue;

        // Header block ends at the first blank line (CRLFCRLF or LFLF).
        const sep = std.mem.indexOf(u8, part, "\r\n\r\n") orelse
            std.mem.indexOf(u8, part, "\n\n") orelse continue;
        const sep_len: usize = if (part[sep] == '\r') 4 else 2;
        const headers = part[0..sep];
        var content = part[sep + sep_len ..];
        // Strip exactly ONE trailing line terminator (the CRLF / LF / lone CR
        // that precedes the next boundary delimiter — the split on "\n--<b>"
        // can leave a bare CR). Trimming greedily would corrupt file content
        // that legitimately ends with newlines.
        if (std.mem.endsWith(u8, content, "\r\n")) {
            content = content[0 .. content.len - 2];
        } else if (std.mem.endsWith(u8, content, "\n") or std.mem.endsWith(u8, content, "\r")) {
            content = content[0 .. content.len - 1];
        }

        // Find the disposition name / filename.
        const name = extractDispositionField(headers, "name");
        const fname = extractDispositionField(headers, "filename");

        if (fname) |fn_val| {
            form.filename = fn_val;
            form.content = content;
        } else if (name) |n| {
            if (std.mem.eql(u8, n, "root")) {
                form.root = content;
            } else if (std.mem.eql(u8, n, "path")) {
                form.path = content;
            } else if (std.mem.eql(u8, n, "filename") and form.filename == null) {
                form.filename = content;
            }
        }
    }
    return form;
}

/// Extract a `key="value"` parameter from a Content-Disposition header block.
fn extractDispositionField(headers: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [32]u8 = undefined;
    if (key.len + 2 > search_buf.len) return null;
    const needle = std.fmt.bufPrint(&search_buf, "{s}=\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, headers, needle) orelse return null;
    const start = idx + needle.len;
    const end = std.mem.indexOfScalarPos(u8, headers, start, '"') orelse return null;
    return headers[start..end];
}

// --- tests ---------------------------------------------------------------

const methods = @import("core/methods.zig");

test "streamUntilSeparator: extracts content before the separator and consumes it" {
    const a = std.testing.allocator;
    const sep = "\r\n--BOUNDARY";
    var rdr = std.Io.Reader.fixed("FILEDATA" ++ sep ++ "TRAILING");
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try streamUntilSeparator(&rdr, &out.writer, sep);
    try std.testing.expectEqualStrings("FILEDATA", out.written());
    // The separator is consumed; the trailing bytes remain.
    const rest = try rdr.peekGreedy(1);
    try std.testing.expectEqualStrings("TRAILING", rest);
}

test "streamUntilSeparator: binary content with near-boundary bytes is not split early" {
    const a = std.testing.allocator;
    const sep = "\r\n--BOUNDARY";
    // Content contains a *partial* boundary ("\r\n--X") and a stray CRLF that must
    // NOT be mistaken for the real separator.
    const content = "line1\r\n--X\r\nstill data";
    var rdr = std.Io.Reader.fixed(content ++ sep);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try streamUntilSeparator(&rdr, &out.writer, sep);
    try std.testing.expectEqualStrings(content, out.written());
}

test "streamUntilSeparator: empty content (separator at start)" {
    const a = std.testing.allocator;
    const sep = "\r\n--BOUNDARY";
    var rdr = std.Io.Reader.fixed(sep ++ "rest");
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try streamUntilSeparator(&rdr, &out.writer, sep);
    try std.testing.expectEqualStrings("", out.written());
}

test "streamUntilSeparator: missing separator errors (malformed body)" {
    var rdr = std.Io.Reader.fixed("data with no boundary at all");
    try std.testing.expectError(error.MalformedUpload, streamUntilSeparator(&rdr, null, "\r\n--BOUNDARY"));
}

test "streamUntilSeparator: discards body when out is null and still consumes the separator" {
    const sep = "\r\n--B";
    var rdr = std.Io.Reader.fixed("ignored field value" ++ sep ++ "next");
    try streamUntilSeparator(&rdr, null, sep);
    const rest = try rdr.peekGreedy(1);
    try std.testing.expectEqualStrings("next", rest);
}

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

test "corsOriginAllowed: wildcard, exact, subdomain, host" {
    const star = [_][]const u8{"*"};
    try std.testing.expect(corsOriginAllowed(&star, "http://anything.com"));
    const exact = [_][]const u8{"http://app.example.com"};
    try std.testing.expect(corsOriginAllowed(&exact, "http://app.example.com"));
    try std.testing.expect(!corsOriginAllowed(&exact, "http://evil.com"));
    const sub = [_][]const u8{"*.local"};
    try std.testing.expect(corsOriginAllowed(&sub, "http://printer.local"));
    try std.testing.expect(!corsOriginAllowed(&sub, "http://printer.remote"));
    const host = [_][]const u8{"192.168.0.150:7199"};
    try std.testing.expect(corsOriginAllowed(&host, "http://192.168.0.150:7199"));
    // Empty origin / empty list never allowed.
    try std.testing.expect(!corsOriginAllowed(&star, ""));
    try std.testing.expect(!corsOriginAllowed(&.{}, "http://x"));
}

test "buildResponseHeaders: CORS headers only when origin allowed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const allow = [_][]const u8{"*"};
    const h1 = buildResponseHeaders(a, &allow, "http://ui.example");
    var has_acao = false;
    for (h1) |h| if (std.ascii.eqlIgnoreCase(h.name, "Access-Control-Allow-Origin")) {
        has_acao = true;
        try std.testing.expectEqualStrings("http://ui.example", h.value);
    };
    try std.testing.expect(has_acao);
    // No origin / no cors config → just content-type, no ACAO.
    const h2 = buildResponseHeaders(a, &.{}, "http://ui.example");
    for (h2) |h| try std.testing.expect(!std.ascii.eqlIgnoreCase(h.name, "Access-Control-Allow-Origin"));
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
