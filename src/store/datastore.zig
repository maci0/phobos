//! DataStore — a namespaced key/value abstraction mirroring Moonraker's
//! database component semantics (see
//! `vendor/moonraker/moonraker/components/database.py`).
//!
//! Moonraker stores data as a set of *namespaces*. In the LMDB backend each
//! namespace is a named sub-database (dbi). A namespace maps top-level record
//! keys to *encoded records*. A record's logical value is a JSON value
//! (object, array, string, number, bool, or null).
//!
//! Keys passed to get/insert/update/delete are *dotted paths*: the first
//! segment selects the top-level record within the namespace; subsequent
//! segments index into the decoded JSON tree of that record. This file owns
//! the dotted-path tree-walking semantics; concrete backends (see
//! `lmdb_store.zig`) own persistence and record encoding.
//!
//! Dotted-key semantics replicated from database.py `SqliteProvider`:
//!   * parse_namespace_key: split on '.'; empty key or any empty segment is
//!     an error (`InvalidKey`).
//!   * insert_item: with a single segment, the record value is replaced
//!     wholesale. With multiple segments, the top-level record is fetched
//!     (defaulting to an empty object); if it is not an object it is replaced
//!     by a fresh object; intermediate segments are walked, *creating* empty
//!     objects for missing ones (getitem_with_default); the final segment is
//!     assigned. A non-object encountered at an intermediate segment is an
//!     error (`NotAnObject`).
//!   * update_item: the top-level record must already exist. Single segment:
//!     if both existing record and new value are objects, they are *merged*
//!     (dict.update); otherwise replaced. Multiple segments: intermediate
//!     path must already exist and resolve to an object, and the final
//!     segment must already be present; if existing leaf and value are both
//!     objects they merge, else the leaf is replaced.
//!   * delete_item: walks to the parent of the final segment (which must
//!     exist) and removes the final key, returning the removed value. If the
//!     top-level record becomes empty (single-segment delete, or the record
//!     reduced to nothing) the whole record is removed from the namespace.
//!   * get_item: with no key, returns the whole namespace as an object of
//!     key -> value. With a key, walks the dotted path; a missing path is
//!     `KeyNotFound` (unless a default is supplied by the caller).

const std = @import("std");
const json = std.json;

pub const Error = error{
    InvalidKey,
    KeyNotFound,
    NamespaceNotFound,
    NotAnObject,
    OutOfMemory,
    BackendError,
};

/// Maximum number of dotted segments in a key. Moonraker imposes no hard
/// limit, but a bound keeps stack walking simple and guards pathological
/// fuzz inputs. 16 is far beyond any real Moonraker key (typically 2-4); the
/// previous 64 cost ~1 KiB of stack per parseKey on every get/insert/update.
pub const max_key_segments = 16;

/// Parsed dotted key: a list of non-empty segments. Backed by a caller-owned
/// fixed buffer to avoid allocation on the hot path.
pub const ParsedKey = struct {
    segments: [max_key_segments][]const u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const ParsedKey) []const []const u8 {
        return self.segments[0..self.len];
    }
};

/// Split a dotted key into segments, replicating database.py
/// `parse_namespace_key`. Returns `InvalidKey` for an empty key, an empty
/// segment (e.g. `a..b`, leading/trailing dot), or more than
/// `max_key_segments` segments.
pub fn parseKey(key: []const u8) Error!ParsedKey {
    if (key.len == 0) return Error.InvalidKey;
    var pk: ParsedKey = .{};
    var it = std.mem.splitScalar(u8, key, '.');
    while (it.next()) |seg| {
        if (seg.len == 0) return Error.InvalidKey;
        if (pk.len == max_key_segments) return Error.InvalidKey;
        pk.segments[pk.len] = seg;
        pk.len += 1;
    }
    if (pk.len == 0) return Error.InvalidKey;
    return pk;
}

