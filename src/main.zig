//! Root module: process entrypoint (`main`) and the public barrel that
//! re-exports every phobos module. Importing `@import("main.zig")` (or the
//! package root) gives access to the whole tree via the `pub const` aliases
//! below; `src/app.zig` is the runtime assembly point those modules wire into.
const std = @import("std");
const build_options = @import("build_options");
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
pub const json_params = @import("json/params.zig");
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
pub const paneldue = @import("components/paneldue.zig");
pub const feather_updates = @import("components/feather_updates.zig");
pub const announcements = @import("components/announcements.zig");
pub const testutil_server = @import("testutil/server.zig");
pub const testutil_ws_client = @import("testutil/ws_client.zig");
pub const testutil_klippy_sim = @import("testutil/klippy_sim.zig");
pub const test_stress = @import("test_stress.zig");
pub const app = @import("app.zig");
pub const oracle_replay = @import("oracle/replay.zig");

const usage_text =
    \\phobos: Moonraker-compatible print server
    \\
    \\Usage: phobos [options]
    \\
    \\Options:
    \\  -c, --config <path>      Moonraker-style config file to load
    \\  -d, --data-path <path>   Data directory. With no -c, loads <path>/config/moonraker.conf
    \\                           and opens <path>/database/moonraker-sql.db
    \\      --dump-api           Print the API surface as JSON to stdout and exit
    \\      schema [command]     Print the CLI Spec document and exit
    \\      --version            Print version and exit
    \\  -o, --output FMT         auto, text, or json. auto stays text on a pipe
    \\  -h, --help               Show this help and exit
    \\
;

const OutputMode = enum { auto, text, json };
var output_mode: OutputMode = .auto;

fn wantsJson() bool {
    return output_mode == .json;
}

fn badOutput() noreturn {
    output_mode = .auto;
    std.debug.print("phobos: error: --output requires auto, text, or json\n", .{});
    std.process.exit(2);
}

fn setOutputMode(value: []const u8) void {
    if (std.mem.eql(u8, value, "auto")) {
        output_mode = .auto;
    } else if (std.mem.eql(u8, value, "text")) {
        output_mode = .text;
    } else if (std.mem.eql(u8, value, "json")) {
        output_mode = .json;
    } else badOutput();
}

fn schemaSelected(name: []const u8, filter: []const u8) bool {
    if (filter.len == 0) return true;
    if (std.mem.eql(u8, name, filter)) return true;
    return name.len > filter.len and std.mem.startsWith(u8, name, filter) and name[filter.len] == ' ';
}

const SpecCmd = struct {
    name: []const u8,
    description: []const u8,
    effects: []const u8,
    body: []const u8,
};

fn specCmds() [4]SpecCmd {
    return .{
        .{
            .name = "schema",
            .effects = "read_only",
            .description = "Print this CLI Spec document. schema <command> returns the same document filtered to that command.",
            .body = "\"output_kind\":\"opaque\",\"media_type\":\"application/json\"",
        },
        .{
            .name = "version",
            .effects = "read_only",
            .description = "Print the phobos release. --version without JSON prints the Moonraker compatibility string.",
            .body = "\"cardinality\":\"single\",\"output_fields\":[{\"name\":\"version\",\"type\":\"string\"}]",
        },
        .{
            .name = "dump-api",
            .effects = "read_only",
            .description = "Print the API surface. Stdout stays that JSON document in every output mode. Does not bind a socket.",
            .body = "\"output_kind\":\"opaque\",\"media_type\":\"application/json\"",
        },
        .{
            .name = "serve",
            .effects = "non_idempotent",
            .description = "Listen for Moonraker clients. The word serve is not typed. A retry is not safe.",
            .body = "\"output_kind\":\"opaque\",\"media_type\":\"text/plain\"",
        },
    };
}

