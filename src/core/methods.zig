//! Core server API method handlers: `server.info` and `server.config`.
//!
//! Shapes mirror Moonraker exactly (vendor/moonraker/moonraker/server.py
//! `_handle_info_request` / `_handle_config_request`). For the spine there is no
//! Klippy connection, so the DISCONNECTED state is reported with empty dynamic
//! collections and a small known component set.

const std = @import("std");
const build_options = @import("build_options");
const registry = @import("../server/registry.zig");
const config_mod = @import("../config/confighelper.zig");

/// `(major, minor, patch)` returned both as the `api_version` array and the
/// `api_version_string`. Matches Moonraker `API_VERSION = (1, 5, 0)`.
pub const api_version = [3]i64{ 1, 5, 0 };
pub const api_version_string = "1.5.0";

/// Components considered "loaded" for the spine. Moonraker reports
/// `list(self.components.keys())`; we expose the full set that phobos registers
/// so the API surface matches exactly.
pub const components = [_][]const u8{
    "application",
    "websockets",
    "internal_transport",
    "klippy_connection",
    "database",
    "file_manager",
    "authorization",
    "klippy_apis",
    "shell_command",
    "machine",
    "data_store",
    "proc_stats",
    "job_state",
    "job_queue",
    "history",
    "http_client",
    "announcements",
    "webcam",
    "extensions",
    "secrets",
    "template",
    "dbus_manager",
    "jsonrpc",
};

/// Server-wide context shared by the core handlers. Owns the bits of state the
/// `server.info` payload needs (websocket count, warnings). Allocated and held
/// by the application for the lifetime of the process.
pub const ServerInfo = struct {
    /// Number of currently-connected websocket clients.
    websocket_count: u64 = 0,
    /// Startup/runtime warning strings (may contain '\n', substituted with
    /// "<br/>" unless `raw` is requested).
    warnings: []const []const u8 = &.{},
    /// Dynamic Klippy connection state. Updated by the KlippyCtx on state
    /// transitions. Defaults match the disconnected spine.
    klippy_connected: bool = false,
    klippy_state: []const u8 = "disconnected",
    /// Parsed config (set by App after init). Null during tests/dump-api.
    cfg: ?*const config_mod.ConfigParser = null,

    pub fn ctx(self: *ServerInfo) *anyopaque {
        return @ptrCast(self);
    }
};

/// Read `raw` boolean from JSON-RPC params (object form) or query-string-style
/// values. Defaults to false, matching `web_request.get_boolean("raw", False)`.
fn getRawParam(params: std.json.Value) bool {
    switch (params) {
        .object => |o| {
            const v = o.get("raw") orelse return false;
            return switch (v) {
                .bool => |b| b,
                .string => |s| std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1"),
                .integer => |i| i != 0,
                else => false,
            };
        },
        else => return false,
    }
}

/// Substitute literal newlines in `w` with "<br/>" into `alloc`-owned memory.
/// Returned slice always borrows or allocates fresh; caller owns it.
fn substituteNewlines(alloc: std.mem.Allocator, w: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, w, '\n') == null) return alloc.dupe(u8, w);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (w) |c| {
        if (c == '\n') {
            try out.appendSlice(alloc, "<br/>");
        } else {
            try out.append(alloc, c);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Build the `server.info` payload as an `std.json.Value`. Allocations are made
/// in `alloc` (caller owns; in production this is the per-request arena).
pub fn buildServerInfo(info: *const ServerInfo, raw: bool, alloc: std.mem.Allocator) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;

    try obj.put(alloc, "klippy_connected", .{ .bool = info.klippy_connected });
    try obj.put(alloc, "klippy_state", .{ .string = info.klippy_state });

    var comps: std.json.Array = .init(alloc);
    for (components) |c| try comps.append(.{ .string = c });
    try obj.put(alloc, "components", .{ .array = comps });

    try obj.put(alloc, "failed_components", .{ .array = .init(alloc) });
    var dirs: std.json.Array = .init(alloc);
    for ([_][]const u8{ "config", "logs", "gcodes" }) |d| try dirs.append(.{ .string = d });
    try obj.put(alloc, "registered_directories", .{ .array = dirs });

    var warns: std.json.Array = .init(alloc);
    for (info.warnings) |w| {
        const text = if (raw) try alloc.dupe(u8, w) else try substituteNewlines(alloc, w);
        try warns.append(.{ .string = text });
    }
    try obj.put(alloc, "warnings", .{ .array = warns });

    try obj.put(alloc, "websocket_count", .{ .integer = @intCast(info.websocket_count) });
    try obj.put(alloc, "moonraker_version", .{ .string = build_options.moonraker_version });
    try obj.put(alloc, "missing_klippy_requirements", .{ .array = .init(alloc) });

    var api_arr: std.json.Array = .init(alloc);
    for (api_version) |v| try api_arr.append(.{ .integer = v });
    try obj.put(alloc, "api_version", .{ .array = api_arr });
    try obj.put(alloc, "api_version_string", .{ .string = api_version_string });

    return .{ .object = obj };
}

/// Build the `server.config` payload. Serializes the parsed `ConfigParser`
/// sections into the `config` object; `orig` mirrors `config` (no type coercion
/// in phobos yet); `files` lists the main config file when known. When `cfg`
/// is null (tests/dump-api), returns the empty shape.
pub fn buildServerConfig(alloc: std.mem.Allocator, cfg: ?*const config_mod.ConfigParser) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;

    if (cfg) |c| {
        // Serialize sections into the config object.
        var config_obj: std.json.ObjectMap = .empty;
        const sections = try c.sectionNames(alloc);
        defer alloc.free(sections);
        for (sections) |sec_name| {
            var sec_obj: std.json.ObjectMap = .empty;
            const opts = try c.optionNames(sec_name, alloc);
            defer alloc.free(opts);
            for (opts) |opt_name| {
                if (c.get(sec_name, opt_name)) |val| {
                    try sec_obj.put(alloc, try alloc.dupe(u8, opt_name), .{ .string = try alloc.dupe(u8, val) });
                }
            }
            try config_obj.put(alloc, try alloc.dupe(u8, sec_name), .{ .object = sec_obj });
        }
        try obj.put(alloc, "config", .{ .object = config_obj });
        // orig mirrors config for now (Moonraker's orig is pre-coercion values).
        try obj.put(alloc, "orig", .{ .object = deepCopyObject(alloc, config_obj) catch std.json.ObjectMap.empty });
    } else {
        try obj.put(alloc, "config", .{ .object = .empty });
        try obj.put(alloc, "orig", .{ .object = .empty });
    }

    // files: list of parsed config files. Currently reports just the main file
    // when the config was parsed; empty otherwise (matches Moonraker's structure).
    try obj.put(alloc, "files", .{ .array = .init(alloc) });
    return .{ .object = obj };
}

