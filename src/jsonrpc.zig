//! JSON-RPC 2.0 dispatcher.
//!
//! Handler signature:
//!   fn(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value
//!
//! Handlers return either a result Value (caller owns any allocations inside) or an error.
//! Errors are mapped to JSON-RPC codes matching Moonraker's `JsonRPC.execute_method`:
//! `error.InvalidParams` → -32602, `error.NotFound` → -32601, `error.Forbidden` → 403,
//! the Klippy/MQTT/service-unavailable family → 503, the agent/estimator/Klippy-request
//! family → 400, and any unmapped error → -32603 Internal error. See the `switch (err)`
//! in `handleParsedRoot` for the full table.
//!
//! Notifications (requests without "id") execute the handler but produce no response bytes.
const std = @import("std");
const jv = @import("json/value.zig");
const Core = @import("server/core.zig").Core;

pub const Error = error{
    InvalidParams,
};

/// Erased handler function pointer.
const HandlerFn = *const fn (ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value;

const Entry = struct {
    ctx: *anyopaque,
    handler: HandlerFn,
    /// Run without the Core lock (read-only handler — see ApiDef.off_core).
    off_core: bool = false,
};

/// Trampoline so a runtime handler pointer can run inside `Core.run` (which
/// needs a comptime-known function).
/// Comptime-known trampoline so a runtime handler pointer can run inside
/// `Core.run` (which requires a comptime-known function). Shared by both
/// transports (HTTP REST + JSON-RPC) so the dispatch shim is defined once.
pub fn callHandlerTramp(handler: HandlerFn, ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    return handler(ctx, params, alloc);
}

pub const Dispatcher = struct {
    alloc: std.mem.Allocator,
    methods: std.StringHashMap(Entry),
    /// Serialized-core handle. Set by App after init so `handle` can acquire Core
    /// per-method (read-only methods skip it). Null in bare unit tests → handlers
    /// run unlocked (single-threaded, no concurrency to serialize).
    core: ?*Core = null,
    io: ?std.Io = null,

    pub fn init(alloc: std.mem.Allocator) Dispatcher {
        return .{
            .alloc = alloc,
            .methods = std.StringHashMap(Entry).init(alloc),
        };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.methods.deinit();
    }

    /// Wire the runtime Core + io so `handle` serializes non-read-only methods.
    pub fn setRuntime(self: *Dispatcher, core: *Core, io: std.Io) void {
        self.core = core;
        self.io = io;
    }

    /// Register a method.  `name` must outlive the Dispatcher (caller-owned string).
    /// `ctx` is passed back to `handler` on each call.
    pub fn register(
        self: *Dispatcher,
        name: []const u8,
        ctx: *anyopaque,
        handler: HandlerFn,
    ) error{OutOfMemory}!void {
        try self.registerEx(name, ctx, handler, false);
    }

    /// Register a method, choosing whether it runs off the Core lock.
    pub fn registerEx(
        self: *Dispatcher,
        name: []const u8,
        ctx: *anyopaque,
        handler: HandlerFn,
        off_core: bool,
    ) error{OutOfMemory}!void {
        try self.methods.put(name, .{ .ctx = ctx, .handler = handler, .off_core = off_core });
    }

    /// Process a raw JSON-RPC request.  Returns owned response bytes (caller must free),
    /// or an empty slice for notifications.  Never returns an error — malformed input
    /// produces an appropriate JSON-RPC error response.
    pub fn handle(self: *Dispatcher, request_json: []const u8, alloc: std.mem.Allocator) error{OutOfMemory}![]u8 {
        // --- Parse ---
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, request_json, .{}) catch {
            return jv.errorResponse(alloc, .null, -32700, "Parse error");
        };
        defer parsed.deinit();
        return self.handleParsedRoot(parsed.value, alloc);
    }

    /// Same as `handle` but takes an already-parsed JSON-RPC root, so callers
    /// that already parsed the request (the WS transport peeks the method) don't
    /// pay a second parse. `root`'s backing memory must outlive this call.
    pub fn handleParsedRoot(self: *Dispatcher, root: std.json.Value, alloc: std.mem.Allocator) error{OutOfMemory}![]u8 {
        // Must be an object
        if (root != .object) {
            return jv.errorResponse(alloc, .null, -32600, "Invalid Request");
        }
        const obj = root.object;

        // Determine id (may be absent = notification)
        const id_val: ?std.json.Value = obj.get("id");
        const id: std.json.Value = id_val orelse .null;
        const is_notification = (id_val == null);

        // Validate jsonrpc == "2.0"
        const jsonrpc_field = obj.get("jsonrpc") orelse {
            return jv.errorResponse(alloc, id, -32600, "Invalid Request");
        };
        if (jsonrpc_field != .string or !std.mem.eql(u8, jsonrpc_field.string, "2.0")) {
            return jv.errorResponse(alloc, id, -32600, "Invalid Request");
        }

        // Validate method
        const method_field = obj.get("method") orelse {
            return jv.errorResponse(alloc, id, -32600, "Invalid Request");
        };
        if (method_field != .string) {
            return jv.errorResponse(alloc, id, -32600, "Invalid Request");
        }
        const method = method_field.string;

        // Params (optional, may be absent)
        var params: std.json.Value = obj.get("params") orelse .null;

        // Look up method
        const entry = self.methods.get(method) orelse {
            if (is_notification) return try alloc.dupe(u8, &.{});
            return jv.errorResponse(alloc, id, -32601, "Method not found");
        };

        // Handler allocations go into an arena so they are freed after the
        // response is serialized.  The outer allocator is used only for
        // parsing and the final response bytes.
        var handler_arena = std.heap.ArenaAllocator.init(alloc);
        defer handler_arena.deinit();
        const handler_alloc = handler_arena.allocator();

        // Inject the HTTP verb as _method when params is an object, so
        // multi-verb handlers can dispatch correctly (mirrors the HTTP
        // transport behaviour). Non-object params are passed through
        // as-is; multi-verb endpoints always receive objects in practice.
        if (params == .object) {
            const verb: []const u8 = verb: {
                if (std.mem.lastIndexOfScalar(u8, method, '.')) |dot| {
                    const last = method[dot + 1 ..];
                    if (std.mem.startsWith(u8, last, "get_")) break :verb "GET";
                    if (std.mem.startsWith(u8, last, "post_")) break :verb "POST";
                    if (std.mem.startsWith(u8, last, "delete_")) break :verb "DELETE";
                }
                break :verb method;
            };
            try params.object.put(handler_alloc, "_method", .{ .string = verb });
        }

        // Call handler under the serialized Core, unless it is a read-only
        // (`off_core`) method or no Core is wired (bare tests). This is the one
        // place the lock is taken for JSON-RPC, so REST and JSON-RPC agree: both
        // skip Core for off_core methods and hold it for everything else.
        const result = (if (entry.off_core or self.core == null)
            entry.handler(entry.ctx, params, handler_alloc)
        else
            self.core.?.run(self.io.?, callHandlerTramp, .{ entry.handler, entry.ctx, params, handler_alloc })) catch |err| {
            if (is_notification) return try alloc.dupe(u8, &.{});
            // Moonraker's JsonRPC.execute_method maps a ServerError to its
            // status_code verbatim (except 404→-32601, 401→-32602). The
            // Klippy-disconnected error is ServerError("Klippy Host not
            // connected", 503), so it surfaces as code 503 with that message.
            const code: i64 = switch (err) {
                error.InvalidParams => -32602,
                error.Forbidden => 403,
                // Moonraker remaps a 404 ServerError to -32601 over JSON-RPC
                // (JsonRPC.execute_method); only HTTP keeps the literal 404.
                error.NotFound => -32601,
                error.KlippyDisconnected => 503,
                error.MqttNotConfigured => 503,
                error.ServiceUnavailable => 503,
                error.UpdateRefusedPrinting => 503,
                error.NotReady => 503,
                error.PrinterLocked => 503,
                error.AgentNotConnected, error.AgentRpcNotSupported, error.AgentAlreadyRegistered, error.ReservedEvent, error.EstimatorNotAvailable => 400,
                // Klippy rejected the command (bad gcode, unknown mcu command, …):
                // a client error, not a phobos internal error. Moonraker surfaces
                // these as 400, not 500/-32603.
                error.KlippyRequestFailed => 400,
                else => -32603,
            };
            const msg: []const u8 = switch (err) {
                error.InvalidParams => "Invalid params",
                error.Forbidden => "Forbidden",
                error.NotFound => "Not Found",
                error.KlippyDisconnected => "Klippy Host not connected",
                error.MqttNotConfigured => "MQTT not configured",
                error.ServiceUnavailable => "Service Unavailable",
                error.UpdateRefusedPrinting => "Update Refused: Klippy is printing",
                error.NotReady => "Service Unavailable",
                error.PrinterLocked => "Printer is busy",
                error.AgentNotConnected => "Agent not connected",
                error.AgentRpcNotSupported => "Agent method not supported",
                error.AgentAlreadyRegistered => "Agent already registered",
                error.ReservedEvent => "Reserved event name",
                error.EstimatorNotAvailable => "Estimator not available",
                error.KlippyRequestFailed => "Klippy request failed",
                else => "Internal error",
            };
            return jv.errorResponse(alloc, id, code, msg);
        };

        // Notification: handler ran but produce no bytes
        if (is_notification) return try alloc.dupe(u8, &.{});

        return jv.successResponse(alloc, id, result);
    }
};

