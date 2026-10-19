//! server.extensions.* and connection.* API component — Moonraker-compatible
//! extension/agent management.
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
//! Response shapes:
//!   list    → {"agents": [...client_data dicts...]}
//!   request → result from the agent (pass-through)
//!   register_remote_method → "ok"
//!   send_event             → "ok"
//!
//! Without registered agents:
//!   list    → {"agents": []}
//!   request → error.AgentNotConnected
//!
//! NOTE: Real agent connections come in over Unix sockets / WebSockets.
//! The ExtensionsCtx keeps a simple in-memory agent registry. Agent
//! registration happens via the live WebSocket connection (when an agent
//! calls server.connection.identify with type="agent"). The connection.*
//! methods are registered as WS-only (TransportType.WEBSOCKET) to match
//! extensions.py which uses transports=TransportType.WEBSOCKET.

const std = @import("std");
const registry = @import("../server/registry.zig");

const Registry = registry.Registry;

// ---------------------------------------------------------------------------
// Agent client data shape (matches BaseRemoteConnection.client_data)
// ---------------------------------------------------------------------------

pub const AgentData = struct {
    name: []const u8,
    type: []const u8,
    version: []const u8,
    url: []const u8,

    fn dupe(self: AgentData, alloc: std.mem.Allocator) !AgentData {
        var owned = self;
        inline for (comptime std.meta.fieldNames(AgentData)) |field| @field(owned, field) = "";
        errdefer owned.deinit(alloc);
        inline for (comptime std.meta.fieldNames(AgentData)) |field| @field(owned, field) = try alloc.dupe(u8, @field(self, field));
        return owned;
    }

    fn deinit(self: *AgentData, alloc: std.mem.Allocator) void {
        inline for (comptime std.meta.fieldNames(AgentData)) |field| alloc.free(@field(self, field));
    }

    pub fn asJson(self: *const AgentData, alloc: std.mem.Allocator) !std.json.Value {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(alloc, "name", .{ .string = self.name });
        try obj.put(alloc, "type", .{ .string = self.type });
        try obj.put(alloc, "version", .{ .string = self.version });
        try obj.put(alloc, "url", .{ .string = self.url });
        return .{ .object = obj };
    }
};

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

pub const ExtensionsCtx = struct {
    /// GPA for owned agent entries.
    gpa: std.mem.Allocator,
    /// Registered agents: name → AgentData.
    agents: std.StringHashMapUnmanaged(AgentData),

    pub fn init(alloc: std.mem.Allocator) ExtensionsCtx {
        return .{ .gpa = alloc, .agents = .{} };
    }

    pub fn deinit(self: *ExtensionsCtx) void {
        var it = self.agents.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(self.gpa);
        }
        self.agents.deinit(self.gpa);
    }

    /// Register an agent (called when a WS connection identifies as agent type).
    pub fn registerAgent(self: *ExtensionsCtx, data: AgentData) !void {
        if (self.agents.contains(data.name)) return error.AgentAlreadyRegistered;
        const key = try self.gpa.dupe(u8, data.name);
        errdefer self.gpa.free(key);
        var owned = try data.dupe(self.gpa);
        errdefer owned.deinit(self.gpa);
        try self.agents.put(self.gpa, key, owned);
    }

    /// Remove an agent by name.
    pub fn removeAgent(self: *ExtensionsCtx, name: []const u8) void {
        if (self.agents.fetchRemove(name)) |kv| {
            self.gpa.free(kv.key);
            var old = kv.value;
            old.deinit(self.gpa);
        }
    }
};

// ---------------------------------------------------------------------------
// Parameter helpers
// ---------------------------------------------------------------------------

fn getOptStr(params: std.json.Value, field: []const u8) ?[]const u8 {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return null;
            return switch (v) {
                .string => |s| s,
                else => null,
            };
        },
        else => return null,
    }
}

fn getStr(params: std.json.Value, field: []const u8) error{InvalidParams}![]const u8 {
    return getOptStr(params, field) orelse error.InvalidParams;
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /server/extensions/list → {"agents": [...]}
/// Returns all currently registered agents.
pub fn handleList(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *ExtensionsCtx = @ptrCast(@alignCast(ctx));

    var agents_arr: std.json.Array = .init(alloc);
    var it = c.agents.iterator();
    while (it.next()) |e| {
        const agent_json = try e.value_ptr.asJson(alloc);
        try agents_arr.append(agent_json);
    }

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "agents", .{ .array = agents_arr });
    return .{ .object = obj };
}

