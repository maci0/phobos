//! Agent registration, bidirectional RPC and Klippy remote methods.
const std = @import("std");
const Io = std.Io;
const webreq = @import("../json/params.zig");
const jv = @import("../json/value.zig");
const jsonrpc = @import("../jsonrpc.zig");
const registry = @import("../server/registry.zig");
const connections = @import("../server/connections.zig");
const notify = @import("../server/notify.zig");
const KlippyCtx = @import("klippy_connection.zig").KlippyCtx;

pub const max_agent_methods = 256;
pub const max_agents = 256;
pub const max_agent_name_len = 256;
pub const max_pending_requests = 32;
const request_timeout: Io.Duration = .fromSeconds(20);

const Waiter = struct {
    connection_id: u64,
    ready: Io.Semaphore = .{},
    payload: ?[]u8 = null,
    failed: bool = false,
};

pub const ExtensionsCtx = struct {
    alloc: std.mem.Allocator = std.heap.smp_allocator,
    bus: ?*notify.NotifyBus = null,
    io: ?Io = null,
    klippy: ?*KlippyCtx = null,
    /// Agent and method names are owned here. Core guards both maps.
    agents: std.StringArrayHashMapUnmanaged(u64) = .empty,
    methods: std.StringHashMapUnmanaged(u64) = .empty,
    pending_mutex: Io.Mutex = .init,
    pending: std.AutoHashMapUnmanaged(u64, *Waiter) = .empty,
    next_id: u64 = 0,
    timeout: Io.Duration = request_timeout,

    pub fn deinit(self: *ExtensionsCtx) void {
        std.debug.assert(self.pending.count() == 0);
        for (self.agents.keys()) |key| self.alloc.free(key);
        self.agents.deinit(self.alloc);
        var methods = self.methods.keyIterator();
        while (methods.next()) |key| self.alloc.free(key.*);
        self.methods.deinit(self.alloc);
        self.pending.deinit(self.alloc);
    }

    /// Called under Core after identify copied the client metadata.
    pub fn registerAgent(self: *ExtensionsCtx, conn: *connections.Connection, alloc: std.mem.Allocator) !void {
        if (!std.mem.eql(u8, conn.client.type, "agent")) return error.AgentMethodsOnly;
        if (conn.client.name.len == 0 or conn.client.name.len > max_agent_name_len) return error.InvalidParams;
        if (self.agents.contains(conn.client.name)) return error.AgentDuplicate;
        if (self.agents.count() >= max_agents) return error.AgentCapacity;
        const key = try self.alloc.dupe(u8, conn.client.name);
        errdefer self.alloc.free(key);
        try self.agents.put(self.alloc, key, conn.id);
        errdefer _ = self.agents.orderedRemove(key);
        try self.event(conn, "connected", try clientJson(alloc, conn.client), alloc);
    }

    /// Called under Core before the session's registry entry is removed.
    pub fn removeAgent(self: *ExtensionsCtx, conn: *connections.Connection) !void {
        const io = self.io orelse return;
        self.pending_mutex.lockUncancelable(io);
        var pending = self.pending.valueIterator();
        while (pending.next()) |entry| if (entry.*.connection_id == conn.id and entry.*.payload == null and !entry.*.failed) {
            entry.*.failed = true;
            entry.*.ready.post(io);
        };
        self.pending_mutex.unlock(io);
        while (true) {
            var it = self.methods.iterator();
            const key = while (it.next()) |entry| {
                if (entry.value_ptr.* == conn.id) break entry.key_ptr.*;
            } else break;
            if (self.klippy) |klippy| klippy.removeAgentMethod(io, key, conn.id);
            _ = self.methods.remove(key);
            self.alloc.free(key);
        }
        if (self.agents.get(conn.client.name)) |id| if (id == conn.id) {
            const removed = self.agents.fetchOrderedRemove(conn.client.name).?;
            self.alloc.free(removed.key);
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            try self.event(conn, "disconnected", null, arena.allocator());
        };
    }

    fn event(self: *ExtensionsCtx, conn: *connections.Connection, name: []const u8, data: ?std.json.Value, alloc: std.mem.Allocator) !void {
        const io = self.io orelse return;
        const bus = self.bus orelse return;
        var event_data: std.json.ObjectMap = .empty;
        try event_data.put(alloc, "agent", .{ .string = conn.client.name });
        try event_data.put(alloc, "event", .{ .string = name });
        if (data) |value| if (value != .null) try event_data.put(alloc, "data", value);
        const frame = try std.json.Stringify.valueAlloc(alloc, .{ .jsonrpc = "2.0", .method = notify.names.agent_event, .params = [_]std.json.Value{.{ .object = event_data }} }, .{});
        defer alloc.free(frame);
        bus.conns.broadcastExcept(io, alloc, frame, null, null, conn.id);
    }

    /// Response correlation runs on the reader, independently of Core.
    pub fn resolveResponse(self: *ExtensionsCtx, conn: *connections.Connection, root: std.json.Value) void {
        const io = self.io orelse return;
        if (conn.need_auth.load(.acquire) or root != .object or root.object.contains("method")) return;
        const id = root.object.get("id") orelse return;
        const version = root.object.get("jsonrpc") orelse return;
        if (version != .string or !std.mem.eql(u8, version.string, "2.0") or id != .integer or id.integer < 0) return;
        if (jv.exceedsDepth(root, jv.max_value_depth)) return;
        self.pending_mutex.lockUncancelable(io);
        defer self.pending_mutex.unlock(io);
        const waiter = self.pending.get(@intCast(id.integer)) orelse return;
        if (waiter.connection_id != conn.id or waiter.payload != null or waiter.failed) return;
        waiter.payload = std.json.Stringify.valueAlloc(self.alloc, root, .{}) catch null;
        waiter.ready.post(io);
    }

    /// Klippy invokes this under Core; method ownership is removed on close.
    pub fn forwardRemote(self: *ExtensionsCtx, method: []const u8, params: std.json.Value, alloc: std.mem.Allocator) !bool {
        const id = self.methods.get(method) orelse return false;
        const io = self.io orelse return false;
        const conns = (self.bus orelse return false).conns;
        const conn = conns.pin(io, id) catch return true;
        defer conns.unpin(io, conn);
        if (conn.need_auth.load(.acquire)) return true;
        const frame = try std.json.Stringify.valueAlloc(alloc, .{ .jsonrpc = "2.0", .method = method, .params = params }, .{});
        defer alloc.free(frame);
        try conns.writeFrame(io, conn, frame);
        return true;
    }

    fn connection(self: *ExtensionsCtx, params: std.json.Value) !*connections.Connection {
        const raw_id = try webreq.required(i64, params, jsonrpc.connection_key);
        if (raw_id < 0) return error.NoAgentConnection;
        const id: u64 = @intCast(raw_id);
        const io = self.io orelse return error.NoAgentConnection;
        return (self.bus orelse return error.NoAgentConnection).conns.pin(io, id) catch error.NoAgentConnection;
    }

    fn unpin(self: *ExtensionsCtx, conn: *connections.Connection) void {
        self.bus.?.conns.unpin(self.io.?, conn);
    }
};