fn renderSchema(alloc: std.mem.Allocator, filter: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    try list.appendSlice(alloc, "{\"clispec\":\"0.3\",\"name\":\"phobos\",\"version\":\"");
    try list.appendSlice(alloc, build_options.phobos_version);
    try list.appendSlice(alloc, "\",\"description\":\"Moonraker-compatible print server.\",\"output\":{\"tty\":\"text\",\"piped\":\"text\"},\"global_args\":[{\"name\":\"--output\",\"short\":\"-o\",\"type\":\"string\",\"required\":false,\"description\":\"auto, text, or json. auto stays text when piped.\",\"default\":\"auto\",\"enum\":[\"auto\",\"text\",\"json\"]}],\"commands\":[");
    var count: usize = 0;
    for (specCmds()) |cmd| {
        if (!schemaSelected(cmd.name, filter)) continue;
        if (count != 0) try list.append(alloc, ',');
        try list.appendSlice(alloc, "{\"name\":\"");
        try list.appendSlice(alloc, cmd.name);
        try list.appendSlice(alloc, "\",\"description\":\"");
        try list.appendSlice(alloc, cmd.description);
        try list.appendSlice(alloc, "\",\"effects\":\"");
        try list.appendSlice(alloc, cmd.effects);
        try list.appendSlice(alloc, "\",");
        try list.appendSlice(alloc, cmd.body);
        try list.append(alloc, '}');
        count += 1;
    }
    if (count == 0) return error.UnknownPath;
    try list.appendSlice(alloc, "],\"errors\":[{\"kind\":\"usage\",\"exit_code\":2,\"retryable\":false,\"description\":\"The arguments are not valid.\"},{\"kind\":\"failure\",\"exit_code\":1,\"retryable\":true,\"description\":\"The server failed to start.\"}]}\n");
    return list.toOwnedSlice(alloc);
}

/// Write to stdout with a small bounded buffer. Used for --help/--version so
/// requested output lands on stdout (parseable), not the stderr debug channel.
fn writeStdout(aio: std.Io, bytes: []const u8) !void {
    const stdout = std.Io.File.stdout();
    var wbuf: [512]u8 = undefined;
    var sw = stdout.writer(aio, &wbuf);
    try sw.interface.writeAll(bytes);
    try sw.interface.flush();
}

/// Report a CLI usage error on stderr (with usage text) and exit with code 2,
/// the conventional "command-line usage" status (distinct from 1 = runtime).
fn usageError(arg: []const u8, detail: []const u8) noreturn {
    std.debug.print("phobos: error: '{s}'{s}\n\n{s}", .{ arg, detail, usage_text });
    if (output_mode == .json) {
        std.debug.print("{s}", .{"{\"error\":{\"kind\":\"usage\",\"message\":\"invalid arguments\"}}\n"});
    }
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| {
        if (output_mode == .json) {
            std.debug.print("{s}", .{"{\"error\":{\"kind\":\"failure\",\"message\":\"command failed\"}}\n"});
            std.process.exit(1);
        }
        return err;
    };
}

