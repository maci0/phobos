//! In-process HTTP test harness.
//!
//! `TestServer` owns a `std.Io.Threaded` event loop, binds a `Listener` on an
//! ephemeral 127.0.0.1 port, and runs the real `http_transport.serveConn` accept
//! loop in the background. `get` / `postJson` issue requests via
//! `std.http.Client` and return the response body, so tests exercise the
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
const MachineCtx = @import("../components/machine.zig").MachineCtx;
const authz = @import("../components/authorization.zig");
const klippy_sim_mod = @import("klippy_sim.zig");
const http_get = @import("../components/http_get.zig");
const default_request_timeout: Io.Duration = .fromSeconds(5);

/// Mock command runner for integration tests: returns fake service state for
/// "systemctl show" calls and no-op for everything else, so tests never
/// accidentally run real systemctl/reboot/shutdown on the host.
fn updateShellOk(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!void {}

fn mockRunCmd(ctx: *anyopaque, gpa: std.mem.Allocator, argv: []const []const u8) anyerror!MachineCtx.RunCmdResult {
    _ = ctx;
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "list-units")) {
        return .{ .stdout = try gpa.dupe(u8, "klipper.service loaded active running\nmoonraker.service loaded active running\n"), .stderr = &.{} };
    }
    if (argv.len >= 3 and std.mem.eql(u8, argv[1], "show")) {
        const out = try gpa.dupe(u8, "active\nrunning\n");
        return .{ .stdout = out, .stderr = &.{} };
    }
    return .{ .stdout = &.{}, .stderr = &.{} };
}

pub const TestServer = struct {
    threaded: *std.Io.Threaded,
    io: Io,
    listener: ioz.Listener,
    bound_port: u16,
    /// Maximum duration of one HTTP request or WebSocket upgrade.
    request_timeout: Io.Duration = default_request_timeout,

    app: *app_mod.App,
    srv: *http_transport.Server,
    /// Pointer into app.conns — exposed as a field for compatibility with
    /// ws_client tests that inspect connection state directly.
    conns: *connections_mod.Connections,

    /// Datadir and Klippy simulator socket. Deleted by `stop`.
    tmp: std.testing.TmpDir,

    /// Thread-safe allocator for the App, so handler leaks and double frees
    /// fail the test. `stop` checks it after `App.deinit`.
    app_gpa: std.heap.DebugAllocator(.{}),

    /// Optional Klippy simulator for end-to-end bridge testing.
    klippy_sim: ?*klippy_sim_mod.KlippySim = null,

    serve_fut: Io.Future(void),

    alloc: std.mem.Allocator,

    fn serveLoop(listener: *ioz.Listener, pio: Io, ctx: *anyopaque) void {
        listener.serveWith(pio, ctx, http_transport.connHandler) catch {};
    }

    /// Spin up a server with all endpoints registered via App.
    pub fn init(alloc: std.mem.Allocator) !*TestServer {
        return initWithConfig(alloc, null);
    }

    /// Same as `init`, but `setConfig` runs before `httpServer` so options such
    /// as `[server] use_xheaders` are the ones the accept loop actually serves.
    pub fn initWithConfig(alloc: std.mem.Allocator, config_path: ?[]const u8) !*TestServer {
        const self = try alloc.create(TestServer);
        errdefer alloc.destroy(self);

        self.klippy_sim = null;
        self.request_timeout = default_request_timeout;
        self.alloc = alloc;
        self.app_gpa = .init;
        // The leak report on this error path is logged by the allocator itself.
        errdefer _ = self.app_gpa.deinit();
        self.threaded = try alloc.create(std.Io.Threaded);
        errdefer alloc.destroy(self.threaded);
        // Handlers run on the deployed handler stack size, so a stack
        // regression fails here instead of only on the printer.
        self.threaded.* = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = ioz.Listener.handler_stack_size });
        errdefer self.threaded.deinit();
        self.io = self.threaded.io();

        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const data_path = try self.tmp.dir.realPathFileAlloc(self.io, ".", alloc);
        defer alloc.free(data_path);

        self.app = try alloc.create(app_mod.App);
        errdefer alloc.destroy(self.app);
        self.app.* = try app_mod.App.init(self.app_gpa.allocator(), self.io, data_path);
        errdefer self.app.deinit(self.io);

        // Prevent tests from accidentally running real systemctl/reboot/shutdown.
        self.app.setMachineRunCmdFn(mockRunCmd, @ptrCast(self));
        // System updates call apt-get through this hook. The test double
        // succeeds without touching the host package manager; the command
        // text is checked in update_manager's unit test.
        self.app.update_ctx.shell = updateShellOk;
        self.app.update_ctx.shell_ctx = self;
        // Disable the proc_stat timer to avoid background-thread + thread-pool
        // interactions that deadlock the test harness.
        self.app.machine_ctx.no_proc_stat_timer = true;
        // Test clients connect from loopback without credentials. A config
        // with `[authorization] trusted_clients` replaces this table.
        try self.app.auth_ctx.setTrustedClients("127.0.0.1 ::1");
        if (config_path) |path| try self.app.setConfig(self.io, path);

        self.srv = try alloc.create(http_transport.Server);
        errdefer alloc.destroy(self.srv);
        self.srv.* = self.app.httpServer(self.io);
        // Convenience pointer for tests that inspect connection state.
        self.conns = self.app.conns;

        self.listener = try ioz.Listener.bind(self.io, "127.0.0.1", 0);
        self.bound_port = self.listener.port();

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

    /// Broadcast a notification to every connected client via the app's bus.
    pub fn emit(self: *TestServer, method: []const u8, params: std.json.Value) !void {
        return self.app.bus.emit(self.io, method, params);
    }

    /// Start a Klippy simulator on a background thread and wire the App's
    /// Klippy bridge to connect to it. Must be called after `init()` and
    /// before any printer.* requests. The socket is `klippy.sock` in `tmp`,
    /// by relative path to stay under the 108-byte `sun_path` limit.
    pub fn startKlippyBridge(self: *TestServer) !void {
        var path_buf: [64]u8 = undefined;
        const socket_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/klippy.sock", .{ std.testing.TmpDir.parent_dir_path, &self.tmp.sub_path });
        const sim = try klippy_sim_mod.KlippySim.init(self.alloc, socket_path);
        errdefer sim.deinit();

        // Point the Klippy connection context at the simulator's socket.
        self.app.klippy_ctx.uds_path = sim.socket_path;

        // start() listens before returning, so the bridge's connect queues in
        // the backlog even if the sim thread has not reached accept yet.
        try sim.start();
        errdefer sim.stop();

        // Start the background Klippy bridge task so it connects to the
        // simulator and runs the handshake.
        try self.app.klippy_ctx.start();
        // The bridge reads `sim.socket_path`; stop it before the sim is freed.
        errdefer self.app.klippy_ctx.stop(self.io);

        // Wait for the simulator handshake to complete.
        try sim.waitReady();

        self.klippy_sim = sim;
    }

    /// Point the Klippy bridge at an ALREADY-RUNNING Klippy API socket (a real
    /// Klippy, not the simulator) and start the background bridge. Used by the
    /// gated real-Klippy integration test. `socket_path` must outlive the bridge
    /// (pass a string literal). No simulator is created, so `stop()` tears down
    /// only the bridge task.
    pub fn connectRealKlippy(self: *TestServer, socket_path: []const u8) !void {
        self.app.klippy_ctx.uds_path = socket_path;
        try self.app.klippy_ctx.start();
    }

    /// Stop the accept loop and free everything.
    pub fn stop(self: *TestServer) void {
        self.serve_fut.cancel(self.io);
        self.listener.deinit(self.io);
        // Signal the Klippy bridge background task to exit before tearing
        // down the simulator and app components it references.
        self.app.klippy_ctx.stop(self.io);
        if (self.klippy_sim) |sim| {
            sim.deinit();
            // deinit calls stop() which closes the socket; the bridge task
            // will see the disconnect and exit its read loop.
        }
        self.app.deinit(self.io);
        self.tmp.cleanup();
        self.threaded.deinit();
        // The allocator logs each leak with its stack trace; an error log
        // fails the test.
        if (self.app_gpa.deinit() == .leak) std.log.err("TestServer: the App leaked memory", .{});

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

    /// GET with extra request headers. Used to prove `X-Real-Ip` /
    /// `X-Forwarded-For` follow `[server] use_xheaders`.
    pub fn getWithHeaders(self: *TestServer, alloc: std.mem.Allocator, path: []const u8, headers: []const std.http.Header) ![]u8 {
        return self.requestHeaders(alloc, .GET, path, null, headers);
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

    /// Issue a bodyless DELETE and return the owned response body. Parameters
    /// go in the query string (e.g. "?namespace=ns&key=k").
    pub fn delete(self: *TestServer, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
        return self.request(alloc, .DELETE, path, null);
    }

    fn request(
        self: *TestServer,
        alloc: std.mem.Allocator,
        method: std.http.Method,
        path: []const u8,
        body: ?[]const u8,
    ) ![]u8 {
        return self.requestHeaders(alloc, method, path, body, &.{});
    }

    fn requestHeaders(
        self: *TestServer,
        alloc: std.mem.Allocator,
        method: std.http.Method,
        path: []const u8,
        body: ?[]const u8,
        headers: []const std.http.Header,
    ) ![]u8 {
        var client: std.http.Client = .{ .allocator = alloc, .io = self.io };
        defer client.deinit();

        var url_buf: [256]u8 = undefined;
        const full = try self.url(&url_buf, path);

        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();

        const Outcome = union(enum) {
            fetched: anyerror!void,
            expired: Io.Cancelable!void,
        };
        var outcomes: [2]Outcome = undefined;
        var select: Io.Select(Outcome) = .init(self.io, &outcomes);
        defer select.cancelDiscard();
        try select.concurrent(.fetched, fetchResponse, .{ &client, method, full, body, headers, &aw.writer });
        try select.concurrent(.expired, Io.sleep, .{ self.io, self.request_timeout, .awake });
        switch (try select.await()) {
            .expired => |result| {
                try result;
                return error.Timeout;
            },
            .fetched => |result| _ = try result,
        }
        // Cancellation joins the fetch before its client and writer are freed.
        select.cancelDiscard();
        return aw.toOwnedSlice();
    }

    fn fetchResponse(client: *std.http.Client, method: std.http.Method, full: []const u8, body: ?[]const u8, headers: []const std.http.Header, writer: *Io.Writer) !void {
        var req = try client.request(method, try std.Uri.parse(full), .{
            .extra_headers = headers,
            .redirect_behavior = if (body == null) @fromBackingInt(3) else .unhandled,
            .keep_alive = false,
            .headers = http_get.identity_headers,
        });
        defer req.deinit();
        req.accept_encoding = http_get.identity_only;
        if (body) |payload| {
            req.transfer_encoding = .{ .content_length = payload.len };
            var request_body = try req.sendBodyUnflushed(&.{});
            try request_body.writer.writeAll(payload);
            try request_body.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }
        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = try req.receiveHead(if (body == null) &redirect_buf else &.{});
        // Client.fetch unwraps a missing bodyErr when a socket read is cancelled.
        _ = response.reader(&.{}).streamRemaining(writer) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
            else => return err,
        };
    }
};