fn clientJson(alloc: std.mem.Allocator, client: connections.ClientData) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    inline for (.{ "name", "version", "type", "url" }) |key| try object.put(alloc, key, .{ .string = @field(client, key) });
    return .{ .object = object };
}

pub fn handleList(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const self: *ExtensionsCtx = @ptrCast(@alignCast(ctx));
    var agents: std.json.Array = .init(alloc);
    if (self.io) |io| {
        const conns = self.bus.?.conns;
        for (self.agents.values()) |id| {
            const conn = conns.pin(io, id) catch continue;
            defer conns.unpin(io, conn);
            try agents.append(try clientJson(alloc, conn.client));
        }
    }
    var object: std.json.ObjectMap = .empty;
    try object.put(alloc, "agents", .{ .array = agents });
    return .{ .object = object };
}

pub fn handleRequest(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const self: *ExtensionsCtx = @ptrCast(@alignCast(ctx));
    const name = try webreq.required([]const u8, params, "agent");
    const method = try webreq.required([]const u8, params, "method");
    const arguments = (try webreq.optional(std.json.Value, params, "arguments")) orelse .null;
    if (arguments != .null and arguments != .object and arguments != .array) return error.AgentArgumentsInvalid;
    const connection_id = self.agents.get(name) orelse return error.AgentNotConnected;
    const io = self.io orelse return error.AgentNotConnected;
    const bus = self.bus.?;
    const conn = bus.conns.pin(io, connection_id) catch return error.AgentNotConnected;
    defer bus.conns.unpin(io, conn);
    if (conn.need_auth.load(.acquire)) return error.AgentNotConnected;
    var waiter: Waiter = .{ .connection_id = connection_id };
    const id = blk: {
        self.pending_mutex.lockUncancelable(io);
        defer self.pending_mutex.unlock(io);
        if (self.pending.count() >= max_pending_requests) return error.AgentCapacity;
        self.next_id += 1;
        try self.pending.put(self.alloc, self.next_id, &waiter);
        break :blk self.next_id;
    };
    defer {
        self.pending_mutex.lockUncancelable(io);
        _ = self.pending.remove(id);
        self.pending_mutex.unlock(io);
        if (waiter.payload) |payload| self.alloc.free(payload);
    }
    var request: std.json.ObjectMap = .empty;
    try request.put(alloc, "jsonrpc", .{ .string = "2.0" });
    try request.put(alloc, "method", .{ .string = method });
    try request.put(alloc, "id", .{ .integer = @intCast(id) });
    if (arguments == .object and arguments.object.count() != 0 or arguments == .array and arguments.array.items.len != 0) try request.put(alloc, "params", arguments);
    const frame = try std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = request }, .{});
    defer alloc.free(frame);
    const deadline: Io.Timeout = .{ .deadline = .fromNow(io, .{ .raw = self.timeout, .clock = .awake }) };
    {
        bus.core.unlock(io);
        defer bus.core.lock(io);
        try bus.conns.writeFrame(io, conn, frame);
        waiter.ready.waitTimeout(io, deadline) catch |err| switch (err) {
            error.Timeout => return error.AgentRequestTimedOut,
            error.Canceled => return error.Canceled,
        };
    }
    if (waiter.failed) return error.AgentDisconnected;
    const payload = waiter.payload orelse return error.OutOfMemory;
    const response = try std.json.parseFromSliceLeaky(std.json.Value, alloc, payload, .{ .allocate = .alloc_always });
    if (response.object.get("result")) |result| if (result != .null) return result;
    const message = try std.fmt.allocPrint(alloc, "Agent {s} RPC error", .{name});
    try jsonrpc.setErrorReply(alloc, params, .failed_dependency, message);
    const carrier = params.object.getPtr(jsonrpc.method_key).?;
    try carrier.object.put(alloc, "data", response.object.get("error") orelse .null);
    return error.UpstreamRequestFailed;
}