fn run(init: std.process.Init) !void {
    // `init.gpa` is std's DebugAllocator — it captures a dwarf stack trace on
    // every allocation for leak/UAF detection. That tracing dominates the hot
    // path (allocation-heavy Klippy-proxy requests) and is pointless in a
    // long-running release daemon, so use the lock-sharded `smp_allocator` in
    // release and keep the checked allocator only for Debug builds.
    const alloc = if (@import("builtin").mode == .debug) init.gpa else std.heap.smp_allocator;
    // On 32-bit targets (armv7) the runtime-default IO backend's 16 MB handler
    // stacks reserve ~2 GB of VSZ at the ~128-thread peak — enough to exhaust the
    // 3 GB user address space. Own the backend there with a 1 MB stack (handlers
    // need ~120 KB: the 64 KB file buffer + bounded JSON depth). On 64-bit the
    // address space is effectively unlimited, so the default backend is fine and
    // we skip the override entirely — the whole thing compiles out.
    const bounded_stack = @import("builtin").target.ptrBitWidth() <= 32;
    var threaded: std.Io.Threaded = if (bounded_stack)
        std.Io.Threaded.init(alloc, .{ .stack_size = io.Listener.handler_stack_size })
    else
        undefined;
    defer if (bounded_stack) threaded.deinit();
    const aio = if (bounded_stack) threaded.io() else init.io;

    // Parse CLI args.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var config_path: ?[]const u8 = null;
    var data_path: ?[]const u8 = null;
    var dump_api = false;
    var schema = false;
    var filter_buf: [96]u8 = undefined;
    var filter_len: usize = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--output")) {
            i += 1;
            if (i >= args.len) badOutput();
            setOutputMode(args[i]);
        } else if (std.mem.startsWith(u8, a, "--output=")) {
            setOutputMode(a["--output=".len..]);
        } else if (std.mem.eql(u8, a, "schema")) {
            schema = true;
        } else if (schema and a.len > 0 and a[0] != '-') {
            if (filter_len != 0 and filter_len < filter_buf.len) {
                filter_buf[filter_len] = ' ';
                filter_len += 1;
            }
            const n = @min(a.len, filter_buf.len - filter_len);
            @memcpy(filter_buf[filter_len..][0..n], a[0..n]);
            filter_len += n;
        } else if (std.mem.eql(u8, a, "--dump-api")) {
            dump_api = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try writeStdout(aio, usage_text);
            return;
        } else if (std.mem.eql(u8, a, "--version")) {
            if (wantsJson()) {
                try writeStdout(aio, "{\"version\":\"");
                try writeStdout(aio, build_options.phobos_version);
                try writeStdout(aio, "\"}\n");
            } else {
                try writeStdout(aio, build_options.moonraker_version);
                try writeStdout(aio, "\n");
            }
            return;
        } else if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--config")) {
            i += 1;
            if (i >= args.len) return usageError(a, " requires a <path> value");
            config_path = args[i];
        } else if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "--data-path")) {
            // Moonraker-compatible datadir flag. Backs the file_manager roots
            // (gcodes/config/logs). Without it phobos uses a temp dir under /tmp
            // and deletes it at exit; /tmp is tmpfs on embedded targets, never
            // for real data.
            i += 1;
            if (i >= args.len) return usageError(a, " requires a <path> value");
            data_path = args[i];
        } else {
            // Unknown argument: fail loudly with usage instead of silently
            // ignoring it (a silently-dropped flag looks like it took effect).
            return usageError(a, ": unknown argument");
        }
    }

    if (schema) {
        const doc = renderSchema(alloc, filter_buf[0..filter_len]) catch |err| switch (err) {
            error.UnknownPath => {
                std.debug.print("unknown command path\n", .{});
                usageError("schema", ": unknown command path");
            },
            else => return err,
        };
        defer alloc.free(doc);
        try writeStdout(aio, doc);
        return;
    }

    if (dump_api) return dumpApi(alloc, aio);

    // Moonraker's `-d` with no `-c` loads <data>/config/moonraker.conf.
    // S65moonraker passes only `-d /root/printer_data`.
    const implied_config = if (config_path == null and data_path != null)
        try std.fs.path.join(alloc, &.{ data_path.?, "config", "moonraker.conf" })
    else
        null;
    defer if (implied_config) |p| alloc.free(p);
    if (implied_config) |p| config_path = p;

    // Read host/port from config when available, with defaults matching Moonraker.
    const host, const bind_port = try resolveBindAddr(alloc, init.arena.allocator(), aio, config_path);
    std.debug.print("phobos: bind host='{s}' port={d}\n", .{ host, bind_port });

    // Select the DataStore backend from `[database] backend` (sqlite | file).
    const db_backend = resolveDbBackend(alloc, aio, config_path);
    const db_path = try resolveDbPath(alloc, init.arena.allocator(), aio, config_path, data_path);
    std.debug.print("phobos: datastore backend = {s}{s}\n", .{ @tagName(db_backend), if (db_path) |p| p else "" });

    if (data_path) |dp| std.debug.print("phobos: data path = {s}\n", .{dp});
    var server_app = try app.App.initWithStore(alloc, db_backend, aio, db_path, data_path);
    defer server_app.deinit(aio);

    if (config_path) |path| {
        server_app.setConfig(aio, path);
    }

    var srv = server_app.httpServer(aio);

    // Start the background Klippy Unix-socket bridge. Only the real daemon
    // path calls start(); tests go through App.init/httpServer which only
    // calls setIo() so no background task is spawned during testing.
    try server_app.klippy_ctx.start();
    try server_app.data_store_ctx.startSampler();
    server_app.update_ctx.startAutoRefresh();
    // Moonraker fetches announcements at startup; the refresh worker first
    // waits its interval. Fetch in the background so the listener starts now.
    var startup_announcements = try aio.concurrent(refreshAnnouncements, .{ &server_app, aio });
    defer startup_announcements.cancel(aio);

    var listener = try io.Listener.bind(aio, host, bind_port);
    defer listener.deinit(aio);

    std.debug.print("phobos listening on http://{s}:{d}\n", .{ host, bind_port });
    try listener.serveWith(aio, @ptrCast(&srv), http_transport.connHandler);
}