// --- tests ---------------------------------------------------------------

test "HTTP test requests time out on silent headers and incomplete bodies" {
    const ts = try TestServer.init(std.testing.allocator);
    defer ts.stop();
    ts.request_timeout = .fromMilliseconds(20);
    for ([_][]const u8{ "", "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nx" }) |prefix| {
        var listener = try ioz.Listener.bind(ts.io, "127.0.0.1", 0);
        defer listener.deinit(ts.io);
        ts.bound_port = listener.port();
        var peer = try ts.io.concurrent(struct {
            fn serve(io: Io, server: *ioz.Listener, response: []const u8) !void {
                const stream = try server.server.accept(io);
                defer stream.close(io);
                var buf: [256]u8 = undefined;
                var writer = stream.writer(io, &buf);
                try writer.interface.writeAll(response);
                try writer.interface.flush();
                try io.sleep(.fromMilliseconds(500), .awake);
            }
        }.serve, .{ ts.io, &listener, prefix });
        defer peer.cancel(ts.io) catch {};
        try std.testing.expectError(error.Timeout, ts.get(std.testing.allocator, "/stalled"));
    }
}

/// Connection writer that records every notification frame. Frames use
/// smp_allocator, not the testing allocator: the write runs on a server thread
/// while the test thread is inside std.http.Client.fetch, which holds the
/// testing allocator. Sharing it deadlocks on Zig 0.17.
const RecordWriter = struct {
    frames: std.ArrayList([]u8) = .empty,
    fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const dup = try std.heap.smp_allocator.dupe(u8, bytes);
        errdefer std.heap.smp_allocator.free(dup);
        try self.frames.append(std.heap.smp_allocator, dup);
    }
    fn deinit(self: *@This()) void {
        for (self.frames.items) |f| std.heap.smp_allocator.free(f);
        self.frames.deinit(std.heap.smp_allocator);
    }
};

test "use_xheaders false ignores X-Real-Ip and X-Forwarded-For on the live server" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "off.cfg", .data = "[server]\nuse_xheaders: false\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "on.cfg", .data = "[server]\nuse_xheaders: true\n" });
    const off_path = try tmp.dir.realPathFileAlloc(io, "off.cfg", alloc);
    defer alloc.free(off_path);
    const on_path = try tmp.dir.realPathFileAlloc(io, "on.cfg", alloc);
    defer alloc.free(on_path);

    const hdrs = [_]std.http.Header{
        .{ .name = "X-Forwarded-For", .value = "8.8.8.8" },
        .{ .name = "X-Real-Ip", .value = "8.8.8.8" },
    };

    const off = try TestServer.initWithConfig(alloc, off_path);
    defer off.stop();
    const off_body = try off.getWithHeaders(alloc, "/access/user", &hdrs);
    defer alloc.free(off_body);
    // Socket peer is 127.0.0.1. Headers must not rewrite it to 8.8.8.8.
    try std.testing.expect(std.mem.indexOf(u8, off_body, "\"_TRUSTED_USER_\"") != null);

    const on = try TestServer.initWithConfig(alloc, on_path);
    defer on.stop();
    const on_body = try on.getWithHeaders(alloc, "/access/user", &hdrs);
    defer alloc.free(on_body);
    // Same headers rewrite the client to 8.8.8.8, which is not trusted.
    try std.testing.expect(std.mem.indexOf(u8, on_body, "\"code\":401") != null);
}

test "a peer outside trusted_clients gets 401 on the live server" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "m.cfg", .data = "[authorization]\ntrusted_clients:\n 10.0.0.0/8\n" });
    const cfg_path = try tmp.dir.realPathFileAlloc(io, "m.cfg", alloc);
    defer alloc.free(cfg_path);

    const ts = try TestServer.initWithConfig(alloc, cfg_path);
    defer ts.stop();
    const body = try ts.get(alloc, "/server/config");
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"code\":401") != null);
    // auth_required=false routes stay reachable.
    const info = try ts.get(alloc, "/access/info");
    defer alloc.free(info);
    try std.testing.expect(std.mem.indexOf(u8, info, "\"trusted\":false") != null);
}

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

