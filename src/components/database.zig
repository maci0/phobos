//! server.database.* API component — Moonraker-compatible namespaced key/value
//! store endpoints.
//!
//! Matches the endpoints registered in
//! `vendor/moonraker/moonraker/components/database.py`:
//!
//!   GET    /server/database/list    → server.database.list
//!   GET    /server/database/item    → server.database.item  (JSON-RPC GET semantics)
//!   POST   /server/database/item    → HTTP only (no separate JSON-RPC name)
//!   DELETE /server/database/item    → HTTP only (no separate JSON-RPC name)
//!   POST   /server/database/compact → server.database.compact
//!   POST   /server/database/backup  → server.database.post_backup
//!   DELETE /server/database/backup  → server.database.delete_backup
//!   POST   /server/database/restore → server.database.restore
//!   GET    /debug/database/list     → debug.database.list
//!   GET    /debug/database/item     → debug.database.item
//!   POST   /debug/database/item     → HTTP only
//!   DELETE /debug/database/item     → HTTP only
//!   GET    /debug/database/table    → debug.database.table
//!
//! Namespace access rules (database.py):
//!   - forbidden_namespaces {"database"}: no API read or write access.
//!   - protected_namespaces {"moonraker"}: read-only via public API; debug
//!     endpoints bypass the write restriction.
//!
//! Response shapes match Moonraker exactly:
//!   list    → {"namespaces": [...], "backups": [...]}
//!   item    → {"namespace": "ns", "key": "k", "value": <v>}
//!   compact → {"old_size": 0, "new_size": 0}  (stub)
//!   backup  → {"backup_path": ""}             (stub)
//!   restore → {"status": "ok"}                (stub)
//!
//! NOTE: compact/backup/restore are registered with faithful response shapes.
//! The underlying compact/backup/restore operations are stubs.

const std = @import("std");
const registry = @import("../server/registry.zig");
const ds = @import("../store/datastore.zig");

const Registry = registry.Registry;
const DataStore = ds.DataStore;

// ---------------------------------------------------------------------------
// Namespace access policy (mirrors database.py defaults)
// ---------------------------------------------------------------------------

/// Namespaces with NO API access whatsoever (read or write). Not configurable
/// through the public API. Mirrors database.py `forbidden_namespaces`.
pub const default_forbidden_namespaces = [_][]const u8{"database"};

/// Namespaces with read-only public API access. Mirrors database.py
/// `protected_namespaces`.
pub const default_protected_namespaces = [_][]const u8{"moonraker"};

pub fn isForbidden(namespace: []const u8) bool {
    for (default_forbidden_namespaces) |ns| {
        if (std.mem.eql(u8, ns, namespace)) return true;
    }
    return false;
}

pub fn isProtected(namespace: []const u8) bool {
    for (default_protected_namespaces) |ns| {
        if (std.mem.eql(u8, ns, namespace)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Context passed to every handler
// ---------------------------------------------------------------------------

pub const DbCtx = struct {
    store: DataStore,
};

// ---------------------------------------------------------------------------
// Parameter extraction helpers
// ---------------------------------------------------------------------------

/// Required string param. Returns `error.InvalidParams` if absent or non-string.
pub fn getStr(params: std.json.Value, field: []const u8) error{InvalidParams}![]const u8 {
    const obj = switch (params) {
        .object => |o| o,
        else => return error.InvalidParams,
    };
    const v = obj.get(field) orelse return error.InvalidParams;
    return switch (v) {
        .string => |s| s,
        else => error.InvalidParams,
    };
}

/// Optional string param. Returns null when the field is absent or null.
pub fn getOptStr(params: std.json.Value, field: []const u8) error{InvalidParams}!?[]const u8 {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return null;
            return switch (v) {
                .string => |s| s,
                .null => null,
                else => error.InvalidParams,
            };
        },
        else => return null,
    }
}

/// The `value` param — any JSON value is accepted. Returns `error.InvalidParams`
/// when the key is absent.
pub fn getValue(params: std.json.Value) error{InvalidParams}!std.json.Value {
    const obj = switch (params) {
        .object => |o| o,
        else => return error.InvalidParams,
    };
    return obj.get("value") orelse error.InvalidParams;
}

// ---------------------------------------------------------------------------
// Response builders
// ---------------------------------------------------------------------------

fn buildListResponse(
    alloc: std.mem.Allocator,
    namespaces: []const []const u8,
    backups: []const []const u8,
) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;

    var ns_arr: std.json.Array = .init(alloc);
    for (namespaces) |ns| try ns_arr.append(.{ .string = ns });
    try obj.put(alloc, "namespaces", .{ .array = ns_arr });

    var bkp_arr: std.json.Array = .init(alloc);
    for (backups) |bkp| try bkp_arr.append(.{ .string = bkp });
    try obj.put(alloc, "backups", .{ .array = bkp_arr });

    return .{ .object = obj };
}

