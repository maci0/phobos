//! HTTP transport over `std.http.Server` (driven on top of an `std.Io.net`
//! stream — no hand-rolled HTTP).
//!
//! A single `Registry` + `Dispatcher` back both transports:
//!   * REST: look up the route by (method, path), authenticate, run the
//!     handler under the serialized `Core`, then respond — wrapping the result
//!     as `{"result": <r>}` unless the endpoint sets `wrap_result = false`.
//!   * JSON-RPC: `POST /server/jsonrpc` authenticates like Moonraker's
//!     `RPCHandler` (auth optional for the request, enforced per method) and
//!     returns the JSON-RPC envelope verbatim.
//!   * WebSocket: `/websocket` and `/klippysocket` upgrades pass tornado's
//!     origin check (or `cors_domains`) and authenticate at the upgrade.
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

/// Moonraker `[server] max_websocket_connections` default.
pub const default_max_websocket_connections = 50;

fn routeHasTransport(route: *const Route, kind: TransportType) bool {
    for (route.transports) |t| if (t == kind) return true;
    return false;
}

/// Run the auth chain (JWT → oneshot → API key → trusted client) for `creds`.
/// Without an authorization component (bare-Server tests) every request is
/// anonymous and allowed.
fn authenticate(srv: *Server, transport: TransportType, creds: HttpCreds, alloc: std.mem.Allocator, auth_required: bool) authz.AuthOutcome {
    const auth_ctx = srv.auth orelse return .{ .anonymous = {} };
    return authz.authenticateRequest(auth_ctx, alloc, transport, .{
        .jwt = creds.jwt,
        .oneshot = creds.oneshot,
        .api_key = creds.api_key,
        .remote_ip = creds.remote_ip,
        .proxy_ip = creds.proxy_ip,
    }, auth_required);
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
    file_request: ?file_manager.Resolved = null,
};

/// Context bundling the shared state a connection needs.
pub const Server = struct {
    io: Io,
    core: *Core,
    reg: *Registry,
    dispatcher: *jsonrpc.Dispatcher,
    /// Active WebSocket connection registry. Optional so non-WS callers/tests
    /// can construct a Server without it; when null, upgrade requests are
    /// rejected (400) instead of handed off.
    conns: ?*connections.Connections = null,
    /// Authorization component. When set, requests are authenticated via the
    /// JWT → oneshot → API key → trusted chain and the resolved user is
    /// injected into access.* params. When null, every request is allowed.
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
    /// Moonraker `[server] use_xheaders`, default true. When set, `X-Real-Ip`
    /// and `X-Forwarded-For` replace the socket peer for trusted-client checks
    /// and the socket peer must itself be trusted.
    use_xheaders: bool = true,
    /// Upgrades are refused once this many WebSocket sessions are open.
    max_websocket_connections: usize = default_max_websocket_connections,
};

/// Credentials and client headers carried by an HTTP request. All slices
/// live in the request arena.
pub const HttpCreds = struct {
    jwt: ?[]const u8 = null,
    oneshot: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    remote_ip: ?[]const u8 = null,
    /// Socket peer when `use_xheaders` rewrote `remote_ip`. Null otherwise.
    proxy_ip: ?[]const u8 = null,
    x_real_ip: ?[]const u8 = null,
    x_forwarded_for: ?[]const u8 = null,
    /// `Origin` header, else `Sec-WebSocket-Origin`.
    origin: ?[]const u8 = null,
    host: ?[]const u8 = null,
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
/// use request-arena storage when decoding is needed, otherwise borrow `target`.
/// Form query strings decode '+' as a space; URL paths keep literal '+'.
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
        try obj.put(alloc, try decodeUriPart(alloc, key, true), .{ .string = try decodeUriPart(alloc, value, true) });
    }
    if (obj.count() == 0) return .null;
    return .{ .object = obj };
}

/// Returned storage belongs to the request arena or borrows `encoded`.
fn decodeUriPart(alloc: std.mem.Allocator, encoded: []const u8, form: bool) ![]const u8 {
    const text = if (form and std.mem.indexOfScalar(u8, encoded, '+') != null) blk: {
        const copy = try alloc.dupe(u8, encoded);
        std.mem.replaceScalar(u8, copy, '+', ' ');
        break :blk copy;
    } else encoded;
    const decoded = try (std.Uri.Component{ .percent_encoded = text }).toRawMaybeAlloc(alloc);
    if (!std.unicode.utf8ValidateSlice(decoded)) return error.InvalidParams;
    return decoded;
}

/// Build a Moonraker-shaped error body `{"error":{"code":<code>,"message":<m>}}`.
fn errorBody(alloc: std.mem.Allocator, code: i64, message: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, .{ .@"error" = .{ .code = code, .message = message } }, .{});
}

/// An error response whose body code is the HTTP status.
fn errorResponse(alloc: std.mem.Allocator, status: std.http.Status, message: []const u8) !Response {
    return .{ .status = status, .body = try errorBody(alloc, @backingInt(status), message) };
}

/// Wrap a handler result as `{"result": <r>}`.
fn wrapResult(alloc: std.mem.Allocator, result: std.json.Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, .{ .result = result }, .{});
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
    const qp = queryParams(alloc, target) catch |err| return fileErrResponse(alloc, err);
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

    if (url) |u| return errorResponse(alloc, .bad_request, try std.fmt.allocPrint(alloc, "Unauthorized URL redirect: {s}", .{u}));
    return errorResponse(alloc, .bad_request, "No url argument provided");
}

/// POST /server/jsonrpc, Moonraker's `RPCHandler`: the request authenticates
/// with auth optional; without a user, `auth_required` methods answer -32602
/// "Unauthorized". An invalid JWT or API key is a 401 for the whole request.
fn handleJsonRpc(srv: *Server, transport: TransportType, body: []const u8, creds: HttpCreds, alloc: std.mem.Allocator) !Response {
    var caller: jsonrpc.Caller = .{ .transport = transport, .remote_ip = creds.remote_ip };
    if (srv.auth != null and transport != .INTERNAL) switch (authenticate(srv, transport, creds, alloc, false)) {
        .user => |u| caller.user = u,
        .anonymous => caller.need_auth = true,
        .unauthorized => return errorResponse(alloc, .unauthorized, "Unauthorized"),
    };
    const bytes = if (std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{})) |root|
        try srv.dispatcher.handleParsedRoot(caller, root, alloc)
    else |_|
        try jv.errorResponse(alloc, .null, -32700, "Parse error");
    // Nothing to send (e.g. an id-less request): keep the body valid JSON.
    return .{ .status = .ok, .body = if (bytes.len == 0) "{}" else bytes };
}

