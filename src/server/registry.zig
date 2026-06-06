//! Endpoint registry.
//!
//! Mirrors Moonraker's `APIDefinition` (vendor/moonraker/moonraker/common.py):
//! a single `registerEndpoint` call wires BOTH an HTTP route (path + verb) and
//! the derived JSON-RPC method name(s) into the shared `Dispatcher`, so the one
//! handler is reachable over every transport.
//!
//! JSON-RPC name derivation (`APIDefinition.create`):
//!   * path "/"            -> "."
//!   * single request type -> dotted path  ("/server/info" -> "server.info")
//!   * multiple types      -> last segment prefixed with the verb,
//!                            ("/server/x" GET+POST -> "server.get_x","server.post_x")
//! Verb order is fixed GET, POST, DELETE (the declaration order of RequestType).

const std = @import("std");
const jsonrpc = @import("../jsonrpc.zig");

/// HTTP request verbs we route on. Declaration order is significant: it drives
/// the iteration order used when deriving multi-verb JSON-RPC method names.
pub const RequestType = enum {
    GET,
    POST,
    DELETE,

    /// Lower-cased verb name used as the JSON-RPC method-name prefix.
    pub fn prefix(self: RequestType) []const u8 {
        return switch (self) {
            .GET => "get_",
            .POST => "post_",
            .DELETE => "delete_",
        };
    }

    /// Map an `std.http.Method` to our `RequestType`, or null if unsupported.
    pub fn fromHttp(m: std.http.Method) ?RequestType {
        return switch (m) {
            .GET => .GET,
            .POST => .POST,
            .DELETE => .DELETE,
            else => null,
        };
    }
};

/// Transport channels an endpoint is reachable over.
pub const TransportType = enum {
    HTTP,
    WEBSOCKET,
    MQTT,
    INTERNAL,
};