fn buildItemResponse(
    alloc: std.mem.Allocator,
    namespace: []const u8,
    key: ?[]const u8,
    value: std.json.Value,
) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "namespace", .{ .string = namespace });
    if (key) |k| {
        try obj.put(alloc, "key", .{ .string = k });
    } else {
        try obj.put(alloc, "key", .null);
    }
    try obj.put(alloc, "value", value);
    return .{ .object = obj };
}

// ---------------------------------------------------------------------------
// /server/database/list (GET)
// ---------------------------------------------------------------------------

pub fn handleList(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *DbCtx = @ptrCast(@alignCast(ctx));
    return handleListImpl(c, params, alloc, false);
}

pub fn handleListDebug(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *DbCtx = @ptrCast(@alignCast(ctx));
    return handleListImpl(c, params, alloc, true);
}

fn handleListImpl(
    c: *DbCtx,
    _: std.json.Value,
    alloc: std.mem.Allocator,
    is_debug: bool,
) anyerror!std.json.Value {
    const all_ns = try c.store.listNamespaces(alloc);

    var visible: std.ArrayList([]const u8) = .empty;
    for (all_ns) |ns| {
        if (!is_debug and isForbidden(ns)) continue;
        try visible.append(alloc, ns);
    }

    // Backups: stub (no SQLite backup dir in phobos).
    const backups: []const []const u8 = &.{};
    return buildListResponse(alloc, visible.items, backups);
}

// ---------------------------------------------------------------------------
// /server/database/item (GET)
// /debug/database/item  (GET)
// ---------------------------------------------------------------------------

pub fn handleGetItem(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *DbCtx = @ptrCast(@alignCast(ctx));
    return handleItemGet(c, params, alloc, false);
}

pub fn handleGetItemDebug(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *DbCtx = @ptrCast(@alignCast(ctx));
    return handleItemGet(c, params, alloc, true);
}

fn handleItemGet(
    c: *DbCtx,
    params: std.json.Value,
    alloc: std.mem.Allocator,
    is_debug: bool,
) anyerror!std.json.Value {
    const namespace = try getStr(params, "namespace");
    if (!is_debug and isForbidden(namespace)) return error.Forbidden;

    const key_opt = try getOptStr(params, "key");
    const ns_z = try alloc.dupeZ(u8, namespace);

    const value: std.json.Value = if (key_opt) |key| blk: {
        const v = try c.store.getItem(alloc, ns_z, key);
        break :blk v orelse return error.NotFound;
    } else blk: {
        break :blk try c.store.getNamespace(alloc, ns_z);
    };

    return buildItemResponse(alloc, namespace, key_opt, value);
}

// ---------------------------------------------------------------------------
// /server/database/item (POST)
// /debug/database/item  (POST)
// ---------------------------------------------------------------------------

pub fn handlePostItem(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *DbCtx = @ptrCast(@alignCast(ctx));
    return handleItemPost(c, params, alloc, false);
}

pub fn handlePostItemDebug(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *DbCtx = @ptrCast(@alignCast(ctx));
    return handleItemPost(c, params, alloc, true);
}

fn handleItemPost(
    c: *DbCtx,
    params: std.json.Value,
    alloc: std.mem.Allocator,
    is_debug: bool,
) anyerror!std.json.Value {
    const namespace = try getStr(params, "namespace");
    if (!is_debug and isForbidden(namespace)) return error.Forbidden;
    if (!is_debug and isProtected(namespace)) return error.Forbidden;

    const key = try getStr(params, "key");
    const value = try getValue(params);
    const ns_z = try alloc.dupeZ(u8, namespace);

    try c.store.insertItem(alloc, ns_z, key, value);
    return buildItemResponse(alloc, namespace, key, value);
}

// ---------------------------------------------------------------------------
// /server/database/item (DELETE)
// /debug/database/item  (DELETE)
// ---------------------------------------------------------------------------

