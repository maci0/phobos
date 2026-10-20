//! server.database.* API component — Moonraker-compatible namespaced key/value
//! store endpoints.
//!
//! Matches the endpoints registered in
//! `vendor/moonraker/moonraker/components/database.py`:
//!
//!   GET    /server/database/list    → server.database.list
//!   GET    /server/database/item    → server.database.get_item
//!   POST   /server/database/item    → server.database.post_item
//!   DELETE /server/database/item    → server.database.delete_item
//!   POST   /server/database/compact → server.database.compact
//!   POST   /server/database/backup  → server.database.post_backup
//!   DELETE /server/database/backup  → server.database.delete_backup
//!   POST   /server/database/restore → server.database.restore
//!   GET    /debug/database/list     → debug.database.list
//!   GET    /debug/database/item     → debug.database.get_item
//!   POST   /debug/database/item     → debug.database.post_item
//!   DELETE /debug/database/item     → debug.database.delete_item
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
const jv = @import("../json/value.zig");
const webreq = @import("../json/params.zig");

const Registry = registry.Registry;
const DataStore = ds.DataStore;

// ---------------------------------------------------------------------------
// Namespace access policy (mirrors database.py defaults)
// ---------------------------------------------------------------------------

/// Namespaces with NO API access whatsoever (read or write). Not configurable
/// through the public API. Mirrors database.py `forbidden_namespaces`.
pub const default_forbidden_namespaces = [_][]const u8{ "database", "authorized_users" };

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
    registered_namespaces: []const []const u8 = &.{},
};

fn namespaceListed(c: *DbCtx, alloc: std.mem.Allocator, policy: []const u8, namespace: []const u8) !bool {
    const names = (try c.store.getItem(alloc, "database", policy)) orelse return false;
    if (names != .array) return false;
    for (names.array.items) |name| {
        if (name == .string and std.mem.eql(u8, name.string, namespace)) return true;
    }
    return false;
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
        if (!is_debug and (isForbidden(ns) or try namespaceListed(c, alloc, "forbidden_namespaces", ns))) continue;
        try visible.append(alloc, ns);
    }
    for (c.registered_namespaces) |ns| {
        if (!is_debug and (isForbidden(ns) or try namespaceListed(c, alloc, "forbidden_namespaces", ns))) continue;
        var exists = false;
        for (visible.items) |name| if (std.mem.eql(u8, name, ns)) {
            exists = true;
            break;
        };
        if (!exists) try visible.append(alloc, ns);
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
    const namespace = try webreq.required([]const u8, params, "namespace");
    if (!is_debug and (isForbidden(namespace) or try namespaceListed(c, alloc, "forbidden_namespaces", namespace))) return error.Forbidden;

    // database.py reads `key` with a raw `get("key", None)`: JSON null selects
    // the whole namespace like an absent key. List keys are not supported.
    const key_opt: ?[]const u8 = switch ((try webreq.optional(std.json.Value, params, "key")) orelse .null) {
        .null => null,
        .string => |s| s,
        else => return error.InvalidParams,
    };
    const ns_z = try alloc.dupeSentinel(u8, namespace, 0);

    const value: std.json.Value = if (key_opt) |key| blk: {
        const v = c.store.getItem(alloc, ns_z, key) catch |err| return requestError(err);
        break :blk v orelse return error.MissingDbKey;
    } else blk: {
        if (!try namespaceKnown(c, alloc, namespace)) return error.UnknownDbNamespace;
        break :blk c.store.getNamespace(alloc, ns_z) catch |err| return requestError(err);
    };

    return buildItemResponse(alloc, namespace, key_opt, value);
}

fn namespaceKnown(c: *DbCtx, alloc: std.mem.Allocator, namespace: []const u8) !bool {
    for (c.registered_namespaces) |name| if (std.mem.eql(u8, name, namespace)) return true;
    if (std.mem.eql(u8, namespace, "history") or std.mem.eql(u8, namespace, "history_totals")) {
        return true;
    }
    const names = try c.store.listNamespaces(alloc);
    for (names) |n| {
        if (std.mem.eql(u8, n, namespace)) return true;
    }
    return false;
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
    const namespace = try webreq.required([]const u8, params, "namespace");
    if (!is_debug and (isForbidden(namespace) or try namespaceListed(c, alloc, "forbidden_namespaces", namespace))) return error.Forbidden;
    if (!is_debug and (isProtected(namespace) or try namespaceListed(c, alloc, "protected_namespaces", namespace))) return error.Forbidden;

    const key = try webreq.required([]const u8, params, "key");
    const value = try webreq.required(std.json.Value, params, "value");
    // Reject pathologically-nested values: storing one would let a later GET
    // serialize it through std.json.Stringify's fixed 256-level nesting stack,
    // which panics / corrupts memory past its limit. Real data is shallow.
    if (jv.exceedsDepth(value, jv.max_value_depth)) return error.InvalidParams;
    const ns_z = try alloc.dupeSentinel(u8, namespace, 0);

    c.store.insertItem(alloc, ns_z, key, value) catch |err| return requestError(err);
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
    const namespace = try webreq.required([]const u8, params, "namespace");
    if (!is_debug and (isForbidden(namespace) or try namespaceListed(c, alloc, "forbidden_namespaces", namespace))) return error.Forbidden;
    if (!is_debug and (isProtected(namespace) or try namespaceListed(c, alloc, "protected_namespaces", namespace))) return error.Forbidden;

    const key = try webreq.required([]const u8, params, "key");
    const ns_z = try alloc.dupeSentinel(u8, namespace, 0);

    const removed = c.store.deleteItem(alloc, ns_z, key) catch |err| switch (err) {
        ds.Error.KeyNotFound, ds.Error.NamespaceNotFound => return error.NotFound,
        else => return requestError(err),
    };
    return buildItemResponse(alloc, namespace, key, removed);
}

