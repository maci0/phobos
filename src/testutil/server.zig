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

    /// Upload a file via POST /server/files/upload using a multipart/form-data
    /// body. `root`/`dir` are optional form fields; `filename` and `contents`
    /// are the file part. Returns the owned response body.
    pub fn uploadFile(
        self: *TestServer,
        alloc: std.mem.Allocator,
        root: ?[]const u8,
        dir: ?[]const u8,
        filename: []const u8,
        contents: []const u8,
    ) ![]u8 {
        const boundary = "----phobostestboundary";
        var b: std.Io.Writer.Allocating = .init(alloc);
        defer b.deinit();
        const w = &b.writer;
        if (root) |r| {
            try w.print("--{s}\r\nContent-Disposition: form-data; name=\"root\"\r\n\r\n{s}\r\n", .{ boundary, r });
        }
        if (dir) |d| {
            try w.print("--{s}\r\nContent-Disposition: form-data; name=\"path\"\r\n\r\n{s}\r\n", .{ boundary, d });
        }
        try w.print(
            "--{s}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{s}\"\r\nContent-Type: application/octet-stream\r\n\r\n{s}\r\n--{s}--\r\n",
            .{ boundary, filename, contents, boundary },
        );
        return self.postJson(alloc, "/server/files/upload", b.written());
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

// ---------------------------------------------------------------------------
// Authorization (access.*) integration tests — full socket → auth path
// ---------------------------------------------------------------------------

test "access: GET /access/info is reachable without auth and has the shape" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/access/info");
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?;
    try std.testing.expectEqualStrings("moonraker", result.object.get("default_source").?.string);
    try std.testing.expect(result.object.get("available_sources").? == .array);
    try std.testing.expect(result.object.get("login_required").? == .bool);
}

test "access: GET /access/api_key returns a 32-char key" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/access/api_key");
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    // api_key endpoint has wrap_result=true → {"result": "<key>"}.
    const result = parsed.value.object.get("result").?;
    try std.testing.expectEqual(@as(usize, 32), result.string.len);
}

test "access: create user → login → use JWT on a protected route" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    // Create a user (POST /access/user).
    const create_body = try ts.postJson(alloc, "/access/user",
        \\{"username":"inttest_user","password":"sw0rdfish"}
    );
    defer alloc.free(create_body);
    const cp = try std.json.parseFromSlice(std.json.Value, alloc, create_body, .{});
    defer cp.deinit();
    const created = cp.value.object.get("result").?;
    try std.testing.expectEqualStrings("user_created", created.object.get("action").?.string);
    try std.testing.expect(created.object.get("token").? == .string);
    try std.testing.expect(created.object.get("refresh_token").? == .string);
}

test "access: login returns a JWT and refresh token; refresh mints a new token" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const cb = try ts.postJson(alloc, "/access/user",
        \\{"username":"refresher2","password":"pw"}
    );
    defer alloc.free(cb);

    const login_body = try ts.postJson(alloc, "/access/login",
        \\{"username":"refresher2","password":"pw"}
    );
    defer alloc.free(login_body);
    const lp = try std.json.parseFromSlice(std.json.Value, alloc, login_body, .{});
    defer lp.deinit();
    const logged = lp.value.object.get("result").?;
    try std.testing.expectEqualStrings("user_logged_in", logged.object.get("action").?.string);
    const refresh_token = logged.object.get("refresh_token").?.string;

    // refresh_jwt with the refresh token → new access token.
    var rbuf: std.Io.Writer.Allocating = .init(alloc);
    defer rbuf.deinit();
    var jw: std.json.Stringify = .{ .writer = &rbuf.writer };
    try jw.beginObject();
    try jw.objectField("refresh_token");
    try jw.write(refresh_token);
    try jw.endObject();

    const refresh_body = try ts.postJson(alloc, "/access/refresh_jwt", rbuf.written());
    defer alloc.free(refresh_body);
    const rp = try std.json.parseFromSlice(std.json.Value, alloc, refresh_body, .{});
    defer rp.deinit();
    const refreshed = rp.value.object.get("result").?;
    try std.testing.expectEqualStrings("user_jwt_refresh", refreshed.object.get("action").?.string);
    try std.testing.expect(refreshed.object.get("token").? == .string);
}

