//! Miscellaneous server endpoints from Moonraker's core server:
//!
//!   POST /server/restart          → server.restart
//!   POST /server/logs/rollover    → server.logs.rollover
//!
//! server.restart (server.py _handle_server_restart):
//!   Response: "ok" (a bare string, matching the Python `-> str` return type).
//!   Moonraker schedules an actual restart; in phobos this is a no-op stub
//!   noted here. The response shape is faithful.
//!
//! server.logs.rollover (loghelper.py _handle_log_rollover):
//!   Optional param: application (str) — "moonraker" or "klipper"
//!   Response: {"rolled_over": [...], "failed": {...}}
//!   phobos has no log file and no Klipper service unit, so each requested
//!   application fails with Moonraker's text for that case.

const std = @import("std");
const registry = @import("../server/registry.zig");

const Registry = registry.Registry;

// ---------------------------------------------------------------------------
// Context (stateless — both handlers are stubs)
// ---------------------------------------------------------------------------

pub const ServerMiscCtx = struct {};

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// POST /server/restart → "ok"
/// Moonraker returns the bare string "ok" (not an object), matching Python
/// `async def _handle_server_restart(...) -> str: return "ok"`.
pub fn handleRestart(_: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    _ = alloc;
    return .{ .string = "ok" };
}

/// Moonraker's rollover failure for its own log: phobos keeps no log file.
const moonraker_rollover_error = "File Logging Disabled";
/// Moonraker's rollover failure when it has no Klipper service unit
/// (`KlippyConnection.rollover_log`); phobos never detects one.
const klipper_rollover_error = "Unable to detect Klipper Service, cannot perform manual rollover";

/// POST /server/logs/rollover → {"rolled_over": [], "failed": {...}}
/// Every requested application fails with Moonraker's text for its missing
/// log or service. Another string `application` is error.UnknownApplication
/// ("Unknown application <app>"); null or a number, which Moonraker
/// str()-converts, is error.InvalidParams.
pub fn handleLogsRollover(_: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const app: ?std.json.Value = if (params == .object) params.object.get("application") else null;
    const want_moonraker, const want_klipper = if (app) |v| blk: {
        if (v != .string) return error.InvalidParams;
        if (std.mem.eql(u8, v.string, "moonraker")) break :blk .{ true, false };
        if (std.mem.eql(u8, v.string, "klipper")) break :blk .{ false, true };
        return error.UnknownApplication;
    } else .{ true, true };

    var failed_obj: std.json.ObjectMap = .empty;
    if (want_moonraker) try failed_obj.put(alloc, "moonraker", .{ .string = moonraker_rollover_error });
    if (want_klipper) try failed_obj.put(alloc, "klipper", .{ .string = klipper_rollover_error });

    var result: std.json.ObjectMap = .empty;
    try result.put(alloc, "rolled_over", .{ .array = .init(alloc) });
    try result.put(alloc, "failed", .{ .object = failed_obj });
    return .{ .object = result };
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn registerServerMisc(reg: *Registry, ctx: *ServerMiscCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    // POST /server/restart — single verb → "server.restart"
    try reg.registerEndpoint(
        .{ .path = "/server/restart", .methods = &.{.POST} },
        c,
        handleRestart,
    );

    // POST /server/logs/rollover — single verb → "server.logs.rollover"
    try reg.registerEndpoint(
        .{ .path = "/server/logs/rollover", .methods = &.{.POST} },
        c,
        handleLogsRollover,
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn mkParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    return p.value;
}

test "handleRestart: returns string 'ok'" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = ServerMiscCtx{};
    const result = try handleRestart(@ptrCast(&ctx), .null, arena.allocator());
    try testing.expectEqualStrings("ok", result.string);
}

test "handleLogsRollover: no param → both apps in failed, none rolled_over" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = ServerMiscCtx{};

    const result = try handleLogsRollover(@ptrCast(&ctx), .null, a);
    const rolled = result.object.get("rolled_over").?.array;
    const failed = result.object.get("failed").?.object;

    try testing.expectEqual(@as(usize, 0), rolled.items.len);
    try testing.expectEqualStrings("File Logging Disabled", failed.get("moonraker").?.string);
    try testing.expectEqualStrings("Unable to detect Klipper Service, cannot perform manual rollover", failed.get("klipper").?.string);
}

test "handleLogsRollover: application=moonraker → only moonraker in failed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = ServerMiscCtx{};

    const params = try mkParams(a, "{\"application\":\"moonraker\"}");
    const result = try handleLogsRollover(@ptrCast(&ctx), params, a);
    const failed = result.object.get("failed").?.object;

    try testing.expect(failed.get("moonraker") != null);
    try testing.expect(failed.get("klipper") == null);
}

test "handleLogsRollover: application=klipper → only klipper in failed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = ServerMiscCtx{};

    const params = try mkParams(a, "{\"application\":\"klipper\"}");
    const result = try handleLogsRollover(@ptrCast(&ctx), params, a);
    const failed = result.object.get("failed").?.object;

    try testing.expect(failed.get("klipper") != null);
    try testing.expect(failed.get("moonraker") == null);
}

test "handleLogsRollover: unknown application is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = ServerMiscCtx{};

    try testing.expectError(error.UnknownApplication, handleLogsRollover(@ptrCast(&ctx), try mkParams(a, "{\"application\":\"unknown_app\"}"), a));
    for ([_][]const u8{ "{\"application\":null}", "{\"application\":5}" }) |body| {
        try testing.expectError(error.InvalidParams, handleLogsRollover(@ptrCast(&ctx), try mkParams(a, body), a));
    }
}

test "handleLogsRollover: response has both rolled_over and failed keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = ServerMiscCtx{};

    const result = try handleLogsRollover(@ptrCast(&ctx), .null, a);
    try testing.expect(result.object.get("rolled_over") != null);
    try testing.expect(result.object.get("failed") != null);
}

test "registerServerMisc: wires routes and JSON-RPC methods" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");

    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var ctx = ServerMiscCtx{};
    try registerServerMisc(&reg, &ctx);

    try testing.expect(reg.lookup(.POST, "/server/restart") != null);
    try testing.expect(reg.lookup(.POST, "/server/logs/rollover") != null);
    try testing.expect(d.methods.get("server.restart") != null);
    try testing.expect(d.methods.get("server.logs.rollover") != null);
}

// --- Fuzz tests ---

test "fuzz handleRestart: never crashes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var ctx = ServerMiscCtx{};
            var buf: [4]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = handleRestart(@ptrCast(&ctx), .null, arena.allocator()) catch {};
        }
    }.run, .{});
}

test "fuzz handleLogsRollover: arbitrary params never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = ServerMiscCtx{};

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);

            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"application\":\"moonraker\"}",
                "{\"application\":\"klipper\"}",
                "{\"application\":\"bogus\"}",
                "{\"application\":null}",
                "1",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            _ = handleLogsRollover(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}