/// Walk a dotted path (segments after the first) into a decoded JSON value.
/// Each intermediate step must be an object. Returns the addressed sub-value
/// (a borrow into `root`) or `KeyNotFound`.
pub fn getPath(root: json.Value, segments: []const []const u8) Error!json.Value {
    var cur = root;
    for (segments) |seg| {
        switch (cur) {
            .object => |obj| {
                cur = obj.get(seg) orelse return Error.KeyNotFound;
            },
            else => return Error.KeyNotFound,
        }
    }
    return cur;
}

/// Ensure `obj[field]` exists and is an object, creating an empty object if
/// absent (mirrors database.py `getitem_with_default`). Returns a pointer to
/// the child value so callers can recurse. Errors if `field` exists but is
/// not an object only when `strict` is set.
fn getOrCreateObject(
    alloc: std.mem.Allocator,
    obj: *json.ObjectMap,
    field: []const u8,
) Error!*json.Value {
    const dup = try alloc.dupe(u8, field);
    const gop = try obj.getOrPut(alloc, dup);
    if (gop.found_existing) {
        // The duped key is unused when the entry already exists.
        alloc.free(dup);
    } else {
        gop.value_ptr.* = .{ .object = .empty };
    }
    return gop.value_ptr;
}

/// Insert `value` at the dotted path within `record`, returning the
/// (possibly replaced) top-level record value. `segments` are the key
/// segments *after* the first (which selected `record`). When `segments` is
/// empty the value replaces the record wholesale.
///
/// Mirrors database.py `insert_item`. Intermediate missing objects are
/// created; a non-object intermediate is an error.
pub fn insertPath(
    alloc: std.mem.Allocator,
    record: json.Value,
    segments: []const []const u8,
    value: json.Value,
) Error!json.Value {
    if (segments.len == 0) return value;

    // Coerce record to an object (database.py overwrites non-dicts).
    var root: json.Value = switch (record) {
        .object => record,
        else => .{ .object = .empty },
    };

    var cur: *json.Value = &root;
    // Walk all but the final segment, creating intermediate objects.
    for (segments[0 .. segments.len - 1]) |seg| {
        switch (cur.*) {
            .object => |*obj| {
                cur = try getOrCreateObject(alloc, obj, seg);
            },
            else => return Error.NotAnObject,
        }
    }
    switch (cur.*) {
        .object => |*obj| {
            const last = segments[segments.len - 1];
            const dup = try alloc.dupe(u8, last);
            const gop = try obj.getOrPut(alloc, dup);
            if (gop.found_existing) alloc.free(dup);
            gop.value_ptr.* = value;
        },
        else => return Error.NotAnObject,
    }
    return root;
}

/// Update `value` at the dotted path within an existing `record`, returning
/// the updated record. Mirrors database.py `update_item`: requires the path
/// to already exist; object values merge rather than replace.
pub fn updatePath(
    alloc: std.mem.Allocator,
    record: json.Value,
    segments: []const []const u8,
    value: json.Value,
) Error!json.Value {
    if (segments.len == 0) {
        // Single-segment update: merge objects, else replace.
        if (record == .object and value == .object) {
            var rec = record;
            try mergeInto(alloc, &rec.object, value.object);
            return rec;
        }
        return value;
    }

    if (record != .object) return Error.KeyNotFound;
    var root = record;
    var cur: *json.Value = &root;
    for (segments[0 .. segments.len - 1]) |seg| {
        switch (cur.*) {
            .object => |obj| {
                cur = obj.getPtr(seg) orelse return Error.KeyNotFound;
            },
            else => return Error.NotAnObject,
        }
    }
    switch (cur.*) {
        .object => |*obj| {
            const last = segments[segments.len - 1];
            const existing = obj.getPtr(last) orelse return Error.NotAnObject;
            if (existing.* == .object and value == .object) {
                try mergeInto(alloc, &existing.object, value.object);
            } else {
                existing.* = value;
            }
        },
        else => return Error.NotAnObject,
    }
    return root;
}

