const std = @import("std");
pub const arena = @import("util/arena.zig");
pub const clock = @import("util/clock.zig");

pub const datastore = @import("store/datastore.zig");
pub const file_store = @import("store/file_store.zig");
pub const sqlite_c = @import("store/sqlite_c.zig");
pub const sqlite_store = @import("store/sqlite_store.zig");
pub const config_backend = @import("config/backend.zig");
pub const config = @import("config/confighelper.zig");
pub const io = @import("io.zig");
pub const core = @import("server/core.zig");
pub const jsonrpc = @import("jsonrpc.zig");
pub const json_value = @import("json/value.zig");
pub const registry = @import("server/registry.zig");
pub const methods = @import("core/methods.zig");
pub const http_transport = @import("http_transport.zig");
pub const connections = @import("server/connections.zig");
pub const notify = @import("server/notify.zig");
pub const ws_transport = @import("transport/ws.zig");
pub const database_component = @import("components/database.zig");
pub const klippy_connection = @import("components/klippy_connection.zig");
pub const ws_client = @import("components/ws_client.zig");
pub const sensor_template = @import("components/sensor_template.zig");
pub const testutil_server = @import("testutil/server.zig");
pub const testutil_ws_client = @import("testutil/ws_client.zig");
pub const testutil_klippy_sim = @import("testutil/klippy_sim.zig");
pub const app = @import("app.zig");
pub const oracle_normalize = @import("oracle/normalize.zig");
pub const oracle_replay = @import("oracle/replay.zig");

pub fn main(init: std.process.Init) !void {
    // `init.gpa` is std's DebugAllocator — it captures a dwarf stack trace on
    // every allocation for leak/UAF detection. That tracing dominates the hot
    // path (allocation-heavy Klippy-proxy requests) and is pointless in a
    // long-running release daemon, so use the lock-sharded `smp_allocator` in
    // release and keep the checked allocator only for Debug builds.
    const alloc = if (@import("builtin").mode == .Debug) init.gpa else std.heap.smp_allocator;
    const aio = init.io;

    // Parse CLI args.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var config_path: ?[]const u8 = null;
    var dump_api = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dump-api")) {
            dump_api = true;
        } else if ((std.mem.eql(u8, args[i], "-c") or std.mem.eql(u8, args[i], "--config")) and i + 1 < args.len) {
            i += 1;
            config_path = args[i];
        }
    }

    if (dump_api) return dumpApi(alloc, aio);

    // Read host/port from config when available, with defaults matching Moonraker.
    const host, const bind_port = try resolveBindAddr(alloc, init.arena.allocator(), aio, config_path);
    std.debug.print("phobos: bind host='{s}' port={d}\n", .{ host, bind_port });

    // Select the DataStore backend from `[database] backend` (sqlite | file).
    const db_backend = resolveDbBackend(alloc, aio, config_path);
    const db_path = resolveDbPath(alloc, init.arena.allocator(), aio, config_path);
    std.debug.print("phobos: datastore backend = {s}{s}\n", .{ @tagName(db_backend), if (db_path) |p| p else "" });

    var server_app = try app.App.initWithStore(alloc, db_backend, aio, db_path);
    defer server_app.deinit(aio);

    if (config_path) |path| {
        server_app.setConfig(aio, path);
    }

    var srv = server_app.httpServer(aio);

    // Start the background Klippy Unix-socket bridge. Only the real daemon
    // path calls start(); tests go through App.init/httpServer which only
    // calls setIo() so no background task is spawned during testing.
    server_app.klippy_ctx.start();

    var listener = try io.Listener.bind(aio, host, bind_port);
    defer listener.deinit(aio);

    std.debug.print("phobos listening on http://{s}:{d}\n", .{ host, bind_port });
    try listener.serveWith(aio, @ptrCast(&srv), http_transport.connHandler);
}

/// Read `[database] backend` (sqlite | file) from the config; defaults to sqlite.
pub fn resolveDbBackend(gpa: std.mem.Allocator, aio: std.Io, config_path: ?[]const u8) app.StoreBackend {
    const path = config_path orelse return .sqlite;
    var cfg = config.ConfigParser.init(gpa);
    defer cfg.deinit();
    cfg.parseFile(aio, path) catch return .sqlite;
    const v = cfg.get("database", "backend") orelse return .sqlite;
    if (std.mem.eql(u8, v, "file")) return .file;
    return .sqlite;
}