test "Klippy task cancellation joins a stalled handshake" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();
    // Relative to the cwd: an absolute checkout path can exceed `sun_path`.
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/stalled.sock", .{ std.testing.TmpDir.parent_dir_path, &ts.tmp.sub_path });
    var listener = try (try std.Io.net.UnixAddress.init(path)).listen(ts.io, .{});
    defer listener.deinit(ts.io);
    try ts.connectRealKlippy(path);
    const peer = try listener.accept(ts.io);
    defer peer.close(ts.io);
    var buf: [1024]u8 = undefined;
    var reader = peer.reader(ts.io, &buf);
    _ = try reader.interface.takeByte();
    const start = std.Io.Clock.Timestamp.now(ts.io, .awake);
    ts.app.klippy_ctx.stop(ts.io);
    try std.testing.expect(start.untilNow(ts.io).raw.toMilliseconds() < 1000);
    try std.testing.expect(ts.app.klippy_ctx.task == null);
    try std.testing.expect(ts.app.klippy_ctx.stream == null);
}

test "fuzz Klippy task start and stop owns each reconnect future" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            const ts = try TestServer.init(std.testing.allocator);
            defer ts.stop();
            const count = smith.valueRangeAtMostWithHash(u8, 1, 3, 0);
            var path_buf: [64]u8 = undefined;
            const missing = try std.fmt.bufPrint(&path_buf, "{s}/{s}/missing.sock", .{ std.testing.TmpDir.parent_dir_path, &ts.tmp.sub_path });
            for (0..count) |_| {
                try ts.connectRealKlippy(missing);
                ts.app.klippy_ctx.stop(ts.io);
                try std.testing.expect(ts.app.klippy_ctx.task == null);
                try std.testing.expect(ts.app.klippy_ctx.stream == null);
            }
        }
    }.run, .{});
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

test "database: POST item then GET it back — value round-trips" {
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

test "database: GET /server/database/list includes namespace after POST" {
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

test "database: DELETE removes item; subsequent GET returns error shape" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    // Insert.
    const post_body = try ts.postJson(alloc, "/server/database/item",
        \\{"namespace":"deltest","key":"dk","value":"hello"}
    );
    defer alloc.free(post_body);

    // DELETE via query string (Zig HTTP client does not support DELETE + body).
    const del_body = try ts.delete(alloc, "/server/database/item?namespace=deltest&key=dk");
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

test "REST and JSON-RPC preserve public missing-argument and namespace messages" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();
    var req_arena = std.heap.ArenaAllocator.init(alloc);
    defer req_arena.deinit();
    const a = req_arena.allocator();
    const cases = [_]struct { path: []const u8, method: []const u8, params: []const u8, message: []const u8, code: i64 }{
        .{ .path = "/server/files/thumbnails", .method = "server.files.thumbnails", .params = "{}", .message = "No data for argument: filename", .code = 400 },
        .{ .path = "/server/webcams/item", .method = "server.webcams.get_item", .params = "{}", .message = "No data for argument: name", .code = 400 },
        .{ .path = "/server/database/item?namespace=no_such_namespace", .method = "server.database.get_item", .params = "{\"namespace\":\"no_such_namespace\"}", .message = "Namespace no_such_namespace not found", .code = -32601 },
        .{ .path = "/server/database/item?namespace=no_such_namespace&key=key", .method = "server.database.get_item", .params = "{\"namespace\":\"no_such_namespace\",\"key\":\"key\"}", .message = "Key 'key' in namespace 'no_such_namespace' not found", .code = -32601 },
    };
    for (cases) |case| {
        const body = try ts.get(a, case.path);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        const err = parsed.value.object.get("error").?.object;
        try std.testing.expectEqualStrings(case.message, err.get("message").?.string);
        try std.testing.expect(err.get("traceback") == null);
        const request = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}", .{ case.method, case.params });
        const rpc_body = try ts.postJson(a, "/server/jsonrpc", request);
        const rpc = try std.json.parseFromSlice(std.json.Value, a, rpc_body, .{});
        const rpc_err = rpc.value.object.get("error").?.object;
        try std.testing.expectEqualStrings(case.message, rpc_err.get("message").?.string);
        try std.testing.expectEqual(case.code, rpc_err.get("code").?.integer);
    }
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

test "files: GET /server/files/roots lists gcodes/config/logs" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/server/files/roots");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
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
    const up_p = try std.json.parseFromSlice(std.json.Value, alloc, up, .{});
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
    const md_p = try std.json.parseFromSlice(std.json.Value, alloc, md, .{});
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

test "files: zip creates an archive and emits its create_file notification" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();
    const upload = try ts.uploadFile(alloc, "gcodes", null, "cube.gcode", "G1 X25\n");
    defer alloc.free(upload);
    var rec = RecordWriter{};
    defer rec.deinit();
    const cid = try ts.conns.add(ts.io, false);
    ts.conns.attachWriter(ts.io, cid, &rec, RecordWriter.write);
    defer ts.conns.remove(ts.io, cid);
    defer ts.conns.detachWriter(ts.io, cid);
    const body = try ts.postJson(alloc, "/server/files/zip", "{\"dest\":\"config/out.zip\",\"items\":[\"gcodes/cube.gcode\"]}");
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?;
    try std.testing.expectEqualStrings("zip_files", result.object.get("action").?.string);
    try std.testing.expect(result.object.get("destination").?.object.get("size").?.integer > 0);
    const download = try ts.get(alloc, "/server/files/config/out.zip");
    defer alloc.free(download);
    try std.testing.expect(download.len > 30);
    try std.testing.expectEqualSlices(u8, &std.zip.local_file_header_sig, download[0..4]);
    var saw = false;
    for (rec.frames.items) |frame| {
        if (std.mem.indexOf(u8, frame, "notify_filelist_changed") != null and
            std.mem.indexOf(u8, frame, "create_file") != null and
            std.mem.indexOf(u8, frame, "out.zip") != null) saw = true;
    }
    try std.testing.expect(saw);
}

test "files: metadata thumbnails persist and their advertised URLs serve image bytes" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();
    const encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jBqkAAAAASUVORK5CYII=";
    const gcode = try std.fmt.allocPrint(alloc, "; thumbnail begin 1x1 {d}\n; {s}\n; thumbnail end\nG28\n", .{ encoded.len, encoded });
    defer alloc.free(gcode);
    const upload = try ts.uploadFile(alloc, "gcodes", "sub", "model.gcode", gcode);
    defer alloc.free(upload);
    const metadata = try ts.get(alloc, "/server/files/metadata?filename=sub/model.gcode");
    defer alloc.free(metadata);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, metadata, .{});
    defer parsed.deinit();
    const thumb = parsed.value.object.get("result").?.object.get("thumbnails").?.array.items[0].object;
    try std.testing.expect(thumb.get("relative_path") != null);
    try std.testing.expectEqualStrings(".thumbs/model-1x1.png", thumb.get("relative_path").?.string);
    try std.testing.expect(thumb.get("data") == null);
    const path = try std.fmt.allocPrint(alloc, "/server/files/gcodes/sub/{s}", .{thumb.get("relative_path").?.string});
    defer alloc.free(path);
    const image = try ts.get(alloc, path);
    defer alloc.free(image);
    const expected = try alloc.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
    defer alloc.free(expected);
    try std.base64.standard.Decoder.decode(expected, encoded);
    try std.testing.expectEqualSlices(u8, expected, image);
    try std.testing.expectEqual(@as(i64, @intCast(expected.len)), thumb.get("size").?.integer);
    const thumbs = try ts.get(alloc, "/server/files/thumbnails?filename=sub/model.gcode");
    defer alloc.free(thumbs);
    const thumbnail_response = try std.json.parseFromSlice(std.json.Value, alloc, thumbs, .{});
    defer thumbnail_response.deinit();
    const listed = thumbnail_response.value.object.get("result").?.array.items[0].object;
    try std.testing.expectEqualStrings("sub/.thumbs/model-1x1.png", listed.get("thumbnail_path").?.string);
    try std.testing.expect(listed.get("relative_path") == null);
}