/// Moonraker answers a malformed key with a 400 `ServerError`
/// (database.py `parse_namespace_key`); the file backend also rejects a
/// namespace that would name a path outside its directory.
fn requestError(err: ds.Error) anyerror {
    return if (err == ds.Error.InvalidKey) error.InvalidParams else err;
}

// ---------------------------------------------------------------------------
// /debug/database/table (GET)
// ---------------------------------------------------------------------------
// Stub: compact/backup/restore not implemented. Registered for API-surface coverage.

pub fn handleTableDebug(_: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const table = try webreq.required([]const u8, params, "table");
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
//   Moonraker's RequestType.all() registration verb-prefixes the three methods:
//   server.database.get_item / post_item / delete_item (Mainsail/Fluidd call
//   these over WS on init). phobos matches this by registering each verb with
//   `multi_verb = true` below, so `deriveMethodName` emits the prefixed names.
//   Same for /debug/database/item → debug.database.get_item / … .
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
    // Moonraker verb-prefixes all three: server.database.get_item / post_item /
    // delete_item (Mainsail/Fluidd call these over WS on init). One HTTP path,
    // three handlers → multi_verb on each.
    try reg.registerEndpoint(
        .{ .path = "/server/database/item", .methods = &.{.GET}, .multi_verb = true, .off_core = true },
        c,
        handleGetItem,
    );
    try reg.registerEndpoint(
        .{ .path = "/server/database/item", .methods = &.{.POST}, .multi_verb = true },
        c,
        handlePostItem,
    );
    try reg.registerEndpoint(
        .{ .path = "/server/database/item", .methods = &.{.DELETE}, .multi_verb = true },
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
    // Verb-prefixed like the public endpoint: debug.database.get_item /
    // post_item / delete_item.
    try reg.registerEndpoint(
        .{ .path = "/debug/database/item", .methods = &.{.GET}, .multi_verb = true },
        c,
        handleGetItemDebug,
    );
    try reg.registerEndpoint(
        .{ .path = "/debug/database/item", .methods = &.{.POST}, .multi_verb = true },
        c,
        handlePostItemDebug,
    );
    try reg.registerEndpoint(
        .{ .path = "/debug/database/item", .methods = &.{.DELETE}, .multi_verb = true },
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

test "database policies hide auth records and honor persisted namespace access" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = makeCtx(a, &mem);
    ctx.registered_namespaces = &.{"announcements"};
    try ctx.store.insertItem(a, "authorized_users", "user", .{ .string = "private" });
    try ctx.store.insertItem(a, "secret", "key", .null);
    try ctx.store.insertItem(a, "database", "forbidden_namespaces", try mkParams(a, "[\"secret\"]"));
    try ctx.store.insertItem(a, "database", "protected_namespaces", try mkParams(a, "[\"announcements\"]"));
    const listed = try handleList(&ctx, .null, a);
    const names = listed.object.get("namespaces").?.array.items;
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("announcements", names[0].string);
    const empty = try handleGetItem(&ctx, try mkParams(a, "{\"namespace\":\"announcements\"}"), a);
    try testing.expectEqual(@as(usize, 0), empty.object.get("value").?.object.count());
    try testing.expectError(error.Forbidden, handleGetItem(&ctx, try mkParams(a, "{\"namespace\":\"authorized_users\"}"), a));
    try testing.expectError(error.Forbidden, handleGetItem(&ctx, try mkParams(a, "{\"namespace\":\"secret\"}"), a));
    const params = try mkParams(a, "{\"namespace\":\"announcements\",\"key\":\"one\",\"value\":1}");
    try testing.expectError(error.Forbidden, handlePostItem(&ctx, params, a));
    try testing.expectError(error.Forbidden, handleDeleteItem(&ctx, params, a));
    _ = try handlePostItemDebug(&ctx, params, a);
    _ = try handleGetItemDebug(&ctx, try mkParams(a, "{\"namespace\":\"secret\"}"), a);
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

test "handlePostItem: rejects a pathologically deep value (guards the serializer)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = makeCtx(a, &mem);

    // value = 400-deep nested array — past max_value_depth (100). Storing it would
    // let a later GET serialize it through Stringify's fixed 256-level stack → crash.
    const depth = 400;
    var vbuf: std.ArrayList(u8) = .empty;
    defer vbuf.deinit(a);
    try vbuf.appendSlice(a, "{\"namespace\":\"testns\",\"key\":\"deep\",\"value\":");
    for (0..depth) |_| try vbuf.append(a, '[');
    try vbuf.append(a, '1');
    for (0..depth) |_| try vbuf.append(a, ']');
    try vbuf.append(a, '}');

    const params = try mkParams(a, vbuf.items);
    try testing.expectError(error.InvalidParams, handlePostItem(@ptrCast(&ctx), params, a));

    // A shallow value in the same namespace still works (guard is not over-broad).
    const ok_params = try mkParams(a, "{\"namespace\":\"testns\",\"key\":\"shallow\",\"value\":{\"a\":[1,2,3]}}");
    _ = try handlePostItem(@ptrCast(&ctx), ok_params, a);
}

test "item handlers on a FileStore reject a namespace outside the database directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    var fs = try @import("../store/file_store.zig").FileStore.open(io, try std.fs.path.join(a, &.{ root, "database" }));
    defer fs.deinit();
    var ctx: DbCtx = .{ .store = fs.dataStore() };

    const bad = "{\"namespace\":\"../escape\",\"key\":\"k\",\"value\":1}";
    try testing.expectError(error.InvalidParams, handlePostItem(@ptrCast(&ctx), try mkParams(a, bad), a));
    try testing.expectError(error.InvalidParams, handleGetItem(@ptrCast(&ctx), try mkParams(a, bad), a));
    try testing.expectError(error.InvalidParams, handleDeleteItem(@ptrCast(&ctx), try mkParams(a, bad), a));
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "escape.json", .{}));

    const good = "{\"namespace\":\"fluidd\",\"key\":\"k\",\"value\":1}";
    _ = try handlePostItem(@ptrCast(&ctx), try mkParams(a, good), a);
    const got = try handleGetItem(@ptrCast(&ctx), try mkParams(a, good), a);
    try testing.expectEqual(@as(i64, 1), got.object.get("value").?.integer);
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
    try testing.expectError(error.MissingDbKey, handleGetItem(@ptrCast(&ctx), get_params, a));
}

