//! Core server API method handlers: `server.info` and `server.config`.
//!
//! Shapes mirror Moonraker exactly (vendor/moonraker/moonraker/server.py
//! `_handle_info_request` / `_handle_config_request`). For the spine there is no
//! Klippy connection, so the DISCONNECTED state is reported with empty dynamic
//! collections and a small known component set.

const std = @import("std");
const build_options = @import("build_options");
const registry = @import("../server/registry.zig");

/// `(major, minor, patch)` returned both as the `api_version` array and the
/// `api_version_string`. Matches Moonraker `API_VERSION = (1, 5, 0)`.
pub const api_version = [3]i64{ 1, 5, 0 };
pub const api_version_string = "1.5.0";

/// Components considered "loaded" for the spine. Moonraker reports
/// `list(self.components.keys())`; we expose a fixed core subset.
pub const components = [_][]const u8{
    "application",
    "websockets",
    "internal_transport",
    "klippy_connection",
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

    try obj.put(alloc, "klippy_connected", .{ .bool = false });
    try obj.put(alloc, "klippy_state", .{ .string = "disconnected" });

    var comps: std.json.Array = .init(alloc);
    for (components) |c| try comps.append(.{ .string = c });
    try obj.put(alloc, "components", .{ .array = comps });

    try obj.put(alloc, "failed_components", .{ .array = .init(alloc) });
    try obj.put(alloc, "registered_directories", .{ .array = .init(alloc) });

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

/// Build the `server.config` payload. For the spine the config is empty: the
/// shape (`config`, `orig`, `files`) matches `_handle_config_request`.
pub fn buildServerConfig(alloc: std.mem.Allocator) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "config", .{ .object = .empty });
    try obj.put(alloc, "orig", .{ .object = .empty });
    try obj.put(alloc, "files", .{ .array = .init(alloc) });
    return .{ .object = obj };
}

// --- handlers (registry/dispatcher entry points) -------------------------

pub fn serverInfoHandler(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const info: *const ServerInfo = @ptrCast(@alignCast(ctx));
    return buildServerInfo(info, getRawParam(params), alloc);
}

pub fn serverConfigHandler(_: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    return buildServerConfig(alloc);
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
    try std.testing.expectEqual(@as(usize, 0), o.get("registered_directories").?.array.items.len);
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
    const v = try buildServerConfig(arena.allocator());
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
            const v = try buildServerConfig(a);
            const s = try std.json.Stringify.valueAlloc(a, v, .{});
            try std.testing.expect(s.len > 0);
        }
    }.run, .{});
}