test "files: encoded names work through metadata download and delete" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();
    const name = "hello +%重.gcode";
    const upload = try ts.uploadFile(alloc, "gcodes", null, name, "G1\n");
    defer alloc.free(upload);
    const metadata = try ts.get(alloc, "/server/files/metadata?filename=hello+%2B%25%E9%87%8D.gcode");
    defer alloc.free(metadata);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, metadata, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(name, parsed.value.object.get("result").?.object.get("filename").?.string);
    const path = "/server/files/gcodes/hello%20+%25%E9%87%8D.gcode";
    const download = try ts.get(alloc, path);
    defer alloc.free(download);
    try std.testing.expectEqualStrings("G1\n", download);
    const deleted = try ts.delete(alloc, path);
    defer alloc.free(deleted);
    const deletion = try std.json.parseFromSlice(std.json.Value, alloc, deleted, .{});
    defer deletion.deinit();
    try std.testing.expectEqualStrings("delete_file", deletion.value.object.get("result").?.object.get("action").?.string);

    for ([_][]const u8{ "/server/files/metadata?filename=%FF", "/server/files/gcodes/%FF" }) |invalid| {
        const body = try ts.get(alloc, invalid);
        defer alloc.free(body);
        const failure = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        defer failure.deinit();
        try std.testing.expectEqual(@as(i64, 400), failure.value.object.get("error").?.object.get("code").?.integer);
    }
    const traversal = try ts.get(alloc, "/server/files/gcodes/%2E%2E/%2E%2E/etc/passwd");
    defer alloc.free(traversal);
    const denied = try std.json.parseFromSlice(std.json.Value, alloc, traversal, .{});
    defer denied.deinit();
    try std.testing.expectEqual(@as(i64, 403), denied.value.object.get("error").?.object.get("code").?.integer);
}

test "files: failed upload preserves an existing complete file" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();
    const upload = try ts.uploadFile(alloc, "gcodes", null, "existing.gcode", "complete\n");
    defer alloc.free(upload);
    const broken = "--broken\r\nContent-Disposition: form-data; name=\"file\"; filename=\"existing.gcode\"\r\n\r\npartial";
    const rejected = try ts.postJson(alloc, "/server/files/upload", broken);
    defer alloc.free(rejected);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, rejected, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 400), parsed.value.object.get("error").?.object.get("code").?.integer);
    const contents = try ts.get(alloc, "/server/files/gcodes/existing.gcode");
    defer alloc.free(contents);
    try std.testing.expectEqualStrings("complete\n", contents);
}

test "files: downloads and uploads reject an escaping directory link" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.writeFile(ts.io, .{ .sub_path = "outside.gcode", .data = "outside\n" });
    const target = try outside.dir.realPathFileAlloc(ts.io, ".", alloc);
    defer alloc.free(target);
    const root = ts.app.file_ctx.findRoot("gcodes").?;
    const link = try std.fs.path.join(alloc, &.{ root.path, "escape" });
    defer alloc.free(link);
    try std.Io.Dir.cwd().symLink(ts.io, target, link, .{});
    const download = try ts.get(alloc, "/server/files/gcodes/escape/outside.gcode");
    defer alloc.free(download);
    const result = try std.json.parseFromSlice(std.json.Value, alloc, download, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(i64, 403), result.value.object.get("error").?.object.get("code").?.integer);
    const upload = try ts.uploadFile(alloc, "gcodes", "escape", "outside.gcode", "replacement\n");
    defer alloc.free(upload);
    const failure = try std.json.parseFromSlice(std.json.Value, alloc, upload, .{});
    defer failure.deinit();
    try std.testing.expectEqual(@as(i64, 400), failure.value.object.get("error").?.object.get("code").?.integer);
    const contents = try outside.dir.readFileAlloc(ts.io, "outside.gcode", alloc, .limited(32));
    defer alloc.free(contents);
    try std.testing.expectEqualStrings("outside\n", contents);
}

test "files: get_directory shows uploaded file with disk_usage and root_info" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const up = try ts.uploadFile(alloc, "gcodes", null, "dir_test.gcode", "G1\n");
    defer alloc.free(up);

    const body = try ts.get(alloc, "/server/files/directory?path=gcodes");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
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
    const mk_p = try std.json.parseFromSlice(std.json.Value, alloc, mk, .{});
    defer mk_p.deinit();
    try std.testing.expectEqualStrings("create_dir", mk_p.value.object.get("result").?.object.get("action").?.string);

    // DELETE via query string (Zig client has no DELETE body).
    const rm = try ts.delete(alloc, "/server/files/directory?path=gcodes/intdir");
    defer alloc.free(rm);
    const rm_p = try std.json.parseFromSlice(std.json.Value, alloc, rm, .{});
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
    const mv_p = try std.json.parseFromSlice(std.json.Value, alloc, mv, .{});
    defer mv_p.deinit();
    try std.testing.expectEqualStrings("move_file", mv_p.value.object.get("result").?.object.get("action").?.string);

    // Copy.
    const cp = try ts.postJson(alloc, "/server/files/copy",
        \\{"source":"gcodes/mc2.gcode","dest":"gcodes/mc3.gcode"}
    );
    defer alloc.free(cp);
    const cp_p = try std.json.parseFromSlice(std.json.Value, alloc, cp, .{});
    defer cp_p.deinit();
    try std.testing.expectEqualStrings("create_file", cp_p.value.object.get("result").?.object.get("action").?.string);

    // Delete (DELETE /server/files/<root>/<path>).
    const del = try ts.delete(alloc, "/server/files/gcodes/mc3.gcode");
    defer alloc.free(del);
    const del_p = try std.json.parseFromSlice(std.json.Value, alloc, del, .{});
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

// ---------------------------------------------------------------------------
// Machine (machine.* + machine.proc_stats) integration tests — full socket path.
// ---------------------------------------------------------------------------

test "machine: GET /machine/system_info returns full system_info shape with real cpu/distro" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/machine/system_info");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    const si = p.value.object.get("result").?.object.get("system_info").?.object;

    // Required sub-objects present.
    for ([_][]const u8{ "cpu_info", "sd_info", "distribution", "virtualization", "network", "canbus", "python", "available_services", "service_state", "instance_ids", "provider" }) |k| {
        try std.testing.expect(si.get(k) != null);
    }
    // cpu_info has a real cpu_count (>=1) from /proc/cpuinfo.
    const cpu = si.get("cpu_info").?.object;
    try std.testing.expect(cpu.get("cpu_count").?.integer >= 1);
    try std.testing.expect(cpu.get("cpu_desc") != null);
    // distribution has a name from /etc/os-release on a real Linux host.
    const distro = si.get("distribution").?.object;
    try std.testing.expect(distro.get("name") != null);
    try std.testing.expect(distro.get("kernel_version") != null);
    // instance_ids.moonraker present.
    try std.testing.expectEqualStrings("moonraker", si.get("instance_ids").?.object.get("moonraker").?.string);
}

test "machine: GET /machine/proc_stats returns the proc_stats shape" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/machine/proc_stats");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    const r = p.value.object.get("result").?.object;
    for ([_][]const u8{ "moonraker_stats", "throttled_state", "cpu_temp", "network", "system_cpu_usage", "system_uptime", "system_memory", "websocket_connections" }) |k| {
        try std.testing.expect(r.get(k) != null);
    }
    try std.testing.expect(r.get("moonraker_stats").? == .array);
    // system_memory populated from /proc/meminfo on a real host.
    try std.testing.expect(r.get("system_memory").?.object.get("total") != null);
}

// AGENT: NEVER implement this test for real. These posts must keep
// returning "ok" without systemctl, reboot, shutdown, poweroff, or a
// guest/host halt. Running the real command reboots the machine that
// runs the tests. Do not "finish" the stub.
test "machine: POST /machine/reboot and /machine/shutdown return ok ack" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    for ([_][]const u8{ "/machine/reboot", "/machine/shutdown" }) |path| {
        const body = try ts.postJson(alloc, path, "{}");
        defer alloc.free(body);
        const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        defer p.deinit();
        try std.testing.expectEqualStrings("ok", p.value.object.get("result").?.string);
    }
}