/// Read `[database] path` — an explicit DataStore path (a SQLite file, or a
/// directory for the file backend). Null = use the default ephemeral location.
/// Lets phobos open an existing Moonraker `moonraker-sql.db`.
pub fn resolveDbPath(gpa: std.mem.Allocator, arena_alloc: std.mem.Allocator, aio: std.Io, config_path: ?[]const u8) ?[]const u8 {
    const path = config_path orelse return null;
    var cfg = config.ConfigParser.init(gpa);
    defer cfg.deinit();
    cfg.parseFile(aio, path) catch return null;
    const v = cfg.get("database", "path") orelse return null;
    return arena_alloc.dupe(u8, v) catch null;
}

/// Resolve the bind address from a config file (or defaults).
/// Defaults: host = "127.0.0.1", port = 7125 (Moonraker's documented default).
pub fn resolveBindAddr(
    gpa: std.mem.Allocator,
    arena_alloc: std.mem.Allocator,
    aio: std.Io,
    config_path: ?[]const u8,
) !struct { []const u8, u16 } {
    const default_host = "127.0.0.1";
    const default_port: u16 = 7125;

    const path = config_path orelse return .{ default_host, default_port };

    var cfg = config.ConfigParser.init(gpa);
    defer cfg.deinit();
    cfg.parseFile(aio, path) catch |err| {
        std.debug.print("phobos: warning: could not parse config '{s}': {} — using defaults\n", .{ path, err });
        return .{ default_host, default_port };
    };

    const host, const port = try extractBindAddr(&cfg, default_host, default_port);
    // Duplicate into arena_alloc: cfg.deinit() frees the original.
    return .{ try arena_alloc.dupe(u8, host), port };
}

/// Extract host/port from an already-parsed ConfigParser.
/// Testable without filesystem access (pair with parseString).
pub fn extractBindAddr(cfg: *const config.ConfigParser, default_host: []const u8, default_port: u16) !struct { []const u8, u16 } {
    const host = cfg.get("server", "host") orelse default_host;
    const port: u16 = if (cfg.hasOption("server", "port"))
        @intCast(cfg.getInt("server", "port") catch |err| {
            std.debug.print("phobos: warning: invalid [server] port in config: {} — using default\n", .{err});
            return .{ host, default_port };
        })
    else
        default_port;

    return .{ host, port };
}

/// Build an App, enumerate its registrations, and print a deterministic JSON
/// document to stdout describing phobos's current API surface.
///
/// Shape:
///   { "endpoints": [...], "jsonrpc_methods": [...], "notifications": [...],
///     "router_routes": [...] }
///
/// All arrays are sorted. Does NOT bind any sockets.
pub fn dumpApi(alloc: std.mem.Allocator, aio: std.Io) !void {
    const out = try buildDumpApiJson(alloc, aio);
    defer alloc.free(out);

    const stdout = std.Io.File.stdout();
    var wbuf: [4096]u8 = undefined;
    var sw = stdout.writer(aio, &wbuf);
    try sw.interface.writeAll(out);
    try sw.interface.writeByte('\n');
    try sw.interface.flush();
}