pub fn handleDeleteItem(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *DbCtx = @ptrCast(@alignCast(ctx));
    return handleItemDelete(c, params, alloc, false);
}

pub fn handleDeleteItemDebug(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *DbCtx = @ptrCast(@alignCast(ctx));
    return handleItemDelete(c, params, alloc, true);
}

fn handleItemDelete(
    c: *DbCtx,
    params: std.json.Value,
    alloc: std.mem.Allocator,
    is_debug: bool,
) anyerror!std.json.Value {
    const namespace = try getStr(params, "namespace");
    if (!is_debug and isForbidden(namespace)) return error.Forbidden;
    if (!is_debug and isProtected(namespace)) return error.Forbidden;

    const key = try getStr(params, "key");
    const ns_z = try alloc.dupeZ(u8, namespace);

    const removed = c.store.deleteItem(alloc, ns_z, key) catch |err| switch (err) {
        ds.Error.KeyNotFound, ds.Error.NamespaceNotFound => return error.NotFound,
        else => return err,
    };
    return buildItemResponse(alloc, namespace, key, removed);
}

// ---------------------------------------------------------------------------
// /debug/database/table (GET)
// ---------------------------------------------------------------------------
// Stub: compact/backup/restore not implemented. Registered for API-surface coverage.

pub fn handleTableDebug(_: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const table = try getStr(params, "table");
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "table_name", .{ .string = table });
    try obj.put(alloc, "rows", .{ .array = .init(alloc) });
    return .{ .object = obj };
}

// ---------------------------------------------------------------------------
// /server/database/compact (POST)
// ---------------------------------------------------------------------------
// Stub: SQLite VACUUM equivalent. Returns shape matching Moonraker.

pub fn handleCompact(_: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "old_size", .{ .integer = 0 });
    try obj.put(alloc, "new_size", .{ .integer = 0 });
    return .{ .object = obj };
}

// ---------------------------------------------------------------------------
// /server/database/backup (POST + DELETE)
// ---------------------------------------------------------------------------
// Stub: SQLite backup. Returns shape matching Moonraker.

pub fn handleBackup(_: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "backup_path", .{ .string = "" });
    return .{ .object = obj };
}

// ---------------------------------------------------------------------------
// /server/database/restore (POST)
// ---------------------------------------------------------------------------
// Stub: SQLite restore. Returns shape matching Moonraker.

pub fn handleRestore(_: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "status", .{ .string = "ok" });
    return .{ .object = obj };
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------
//
// JSON-RPC naming strategy for /server/database/item:
//
//   The Moonraker baseline expects the single method name "server.database.item"
//   (not the multi-verb prefixed names get_item/post_item/delete_item), because
//   Moonraker uses RequestType.all() which baseline scanner classifies as
//   multi_verb=False with a single JSON-RPC name.
//
//   In phobos, `deriveMethodName` produces a non-prefixed name when multi=false
//   (single-verb registration). Strategy:
//     • Register GET with default transports → creates "server.database.item"
//       JSON-RPC method (GET semantics over RPC).
//     • Register POST and DELETE as HTTP-only (transports = &.{.HTTP}) →
//       no JSON-RPC methods created; per-verb HTTP routes still exist.
//
//   Same logic for /debug/database/item → "debug.database.item".
//
//   For /server/database/backup (POST + DELETE), the baseline has two separate
//   JSON-RPC names: server.database.post_backup and server.database.delete_backup.
//   That is the multi-verb naming, so it is registered with both verbs in one
//   call (multi=true → prefixed names).

