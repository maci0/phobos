//! In-process HTTP test harness.
//!
//! `TestServer` owns a `std.Io.Threaded` event loop, binds a `Listener` on an
//! ephemeral 127.0.0.1 port, and runs the real `http_transport.serveConn` accept
//! loop in the background. `get` / `postJson` issue requests via
//! `std.http.Client.fetch` and return the response body, so tests exercise the
//! full socket → std.http.Server → registry → handler → std.http.Client path.

const std = @import("std");
const Io = std.Io;

const ioz = @import("../io.zig");
const Core = @import("../server/core.zig").Core;
const registry = @import("../server/registry.zig");
const jsonrpc = @import("../jsonrpc.zig");
const http_transport = @import("../http_transport.zig");
const methods = @import("../core/methods.zig");

pub const TestServer = struct {
    threaded: *std.Io.Threaded,
    io: Io,
    listener: ioz.Listener,
    bound_port: u16,

    core: *Core,
    dispatcher: *jsonrpc.Dispatcher,
    reg: *registry.Registry,
    info: *methods.ServerInfo,
    srv: *http_transport.Server,

    serve_fut: Io.Future(void),

    alloc: std.mem.Allocator,

    fn serveLoop(listener: *ioz.Listener, io: Io, ctx: *anyopaque) void {
        listener.serveWith(io, ctx, http_transport.connHandler) catch {};
    }

    /// Spin up a server with the core endpoints registered.
    pub fn init(alloc: std.mem.Allocator) !*TestServer {
        const self = try alloc.create(TestServer);
        errdefer alloc.destroy(self);

        self.alloc = alloc;
        self.threaded = try alloc.create(std.Io.Threaded);
        self.threaded.* = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        self.io = self.threaded.io();

        self.core = try alloc.create(Core);
        self.core.* = Core.init();

        self.dispatcher = try alloc.create(jsonrpc.Dispatcher);
        self.dispatcher.* = jsonrpc.Dispatcher.init(alloc);

        self.reg = try alloc.create(registry.Registry);
        self.reg.* = registry.Registry.init(alloc, self.dispatcher);

        self.info = try alloc.create(methods.ServerInfo);
        self.info.* = .{};

        try methods.registerCore(self.reg, self.info);

        self.srv = try alloc.create(http_transport.Server);
        self.srv.* = .{
            .io = self.io,
            .core = self.core,
            .reg = self.reg,
            .dispatcher = self.dispatcher,
        };

        self.listener = try ioz.Listener.bind(self.io, "127.0.0.1", 0);
        self.bound_port = try self.listener.port();

        self.serve_fut = self.io.async(serveLoop, .{ &self.listener, self.io, @as(*anyopaque, @ptrCast(self.srv)) });
        return self;
    }

    pub fn port(self: *TestServer) u16 {
        return self.bound_port;
    }

    /// Stop the accept loop and free everything.
    pub fn stop(self: *TestServer) void {
        self.serve_fut.cancel(self.io);
        self.listener.deinit(self.io);
        self.reg.deinit();
        self.dispatcher.deinit();
        self.threaded.deinit();

        const alloc = self.alloc;
        alloc.destroy(self.srv);
        alloc.destroy(self.info);
        alloc.destroy(self.reg);
        alloc.destroy(self.dispatcher);
        alloc.destroy(self.core);
        alloc.destroy(self.threaded);
        alloc.destroy(self);
    }

    fn url(self: *TestServer, buf: []u8, path: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ self.bound_port, path });
    }

    /// Issue a GET and return the owned response body (caller frees with `alloc`).
    pub fn get(self: *TestServer, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
        return self.request(alloc, .GET, path, null);
    }

    /// Issue a POST with a JSON body and return the owned response body.
    pub fn postJson(self: *TestServer, alloc: std.mem.Allocator, path: []const u8, body: []const u8) ![]u8 {
        return self.request(alloc, .POST, path, body);
    }

    fn request(
        self: *TestServer,
        alloc: std.mem.Allocator,
        method: std.http.Method,
        path: []const u8,
        body: ?[]const u8,
    ) ![]u8 {
        var client: std.http.Client = .{ .allocator = alloc, .io = self.io };
        defer client.deinit();

        var url_buf: [256]u8 = undefined;
        const full = try self.url(&url_buf, path);

        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = full },
            .method = method,
            .payload = body,
            .response_writer = &aw.writer,
        });
        _ = result;
        return aw.toOwnedSlice();
    }
};