/// Core request handling, independent of sockets, so it can be unit- and
/// fuzz-tested directly. Produces the response body + status for a parsed
/// request. `creds` are the credentials extracted by the socket layer;
/// `alloc` should be a per-request arena.
pub fn handleParsed(
    srv: *Server,
    transport: TransportType,
    method: ?RequestType,
    target: []const u8,
    body: []const u8,
    creds: HttpCreds,
    alloc: std.mem.Allocator,
) !Response {
    const path = pathOf(target);

    if (method == .POST and std.mem.eql(u8, path, jsonrpc_path)) return handleJsonRpc(srv, transport, body, creds, alloc);

    // CORS redirect: GET /server/redirect (a Tornado router route, not a
    // register_endpoint). With no CORS check wired every candidate URL is
    // rejected (see handleRedirect).
    if (method == .GET and std.mem.eql(u8, path, "/server/redirect")) {
        return handleRedirect(target, body, alloc);
    }

    // File manager download / delete: /server/files/<root>/<path...>. Matched by
    // prefix so the dynamic tail is captured. Skips the named sub-routes
    // (list, roots, directory, ...) which the registry already owns. Moonraker
    // serves these through AuthorizedFileHandler (auth required).
    if ((method == .GET or method == .DELETE) and isFileServePath(path)) {
        if (srv.file_ctx) |fctx| {
            if (authenticate(srv, transport, creds, alloc, true) == .unauthorized) {
                return errorResponse(alloc, .unauthorized, "Unauthorized");
            }
            return handleFileServe(srv, fctx, method.?, path, alloc);
        }
    }

    // Unsupported HTTP verb -> 404 (no route can match).
    const verb = method orelse return errorResponse(alloc, .not_found, "Not Found");

    const route = srv.reg.lookup(verb, path) orelse {
        // Distinguish wrong-verb (405) from genuinely-unknown path (404).
        inline for (.{ RequestType.GET, RequestType.POST, RequestType.DELETE }) |other_verb| {
            if (srv.reg.lookup(other_verb, path)) |other_route| {
                if (routeHasTransport(other_route, .HTTP)) return errorResponse(alloc, .method_not_allowed, "Method Not Allowed");
            }
        }
        return errorResponse(alloc, .not_found, "Not Found");
    };

    // Websocket-only routes (server.websocket.id, server.connection.identify)
    // are still registered so the API surface lists them. HTTP must 404, the
    // same as Moonraker. The handler would otherwise answer 500.
    if (!routeHasTransport(route, .HTTP)) return errorResponse(alloc, .not_found, "Not Found");

    var caller: jsonrpc.Caller = .{ .transport = transport, .remote_ip = creds.remote_ip };
    switch (authenticate(srv, transport, creds, alloc, route.auth_required)) {
        .user => |u| caller.user = u,
        .anonymous => {},
        .unauthorized => return errorResponse(alloc, .unauthorized, "Unauthorized"),
    }

    // Params come from a JSON object body (POST) or the query string, with
    // string values like Moonraker's `WebRequest` arg coercion.
    var src: ?std.json.ObjectMap = null;
    if (body.len > 0) {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{}) catch std.json.Value.null;
        if (jv.exceedsDepth(parsed, jv.max_value_depth)) return errorResponse(alloc, .bad_request, "Request body nested too deeply");
        if (parsed == .object) src = parsed.object;
    }
    if (src == null) {
        const qp = queryParams(alloc, target) catch |err| return fileErrResponse(alloc, err);
        if (qp == .object) src = qp.object;
    }
    // `_method` for every route; the caller's user and address for access.*.
    const params = try jsonrpc.requestParams(alloc, src, verb, caller, std.mem.startsWith(u8, path, "/access/"));

    // Run the handler under the serialized core. `Core.run` needs a
    // comptime-known function, so dispatch the runtime handler pointer through a
    // fixed trampoline. `off_core` read routes skip the lock and run in parallel
    // (same decision the JSON-RPC dispatcher makes, so both transports agree).
    const result = (if (route.off_core)
        callHandler(route.handler, route.ctx, params, alloc)
    else
        srv.core.run(srv.io, callHandler, .{ route.handler, route.ctx, params, alloc })) catch |err| {
        const reply = try jsonrpc.errorReply(err, params, alloc);
        return errorResponse(alloc, reply.status, reply.message);
    };

    const out = if (route.wrap_result)
        try wrapResult(alloc, result)
    else
        try std.json.Stringify.valueAlloc(alloc, result, .{});

    return .{ .status = .ok, .body = out };
}

/// Adapter matching `io.CtxHandler` so `serveConn` can be wired straight into
/// `Listener.serveWith`. The opaque context is the `*Server`.
pub fn connHandler(ctx: *anyopaque, _: Io, stream: net.Stream) void {
    const srv: *Server = @ptrCast(@alignCast(ctx));
    serveConn(srv, stream);
}

/// The client address of a socket peer, without the port.
fn peerAddress(buf: []u8, address: net.IpAddress) ![]const u8 {
    return switch (address) {
        .ip4 => |ip| std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ ip.bytes[0], ip.bytes[1], ip.bytes[2], ip.bytes[3] }),
        .ip6 => |ip| std.fmt.bufPrint(buf, "{f}", .{net.Ip6Address.Unresolved{ .bytes = ip.bytes, .interface_name = null }}),
    };
}

/// Serve a single HTTP connection: build the std.http.Server over the stream,
/// receive the head, dispatch, and respond. Keeps the connection alive for
/// subsequent requests until the client closes or an error occurs.
pub fn serveConn(srv: *Server, stream: net.Stream) void {
    serveConnInner(srv, stream) catch {};
}

