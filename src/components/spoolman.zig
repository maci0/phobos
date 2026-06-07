//! server.spoolman.* API component — Moonraker-compatible spoolman integration.
//!
//! Matches the endpoints registered in
//! `vendor/moonraker/moonraker/components/spoolman.py` (SpoolManager):
//!
//!   GET/POST /server/spoolman/spool_id → server.spoolman.get_spool_id
//!                                        server.spoolman.post_spool_id
//!   POST     /server/spoolman/proxy    → server.spoolman.proxy
//!   GET      /server/spoolman/status   → server.spoolman.status
//!
//! Active spool ID is persisted in the DataStore under
//! namespace "moonraker", key "spoolman.spool_id" (matches spoolman.py).
//!
//! notify_active_spool_set is emitted (via NotifyBus.emitLocked + io) whenever
//! the active spool changes, with payload [{"spool_id": <id|null>}]. Emission
//! requires a live io; call setIo() after the App event loop starts. emitLocked
//! is used because the POST handler runs under the held Core lock.
//!
//! NOTE: phobos has an HTTP proxy client (handleProxy forwards to the configured
//! Spoolman server_url via std.http), but no persistent websocket — ws_connected
//! is always false. When no server_url is configured the proxy returns the v2
//! "not connected" error shape when use_v2_response=true, or a 503 otherwise,
//! exactly as Moonraker does.

const std = @import("std");
const registry = @import("../server/registry.zig");
const ds = @import("../store/datastore.zig");
const notify = @import("../server/notify.zig");

const Registry = registry.Registry;
const DataStore = ds.DataStore;
const NotifyBus = notify.NotifyBus;

// ---------------------------------------------------------------------------
// Persistence constants (matches spoolman.py)
// ---------------------------------------------------------------------------

const db_namespace: [:0]const u8 = "moonraker";
const active_spool_key = "spoolman.spool_id";

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

pub const SpoolmanCtx = struct {
    store: DataStore,
    bus: *NotifyBus,
    /// io is set after the event loop starts (via setIo). Notifications are
    /// only emitted when io is non-null. This avoids requiring a live event
    /// loop during App.init / dump-api / unit tests.
    io: ?std.Io,
    /// Allocator for arena-scoped notification payloads.
    gpa: std.mem.Allocator,
    /// Spoolman server URL (e.g. "http://localhost:7912"). When non-null,
    /// handleProxy forwards requests to this server; when null, proxy
    /// returns the "not connected" error shape.
    server_url: ?[]const u8,

    pub fn init(alloc: std.mem.Allocator, store: DataStore, bus: *NotifyBus, server_url: ?[]const u8) SpoolmanCtx {
        const ctx = SpoolmanCtx{
            .store = store,
            .bus = bus,
            .io = null,
            .gpa = alloc,
            .server_url = server_url,
        };
        return ctx;
    }

    /// Supply a live io so notifications can be emitted. Called after the
    /// App's event loop is running (e.g. from httpServer setup).
    pub fn setIo(self: *SpoolmanCtx, io: std.Io) void {
        self.io = io;
        // Emit current connection state now that the event loop is live.
        self.emitSpoolmanStatusChanged();
    }

    /// Set the spoolman server URL. Called when the config file is parsed
    /// (setConfig) so that handleProxy can forward requests.
    /// Emits notify_spoolman_status_changed when io is live.
    pub fn setServerUrl(self: *SpoolmanCtx, url: ?[]const u8) void {
        self.server_url = url;
        self.emitSpoolmanStatusChanged();
    }

    /// Emit notify_spoolman_status_changed with the current connected state.
    fn emitSpoolmanStatusChanged(self: *SpoolmanCtx) void {
        const io = self.io orelse return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var payload: std.json.ObjectMap = .empty;
        payload.put(a, "spoolman_connected", .{ .bool = self.server_url != null }) catch return;
        self.bus.emitLocked(io, notify.names.spoolman_status_changed, .{ .object = payload }) catch {};
    }

    fn loadSpoolId(self: *SpoolmanCtx) ?i64 {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const v = self.store.getItem(a, db_namespace, active_spool_key) catch return null;
        return switch (v orelse return null) {
            .integer => |i| i,
            .null => null,
            else => null,
        };
    }

    /// Return the active spool ID stored in the DataStore (null if none).
    pub fn getSpoolId(self: *SpoolmanCtx) ?i64 {
        return self.loadSpoolId();
    }

    /// Set the active spool ID. Persists to DataStore and, if io is set,
    /// emits notify_active_spool_set with payload [{"spool_id": <id|null>}].
    pub fn setSpoolId(self: *SpoolmanCtx, spool_id: ?i64) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const val: std.json.Value = if (spool_id) |id| .{ .integer = id } else .null;
        self.store.insertItem(a, db_namespace, active_spool_key, val) catch {};

        // Emit notification only when a live event loop is available.
        const io = self.io orelse return;
        var obj: std.json.ObjectMap = .empty;
        obj.put(a, "spool_id", val) catch return;
        var arr: std.json.Array = .init(a);
        arr.append(.{ .object = obj }) catch return;
        // setSpoolId is reached from the POST /server/spoolman/spool_id handler,
        // which runs under the held Core lock (Core.run). Re-acquiring via emit
        // would deadlock the non-reentrant mutex; use emitLocked.
        self.bus.emitLocked(io, notify.names.active_spool_set, .{ .array = arr }) catch {};
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

fn getOptBool(params: std.json.Value, field: []const u8, default_val: bool) bool {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return default_val;
            return switch (v) {
                .bool => |b| b,
                .string => |s| std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1"),
                .integer => |i| i != 0,
                else => default_val,
            };
        },
        else => return default_val,
    }
}