/// POST /server/extensions/request → call a method on a connected agent
///
/// params: agent (str, required), method (str, required),
///         arguments (object or array, optional)
///
/// NOTE: No real agent RPC is possible without a live WS connection.
/// Returns AgentNotConnected if the named agent is absent.
pub fn handleRequest(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    _ = alloc;
    const c: *ExtensionsCtx = @ptrCast(@alignCast(ctx));

    const agent_name = try getStr(params, "agent");
    const method_name = try getStr(params, "method");
    _ = method_name;

    if (!c.agents.contains(agent_name)) return error.AgentNotConnected;

    // Agent is registered but in this slice we cannot perform actual RPC
    // without a live WS connection and a pending response future.
    // Return a stub error that indicates the limitation.
    return error.AgentRpcNotSupported;
}

/// POST /connection/register_remote_method (WS-only)
///
/// Registers a remote method on the agent's connection. In phobos this is a
/// stub — without a live klippy connection there is nothing to register with.
/// Returns "ok" to satisfy the Moonraker wire contract.
pub fn handleRegisterRemoteMethod(_: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    // Validate required param
    const method_name = try getStr(params, "method_name");
    _ = method_name;

    // NOTE: Real implementation would register `method_name` with the
    // klippy_connection for the calling WS connection. Not implemented
    // in this slice (no klippy integration).
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "result", .{ .string = "ok" });
    return .{ .object = obj };
}

/// POST /connection/send_event (WS-only)
///
/// Sends an agent event to connected clients. Requires caller to be of
/// agent type. phobos stub: validates params and returns "ok".
pub fn handleSendEvent(_: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const event_name = try getStr(params, "event");
    // Reserved event names per extensions.py
    if (std.mem.eql(u8, event_name, "connected") or
        std.mem.eql(u8, event_name, "disconnected"))
    {
        return error.ReservedEvent;
    }

    // NOTE: Real implementation would fan-out agent_event notification to
    // all connected WS clients. Not implemented in this slice.
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "result", .{ .string = "ok" });
    return .{ .object = obj };
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn registerExtensions(reg: *Registry, ctx: *ExtensionsCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    // GET /server/extensions/list → "server.extensions.list"
    try reg.registerEndpoint(
        .{ .path = "/server/extensions/list", .methods = &.{.GET} },
        c,
        handleList,
    );

    // POST /server/extensions/request → "server.extensions.request"
    try reg.registerEndpoint(
        .{ .path = "/server/extensions/request", .methods = &.{.POST} },
        c,
        handleRequest,
    );

    // WS-only: /connection/register_remote_method
    // extensions.py: transports=TransportType.WEBSOCKET — no HTTP transport.
    try reg.registerEndpoint(
        .{
            .path = "/connection/register_remote_method",
            .methods = &.{.POST},
            .transports = &.{.WEBSOCKET},
        },
        c,
        handleRegisterRemoteMethod,
    );

    // WS-only: /connection/send_event
    try reg.registerEndpoint(
        .{
            .path = "/connection/send_event",
            .methods = &.{.POST},
            .transports = &.{.WEBSOCKET},
        },
        c,
        handleSendEvent,
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

test "handleList: empty → {agents: []}" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = ExtensionsCtx.init(a);
    defer ctx.deinit();

    const result = try handleList(@ptrCast(&ctx), .null, a);
    const agents = result.object.get("agents").?.array;
    try testing.expectEqual(@as(usize, 0), agents.items.len);
}

test "handleList: with registered agent returns correct shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = ExtensionsCtx.init(a);
    defer ctx.deinit();

    try ctx.registerAgent(.{
        .name = "test_agent",
        .type = "agent",
        .version = "1.0.0",
        .url = "http://localhost:9000",
    });

    const result = try handleList(@ptrCast(&ctx), .null, a);
    const agents = result.object.get("agents").?.array;
    try testing.expectEqual(@as(usize, 1), agents.items.len);
    try testing.expectEqualStrings("test_agent", agents.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("agent", agents.items[0].object.get("type").?.string);
}

test "handleRequest: missing agent → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = ExtensionsCtx.init(a);
    defer ctx.deinit();

    try testing.expectError(error.InvalidParams, handleRequest(@ptrCast(&ctx), .null, a));
}

test "handleRequest: agent not connected → AgentNotConnected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = ExtensionsCtx.init(a);
    defer ctx.deinit();

    const params = try mkParams(a, "{\"agent\": \"missing\", \"method\": \"do_thing\"}");
    try testing.expectError(error.AgentNotConnected, handleRequest(@ptrCast(&ctx), params, a));
}

test "handleRequest: agent registered but RPC stub" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = ExtensionsCtx.init(a);
    defer ctx.deinit();

    try ctx.registerAgent(.{
        .name = "myagent",
        .type = "agent",
        .version = "0.1",
        .url = "",
    });

    const params = try mkParams(a, "{\"agent\": \"myagent\", \"method\": \"ping\"}");
    try testing.expectError(error.AgentRpcNotSupported, handleRequest(@ptrCast(&ctx), params, a));
}

