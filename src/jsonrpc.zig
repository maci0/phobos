/// JSON-RPC 2.0 dispatcher.
///
/// Handler signature:
///   fn(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value
///
/// Handlers return either a result Value (caller owns any allocations inside) or an error.
/// Returning `error.InvalidParams` maps to -32602; any other error maps to -32603 Internal error.
///
/// Notifications (requests without "id") execute the handler but produce no response bytes.
const std = @import("std");
const jv = @import("json/value.zig");

pub const Error = error{
    InvalidParams,
};

/// Erased handler function pointer.
const HandlerFn = *const fn (ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value;

const Entry = struct {
    ctx: *anyopaque,
    handler: HandlerFn,
};

pub const Dispatcher = struct {
    alloc: std.mem.Allocator,
    methods: std.StringHashMap(Entry),

    pub fn init(alloc: std.mem.Allocator) Dispatcher {
        return .{
            .alloc = alloc,
            .methods = std.StringHashMap(Entry).init(alloc),
        };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.methods.deinit();
    }

    /// Register a method.  `name` must outlive the Dispatcher (caller-owned string).
    /// `ctx` is passed back to `handler` on each call.
    pub fn register(
        self: *Dispatcher,
        name: []const u8,
        ctx: *anyopaque,
        handler: HandlerFn,
    ) error{OutOfMemory}!void {
        try self.methods.put(name, .{ .ctx = ctx, .handler = handler });
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

        const root = parsed.value;

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

        // Call handler
        const result = entry.handler(entry.ctx, params, handler_alloc) catch |err| {
            if (is_notification) return try alloc.dupe(u8, &.{});
            // Moonraker's JsonRPC.execute_method maps a ServerError to its
            // status_code verbatim (except 404→-32601, 401→-32602). The
            // Klippy-disconnected error is ServerError("Klippy Host not
            // connected", 503), so it surfaces as code 503 with that message.
            const code: i64 = switch (err) {
                error.InvalidParams => -32602,
                error.KlippyDisconnected => 503,
                error.MqttNotConfigured => 503,
                error.ServiceUnavailable => 503,
                error.UpdateRefusedPrinting => 503,
                else => -32603,
            };
            const msg: []const u8 = switch (err) {
                error.InvalidParams => "Invalid params",
                error.KlippyDisconnected => "Klippy Host not connected",
                error.MqttNotConfigured => "MQTT not configured",
                error.ServiceUnavailable => "Service Unavailable",
                error.UpdateRefusedPrinting => "Update Refused: Klippy is printing",
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