test "machine: POST /machine/services/* ack for allowed, error for disallowed" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    // Allowed service (klipper) → ok.
    const ok = try ts.postJson(alloc, "/machine/services/restart",
        \\{"service":"klipper"}
    );
    defer alloc.free(ok);
    const okp = try std.json.parseFromSlice(std.json.Value, alloc, ok, .{});
    defer okp.deinit();
    try std.testing.expectEqualStrings("ok", okp.value.object.get("result").?.string);

    // Disallowed service (sshd) → error envelope.
    const bad = try ts.postJson(alloc, "/machine/services/stop",
        \\{"service":"sshd"}
    );
    defer alloc.free(bad);
    const badp = try std.json.parseFromSlice(std.json.Value, alloc, bad, .{});
    defer badp.deinit();
    try std.testing.expect(badp.value.object.get("error") != null);
}

test "machine: GET /machine/sudo/info shape" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/machine/sudo/info");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    const r = p.value.object.get("result").?.object;
    try std.testing.expect(r.get("sudo_access") != null); // null is allowed
    try std.testing.expect(r.get("linux_user") != null);
    try std.testing.expectEqual(false, r.get("sudo_requested").?.bool);
    try std.testing.expect(r.get("request_messages").? == .array);
}

test "machine: POST /machine/sudo/password acks success" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.postJson(alloc, "/machine/sudo/password",
        \\{"password":"hunter2"}
    );
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    const r = p.value.object.get("result").?.object;
    try std.testing.expectEqual(false, r.get("is_restarting").?.bool);
    try std.testing.expect(r.get("sudo_responses").?.array.items.len >= 1);
}

test "machine: GET /machine/peripherals/* return correct list shapes" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const usb = try ts.get(alloc, "/machine/peripherals/usb");
    defer alloc.free(usb);
    const up = try std.json.parseFromSlice(std.json.Value, alloc, usb, .{});
    defer up.deinit();
    try std.testing.expect(up.value.object.get("result").?.object.get("usb_devices").? == .array);

    const ser = try ts.get(alloc, "/machine/peripherals/serial");
    defer alloc.free(ser);
    const sp = try std.json.parseFromSlice(std.json.Value, alloc, ser, .{});
    defer sp.deinit();
    try std.testing.expect(sp.value.object.get("result").?.object.get("serial_devices").? == .array);

    const vid = try ts.get(alloc, "/machine/peripherals/video");
    defer alloc.free(vid);
    const vp = try std.json.parseFromSlice(std.json.Value, alloc, vid, .{});
    defer vp.deinit();
    const vres = vp.value.object.get("result").?.object;
    try std.testing.expect(vres.get("v4l2_devices").? == .array);
    try std.testing.expect(vres.get("libcamera_devices").? == .array);

    const can = try ts.get(alloc, "/machine/peripherals/canbus");
    defer alloc.free(can);
    const cp = try std.json.parseFromSlice(std.json.Value, alloc, can, .{});
    defer cp.deinit();
    try std.testing.expect(cp.value.object.get("result").?.object.get("can_uuids").? == .array);
}

// ---------------------------------------------------------------------------
// Update manager (machine.update.*) integration tests — full socket path.
// ---------------------------------------------------------------------------

test "update: GET /machine/update/status returns version_info with configured sources" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/machine/update/status");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    const r = p.value.object.get("result").?.object;

    // Top-level rate-limit + busy keys.
    for ([_][]const u8{ "github_rate_limit", "github_requests_remaining", "github_limit_reset_time", "version_info", "busy" }) |k| {
        try std.testing.expect(r.get(k) != null);
    }
    try std.testing.expectEqual(false, r.get("busy").?.bool);

    const vi = r.get("version_info").?.object;
    // Default sources present.
    try std.testing.expect(vi.get("moonraker") != null);
    try std.testing.expect(vi.get("klipper") != null);
    try std.testing.expect(vi.get("system") != null);
    // An unconfigured built-in updater has no deployment status.
    const moon = vi.get("moonraker").?.object;
    try std.testing.expectEqual(@as(usize, 0), moon.count());
    try std.testing.expectEqual(@as(usize, 0), vi.get("klipper").?.object.count());
    // system is a package type.
    const sys = vi.get("system").?.object;
    try std.testing.expectEqualStrings("system", sys.get("configured_type").?.string);
    try std.testing.expect(sys.get("package_list").? == .array);
}

test "update: POST /machine/update/refresh returns status and emits notify_update_refreshed" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    var rec = RecordWriter{};
    defer rec.deinit();
    const conns = ts.conns;
    const cid = try conns.add(ts.io, false);
    conns.attachWriter(ts.io, cid, &rec, RecordWriter.write);
    defer conns.remove(ts.io, cid);
    defer conns.detachWriter(ts.io, cid);

    const body = try ts.postJson(alloc, "/machine/update/refresh", "{}");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    try std.testing.expect(p.value.object.get("result").?.object.get("version_info") != null);

    var saw = false;
    for (rec.frames.items) |f| {
        if (std.mem.indexOf(u8, f, "notify_update_refreshed") != null and
            std.mem.indexOf(u8, f, "version_info") != null) saw = true;
    }
    try std.testing.expect(saw);
}

test "update: POST /machine/update/upgrade emits notify_update_response and acks ok" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    var rec = RecordWriter{};
    defer rec.deinit();
    const conns = ts.conns;
    const cid = try conns.add(ts.io, false);
    conns.attachWriter(ts.io, cid, &rec, RecordWriter.write);
    defer conns.remove(ts.io, cid);
    defer conns.detachWriter(ts.io, cid);

    const body = try ts.postJson(alloc, "/machine/update/moonraker", "{}");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    try std.testing.expectEqualStrings("ok", p.value.object.get("result").?.string);

    // notify_update_response with the CommandHelper shape must have been emitted.
    var saw = false;
    for (rec.frames.items) |f| {
        if (std.mem.indexOf(u8, f, "notify_update_response") != null and
            std.mem.indexOf(u8, f, "\"application\":\"moonraker\"") != null and
            std.mem.indexOf(u8, f, "\"proc_id\"") != null and
            std.mem.indexOf(u8, f, "\"complete\"") != null) saw = true;
    }
    try std.testing.expect(saw);
}

test "update: per-target endpoints and full update ack ok" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    for ([_][]const u8{
        "/machine/update/klipper",
        "/machine/update/system",
        "/machine/update/full",
        "/machine/update/client",
    }) |path| {
        const body = try ts.postJson(alloc, path, "{}");
        defer alloc.free(body);
        const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        defer p.deinit();
        try std.testing.expectEqualStrings("ok", p.value.object.get("result").?.string);
    }
}

test "update: recover (git source) and rollback ack ok; recover non-git errors" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const rec = try ts.postJson(alloc, "/machine/update/recover",
        \\{"name":"klipper","hard":true}
    );
    defer alloc.free(rec);
    const rp = try std.json.parseFromSlice(std.json.Value, alloc, rec, .{});
    defer rp.deinit();
    try std.testing.expectEqualStrings("ok", rp.value.object.get("result").?.string);

    const rb = try ts.postJson(alloc, "/machine/update/rollback",
        \\{"name":"moonraker"}
    );
    defer alloc.free(rb);
    const rbp = try std.json.parseFromSlice(std.json.Value, alloc, rb, .{});
    defer rbp.deinit();
    try std.testing.expectEqualStrings("ok", rbp.value.object.get("result").?.string);

    // Recover on the system (non-git) source → error envelope.
    const bad = try ts.postJson(alloc, "/machine/update/recover",
        \\{"name":"system"}
    );
    defer alloc.free(bad);
    try std.testing.expect(std.mem.indexOf(u8, bad, "\"error\"") != null);
}

// ---------------------------------------------------------------------------
// Power device (machine.device_power.*) integration tests
// ---------------------------------------------------------------------------