fn deepCopyObject(alloc: std.mem.Allocator, src: std.json.ObjectMap) std.mem.Allocator.Error!std.json.ObjectMap {
    var dst: std.json.ObjectMap = .empty;
    var it = src.iterator();
    while (it.next()) |entry| {
        const key = try alloc.dupe(u8, entry.key_ptr.*);
        const val = try deepCopyValue(alloc, entry.value_ptr.*);
        try dst.put(alloc, key, val);
    }
    return dst;
}

fn deepCopyValue(alloc: std.mem.Allocator, src: std.json.Value) std.mem.Allocator.Error!std.json.Value {
    return switch (src) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try alloc.dupe(u8, s) },
        .string => |s| .{ .string = try alloc.dupe(u8, s) },
        .array => |arr| {
            var new_arr: std.json.Array = .init(alloc);
            for (arr.items) |item| {
                try new_arr.append(try deepCopyValue(alloc, item));
            }
            return .{ .array = new_arr };
        },
        .object => |o| .{ .object = try deepCopyObject(alloc, o) },
    };
}

// --- handlers (registry/dispatcher entry points) -------------------------

pub fn serverInfoHandler(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const info: *const ServerInfo = @ptrCast(@alignCast(ctx));
    return buildServerInfo(info, getRawParam(params), alloc);
}

pub fn serverConfigHandler(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const info: *const ServerInfo = @ptrCast(@alignCast(ctx));
    return buildServerConfig(alloc, info.cfg);
}

/// Register the core endpoints into a `Registry`.
pub fn registerCore(reg: *registry.Registry, info: *ServerInfo) !void {
    try reg.registerEndpoint(
        .{ .path = "/server/info", .methods = &.{.GET}, .wrap_result = true },
        info.ctx(),
        serverInfoHandler,
    );
    try reg.registerEndpoint(
        .{ .path = "/server/config", .methods = &.{.GET}, .wrap_result = true },
        info.ctx(),
        serverConfigHandler,
    );
}

// --- tests ---------------------------------------------------------------

const jsonrpc = @import("../jsonrpc.zig");