fn getOptInt(params: std.json.Value, field: []const u8) ?i64 {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return null;
            return switch (v) {
                .integer => |i| i,
                .null => null,
                .float => |f| @intFromFloat(f),
                .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
                else => null,
            };
        },
        else => return null,
    }
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /server/spoolman/status → spoolman connection status
/// Shape: {"spoolman_connected": false, "pending_reports": [], "spool_id": <id|null>}
pub fn handleStatus(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *SpoolmanCtx = @ptrCast(@alignCast(ctx));
    var obj: std.json.ObjectMap = .empty;
    const connected = c.server_url != null;
    try obj.put(alloc, "spoolman_connected", .{ .bool = connected });
    try obj.put(alloc, "pending_reports", .{ .array = .init(alloc) });
    const spool_id = c.getSpoolId();
    if (spool_id) |id| {
        try obj.put(alloc, "spool_id", .{ .integer = id });
    } else {
        try obj.put(alloc, "spool_id", .null);
    }
    return .{ .object = obj };
}

/// GET /server/spoolman/spool_id → {"spool_id": <id|null>}
/// POST /server/spoolman/spool_id (spool_id param) → set active spool
pub fn handleSpoolId(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *SpoolmanCtx = @ptrCast(@alignCast(ctx));
    // Determine if this is a POST (has spool_id in params object) or GET.
    // The same handler is used for both - POST sets, GET returns current.
    // When called from POST path, params will have "spool_id" key (possibly null).
    const is_post = switch (params) {
        .object => |obj| obj.contains("spool_id"),
        else => false,
    };

    if (is_post) {
        const new_id = getOptInt(params, "spool_id");
        c.setSpoolId(new_id);
    }

    var obj: std.json.ObjectMap = .empty;
    const spool_id = c.getSpoolId();
    if (spool_id) |id| {
        try obj.put(alloc, "spool_id", .{ .integer = id });
    } else {
        try obj.put(alloc, "spool_id", .null);
    }
    return .{ .object = obj };
}