// =============================================================================
// Tests
// =============================================================================

// --- helpers for tests ---

/// Trivial non-void context; we just pass a pointer to a bool sentinel.
var _dummy_ctx: u8 = 0;

fn echoHandler(_: *anyopaque, params: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    return params;
}

fn invalidParamsHandler(_: *anyopaque, _: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    return error.InvalidParams;
}

var notification_ran: bool = false;

fn sideEffectHandler(_: *anyopaque, _: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    notification_ran = true;
    return std.json.Value{ .integer = 0 };
}

fn makeDispatcher(alloc: std.mem.Allocator) !Dispatcher {
    var d = Dispatcher.init(alloc);
    try d.register("echo", @ptrCast(&_dummy_ctx), echoHandler);
    try d.register("bang", @ptrCast(&_dummy_ctx), invalidParamsHandler);
    try d.register("notify_me", @ptrCast(&_dummy_ctx), sideEffectHandler);
    return d;
}

test "unknown method returns -32601 and echoes id" {
    const alloc = std.testing.allocator;
    var d = try makeDispatcher(alloc);
    defer d.deinit();

    const req =
        \\{"jsonrpc":"2.0","method":"nonexistent","id":1}
    ;
    const resp = try d.handle(req, alloc);
    defer alloc.free(resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const err_obj = obj.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32601), err_obj.get("code").?.integer);
    try std.testing.expectEqual(@as(i64, 1), obj.get("id").?.integer);
}