fn serveConnInner(srv: *Server, stream: net.Stream) !void {
    const io = srv.io;

    var peer_ip_buf: [64]u8 = undefined;
    const peer_ip = try peerAddress(&peer_ip_buf, stream.socket.address);

    // Reader buffer also backs WebSocket input after upgrade
    // (std.http.WebSocket.input == server.reader.in), and `readSmallMessage`
    // requires each INBOUND WS message fit it, so 16 KiB caps one inbound
    // JSON-RPC message. The writer streams responses/notifications, so 8 KB
    // suffices. These live for the whole connection; 64+64 KB × the
    // WS-connection ceiling (default 50) was ~6.4 MB of stack.
    var sbuf: [16 * 1024]u8 = undefined;
    var s_r = stream.reader(io, &sbuf);
    var wbuf: [8 * 1024]u8 = undefined;
    var s_w = stream.writer(io, &wbuf);

    var http_server = std.http.Server.init(&s_r.interface, &s_w.interface);

    while (true) {
        var req = http_server.receiveHead() catch return;

        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Copy head fields before reading the body: the body reader
        // invalidates the string memory backing `req.head`.
        const verb = RequestType.fromHttp(req.head.method);
        const target = try alloc.dupe(u8, req.head.target);
        var creds = try extractCreds(&req, target, alloc);
        const addr = authz.resolveClientAddr(peer_ip, creds.x_real_ip, creds.x_forwarded_for, srv.use_xheaders);
        creds.remote_ip = try alloc.dupe(u8, addr.client);
        if (addr.proxy) |proxy| creds.proxy_ip = try alloc.dupe(u8, proxy);
        const path = pathOf(target);
        const headers = buildResponseHeaders(alloc, srv.cors_domains, creds.origin);

        switch (req.upgradeRequested()) {
            .websocket => |key| {
                // /klippysocket is the bridge; any other path is the client
                // socket. The session consumes the connection.
                serveUpgrade(srv, &req, key orelse "", path, creds, headers, alloc, stream, &wbuf);
                return;
            },
            .other, .none => {},
        }

        // Streaming upload: handle POST /server/files/upload before reading the
        // body, so a large gcode streams to disk in constant memory instead of
        // buffering the whole multipart blob in the request arena.
        // `/api/files/local` is the OctoPrint slicer-upload alias (different
        // response shape; same streaming multipart body).
        const is_octo_upload = std.mem.eql(u8, path, "/api/files/local");
        if (req.head.method == .POST and (std.mem.eql(u8, path, "/server/files/upload") or is_octo_upload)) {
            if (srv.file_ctx) |fctx| {
                // File upload is a write primitive and must pass the same auth
                // chain as every other REST route (Moonraker's upload handler is
                // auth_required). Reject before touching the multipart body,
                // without a 100 Continue, then close.
                if (authenticate(srv, .HTTP, creds, alloc, true) == .unauthorized) {
                    req.head.expect = null;
                    const eb = try errorBody(alloc, 401, "Unauthorized");
                    req.respond(eb, .{ .status = .unauthorized, .extra_headers = headers, .keep_alive = false }) catch {};
                    return;
                }
                // The parser consumes the body only up to the closing boundary,
                // so the connection is not byte-synced for another request.
                handleUploadStreaming(srv, fctx, &req, alloc, headers, is_octo_upload) catch {};
                return;
            }
        }

        const body = readBody(&req, alloc) catch |err| {
            // The body is not fully consumed: answer and close so its
            // remainder is never parsed as the next request.
            const status: std.http.Status, const message: []const u8 = switch (err) {
                error.StreamTooLong => .{ .payload_too_large, "Request body too large" },
                error.HttpExpectationFailed => .{ .expectation_failed, "Expectation Failed" },
                error.OutOfMemory => .{ .internal_server_error, "Internal Server Error" },
                error.ReadFailed, error.WriteFailed => return,
            };
            req.head.expect = null;
            const eb = try errorBody(alloc, @backingInt(status), message);
            req.respond(eb, .{ .status = status, .extra_headers = headers, .keep_alive = false }) catch {};
            return;
        };

        // CORS preflight: answer OPTIONS directly with the allow headers, no auth.
        if (req.head.method == .OPTIONS) {
            req.respond("", .{ .status = .no_content, .extra_headers = headers }) catch return;
            if (!req.head.keep_alive) return;
            continue;
        }

        const resp = handleParsed(srv, .HTTP, verb, target, body, creds, alloc) catch
            Response{ .status = .internal_server_error, .body = "{\"error\":{\"code\":500,\"message\":\"Internal Server Error\"}}" };

        if (resp.file_request) |file_request| {
            // Stream the file from disk in 64 KB chunks — constant memory
            // regardless of file size. Falls back to a 404 on open failure.
            sendFileStreaming(io, &req, file_request, alloc, headers) catch return;
        } else {
            req.respond(resp.body, .{
                .status = resp.status,
                .extra_headers = headers,
            }) catch return;
        }

        if (!req.head.keep_alive) return;
    }
}

/// Upgrade `/websocket` or `/klippysocket`, following Moonraker's
/// `WebSocket.prepare` / `BridgeSocket.prepare` and tornado's origin check.
/// The client socket authenticates at the upgrade; a failure leaves the
/// session open but unauthenticated. The bridge socket requires it.
fn serveUpgrade(
    srv: *Server,
    req: *std.http.Server.Request,
    key: []const u8,
    path: []const u8,
    creds: HttpCreds,
    headers: []const std.http.Header,
    alloc: std.mem.Allocator,
    stream: net.Stream,
    /// The HTTP writer buffer, free once the handshake is flushed.
    out_buf: []u8,
) void {
    const refuse = struct {
        fn f(r: *std.http.Server.Request, a: std.mem.Allocator, h: []const std.http.Header, status: std.http.Status, msg: []const u8) void {
            const b = errorBody(a, @backingInt(status), msg) catch return;
            r.respond(b, .{ .status = status, .extra_headers = h, .keep_alive = false }) catch {};
        }
    }.f;
    if (!originAllowed(srv.cors_domains, creds.origin, creds.host)) return refuse(req, alloc, headers, .forbidden, "Cross origin websockets not allowed");
    const conns = srv.conns orelse return refuse(req, alloc, headers, .bad_request, "WebSocket unsupported");
    if (conns.count(srv.io) >= srv.max_websocket_connections) return refuse(req, alloc, headers, .service_unavailable, "Maximum Number of Websocket Connections Reached");
    const outcome = authenticate(srv, .HTTP, creds, alloc, true);

    if (std.mem.eql(u8, path, "/klippysocket")) {
        if (outcome == .unauthorized) return refuse(req, alloc, headers, .unauthorized, "Unauthorized");
        const kc = srv.klippy_ctx orelse return refuse(req, alloc, headers, .service_unavailable, "Failed to open connection to Klippy");
        var bridge = req.respondWebSocket(.{ .key = key }) catch return;
        ws.serveBridge(srv.io, &bridge, kc);
        return;
    }

    var web_socket = req.respondWebSocket(.{ .key = key }) catch return;
    web_socket.flush() catch return;
    var out = ws.DeadlineWriter.init(srv.io, stream, out_buf);
    web_socket.output = &out.interface;
    var ws_srv = ws.WsServer{
        .io = srv.io,
        .dispatcher = srv.dispatcher,
        .conns = conns,
        .klippy = srv.klippy_ctx,
        .auth = srv.auth,
    };
    ws.serveWebSocket(&ws_srv, &web_socket, .{
        .user = switch (outcome) {
            .user => |u| u,
            .anonymous, .unauthorized => null,
        },
        .need_auth = outcome == .unauthorized,
        .remote_ip = creds.remote_ip,
    });
}