/// Fetch every announcement feed once, under Core like the refresh worker.
/// A failed fetch is logged; the worker retries on its interval.
fn refreshAnnouncements(server_app: *app.App, aio: std.Io) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    _ = server_app.core.run(aio, announcements.handleUpdate, .{ @as(*anyopaque, server_app.announcements_ctx), std.json.Value.null, arena.allocator() }) catch |err|
        std.debug.print("phobos: warning: startup announcements refresh failed: {}\n", .{err});
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

/// Read `[database] path` when the config sets it. Otherwise, a `-d` data
/// path opens `<data>/database/moonraker-sql.db`, which is where Moonraker
/// stores the printer database. Null (no `[database] path`, no `-d`) puts it in
/// the temporary datadir that `App.deinit` deletes.
pub fn resolveDbPath(
    gpa: std.mem.Allocator,
    arena_alloc: std.mem.Allocator,
    aio: std.Io,
    config_path: ?[]const u8,
    data_path: ?[]const u8,
) !?[]const u8 {
    if (config_path) |path| {
        var cfg = config.ConfigParser.init(gpa);
        defer cfg.deinit();
        if (cfg.parseFile(aio, path)) {
            if (cfg.get("database", "path")) |v| {
                if (v.len > 0) return try arena_alloc.dupe(u8, v);
            }
        } else |_| {}
    }
    const dp = data_path orelse return null;
    return try std.fs.path.join(arena_alloc, &.{ dp, "database", "moonraker-sql.db" });
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
    var port: u16 = default_port;
    if (cfg.hasOption("server", "port")) {
        const raw = cfg.getInt("server", "port") catch |err| {
            std.debug.print("phobos: warning: invalid [server] port in config: {} — using default\n", .{err});
            return .{ host, default_port };
        };
        // Range-check before @intCast: getInt returns i64, so an out-of-range
        // value (e.g. 70000 or -1) parses fine and would panic the cast.
        if (raw < 1 or raw > 65535) {
            std.debug.print("phobos: warning: [server] port {d} out of range — using default\n", .{raw});
            return .{ host, default_port };
        }
        port = @intCast(raw);
    }

    return .{ host, port };
}

/// Build an App, enumerate its registrations, and print a deterministic JSON
/// document to stdout describing phobos's current API surface.
///
/// Shape:
///   { "endpoints": [...], "jsonrpc_methods": [...], "notifications": [...],
///     "router_routes": [...] }
///
/// All arrays are sorted. Does NOT bind any sockets. The roots live in a
/// temp datadir that is deleted on return; the database is in memory.
pub fn dumpApi(alloc: std.mem.Allocator, aio: std.Io) !void {
    const out = try buildDumpApiJson(alloc, aio, null);
    defer alloc.free(out);

    const stdout = std.Io.File.stdout();
    var wbuf: [4096]u8 = undefined;
    var sw = stdout.writer(aio, &wbuf);
    try sw.interface.writeAll(out);
    try sw.interface.writeByte('\n');
    try sw.interface.flush();
}

/// Build the --dump-api JSON without touching stdout (testable). `data_path`
/// is as for `App.initWithStore`.
pub fn buildDumpApiJson(alloc: std.mem.Allocator, aio: std.Io, data_path: ?[]const u8) ![]u8 {
    var server_app = try app.App.init(alloc, aio, data_path);
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
    return @backingInt(x) < @backingInt(y);
}

const EndpointEntry = struct {
    path: []const u8,
    wrap_result: bool,
    auth_required: bool,
    methods_list: std.ArrayList(registry.RequestType),
};

// --- tests ---------------------------------------------------------------

test "schemaSelected matches a command and rejects a prefix" {
    try std.testing.expect(schemaSelected("dump-api", ""));
    try std.testing.expect(schemaSelected("dump-api", "dump-api"));
    try std.testing.expect(!schemaSelected("serve", "dump-api"));
    try std.testing.expect(!schemaSelected("dump-api", "dump"));
}