pub fn registerDatabase(reg: *Registry, ctx: *DbCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    // ---- /server/database/list ----
    try reg.registerEndpoint(
        .{ .path = "/server/database/list", .methods = &.{.GET} },
        c,
        handleList,
    );

    // ---- /server/database/item ----
    // GET: normal transports → derives "server.database.item" JSON-RPC method.
    try reg.registerEndpoint(
        .{ .path = "/server/database/item", .methods = &.{.GET} },
        c,
        handleGetItem,
    );
    // POST: HTTP-only → no JSON-RPC method (baseline has no post_item name).
    try reg.registerEndpoint(
        .{ .path = "/server/database/item", .methods = &.{.POST}, .transports = &.{.HTTP} },
        c,
        handlePostItem,
    );
    // DELETE: HTTP-only → no JSON-RPC method.
    try reg.registerEndpoint(
        .{ .path = "/server/database/item", .methods = &.{.DELETE}, .transports = &.{.HTTP} },
        c,
        handleDeleteItem,
    );

    // ---- /server/database/compact ----
    try reg.registerEndpoint(
        .{ .path = "/server/database/compact", .methods = &.{.POST} },
        c,
        handleCompact,
    );

    // ---- /server/database/backup ----
    // POST + DELETE in one call → multi-verb → "server.database.post_backup"
    // and "server.database.delete_backup".
    try reg.registerEndpoint(
        .{ .path = "/server/database/backup", .methods = &.{ .POST, .DELETE } },
        c,
        handleBackup,
    );

    // ---- /server/database/restore ----
    try reg.registerEndpoint(
        .{ .path = "/server/database/restore", .methods = &.{.POST} },
        c,
        handleRestore,
    );

    // ---- /debug/database/list ----
    // Debug endpoints: Moonraker uses `register_debug_endpoint` which in
    // production includes WEBSOCKET transport (so the JSON-RPC method
    // "debug.database.list" is derived). Replicate that here.
    try reg.registerEndpoint(
        .{ .path = "/debug/database/list", .methods = &.{.GET} },
        c,
        handleListDebug,
    );

    // ---- /debug/database/item ----
    // GET: normal transports → derives "debug.database.item" JSON-RPC method.
    try reg.registerEndpoint(
        .{ .path = "/debug/database/item", .methods = &.{.GET} },
        c,
        handleGetItemDebug,
    );
    // POST: HTTP-only.
    try reg.registerEndpoint(
        .{ .path = "/debug/database/item", .methods = &.{.POST}, .transports = &.{.HTTP} },
        c,
        handlePostItemDebug,
    );
    // DELETE: HTTP-only.
    try reg.registerEndpoint(
        .{ .path = "/debug/database/item", .methods = &.{.DELETE}, .transports = &.{.HTTP} },
        c,
        handleDeleteItemDebug,
    );

    // ---- /debug/database/table ----
    try reg.registerEndpoint(
        .{ .path = "/debug/database/table", .methods = &.{.GET} },
        c,
        handleTableDebug,
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// --- In-memory backend for unit tests (no real store required) ---

const MemNamespace = struct {
    name: []const u8,
    data: std.StringHashMap(std.json.Value),

    fn init(alloc: std.mem.Allocator, name: []const u8) MemNamespace {
        return .{ .name = name, .data = std.StringHashMap(std.json.Value).init(alloc) };
    }

    fn deinit(self: *MemNamespace) void {
        self.data.deinit();
    }
};

const MemStore = struct {
    alloc: std.mem.Allocator,
    namespaces: std.ArrayList(MemNamespace),

    fn init(alloc: std.mem.Allocator) MemStore {
        return .{ .alloc = alloc, .namespaces = .empty };
    }

    fn deinit(self: *MemStore) void {
        for (self.namespaces.items) |*ns| ns.deinit();
        self.namespaces.deinit(self.alloc);
    }

    fn getNs(self: *MemStore, name: []const u8) ?*MemNamespace {
        for (self.namespaces.items) |*ns| {
            if (std.mem.eql(u8, ns.name, name)) return ns;
        }
        return null;
    }

    fn getOrCreateNs(self: *MemStore, name: []const u8) !*MemNamespace {
        if (self.getNs(name)) |n| return n;
        try self.namespaces.append(self.alloc, .init(self.alloc, name));
        return &self.namespaces.items[self.namespaces.items.len - 1];
    }

    fn vtGetItem(ctx: *anyopaque, _: std.mem.Allocator, ns: [:0]const u8, key: []const u8) ds.Error!?std.json.Value {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        const n = self.getNs(ns) orelse return null;
        return n.data.get(key);
    }

    fn vtInsertItem(ctx: *anyopaque, _: std.mem.Allocator, ns: [:0]const u8, key: []const u8, value: std.json.Value) ds.Error!void {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        const n = self.getOrCreateNs(ns) catch return ds.Error.OutOfMemory;
        n.data.put(key, value) catch return ds.Error.OutOfMemory;
    }

    fn vtUpdateItem(ctx: *anyopaque, _: std.mem.Allocator, ns: [:0]const u8, key: []const u8, value: std.json.Value) ds.Error!void {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        const n = self.getNs(ns) orelse return ds.Error.NamespaceNotFound;
        if (!n.data.contains(key)) return ds.Error.KeyNotFound;
        n.data.put(key, value) catch return ds.Error.OutOfMemory;
    }

    fn vtDeleteItem(ctx: *anyopaque, _: std.mem.Allocator, ns: [:0]const u8, key: []const u8) ds.Error!std.json.Value {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        const n = self.getNs(ns) orelse return ds.Error.KeyNotFound;
        const v = n.data.get(key) orelse return ds.Error.KeyNotFound;
        _ = n.data.remove(key);
        return v;
    }

    fn vtListNamespaces(ctx: *anyopaque, arena: std.mem.Allocator) ds.Error![][]const u8 {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        var out: std.ArrayList([]const u8) = .empty;
        for (self.namespaces.items) |*ns| {
            out.append(arena, ns.name) catch return ds.Error.OutOfMemory;
        }
        return out.toOwnedSlice(arena) catch return ds.Error.OutOfMemory;
    }

    fn vtGetNamespace(ctx: *anyopaque, arena: std.mem.Allocator, ns: [:0]const u8) ds.Error!std.json.Value {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        const n = self.getNs(ns) orelse return .{ .object = .empty };
        var obj: std.json.ObjectMap = .empty;
        var it = n.data.iterator();
        while (it.next()) |e| {
            obj.put(arena, e.key_ptr.*, e.value_ptr.*) catch return ds.Error.OutOfMemory;
        }
        return .{ .object = obj };
    }

    const vtable: ds.VTable = .{
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

fn makeCtx(alloc: std.mem.Allocator, mem: *MemStore) DbCtx {
    _ = alloc;
    return .{ .store = mem.dataStore() };
}

fn mkParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    return p.value;
}

// ---- Unit tests ----

test "handleList: filters forbidden namespaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    _ = try mem.getOrCreateNs("myns");
    _ = try mem.getOrCreateNs("database"); // forbidden
    _ = try mem.getOrCreateNs("moonraker"); // protected but visible

    var ctx = makeCtx(a, &mem);
    const result = try handleList(@ptrCast(&ctx), .null, a);
    const ns_arr = result.object.get("namespaces").?.array;

    var found_myns = false;
    var found_database = false;
    for (ns_arr.items) |item| {
        if (std.mem.eql(u8, item.string, "myns")) found_myns = true;
        if (std.mem.eql(u8, item.string, "database")) found_database = true;
    }
    try testing.expect(found_myns);
    try testing.expect(!found_database); // forbidden → hidden
    try testing.expect(result.object.get("backups") != null);
}

test "handleListDebug: includes forbidden namespaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    _ = try mem.getOrCreateNs("database");

    var ctx = makeCtx(a, &mem);
    const result = try handleListDebug(@ptrCast(&ctx), .null, a);
    const ns_arr = result.object.get("namespaces").?.array;

    var found = false;
    for (ns_arr.items) |item| {
        if (std.mem.eql(u8, item.string, "database")) found = true;
    }
    try testing.expect(found);
}

test "handlePostItem + handleGetItem: value round-trips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = makeCtx(a, &mem);

    const post_params = try mkParams(a, "{\"namespace\":\"testns\",\"key\":\"mykey\",\"value\":42}");
    const post_result = try handlePostItem(@ptrCast(&ctx), post_params, a);
    try testing.expectEqualStrings("testns", post_result.object.get("namespace").?.string);
    try testing.expectEqualStrings("mykey", post_result.object.get("key").?.string);
    try testing.expectEqual(@as(i64, 42), post_result.object.get("value").?.integer);

    const get_params = try mkParams(a, "{\"namespace\":\"testns\",\"key\":\"mykey\"}");
    const get_result = try handleGetItem(@ptrCast(&ctx), get_params, a);
    try testing.expectEqualStrings("testns", get_result.object.get("namespace").?.string);
    try testing.expectEqualStrings("mykey", get_result.object.get("key").?.string);
    try testing.expectEqual(@as(i64, 42), get_result.object.get("value").?.integer);
}