fn errNotAvailable(alloc: std.mem.Allocator, use_v2: bool) anyerror!std.json.Value {
    if (use_v2) {
        var err_obj: std.json.ObjectMap = .empty;
        try err_obj.put(alloc, "status_code", .{ .integer = 503 });
        try err_obj.put(alloc, "message", .{ .string = "Spoolman server not available" });
        var obj: std.json.ObjectMap = .empty;
        try obj.put(alloc, "response", .null);
        try obj.put(alloc, "error", .{ .object = err_obj });
        return .{ .object = obj };
    }
    return error.ServiceUnavailable;
}

/// POST /server/spoolman/proxy → proxy request to Spoolman service.
///
/// When server_url is configured, forwards the request to the external
/// Spoolman HTTP service and returns the response. When server_url is null
/// (no [spoolman] server in config), returns the Moonraker-shaped
/// "not connected" error.
///
/// Supported params (mirrors spoolman.py):
///   request_method: "GET" | "POST" | "PUT" | "PATCH" | "DELETE" (required)
///   path: "/v1/..." (required, must start with /v1/)
///   query: "key=val&..." (optional, appended as ?query to the URL)
///   body: JSON object (optional, becomes the JSON request body)
///   use_v2_response: bool (optional, wraps in {response, error, response_headers})
pub fn handleProxy(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *SpoolmanCtx = @ptrCast(@alignCast(ctx));

    // Validate required params (mirrors spoolman.py param extraction).
    const request_method_str = getStr(params, "request_method") catch return error.InvalidParams;
    const path = getStr(params, "path") catch return error.InvalidParams;

    // Validate path starts with /v1/
    if (path.len < 4 or !std.mem.startsWith(u8, path, "/v1/")) {
        return error.InvalidParams;
    }

    const use_v2 = getOptBool(params, "use_v2_response", false);

    // No server configured → return "not connected" error.
    const server_url = c.server_url orelse return errNotAvailable(alloc, use_v2);

    // Parse HTTP method from the request_method string.
    const method = std.meta.stringToEnum(std.http.Method, request_method_str) orelse return error.InvalidParams;

    // Reject GET requests with body before io check (parameter validation).
    if (method == .GET) {
        if (params == .object) {
            if (params.object.get("body")) |body_val| {
                if (body_val != .null) return error.InvalidParams;
            }
        }
    }

    // Need a live io for the HTTP client; absent during tests / dump-api.
    const io = c.io orelse return errNotAvailable(alloc, use_v2);

    // Extract optional query string (mirrors spoolman.py).
    const query = getOptStr(params, "query");

    // Build the full URL from server_url + path [+ ?query].
    var url_buf: [2048]u8 = undefined;
    const full_url = if (query) |q|
        std.fmt.bufPrint(&url_buf, "{s}{s}?{s}", .{ server_url, path, q }) catch return errNotAvailable(alloc, use_v2)
    else
        std.fmt.bufPrint(&url_buf, "{s}{s}", .{ server_url, path }) catch return errNotAvailable(alloc, use_v2);

    // Serialize the body parameter to JSON if present.
    var body_json_buf: [4096]u8 = undefined;
    var body_slice: ?[]const u8 = null;
    if (params == .object) {
        if (params.object.get("body")) |body_val| {
            if (body_val != .null) {
                var w: std.Io.Writer = .fixed(&body_json_buf);
                var jw: std.json.Stringify = .{ .writer = &w };
                jw.write(body_val) catch return errNotAvailable(alloc, use_v2);
                body_slice = w.buffered();
            }
        }
    }

    // Use an arena for temporary allocations during the HTTP round-trip.
    var arena = std.heap.ArenaAllocator.init(c.gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var client: std.http.Client = .{ .allocator = aa, .io = io };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(aa);
    defer aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = full_url },
        .method = method,
        .payload = body_slice,
        .response_writer = &aw.writer,
    }) catch return errNotAvailable(alloc, use_v2);

    // Check for non-success HTTP status.
    if (result.status != .ok and result.status != .created and result.status != .no_content) {
        if (use_v2) {
            var err_obj: std.json.ObjectMap = .empty;
            try err_obj.put(alloc, "status_code", .{ .integer = @intFromEnum(result.status) });
            try err_obj.put(alloc, "message", .{ .string = "Spoolman request failed" });
            var obj: std.json.ObjectMap = .empty;
            try obj.put(alloc, "response", .null);
            try obj.put(alloc, "error", .{ .object = err_obj });
            return .{ .object = obj };
        }
        return error.ServiceUnavailable;
    }

    const response_body = aw.toOwnedSlice() catch return errNotAvailable(alloc, use_v2);

    // Parse the response as JSON (spoolman returns JSON).
    var response_val: std.json.Value = .null;
    if (response_body.len > 0) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, response_body, .{}) catch {
            // Fallback: return the raw body as a string.
            return .{ .string = try alloc.dupe(u8, response_body) };
        };
        response_val = parsed.value;
    }

    if (use_v2) {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(alloc, "response", response_val);
        try obj.put(alloc, "error", .null);
        // response_headers: use empty map (fetch API doesn't expose headers).
        // The Python reference includes dict(resp.headers.items()); a future
        // switch to client.request() would enable full header capture.
        try obj.put(alloc, "response_headers", .{ .object = .empty });
        return .{ .object = obj };
    }

    return response_val;
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------
//
// spoolman.py registers spool_id with RequestType.GET | RequestType.POST
// which in the baseline scanner produces multi_verb names:
//   server.spoolman.get_spool_id, server.spoolman.post_spool_id
//
// Strategy: register GET+POST together (multi=true) for spool_id,
// single-verb for proxy and status.