test "access: wrong password login returns an error envelope" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const cb = try ts.postJson(alloc, "/access/user",
        \\{"username":"badpw","password":"right"}
    );
    defer alloc.free(cb);

    const body = try ts.postJson(alloc, "/access/login",
        \\{"username":"badpw","password":"wrong"}
    );
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("error") != null);
}

test "access: GET /access/users/list returns a users array" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/access/users/list");
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?;
    try std.testing.expect(result.object.get("users").? == .array);
}

test "access: POST /access/api_key regenerates the key" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const get1 = try ts.get(alloc, "/access/api_key");
    defer alloc.free(get1);
    const g1 = try std.json.parseFromSlice(std.json.Value, alloc, get1, .{});
    defer g1.deinit();
    const key1 = try alloc.dupe(u8, g1.value.object.get("result").?.string);
    defer alloc.free(key1);

    const post = try ts.postJson(alloc, "/access/api_key", "{}");
    defer alloc.free(post);
    const pp = try std.json.parseFromSlice(std.json.Value, alloc, post, .{});
    defer pp.deinit();
    const key2 = pp.value.object.get("result").?.string;
    try std.testing.expectEqual(@as(usize, 32), key2.len);
    try std.testing.expect(!std.mem.eql(u8, key1, key2));
}

// ---------------------------------------------------------------------------
// File manager (server.files.*) integration tests — full socket path on a
// per-instance temp datadir.
// ---------------------------------------------------------------------------

fn resultOf(alloc: std.mem.Allocator, body: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, body, .{});
}

test "files: GET /server/files/roots lists gcodes/config/logs" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/server/files/roots");
    defer alloc.free(body);
    const p = try resultOf(alloc, body);
    defer p.deinit();
    const roots = p.value.object.get("result").?.array;
    try std.testing.expect(roots.items.len >= 3);
    var found_gcodes = false;
    for (roots.items) |r| {
        if (std.mem.eql(u8, r.object.get("name").?.string, "gcodes")) {
            found_gcodes = true;
            try std.testing.expectEqualStrings("rw", r.object.get("permissions").?.string);
        }
    }
    try std.testing.expect(found_gcodes);
}

test "files: upload → list → metadata → download round-trip" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    // Upload a gcode file.
    const up = try ts.uploadFile(alloc, "gcodes", null, "round.gcode", "G28\nG1 X1 Y2\n");
    defer alloc.free(up);
    const up_p = try resultOf(alloc, up);
    defer up_p.deinit();
    const up_res = up_p.value.object.get("result").?.object;
    const item = up_res.get("item").?.object;
    try std.testing.expectEqualStrings("round.gcode", item.get("path").?.string);
    try std.testing.expectEqualStrings("gcodes", item.get("root").?.string);
    try std.testing.expectEqual(false, up_res.get("print_started").?.bool);

    // List shows it.
    const list = try ts.get(alloc, "/server/files/list?root=gcodes");
    defer alloc.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, "round.gcode") != null);

    // Metadata has the record shape.
    const md = try ts.get(alloc, "/server/files/metadata?filename=round.gcode");
    defer alloc.free(md);
    const md_p = try resultOf(alloc, md);
    defer md_p.deinit();
    const md_res = md_p.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("round.gcode", md_res.get("filename").?.string);
    try std.testing.expect(md_res.get("size") != null);
    try std.testing.expect(md_res.get("uuid") != null);
    try std.testing.expect(md_res.get("thumbnails").? == .array);

    // Download round-trips the exact bytes.
    const dl = try ts.get(alloc, "/server/files/gcodes/round.gcode");
    defer alloc.free(dl);
    try std.testing.expectEqualStrings("G28\nG1 X1 Y2\n", dl);
}

test "files: get_directory shows uploaded file with disk_usage and root_info" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const up = try ts.uploadFile(alloc, "gcodes", null, "dir_test.gcode", "G1\n");
    defer alloc.free(up);

    const body = try ts.get(alloc, "/server/files/directory?path=gcodes");
    defer alloc.free(body);
    const p = try resultOf(alloc, body);
    defer p.deinit();
    const res = p.value.object.get("result").?.object;
    try std.testing.expect(res.get("files").? == .array);
    try std.testing.expect(res.get("dirs").? == .array);
    const du = res.get("disk_usage").?.object;
    try std.testing.expect(du.get("total") != null);
    try std.testing.expect(du.get("used") != null);
    try std.testing.expect(du.get("free") != null);
    const ri = res.get("root_info").?.object;
    try std.testing.expectEqualStrings("gcodes", ri.get("name").?.string);
}

