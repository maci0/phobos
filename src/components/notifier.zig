//! server.notifiers.* API component — Moonraker-compatible notifier list.
//!
//! Matches the endpoints registered in
//! `vendor/moonraker/moonraker/components/notifier.py` (Notifier):
//!
//!   GET  /server/notifiers/list   → server.notifiers.list
//!   POST /debug/notifiers/test    → debug.notifiers.test (debug only)
//!
//! `[notifier <name>]` sections fill the list. Sending needs apprise, which
//! phobos does not link: the test endpoint fails with `AppriseNotAvailable`
//! for a configured name and 404 for an unknown one.
//!
//! Notifier record shape (NotifierInstance.as_dict): name, url, title, body,
//! body_format (null when unset), events (the configured list), attach (null).

const std = @import("std");
const registry = @import("../server/registry.zig");

const Registry = registry.Registry;

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

/// One `[notifier <name>]` section as read from the config. Slices are borrowed.
pub const Config = struct {
    name: []const u8,
    url: []const u8,
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
    body_format: ?[]const u8 = null,
    /// The raw `events` option: a comma-separated list.
    events: []const u8,
};

pub const Notifier = struct {
    name: []const u8,
    url: []const u8,
    title: ?[]const u8,
    body: ?[]const u8,
    body_format: ?[]const u8,
    events: []const []const u8,
};

pub const NotifierCtx = struct {
    /// Configured records; every slice lives in `arena`.
    notifiers: []const Notifier = &.{},
    arena: std.heap.ArenaAllocator.State = .{},

    pub fn deinit(self: *NotifierCtx, alloc: std.mem.Allocator) void {
        self.arena.promote(alloc).deinit();
        self.* = .{};
    }

    /// Append one config record, copying its strings. `events` splits like
    /// Moonraker's `getlist(separator=",")`: items are trimmed and empty ones
    /// dropped. On error the list is unchanged.
    pub fn addNotifier(self: *NotifierCtx, alloc: std.mem.Allocator, src: Config) !void {
        var arena = self.arena.promote(alloc);
        defer self.arena = arena.state;
        const a = arena.allocator();
        var events: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, src.events, ',');
        while (it.next()) |raw| {
            const event = std.mem.trim(u8, raw, &std.ascii.whitespace);
            if (event.len > 0) try events.append(a, try a.dupe(u8, event));
        }
        const grown = try a.alloc(Notifier, self.notifiers.len + 1);
        @memcpy(grown[0..self.notifiers.len], self.notifiers);
        grown[self.notifiers.len] = .{
            .name = try a.dupe(u8, src.name),
            .url = try a.dupe(u8, src.url),
            .title = if (src.title) |s| try a.dupe(u8, s) else null,
            .body = if (src.body) |s| try a.dupe(u8, s) else null,
            .body_format = if (src.body_format) |s| try a.dupe(u8, s) else null,
            .events = events.items,
        };
        self.notifiers = grown;
    }
};

fn optString(s: ?[]const u8) std.json.Value {
    return if (s) |v| .{ .string = v } else .null;
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /server/notifiers/list → {"notifiers": [...]}
pub fn handleNotifierList(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *NotifierCtx = @ptrCast(@alignCast(ctx_ptr));
    var arr: std.json.Array = .init(alloc);
    for (ctx.notifiers) |n| {
        var events: std.json.Array = .init(alloc);
        for (n.events) |e| try events.append(.{ .string = e });
        var obj: std.json.ObjectMap = .empty;
        try obj.put(alloc, "name", .{ .string = n.name });
        try obj.put(alloc, "url", .{ .string = n.url });
        try obj.put(alloc, "title", optString(n.title));
        try obj.put(alloc, "body", optString(n.body));
        try obj.put(alloc, "body_format", optString(n.body_format));
        try obj.put(alloc, "events", .{ .array = events });
        try obj.put(alloc, "attach", .null);
        try arr.append(.{ .object = obj });
    }
    var result: std.json.ObjectMap = .empty;
    try result.put(alloc, "notifiers", .{ .array = arr });
    return .{ .object = result };
}

/// POST /debug/notifiers/test. Moonraker sends a test notification through
/// apprise; phobos returns `AppriseNotAvailable` for a configured name and
/// `NotFound` (404) otherwise.
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

test "handleNotifierList: records keep strings, null unset options and the events list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = NotifierCtx{};
    defer ctx.deinit(testing.allocator);
    try ctx.addNotifier(testing.allocator, .{
        .name = "desk",
        .url = "tgram://token/chat",
        .title = "hi",
        .body = "there",
        .body_format = "markdown",
        .events = " complete, error ,, ",
    });
    try ctx.addNotifier(testing.allocator, .{ .name = "bare", .url = "json://h", .events = "*" });
    const result = try handleNotifierList(@ptrCast(&ctx), .null, arena.allocator());
    const items = result.object.get("notifiers").?.array.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    const desk = items[0].object;
    try testing.expectEqualStrings("desk", desk.get("name").?.string);
    try testing.expectEqualStrings("tgram://token/chat", desk.get("url").?.string);
    try testing.expectEqualStrings("hi", desk.get("title").?.string);
    try testing.expectEqualStrings("there", desk.get("body").?.string);
    try testing.expectEqualStrings("markdown", desk.get("body_format").?.string);
    const events = desk.get("events").?.array.items;
    try testing.expectEqual(@as(usize, 2), events.len);
    try testing.expectEqualStrings("complete", events[0].string);
    try testing.expectEqualStrings("error", events[1].string);
    try testing.expect(desk.get("attach").? == .null);
    const bare = items[1].object;
    try testing.expect(bare.get("title").? == .null);
    try testing.expect(bare.get("body").? == .null);
    try testing.expect(bare.get("body_format").? == .null);
    try testing.expectEqualStrings("*", bare.get("events").?.array.items[0].string);
}

test "fuzz addNotifier: arbitrary events never leak and never keep empty items" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [32]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var ctx = NotifierCtx{};
            defer ctx.deinit(testing.allocator);
            try ctx.addNotifier(testing.allocator, .{ .name = "n", .url = "u", .events = &buf });
            for (ctx.notifiers[0].events) |e| try testing.expect(e.len > 0);
        }
    }.run, .{});
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
    var ctx = NotifierCtx{};
    defer ctx.deinit(testing.allocator);
    try ctx.addNotifier(testing.allocator, .{ .name = "telegram", .url = "tgram://t/c", .events = "complete" });
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