test "fuzz schemaSelected never panics" {
    var prng = std.Random.DefaultPrng.init(0xC11_5EC);
    const rnd = prng.random();
    var buf: [24]u8 = undefined;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..len]);
        _ = schemaSelected("dump-api", buf[0..len]);
        _ = schemaSelected("serve", buf[0..len]);
    }
}

test "renderSchema is clispec 0.3 and filters" {
    const doc = try renderSchema(std.testing.allocator, "");
    defer std.testing.allocator.free(doc);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"clispec\":\"0.3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"name\":\"dump-api\"") != null);
    const one = try renderSchema(std.testing.allocator, "serve");
    defer std.testing.allocator.free(one);
    try std.testing.expect(std.mem.indexOf(u8, one, "\"name\":\"serve\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, one, "\"name\":\"dump-api\"") == null);
}

test "dumpApi: output contains server.info and server.config" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = io.Listener.handler_stack_size });
    defer threaded.deinit();
    const aio = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try tmp.dir.realPathFileAlloc(aio, ".", alloc);
    defer alloc.free(data_path);
    const out = try buildDumpApiJson(alloc, aio, data_path);
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"server.info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"server.config\"") != null);
}

test "dumpApi: output contains WS-only methods" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = io.Listener.handler_stack_size });
    defer threaded.deinit();
    const aio = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try tmp.dir.realPathFileAlloc(aio, ".", alloc);
    defer alloc.free(data_path);
    const out = try buildDumpApiJson(alloc, aio, data_path);
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"server.connection.identify\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"server.websocket.id\"") != null);
}

test "dumpApi: output contains 27 notifications" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = io.Listener.handler_stack_size });
    defer threaded.deinit();
    const aio = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try tmp.dir.realPathFileAlloc(aio, ".", alloc);
    defer alloc.free(data_path);
    const out = try buildDumpApiJson(alloc, aio, data_path);
    defer alloc.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();

    const notifs = parsed.value.object.get("notifications").?.array;
    try std.testing.expectEqual(@as(usize, 27), notifs.items.len);
}

test "dumpApi: output contains all four router routes" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = io.Listener.handler_stack_size });
    defer threaded.deinit();
    const aio = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try tmp.dir.realPathFileAlloc(aio, ".", alloc);
    defer alloc.free(data_path);
    const out = try buildDumpApiJson(alloc, aio, data_path);
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
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = io.Listener.handler_stack_size });
    defer threaded.deinit();
    const aio = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try tmp.dir.realPathFileAlloc(aio, ".", alloc);
    defer alloc.free(data_path);
    const out = try buildDumpApiJson(alloc, aio, data_path);
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

            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = io.Listener.handler_stack_size });
            defer threaded.deinit();
            const io2 = threaded.io();

            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const data_path = try tmp.dir.realPathFileAlloc(io2, ".", std.heap.smp_allocator);
            defer std.heap.smp_allocator.free(data_path);
            const out = try buildDumpApiJson(std.heap.smp_allocator, io2, data_path);
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

test "resolveDbPath: -d uses moonraker-sql.db unless the config sets a path" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();
    var req_arena = std.heap.ArenaAllocator.init(alloc);
    defer req_arena.deinit();
    const a = req_arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(a, "{s}/{s}", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    try tmp.dir.createDirPath(aio, "config");
    try tmp.dir.writeFile(aio, .{ .sub_path = "config/moonraker.conf", .data = "[server]\nport: 7125\n" });
    const implied = (try resolveDbPath(alloc, a, aio, try std.fs.path.join(a, &.{ base, "config/moonraker.conf" }), base)).?;
    try std.testing.expect(std.mem.endsWith(u8, implied, "/database/moonraker-sql.db"));
    try std.testing.expect(std.mem.indexOf(u8, implied, base) != null);

    try tmp.dir.writeFile(aio, .{ .sub_path = "config/override.conf", .data = "[database]\npath: /var/lib/moonraker-sql.db\n" });
    const over = (try resolveDbPath(alloc, a, aio, try std.fs.path.join(a, &.{ base, "config/override.conf" }), base)).?;
    try std.testing.expectEqualStrings("/var/lib/moonraker-sql.db", over);

    try std.testing.expect((try resolveDbPath(alloc, a, aio, null, null)) == null);
}

test {
    std.testing.refAllDecls(@This());
}
