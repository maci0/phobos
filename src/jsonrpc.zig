//! JSON-RPC 2.0 dispatcher, following Moonraker's `JsonRPC.dispatch`
//! (common.py).
//!
//! Handler signature:
//!   fn(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value
//!
//! Request processing, in Moonraker's order: parse error -32700; a batch array
//! answers with an array of the item responses; `jsonrpc` other than "2.0"
//! -32600; an object without `method` is a response and gets no reply; a
//! non-string method -32600; unknown method -32601; a method not exposed on the
//! caller's transport -32601 "Method not found for transport <T>"; non-object
//! params -32602 "Invalid params:"; an `auth_required` method on an
//! unauthenticated caller -32602 "Unauthorized". Handler errors map through
//! `errorReply` (404 → -32601, 401 → -32602, otherwise the HTTP status).
//! Requests without an id (or with `"id": null`) get no reply on success;
//! errors are still sent.
const std = @import("std");
const jv = @import("json/value.zig");
const Core = @import("server/core.zig").Core;
const registry = @import("server/registry.zig");

const RequestType = registry.RequestType;
const TransportType = registry.TransportType;

/// Erased handler function pointer.
pub const HandlerFn = *const fn (ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value;

/// Params keys owned by the transports. Client-supplied values are removed
/// before injection.
pub const method_key = "_method";
pub const current_user_key = "_current_user";
pub const current_ip_key = "_remote_ip";
pub const connection_key = "_connection_id";

pub const Entry = struct {
    ctx: *anyopaque,
    handler: HandlerFn,
    /// Run without the Core lock (read-only handler, see ApiDef.off_core).
    off_core: bool = false,
    auth_required: bool = true,
    /// Request type injected as `_method` (Moonraker passes it to the callback).
    verb: RequestType = .POST,
    transports: []const TransportType = std.enums.values(TransportType),
};

/// Who sent a request. In-process callers use the default (INTERNAL, trusted).
pub const Caller = struct {
    transport: TransportType = .INTERNAL,
    /// Authenticated user, injected as `_current_user` for access.* methods.
    user: ?[]const u8 = null,
    /// Client address, injected as `_remote_ip` for access.* methods.
    remote_ip: ?[]const u8 = null,
    /// No authenticated user: `auth_required` methods answer "Unauthorized".
    need_auth: bool = false,
    connection_id: ?u64 = null,
    screen: ?Screen = null,
};

/// Transport-specific screening after method, params and authentication checks.
pub const Screen = struct {
    ctx: *anyopaque,
    run: *const fn (*anyopaque, *std.json.Value, std.mem.Allocator) anyerror!void,
};

/// Comptime-known trampoline so a runtime handler pointer can run inside
/// `Core.run` (which requires a comptime-known function). Shared by the REST
/// and JSON-RPC paths.
pub fn callHandlerTramp(handler: HandlerFn, ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    return handler(ctx, params, alloc);
}

/// A handler error as Moonraker reports it: the ServerError status and message.
pub const ErrorReply = struct {
    status: std.http.Status,
    message: []const u8,
    /// JSON-RPC code: `JsonRPC.execute_method` maps 404 to -32601 and 401 to
    /// -32602; any other ServerError, including a bad argument (400), keeps
    /// its status. -32602 "Invalid params:" is only for non-object params.
    rpc_code: i64,
    data: ?std.json.Value = null,
};

/// Map a handler error to its HTTP status, JSON-RPC code and message. The
/// message may be allocated in `alloc`.
pub fn errorReply(err: anyerror, params: std.json.Value, alloc: std.mem.Allocator) error{OutOfMemory}!ErrorReply {
    if (err == error.UpstreamRequestFailed and params == .object) {
        const slot = params.object.get(method_key) orelse .null;
        if (slot == .object) {
            const code = slot.object.get("status") orelse .null;
            const message = slot.object.get("message") orelse .null;
            if (code == .integer and code.integer >= 400 and code.integer <= 599 and message == .string) {
                return .{ .status = @fromBackingInt(@intCast(code.integer)), .message = message.string, .data = slot.object.get("data"), .rpc_code = switch (code.integer) {
                    404 => -32601,
                    401 => -32602,
                    else => code.integer,
                } };
            }
        }
    }
    const status: std.http.Status, const message: []const u8 = switch (err) {
        error.InvalidParams => .{ .bad_request, "Invalid params" },
        error.MissingFilename => .{ .bad_request, "No data for argument: filename" },
        error.MissingWebcamName => .{ .bad_request, "No data for argument: name" },
        error.Forbidden => .{ .forbidden, "Forbidden" },
        // file_manager.py _handle_operation_check.
        error.FileInUse => .{ .forbidden, "File currently in use" },
        error.NotFound => .{ .not_found, "Not Found" },
        // file_manager.py get_file_metadata.
        error.MetadataNotAvailable => .{ .not_found, try std.fmt.allocPrint(alloc, "Metadata not available for <{s}>", .{paramStr(params, "filename")}) },
        // analysis.py; the "exit" typo is Moonraker's.
        error.GcodeNotFound => .{ .bad_request, try std.fmt.allocPrint(alloc, "GCode File '{s}' does not exit in gcodes path", .{std.mem.trim(u8, paramStr(params, "filename"), "/")}) },
        error.UnknownDbNamespace => .{ .not_found, try std.fmt.allocPrint(alloc, "Namespace {s} not found", .{paramStr(params, "namespace")}) },
        error.MissingDbKey => .{ .not_found, try std.fmt.allocPrint(alloc, "Key '{s}' in namespace '{s}' not found", .{ paramStr(params, "key"), paramStr(params, "namespace") }) },
        // Moonraker ServerError("Klippy Host not connected", 503).
        error.KlippyDisconnected => .{ .service_unavailable, "Klippy Host not connected" },
        error.MqttNotConfigured => .{ .service_unavailable, "MQTT not configured" },
        error.MqttTimeout => .{ .gateway_timeout, "MQTT Subscribe Timed Out" },
        error.DuplicateMqttRequest => .{ .bad_request, "Duplicate MQTT Request" },
        error.ServiceUnavailable, error.NotReady => .{ .service_unavailable, "Service Unavailable" },
        error.UpdateRefusedPrinting => .{ .service_unavailable, "Update Refused: Klippy is printing" },
        error.UpdateBusy => .{ .service_unavailable, "Server is busy, cannot perform refresh" },
        // power.py process_request with locked_while_printing.
        error.PrinterLocked => .{ .bad_request, try std.fmt.allocPrint(alloc, "Unable to change power for {s} while printing", .{paramStr(params, "device")}) },
        // power.py _send_power_request failure, or wled.py _send_wled_command.
        error.DeviceRequestFailed => .{ .bad_request, if (paramStr(params, "strip").len > 0)
            "WLED: Error"
        else
            try std.fmt.allocPrint(alloc, "Error Setting Device Status: {s} to {s}", .{ paramStr(params, "device"), paramStr(params, "action") }) },
        // machine.py _handle_service_request.
        error.ServiceNotAllowed => .{ .bad_request, try std.fmt.allocPrint(alloc, "Service '{s}' not allowed", .{paramStr(params, "service")}) },
        error.ServiceNotInstalled => .{ .bad_request, try std.fmt.allocPrint(alloc, "Service '{s}' not installed", .{paramStr(params, "service")}) },
        // loghelper.py rollover.
        error.UnknownApplication => .{ .bad_request, try std.fmt.allocPrint(alloc, "Unknown application {s}", .{paramStr(params, "application")}) },
        // system_deploy.py without a package provider.
        error.NoPackageProvider => .{ .bad_request, "Cannot upgrade packages, no provider set" },
        // octoprint_compat.py _select_file.
        error.UnsupportedCommand => .{ .bad_request, try std.fmt.allocPrint(alloc, "Unsupported Command: {s}", .{paramStr(params, "command")}) },
        error.SelectNotGcodes => .{ .bad_request, "File must be located in the 'gcodes' root" },
        error.FileDoesNotExist => .{ .bad_request, "File does not exist" },
        error.Conflict => .{ .conflict, "Conflict" },
        error.AgentNotConnected => .{ .bad_request, try std.fmt.allocPrint(alloc, "Agent {s} not connected", .{paramStr(params, "agent")}) },
        error.ReservedEvent => .{ .bad_request, try std.fmt.allocPrint(alloc, "Event '{s}' is reserved", .{paramStr(params, "event")}) },
        error.NoAgentConnection => .{ .bad_request, "No connection detected" },
        error.AgentEventsOnly => .{ .bad_request, "Only connections of the 'agent' type can send events" },
        error.AgentMethodsOnly => .{ .bad_request, "Only connections of the 'agent' type can register methods" },
        error.AgentArgumentsInvalid => .{ .bad_request, "The 'arguments' field must contain an object or a list" },
        error.AgentDuplicate => .{ .bad_request, try std.fmt.allocPrint(alloc, "Agent '{s}' already registered and connected'", .{paramStr(params, "client_name")}) },
        error.AgentMethodDuplicate => .{ .bad_request, try std.fmt.allocPrint(alloc, "Remote method ({s}) already registered", .{paramStr(params, "method_name")}) },
        error.AgentDisconnected => .{ .internal_server_error, "Client Socket Disconnected" },
        error.AgentRequestTimedOut => .{ .internal_server_error, "Agent request timed out" },
        error.AgentCapacity => .{ .service_unavailable, "Too many pending agent requests" },
        error.EstimatorNotAvailable => .{ .bad_request, "Estimator not available" },
        // Klippy rejected the command (bad gcode, unknown mcu command): a
        // client error, as in Moonraker.
        error.KlippyRequestFailed => .{ .bad_request, "Klippy request failed" },
        error.KlippyRequestTimedOut => .{ .internal_server_error, "Klippy request timed out" },
        error.Unauthorized => .{ .unauthorized, "Unauthorized" },
        // Moonraker klippy_connection.py: objects/subscribe needs a socket.
        error.NoSubscriptionConnection => .{ .bad_request, "No connection associated with subscription request" },
        else => .{ .internal_server_error, "Internal Server Error" },
    };
    const rpc_code: i64 = if (err == error.DuplicateMqttRequest) -10000 else switch (status) {
        .not_found => -32601,
        .unauthorized => -32602,
        else => @backingInt(status),
    };
    return .{ .status = status, .message = message, .rpc_code = rpc_code };
}

/// Replace the reserved verb slot after an upstream failure. The caller must
/// immediately return UpstreamRequestFailed. Storage belongs to alloc.
pub fn setErrorReply(alloc: std.mem.Allocator, params: std.json.Value, status: std.http.Status, message: []const u8) error{OutOfMemory}!void {
    std.debug.assert(params == .object);
    const slot = params.object.getPtr(method_key).?;
    var fields: std.json.ObjectMap = .empty;
    try fields.put(alloc, "status", .{ .integer = @backingInt(status) });
    try fields.put(alloc, "message", .{ .string = try alloc.dupe(u8, message) });
    slot.* = .{ .object = fields };
}

/// The string at `key` in `params`, or "" when absent or not a string.
fn paramStr(params: std.json.Value, key: []const u8) []const u8 {
    if (params != .object) return "";
    return switch (params.object.get(key) orelse return "") {
        .string => |s| s,
        else => "",
    };
}

/// Build handler params from the request's object: drop client-supplied
/// transport keys, set `_method` to `verb`, and when `identity` is set add the
/// caller's user and client address. Entries are copied shallowly into `alloc`.
pub fn requestParams(
    alloc: std.mem.Allocator,
    src: ?std.json.ObjectMap,
    verb: RequestType,
    caller: Caller,
    identity: bool,
) error{OutOfMemory}!std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    if (src) |s| {
        try obj.ensureTotalCapacity(alloc, s.count() + 4);
        var it = s.iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            if (std.mem.eql(u8, k, method_key) or std.mem.eql(u8, k, current_user_key) or std.mem.eql(u8, k, current_ip_key) or std.mem.eql(u8, k, connection_key)) continue;
            obj.putAssumeCapacity(k, e.value_ptr.*);
        }
    }
    try obj.put(alloc, method_key, .{ .string = @tagName(verb) });
    if (caller.transport == .WEBSOCKET) if (caller.connection_id) |id| try obj.put(alloc, connection_key, .{ .integer = @intCast(id) });
    if (identity) {
        if (caller.user) |u| try obj.put(alloc, current_user_key, .{ .string = u });
        if (caller.remote_ip) |ip| try obj.put(alloc, current_ip_key, .{ .string = ip });
    }
    return .{ .object = obj };
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

    /// Register a method with default `Entry` settings. `name` must outlive
    /// the Dispatcher.
    pub fn register(
        self: *Dispatcher,
        name: []const u8,
        ctx: *anyopaque,
        handler: HandlerFn,
    ) error{OutOfMemory}!void {
        try self.registerEntry(name, .{ .ctx = ctx, .handler = handler });
    }

    /// Register a method with explicit settings. `name` must outlive the
    /// Dispatcher.
    pub fn registerEntry(self: *Dispatcher, name: []const u8, entry: Entry) error{OutOfMemory}!void {
        try self.methods.put(name, entry);
    }

    /// Process a raw request from an in-process caller (INTERNAL transport, no
    /// authentication). Returns owned response bytes, or an empty slice when
    /// there is nothing to send. Malformed input produces a JSON-RPC error.
    pub fn handle(self: *Dispatcher, request_json: []const u8, alloc: std.mem.Allocator) error{OutOfMemory}![]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, request_json, .{}) catch {
            return jv.errorResponse(alloc, .null, -32700, "Parse error");
        };
        defer parsed.deinit();
        return self.handleParsedRoot(.{}, parsed.value, alloc);
    }

    /// Process an already-parsed request for `caller`. `root`'s backing memory
    /// must outlive this call. Returns owned bytes in `alloc`; empty when
    /// there is nothing to send.
    pub fn handleParsedRoot(self: *Dispatcher, caller: Caller, root: std.json.Value, alloc: std.mem.Allocator) error{OutOfMemory}![]u8 {
        // std.json.Stringify recurses per nesting level; the id is echoed, so
        // an over-deep request is refused before anything is serialized.
        if (jv.exceedsDepth(root, jv.max_value_depth)) return jv.errorResponse(alloc, .null, -32600, "Invalid Request");
        switch (root) {
            .object => |obj| return (try self.processObject(caller, obj, alloc)) orelse alloc.dupe(u8, &.{}),
            .array => |items| {
                var out: std.Io.Writer.Allocating = .init(alloc);
                defer out.deinit();
                for (items.items) |item| {
                    const resp = switch (item) {
                        .object => |obj| try self.processObject(caller, obj, alloc),
                        else => try jv.errorResponse(alloc, .null, -32600, "Invalid Request"),
                    } orelse continue;
                    defer alloc.free(resp);
                    out.writer.writeByte(if (out.written().len == 0) '[' else ',') catch return error.OutOfMemory;
                    out.writer.writeAll(resp) catch return error.OutOfMemory;
                }
                if (out.written().len == 0) return alloc.dupe(u8, &.{});
                out.writer.writeByte(']') catch return error.OutOfMemory;
                return out.toOwnedSlice();
            },
            else => return jv.errorResponse(alloc, .null, -32600, "Invalid Request"),
        }
    }

    /// One request object. Null means no reply (a response object, or a
    /// successful request without an id).
    fn processObject(self: *Dispatcher, caller: Caller, obj: std.json.ObjectMap, alloc: std.mem.Allocator) error{OutOfMemory}!?[]u8 {
        // Everything except the returned bytes is freed on return.
        var handler_arena = std.heap.ArenaAllocator.init(alloc);
        defer handler_arena.deinit();
        const handler_alloc = handler_arena.allocator();

        const id: std.json.Value = obj.get("id") orelse .null;
        const jsonrpc_field = obj.get("jsonrpc") orelse .null;
        if (jsonrpc_field != .string or !std.mem.eql(u8, jsonrpc_field.string, "2.0")) {
            return try jv.errorResponse(alloc, id, -32600, "Invalid Request");
        }
        const method_field = obj.get("method") orelse return null;
        if (method_field != .string) return try jv.errorResponse(alloc, id, -32600, "Invalid Request");
        const method = method_field.string;

        const entry = self.methods.get(method) orelse return try jv.errorResponse(alloc, id, -32601, "Method not found");
        if (std.mem.indexOfScalar(TransportType, entry.transports, caller.transport) == null) {
            const msg = try std.fmt.allocPrint(handler_alloc, "Method not found for transport {t}", .{caller.transport});
            return try jv.errorResponse(alloc, id, -32601, msg);
        }
        const src: ?std.json.ObjectMap = switch (obj.get("params") orelse std.json.Value{ .object = .empty }) {
            .object => |o| o,
            else => return try jv.errorResponse(alloc, id, -32602, "Invalid params:"),
        };
        if (caller.need_auth and entry.auth_required) return try jv.errorResponse(alloc, id, -32602, "Unauthorized");

        var scoped_caller = caller;
        if (!std.mem.startsWith(u8, method, "connection.")) scoped_caller.connection_id = null;
        var params = try requestParams(handler_alloc, src, entry.verb, scoped_caller, std.mem.startsWith(u8, method, "access."));
        if (caller.screen) |screen| screen.run(screen.ctx, &params, handler_alloc) catch |err| {
            const reply = try errorReply(err, params, handler_alloc);
            return try formatError(alloc, id, reply);
        };

        // REST and JSON-RPC agree: off_core methods skip the Core lock, the
        // rest hold it. Bare tests wire no Core.
        if (!entry.off_core) if (self.core) |core| core.lock(self.io.?);
        defer if (!entry.off_core) if (self.core) |core| core.unlock(self.io.?);
        const result = entry.handler(entry.ctx, params, handler_alloc) catch |err| {
            const reply = try errorReply(err, params, handler_alloc);
            return try formatError(alloc, id, reply);
        };
        if (id == .null) return null;
        return try jv.successResponse(alloc, id, result);
    }
};