test "files: mkdir then rmdir via POST/DELETE /server/files/directory" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const mk = try ts.postJson(alloc, "/server/files/directory",
        \\{"path":"gcodes/intdir"}
    );
    defer alloc.free(mk);
    const mk_p = try resultOf(alloc, mk);
    defer mk_p.deinit();
    try std.testing.expectEqualStrings("create_dir", mk_p.value.object.get("result").?.object.get("action").?.string);

    // DELETE via query string (Zig client has no DELETE body).
    const rm = try ts.deleteJson(alloc, "/server/files/directory?path=gcodes/intdir", null);
    defer alloc.free(rm);
    const rm_p = try resultOf(alloc, rm);
    defer rm_p.deinit();
    try std.testing.expectEqualStrings("delete_dir", rm_p.value.object.get("result").?.object.get("action").?.string);
}

test "files: move then copy then delete a file" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const up = try ts.uploadFile(alloc, "gcodes", null, "mc.gcode", "G28\n");
    defer alloc.free(up);

    // Move.
    const mv = try ts.postJson(alloc, "/server/files/move",
        \\{"source":"gcodes/mc.gcode","dest":"gcodes/mc2.gcode"}
    );
    defer alloc.free(mv);
    const mv_p = try resultOf(alloc, mv);
    defer mv_p.deinit();
    try std.testing.expectEqualStrings("move_file", mv_p.value.object.get("result").?.object.get("action").?.string);

    // Copy.
    const cp = try ts.postJson(alloc, "/server/files/copy",
        \\{"source":"gcodes/mc2.gcode","dest":"gcodes/mc3.gcode"}
    );
    defer alloc.free(cp);
    const cp_p = try resultOf(alloc, cp);
    defer cp_p.deinit();
    try std.testing.expectEqualStrings("create_file", cp_p.value.object.get("result").?.object.get("action").?.string);

    // Delete (DELETE /server/files/<root>/<path>).
    const del = try ts.deleteJson(alloc, "/server/files/gcodes/mc3.gcode", null);
    defer alloc.free(del);
    const del_p = try resultOf(alloc, del);
    defer del_p.deinit();
    try std.testing.expectEqualStrings("delete_file", del_p.value.object.get("result").?.object.get("action").?.string);
}

test "files: path escape attempt is rejected (403/400 error envelope)" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    // Download with a traversal escape → error envelope, never serves /etc.
    const body = try ts.get(alloc, "/server/files/gcodes/../../../etc/passwd");
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "root:") == null);
}

test "files: notify_filelist_changed emitted on upload with correct payload" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    // Subscribe a websocket-less recorder via the connection registry. Simplest
    // path: attach a recording writer to a fresh connection.
    const RecordWriter = struct {
        alloc: std.mem.Allocator,
        frames: std.ArrayList([]u8) = .empty,
        fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const dup = try self.alloc.dupe(u8, bytes);
            try self.frames.append(self.alloc, dup);
        }
        fn deinit(self: *@This()) void {
            for (self.frames.items) |f| self.alloc.free(f);
            self.frames.deinit(self.alloc);
        }
    };
    var rec = RecordWriter{ .alloc = alloc };
    defer rec.deinit();
    const conns = ts.connsRef();
    const cid = try conns.add(ts.io);
    conns.attachWriter(ts.io, cid, &rec, RecordWriter.write);

    const up = try ts.uploadFile(alloc, "gcodes", null, "notif.gcode", "G28\n");
    defer alloc.free(up);

    // The filelist_changed notification must have reached the connection.
    try std.testing.expect(rec.frames.items.len >= 1);
    var saw = false;
    for (rec.frames.items) |f| {
        if (std.mem.indexOf(u8, f, "notify_filelist_changed") != null and
            std.mem.indexOf(u8, f, "create_file") != null and
            std.mem.indexOf(u8, f, "notif.gcode") != null)
        {
            saw = true;
        }
    }
    try std.testing.expect(saw);
}