/// Tornado `WebSocketHandler.check_origin` with Moonraker's CORS fallback: no
/// origin, or one whose host[:port] equals the Host header, is allowed;
/// otherwise the origin must match `cors_domains`.
fn originAllowed(cors_domains: []const []const u8, origin: ?[]const u8, host: ?[]const u8) bool {
    const o = origin orelse return true;
    const rest = if (std.mem.indexOf(u8, o, "://")) |i| o[i + 3 ..] else o;
    const netloc = rest[0 .. std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len];
    if (host) |h| if (std.ascii.eqlIgnoreCase(netloc, h)) return true;
    return corsOriginAllowed(cors_domains, o);
}

/// Stream a file from disk to the HTTP response in 64 KB chunks, with
/// content-length set from the file size, so a download uses constant memory
/// regardless of file size (large gcode would otherwise buffer whole-file in the
/// request arena). Replies 404 if the file can't be opened.
fn sendFileStreaming(io: Io, req: *std.http.Server.Request, file_request: file_manager.Resolved, alloc: std.mem.Allocator, headers: []const std.http.Header) !void {
    const f = file_request.openFile(io, alloc) catch |err| {
        if (err == error.Forbidden) return req.respond("{\"error\":{\"code\":403,\"message\":\"Forbidden\"}}", .{ .status = .forbidden, .extra_headers = headers });
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
    // Send the advertised size; growth is ignored and truncation aborts the response.
    fr.interface.streamExact64(&bw.writer, st.size) catch return error.DownloadAborted;
    try bw.end();
}

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

/// Extract the auth credentials Moonraker recognizes from the request:
///   * JWT: "Authorization: Bearer <t>" / "X-Access-Token" / "?access_token="
///   * Oneshot: "?token="
///   * API key: "X-Api-Key"
/// plus the client headers the transport needs. All returned slices are duped
/// into `alloc` so they survive the body read.
fn extractCreds(req: *std.http.Server.Request, target: []const u8, alloc: std.mem.Allocator) !HttpCreds {
    var creds = HttpCreds{};

    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
            creds.jwt = try alloc.dupe(u8, h.value);
        } else if (std.ascii.eqlIgnoreCase(h.name, "x-access-token")) {
            if (creds.jwt == null) creds.jwt = try alloc.dupe(u8, h.value);
        } else if (std.ascii.eqlIgnoreCase(h.name, "x-api-key")) {
            creds.api_key = try alloc.dupe(u8, h.value);
        } else if (std.ascii.eqlIgnoreCase(h.name, "x-real-ip")) {
            creds.x_real_ip = try alloc.dupe(u8, h.value);
        } else if (std.ascii.eqlIgnoreCase(h.name, "x-forwarded-for")) {
            creds.x_forwarded_for = try alloc.dupe(u8, h.value);
        } else if (std.ascii.eqlIgnoreCase(h.name, "origin")) {
            creds.origin = try alloc.dupe(u8, h.value);
        } else if (std.ascii.eqlIgnoreCase(h.name, "sec-websocket-origin")) {
            if (creds.origin == null) creds.origin = try alloc.dupe(u8, h.value);
        } else if (std.ascii.eqlIgnoreCase(h.name, "host")) {
            creds.host = try alloc.dupe(u8, h.value);
        }
    }

    // Query params: access_token (JWT) and token (oneshot). An undecodable
    // query carries no credentials; the route reports the bad query.
    const qp = queryParams(alloc, target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidParams => std.json.Value.null,
    };
    if (qp == .object) {
        if (qp.object.get("access_token")) |v| switch (v) {
            .string => |s| if (creds.jwt == null) {
                creds.jwt = s;
            },
            else => {},
        };
        if (qp.object.get("token")) |v| switch (v) {
            .string => |s| creds.oneshot = s,
            else => {},
        };
    }

    return creds;
}

/// Cap for non-upload request bodies, which are buffered and parsed in the
/// request arena (uploads stream to disk instead). Moonraker applies
/// `max_upload_size` (1 GiB) to every body; phobos bounds buffered JSON to
/// 1 MiB because a body costs several times its size once parsed and up to
/// `io.Listener.max_concurrent_conns` requests run at once.
const max_request_body = 1024 * 1024;

/// Hard upper bound on a single streamed file-upload part. Real gcode is far
/// smaller; this only backstops an unbounded/never-terminating upload body from
/// filling the disk. (Free-space is the practical limit; this bounds the stream.)
const max_upload_bytes = 2 * 1024 * 1024 * 1024;
/// Multipart form fields (root/path) are a few bytes; cap them tight so a giant
/// field value can't balloon the request arena before the file part is reached.
const max_field_bytes = 64 * 1024;
/// RFC 2046 boundary: at most 70 characters, after the leading "--".
const max_boundary_line = 2 + 70;

/// Read the full request body into `alloc`, answering `Expect: 100-continue`.
/// Returns an empty slice when there is no body.
fn readBody(req: *std.http.Server.Request, alloc: std.mem.Allocator) ![]const u8 {
    if (req.head.transfer_encoding == .none and (req.head.content_length orelse 0) == 0) return &.{};
    var rbuf: [16 * 1024]u8 = undefined;
    const reader = try req.readerExpectContinue(&rbuf);
    return reader.allocRemaining(alloc, .limited(max_request_body));
}

// ---------------------------------------------------------------------------
// File manager upload / download / delete wiring
// ---------------------------------------------------------------------------

/// The reserved named sub-routes under /server/files/ that are handled by the
/// registry, NOT by the dynamic file-serve handler.
const reserved_file_subpaths = [_][]const u8{
    "list",        "roots", "directory", "metadata", "metascan",
    "thumbnails",  "move",  "copy",      "zip",      "upload",
    "delete_file",
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
    const request_path = decodeUriPart(alloc, path[prefix.len..], false) catch |err| return fileErrResponse(alloc, err);

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
        return fileErrResponse(alloc, err);
    };
    // Verify the file exists here so the 404 is correct for ALL consumers, not
    // only the streaming HTTP path (which opens it again — a tiny benign re-open).
    const probe = resolved.openFile(srv.io, alloc) catch |err| {
        if (err == error.Forbidden or err == error.InvalidParams) return fileErrResponse(alloc, err);
        return errorResponse(alloc, .not_found, "File not found");
    };
    probe.close(srv.io);
    return .{ .status = .ok, .body = "", .file_request = resolved };
}