/// Build the --dump-api JSON without touching stdout (testable).
pub fn buildDumpApiJson(alloc: std.mem.Allocator, aio: std.Io) ![]u8 {
    var server_app = try app.App.init(alloc);
    defer server_app.deinit(aio);

    // Collect endpoints from the registry, grouped by path.
    var path_map = std.StringHashMap(EndpointEntry).init(alloc);
    defer {
        var it = path_map.valueIterator();
        while (it.next()) |e| e.methods_list.deinit(alloc);
        path_map.deinit();
    }
    for (server_app.reg.routes.items) |*route| {
        const gop = try path_map.getOrPut(route.path);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .path = route.path,
                .wrap_result = route.wrap_result,
                .auth_required = route.auth_required,
                .methods_list = .empty,
            };
        }
        try gop.value_ptr.methods_list.append(alloc, route.method);
    }

    // Sorted endpoint paths.
    var ep_paths: std.ArrayList([]const u8) = .empty;
    defer ep_paths.deinit(alloc);
    var ep_it = path_map.keyIterator();
    while (ep_it.next()) |k| try ep_paths.append(alloc, k.*);
    std.mem.sort([]const u8, ep_paths.items, {}, strLt);

    // Sorted JSON-RPC method names from dispatcher.
    var jrpc_names: std.ArrayList([]const u8) = .empty;
    defer jrpc_names.deinit(alloc);
    var dit = server_app.dispatcher.methods.keyIterator();
    while (dit.next()) |k| try jrpc_names.append(alloc, k.*);
    std.mem.sort([]const u8, jrpc_names.items, {}, strLt);

    // Sorted notification names.
    var notif_names: std.ArrayList([]const u8) = .empty;
    defer notif_names.deinit(alloc);
    for (notify.all_names) |n| try notif_names.append(alloc, n);
    std.mem.sort([]const u8, notif_names.items, {}, strLt);

    // Transport routes phobos serves (sorted). These are the non-register_endpoint
    // Tornado routes (api/api_surface.json router_routes): the JSON-RPC bridge,
    // the client websocket, the Klippy bridge socket, and the CORS redirect.
    const router_routes = [_][]const u8{ "/klippysocket", "/server/jsonrpc", "/server/redirect", "/websocket" };

    // Serialize.
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var w: std.json.Stringify = .{ .writer = &aw.writer };

    try w.beginObject();

    // endpoints
    try w.objectField("endpoints");
    try w.beginArray();
    for (ep_paths.items) |path| {
        const e = path_map.get(path).?;
        const multi = e.methods_list.items.len > 1;

        const sorted_verbs = try alloc.dupe(registry.RequestType, e.methods_list.items);
        defer alloc.free(sorted_verbs);
        std.mem.sort(registry.RequestType, sorted_verbs, {}, rtLt);

        var jrpc_method: []const u8 = "";
        var jrpc_buf: [registry.max_method_name]u8 = undefined;
        if (!multi) {
            jrpc_method = registry.deriveMethodName(
                &jrpc_buf,
                path,
                sorted_verbs[0],
                false,
            ) catch "";
        }

        try w.beginObject();
        try w.objectField("auth_required");
        try w.write(e.auth_required);
        try w.objectField("jsonrpc_method");
        try w.write(jrpc_method);
        try w.objectField("methods");
        try w.beginArray();
        for (sorted_verbs) |v| try w.write(@tagName(v));
        try w.endArray();
        try w.objectField("path");
        try w.write(path);
        try w.objectField("wrap_result");
        try w.write(e.wrap_result);
        try w.endObject();
    }
    try w.endArray();

    // jsonrpc_methods
    try w.objectField("jsonrpc_methods");
    try w.beginArray();
    for (jrpc_names.items) |m| try w.write(m);
    try w.endArray();

    // notifications
    try w.objectField("notifications");
    try w.beginArray();
    for (notif_names.items) |n| try w.write(n);
    try w.endArray();

    // router_routes
    try w.objectField("router_routes");
    try w.beginArray();
    for (router_routes) |r| try w.write(r);
    try w.endArray();

    try w.endObject();

    return aw.toOwnedSlice();
}

fn strLt(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn rtLt(_: void, x: registry.RequestType, y: registry.RequestType) bool {
    return @intFromEnum(x) < @intFromEnum(y);
}

const EndpointEntry = struct {
    path: []const u8,
    wrap_result: bool,
    auth_required: bool,
    methods_list: std.ArrayList(registry.RequestType),
};

// --- tests ---------------------------------------------------------------

test "dumpApi: output contains server.info and server.config" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();

    const out = try buildDumpApiJson(alloc, aio);
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"server.info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"server.config\"") != null);
}

test "dumpApi: output contains WS-only methods" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();

    const out = try buildDumpApiJson(alloc, aio);
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"server.connection.identify\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"server.websocket.id\"") != null);
}