pub fn handleRegisterRemoteMethod(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const self: *ExtensionsCtx = @ptrCast(@alignCast(ctx));
    const method = try webreq.required([]const u8, params, "method_name");
    if (method.len == 0 or method.len > max_agent_name_len) return error.InvalidParams;
    const conn = self.connection(params) catch return error.NoAgentConnection;
    defer self.unpin(conn);
    if (!std.mem.eql(u8, conn.client.type, "agent")) return error.AgentMethodsOnly;
    if (self.agents.get(conn.client.name) != conn.id) return error.NoAgentConnection;
    if (self.methods.contains(method)) return error.AgentMethodDuplicate;
    if (self.methods.count() >= max_agent_methods) return error.AgentCapacity;
    const klippy = self.klippy orelse return error.NotReady;
    const key = try self.alloc.dupe(u8, method);
    self.methods.put(self.alloc, key, conn.id) catch |err| {
        self.alloc.free(key);
        return err;
    };
    klippy.addAgentMethod(self.io.?, method, conn.id, alloc) catch |err| {
        if (self.methods.get(method)) |owner| if (owner == conn.id) {
            const removed = self.methods.fetchRemove(method).?;
            self.alloc.free(removed.key);
        };
        return err;
    };
    return .{ .string = "ok" };
}

