const std = @import("std");
const build_options = @import("build_options");
pub const arena = @import("util/arena.zig");

/// LMDB-backed datastore modules. Guarded behind the `with_lmdb` build option
/// so `-Dwith_lmdb=false` still compiles (no libc, no vendored C). When the
/// option is off these alias an empty struct so `refAllDecls` stays cheap.
pub const lmdb_c = if (build_options.with_lmdb) @import("store/lmdb_c.zig") else struct {};
pub const datastore = if (build_options.with_lmdb) @import("store/datastore.zig") else struct {};
pub const lmdb_store = if (build_options.with_lmdb) @import("store/lmdb_store.zig") else struct {};
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
pub const testutil_server = @import("testutil/server.zig");
pub const testutil_ws_client = @import("testutil/ws_client.zig");
pub const app = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const aio = init.io;

    // Parse args: with --dump-api, print the API surface and exit.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--dump-api")) {
            return dumpApi(alloc, aio);
        }
    }

    var server_app = try app.App.init(alloc);
    defer server_app.deinit(aio);

    var srv = server_app.httpServer(aio);

    const host = "127.0.0.1";
    const bind_port: u16 = 7125; // Moonraker's default HTTP port.
    var listener = try io.Listener.bind(aio, host, bind_port);
    defer listener.deinit(aio);

    std.debug.print("phobos listening on http://{s}:{d}\n", .{ host, bind_port });
    try listener.serveWith(aio, @ptrCast(&srv), http_transport.connHandler);
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

    // Transport routes phobos serves (sorted).
    const router_routes = [_][]const u8{ "/server/jsonrpc", "/websocket" };

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

test "dumpApi: output contains /server/jsonrpc and /websocket router routes" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();

    const out = try buildDumpApiJson(alloc, aio);
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"/server/jsonrpc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"/websocket\"") != null);
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

test { std.testing.refAllDecls(@This()); }