fn fileErrResponse(alloc: std.mem.Allocator, err: anyerror) !Response {
    const reply = try jsonrpc.errorReply(err, .null, alloc);
    return errorResponse(alloc, reply.status, reply.message);
}

/// Read from `r` into `out` (or discard, when null) until `sep` is found,
/// consuming `sep`. Holds back at most `sep.len - 1` bytes between reads, so it
/// works in bounded memory regardless of the part size (the whole point — a
/// gcode upload streams to disk instead of buffering). Errors if the stream ends
/// before `sep` (a malformed body).
fn streamUntilSeparator(r: *std.Io.Reader, out: ?*std.Io.Writer, sep: []const u8, max: usize) !void {
    var consumed: usize = 0;
    while (true) {
        const win = r.peekGreedy(sep.len) catch return error.MalformedUpload;
        if (std.mem.indexOf(u8, win, sep)) |idx| {
            // Cap is enforced on the part content (excludes the separator) so a
            // client can neither fill the disk with a huge file part nor balloon
            // the request arena with a huge form field (CWE-400).
            if (consumed + idx > max) return error.UploadTooLarge;
            if (out) |w| try w.writeAll(win[0..idx]);
            r.toss(idx + sep.len);
            return;
        }
        // No full match in the window; the tail might be a partial `sep`, so keep
        // the last sep.len-1 bytes and flush the rest, then pull more.
        const flush = win.len - (sep.len - 1);
        if (consumed + flush > max) return error.UploadTooLarge;
        consumed += flush;
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
    /// true for the OctoPrint `/api/files/local` slicer-upload endpoint, which
    /// returns the OctoPrint response shape (raw, wrap_result=false) instead of
    /// Moonraker's `{result: ...}`.
    octoprint: bool,
) !void {
    const io = srv.io;
    var rbuf: [64 * 1024]u8 = undefined;
    const r = req.readerExpectContinue(&rbuf) catch |err| switch (err) {
        error.HttpExpectationFailed => {
            req.head.expect = null;
            const b = try errorBody(alloc, 417, "Expectation Failed");
            return req.respond(b, .{ .status = .expectation_failed, .extra_headers = headers, .keep_alive = false });
        },
        error.WriteFailed => return err,
    };
    const bad = struct {
        fn f(rq: *std.http.Server.Request, a: std.mem.Allocator, h: []const std.http.Header, msg: []const u8) !void {
            const b = try errorBody(a, 400, msg);
            try rq.respond(b, .{ .status = .bad_request, .extra_headers = h });
        }
    }.f;
    const tooLarge = struct {
        fn f(rq: *std.http.Server.Request, a: std.mem.Allocator, h: []const std.http.Header) !void {
            const b = try errorBody(a, 413, "Upload too large");
            try rq.respond(b, .{ .status = .payload_too_large, .extra_headers = h });
        }
    }.f;

    // First line is "--<boundary>\r\n"; the inter-part separator is "\r\n--<boundary>".
    const first = r.takeDelimiterInclusive('\n') catch return bad(req, alloc, headers, "Invalid upload form");
    const boundary_line = std.mem.trimEnd(u8, first, "\r\n");
    // An over-long boundary would make the separator outgrow the read buffer.
    if (!std.mem.startsWith(u8, boundary_line, "--") or boundary_line.len > max_boundary_line) return bad(req, alloc, headers, "Invalid upload form");
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
            srv.core.run(io, file_manager.FileCtx.checkInUse, .{ fctx, res, false }) catch {
                const b = try errorBody(alloc, 403, "File currently in use");
                return req.respond(b, .{ .status = .forbidden, .extra_headers = headers });
            };
            var parent = res.parent(io, alloc, .{ .make_path = true }) catch return bad(req, alloc, headers, "Invalid upload path");
            defer parent.close(io);
            var output = parent.dir.createFileAtomic(io, parent.name, .{ .replace = true }) catch return bad(req, alloc, headers, "Write error");
            defer output.deinit(io);
            var wbuf2: [32 * 1024]u8 = undefined;
            var fw = output.file.writer(io, &wbuf2);
            streamUntilSeparator(r, &fw.interface, part_sep, max_upload_bytes) catch |err| {
                if (err == error.UploadTooLarge) return tooLarge(req, alloc, headers);
                return bad(req, alloc, headers, "Invalid upload form");
            };
            fw.interface.flush() catch return bad(req, alloc, headers, "Write error");
            output.file.sync(io) catch return bad(req, alloc, headers, "Write error");
            output.replace(io) catch return bad(req, alloc, headers, "Write error");
            resolved = res;
        } else if (extractDispositionField(cd, "name")) |n| {
            // Small field value — buffer it (root / path).
            var vb: std.Io.Writer.Allocating = .init(alloc);
            streamUntilSeparator(r, &vb.writer, part_sep, max_field_bytes) catch |e| {
                if (e == error.UploadTooLarge) return tooLarge(req, alloc, headers);
                return bad(req, alloc, headers, "Invalid upload form");
            };
            if (std.mem.eql(u8, n, "root")) root_field = vb.written() else if (std.mem.eql(u8, n, "path")) path_field = vb.written();
        } else {
            // Unknown field: discard, but still bound it so it can't run forever.
            streamUntilSeparator(r, null, part_sep, max_field_bytes) catch |e| {
                if (e == error.UploadTooLarge) return tooLarge(req, alloc, headers);
                return bad(req, alloc, headers, "Invalid upload form");
            };
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
    if (octoprint) {
        // OctoPrint upload response (wrap_result=false): slicers ("Upload to
        // OctoPrint") expect { files: { local: { name, path, origin } }, done }.
        const name = std.fs.path.basename(res.rel);
        var local: std.json.ObjectMap = .empty;
        try local.put(alloc, "name", .{ .string = name });
        try local.put(alloc, "path", .{ .string = res.rel });
        try local.put(alloc, "origin", .{ .string = "local" });
        var files: std.json.ObjectMap = .empty;
        try files.put(alloc, "local", .{ .object = local });
        var out: std.json.ObjectMap = .empty;
        try out.put(alloc, "files", .{ .object = files });
        try out.put(alloc, "done", .{ .bool = true });
        const ov: std.json.Value = .{ .object = out };
        const ob = try std.json.Stringify.valueAlloc(alloc, ov, .{});
        try req.respond(ob, .{ .status = .ok, .extra_headers = headers });
        return;
    }
    const b = try wrapResult(alloc, result);
    try req.respond(b, .{ .status = .ok, .extra_headers = headers });
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
    try streamUntilSeparator(&rdr, &out.writer, sep, max_upload_bytes);
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
    try streamUntilSeparator(&rdr, &out.writer, sep, max_upload_bytes);
    try std.testing.expectEqualStrings(content, out.written());
}

test "streamUntilSeparator: empty content (separator at start)" {
    const a = std.testing.allocator;
    const sep = "\r\n--BOUNDARY";
    var rdr = std.Io.Reader.fixed(sep ++ "rest");
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try streamUntilSeparator(&rdr, &out.writer, sep, max_upload_bytes);
    try std.testing.expectEqualStrings("", out.written());
}

test "streamUntilSeparator: missing separator errors (malformed body)" {
    var rdr = std.Io.Reader.fixed("data with no boundary at all");
    try std.testing.expectError(error.MalformedUpload, streamUntilSeparator(&rdr, null, "\r\n--BOUNDARY", max_upload_bytes));
}

test "streamUntilSeparator: discards body when out is null and still consumes the separator" {
    const sep = "\r\n--B";
    var rdr = std.Io.Reader.fixed("ignored field value" ++ sep ++ "next");
    try streamUntilSeparator(&rdr, null, sep, max_upload_bytes);
    const rest = try rdr.peekGreedy(1);
    try std.testing.expectEqualStrings("next", rest);
}

test "streamUntilSeparator: content exceeding the cap returns UploadTooLarge" {
    const a = std.testing.allocator;
    const sep = "\r\n--B";
    var rdr = std.Io.Reader.fixed("0123456789" ++ sep);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    // Cap of 5 < 10 bytes of content before the separator.
    try std.testing.expectError(error.UploadTooLarge, streamUntilSeparator(&rdr, &out.writer, sep, 5));
}

test "streamUntilSeparator: content exactly at the cap is allowed" {
    const a = std.testing.allocator;
    const sep = "\r\n--B";
    var rdr = std.Io.Reader.fixed("01234" ++ sep);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try streamUntilSeparator(&rdr, &out.writer, sep, 5);
    try std.testing.expectEqualStrings("01234", out.written());
}

test "fuzz streamUntilSeparator: arbitrary body + separator never crashes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var body_buf: [256]u8 = undefined;
            const blen = smith.valueRangeAtMostWithHash(u32, 0, body_buf.len, 1);
            smith.bytesWithHash(body_buf[0..blen], 2);
            var sep_buf: [8]u8 = undefined;
            const slen = smith.valueRangeAtMostWithHash(u32, 1, sep_buf.len, 3);
            smith.bytesWithHash(sep_buf[0..slen], 4);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            var rdr = std.Io.Reader.fixed(body_buf[0..blen]);
            var out: std.Io.Writer.Allocating = .init(arena.allocator());
            // Must return one of the typed errors or succeed — never panic, never
            // write past the separator, never over-read.
            _ = streamUntilSeparator(&rdr, &out.writer, sep_buf[0..slen], max_field_bytes) catch {};
        }
    }.run, .{});
}