pub fn handleSendEvent(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const self: *ExtensionsCtx = @ptrCast(@alignCast(ctx));
    const conn = self.connection(params) catch return error.NoAgentConnection;
    defer self.unpin(conn);
    if (!std.mem.eql(u8, conn.client.type, "agent")) return error.AgentEventsOnly;
    if (self.agents.get(conn.client.name) != conn.id) return error.NoAgentConnection;
    const event = try webreq.required([]const u8, params, "event");
    if (std.mem.eql(u8, event, "connected") or std.mem.eql(u8, event, "disconnected")) return error.ReservedEvent;
    try self.event(conn, event, (try webreq.optional(std.json.Value, params, "data")) orelse .null, alloc);
    return .{ .string = "ok" };
}

pub fn registerExtensions(reg: *registry.Registry, ctx: *ExtensionsCtx) !void {
    try reg.registerEndpoint(.{ .path = "/server/extensions/list", .methods = &.{.GET} }, ctx, handleList);
    try reg.registerEndpoint(.{ .path = "/server/extensions/request", .methods = &.{.POST} }, ctx, handleRequest);
    try reg.registerEndpoint(.{ .path = "/connection/register_remote_method", .methods = &.{.POST}, .transports = &.{.WEBSOCKET} }, ctx, handleRegisterRemoteMethod);
    try reg.registerEndpoint(.{ .path = "/connection/send_event", .methods = &.{.POST}, .transports = &.{.WEBSOCKET} }, ctx, handleSendEvent);
}

test "extension handlers reject missing agents, invalid arguments and unbound connections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx: ExtensionsCtx = .{};
    defer ctx.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try handleList(&ctx, .null, alloc)).object.get("agents").?.array.items.len);
    const request = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"agent\":\"x\",\"method\":\"m\"}", .{});
    try std.testing.expectError(error.AgentNotConnected, handleRequest(&ctx, request, alloc));
    try std.testing.expectError(error.NoAgentConnection, handleSendEvent(&ctx, request, alloc));
    try std.testing.expectError(error.InvalidParams, handleRegisterRemoteMethod(&ctx, request, alloc));
}

test "fuzz extension handlers reject arbitrary unbound input" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            var ctx: ExtensionsCtx = .{};
            defer ctx.deinit();
            var bytes: [128]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            var params: std.json.ObjectMap = .empty;
            for ([_][]const u8{ "agent", "method", "method_name", "event", jsonrpc.connection_key }) |key| try params.put(alloc, key, .{ .string = &bytes });
            const handlers = [_]registry.HandlerFn{ handleList, handleRequest, handleRegisterRemoteMethod, handleSendEvent };
            for (handlers) |handler| _ = handler(&ctx, .{ .object = params }, alloc) catch continue;
        }
    }.run, .{});
}