// --- tests ---------------------------------------------------------------

test "GET /server/info returns result with disconnected klippy state" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/server/info");
    defer alloc.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"api_version_string\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"klippy_connected\":false") != null);
}

test "GET /server/config returns result" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/server/config");
    defer alloc.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"config\"") != null);
}

test "POST /server/jsonrpc server.info result equals the REST result" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const rpc_body = try ts.postJson(alloc, "/server/jsonrpc",
        \\{"jsonrpc":"2.0","method":"server.info","id":1}
    );
    defer alloc.free(rpc_body);

    const rest_body = try ts.get(alloc, "/server/info");
    defer alloc.free(rest_body);

    const rpc_parsed = try std.json.parseFromSlice(std.json.Value, alloc, rpc_body, .{});
    defer rpc_parsed.deinit();
    const rest_parsed = try std.json.parseFromSlice(std.json.Value, alloc, rest_body, .{});
    defer rest_parsed.deinit();

    const rpc_result = rpc_parsed.value.object.get("result").?;
    const rest_result = rest_parsed.value.object.get("result").?;

    const rpc_s = try std.json.Stringify.valueAlloc(alloc, rpc_result, .{});
    defer alloc.free(rpc_s);
    const rest_s = try std.json.Stringify.valueAlloc(alloc, rest_result, .{});
    defer alloc.free(rest_s);

    try std.testing.expectEqualStrings(rest_s, rpc_s);
}

test "GET /server/info?raw=true preserves newlines vs default <br/> substitution" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    // Inject a multi-line warning so the substitution is observable.
    const warns = [_][]const u8{"line one\nline two"};
    ts.info.warnings = &warns;

    const cooked = try ts.get(alloc, "/server/info");
    defer alloc.free(cooked);
    try std.testing.expect(std.mem.indexOf(u8, cooked, "line one<br/>line two") != null);

    const raw = try ts.get(alloc, "/server/info?raw=true");
    defer alloc.free(raw);
    // Raw form keeps the literal newline (JSON-escaped as \n) and no <br/>.
    try std.testing.expect(std.mem.indexOf(u8, raw, "<br/>") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "line one\\nline two") != null);
}

test "GET unknown route returns 404 error envelope" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/no/such/thing");
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, 404), err.get("code").?.integer);
}

test "fuzz_testserver: arbitrary paths never crash the server, always JSON back" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    try std.testing.fuzz(ts, struct {
        fn run(server: *TestServer, smith: *std.testing.Smith) anyerror!void {
            var raw: [64]u8 = undefined;
            smith.bytesWithHash(&raw, 0);
            const n = 1 + (@as(usize, raw[0]) % 40);

            // Build a path from a small safe alphabet (always leading '/').
            const alphabet = "abc/";
            var path_buf: [64]u8 = undefined;
            path_buf[0] = '/';
            var len: usize = 1;
            for (raw[0..n]) |b| {
                path_buf[len] = alphabet[b % alphabet.len];
                len += 1;
            }
            const path = path_buf[0..len];

            const body = server.get(std.heap.smp_allocator, path) catch return;
            defer std.heap.smp_allocator.free(body);

            const parsed = std.json.parseFromSlice(std.json.Value, std.heap.smp_allocator, body, .{}) catch {
                return error.FuzzResponseNotJson;
            };
            parsed.deinit();
        }
    }.run, .{});
}