test "invalid JSON returns -32700" {
    const alloc = std.testing.allocator;
    var d = try makeDispatcher(alloc);
    defer d.deinit();

    const resp = try d.handle("not json {{{{", alloc);
    defer alloc.free(resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const err_obj = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32700), err_obj.get("code").?.integer);
}

test "missing jsonrpc field returns -32600" {
    const alloc = std.testing.allocator;
    var d = try makeDispatcher(alloc);
    defer d.deinit();

    const req =
        \\{"method":"echo","id":2}
    ;
    const resp = try d.handle(req, alloc);
    defer alloc.free(resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const err_obj = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32600), err_obj.get("code").?.integer);
}

test "wrong jsonrpc version returns -32600" {
    const alloc = std.testing.allocator;
    var d = try makeDispatcher(alloc);
    defer d.deinit();

    const req =
        \\{"jsonrpc":"1.0","method":"echo","id":3}
    ;
    const resp = try d.handle(req, alloc);
    defer alloc.free(resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const err_obj = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32600), err_obj.get("code").?.integer);
}

test "echo method returns params as result" {
    const alloc = std.testing.allocator;
    var d = try makeDispatcher(alloc);
    defer d.deinit();

    const req =
        \\{"jsonrpc":"2.0","method":"echo","params":{"foo":"bar"},"id":4}
    ;
    const resp = try d.handle(req, alloc);
    defer alloc.free(resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("result") != null);
    const result = obj.get("result").?.object;
    try std.testing.expectEqualStrings("bar", result.get("foo").?.string);
    try std.testing.expectEqual(@as(i64, 4), obj.get("id").?.integer);
}

test "handler raising invalid params returns -32602" {
    const alloc = std.testing.allocator;
    var d = try makeDispatcher(alloc);
    defer d.deinit();

    const req =
        \\{"jsonrpc":"2.0","method":"bang","id":5}
    ;
    const resp = try d.handle(req, alloc);
    defer alloc.free(resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const err_obj = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32602), err_obj.get("code").?.integer);
}

test "notification: handle returns empty slice, handler still ran" {
    const alloc = std.testing.allocator;
    var d = try makeDispatcher(alloc);
    defer d.deinit();
    notification_ran = false;

    // No "id" field = notification
    const req =
        \\{"jsonrpc":"2.0","method":"notify_me","params":null}
    ;
    const resp = try d.handle(req, alloc);
    defer alloc.free(resp);

    try std.testing.expectEqual(@as(usize, 0), resp.len);
    try std.testing.expect(notification_ran);
}

test "fuzz_jsonrpc: arbitrary bytes never crash, always valid JSON or empty" {
    const alloc = std.testing.allocator;
    var d = try makeDispatcher(alloc);
    defer d.deinit();

    try std.testing.fuzz(&d, struct {
        fn run(dp: *Dispatcher, smith: *std.testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const len = @as(usize, buf[0]) % buf.len;
            const input = buf[0..len];

            const resp = try dp.handle(input, std.testing.allocator);
            defer std.testing.allocator.free(resp);

            if (resp.len == 0) return; // notification or nothing to return

            // Response must be valid JSON
            const parsed = std.json.parseFromSlice(std.json.Value, std.testing.allocator, resp, .{}) catch {
                return error.FuzzResponseNotValidJson;
            };
            defer parsed.deinit();

            // Must have "jsonrpc":"2.0"
            const obj = parsed.value.object;
            const jsonrpc = obj.get("jsonrpc") orelse return error.FuzzMissingJsonrpc;
            if (!std.mem.eql(u8, jsonrpc.string, "2.0")) return error.FuzzBadJsonrpcVersion;

            // Must have either "result" or "error"
            if (obj.get("result") == null and obj.get("error") == null) {
                return error.FuzzNoResultOrError;
            }
        }
    }.run, .{});
}