test "dumpApi: output contains 27 notifications" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();

    const out = try buildDumpApiJson(alloc, aio);
    defer alloc.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();

    const notifs = parsed.value.object.get("notifications").?.array;
    try std.testing.expectEqual(@as(usize, 27), notifs.items.len);
}

test "dumpApi: output contains all four router routes" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();

    const out = try buildDumpApiJson(alloc, aio);
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"/server/jsonrpc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"/websocket\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"/klippysocket\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"/server/redirect\"") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();
    const routes = parsed.value.object.get("router_routes").?.array;
    try std.testing.expectEqual(@as(usize, 4), routes.items.len);
}

test "dumpApi: output is valid JSON with all required top-level keys" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();

    const out = try buildDumpApiJson(alloc, aio);
    defer alloc.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expect(obj.get("endpoints") != null);
    try std.testing.expect(obj.get("jsonrpc_methods") != null);
    try std.testing.expect(obj.get("notifications") != null);
    try std.testing.expect(obj.get("router_routes") != null);
}

test "fuzz_dumpApi: output is always valid JSON" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var b: [4]u8 = undefined;
            smith.bytesWithHash(&b, 0);
            const _unused = b[0];
            _ = _unused;

            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io2 = threaded.io();

            const out = try buildDumpApiJson(std.heap.smp_allocator, io2);
            defer std.heap.smp_allocator.free(out);

            const parsed = std.json.parseFromSlice(
                std.json.Value,
                std.heap.smp_allocator,
                out,
                .{},
            ) catch return error.FuzzDumpApiNotJson;
            parsed.deinit();
        }
    }.run, .{});
}

test "extractBindAddr: defaults when [server] section missing" {
    const alloc = std.testing.allocator;
    var cfg = config.ConfigParser.init(alloc);
    defer cfg.deinit();

    const host, const port = try extractBindAddr(&cfg, "127.0.0.1", 7125);
    try std.testing.expectEqualStrings("127.0.0.1", host);
    try std.testing.expectEqual(@as(u16, 7125), port);
}

test "extractBindAddr: reads host and port from [server]" {
    const alloc = std.testing.allocator;
    const src =
        \\[server]
        \\host: 0.0.0.0
        \\port = 8080
        \\
    ;
    var cfg = config.ConfigParser.init(alloc);
    defer cfg.deinit();
    try cfg.parseString(src, "<test>");

    const host, const port = try extractBindAddr(&cfg, "127.0.0.1", 7125);
    try std.testing.expectEqualStrings("0.0.0.0", host);
    try std.testing.expectEqual(@as(u16, 8080), port);
}

test "extractBindAddr: host-only falls back on default port" {
    const alloc = std.testing.allocator;
    const src =
        \\[server]
        \\host: 0.0.0.0
        \\
    ;
    var cfg = config.ConfigParser.init(alloc);
    defer cfg.deinit();
    try cfg.parseString(src, "<test>");

    const host, const port = try extractBindAddr(&cfg, "127.0.0.1", 7125);
    try std.testing.expectEqualStrings("0.0.0.0", host);
    try std.testing.expectEqual(@as(u16, 7125), port);
}

test "extractBindAddr: invalid port uses default" {
    const alloc = std.testing.allocator;
    const src =
        \\[server]
        \\port: notanumber
        \\
    ;
    var cfg = config.ConfigParser.init(alloc);
    defer cfg.deinit();
    try cfg.parseString(src, "<test>");

    const host, const port = try extractBindAddr(&cfg, "127.0.0.1", 7125);
    try std.testing.expectEqualStrings("127.0.0.1", host);
    try std.testing.expectEqual(@as(u16, 7125), port);
}

test "extractBindAddr: enabled boolean has no effect on bind addr" {
    const alloc = std.testing.allocator;
    const src =
        \\[server]
        \\enabled: false
        \\
    ;
    var cfg = config.ConfigParser.init(alloc);
    defer cfg.deinit();
    try cfg.parseString(src, "<test>");

    const host, const port = try extractBindAddr(&cfg, "127.0.0.1", 7125);
    try std.testing.expectEqualStrings("127.0.0.1", host);
    try std.testing.expectEqual(@as(u16, 7125), port);
}

test { std.testing.refAllDecls(@This()); }