test "handleDeleteItem: removes key and returns removed value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = makeCtx(a, &mem);

    const ns = try mem.getOrCreateNs("delns");
    try ns.data.put("k", .{ .string = "removed_val" });

    const del_params = try mkParams(a, "{\"namespace\":\"delns\",\"key\":\"k\"}");
    const del_result = try handleDeleteItem(@ptrCast(&ctx), del_params, a);
    try testing.expectEqualStrings("removed_val", del_result.object.get("value").?.string);

    // GET after DELETE → NotFound.
    const get_params = try mkParams(a, "{\"namespace\":\"delns\",\"key\":\"k\"}");
    try testing.expectError(error.NotFound, handleGetItem(@ptrCast(&ctx), get_params, a));
}

test "handleGetItem: missing key → NotFound" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = makeCtx(a, &mem);

    const params = try mkParams(a, "{\"namespace\":\"empty\",\"key\":\"nope\"}");
    try testing.expectError(error.NotFound, handleGetItem(@ptrCast(&ctx), params, a));
}

test "handleGetItem: forbidden namespace → Forbidden" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = makeCtx(a, &mem);

    const params = try mkParams(a, "{\"namespace\":\"database\",\"key\":\"k\"}");
    try testing.expectError(error.Forbidden, handleGetItem(@ptrCast(&ctx), params, a));
}