test "handleGetItem: missing key has its own error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = makeCtx(a, &mem);
    _ = try mem.getOrCreateNs("empty");

    const params = try mkParams(a, "{\"namespace\":\"empty\",\"key\":\"nope\"}");
    try testing.expectError(error.MissingDbKey, handleGetItem(@ptrCast(&ctx), params, a));
}

test "handleGetItem: missing namespace has its own error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = makeCtx(a, &mem);

    const params = try mkParams(a, "{\"namespace\":\"parity_no_such\"}");
    try testing.expectError(error.UnknownDbNamespace, handleGetItem(@ptrCast(&ctx), params, a));
}

test "handleGetItem: empty existing namespace is returned" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = makeCtx(a, &mem);
    _ = try mem.getOrCreateNs("empty_ns");

    const params = try mkParams(a, "{\"namespace\":\"empty_ns\"}");
    const result = try handleGetItem(@ptrCast(&ctx), params, a);
    try testing.expectEqual(@as(usize, 0), result.object.get("value").?.object.count());
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
    // A raw `get("key", None)`: null reads the namespace, other non-strings fail.
    const null_key = try handleGetItem(@ptrCast(&ctx), try mkParams(a, "{\"namespace\":\"wholens\",\"key\":null}"), a);
    try testing.expectEqual(2, null_key.object.get("value").?.object.count());
    try testing.expectError(error.InvalidParams, handleGetItem(@ptrCast(&ctx), try mkParams(a, "{\"namespace\":\"wholens\",\"key\":1}"), a));
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
    try testing.expect(d.methods.get("server.database.get_item") != null);
    try testing.expect(d.methods.get("server.database.post_item") != null);
    try testing.expect(d.methods.get("server.database.delete_item") != null);
    try testing.expect(d.methods.get("server.database.item") == null); // renamed
    try testing.expect(d.methods.get("server.database.compact") != null);
    try testing.expect(d.methods.get("server.database.post_backup") != null);
    try testing.expect(d.methods.get("server.database.delete_backup") != null);
    try testing.expect(d.methods.get("server.database.restore") != null);
    try testing.expect(d.methods.get("debug.database.list") != null);
    try testing.expect(d.methods.get("debug.database.get_item") != null);
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
            ctx.registered_namespaces = &.{"announcements"};
            const policies = [_][]const u8{ "null", "42", "{}", "[null,1,\"n1\"]", "[\"announcements\"]" };
            const policy = try mkParams(a, policies[buf[0] % policies.len]);
            try ctx.store.insertItem(a, "database", "forbidden_namespaces", policy);
            _ = try namespaceListed(&ctx, a, "forbidden_namespaces", "n1");
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