test "handleRegisterRemoteMethod: missing method_name → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = ExtensionsCtx.init(a);
    defer ctx.deinit();

    try testing.expectError(error.InvalidParams, handleRegisterRemoteMethod(@ptrCast(&ctx), .null, a));
}

test "handleRegisterRemoteMethod: valid → returns ok" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = ExtensionsCtx.init(a);
    defer ctx.deinit();

    const params = try mkParams(a, "{\"method_name\": \"my_remote_fn\"}");
    const result = try handleRegisterRemoteMethod(@ptrCast(&ctx), params, a);
    try testing.expectEqualStrings("ok", result.object.get("result").?.string);
}

test "handleSendEvent: missing event → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = ExtensionsCtx.init(a);
    defer ctx.deinit();

    try testing.expectError(error.InvalidParams, handleSendEvent(@ptrCast(&ctx), .null, a));
}

test "handleSendEvent: reserved event name → ReservedEvent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = ExtensionsCtx.init(a);
    defer ctx.deinit();

    for ([_][]const u8{ "connected", "disconnected" }) |ev| {
        var buf: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{{\"event\": \"{s}\"}}", .{ev});
        const params = try mkParams(a, s);
        try testing.expectError(error.ReservedEvent, handleSendEvent(@ptrCast(&ctx), params, a));
    }
}

test "handleSendEvent: valid event → returns ok" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = ExtensionsCtx.init(a);
    defer ctx.deinit();

    const params = try mkParams(a, "{\"event\": \"my_custom_event\"}");
    const result = try handleSendEvent(@ptrCast(&ctx), params, a);
    try testing.expectEqualStrings("ok", result.object.get("result").?.string);
}

test "registerExtensions: wires routes and JSON-RPC methods" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");

    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var ctx = ExtensionsCtx.init(alloc);
    defer ctx.deinit();

    try registerExtensions(&reg, &ctx);

    // HTTP routes
    try testing.expect(reg.lookup(.GET, "/server/extensions/list") != null);
    try testing.expect(reg.lookup(.POST, "/server/extensions/request") != null);
    // WS-only routes are still registered as HTTP routes (for path lookup)
    try testing.expect(reg.lookup(.POST, "/connection/register_remote_method") != null);
    try testing.expect(reg.lookup(.POST, "/connection/send_event") != null);

    // JSON-RPC methods: server.extensions.*
    try testing.expect(d.methods.get("server.extensions.list") != null);
    try testing.expect(d.methods.get("server.extensions.request") != null);
    // WS-only methods: connection.*
    try testing.expect(d.methods.get("connection.register_remote_method") != null);
    try testing.expect(d.methods.get("connection.send_event") != null);
}

test "ExtensionsCtx: registerAgent duplicate → error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = ExtensionsCtx.init(a);
    defer ctx.deinit();

    try ctx.registerAgent(.{
        .name = "ag1",
        .type = "agent",
        .version = "1.0",
        .url = "",
    });
    try testing.expectError(error.AgentAlreadyRegistered, ctx.registerAgent(.{
        .name = "ag1",
        .type = "agent",
        .version = "1.0",
        .url = "",
    }));
}

test "ExtensionsCtx: removeAgent removes from list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = ExtensionsCtx.init(a);
    defer ctx.deinit();

    try ctx.registerAgent(.{
        .name = "ag2",
        .type = "agent",
        .version = "1.0",
        .url = "",
    });
    ctx.removeAgent("ag2");
    try testing.expectEqual(@as(usize, 0), ctx.agents.count());
}

// --- Fuzz tests ---

test "fuzz handleList: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = ExtensionsCtx.init(a);
            defer ctx.deinit();
            var buf: [4]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = handleList(@ptrCast(&ctx), .null, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleRequest: never panics on arbitrary params" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = ExtensionsCtx.init(a);
            defer ctx.deinit();
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"agent\": \"x\", \"method\": \"m\"}",
                "{\"agent\": \"x\"}",
                "{\"method\": \"m\"}",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            _ = handleRequest(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleSendEvent: never panics on arbitrary params" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = ExtensionsCtx.init(a);
            defer ctx.deinit();
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"event\": \"connected\"}",
                "{\"event\": \"custom\"}",
                "{\"event\": \"disconnected\"}",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            _ = handleSendEvent(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleRegisterRemoteMethod: never panics on arbitrary params" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = ExtensionsCtx.init(a);
            defer ctx.deinit();
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"method_name\": \"test.method\"}",
                "{\"method_name\": \"\"}",
                "{\"method_name\": 42}",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            _ = handleRegisterRemoteMethod(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "agents free partial fields on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(alloc: std.mem.Allocator) !void {
            var ctx = ExtensionsCtx.init(alloc);
            defer ctx.deinit();
            try ctx.registerAgent(.{ .name = "agent", .type = "agent", .version = "1", .url = "http://localhost" });
            ctx.removeAgent("agent");
        }
    }.check, .{});
}