test "handlePostItem: forbidden namespace → Forbidden" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = makeCtx(a, &mem);

    const params = try mkParams(a, "{\"namespace\":\"database\",\"key\":\"k\",\"value\":1}");
    try testing.expectError(error.Forbidden, handlePostItem(@ptrCast(&ctx), params, a));
}

test "handlePostItem: protected namespace → Forbidden" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = makeCtx(a, &mem);

    const params = try mkParams(a, "{\"namespace\":\"moonraker\",\"key\":\"k\",\"value\":1}");
    try testing.expectError(error.Forbidden, handlePostItem(@ptrCast(&ctx), params, a));
}

test "handleDeleteItem: protected namespace → Forbidden" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = makeCtx(a, &mem);

    const params = try mkParams(a, "{\"namespace\":\"moonraker\",\"key\":\"k\"}");
    try testing.expectError(error.Forbidden, handleDeleteItem(@ptrCast(&ctx), params, a));
}

test "handlePostItemDebug: protected namespace allowed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = makeCtx(a, &mem);

    const params = try mkParams(a, "{\"namespace\":\"moonraker\",\"key\":\"testkey\",\"value\":\"v\"}");
    const result = try handlePostItemDebug(@ptrCast(&ctx), params, a);
    try testing.expectEqualStrings("moonraker", result.object.get("namespace").?.string);
}

test "handleGetItem: no key → whole namespace returned" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = makeCtx(a, &mem);

    const ns = try mem.getOrCreateNs("wholens");
    try ns.data.put("a", .{ .integer = 1 });
    try ns.data.put("b", .{ .integer = 2 });

    const params = try mkParams(a, "{\"namespace\":\"wholens\"}");
    const result = try handleGetItem(@ptrCast(&ctx), params, a);
    try testing.expect(result.object.get("value").? == .object);
}

test "handleCompact: response shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try handleCompact(undefined, .null, a);
    try testing.expectEqual(@as(i64, 0), result.object.get("old_size").?.integer);
    try testing.expectEqual(@as(i64, 0), result.object.get("new_size").?.integer);
}

test "handleBackup: response shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try handleBackup(undefined, .null, a);
    try testing.expect(result.object.get("backup_path") != null);
}

test "handleRestore: response shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try handleRestore(undefined, .null, a);
    try testing.expect(result.object.get("status") != null);
}

test "handleTableDebug: stub returns table_name + empty rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = makeCtx(a, &mem);

    const params = try mkParams(a, "{\"table\":\"mytable\"}");
    const result = try handleTableDebug(@ptrCast(&ctx), params, a);
    try testing.expectEqualStrings("mytable", result.object.get("table_name").?.string);
    try testing.expectEqual(@as(usize, 0), result.object.get("rows").?.array.items.len);
}

test "isForbidden/isProtected match database.py defaults" {
    try testing.expect(isForbidden("database"));
    try testing.expect(!isForbidden("moonraker"));
    try testing.expect(!isForbidden("myns"));
    try testing.expect(isProtected("moonraker"));
    try testing.expect(!isProtected("database"));
    try testing.expect(!isProtected("myns"));
}