test "extractDispositionField: parses filename and name, handles missing/oversized" {
    const cd = "Content-Disposition: form-data; name=\"file\"; filename=\"a b.gcode\"";
    try std.testing.expectEqualStrings("a b.gcode", extractDispositionField(cd, "filename").?);
    try std.testing.expectEqualStrings("file", extractDispositionField(cd, "name").?);
    // Missing key → null.
    try std.testing.expect(extractDispositionField(cd, "charset") == null);
    // Unterminated quote → null (no closing ").
    try std.testing.expect(extractDispositionField("name=\"unterminated", "name") == null);
    // Key longer than the search buffer → null, no overflow.
    const long_key: [64]u8 = @splat('x');
    try std.testing.expect(extractDispositionField(cd, &long_key) == null);
    // Empty value is valid and returns "".
    try std.testing.expectEqualStrings("", extractDispositionField("name=\"\"", "name").?);
}

test "fuzz extractDispositionField: arbitrary header bytes never crash" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var hdr: [256]u8 = undefined;
            const n = smith.valueRangeAtMostWithHash(u32, 0, hdr.len, 1);
            smith.bytesWithHash(hdr[0..n], 2);
            // Any returned slice must lie within the input header bytes.
            inline for (.{ "filename", "name", "charset" }) |key| {
                if (extractDispositionField(hdr[0..n], key)) |v| {
                    const base = @intFromPtr(hdr[0..n].ptr);
                    const vp = @intFromPtr(v.ptr);
                    try std.testing.expect(vp >= base and vp + v.len <= base + n);
                }
            }
        }
    }.run, .{});
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

    const encoded = try queryParams(a, "/printer/objects/query?temperature_sensor+tvocValue=temperature&file=hello%20%2B%25.gcode&%E9%87%8D=%E9%87%8F");
    try std.testing.expectEqualStrings("temperature", encoded.object.get("temperature_sensor tvocValue").?.string);
    try std.testing.expectEqualStrings("hello +%.gcode", encoded.object.get("file").?.string);
    try std.testing.expectEqualStrings("量", encoded.object.get("重").?.string);
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

    const resp = try handleParsed(&srv, .HTTP, .GET, "/server/info", "", .{}, arena.allocator());
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

    const resp = try handleParsed(&srv, .HTTP, .GET, "/server/config", "", .{}, arena.allocator());
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
    , .{}, a);
    try std.testing.expectEqual(std.http.Status.ok, rpc.status);

    // The JSON-RPC result payload must equal the REST result payload.
    const rest = try handleParsed(&srv, .HTTP, .GET, "/server/info", "", .{}, a);

    const rpc_parsed = try std.json.parseFromSlice(std.json.Value, a, rpc.body, .{});
    const rest_parsed = try std.json.parseFromSlice(std.json.Value, a, rest.body, .{});
    const rpc_result = rpc_parsed.value.object.get("result").?;
    const rest_result = rest_parsed.value.object.get("result").?;

    const rpc_s = try std.json.Stringify.valueAlloc(a, rpc_result, .{});
    const rest_s = try std.json.Stringify.valueAlloc(a, rest_result, .{});
    try std.testing.expectEqualStrings(rest_s, rpc_s);
}

