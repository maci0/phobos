//! In-process HTTP test harness.
//!
//! `TestServer` owns a `std.Io.Threaded` event loop, binds a `Listener` on an
//! ephemeral 127.0.0.1 port, and runs the real `http_transport.serveConn` accept
//! loop in the background. `get` / `postJson` issue requests via
//! `std.http.Client.fetch` and return the response body, so tests exercise the
//! full socket → std.http.Server → registry → handler → std.http.Client path.
//!
//! `TestServer` now builds on `App` (src/app.zig) so tests and the production
//! binary share identical registration wiring.

const std = @import("std");
const Io = std.Io;

const ioz = @import("../io.zig");
const app_mod = @import("../app.zig");
const http_transport = @import("../http_transport.zig");
const methods = @import("../core/methods.zig");
const notify = @import("../server/notify.zig");
const connections_mod = @import("../server/connections.zig");

pub const TestServer = struct {
    threaded: *std.Io.Threaded,
    io: Io,
    listener: ioz.Listener,
    bound_port: u16,

    app: *app_mod.App,
    srv: *http_transport.Server,
    /// Pointer into app.conns — exposed as a field for compatibility with
    /// ws_client tests that inspect connection state directly.
    conns: *connections_mod.Connections,

    serve_fut: Io.Future(void),

    alloc: std.mem.Allocator,

    fn serveLoop(listener: *ioz.Listener, pio: Io, ctx: *anyopaque) void {
        listener.serveWith(pio, ctx, http_transport.connHandler) catch {};
    }

    /// Spin up a server with all endpoints registered via App.
    pub fn init(alloc: std.mem.Allocator) !*TestServer {
        const self = try alloc.create(TestServer);
        errdefer alloc.destroy(self);

        self.alloc = alloc;
        self.threaded = try alloc.create(std.Io.Threaded);
        self.threaded.* = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        self.io = self.threaded.io();

        self.app = try alloc.create(app_mod.App);
        errdefer alloc.destroy(self.app);
        self.app.* = try app_mod.App.init(alloc);

        self.srv = try alloc.create(http_transport.Server);
        errdefer alloc.destroy(self.srv);
        self.srv.* = self.app.httpServer(self.io);
        // Convenience pointer for tests that inspect connection state.
        self.conns = self.app.conns;

        self.listener = try ioz.Listener.bind(self.io, "127.0.0.1", 0);
        self.bound_port = try self.listener.port();

        self.serve_fut = self.io.async(serveLoop, .{ &self.listener, self.io, @as(*anyopaque, @ptrCast(self.srv)) });
        return self;
    }

    pub fn port(self: *TestServer) u16 {
        return self.bound_port;
    }

    /// Expose the ServerInfo so tests can inject warnings etc.
    pub fn serverInfo(self: *TestServer) *methods.ServerInfo {
        return self.app.info;
    }

    /// Expose the Connections registry so integration tests can inspect state.
    pub fn connsRef(self: *TestServer) *@import("../server/connections.zig").Connections {
        return self.app.conns;
    }

    /// Broadcast a notification to every connected client via the app's bus.
    pub fn emit(self: *TestServer, method: []const u8, params: std.json.Value) !void {
        return self.app.bus.emit(self.io, method, params);
    }

    /// Stop the accept loop and free everything.
    pub fn stop(self: *TestServer) void {
        self.serve_fut.cancel(self.io);
        self.listener.deinit(self.io);
        self.app.deinit(self.io);
        self.threaded.deinit();

        const alloc = self.alloc;
        alloc.destroy(self.srv);
        alloc.destroy(self.app);
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

    /// Issue a DELETE request. Body is passed as JSON query params aren't supported
    /// for DELETE in std.http.Client, so params must be embedded in the path as
    /// query string (e.g. "?namespace=ns&key=k"), or pass null for bodyless DELETE.
    pub fn deleteJson(self: *TestServer, alloc: std.mem.Allocator, path: []const u8, _: ?[]const u8) ![]u8 {
        return self.request(alloc, .DELETE, path, null);
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
    ts.serverInfo().warnings = &warns;

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

// ---------------------------------------------------------------------------
// Database component integration tests
// ---------------------------------------------------------------------------

const build_options = @import("build_options");

test "database: GET /server/database/list returns namespaces and backups" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/server/database/list");
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("result").?;
    try std.testing.expect(result.object.get("namespaces") != null);
    try std.testing.expect(result.object.get("backups") != null);
}

test "database: POST item then GET it back — value round-trips (lmdb only)" {
    if (!build_options.with_lmdb) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    // POST an item.
    const post_body = try ts.postJson(alloc, "/server/database/item",
        \\{"namespace":"inttest","key":"mykey","value":{"x":99}}
    );
    defer alloc.free(post_body);
    const post_parsed = try std.json.parseFromSlice(std.json.Value, alloc, post_body, .{});
    defer post_parsed.deinit();
    const post_result = post_parsed.value.object.get("result").?;
    try std.testing.expectEqualStrings("inttest", post_result.object.get("namespace").?.string);
    try std.testing.expectEqualStrings("mykey", post_result.object.get("key").?.string);
    try std.testing.expectEqual(@as(i64, 99), post_result.object.get("value").?.object.get("x").?.integer);

    // GET it back.
    const get_body = try ts.get(alloc, "/server/database/item?namespace=inttest&key=mykey");
    defer alloc.free(get_body);
    const get_parsed = try std.json.parseFromSlice(std.json.Value, alloc, get_body, .{});
    defer get_parsed.deinit();
    const get_result = get_parsed.value.object.get("result").?;
    try std.testing.expectEqualStrings("inttest", get_result.object.get("namespace").?.string);
    try std.testing.expectEqualStrings("mykey", get_result.object.get("key").?.string);
    try std.testing.expectEqual(@as(i64, 99), get_result.object.get("value").?.object.get("x").?.integer);
}

test "database: GET /server/database/list includes namespace after POST (lmdb only)" {
    if (!build_options.with_lmdb) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    // Insert into a fresh namespace.
    const post_body = try ts.postJson(alloc, "/server/database/item",
        \\{"namespace":"listtest","key":"k","value":1}
    );
    defer alloc.free(post_body);

    // List should now contain "listtest".
    const list_body = try ts.get(alloc, "/server/database/list");
    defer alloc.free(list_body);
    try std.testing.expect(std.mem.indexOf(u8, list_body, "\"listtest\"") != null);
}

test "database: DELETE removes item; subsequent GET returns error shape (lmdb only)" {
    if (!build_options.with_lmdb) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    // Insert.
    const post_body = try ts.postJson(alloc, "/server/database/item",
        \\{"namespace":"deltest","key":"dk","value":"hello"}
    );
    defer alloc.free(post_body);

    // DELETE via query string (Zig HTTP client does not support DELETE + body).
    const del_body = try ts.deleteJson(alloc, "/server/database/item?namespace=deltest&key=dk", null);
    defer alloc.free(del_body);
    const del_parsed = try std.json.parseFromSlice(std.json.Value, alloc, del_body, .{});
    defer del_parsed.deinit();
    const del_result = del_parsed.value.object.get("result").?;
    try std.testing.expectEqualStrings("hello", del_result.object.get("value").?.string);

    // GET after delete → error envelope (404).
    const get_body = try ts.get(alloc, "/server/database/item?namespace=deltest&key=dk");
    defer alloc.free(get_body);
    try std.testing.expect(std.mem.indexOf(u8, get_body, "\"error\"") != null);
}

test "database: GET missing key returns error shape" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/server/database/item?namespace=nosuchns&key=nosuchkey");
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("error") != null);
}