test "agent registration and dynamic method ownership survive allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            const io = std.testing.io;
            var core = @import("../server/core.zig").Core.init();
            var conns = connections.Connections.init(alloc, &core);
            defer conns.deinit(io);
            var bus = notify.NotifyBus.init(&core, &conns);
            var klippy = try KlippyCtx.init(alloc, &bus);
            defer klippy.deinit();
            var ctx: ExtensionsCtx = .{ .alloc = alloc, .io = io, .bus = &bus, .klippy = &klippy };
            defer ctx.deinit();
            const conn = try conns.add(io, false);
            try conns.identify(io, conn, .{ .name = "worker", .type = "agent", .url = "local", .version = "1" });
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            core.lock(io);
            defer core.unlock(io);
            try ctx.registerAgent(conn, a);
            try std.testing.expectError(error.AgentDuplicate, ctx.registerAgent(conn, a));
            var params: std.json.ObjectMap = .empty;
            try params.put(a, jsonrpc.connection_key, .{ .integer = @intCast(conn.id) });
            try params.put(a, "method_name", .{ .string = "agent_method" });
            _ = try handleRegisterRemoteMethod(&ctx, .{ .object = params }, a);
            try std.testing.expectEqual(conn.id, klippy.agent_methods.get("agent_method").?);
            try std.testing.expectError(error.AgentMethodDuplicate, handleRegisterRemoteMethod(&ctx, .{ .object = params }, a));
            try std.testing.expectEqual(@as(usize, 1), (try handleList(&ctx, .null, a)).object.get("agents").?.array.items.len);
            try ctx.removeAgent(conn);
            try std.testing.expectEqual(@as(usize, 0), ctx.agents.count());
            try std.testing.expectEqual(@as(usize, 0), ctx.methods.count());
            try std.testing.expectEqual(@as(usize, 0), klippy.agent_methods.count());
        }
    }.run, .{});
}

test "fuzz connection pinning keeps removed records alive until release" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            const io = std.testing.io;
            var core = @import("../server/core.zig").Core.init();
            var conns = connections.Connections.init(std.testing.allocator, &core);
            defer conns.deinit(io);
            const conn = try conns.add(io, false);
            const pins = smith.valueRangeAtMostWithHash(u8, 1, 16, 0);
            for (0..pins) |_| _ = try conns.pin(io, conn.id);
            conns.remove(io, conn);
            try std.testing.expectEqual(@as(usize, 0), conns.count(io));
            for (0..pins) |_| conns.unpin(io, conn);
        }
    }.run, .{});
}

test "fuzz registered agent methods and events preserve owned names and valid frames" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            const io = std.testing.io;
            const alloc = std.testing.allocator;
            var core = @import("../server/core.zig").Core.init();
            var conns = connections.Connections.init(alloc, &core);
            defer conns.deinit(io);
            var bus = notify.NotifyBus.init(&core, &conns);
            var klippy = try KlippyCtx.init(alloc, &bus);
            defer klippy.deinit();
            var ctx: ExtensionsCtx = .{ .alloc = alloc, .io = io, .bus = &bus, .klippy = &klippy };
            defer ctx.deinit();
            const agent = try conns.add(io, false);
            const observer = try conns.add(io, false);
            var name: [16]u8 = undefined;
            smith.bytesWithHash(&name, 0);
            for (&name) |*b| b.* = 'a' + b.* % 26;
            try conns.identify(io, agent, .{ .name = &name, .type = "agent", .version = "1", .url = "local" });
            const Record = struct {
                frames: usize = 0,
                fn write(p: *anyopaque, frame: []const u8) !void {
                    const self: *@This() = @ptrCast(@alignCast(p));
                    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, frame, .{});
                    defer parsed.deinit();
                    try std.testing.expect(parsed.value.object.contains("method"));
                    self.frames += 1;
                }
            };
            var record: Record = .{};
            conns.attachWriter(io, observer, &record, Record.write);
            conns.attachWriter(io, agent, &record, Record.write);
            defer conns.detachWriter(io, observer);
            defer conns.detachWriter(io, agent);
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const a = arena.allocator();
            core.lock(io);
            defer core.unlock(io);
            try ctx.registerAgent(agent, a);
            var params: std.json.ObjectMap = .empty;
            try params.put(a, jsonrpc.connection_key, .{ .integer = @intCast(agent.id) });
            try params.put(a, "method_name", .{ .string = &name });
            _ = try handleRegisterRemoteMethod(&ctx, .{ .object = params }, a);
            try params.put(a, "event", .{ .string = &name });
            try params.put(a, "data", .{ .integer = smith.value(i16) });
            _ = try handleSendEvent(&ctx, .{ .object = params }, a);
            try std.testing.expect(try ctx.forwardRemote(&name, .{ .object = params }, a));
            try ctx.removeAgent(agent);
            try std.testing.expectEqual(@as(usize, 4), record.frames);
        }
    }.run, .{});
}