/// Shallow-merge `src` entries into `dst` (database.py uses dict.update).
/// Keys are duplicated with `alloc`; values are taken by reference.
fn mergeInto(alloc: std.mem.Allocator, dst: *json.ObjectMap, src: json.ObjectMap) Error!void {
    var it = src.iterator();
    while (it.next()) |e| {
        const dup = try alloc.dupe(u8, e.key_ptr.*);
        const gop = try dst.getOrPut(alloc, dup);
        if (gop.found_existing) alloc.free(dup);
        gop.value_ptr.* = e.value_ptr.*;
    }
}

/// Result of a dotted-path delete.
pub const DeleteResult = struct {
    /// The value that was removed (a borrow into the original record tree).
    removed: json.Value,
    /// The new top-level record after removal, or null if the record should
    /// be deleted entirely from the namespace.
    record: ?json.Value,
};

/// Delete the value at the dotted path within `record`. Mirrors database.py
/// `delete_item`: single-segment delete removes the whole record; nested
/// delete removes the leaf and keeps the record unless it became empty.
pub fn deletePath(
    record: json.Value,
    segments: []const []const u8,
) Error!DeleteResult {
    if (segments.len == 0) {
        // Whole record removed.
        return .{ .removed = record, .record = null };
    }
    if (record != .object) return Error.KeyNotFound;
    var root = record;
    var cur: *json.Value = &root;
    for (segments[0 .. segments.len - 1]) |seg| {
        switch (cur.*) {
            .object => |obj| {
                cur = obj.getPtr(seg) orelse return Error.KeyNotFound;
            },
            else => return Error.KeyNotFound,
        }
    }
    switch (cur.*) {
        .object => |*obj| {
            const last = segments[segments.len - 1];
            const removed = obj.get(last) orelse return Error.KeyNotFound;
            _ = obj.orderedRemove(last);
            // If the top-level record is now empty, drop it entirely
            // (database.py: remove_record = False if record else True).
            const drop = root == .object and root.object.count() == 0;
            return .{ .removed = removed, .record = if (drop) null else root };
        },
        else => return Error.KeyNotFound,
    }
}

// ---------------------------------------------------------------------------
// DataStore interface (vtable)
// ---------------------------------------------------------------------------

/// A DataStore is a backend-agnostic handle to a namespaced JSON store. The
/// LMDB backend (`lmdb_store.zig`) provides one via `dataStore()`. All ops
/// allocate results in the supplied `arena`.
pub const VTable = struct {
    getItem: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, namespace: [:0]const u8, key: []const u8) Error!?json.Value,
    insertItem: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, namespace: [:0]const u8, key: []const u8, value: json.Value) Error!void,
    updateItem: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, namespace: [:0]const u8, key: []const u8, value: json.Value) Error!void,
    deleteItem: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, namespace: [:0]const u8, key: []const u8) Error!json.Value,
    listNamespaces: *const fn (ctx: *anyopaque, arena: std.mem.Allocator) Error![][]const u8,
    getNamespace: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, namespace: [:0]const u8) Error!json.Value,
};

