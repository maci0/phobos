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

pub const Notifier = struct {
    name: []const u8,
    url: []const u8 = "",
    title: []const u8 = "",
    body: []const u8 = "",
    body_format: []const u8 = "text",
};

pub const NotifierCtx = struct {
    /// Configured notifier names. Sending still needs apprise, which phobos
    /// does not link; a known name fails with `AppriseNotAvailable`.
    names: []const []const u8 = &.{},
    /// Full records for `server.notifiers.list`. Empty falls back to `names`.
    notifiers: []const Notifier = &.{},
    /// True when `notifiers` and its strings were allocated by `addNotifier`.
    owned: bool = false,

    pub fn deinit(self: *NotifierCtx, alloc: std.mem.Allocator) void {
        if (!self.owned) return;
        for (self.notifiers) |n| {
            alloc.free(n.name);
            alloc.free(n.url);
            alloc.free(n.title);
            alloc.free(n.body);
            alloc.free(n.body_format);
        }
        alloc.free(self.notifiers);
        self.notifiers = &.{};
        self.owned = false;
    }

    /// Append one config record. Strings are copied. The first call allocates
    /// the list; later calls grow it.
    pub fn addNotifier(self: *NotifierCtx, alloc: std.mem.Allocator, src: Notifier) !void {
        const name = try alloc.dupe(u8, src.name);
        errdefer alloc.free(name);
        const url = try alloc.dupe(u8, src.url);
        errdefer alloc.free(url);
        const title = try alloc.dupe(u8, src.title);
        errdefer alloc.free(title);
        const body = try alloc.dupe(u8, src.body);
        errdefer alloc.free(body);
        const body_format = try alloc.dupe(u8, if (src.body_format.len == 0) "text" else src.body_format);
        errdefer alloc.free(body_format);
        const next_len = self.notifiers.len + 1;
        const grown: []Notifier = if (self.owned and self.notifiers.len > 0)
            try alloc.realloc(@constCast(self.notifiers), next_len)
        else
            try alloc.alloc(Notifier, next_len);
        grown[next_len - 1] = .{
            .name = name,
            .url = url,
            .title = title,
            .body = body,
            .body_format = body_format,
        };
        self.notifiers = grown;
        self.owned = true;
    }
};

fn putNotifier(alloc: std.mem.Allocator, arr: *std.json.Array, name: []const u8, url: []const u8, title: []const u8, body: []const u8, body_format: []const u8) !void {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "name", .{ .string = name });
    try obj.put(alloc, "url", .{ .string = url });
    try obj.put(alloc, "title", .{ .string = title });
    try obj.put(alloc, "body", .{ .string = body });
    try obj.put(alloc, "body_format", .{ .string = body_format });
    try obj.put(alloc, "events", .{ .array = .init(alloc) });
    try obj.put(alloc, "attach", .null);
    try arr.append(.{ .object = obj });
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /server/notifiers/list → {"notifiers": [...]}
/// Without configured notifiers the list is always empty (correct shape).
pub fn handleNotifierList(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *NotifierCtx = @ptrCast(@alignCast(ctx_ptr));
    var arr: std.json.Array = .init(alloc);
    if (ctx.notifiers.len > 0) {
        for (ctx.notifiers) |n| {
            try putNotifier(alloc, &arr, n.name, n.url, n.title, n.body, n.body_format);
        }
    } else {
        for (ctx.names) |n| {
            try putNotifier(alloc, &arr, n, "", "", "", "text");
        }
    }
    var result: std.json.ObjectMap = .empty;
    try result.put(alloc, "notifiers", .{ .array = arr });
    return .{ .object = result };
}

/// POST /debug/notifiers/test → {"status": "success", "stats": {}}
/// Stub: no actual notifier to test; returns the success shape.
/// In production Moonraker sends a test notification via apprise.
pub fn handleNotifierTest(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    _ = alloc;
    const ctx: *NotifierCtx = @ptrCast(@alignCast(ctx_ptr));
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
    for (ctx.names) |n| {
        if (std.mem.eql(u8, n, name)) return error.AppriseNotAvailable;
    }
    for (ctx.notifiers) |n| {
        if (std.mem.eql(u8, n.name, name)) return error.AppriseNotAvailable;
    }
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

test "handleNotifierList: a configured record keeps url, title, and body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const one = [_]Notifier{.{
        .name = "desk",
        .url = "tgram://token/chat",
        .title = "hi",
        .body = "there",
        .body_format = "text",
    }};
    var ctx = NotifierCtx{ .notifiers = &one };
    const result = try handleNotifierList(@ptrCast(&ctx), .null, arena.allocator());
    const items = result.object.get("notifiers").?.array.items;
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("desk", items[0].object.get("name").?.string);
    try testing.expectEqualStrings("tgram://token/chat", items[0].object.get("url").?.string);
    try testing.expectEqualStrings("hi", items[0].object.get("title").?.string);
    try testing.expectEqualStrings("there", items[0].object.get("body").?.string);
    try testing.expect(items[0].object.get("attach").? == .null);
    const params = try mkParams(arena.allocator(), "{\"name\":\"desk\"}");
    try testing.expectError(error.AppriseNotAvailable, handleNotifierTest(@ptrCast(&ctx), params, arena.allocator()));
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

test "handleNotifierTest: configured notifier cannot send without apprise" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const names = [_][]const u8{"telegram"};
    var ctx = NotifierCtx{ .names = &names };
    const params = try mkParams(a, "{\"name\":\"telegram\"}");
    try testing.expectError(error.AppriseNotAvailable, handleNotifierTest(@ptrCast(&ctx), params, a));
    const missing = try mkParams(a, "{\"name\":\"other\"}");
    try testing.expectError(error.NotFound, handleNotifierTest(@ptrCast(&ctx), missing, a));
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