test "power: GET /machine/device_power/devices returns empty list (no configured devices)" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/machine/device_power/devices");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    const r = p.value.object.get("result").?;
    const arr = r.object.get("devices").?;
    try std.testing.expect(arr == .array);
    try std.testing.expectEqual(@as(usize, 0), arr.array.items.len);
}

test "power: GET /machine/device_power/device?device=unknown returns error" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/machine/device_power/device?device=unknown");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    try std.testing.expect(p.value.object.get("error") != null);
}

test "power: POST /machine/device_power/on with no args returns error" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.postJson(alloc, "/machine/device_power/on", "{}");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    // Empty params → InvalidParams error envelope.
    try std.testing.expect(p.value.object.get("error") != null);
}

test "power: batch status with unknown device returns device_not_found" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/machine/device_power/status?ghost=1");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    const r = p.value.object.get("result").?;
    try std.testing.expectEqualStrings("device_not_found", r.object.get("ghost").?.string);
}

test "power: POST device action=on/toggle toggles state and emits notify_power_changed" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    var rec = RecordWriter{};
    defer rec.deinit();
    const conns = ts.conns;
    const cid = try conns.add(ts.io, false);
    conns.attachWriter(ts.io, cid, &rec, RecordWriter.write);
    defer conns.remove(ts.io, cid);
    defer conns.detachWriter(ts.io, cid);

    // Add a device via the power_ctx directly (no config loading in tests).
    try ts.app.power_ctx.addDevice(.{ .name = "test_psu", .type_str = "gpio", .state = "off" });

    // POST action=on → state becomes on.
    const on_body = try ts.postJson(alloc, "/machine/device_power/device",
        \\{"device":"test_psu","action":"on"}
    );
    defer alloc.free(on_body);
    const on_p = try std.json.parseFromSlice(std.json.Value, alloc, on_body, .{});
    defer on_p.deinit();
    const r = on_p.value.object.get("result").?;
    try std.testing.expectEqualStrings("on", r.object.get("test_psu").?.string);

    // notify_power_changed must have been emitted with the device info.
    var saw = false;
    for (rec.frames.items) |f| {
        if (std.mem.indexOf(u8, f, "notify_power_changed") != null and
            std.mem.indexOf(u8, f, "test_psu") != null)
        {
            saw = true;
        }
    }
    try std.testing.expect(saw);

    // POST action=toggle → state becomes off.
    const tog_body = try ts.postJson(alloc, "/machine/device_power/device",
        \\{"device":"test_psu","action":"toggle"}
    );
    defer alloc.free(tog_body);
    const tog_p = try std.json.parseFromSlice(std.json.Value, alloc, tog_body, .{});
    defer tog_p.deinit();
    const tr = tog_p.value.object.get("result").?;
    try std.testing.expectEqualStrings("off", tr.object.get("test_psu").?.string);
}

// ---------------------------------------------------------------------------
// WLED (machine.wled.*) integration tests
// ---------------------------------------------------------------------------

test "wled: GET /machine/wled/strips returns empty strips map (no configured strips)" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/machine/wled/strips");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    const r = p.value.object.get("result").?;
    const strips = r.object.get("strips").?;
    try std.testing.expect(strips == .object);
    try std.testing.expectEqual(@as(usize, 0), strips.object.count());
}

test "wled: GET /machine/wled/strip?strip=unknown returns error" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/machine/wled/strip?strip=ghost");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    try std.testing.expect(p.value.object.get("error") != null);
}

test "wled: batch status with unknown strip returns strip_not_found" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/machine/wled/status?ghost=1");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    const r = p.value.object.get("result").?;
    const ghost = r.object.get("ghost").?.object;
    try std.testing.expectEqualStrings("strip_not_found", ghost.get("error").?.string);
}

test "wled: on/off/toggle batch and single strip endpoints work correctly" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    // Add a strip via the wled_ctx.
    try ts.app.wled_ctx.addStrip(.{ .name = "test_strip", .chain_count = 30 });

    // GET strip → initial state "off".
    const get_body = try ts.get(alloc, "/machine/wled/strip?strip=test_strip");
    defer alloc.free(get_body);
    const gp = try std.json.parseFromSlice(std.json.Value, alloc, get_body, .{});
    defer gp.deinit();
    try std.testing.expectEqualStrings("off", gp.value.object.get("result").?.object.get("test_strip").?.object.get("status").?.string);

    // POST action=on → status becomes "on".
    const on_body = try ts.postJson(alloc, "/machine/wled/strip",
        \\{"strip":"test_strip","action":"on"}
    );
    defer alloc.free(on_body);
    const op = try std.json.parseFromSlice(std.json.Value, alloc, on_body, .{});
    defer op.deinit();
    try std.testing.expectEqualStrings("on", op.value.object.get("result").?.object.get("test_strip").?.object.get("status").?.string);

    // POST /machine/wled/off (batch) → turns off.
    const off_body = try ts.postJson(alloc, "/machine/wled/off",
        \\{"test_strip":null}
    );
    defer alloc.free(off_body);
    const offp = try std.json.parseFromSlice(std.json.Value, alloc, off_body, .{});
    defer offp.deinit();
    try std.testing.expectEqualStrings("off", offp.value.object.get("result").?.object.get("test_strip").?.object.get("status").?.string);

    // POST /machine/wled/toggle → should flip to on.
    const tog_body = try ts.postJson(alloc, "/machine/wled/toggle",
        \\{"test_strip":null}
    );
    defer alloc.free(tog_body);
    const tp = try std.json.parseFromSlice(std.json.Value, alloc, tog_body, .{});
    defer tp.deinit();
    try std.testing.expectEqualStrings("on", tp.value.object.get("result").?.object.get("test_strip").?.object.get("status").?.string);
}

// ---------------------------------------------------------------------------
// TD-1 (machine.td1.*) integration tests
// ---------------------------------------------------------------------------

test "td1: GET /machine/td1/data returns status=ok and empty devices (no hardware)" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/machine/td1/data");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    const r = p.value.object.get("result").?;
    try std.testing.expectEqualStrings("ok", r.object.get("status").?.string);
    try std.testing.expect(r.object.get("devices").? == .object);
    try std.testing.expectEqual(@as(usize, 0), r.object.get("devices").?.object.count());
}

test "td1: POST /machine/td1/reboot with serial returns serial_error (no hardware)" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.postJson(alloc, "/machine/td1/reboot",
        \\{"serial":"SN-0001"}
    );
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    const r = p.value.object.get("result").?;
    try std.testing.expectEqualStrings("serial_error", r.object.get("status").?.string);
}

test "td1: POST /machine/td1/reboot without serial returns error envelope" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.postJson(alloc, "/machine/td1/reboot", "{}");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    try std.testing.expect(p.value.object.get("error") != null);
}

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Printer (printer.*) integration tests — full socket path. With no Klippy
// connection every printer endpoint returns Moonraker's 503 disconnected error.
// ---------------------------------------------------------------------------

test "printer: every print/restart endpoint returns Klippy Host not connected" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const paths = [_][]const u8{
        "/printer/print/start",
        "/printer/print/pause",
        "/printer/print/resume",
        "/printer/print/cancel",
        "/printer/restart",
        "/printer/firmware_restart",
    };
    for (paths) |path| {
        const body = try ts.postJson(alloc, path, "{}");
        defer alloc.free(body);
        const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        defer p.deinit();
        const err = p.value.object.get("error").?.object;
        try std.testing.expectEqual(@as(i64, 503), err.get("code").?.integer);
        try std.testing.expectEqualStrings("Klippy Host not connected", err.get("message").?.string);
    }
}

test "printer: JSON-RPC printer.print.start returns code 503 with exact message" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.postJson(alloc, "/server/jsonrpc",
        \\{"jsonrpc":"2.0","method":"printer.print.start","params":{"filename":"a.gcode"},"id":9}
    );
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    const err = p.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, 503), err.get("code").?.integer);
    try std.testing.expectEqualStrings("Klippy Host not connected", err.get("message").?.string);
    try std.testing.expectEqual(@as(i64, 9), p.value.object.get("id").?.integer);
}