/// The handler signature is the Dispatcher's erased handler: it is invoked the
/// same way for HTTP and JSON-RPC, the transport only differs in framing.
pub const HandlerFn = *const fn (ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value;

/// Definition of one endpoint. `methods` is the set of HTTP verbs the path
/// accepts; `transports` the channels it is exposed on.
pub const ApiDef = struct {
    path: []const u8,
    methods: []const RequestType,
    transports: []const TransportType = &.{ .HTTP, .WEBSOCKET, .INTERNAL },
    /// When true the HTTP transport wraps the handler result as
    /// `{"result": <r>}`; when false the raw handler result is the body.
    wrap_result: bool = true,
    auth_required: bool = true,
    /// Klipper-proxied endpoint (Moonraker `is_remote=True`). Such endpoints
    /// accept GET|POST on the HTTP route but map to a SINGLE dotted JSON-RPC
    /// method with no `get_`/`post_` verb prefix (common.py APIDefinition.create).
    is_remote: bool = false,
};

/// A registered HTTP route: matched by (path, method).
pub const Route = struct {
    path: []const u8,
    method: RequestType,
    wrap_result: bool,
    auth_required: bool,
    transports: []const TransportType,
    ctx: *anyopaque,
    handler: HandlerFn,
};

/// Maximum dotted method name length we derive without allocation.
pub const max_method_name = 256;

/// Derive the JSON-RPC method name for a (path, verb) pair into `buf`.
///
/// `multi` indicates the endpoint declares more than one request type, which
/// triggers the verb-prefixed last-segment form. Returns a slice of `buf`.
pub fn deriveMethodName(
    buf: []u8,
    path: []const u8,
    verb: RequestType,
    multi: bool,
) error{NameTooLong}![]const u8 {
    // Moonraker strips the leading '/' then replaces '/' with '.'.
    // "/" is the root endpoint and maps to ".".
    if (std.mem.eql(u8, path, "/")) {
        if (buf.len < 1) return error.NameTooLong;
        buf[0] = '.';
        return buf[0..1];
    }

    const trimmed = std.mem.trimStart(u8, path, "/");

    if (!multi) {
        return dotJoin(buf, trimmed);
    }

    // Multi-verb: prefix the final segment with the verb prefix.
    const last_slash = std.mem.lastIndexOfScalar(u8, trimmed, '/');
    var len: usize = 0;
    const prefix = verb.prefix();

    if (last_slash) |idx| {
        // head = trimmed[0..idx] (with '/'→'.'), then '.', prefix, tail
        const head = trimmed[0..idx];
        const tail = trimmed[idx + 1 ..];
        len = (try dotJoin(buf, head)).len;
        len = try appendByte(buf, len, '.');
        len = try appendStr(buf, len, prefix);
        len = try appendStr(buf, len, tail);
    } else {
        len = try appendStr(buf, len, prefix);
        len = try appendStr(buf, len, trimmed);
    }
    return buf[0..len];
}

fn dotJoin(buf: []u8, s: []const u8) error{NameTooLong}![]const u8 {
    if (s.len > buf.len) return error.NameTooLong;
    for (s, 0..) |c, i| buf[i] = if (c == '/') '.' else c;
    return buf[0..s.len];
}

fn appendByte(buf: []u8, len: usize, b: u8) error{NameTooLong}!usize {
    if (len + 1 > buf.len) return error.NameTooLong;
    buf[len] = b;
    return len + 1;
}

fn appendStr(buf: []u8, len: usize, s: []const u8) error{NameTooLong}!usize {
    if (len + s.len > buf.len) return error.NameTooLong;
    @memcpy(buf[len .. len + s.len], s);
    return len + s.len;
}

pub const Registry = struct {
    alloc: std.mem.Allocator,
    dispatcher: *jsonrpc.Dispatcher,
    routes: std.ArrayList(Route) = .empty,
    /// Owns the method-name strings handed to the Dispatcher (which expects
    /// caller-owned, stable-lifetime keys).
    name_pool: std.ArrayList([]u8) = .empty,

    pub fn init(alloc: std.mem.Allocator, dispatcher: *jsonrpc.Dispatcher) Registry {
        return .{ .alloc = alloc, .dispatcher = dispatcher };
    }

    pub fn deinit(self: *Registry) void {
        for (self.name_pool.items) |n| self.alloc.free(n);
        self.name_pool.deinit(self.alloc);
        self.routes.deinit(self.alloc);
    }

    /// Register one endpoint: an HTTP route per declared verb plus the derived
    /// JSON-RPC method(s) on the shared dispatcher (when a non-HTTP transport is
    /// present, matching Moonraker which only derives rpc methods then).
    pub fn registerEndpoint(
        self: *Registry,
        def: ApiDef,
        ctx: *anyopaque,
        handler: HandlerFn,
    ) !void {
        const multi = def.methods.len > 1;

        // HTTP routes: one per verb.
        for (def.methods) |verb| {
            try self.routes.append(self.alloc, .{
                .path = def.path,
                .method = verb,
                .wrap_result = def.wrap_result,
                .auth_required = def.auth_required,
                .transports = def.transports,
                .ctx = ctx,
                .handler = handler,
            });
        }

        // JSON-RPC methods: derived only when a non-HTTP transport exists, to
        // mirror Moonraker (`transports != TransportType.HTTP`).
        if (hasNonHttpTransport(def.transports)) {
            if (def.is_remote) {
                // Klipper-proxied: one plain dotted method regardless of verbs.
                var buf: [max_method_name]u8 = undefined;
                const derived = try deriveMethodName(&buf, def.path, def.methods[0], false);
                const owned = try self.alloc.dupe(u8, derived);
                errdefer self.alloc.free(owned);
                try self.name_pool.append(self.alloc, owned);
                try self.dispatcher.register(owned, ctx, handler);
            } else {
                for (def.methods) |verb| {
                    var buf: [max_method_name]u8 = undefined;
                    const derived = try deriveMethodName(&buf, def.path, verb, multi);
                    const owned = try self.alloc.dupe(u8, derived);
                    errdefer self.alloc.free(owned);
                    try self.name_pool.append(self.alloc, owned);
                    try self.dispatcher.register(owned, ctx, handler);
                }
            }
        }
    }

    /// Look up a route by (verb, path). Returns null when no match.
    pub fn lookup(self: *Registry, method: RequestType, path: []const u8) ?*const Route {
        for (self.routes.items) |*r| {
            if (r.method == method and std.mem.eql(u8, r.path, path)) return r;
        }
        return null;
    }

    /// Look up a route by path alone (any verb) — used to distinguish a 404
    /// (no such path) from a 405 (path exists, wrong verb).
    pub fn pathExists(self: *Registry, path: []const u8) bool {
        for (self.routes.items) |*r| {
            if (std.mem.eql(u8, r.path, path)) return true;
        }
        return false;
    }
};

fn hasNonHttpTransport(transports: []const TransportType) bool {
    for (transports) |t| {
        if (t != .HTTP) return true;
    }
    return false;
}

// --- tests ---------------------------------------------------------------

fn nameOf(path: []const u8, verb: RequestType, multi: bool) ![]const u8 {
    const S = struct {
        var buf: [max_method_name]u8 = undefined;
    };
    return deriveMethodName(&S.buf, path, verb, multi);
}

test "deriveMethodName: root path maps to dot" {
    try std.testing.expectEqualStrings(".", try nameOf("/", .GET, false));
}

test "deriveMethodName: single verb dotted path" {
    try std.testing.expectEqualStrings("server.info", try nameOf("/server/info", .GET, false));
    try std.testing.expectEqualStrings("server.config", try nameOf("/server/config", .GET, false));
}

test "deriveMethodName: single segment" {
    try std.testing.expectEqualStrings("info", try nameOf("/info", .GET, false));
}

test "deriveMethodName: multi-verb prefixes last segment with get_/post_/delete_" {
    try std.testing.expectEqualStrings("machine.get_device", try nameOf("/machine/device", .GET, true));
    try std.testing.expectEqualStrings("machine.post_device", try nameOf("/machine/device", .POST, true));
    try std.testing.expectEqualStrings("machine.delete_device", try nameOf("/machine/device", .DELETE, true));
}

test "deriveMethodName: multi-verb single segment" {
    try std.testing.expectEqualStrings("get_device", try nameOf("/device", .GET, true));
    try std.testing.expectEqualStrings("delete_device", try nameOf("/device", .DELETE, true));
}

test "deriveMethodName: deep path multi-verb" {
    try std.testing.expectEqualStrings(
        "server.database.post_item",
        try nameOf("/server/database/item", .POST, true),
    );
}

test "deriveMethodName: name too long errors" {
    var small: [4]u8 = undefined;
    try std.testing.expectError(error.NameTooLong, deriveMethodName(&small, "/server/info", .GET, false));
}

fn dummyHandler(_: *anyopaque, params: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    return params;
}

var _ctx: u8 = 0;

test "registerEndpoint registers HTTP route and JSON-RPC method" {
    const alloc = std.testing.allocator;
    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    try reg.registerEndpoint(
        .{ .path = "/server/info", .methods = &.{.GET} },
        @ptrCast(&_ctx),
        dummyHandler,
    );

    // HTTP route present.
    const r = reg.lookup(.GET, "/server/info");
    try std.testing.expect(r != null);
    try std.testing.expect(reg.lookup(.POST, "/server/info") == null);

    // JSON-RPC method present in the shared dispatcher.
    try std.testing.expect(d.methods.get("server.info") != null);
}

test "registerEndpoint multi-verb registers all routes and methods" {
    const alloc = std.testing.allocator;
    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    try reg.registerEndpoint(
        .{ .path = "/machine/device", .methods = &.{ .GET, .POST, .DELETE } },
        @ptrCast(&_ctx),
        dummyHandler,
    );

    try std.testing.expect(reg.lookup(.GET, "/machine/device") != null);
    try std.testing.expect(reg.lookup(.POST, "/machine/device") != null);
    try std.testing.expect(reg.lookup(.DELETE, "/machine/device") != null);

    try std.testing.expect(d.methods.get("machine.get_device") != null);
    try std.testing.expect(d.methods.get("machine.post_device") != null);
    try std.testing.expect(d.methods.get("machine.delete_device") != null);
}

test "registerEndpoint HTTP-only transport derives no JSON-RPC method" {
    const alloc = std.testing.allocator;
    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    try reg.registerEndpoint(
        .{ .path = "/server/info", .methods = &.{.GET}, .transports = &.{.HTTP} },
        @ptrCast(&_ctx),
        dummyHandler,
    );

    try std.testing.expect(reg.lookup(.GET, "/server/info") != null);
    try std.testing.expect(d.methods.get("server.info") == null);
}

test "pathExists distinguishes missing path from wrong verb" {
    const alloc = std.testing.allocator;
    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    try reg.registerEndpoint(.{ .path = "/server/info", .methods = &.{.GET} }, @ptrCast(&_ctx), dummyHandler);

    try std.testing.expect(reg.pathExists("/server/info"));
    try std.testing.expect(!reg.pathExists("/nope"));
}

test "fuzz_registry: deriveMethodName never crashes and stays in bounds" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var raw: [128]u8 = undefined;
            smith.bytesWithHash(&raw, 0);
            const n = @as(usize, raw[0]) % raw.len;

            // Build a path-ish input from fuzz bytes restricted to a small alphabet
            // including '/' so we exercise segment splitting.
            const alphabet = "abc/";
            var path_buf: [129]u8 = undefined;
            path_buf[0] = '/';
            var len: usize = 1;
            for (raw[0..n]) |b| {
                path_buf[len] = alphabet[b % alphabet.len];
                len += 1;
            }
            const path = path_buf[0..len];

            const verb: RequestType = switch (raw[0] % 3) {
                0 => .GET,
                1 => .POST,
                else => .DELETE,
            };
            const multi = (raw[0] & 1) == 0;

            var out: [max_method_name]u8 = undefined;
            const name = deriveMethodName(&out, path, verb, multi) catch return;
            // Result must be a slice of out.
            try std.testing.expect(@intFromPtr(name.ptr) >= @intFromPtr(&out));
            try std.testing.expect(name.len <= out.len);
        }
    }.run, .{});
}

test "fuzz_registry: registerEndpoint then lookup is consistent" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const alloc = std.heap.smp_allocator;
            var raw: [32]u8 = undefined;
            smith.bytesWithHash(&raw, 0);

            var d = jsonrpc.Dispatcher.init(alloc);
            defer d.deinit();
            var reg = Registry.init(alloc, &d);
            defer reg.deinit();

            // Fixed valid path; vary the method set.
            const methods: []const RequestType = switch (raw[0] % 4) {
                0 => &.{.GET},
                1 => &.{ .GET, .POST },
                2 => &.{ .GET, .POST, .DELETE },
                else => &.{.POST},
            };
            reg.registerEndpoint(.{ .path = "/server/x", .methods = methods }, @ptrCast(&_ctx), dummyHandler) catch return;

            for (methods) |verb| {
                try std.testing.expect(reg.lookup(verb, "/server/x") != null);
            }
        }
    }.run, .{});
}