pub fn registerSpoolman(reg: *Registry, ctx: *SpoolmanCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    // /server/spoolman/spool_id — GET+POST → multi-verb names
    try reg.registerEndpoint(
        .{ .path = "/server/spoolman/spool_id", .methods = &.{ .GET, .POST } },
        c,
        handleSpoolId,
    );

    // /server/spoolman/proxy — POST only → "server.spoolman.proxy"
    try reg.registerEndpoint(
        .{ .path = "/server/spoolman/proxy", .methods = &.{.POST} },
        c,
        handleProxy,
    );

    // /server/spoolman/status — GET only → "server.spoolman.status"
    try reg.registerEndpoint(
        .{ .path = "/server/spoolman/status", .methods = &.{.GET} },
        c,
        handleStatus,
    );

    // Klipper remote method: gcode macros can set the active spool
    // (Moonraker register_remote_method("spoolman_set_active_spool", ...)).
    try reg.dispatcher.register("spoolman_set_active_spool", c, handleSetActiveSpool);
}

/// Klipper remote method `spoolman_set_active_spool` → setSpoolId. Params carry
/// `spool_id` (int or null). Returns null (remote methods produce no response).
pub fn handleSetActiveSpool(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    _ = alloc;
    const c: *SpoolmanCtx = @ptrCast(@alignCast(ctx_ptr));
    const sid: ?i64 = switch (params) {
        .object => |o| switch (o.get("spool_id") orelse .null) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => null,
        },
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
    c.setSpoolId(sid);
    return .null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const ds_mod = @import("../store/datastore.zig");
const Core = @import("../server/core.zig").Core;
const connections_mod = @import("../server/connections.zig");

fn mkParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    return p.value;
}

// Minimal null bus for tests.
const NullBus = struct {
    core: Core,
    conns_obj: connections_mod.Connections,
    bus: NotifyBus,

    fn init(alloc: std.mem.Allocator) NullBus {
        var nb: NullBus = undefined;
        nb.core = Core.init();
        nb.conns_obj = connections_mod.Connections.init(alloc, &nb.core);
        nb.bus = NotifyBus.init(&nb.core, &nb.conns_obj);
        return nb;
    }
};