pub fn formatError(alloc: std.mem.Allocator, id: std.json.Value, reply: ErrorReply) error{OutOfMemory}![]u8 {
    if (reply.data) |data| return std.json.Stringify.valueAlloc(alloc, .{
        .jsonrpc = "2.0",
        .@"error" = .{ .code = reply.rpc_code, .message = reply.message, .data = data },
        .id = id,
    }, .{});
    return jv.errorResponse(alloc, id, reply.rpc_code, reply.message);
}

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

test "screening follows validation and applies to each batch request" {
    const ScreenCtx = struct {
        calls: usize = 0,
        fn screen(ctx: *anyopaque, params: *std.json.Value, _: std.mem.Allocator) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            _ = params.object.swapRemove("mqtt_timestamp");
            if (self.calls == 2) return error.DuplicateMqttRequest;
        }
    };
    const a = std.testing.allocator;
    var d = try makeDispatcher(a);
    defer d.deinit();
    var screen: ScreenCtx = .{};
    const root = try std.json.parseFromSlice(std.json.Value, a,
        \\[{"jsonrpc":"2.0","method":"missing","id":0},{"jsonrpc":"2.0","method":"echo","params":[],"id":1},{"jsonrpc":"2.0","method":"echo","params":{"mqtt_timestamp":1},"id":2},{"jsonrpc":"2.0","method":"echo","params":{"mqtt_timestamp":1},"id":3}]
    , .{});
    defer root.deinit();
    const bytes = try d.handleParsedRoot(.{ .screen = .{ .ctx = &screen, .run = ScreenCtx.screen } }, root.value, a);
    defer a.free(bytes);
    const result = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), screen.calls);
    try std.testing.expect(result.value.array.items[2].object.get("result").?.object.get("mqtt_timestamp") == null);
    try std.testing.expectEqual(@as(i64, -10000), result.value.array.items[3].object.get("error").?.object.get("code").?.integer);
}

