//! server.extensions.* and connection.* API component — Moonraker-compatible
//! extension endpoints.
//!
//! Matches the endpoints registered in
//! `vendor/moonraker/moonraker/components/extensions.py` (ExtensionManager):
//!
//!   GET  /server/extensions/list    → server.extensions.list
//!   POST /server/extensions/request → server.extensions.request
//!
//! WS-only (connection-bound) endpoints:
//!   POST /connection/register_remote_method → connection.register_remote_method
//!   POST /connection/send_event             → connection.send_event
//!
//! Phobos has no agent connections: `server.connection.identify` does not
//! register agents, so the list is always `{"agents": []}` and every request
//! fails with AgentNotConnected. register_remote_method and send_event
//! validate their params and return Moonraker's `"ok"` without registering a
//! Klippy method or emitting `notify_agent_event`. See TODO.md.

const std = @import("std");
const webreq = @import("../json/params.zig");
const registry = @import("../server/registry.zig");

const Registry = registry.Registry;

/// Stateless: there is no agent registry.
pub const ExtensionsCtx = struct {};

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /server/extensions/list → {"agents": []}
pub fn handleList(_: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "agents", .{ .array = .init(alloc) });
    return .{ .object = obj };
}

/// POST /server/extensions/request. params: agent, method (str, required).
/// No agent is ever connected.
pub fn handleRequest(_: *anyopaque, params: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    _ = try webreq.required([]const u8, params, "agent");
    _ = try webreq.required([]const u8, params, "method");
    return error.AgentNotConnected;
}

/// POST /connection/register_remote_method (WS-only) → "ok".
pub fn handleRegisterRemoteMethod(_: *anyopaque, params: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    _ = try webreq.required([]const u8, params, "method_name");
    return .{ .string = "ok" };
}

/// POST /connection/send_event (WS-only) → "ok". "connected" and
/// "disconnected" are reserved (extensions.py).
pub fn handleSendEvent(_: *anyopaque, params: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    const event_name = try webreq.required([]const u8, params, "event");
    if (std.mem.eql(u8, event_name, "connected") or std.mem.eql(u8, event_name, "disconnected")) {
        return error.ReservedEvent;
    }
    return .{ .string = "ok" };
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn registerExtensions(reg: *Registry, ctx: *ExtensionsCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    try reg.registerEndpoint(.{ .path = "/server/extensions/list", .methods = &.{.GET} }, c, handleList);
    try reg.registerEndpoint(.{ .path = "/server/extensions/request", .methods = &.{.POST} }, c, handleRequest);
    // extensions.py: transports=TransportType.WEBSOCKET, no HTTP transport.
    try reg.registerEndpoint(.{
        .path = "/connection/register_remote_method",
        .methods = &.{.POST},
        .transports = &.{.WEBSOCKET},
    }, c, handleRegisterRemoteMethod);
    try reg.registerEndpoint(.{
        .path = "/connection/send_event",
        .methods = &.{.POST},
        .transports = &.{.WEBSOCKET},
    }, c, handleSendEvent);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn mkParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    return p.value;
}

test "handleList: {agents: []}" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx: ExtensionsCtx = .{};
    const result = try handleList(@ptrCast(&ctx), .null, a);
    try testing.expectEqual(@as(usize, 0), result.object.get("agents").?.array.items.len);
}

test "handleRequest: missing params → InvalidParams, otherwise AgentNotConnected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx: ExtensionsCtx = .{};
    try testing.expectError(error.InvalidParams, handleRequest(@ptrCast(&ctx), .null, a));
    try testing.expectError(error.InvalidParams, handleRequest(@ptrCast(&ctx), try mkParams(a, "{\"agent\": \"x\"}"), a));
    const params = try mkParams(a, "{\"agent\": \"missing\", \"method\": \"do_thing\"}");
    try testing.expectError(error.AgentNotConnected, handleRequest(@ptrCast(&ctx), params, a));
}

test "handleRegisterRemoteMethod: result is the string ok" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx: ExtensionsCtx = .{};
    try testing.expectError(error.InvalidParams, handleRegisterRemoteMethod(@ptrCast(&ctx), .null, a));
    const result = try handleRegisterRemoteMethod(@ptrCast(&ctx), try mkParams(a, "{\"method_name\": \"my_remote_fn\"}"), a);
    try testing.expectEqualStrings("ok", result.string);
}

test "handleSendEvent: reserved names fail, others return the string ok" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx: ExtensionsCtx = .{};
    try testing.expectError(error.InvalidParams, handleSendEvent(@ptrCast(&ctx), .null, a));
    for ([_][]const u8{ "{\"event\": \"connected\"}", "{\"event\": \"disconnected\"}" }) |s| {
        try testing.expectError(error.ReservedEvent, handleSendEvent(@ptrCast(&ctx), try mkParams(a, s), a));
    }
    const result = try handleSendEvent(@ptrCast(&ctx), try mkParams(a, "{\"event\": \"my_custom_event\"}"), a);
    try testing.expectEqualStrings("ok", result.string);
}

test "registerExtensions: wires routes and JSON-RPC methods" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");

    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var ctx: ExtensionsCtx = .{};
    try registerExtensions(&reg, &ctx);

    try testing.expect(reg.lookup(.GET, "/server/extensions/list") != null);
    try testing.expect(reg.lookup(.POST, "/server/extensions/request") != null);
    try testing.expect(reg.lookup(.POST, "/connection/register_remote_method") != null);
    try testing.expect(reg.lookup(.POST, "/connection/send_event") != null);

    try testing.expect(d.methods.get("server.extensions.list") != null);
    try testing.expect(d.methods.get("server.extensions.request") != null);
    try testing.expect(d.methods.get("connection.register_remote_method") != null);
    try testing.expect(d.methods.get("connection.send_event") != null);
}

test "connection methods return a bare ok result over JSON-RPC" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");
    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();
    var ctx: ExtensionsCtx = .{};
    try registerExtensions(&reg, &ctx);
    const req = try std.json.parseFromSlice(std.json.Value, alloc, "{\"jsonrpc\":\"2.0\",\"method\":\"connection.send_event\",\"params\":{\"event\":\"e\"},\"id\":1}", .{});
    defer req.deinit();
    // connection.* methods are WebSocket-only.
    const out = try d.handleParsedRoot(.{ .transport = .WEBSOCKET }, req.value, alloc);
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"result\":\"ok\"") != null);
}

// --- Fuzz tests ---

test "fuzz extensions handlers: arbitrary params never panic" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx: ExtensionsCtx = .{};
            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"agent\": \"x\", \"method\": \"m\"}",
                "{\"agent\": \"x\"}",
                "{\"event\": \"connected\"}",
                "{\"event\": \"custom\"}",
                "{\"method_name\": \"test.method\"}",
                "{\"method_name\": 42}",
            };
            const p = try std.json.parseFromSlice(std.json.Value, a, strs[smith.value(u8) % strs.len], .{});
            const handlers = [_]registry.HandlerFn{ handleList, handleRequest, handleRegisterRemoteMethod, handleSendEvent };
            const r = handlers[smith.value(u8) % handlers.len](@ptrCast(&ctx), p.value, a) catch return;
            try testing.expect(r == .object or r == .string);
        }
    }.run, .{});
}