// ---------------------------------------------------------------------------
// Printer (printer.*) tests with Klippy simulator connected.
// ---------------------------------------------------------------------------

/// Poll until the Klippy bridge reports connected, giving the background
/// task time to complete the handshake. Returns true if connected within
/// ~2 seconds, false on timeout.
fn waitKlippyConnected(ts: *TestServer) bool {
    var attempts: u16 = 0;
    while (attempts < 200) : (attempts += 1) {
        if (ts.app.klippy_ctx.isConnected()) return true;
        std.Io.sleep(ts.io, .{ .nanoseconds = 10_000_000 }, .real) catch {};
    }
    return false;
}

test "printer: with Klippy sim, server.info reports klippy_connected" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    try ts.startKlippyBridge();
    try std.testing.expect(waitKlippyConnected(ts));

    const body = try ts.get(alloc, "/server/info");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    const result = p.value.object.get("result").?.object;

    // Klippy state should be reflected as connected/ready.
    try std.testing.expectEqualStrings("ready", result.get("klippy_state").?.string);
    try std.testing.expect(result.get("klippy_connected").?.bool == true);
}

test "octoprint: with Klippy sim, /api/printer/command runs gcode through Klippy" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();
    try ts.startKlippyBridge();
    try std.testing.expect(waitKlippyConnected(ts));

    var rec = RecordWriter{};
    defer rec.deinit();
    const cid = try ts.conns.add(ts.io, false);
    ts.conns.attachWriter(ts.io, cid, &rec, RecordWriter.write);
    defer ts.conns.remove(ts.io, cid);
    defer ts.conns.detachWriter(ts.io, cid);

    const body = try ts.postJson(alloc, "/api/printer/command",
        \\{"commands":["G28",5,"M114"]}
    );
    defer alloc.free(body);
    try std.testing.expectEqualStrings("{}", body);
    // The sim answers each gcode/script with a `process_gcode_response`,
    // fanned out as notify_gcode_response; without forwarding none arrives.
    // Count under Core, which serializes notification fan-out.
    const count = struct {
        fn f(r: *const RecordWriter) usize {
            var n: usize = 0;
            for (r.frames.items) |frame| {
                if (std.mem.indexOf(u8, frame, "notify_gcode_response") != null) n += 1;
            }
            return n;
        }
    }.f;
    var responses: usize = 0;
    var attempts: u16 = 0;
    while (attempts < 200 and responses < 2) : (attempts += 1) {
        responses = ts.app.core.run(ts.io, count, .{&rec});
        if (responses < 2) std.Io.sleep(ts.io, .{ .nanoseconds = 10_000_000 }, .real) catch {};
    }
    try std.testing.expectEqual(@as(usize, 2), responses);
}

test "printer: with Klippy sim, print.start returns success" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    try ts.startKlippyBridge();
    try std.testing.expect(waitKlippyConnected(ts));

    const body = try ts.postJson(alloc, "/printer/print/start",
        \\{"filename":"test.gcode"}
    );
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    // No error — the request was forwarded to Klippy successfully.
    try std.testing.expect(p.value.object.get("error") == null);
    try std.testing.expectEqualStrings("ok", p.value.object.get("result").?.string);
}

test "printer: with Klippy sim, JSON-RPC printer.print.start succeeds" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    try ts.startKlippyBridge();
    try std.testing.expect(waitKlippyConnected(ts));

    const body = try ts.postJson(alloc, "/server/jsonrpc",
        \\{"jsonrpc":"2.0","method":"printer.print.start","params":{"filename":"b.gcode"},"id":1}
    );
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    try std.testing.expect(p.value.object.get("error") == null);
    try std.testing.expectEqual(@as(i64, 1), p.value.object.get("id").?.integer);
}

test "printer: with Klippy sim, pause/resume/cancel all succeed" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    try ts.startKlippyBridge();
    try std.testing.expect(waitKlippyConnected(ts));

    const paths = [_][]const u8{
        "/printer/print/pause",
        "/printer/print/resume",
        "/printer/print/cancel",
    };
    for (paths) |path| {
        const body = try ts.postJson(alloc, path, "{}");
        defer alloc.free(body);
        const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        defer p.deinit();
        try std.testing.expect(p.value.object.get("error") == null);
        try std.testing.expectEqualStrings("ok", p.value.object.get("result").?.string);
    }
}

test "printer: with Klippy sim, restart and firmware_restart succeed" {
    const alloc = std.testing.allocator;
    // Use separate server instances: restart causes KlippySim disconnect.
    inline for ([_][]const u8{ "/printer/restart", "/printer/firmware_restart" }) |path| {
        const ts = try TestServer.init(alloc);
        defer ts.stop();

        try ts.startKlippyBridge();
        try std.testing.expect(waitKlippyConnected(ts));

        const body = try ts.postJson(alloc, path, "{}");
        defer alloc.free(body);
        const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        defer p.deinit();
        try std.testing.expect(p.value.object.get("error") == null);
        try std.testing.expectEqualStrings("ok", p.value.object.get("result").?.string);
    }
}

test "printer: with Klippy sim, emergency_stop succeeds" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    try ts.startKlippyBridge();
    try std.testing.expect(waitKlippyConnected(ts));

    const body = try ts.postJson(alloc, "/printer/emergency_stop", "{}");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    try std.testing.expect(p.value.object.get("error") == null);
    try std.testing.expectEqualStrings("ok", p.value.object.get("result").?.string);
}

// ---------------------------------------------------------------------------
// Real Klippy integration test (gated). Runs only when a real Klippy API
// socket is present at /tmp/klippy_uds. Boot one with:
//   .testenv/run-klippy.sh   (native linux host MCU + klippy via uv)
// Skipped automatically in CI / normal `zig build test` when absent.
// ---------------------------------------------------------------------------

test "printer: real Klippy proxies info/objects.list/objects.query" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    // Gate: only run when a real Klippy API socket is present.
    std.Io.Dir.cwd().access(ts.io, "/tmp/klippy_uds", .{}) catch return error.SkipZigTest;

    try ts.connectRealKlippy("/tmp/klippy_uds");
    try std.testing.expect(waitKlippyConnected(ts));

    // server.info reflects the real Klippy "ready" state.
    {
        const body = try ts.get(alloc, "/server/info");
        defer alloc.free(body);
        const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        defer p.deinit();
        const result = p.value.object.get("result").?.object;
        try std.testing.expectEqualStrings("ready", result.get("klippy_state").?.string);
        try std.testing.expect(result.get("klippy_connected").?.bool == true);
    }

    // printer.info proxies to Klippy and returns its real state.
    {
        const body = try ts.postJson(alloc, "/server/jsonrpc",
            \\{"jsonrpc":"2.0","method":"printer.info","id":1}
        );
        defer alloc.free(body);
        const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        defer p.deinit();
        try std.testing.expect(p.value.object.get("error") == null);
        const result = p.value.object.get("result").?.object;
        try std.testing.expectEqualStrings("ready", result.get("state").?.string);
    }

    // printer.objects.list returns Klippy's live object list (must include
    // "toolhead", always present once Klippy is ready).
    {
        const body = try ts.postJson(alloc, "/server/jsonrpc",
            \\{"jsonrpc":"2.0","method":"printer.objects.list","id":2}
        );
        defer alloc.free(body);
        const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        defer p.deinit();
        try std.testing.expect(p.value.object.get("error") == null);
        const objects = p.value.object.get("result").?.object.get("objects").?.array;
        var found_toolhead = false;
        for (objects.items) |o| {
            if (o == .string and std.mem.eql(u8, o.string, "toolhead")) found_toolhead = true;
        }
        try std.testing.expect(found_toolhead);
    }

    // printer.objects.query with a non-trivial params payload (exercises the
    // dynamic request-frame path that previously truncated at 256 bytes).
    {
        const body = try ts.postJson(alloc, "/server/jsonrpc",
            \\{"jsonrpc":"2.0","method":"printer.objects.query","params":{"objects":{"webhooks":null,"toolhead":null,"gcode_move":null}},"id":3}
        );
        defer alloc.free(body);
        const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        defer p.deinit();
        try std.testing.expect(p.value.object.get("error") == null);
        const status = p.value.object.get("result").?.object.get("status").?.object;
        try std.testing.expectEqualStrings("ready", status.get("webhooks").?.object.get("state").?.string);
    }
}

