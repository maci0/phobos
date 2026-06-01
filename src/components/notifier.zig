//! server.notifiers.* API component — Moonraker-compatible notifier list.
//!
//! Matches the endpoints registered in
//! `vendor/moonraker/moonraker/components/notifier.py` (Notifier):
//!
//!   GET  /server/notifiers/list   → server.notifiers.list
//!   POST /debug/notifiers/test    → debug.notifiers.test (debug only)
//!
//! Without configured notifiers the list is always empty, which is the
//! correct faithful shape. No apprise integration is implemented.
//!
//! Notifier record shape (NotifierInstance.as_dict):
//!   name, url, title, body, body_format, events, attach
//!
//! POST /debug/notifiers/test params: name (str)
//! Response: {"status": "success", "stats": {...}}

const std = @import("std");
const registry = @import("../server/registry.zig");

const Registry = registry.Registry;

// ---------------------------------------------------------------------------
// Context (no configured notifiers)
// ---------------------------------------------------------------------------

pub const NotifierCtx = struct {};

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /server/notifiers/list → {"notifiers": [...]}
/// Without configured notifiers the list is always empty (correct shape).
pub fn handleNotifierList(_: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    var result: std.json.ObjectMap = .empty;
    try result.put(alloc, "notifiers", .{ .array = .init(alloc) });
    return .{ .object = result };
}

/// POST /debug/notifiers/test → {"status": "success", "stats": {}}
/// Stub: no actual notifier to test; returns the success shape.
/// In production Moonraker sends a test notification via apprise.
pub fn handleNotifierTest(_: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    _ = alloc;
    // Require "name" param (mirrors notifier.py validation)
    const name: []const u8 = switch (params) {
        .object => |obj| blk: {
            const v = obj.get("name") orelse return error.InvalidParams;
            break :blk switch (v) {
                .string => |s| s,
                else => return error.InvalidParams,
            };
        },
        else => return error.InvalidParams,
    };
    // No configured notifiers → 404 equivalent
    _ = name;
    return error.NotFound;
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn registerNotifier(reg: *Registry, ctx: *NotifierCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    try reg.registerEndpoint(
        .{ .path = "/server/notifiers/list", .methods = &.{.GET} },
        c,
        handleNotifierList,
    );

    // POST /debug/notifiers/test is a debug endpoint in Moonraker
    // (register_debug_endpoint → includes WEBSOCKET transport in prod).
    try reg.registerEndpoint(
        .{ .path = "/debug/notifiers/test", .methods = &.{.POST} },
        c,
        handleNotifierTest,
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

test "handleNotifierList: returns empty notifiers array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = NotifierCtx{};
    const result = try handleNotifierList(@ptrCast(&ctx), .null, arena.allocator());
    const notifiers = result.object.get("notifiers").?;
    try testing.expect(notifiers == .array);
    try testing.expectEqual(@as(usize, 0), notifiers.array.items.len);
}

test "handleNotifierTest: missing name → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = NotifierCtx{};
    try testing.expectError(error.InvalidParams, handleNotifierTest(@ptrCast(&ctx), .null, a));
    const params = try mkParams(a, "{}");
    try testing.expectError(error.InvalidParams, handleNotifierTest(@ptrCast(&ctx), params, a));
}

test "handleNotifierTest: known name but no notifiers → NotFound" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = NotifierCtx{};
    const params = try mkParams(a, "{\"name\":\"my_notifier\"}");
    try testing.expectError(error.NotFound, handleNotifierTest(@ptrCast(&ctx), params, a));
}

test "registerNotifier: wires routes and JSON-RPC methods" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");

    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var ctx = NotifierCtx{};
    try registerNotifier(&reg, &ctx);

    try testing.expect(reg.lookup(.GET, "/server/notifiers/list") != null);
    try testing.expect(reg.lookup(.POST, "/debug/notifiers/test") != null);
    try testing.expect(d.methods.get("server.notifiers.list") != null);
    try testing.expect(d.methods.get("debug.notifiers.test") != null);
}

// --- Fuzz tests ---

test "fuzz handleNotifierList: never crashes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var ctx = NotifierCtx{};
            var buf: [4]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = handleNotifierList(@ptrCast(&ctx), .null, arena.allocator()) catch {};
        }
    }.run, .{});
}

test "fuzz handleNotifierTest: arbitrary params never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = NotifierCtx{};

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);

            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"name\":\"x\"}",
                "{\"name\":null}",
                "{\"name\":42}",
                "1",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            _ = handleNotifierTest(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}