test "upstream error uses only the server-owned request slot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const forged = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"_method":{"status":418,"message":"forged"}}
    , .{});
    const params = try requestParams(a, forged.object, .GET, .{}, false);
    try std.testing.expectEqual(@as(i64, 500), (try errorReply(error.UpstreamRequestFailed, params, a)).rpc_code);
    try setErrorReply(a, params, .conflict, "upstream conflict");
    const reply = try errorReply(error.UpstreamRequestFailed, params, a);
    try std.testing.expectEqual(std.http.Status.conflict, reply.status);
    try std.testing.expectEqualStrings("upstream conflict", reply.message);
    try std.testing.expectEqual(@as(i64, 409), reply.rpc_code);
    try setErrorReply(a, params, .ok, "invalid success");
    try std.testing.expectEqual(@as(i64, 500), (try errorReply(error.UpstreamRequestFailed, params, a)).rpc_code);
}

test "every transport replaces a forged upstream error with its verb" {
    const a = std.testing.allocator;
    var d = Dispatcher.init(a);
    defer d.deinit();
    const Handler = struct {
        fn fail(_: *anyopaque, _: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
            return error.UpstreamRequestFailed;
        }
    };
    try d.register("fail", &_dummy_ctx, Handler.fail);
    try d.register("echo", &_dummy_ctx, echoHandler);
    const root = try std.json.parseFromSlice(std.json.Value, a,
        \\{"jsonrpc":"2.0","method":"fail","params":{"_method":{"status":418,"message":"forged"}},"id":1}
    , .{});
    defer root.deinit();
    for (std.enums.values(TransportType)) |transport| {
        const bytes = try d.handleParsedRoot(.{ .transport = transport }, root.value, a);
        defer a.free(bytes);
        const result = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(i64, 500), result.value.object.get("error").?.object.get("code").?.integer);
    }
}