// Minimal memory-backed DataStore for unit tests.
const MemStore = struct {
    alloc: std.mem.Allocator,
    data: std.StringHashMap(std.json.Value),

    fn init(alloc: std.mem.Allocator) MemStore {
        return .{ .alloc = alloc, .data = std.StringHashMap(std.json.Value).init(alloc) };
    }

    fn deinit(self: *MemStore) void {
        self.data.deinit();
    }

    fn vtGetItem(ctx: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, key: []const u8) ds_mod.Error!?std.json.Value {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        return self.data.get(key);
    }

    fn vtInsertItem(ctx: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, key: []const u8, value: std.json.Value) ds_mod.Error!void {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        self.data.put(key, value) catch return ds_mod.Error.OutOfMemory;
    }

    fn vtUpdateItem(ctx: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, key: []const u8, value: std.json.Value) ds_mod.Error!void {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        self.data.put(key, value) catch return ds_mod.Error.OutOfMemory;
    }

    fn vtDeleteItem(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: []const u8) ds_mod.Error!std.json.Value {
        return ds_mod.Error.KeyNotFound;
    }

    fn vtListNamespaces(_: *anyopaque, arena: std.mem.Allocator) ds_mod.Error![][]const u8 {
        return arena.alloc([]const u8, 0);
    }

    fn vtGetNamespace(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8) ds_mod.Error!std.json.Value {
        return .{ .object = .empty };
    }

    const vtable: ds_mod.VTable = .{
        .getItem = vtGetItem,
        .insertItem = vtInsertItem,
        .updateItem = vtUpdateItem,
        .deleteItem = vtDeleteItem,
        .listNamespaces = vtListNamespaces,
        .getNamespace = vtGetNamespace,
    };

    fn dataStore(self: *MemStore) DataStore {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

fn makeCtx(alloc: std.mem.Allocator, mem: *MemStore, nb: *NullBus) SpoolmanCtx {
    return SpoolmanCtx.init(alloc, mem.dataStore(), &nb.bus, null);
}

test "handleStatus: returns correct shape with no active spool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = makeCtx(a, &mem, &nb);

    const result = try handleStatus(@ptrCast(&ctx), .null, a);
    try testing.expectEqual(false, result.object.get("spoolman_connected").?.bool);
    try testing.expectEqual(.null, result.object.get("spool_id").?);
    try testing.expectEqual(@as(usize, 0), result.object.get("pending_reports").?.array.items.len);
}

test "handleSpoolId GET: returns null when no spool set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = makeCtx(a, &mem, &nb);

    const result = try handleSpoolId(@ptrCast(&ctx), .null, a);
    try testing.expectEqual(.null, result.object.get("spool_id").?);
}

test "handleSpoolId POST: sets active spool and persists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = makeCtx(a, &mem, &nb);

    // POST with spool_id = 42
    const params = try mkParams(a, "{\"spool_id\": 42}");
    const result = try handleSpoolId(@ptrCast(&ctx), params, a);
    try testing.expectEqual(@as(i64, 42), result.object.get("spool_id").?.integer);

    // Verify persistence via GET (no spool_id in params)
    const get_result = try handleSpoolId(@ptrCast(&ctx), .null, a);
    try testing.expectEqual(@as(i64, 42), get_result.object.get("spool_id").?.integer);
}

test "handleSetActiveSpool: remote method sets/clears the active spool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = makeCtx(a, &mem, &nb);

    // Set via the remote method.
    _ = try handleSetActiveSpool(@ptrCast(&ctx), try mkParams(a, "{\"spool_id\": 7}"), a);
    try testing.expectEqual(@as(i64, 7), (try handleSpoolId(@ptrCast(&ctx), .null, a)).object.get("spool_id").?.integer);

    // Clear via the remote method (spool_id null).
    _ = try handleSetActiveSpool(@ptrCast(&ctx), try mkParams(a, "{\"spool_id\": null}"), a);
    try testing.expectEqual(std.json.Value.null, (try handleSpoolId(@ptrCast(&ctx), .null, a)).object.get("spool_id").?);
}