test "handleParsed: websocket-only route is 404 over HTTP" {
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

    const wsOnly = struct {
        fn f(_: *anyopaque, _: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
            return error.WsOnlyMethod;
        }
    }.f;
    try srv.reg.registerEndpoint(
        .{ .path = "/server/websocket/id", .methods = &.{.GET}, .transports = &.{.WEBSOCKET} },
        @ptrCast(&info),
        wsOnly,
    );
    try srv.reg.registerEndpoint(
        .{ .path = "/server/connection/identify", .methods = &.{.POST}, .transports = &.{.WEBSOCKET} },
        @ptrCast(&info),
        wsOnly,
    );

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const resp = try handleParsed(&srv, .HTTP, .GET, "/server/websocket/id", "", .{}, arena.allocator());
    try std.testing.expectEqual(std.http.Status.not_found, resp.status);
    inline for (.{ RequestType.GET, RequestType.POST, RequestType.DELETE }) |verb| {
        const wrong_verb = try handleParsed(&srv, .HTTP, verb, "/server/connection/identify", "", .{}, arena.allocator());
        try std.testing.expectEqual(std.http.Status.not_found, wrong_verb.status);
    }
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

    const resp = try handleParsed(&srv, .HTTP, .GET, "/does/not/exist", "", .{}, arena.allocator());
    try std.testing.expectEqual(std.http.Status.not_found, resp.status);

    const p = try std.json.parseFromSlice(std.json.Value, arena.allocator(), resp.body, .{});
    const err = p.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, 404), err.get("code").?.integer);
    try std.testing.expectEqualStrings("Not Found", err.get("message").?.string);
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

            const resp = try handleParsed(s, .HTTP, verb, target, body, .{}, a);

            // Body must always be valid JSON (result/error envelope or {} ).
            const parsed = std.json.parseFromSlice(std.json.Value, a, resp.body, .{}) catch {
                return error.FuzzResponseNotValidJson;
            };
            _ = parsed;
            // Status must be a sane HTTP status.
            try std.testing.expect(@backingInt(resp.status) >= 200);
        }
    }.run, .{});
}

test "peer addresses exclude ports for both IP families" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("127.0.0.1", try peerAddress(&buf, try net.IpAddress.parse("127.0.0.1", 1234)));
    try std.testing.expectEqualStrings("::1", try peerAddress(&buf, try net.IpAddress.parse("::1", 1234)));
}

test "fuzz peer address formatting stays within its buffer" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var bytes: [16]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            var buf: [64]u8 = undefined;
            _ = try peerAddress(&buf, .{ .ip6 = .{ .bytes = bytes, .port = 65535, .interface = .none } });
        }
    }.run, .{});
}

test "file downloads send exactly the advertised size for a virtual file" {
    const TestServer = @import("testutil/server.zig").TestServer;
    const ts = try TestServer.init(std.testing.allocator);
    defer ts.stop();
    ts.app.file_ctx.roots = &.{.{ .name = "virtual", .path = "/proc", .full_access = false }};
    const file = try std.Io.Dir.cwd().openFile(ts.io, "/proc/version", .{});
    defer file.close(ts.io);
    try std.testing.expectEqual(@as(u64, 0), (try file.stat(ts.io)).size);
    const contents = try ts.get(std.testing.allocator, "/server/files/virtual/version");
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqual(@as(usize, 0), contents.len);
}

test "fuzz HTTP query decoding returns UTF-8 or rejects the request" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var bytes: [128]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            const target = try std.fmt.allocPrint(alloc, "/?{s}", .{bytes});
            const params = queryParams(alloc, target) catch |err| switch (err) {
                error.InvalidParams => return,
                else => return err,
            };
            if (params != .object) return;
            var it = params.object.iterator();
            while (it.next()) |entry| {
                try std.testing.expect(std.unicode.utf8ValidateSlice(entry.key_ptr.*));
                try std.testing.expect(std.unicode.utf8ValidateSlice(entry.value_ptr.string));
            }
        }
    }.run, .{});
}

/// A live test server that trusts no client address.
fn untrustedServer(alloc: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir) !*@import("testutil/server.zig").TestServer {
    try tmp.dir.writeFile(io, .{ .sub_path = "m.cfg", .data = "[authorization]\ntrusted_clients:\n 10.0.0.0/8\n" });
    const cfg_path = try tmp.dir.realPathFileAlloc(io, "m.cfg", alloc);
    defer alloc.free(cfg_path);
    return @import("testutil/server.zig").TestServer.initWithConfig(alloc, cfg_path);
}

/// Send raw request bytes to the live server and return the response status line.
fn rawStatusLine(io: Io, port: u16, request: []const u8, out: []u8) ![]const u8 {
    const stream = try (try net.IpAddress.parse("127.0.0.1", port)).connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [1024]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(request);
    try w.interface.flush();
    var r = stream.reader(io, out);
    return std.mem.trimEnd(u8, try r.interface.takeDelimiterInclusive('\n'), "\r\n");
}

test "an unauthenticated /server/jsonrpc caller runs only auth-free methods" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ts = try untrustedServer(alloc, threaded.io(), &tmp);
    defer ts.stop();

    const denied = try ts.postJson(alloc, jsonrpc_path,
        \\{"jsonrpc":"2.0","method":"access.get_api_key","id":1}
    );
    defer alloc.free(denied);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","error":{"code":-32602,"message":"Unauthorized"},"id":1}
    , denied);
    const open = try ts.postJson(alloc, jsonrpc_path,
        \\{"jsonrpc":"2.0","method":"access.info","id":2}
    );
    defer alloc.free(open);
    try std.testing.expect(std.mem.indexOf(u8, open, "\"result\"") != null);
}

test "client-supplied _current_user does not make a request trusted" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ts = try untrustedServer(alloc, threaded.io(), &tmp);
    defer ts.stop();

    const rest = try ts.get(alloc, "/access/info?_current_user=_TRUSTED_USER_&_remote_ip=10.0.0.1");
    defer alloc.free(rest);
    try std.testing.expect(std.mem.indexOf(u8, rest, "\"trusted\":false") != null);
    const rpc = try ts.postJson(alloc, jsonrpc_path,
        \\{"jsonrpc":"2.0","method":"access.info","params":{"_current_user":"_TRUSTED_USER_","_remote_ip":"10.0.0.1"},"id":1}
    );
    defer alloc.free(rpc);
    try std.testing.expect(std.mem.indexOf(u8, rpc, "\"trusted\":false") != null);
}

test "an untrusted WebSocket client must identify with credentials" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ts = try untrustedServer(alloc, threaded.io(), &tmp);
    defer ts.stop();
    const ws_client = @import("testutil/ws_client.zig");
    const c = try ws_client.connect(ts, alloc);
    defer c.close();

    const denied = try c.call(alloc, "access.get_api_key", null);
    defer alloc.free(denied);
    try std.testing.expect(std.mem.indexOf(u8, denied, "\"Unauthorized\"") != null);
    const no_creds = try c.call(alloc, "server.connection.identify",
        \\{"client_name":"t","version":"1","type":"web","url":"u"}
    );
    defer alloc.free(no_creds);
    try std.testing.expect(std.mem.indexOf(u8, no_creds, "\"Unauthorized\"") != null);

    var params_buf: [192]u8 = undefined;
    const params = try std.fmt.bufPrint(&params_buf,
        \\{{"client_name":"t","version":"1","type":"web","url":"u","api_key":"{s}"}}
    , .{&ts.app.auth_ctx.api_key});
    const ok = try c.call(alloc, "server.connection.identify", params);
    defer alloc.free(ok);
    try std.testing.expect(std.mem.indexOf(u8, ok, "\"connection_id\"") != null);
    const key = try c.call(alloc, "access.get_api_key", null);
    defer alloc.free(key);
    try std.testing.expect(std.mem.indexOf(u8, key, &ts.app.auth_ctx.api_key) != null);
}