test "fuzz upstream error carrier validates status and retains owned text" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var message: [32]u8 = undefined;
            smith.bytesWithHash(&message, 0);
            const params = try requestParams(a, null, .POST, .{}, false);
            const status = smith.valueRangeAtMostWithHash(u16, 100, 999, 1);
            try setErrorReply(a, params, @fromBackingInt(@intCast(status)), &message);
            const reply = try errorReply(error.UpstreamRequestFailed, params, a);
            if (status >= 400 and status <= 599) {
                try std.testing.expectEqual(status, @backingInt(reply.status));
                try std.testing.expectEqualSlices(u8, &message, reply.message);
                try std.testing.expect(reply.message.ptr != &message);
            } else try std.testing.expectEqual(std.http.Status.internal_server_error, reply.status);
        }
    }.run, .{});
}

test "handler borrowed strings are serialized while Core is held" {
    const Probe = struct {
        core: Core = .{},
        text: [4]u8 = "good".*,
        armed: bool = false,
        checks: usize = 0,
        fn handler(raw: *anyopaque, _: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.armed = true;
            return .{ .string = &self.text };
        }
        fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.armed) {
                self.checks += 1;
                if (self.core.mutex.tryLock()) {
                    self.text = "bad!".*;
                    self.core.unlock(std.testing.io);
                }
            }
            return std.testing.allocator.rawAlloc(len, alignment, ret);
        }
        fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
            return std.testing.allocator.rawResize(memory, alignment, len, ret);
        }
        fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
            return std.testing.allocator.rawRemap(memory, alignment, len, ret);
        }
        fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
            std.testing.allocator.rawFree(memory, alignment, ret);
        }
    };
    var probe: Probe = .{};
    const alloc: std.mem.Allocator = .{ .ptr = &probe, .vtable = &.{ .alloc = Probe.alloc, .resize = Probe.resize, .remap = Probe.remap, .free = Probe.free } };
    var d = Dispatcher.init(std.testing.allocator);
    defer d.deinit();
    d.setRuntime(&probe.core, std.testing.io);
    try d.register("borrow", &probe, Probe.handler);
    const response = try d.handle("{\"jsonrpc\":\"2.0\",\"method\":\"borrow\",\"id\":1}", alloc);
    defer alloc.free(response);
    try std.testing.expect(probe.checks > 0);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"result\":\"good\",\"id\":1}", response);
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