pub const DataStore = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn getItem(self: DataStore, arena: std.mem.Allocator, namespace: [:0]const u8, key: []const u8) Error!?json.Value {
        return self.vtable.getItem(self.ctx, arena, namespace, key);
    }
    pub fn insertItem(self: DataStore, arena: std.mem.Allocator, namespace: [:0]const u8, key: []const u8, value: json.Value) Error!void {
        return self.vtable.insertItem(self.ctx, arena, namespace, key, value);
    }
    pub fn updateItem(self: DataStore, arena: std.mem.Allocator, namespace: [:0]const u8, key: []const u8, value: json.Value) Error!void {
        return self.vtable.updateItem(self.ctx, arena, namespace, key, value);
    }
    pub fn deleteItem(self: DataStore, arena: std.mem.Allocator, namespace: [:0]const u8, key: []const u8) Error!json.Value {
        return self.vtable.deleteItem(self.ctx, arena, namespace, key);
    }
    pub fn listNamespaces(self: DataStore, arena: std.mem.Allocator) Error![][]const u8 {
        return self.vtable.listNamespaces(self.ctx, arena);
    }
    pub fn getNamespace(self: DataStore, arena: std.mem.Allocator, namespace: [:0]const u8) Error!json.Value {
        return self.vtable.getNamespace(self.ctx, arena, namespace);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Minimal in-memory DataStore impl used to exercise the vtable dispatch
/// without LMDB. Stores a single namespace's single key.
const MemStore = struct {
    last_key: []const u8 = "",
    last_value: json.Value = .null,

    fn vt() *const VTable {
        return &.{
            .getItem = getItem,
            .insertItem = insertItem,
            .updateItem = insertItem,
            .deleteItem = deleteItem,
            .listNamespaces = listNamespaces,
            .getNamespace = getNamespace,
        };
    }
    fn dataStore(self: *MemStore) DataStore {
        return .{ .ctx = self, .vtable = vt() };
    }
    fn getItem(ctx: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, key: []const u8) Error!?json.Value {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, key, self.last_key)) return self.last_value;
        return null;
    }
    fn insertItem(ctx: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, key: []const u8, value: json.Value) Error!void {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        self.last_key = key;
        self.last_value = value;
    }
    fn deleteItem(ctx: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: []const u8) Error!json.Value {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        self.last_key = "";
        return self.last_value;
    }
    fn listNamespaces(_: *anyopaque, arena: std.mem.Allocator) Error![][]const u8 {
        return arena.alloc([]const u8, 0);
    }
    fn getNamespace(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8) Error!json.Value {
        return .{ .object = .empty };
    }
};

test "DataStore interface dispatch routes through the vtable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem: MemStore = .{};
    const store = mem.dataStore();

    try store.insertItem(a, "ns", "k", .{ .integer = 11 });
    const got = (try store.getItem(a, "ns", "k")).?;
    try testing.expectEqual(@as(i64, 11), got.integer);
    try testing.expect((try store.getItem(a, "ns", "other")) == null);
    const ns = try store.listNamespaces(a);
    try testing.expectEqual(@as(usize, 0), ns.len);
}

fn parseJson(alloc: std.mem.Allocator, text: []const u8) !json.Parsed(json.Value) {
    return json.parseFromSlice(json.Value, alloc, text, .{});
}

test "parseKey: simple and dotted" {
    {
        const pk = try parseKey("a");
        try testing.expectEqual(@as(usize, 1), pk.len);
        try testing.expectEqualStrings("a", pk.segments[0]);
    }
    {
        const pk = try parseKey("a.b.c");
        try testing.expectEqual(@as(usize, 3), pk.len);
        try testing.expectEqualStrings("a", pk.segments[0]);
        try testing.expectEqualStrings("b", pk.segments[1]);
        try testing.expectEqualStrings("c", pk.segments[2]);
    }
}

test "parseKey: invalid forms" {
    try testing.expectError(Error.InvalidKey, parseKey(""));
    try testing.expectError(Error.InvalidKey, parseKey("a..b"));
    try testing.expectError(Error.InvalidKey, parseKey(".a"));
    try testing.expectError(Error.InvalidKey, parseKey("a."));
}

test "getPath: nested lookup matches database.py reduce(getitem)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try parseJson(a, "{\"b\":{\"c\":42}}");
    // segments after the first: b.c against record root
    const v = try getPath(parsed.value, &.{ "b", "c" });
    try testing.expectEqual(@as(i64, 42), v.integer);
    try testing.expectError(Error.KeyNotFound, getPath(parsed.value, &.{ "b", "x" }));
    try testing.expectError(Error.KeyNotFound, getPath(parsed.value, &.{ "b", "c", "d" }));
}

test "insertPath: builds nested objects (a.b.c) like database.py" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Start from an empty/absent record (null) inserting at b.c.d.
    const rec = try insertPath(a, .null, &.{ "b", "c", "d" }, .{ .integer = 7 });
    const got = try getPath(rec, &.{ "b", "c", "d" });
    try testing.expectEqual(@as(i64, 7), got.integer);
}

test "insertPath: single segment replaces wholesale" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rec = try insertPath(a, .{ .integer = 1 }, &.{}, .{ .bool = true });
    try testing.expectEqual(true, rec.bool);
}

