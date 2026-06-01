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
//!   Response: {"rolled_over": [...], "failed": {}}
//!   Without real log files, moonraker rollover always fails (File Logging
//!   Disabled); in phobos we report both as failed (no log file configured).

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

/// POST /server/logs/rollover → {"rolled_over": [...], "failed": {}}
/// In phobos there is no log file; we report each requested application as
/// failed with "File Logging Disabled", matching Moonraker's error text.
pub fn handleLogsRollover(_: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const log_apps = [_][]const u8{ "moonraker", "klipper" };

    // Determine which apps were requested
    const requested_app: ?[]const u8 = blk: {
        switch (params) {
            .object => |obj| {
                const v = obj.get("application") orelse break :blk null;
                switch (v) {
                    .string => |s| {
                        // Validate application name matches Moonraker check
                        var valid = false;
                        for (log_apps) |app| {
                            if (std.mem.eql(u8, app, s)) {
                                valid = true;
                                break;
                            }
                        }
                        if (!valid) return error.InvalidParams;
                        break :blk s;
                    },
                    .null => break :blk null,
                    else => break :blk null,
                }
            },
            else => break :blk null,
        }
    };

    const rolled_over_arr: std.json.Array = .init(alloc);
    var failed_obj: std.json.ObjectMap = .empty;

    // phobos has no log files; report each as failed
    const apps_to_process: []const []const u8 = if (requested_app) |app|
        @as([]const []const u8, &.{app})
    else
        &log_apps;

    for (apps_to_process) |app| {
        try failed_obj.put(alloc, app, .{ .string = "File Logging Disabled" });
    }

    var result: std.json.ObjectMap = .empty;
    try result.put(alloc, "rolled_over", .{ .array = rolled_over_arr });
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
    try testing.expect(failed.get("moonraker") != null);
    try testing.expect(failed.get("klipper") != null);
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

test "handleLogsRollover: unknown application → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = ServerMiscCtx{};

    const params = try mkParams(a, "{\"application\":\"unknown_app\"}");
    try testing.expectError(error.InvalidParams, handleLogsRollover(@ptrCast(&ctx), params, a));
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