test "handler raising invalid params returns Moonraker's ServerError code 400" {
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
    try std.testing.expectEqual(@as(i64, 400), err_obj.get("code").?.integer);
}

test "notification: handle returns empty slice, handler still ran" {
    const alloc = std.testing.allocator;
    var d = try makeDispatcher(alloc);
    defer d.deinit();
    notification_ran = false;

    // No "id" field = notification
    const req =
        \\{"jsonrpc":"2.0","method":"notify_me"}
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

            // A batch answers with an array of responses.
            const items: []const std.json.Value = switch (parsed.value) {
                .array => |a| a.items,
                else => &.{parsed.value},
            };
            for (items) |item| {
                const obj = item.object;
                const jsonrpc = obj.get("jsonrpc") orelse return error.FuzzMissingJsonrpc;
                if (!std.mem.eql(u8, jsonrpc.string, "2.0")) return error.FuzzBadJsonrpcVersion;
                if (obj.get("result") == null and obj.get("error") == null) {
                    return error.FuzzNoResultOrError;
                }
            }
        }
    }.run, .{});
}

fn expectErrorCode(d: *Dispatcher, caller: Caller, req: []const u8, code: i64, message: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, req, .{});
    const resp = try d.handleParsedRoot(caller, root, a);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, resp, .{});
    const err = parsed.object.get("error").?.object;
    try std.testing.expectEqual(code, err.get("code").?.integer);
    try std.testing.expectEqualStrings(message, err.get("message").?.string);
}