test "insertPath: non-object intermediate is overwritten at root, error deeper" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // record is an int; inserting at b.c coerces root to object, creates b.
    const rec = try insertPath(a, .{ .integer = 5 }, &.{ "b", "c" }, .{ .integer = 9 });
    const got = try getPath(rec, &.{ "b", "c" });
    try testing.expectEqual(@as(i64, 9), got.integer);
}

test "updatePath: merges objects on single segment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try parseJson(a, "{\"x\":1,\"y\":2}");
    const add = try parseJson(a, "{\"y\":9,\"z\":3}");
    const rec = try updatePath(a, base.value, &.{}, add.value);
    try testing.expectEqual(@as(i64, 1), (try getPath(rec, &.{"x"})).integer);
    try testing.expectEqual(@as(i64, 9), (try getPath(rec, &.{"y"})).integer);
    try testing.expectEqual(@as(i64, 3), (try getPath(rec, &.{"z"})).integer);
}

test "updatePath: nested requires existing leaf" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try parseJson(a, "{\"b\":{\"c\":1}}");
    const rec = try updatePath(a, base.value, &.{ "b", "c" }, .{ .integer = 5 });
    try testing.expectEqual(@as(i64, 5), (try getPath(rec, &.{ "b", "c" })).integer);

    const base2 = try parseJson(a, "{\"b\":{\"c\":1}}");
    try testing.expectError(Error.NotAnObject, updatePath(a, base2.value, &.{ "b", "missing" }, .{ .integer = 5 }));
}

test "deletePath: nested delete keeps record, returns removed value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try parseJson(a, "{\"b\":{\"c\":1,\"d\":2}}");
    const res = try deletePath(base.value, &.{ "b", "c" });
    try testing.expectEqual(@as(i64, 1), res.removed.integer);
    try testing.expect(res.record != null);
    try testing.expectError(Error.KeyNotFound, getPath(res.record.?, &.{ "b", "c" }));
    try testing.expectEqual(@as(i64, 2), (try getPath(res.record.?, &.{ "b", "d" })).integer);
}

test "deletePath: emptied record is dropped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try parseJson(a, "{\"only\":5}");
    const res = try deletePath(base.value, &.{"only"});
    try testing.expectEqual(@as(i64, 5), res.removed.integer);
    try testing.expect(res.record == null);
}

test "deletePath: single segment drops whole record" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try parseJson(a, "{\"x\":1}");
    const res = try deletePath(base.value, &.{});
    try testing.expect(res.record == null);
}

test "deletePath: missing path errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try parseJson(a, "{\"b\":{\"c\":1}}");
    try testing.expectError(Error.KeyNotFound, deletePath(base.value, &.{ "b", "zzz" }));
}

test "fuzz parseKey: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [128]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const n = @as(usize, buf[0]) % buf.len;
            _ = parseKey(buf[0..n]) catch {};
        }
    }.run, .{});
}

test "fuzz path ops: random JSON + key segments never crash or leak" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);

            // Derive a few segment names from bytes.
            var segs: [3][]const u8 = undefined;
            const names = [_][]const u8{ "a", "b", "c", "d" };
            for (0..3) |i| segs[i] = names[buf[i] % names.len];
            const nseg = buf[3] % 4; // 0..3

            // Build an arbitrary starting record.
            const starts = [_][]const u8{ "null", "5", "\"s\"", "{}", "{\"a\":{\"b\":1}}", "[1,2]" };
            const start = starts[buf[4] % starts.len];
            const parsed = parseJson(a, start) catch return;

            const val_choices = [_][]const u8{ "1", "true", "{\"k\":2}", "\"v\"" };
            const vparsed = parseJson(a, val_choices[buf[5] % val_choices.len]) catch return;

            const op = buf[6] % 3;
            switch (op) {
                0 => _ = insertPath(a, parsed.value, segs[0..nseg], vparsed.value) catch {},
                1 => _ = updatePath(a, parsed.value, segs[0..nseg], vparsed.value) catch {},
                else => _ = deletePath(parsed.value, segs[0..nseg]) catch {},
            }
        }
    }.run, .{});
}