// ---------------------------------------------------------------------------
// /server/redirect (CORS redirect router route) integration tests.
// ---------------------------------------------------------------------------

test "redirect: no url argument returns 400 'No url argument provided'" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/server/redirect");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    const err = p.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, 400), err.get("code").?.integer);
    try std.testing.expectEqualStrings("No url argument provided", err.get("message").?.string);
}

test "redirect: url present is rejected (no CORS configured)" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/server/redirect?url=http://example.com");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    const err = p.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, 400), err.get("code").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, err.get("message").?.string, "Unauthorized URL redirect") != null);
}

// ---------------------------------------------------------------------------
// OctoPrint compatibility (/api/*) integration tests.
// ---------------------------------------------------------------------------

test "octoprint: GET /api/version returns server/api/text (unwrapped)" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/api/version");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    // wrap_result=false → the object is the body directly (no "result" key).
    try std.testing.expect(p.value.object.get("result") == null);
    try std.testing.expectEqualStrings("1.5.0", p.value.object.get("server").?.string);
    try std.testing.expectEqualStrings("0.1", p.value.object.get("api").?.string);
}

test "octoprint: GET /api/printer reports Offline state flags" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/api/printer");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    const state = p.value.object.get("state").?.object;
    try std.testing.expectEqualStrings("Offline", state.get("text").?.string);
    try std.testing.expectEqual(false, state.get("flags").?.object.get("operational").?.bool);
    try std.testing.expectEqual(true, state.get("flags").?.object.get("closedOrError").?.bool);
}

test "octoprint: POST /api/login returns the _api user" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.postJson(alloc, "/api/login", "{}");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    try std.testing.expectEqualStrings("_api", p.value.object.get("name").?.string);
}

// ---------------------------------------------------------------------------
// Zeroconf SSDP integration test.
// ---------------------------------------------------------------------------

test "zeroconf: GET /server/zeroconf/ssdp returns 404 (device not registered)" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    const body = try ts.get(alloc, "/server/zeroconf/ssdp");
    defer alloc.free(body);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer p.deinit();
    try std.testing.expect(p.value.object.get("error") != null);
    try std.testing.expectEqual(@as(i64, 404), p.value.object.get("error").?.object.get("code").?.integer);
}

test "files: notify_filelist_changed emitted on upload with correct payload" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    var rec = RecordWriter{};
    defer rec.deinit();
    const conns = ts.conns;
    const cid = try conns.add(ts.io, false);
    conns.attachWriter(ts.io, cid, &rec, RecordWriter.write);
    defer conns.remove(ts.io, cid);
    defer conns.detachWriter(ts.io, cid);

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

test "files: upload refuses to overwrite the gcode of an active print" {
    const alloc = std.testing.allocator;
    var req_arena = std.heap.ArenaAllocator.init(alloc);
    defer req_arena.deinit();
    const ts = try TestServer.init(alloc);
    defer ts.stop();
    const first = try ts.uploadFile(alloc, "gcodes", null, "busy.gcode", "G28\n");
    defer alloc.free(first);
    var ps: std.json.ObjectMap = .empty;
    try ps.put(req_arena.allocator(), "state", .{ .string = "printing" });
    try ps.put(req_arena.allocator(), "filename", .{ .string = "busy.gcode" });
    ts.app.info.state_mutex.lockUncancelable(ts.io);
    ts.app.info.klippy_state = "ready";
    ts.app.info.state_mutex.unlock(ts.io);
    const JobStateCtx = @import("../components/job_state.zig").JobStateCtx;
    ts.app.core.run(ts.io, JobStateCtx.statusUpdate, .{ ts.app.job_state_ctx, std.json.Value{ .object = ps } });
    const refused = try ts.uploadFile(alloc, "gcodes", null, "busy.gcode", "G1 X1\n");
    defer alloc.free(refused);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, refused, .{});
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, 403), err.get("code").?.integer);
    try std.testing.expectEqualStrings("File currently in use", err.get("message").?.string);
    const contents = try ts.get(alloc, "/server/files/gcodes/busy.gcode");
    defer alloc.free(contents);
    try std.testing.expectEqualStrings("G28\n", contents);
    ts.app.info.state_mutex.lockUncancelable(ts.io);
    ts.app.info.klippy_state = "shutdown";
    ts.app.info.state_mutex.unlock(ts.io);
    const unlocked = try ts.uploadFile(alloc, "gcodes", null, "busy.gcode", "G1 X1\n");
    defer alloc.free(unlocked);
    const replaced = try ts.get(alloc, "/server/files/gcodes/busy.gcode");
    defer alloc.free(replaced);
    try std.testing.expectEqualStrings("G1 X1\n", replaced);
}

test "Klipper remote methods run on the worker, not the Klippy reader" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();
    const KlippyCtx = @import("../components/klippy_connection.zig").KlippyCtx;
    const SpoolmanCtx = @import("../components/spoolman.zig").SpoolmanCtx;

    const frame = try std.json.parseFromSlice(std.json.Value, alloc, "{\"method\":\"spoolman_set_active_spool\",\"params\":{\"spool_id\":7}}", .{});
    defer frame.deinit();
    // The Klippy reader dispatches method frames under Core.
    try ts.app.core.run(ts.io, KlippyCtx.dispatchRemoteMethod, .{ ts.app.klippy_ctx, ts.io, "spoolman_set_active_spool", frame.value });

    var attempts: u16 = 0;
    while (ts.app.core.run(ts.io, SpoolmanCtx.getSpoolId, .{ts.app.spoolman_ctx}) != 7) : (attempts += 1) {
        if (attempts >= 500) return error.RemoteMethodNotRun;
        std.Io.sleep(ts.io, .{ .nanoseconds = 10_000_000 }, .real) catch {};
    }
}

test "octoprint: /api/files/moonraker/<path> reaches _select_file" {
    const alloc = std.testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    // A plain select is Moonraker's None result: 204 with no body.
    const selected = try ts.postJson(alloc, "/api/files/moonraker/gcodes/a.gcode", "{\"command\":\"select\"}");
    defer alloc.free(selected);
    try std.testing.expectEqualStrings("", selected);

    const missing = try ts.postJson(alloc, "/api/files/moonraker/gcodes/a.gcode", "{\"command\":\"select\",\"print\":true}");
    defer alloc.free(missing);
    const err = try std.json.parseFromSlice(std.json.Value, alloc, missing, .{});
    defer err.deinit();
    const e = err.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, 400), e.get("code").?.integer);
    try std.testing.expectEqualStrings("File does not exist", e.get("message").?.string);

    // Klippy is not connected, so the print cannot start: 409 Conflict.
    const root = ts.app.file_ctx.findRoot("gcodes").?;
    var dir = try std.Io.Dir.cwd().openDir(ts.io, root.path, .{});
    defer dir.close(ts.io);
    try dir.writeFile(ts.io, .{ .sub_path = "a.gcode", .data = "G28\n" });
    const busy = try ts.postJson(alloc, "/api/files/moonraker/gcodes/a.gcode", "{\"command\":\"select\",\"print\":true}");
    defer alloc.free(busy);
    const conflict = try std.json.parseFromSlice(std.json.Value, alloc, busy, .{});
    defer conflict.deinit();
    try std.testing.expectEqual(@as(i64, 409), conflict.value.object.get("error").?.object.get("code").?.integer);
}