test "unauthenticated callers cannot run auth_required methods" {
    var d = try makeDispatcher(std.testing.allocator);
    defer d.deinit();
    try d.registerEntry("open", .{ .ctx = @ptrCast(&_dummy_ctx), .handler = echoHandler, .auth_required = false });
    const anon: Caller = .{ .transport = .WEBSOCKET, .need_auth = true };
    try expectErrorCode(&d, anon,
        \\{"jsonrpc":"2.0","method":"echo","id":1}
    , -32602, "Unauthorized");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"jsonrpc":"2.0","method":"open","id":2}
    , .{});
    const ok = try d.handleParsedRoot(anon, root, a);
    try std.testing.expect(std.mem.indexOf(u8, ok, "\"result\"") != null);
}

test "client-supplied identity keys are replaced by the caller's" {
    var d = Dispatcher.init(std.testing.allocator);
    defer d.deinit();
    try d.register("access.echo", @ptrCast(&_dummy_ctx), echoHandler);
    try d.register("other.echo", @ptrCast(&_dummy_ctx), echoHandler);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const caller: Caller = .{ .transport = .WEBSOCKET, .user = "bob", .remote_ip = "10.0.0.2" };

    const root = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"jsonrpc":"2.0","method":"access.echo","params":{"_current_user":"alice","_remote_ip":"1.2.3.4","_method":"DELETE"},"id":1}
    , .{});
    const resp = try std.json.parseFromSliceLeaky(std.json.Value, a, try d.handleParsedRoot(caller, root, a), .{});
    const result = resp.object.get("result").?.object;
    try std.testing.expectEqualStrings("bob", result.get(current_user_key).?.string);
    try std.testing.expectEqualStrings("10.0.0.2", result.get(current_ip_key).?.string);
    try std.testing.expectEqualStrings("POST", result.get(method_key).?.string);

    // Outside access.* the keys are stripped and not injected.
    const other = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"jsonrpc":"2.0","method":"other.echo","params":{"_current_user":"alice"},"id":2}
    , .{});
    const other_resp = try std.json.parseFromSliceLeaky(std.json.Value, a, try d.handleParsedRoot(caller, other, a), .{});
    try std.testing.expect(other_resp.object.get("result").?.object.get(current_user_key) == null);
}