test "fuzz handleSetActiveSpool: arbitrary params never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var mem = MemStore.init(a);
            defer mem.deinit();
            var nb = NullBus.init(a);
            var ctx = makeCtx(a, &mem, &nb);
            var buf: [32]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const p = std.json.parseFromSlice(std.json.Value, a, &buf, .{}) catch return;
            _ = handleSetActiveSpool(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "handleSpoolId POST: set to null clears active spool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = makeCtx(a, &mem, &nb);

    // Set first
    const set_params = try mkParams(a, "{\"spool_id\": 5}");
    _ = try handleSpoolId(@ptrCast(&ctx), set_params, a);

    // Clear (spool_id: null)
    const clear_params = try mkParams(a, "{\"spool_id\": null}");
    const result = try handleSpoolId(@ptrCast(&ctx), clear_params, a);
    try testing.expectEqual(.null, result.object.get("spool_id").?);
}

test "handleProxy: missing request_method → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = makeCtx(a, &mem, &nb);

    try testing.expectError(error.InvalidParams, handleProxy(@ptrCast(&ctx), .null, a));
}

test "handleProxy: invalid path → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = makeCtx(a, &mem, &nb);

    const params = try mkParams(a, "{\"request_method\": \"GET\", \"path\": \"/bad\"}");
    try testing.expectError(error.InvalidParams, handleProxy(@ptrCast(&ctx), params, a));
}

test "handleProxy: not connected → ServiceUnavailable (non-v2)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = makeCtx(a, &mem, &nb);

    const params = try mkParams(a, "{\"request_method\": \"GET\", \"path\": \"/v1/spool\"}");
    try testing.expectError(error.ServiceUnavailable, handleProxy(@ptrCast(&ctx), params, a));
}

test "handleProxy: not connected → v2 error shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = makeCtx(a, &mem, &nb);

    const params = try mkParams(a, "{\"request_method\": \"GET\", \"path\": \"/v1/spool\", \"use_v2_response\": true}");
    const result = try handleProxy(@ptrCast(&ctx), params, a);
    try testing.expectEqual(.null, result.object.get("response").?);
    const err = result.object.get("error").?.object;
    try testing.expectEqual(@as(i64, 503), err.get("status_code").?.integer);
}

test "spoolman active-spool persistence round-trip: set then reload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = makeCtx(a, &mem, &nb);

    // Set spool ID
    ctx.setSpoolId(77);

    // Create a new context from the same datastore (simulates restart)
    var ctx2 = SpoolmanCtx.init(a, mem.dataStore(), &nb.bus, null);
    try testing.expectEqual(@as(?i64, 77), ctx2.getSpoolId());
}

test "registerSpoolman: wires expected routes and JSON-RPC methods" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");

    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var mem = MemStore.init(alloc);
    defer mem.deinit();
    var nb = NullBus.init(alloc);
    var ctx = SpoolmanCtx.init(alloc, mem.dataStore(), &nb.bus, null);

    try registerSpoolman(&reg, &ctx);

    // HTTP routes
    try testing.expect(reg.lookup(.GET, "/server/spoolman/spool_id") != null);
    try testing.expect(reg.lookup(.POST, "/server/spoolman/spool_id") != null);
    try testing.expect(reg.lookup(.POST, "/server/spoolman/proxy") != null);
    try testing.expect(reg.lookup(.GET, "/server/spoolman/status") != null);

    // JSON-RPC methods
    try testing.expect(d.methods.get("server.spoolman.get_spool_id") != null);
    try testing.expect(d.methods.get("server.spoolman.post_spool_id") != null);
    try testing.expect(d.methods.get("server.spoolman.proxy") != null);
    try testing.expect(d.methods.get("server.spoolman.status") != null);
    try testing.expect(d.methods.get("spoolman_set_active_spool") != null);
}

// --- Fuzz tests ---