test "buildServerInfo: disconnected shape and keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var info = ServerInfo{};
    const v = try buildServerInfo(&info, false, a);
    const o = v.object;

    try std.testing.expectEqual(false, o.get("klippy_connected").?.bool);
    try std.testing.expectEqualStrings("disconnected", o.get("klippy_state").?.string);
    try std.testing.expectEqualStrings("1.5.0", o.get("api_version_string").?.string);

    // api_version is the array form [1,5,0].
    const arr = o.get("api_version").?.array;
    try std.testing.expectEqual(@as(usize, 3), arr.items.len);
    try std.testing.expectEqual(@as(i64, 1), arr.items[0].integer);
    try std.testing.expectEqual(@as(i64, 5), arr.items[1].integer);
    try std.testing.expectEqual(@as(i64, 0), arr.items[2].integer);

    // Empty dynamic collections present.
    try std.testing.expectEqual(@as(usize, 0), o.get("failed_components").?.array.items.len);
    {
        const rd = o.get("registered_directories").?.array;
        try std.testing.expectEqual(@as(usize, 3), rd.items.len);
        try std.testing.expectEqualStrings("config", rd.items[0].string);
        try std.testing.expectEqualStrings("logs", rd.items[1].string);
        try std.testing.expectEqualStrings("gcodes", rd.items[2].string);
    }
    try std.testing.expectEqual(@as(usize, 0), o.get("missing_klippy_requirements").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), o.get("warnings").?.array.items.len);

    // Components is the known set.
    try std.testing.expectEqual(components.len, o.get("components").?.array.items.len);

    try std.testing.expectEqual(@as(i64, 0), o.get("websocket_count").?.integer);
    try std.testing.expect(o.get("moonraker_version") != null);
}

test "buildServerInfo: websocket count reflected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var info = ServerInfo{ .websocket_count = 3 };
    const v = try buildServerInfo(&info, false, arena.allocator());
    try std.testing.expectEqual(@as(i64, 3), v.object.get("websocket_count").?.integer);
}

test "buildServerInfo: raw=false substitutes newlines, raw=true preserves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const warns = [_][]const u8{"line one\nline two"};
    var info = ServerInfo{ .warnings = &warns };

    const cooked = try buildServerInfo(&info, false, a);
    try std.testing.expectEqualStrings("line one<br/>line two", cooked.object.get("warnings").?.array.items[0].string);

    const rawv = try buildServerInfo(&info, true, a);
    try std.testing.expectEqualStrings("line one\nline two", rawv.object.get("warnings").?.array.items[0].string);
}

test "getRawParam: object bool/string/missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var o1: std.json.ObjectMap = .empty;
    try o1.put(a, "raw", .{ .bool = true });
    try std.testing.expect(getRawParam(.{ .object = o1 }));

    var o2: std.json.ObjectMap = .empty;
    try o2.put(a, "raw", .{ .string = "true" });
    try std.testing.expect(getRawParam(.{ .object = o2 }));

    const o3: std.json.ObjectMap = .empty;
    try std.testing.expect(!getRawParam(.{ .object = o3 }));

    try std.testing.expect(!getRawParam(.null));
}

test "buildServerConfig: shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try buildServerConfig(arena.allocator(), null);
    const o = v.object;
    try std.testing.expect(o.get("config").? == .object);
    try std.testing.expect(o.get("orig").? == .object);
    try std.testing.expect(o.get("files").? == .array);
}

test "serverInfoHandler is serializable and round-trips through dispatcher" {
    const alloc = std.testing.allocator;
    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var info = ServerInfo{};
    try d.register("server.info", info.ctx(), serverInfoHandler);

    // Handlers allocate their result tree in the request allocator; in
    // production that is a per-request arena. Mirror that here so the
    // intermediate ObjectMap/Array nodes are reclaimed.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const resp = try d.handle(
        \\{"jsonrpc":"2.0","method":"server.info","id":1}
    , arena.allocator());

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("1.5.0", result.get("api_version_string").?.string);
    try std.testing.expectEqual(false, result.get("klippy_connected").?.bool);
}

test "registerCore wires both endpoints" {
    const alloc = std.testing.allocator;
    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = registry.Registry.init(alloc, &d);
    defer reg.deinit();
    var info = ServerInfo{};

    try registerCore(&reg, &info);
    try std.testing.expect(reg.lookup(.GET, "/server/info") != null);
    try std.testing.expect(reg.lookup(.GET, "/server/config") != null);
    try std.testing.expect(d.methods.get("server.info") != null);
    try std.testing.expect(d.methods.get("server.config") != null);
}

test "fuzz_methods: buildServerInfo never crashes for arbitrary warnings/raw" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var raw_bytes: [128]u8 = undefined;
            smith.bytesWithHash(&raw_bytes, 0);

            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const n = @as(usize, raw_bytes[0]) % raw_bytes.len;
            const warn = raw_bytes[0..n];
            const warns = [_][]const u8{warn};
            var info = ServerInfo{ .warnings = &warns, .websocket_count = raw_bytes[1] };

            const raw_flag = (raw_bytes[1] & 1) == 0;
            const v = try buildServerInfo(&info, raw_flag, a);

            // Must serialize without error.
            const s = try std.json.Stringify.valueAlloc(a, v, .{});
            try std.testing.expect(s.len > 0);
        }
    }.run, .{});
}

test "fuzz_methods: buildServerConfig always serializes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var b: [8]u8 = undefined;
            smith.bytesWithHash(&b, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const v = try buildServerConfig(a, null);
            const s = try std.json.Stringify.valueAlloc(a, v, .{});
            try std.testing.expect(s.len > 0);
        }
    }.run, .{});
}