test "database: POST to forbidden namespace returns 403 error" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.postJson(alloc, "/server/database/item",
        \\{"namespace":"database","key":"k","value":1}
    );
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("error") != null);
    try std.testing.expectEqual(@as(i64, 403), parsed.value.object.get("error").?.object.get("code").?.integer);
}

test "database: POST to protected namespace (moonraker) returns error" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.postJson(alloc, "/server/database/item",
        \\{"namespace":"moonraker","key":"k","value":1}
    );
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("error") != null);
}

test "database: POST /server/database/compact returns old_size and new_size" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.postJson(alloc, "/server/database/compact", "{}");
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?;
    try std.testing.expect(result.object.get("old_size") != null);
    try std.testing.expect(result.object.get("new_size") != null);
}

// ---------------------------------------------------------------------------
// Data store component integration tests
// ---------------------------------------------------------------------------

test "data_store: GET /server/gcode_store returns gcode_store array" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/server/gcode_store");
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?;
    try std.testing.expect(result.object.get("gcode_store") != null);
    try std.testing.expect(result.object.get("gcode_store").? == .array);
}

test "data_store: GET /server/temperature_store returns empty object (no Klippy)" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/server/temperature_store");
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?;
    // Empty object (no sensors without Klippy)
    try std.testing.expect(result == .object);
}

// ---------------------------------------------------------------------------
// Server misc integration tests
// ---------------------------------------------------------------------------

test "server_misc: POST /server/restart returns ok" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.postJson(alloc, "/server/restart", "{}");
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?;
    try std.testing.expectEqualStrings("ok", result.string);
}

test "server_misc: POST /server/logs/rollover returns rolled_over and failed" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.postJson(alloc, "/server/logs/rollover", "{}");
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?;
    try std.testing.expect(result.object.get("rolled_over") != null);
    try std.testing.expect(result.object.get("failed") != null);
}

// ---------------------------------------------------------------------------
// Notifier integration tests
// ---------------------------------------------------------------------------

test "notifier: GET /server/notifiers/list returns empty notifiers array" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/server/notifiers/list");
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?;
    try std.testing.expect(result.object.get("notifiers") != null);
    try std.testing.expectEqual(@as(usize, 0), result.object.get("notifiers").?.array.items.len);
}

// ---------------------------------------------------------------------------
// Webcam integration tests
// ---------------------------------------------------------------------------

test "webcam: GET /server/webcams/list returns empty webcams array" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/server/webcams/list");
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?;
    try std.testing.expect(result.object.get("webcams") != null);
    try std.testing.expectEqual(@as(usize, 0), result.object.get("webcams").?.array.items.len);
}

test "webcam: POST /server/webcams/item creates webcam (HTTP)" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.postJson(alloc, "/server/webcams/item",
        \\{"name":"test_cam","stream_url":"http://localhost/stream"}
    );
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?;
    try std.testing.expect(result.object.get("webcam") != null);
    try std.testing.expectEqualStrings("test_cam", result.object.get("webcam").?.object.get("name").?.string);
}

// ---------------------------------------------------------------------------
// Sensor integration tests
// ---------------------------------------------------------------------------

test "sensor: GET /server/sensors/list returns empty sensors object" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/server/sensors/list");
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?;
    try std.testing.expect(result.object.get("sensors") != null);
}

test "sensor: GET /server/sensors/info without sensor param returns error" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/server/sensors/info");
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("error") != null);
}

test "sensor: GET /server/sensors/measurements returns empty object (no sensors)" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/server/sensors/measurements");
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?;
    try std.testing.expect(result == .object);
}