test "handleProxy: query parameter is accepted (not-connected path)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = makeCtx(a, &mem, &nb);

    const params = try mkParams(a, "{\"request_method\": \"GET\", \"path\": \"/v1/spool\", \"query\": \"key=value\"}");
    // No server_url → returns ServiceUnavailable, but query param is valid.
    try testing.expectError(error.ServiceUnavailable, handleProxy(@ptrCast(&ctx), params, a));
}

test "handleProxy: GET with body returns InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = makeCtx(a, &mem, &nb);

    // Set server_url so we get past the "not connected" check and hit the GET+body check.
    ctx.setServerUrl("http://localhost:7912");

    const params = try mkParams(a, "{\"request_method\": \"GET\", \"path\": \"/v1/spool\", \"body\": {\"key\": 1}}");
    try testing.expectError(error.InvalidParams, handleProxy(@ptrCast(&ctx), params, a));
}

test "handleProxy: v2 error shape includes response and error keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = makeCtx(a, &mem, &nb);

    const params = try mkParams(a, "{\"request_method\": \"GET\", \"path\": \"/v1/spool\", \"use_v2_response\": true}");
    const result = try handleProxy(@ptrCast(&ctx), params, a);
    // v2 error shape: {"response": null, "error": {"status_code": 503, ...}}
    try testing.expect(result.object.get("response") != null);
    try testing.expectEqual(.null, result.object.get("response").?);
    try testing.expect(result.object.get("error") != null);
    try testing.expect(result.object.get("error").? == .object);
}

test "handleProxy: query with special characters is accepted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = makeCtx(a, &mem, &nb);

    const params = try mkParams(a, "{\"request_method\": \"GET\", \"path\": \"/v1/spool\", \"query\": \"a=1&b=2\"}");
    try testing.expectError(error.ServiceUnavailable, handleProxy(@ptrCast(&ctx), params, a));
}

test "setServerUrl: updates status and does not crash without io" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = makeCtx(a, &mem, &nb);

    // Verify state tracks server_url.
    try testing.expect(ctx.server_url == null);
    ctx.setServerUrl("http://localhost:7912");
    try testing.expectEqualStrings("http://localhost:7912", ctx.server_url.?);
    try testing.expect(ctx.server_url != null);

    // Status handler reflects the change.
    const status = try handleStatus(@ptrCast(&ctx), .null, a);
    try testing.expectEqual(true, status.object.get("spoolman_connected").?.bool);
}

test "setServerUrl: clearing url marks disconnected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = makeCtx(a, &mem, &nb);

    ctx.setServerUrl("http://localhost:7912");
    ctx.setServerUrl(null);
    try testing.expect(ctx.server_url == null);

    const status = try handleStatus(@ptrCast(&ctx), .null, a);
    try testing.expectEqual(false, status.object.get("spoolman_connected").?.bool);
}

test "fuzz handleSpoolId: never panics on arbitrary params" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var mem = MemStore.init(a);
            defer mem.deinit();
            var nb = NullBus.init(a);
            var ctx = makeCtx(a, &mem, &nb);

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"spool_id\": 1}",
                "{\"spool_id\": null}",
                "{\"spool_id\": \"bad\"}",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            _ = handleSpoolId(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleProxy: never panics on arbitrary params" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var mem = MemStore.init(a);
            defer mem.deinit();
            var nb = NullBus.init(a);
            var ctx = makeCtx(a, &mem, &nb);

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"request_method\": \"GET\", \"path\": \"/v1/spool\"}",
                "{\"request_method\": \"POST\", \"path\": \"/v1/spool\", \"use_v2_response\": true}",
                "{\"request_method\": \"GET\", \"path\": \"/bad\"}",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            _ = handleProxy(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleStatus: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var mem = MemStore.init(a);
            defer mem.deinit();
            var nb = NullBus.init(a);
            var ctx = makeCtx(a, &mem, &nb);

            var buf: [4]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = handleStatus(@ptrCast(&ctx), .null, a) catch {};
        }
    }.run, .{});
}