test "WebSocket upgrades check the origin and the bridge requires auth" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ts = try untrustedServer(alloc, threaded.io(), &tmp);
    defer ts.stop();
    const upgrade = "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n";
    var buf: [1024]u8 = undefined;

    try std.testing.expectEqualStrings("HTTP/1.1 403 Forbidden", try rawStatusLine(ts.io, ts.port(), "GET /websocket HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://evil.example\r\n" ++ upgrade ++ "\r\n", &buf));
    var req_buf: [512]u8 = undefined;
    const same = try std.fmt.bufPrint(&req_buf, "GET /websocket HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nOrigin: http://127.0.0.1:{d}\r\n" ++ upgrade ++ "\r\n", .{ ts.port(), ts.port() });
    try std.testing.expectEqualStrings("HTTP/1.1 101 Switching Protocols", try rawStatusLine(ts.io, ts.port(), same, &buf));
    try std.testing.expectEqualStrings("HTTP/1.1 401 Unauthorized", try rawStatusLine(ts.io, ts.port(), "GET /klippysocket HTTP/1.1\r\nHost: 127.0.0.1\r\n" ++ upgrade ++ "\r\n", &buf));
}

test "originAllowed matches the Host header or cors_domains" {
    const cors = [_][]const u8{"*.example.com"};
    try std.testing.expect(originAllowed(&.{}, null, "h:1"));
    try std.testing.expect(originAllowed(&.{}, "http://Printer.local:7125/path", "printer.local:7125"));
    try std.testing.expect(!originAllowed(&.{}, "http://evil.example", "printer.local:7125"));
    try std.testing.expect(!originAllowed(&.{}, "http://printer.local", "printer.local:7125"));
    try std.testing.expect(originAllowed(&cors, "https://ui.example.com", "printer.local"));
}

test "fuzz originAllowed never crashes and allows a missing origin" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var o: [48]u8 = undefined;
            var h: [24]u8 = undefined;
            const ol = smith.valueRangeAtMostWithHash(u8, 0, o.len, 0);
            const hl = smith.valueRangeAtMostWithHash(u8, 0, h.len, 1);
            smith.bytesWithHash(o[0..ol], 2);
            smith.bytesWithHash(h[0..hl], 3);
            _ = originAllowed(&.{"*.x"}, o[0..ol], h[0..hl]);
            try std.testing.expect(originAllowed(&.{}, null, h[0..hl]));
        }
    }.run, .{});
}

test "Expect: 100-continue gets an interim response, then the body is read" {
    const TestServer = @import("testutil/server.zig").TestServer;
    const ts = try TestServer.init(std.testing.allocator);
    defer ts.stop();
    const body =
        \\{"jsonrpc":"2.0","method":"server.info","id":1}
    ;
    const stream = try (try net.IpAddress.parse("127.0.0.1", ts.port())).connect(ts.io, .{ .mode = .stream });
    defer stream.close(ts.io);
    var wbuf: [512]u8 = undefined;
    var w = stream.writer(ts.io, &wbuf);
    try w.interface.print("POST /server/jsonrpc HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nExpect: 100-continue\r\nContent-Length: {d}\r\n\r\n", .{body.len});
    try w.interface.flush();
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(ts.io, &rbuf);
    try std.testing.expectEqualStrings("HTTP/1.1 100 Continue\r\n", try r.interface.takeDelimiterInclusive('\n'));
    try std.testing.expectEqualStrings("\r\n", try r.interface.takeDelimiterInclusive('\n'));
    try w.interface.writeAll(body);
    try w.interface.flush();
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\n", try r.interface.takeDelimiterInclusive('\n'));
}

test "an oversized body gets 413 and the connection closes before its remainder" {
    const TestServer = @import("testutil/server.zig").TestServer;
    const ts = try TestServer.init(std.testing.allocator);
    defer ts.stop();
    const stream = try (try net.IpAddress.parse("127.0.0.1", ts.port())).connect(ts.io, .{ .mode = .stream });
    defer stream.close(ts.io);
    var wbuf: [4096]u8 = undefined;
    var w = stream.writer(ts.io, &wbuf);
    try w.interface.print("POST /server/database/item HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\n\r\n", .{max_request_body + 64});
    try w.interface.splatByteAll(' ', max_request_body + 1);
    try w.interface.flush();
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(ts.io, &rbuf);
    try std.testing.expectEqualStrings("HTTP/1.1 413 Payload Too Large\r\n", try r.interface.takeDelimiterInclusive('\n'));
    // The server closes instead of parsing the rest of the body as a request.
    var closes = false;
    while (true) {
        const line = try r.interface.takeDelimiterInclusive('\n');
        if (std.mem.eql(u8, line, "\r\n")) break;
        if (std.ascii.eqlIgnoreCase(line, "connection: close\r\n")) closes = true;
    }
    try std.testing.expect(closes);
}

test "a multipart boundary longer than RFC 2046 allows is refused" {
    const TestServer = @import("testutil/server.zig").TestServer;
    const ts = try TestServer.init(std.testing.allocator);
    defer ts.stop();
    // A 65535-byte boundary line fills the 64 KiB upload buffer; its
    // separator would not fit the buffer.
    const line_len = 64 * 1024 - 1;
    const stream = try (try net.IpAddress.parse("127.0.0.1", ts.port())).connect(ts.io, .{ .mode = .stream });
    defer stream.close(ts.io);
    var wbuf: [4096]u8 = undefined;
    var w = stream.writer(ts.io, &wbuf);
    try w.interface.print("POST /server/files/upload HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\n\r\n", .{line_len + 1 + 8});
    try w.interface.splatByteAll('-', line_len);
    try w.interface.writeAll("\nxxxxxxxx");
    try w.interface.flush();
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(ts.io, &rbuf);
    try std.testing.expectEqualStrings("HTTP/1.1 400 Bad Request\r\n", try r.interface.takeDelimiterInclusive('\n'));
}