test "getStr: returns string or InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try mkParams(a, "{\"namespace\":\"ns\"}");
    try testing.expectEqualStrings("ns", try getStr(p, "namespace"));
    try testing.expectError(error.InvalidParams, getStr(p, "missing"));
    try testing.expectError(error.InvalidParams, getStr(.null, "x"));
}

test "getOptStr: optional field semantics" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try mkParams(a, "{\"namespace\":\"ns\",\"key\":\"k\"}");
    const k = try getOptStr(p, "key");
    try testing.expectEqualStrings("k", k.?);
    try testing.expect((try getOptStr(p, "missing")) == null);
    try testing.expect((try getOptStr(.null, "x")) == null);
}

test "getValue: returns value or InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try mkParams(a, "{\"value\":99}");
    try testing.expectEqual(@as(i64, 99), (try getValue(p)).integer);
    try testing.expectError(error.InvalidParams, getValue(.null));
}

test "registerDatabase: wires expected routes and JSON-RPC methods" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");

    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var mem = MemStore.init(alloc);
    defer mem.deinit();
    var ctx = DbCtx{ .store = mem.dataStore() };

    try registerDatabase(&reg, &ctx);

    // HTTP routes present.
    try testing.expect(reg.lookup(.GET, "/server/database/list") != null);
    try testing.expect(reg.lookup(.GET, "/server/database/item") != null);
    try testing.expect(reg.lookup(.POST, "/server/database/item") != null);
    try testing.expect(reg.lookup(.DELETE, "/server/database/item") != null);
    try testing.expect(reg.lookup(.POST, "/server/database/compact") != null);
    try testing.expect(reg.lookup(.POST, "/server/database/backup") != null);
    try testing.expect(reg.lookup(.DELETE, "/server/database/backup") != null);
    try testing.expect(reg.lookup(.POST, "/server/database/restore") != null);
    try testing.expect(reg.lookup(.GET, "/debug/database/list") != null);
    try testing.expect(reg.lookup(.GET, "/debug/database/item") != null);
    try testing.expect(reg.lookup(.POST, "/debug/database/item") != null);
    try testing.expect(reg.lookup(.DELETE, "/debug/database/item") != null);
    try testing.expect(reg.lookup(.GET, "/debug/database/table") != null);

    // JSON-RPC methods present.
    try testing.expect(d.methods.get("server.database.list") != null);
    try testing.expect(d.methods.get("server.database.item") != null);
    try testing.expect(d.methods.get("server.database.compact") != null);
    try testing.expect(d.methods.get("server.database.post_backup") != null);
    try testing.expect(d.methods.get("server.database.delete_backup") != null);
    try testing.expect(d.methods.get("server.database.restore") != null);
    try testing.expect(d.methods.get("debug.database.list") != null);
    try testing.expect(d.methods.get("debug.database.item") != null);
    try testing.expect(d.methods.get("debug.database.table") != null);
}

// ---- Fuzz tests ----

test "fuzz handleList: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var mem = MemStore.init(a);
            defer mem.deinit();
            _ = mem.getOrCreateNs("n1") catch {};
            var ctx = makeCtx(a, &mem);
            var buf: [4]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = handleList(@ptrCast(&ctx), .null, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleGetItem: never panics on arbitrary params" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var mem = MemStore.init(a);
            defer mem.deinit();
            var ctx = makeCtx(a, &mem);
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "{}",
                "{\"namespace\":\"ns\"}",
                "{\"namespace\":\"ns\",\"key\":\"k\"}",
                "{\"namespace\":\"database\",\"key\":\"k\"}",
                "{\"namespace\":\"moonraker\"}",
                "null",
                "1",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            _ = handleGetItem(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handlePostItem: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var mem = MemStore.init(a);
            defer mem.deinit();
            var ctx = makeCtx(a, &mem);
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "{}",
                "{\"namespace\":\"testns\",\"key\":\"k\",\"value\":1}",
                "{\"namespace\":\"database\",\"key\":\"k\",\"value\":true}",
                "{\"namespace\":\"moonraker\",\"key\":\"k\",\"value\":null}",
                "null",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            _ = handlePostItem(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleDeleteItem: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var mem = MemStore.init(a);
            defer mem.deinit();
            var ctx = makeCtx(a, &mem);
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "{\"namespace\":\"testns\",\"key\":\"k\"}",
                "{\"namespace\":\"moonraker\",\"key\":\"k\"}",
                "{}",
                "null",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            _ = handleDeleteItem(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}