test "requests follow Moonraker's JsonRPC.process_object order" {
    var d = try makeDispatcher(std.testing.allocator);
    defer d.deinit();
    const ws_only = [_]TransportType{.WEBSOCKET};
    try d.registerEntry("ws.only", .{ .ctx = @ptrCast(&_dummy_ctx), .handler = echoHandler, .transports = &ws_only });
    const http: Caller = .{ .transport = .HTTP };
    try expectErrorCode(&d, http,
        \\{"jsonrpc":"2.0","method":"ws.only","id":1}
    , -32601, "Method not found for transport HTTP");
    try expectErrorCode(&d, http,
        \\{"jsonrpc":"2.0","method":"echo","params":[1],"id":1}
    , -32602, "Invalid params:");
    // Errors are sent for id-less requests too.
    try expectErrorCode(&d, http,
        \\{"jsonrpc":"2.0","method":"nope"}
    , -32601, "Method not found");

    const alloc = std.testing.allocator;
    // A response object (no method) gets no reply; "id": null success is silent.
    for ([_][]const u8{
        \\{"jsonrpc":"2.0","result":1,"id":3}
        ,
        \\{"jsonrpc":"2.0","method":"echo","id":null}
        ,
        \\[]
    }) |req| {
        const resp = try d.handle(req, alloc);
        defer alloc.free(resp);
        try std.testing.expectEqual(@as(usize, 0), resp.len);
    }
}

test "absent params still carry the request verb" {
    var d = Dispatcher.init(std.testing.allocator);
    defer d.deinit();
    try d.registerEntry("x.get_y", .{ .ctx = @ptrCast(&_dummy_ctx), .handler = echoHandler, .verb = .GET });
    const resp = try d.handle(
        \\{"jsonrpc":"2.0","method":"x.get_y","id":1}
    , std.testing.allocator);
    defer std.testing.allocator.free(resp);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","result":{"_method":"GET"},"id":1}
    , resp);
}

test "a batch answers with an array of the item responses" {
    var d = try makeDispatcher(std.testing.allocator);
    defer d.deinit();
    const resp = try d.handle(
        \\[{"jsonrpc":"2.0","method":"echo","params":{"a":1},"id":1},{"jsonrpc":"2.0","method":"notify_me"},{"jsonrpc":"2.0","method":"nope","id":2}]
    , std.testing.allocator);
    defer std.testing.allocator.free(resp);
    try std.testing.expectEqualStrings(
        \\[{"jsonrpc":"2.0","result":{"a":1,"_method":"POST"},"id":1},{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found"},"id":2}]
    , resp);
}

test "a request nested past max_value_depth is refused before serialization" {
    var d = try makeDispatcher(std.testing.allocator);
    defer d.deinit();
    const depth = 300;
    const req = "{\"jsonrpc\":\"2.0\",\"method\":\"echo\",\"id\":" ++ @as([depth]u8, @splat('[')) ++ @as([depth]u8, @splat(']')) ++ "}";
    const resp = try d.handle(req, std.testing.allocator);
    defer std.testing.allocator.free(resp);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid Request"},"id":null}
    , resp);
}

test "errorReply maps statuses to Moonraker JSON-RPC codes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nf = try errorReply(error.NotFound, .null, a);
    try std.testing.expectEqual(std.http.Status.not_found, nf.status);
    try std.testing.expectEqual(@as(i64, -32601), nf.rpc_code);
    try std.testing.expectEqual(@as(i64, -32602), (try errorReply(error.Unauthorized, .null, a)).rpc_code);
    try std.testing.expectEqual(@as(i64, 400), (try errorReply(error.InvalidParams, .null, a)).rpc_code);
    try std.testing.expectEqual(@as(i64, 503), (try errorReply(error.KlippyDisconnected, .null, a)).rpc_code);
    const mqtt_timeout = try errorReply(error.MqttTimeout, .null, a);
    try std.testing.expectEqual(@as(i64, 504), mqtt_timeout.rpc_code);
    try std.testing.expectEqualStrings("MQTT Subscribe Timed Out", mqtt_timeout.message);
    const no_conn = try errorReply(error.NoSubscriptionConnection, .null, a);
    try std.testing.expectEqual(@as(i64, 400), no_conn.rpc_code);
    try std.testing.expectEqualStrings("No connection associated with subscription request", no_conn.message);
    const unknown = try errorReply(error.SomethingElse, .null, a);
    try std.testing.expectEqual(@as(i64, 500), unknown.rpc_code);
    // A missing namespace param does not crash the message builder.
    try std.testing.expectEqualStrings("Namespace  not found", (try errorReply(error.UnknownDbNamespace, .null, a)).message);

    // Moonraker's ServerError texts for service, log, power and WLED requests.
    const params = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"service":"sshd","application":"x","device":"psu","action":"on"}
    , .{});
    const cases = [_]struct { err: anyerror, message: []const u8 }{
        .{ .err = error.ServiceNotAllowed, .message = "Service 'sshd' not allowed" },
        .{ .err = error.ServiceNotInstalled, .message = "Service 'sshd' not installed" },
        .{ .err = error.UnknownApplication, .message = "Unknown application x" },
        .{ .err = error.PrinterLocked, .message = "Unable to change power for psu while printing" },
        .{ .err = error.DeviceRequestFailed, .message = "Error Setting Device Status: psu to on" },
        .{ .err = error.NoPackageProvider, .message = "Cannot upgrade packages, no provider set" },
    };
    for (cases) |c| {
        const reply = try errorReply(c.err, params, a);
        try std.testing.expectEqual(@as(i64, 400), reply.rpc_code);
        try std.testing.expectEqualStrings(c.message, reply.message);
    }
    var strip: std.json.ObjectMap = .empty;
    try strip.put(a, "strip", .{ .string = "lights" });
    try std.testing.expectEqualStrings("WLED: Error", (try errorReply(error.DeviceRequestFailed, .{ .object = strip }, a)).message);
}

test "fuzz requestParams never keeps a client-supplied transport key" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const keys = [_][]const u8{ method_key, current_user_key, current_ip_key, connection_key, "x", "" };
            var src: std.json.ObjectMap = .empty;
            for (0..smith.valueRangeAtMostWithHash(u8, 0, 8, 0)) |i| {
                const k = keys[smith.valueRangeAtMostWithHash(u8, 0, keys.len - 1, @intCast(i + 1))];
                try src.put(a, k, .{ .string = "client" });
            }
            const identity = smith.valueRangeAtMostWithHash(u8, 0, 1, 99) == 1;
            const kinds = std.enums.values(TransportType);
            const kind = kinds[smith.valueRangeAtMostWithHash(u8, 0, kinds.len - 1, 98)];
            const params = try requestParams(a, src, .GET, .{ .user = "u", .transport = kind, .connection_id = 7 }, identity);
            const o = params.object;
            try std.testing.expectEqualStrings("GET", o.get(method_key).?.string);
            if (o.get(current_user_key)) |u| try std.testing.expectEqualStrings("u", u.string);
            try std.testing.expect(o.get(current_ip_key) == null);
            if (kind == .WEBSOCKET) {
                try std.testing.expectEqual(@as(i64, 7), o.get(connection_key).?.integer);
            } else try std.testing.expect(o.get(connection_key) == null);
            try std.testing.expectEqual(identity, o.get(current_user_key) != null);
        }
    }.run, .{});
}

test "successResponse and errorResponse write the Moonraker envelopes" {
    const alloc = std.testing.allocator;
    const ok = try jv.successResponse(alloc, .{ .integer = 1 }, .{ .string = "ok" });
    defer alloc.free(ok);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","result":"ok","id":1}
    , ok);
    const err = try jv.errorResponse(alloc, .null, -32601, "Method not found");
    defer alloc.free(err);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found"},"id":null}
    , err);
}

test "fuzz successResponse and errorResponse always produce parseable JSON" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            const n = smith.valueRangeAtMostWithHash(u8, 0, buf.len, 0);
            smith.bytesWithHash(buf[0..n], 1);
            // Printable ASCII plus quotes and backslashes that need escaping.
            for (buf[0..n]) |*b| b.* = 0x20 + b.* % 0x5f;
            const alloc = std.testing.allocator;
            const ok = try jv.successResponse(alloc, .{ .string = buf[0..n] }, .{ .string = buf[0..n] });
            defer alloc.free(ok);
            const err = try jv.errorResponse(alloc, .{ .integer = n }, -1, buf[0..n]);
            defer alloc.free(err);
            for ([_][]const u8{ ok, err }) |bytes| {
                const parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
                parsed.deinit();
            }
        }
    }.run, .{});
}
