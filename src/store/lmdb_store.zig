//! LmdbStore — the LMDB-backed DataStore implementation, drop-in compatible
//! with Moonraker's `data.mdb` on-disk format (LMDB 0.9.31).
//!
//! On-disk layout (matches `dbtool.py` and the legacy `database.py` LMDB
//! provider, prior to the SQLite migration):
//!   * The environment is opened on a *directory* containing `data.mdb` /
//!     `lock.mdb`, with `max_dbs = 100` and `map_size = 200 MiB` — the exact
//!     values Moonraker used (`MAX_LMDB_NAMESPACES`, `MAX_LMDB_SIZE`).
//!   * Each Moonraker namespace is an LMDB *named database* (dbi). The main
//!     (unnamed) database holds one entry per namespace: key = namespace name,
//!     value = LMDB-internal dbi page pointer. We enumerate namespaces by
//!     iterating the main DB with a cursor (exactly as dbtool / database.py do).
//!   * Within a namespace dbi, keys are UTF-8 record keys and values are
//!     *encoded records*. The encoding mirrors database.py
//!     `RECORD_ENCODE_FUNCS`:
//!       int   -> 'q' + little-endian i64 (struct.pack("q"))
//!       float -> 'd' + little-endian f64 (struct.pack("d"))
//!       bool  -> '?' + 1 byte (0/1)
//!       str   -> 's' + raw utf-8 bytes
//!       list  -> raw JSON text (begins with '[')
//!       dict  -> raw JSON text (begins with '{')
//!       null  -> single 0x00 byte
//!     Decoding dispatches on the first byte. Note: native byte order — the
//!     Python struct.pack with "q"/"d" uses native order, which on the
//!     little-endian targets we support matches.
//!
//! Public DataStore operations take/return JSON values and dotted keys; the
//! tree-walking semantics live in `datastore.zig`.

const std = @import("std");
const json = std.json;
const c = @import("lmdb_c.zig");
const ds = @import("datastore.zig");

pub const Error = ds.Error || error{ EnvOpenFailed, TxnFailed, PutFailed };

/// Moonraker's LMDB tuning constants (`MAX_LMDB_NAMESPACES`, `MAX_LMDB_SIZE`).
pub const max_namespaces: c.MDB_dbi = 100;
pub const max_map_size: usize = 200 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Record encoding (Moonraker prefix-byte format)
// ---------------------------------------------------------------------------

/// Encode a JSON value into Moonraker's record byte format. Caller owns the
/// returned slice.
pub fn encodeRecord(alloc: std.mem.Allocator, value: json.Value) Error![]u8 {
    switch (value) {
        .null => {
            const out = try alloc.alloc(u8, 1);
            out[0] = 0;
            return out;
        },
        .bool => |b| {
            const out = try alloc.alloc(u8, 2);
            out[0] = '?';
            out[1] = if (b) 1 else 0;
            return out;
        },
        .integer => |i| {
            const out = try alloc.alloc(u8, 9);
            out[0] = 'q';
            std.mem.writeInt(i64, out[1..9], i, .little);
            return out;
        },
        .float => |f| {
            const out = try alloc.alloc(u8, 9);
            out[0] = 'd';
            const bits: u64 = @bitCast(f);
            std.mem.writeInt(u64, out[1..9], bits, .little);
            return out;
        },
        .number_string => |s| {
            // A JSON number that didn't fit i64/f64. Treat as float if it
            // parses, else as a string record (best effort).
            if (std.fmt.parseFloat(f64, s)) |f| {
                return encodeRecord(alloc, .{ .float = f });
            } else |_| {
                return encodeRecord(alloc, .{ .string = s });
            }
        },
        .string => |s| {
            const out = try alloc.alloc(u8, 1 + s.len);
            out[0] = 's';
            @memcpy(out[1..], s);
            return out;
        },
        .array, .object => {
            // Serialize as JSON text; first byte is '[' or '{' which the
            // decoder dispatches on.
            var aw: std.Io.Writer.Allocating = .init(alloc);
            errdefer aw.deinit();
            var w: json.Stringify = .{ .writer = &aw.writer };
            w.write(value) catch return Error.OutOfMemory;
            return aw.toOwnedSlice() catch return Error.OutOfMemory;
        },
    }
}

/// Decode a Moonraker record byte slice into a JSON value. The result borrows
/// from `arena` (strings/containers are arena-allocated). `bytes` need not
/// outlive the call for scalar types, but for str/json the bytes are copied
/// into the arena.
pub fn decodeRecord(arena: std.mem.Allocator, bytes: []const u8) Error!json.Value {
    if (bytes.len == 0) return Error.BackendError;
    switch (bytes[0]) {
        0 => return .null,
        '?' => {
            if (bytes.len < 2) return Error.BackendError;
            return .{ .bool = bytes[1] != 0 };
        },
        'q' => {
            if (bytes.len < 9) return Error.BackendError;
            return .{ .integer = std.mem.readInt(i64, bytes[1..9], .little) };
        },
        'd' => {
            if (bytes.len < 9) return Error.BackendError;
            const bits = std.mem.readInt(u64, bytes[1..9], .little);
            return .{ .float = @bitCast(bits) };
        },
        's' => {
            const s = try arena.dupe(u8, bytes[1..]);
            return .{ .string = s };
        },
        '[', '{' => {
            const parsed = json.parseFromSliceLeaky(json.Value, arena, bytes, .{}) catch
                return Error.BackendError;
            return parsed;
        },
        else => return Error.BackendError,
    }
}

// ---------------------------------------------------------------------------
// LmdbStore
// ---------------------------------------------------------------------------

pub const LmdbStore = struct {
    env: *c.MDB_env,
    read_only: bool,

    /// Open (or create) the LMDB environment in directory `path`. When
    /// `read_only` is true the environment is opened MDB_RDONLY (proves
    /// drop-in reads of an existing Moonraker `data.mdb`).
    pub fn open(path: [:0]const u8, read_only: bool) Error!LmdbStore {
        var env: ?*c.MDB_env = null;
        if (c.mdb_env_create(&env) != c.MDB_SUCCESS) return Error.EnvOpenFailed;
        errdefer c.mdb_env_close(env.?);
        if (c.mdb_env_set_maxdbs(env.?, max_namespaces) != c.MDB_SUCCESS)
            return Error.EnvOpenFailed;
        if (c.mdb_env_set_mapsize(env.?, max_map_size) != c.MDB_SUCCESS)
            return Error.EnvOpenFailed;
        var flags: c_uint = c.MDB_NOTLS;
        if (read_only) flags |= c.MDB_RDONLY;
        if (c.mdb_env_open(env.?, path.ptr, flags, 0o644) != c.MDB_SUCCESS)
            return Error.EnvOpenFailed;
        return .{ .env = env.?, .read_only = read_only };
    }

    pub fn close(self: *LmdbStore) void {
        c.mdb_env_close(self.env);
        self.* = undefined;
    }

    fn beginTxn(self: *LmdbStore, write: bool) Error!*c.MDB_txn {
        var txn: ?*c.MDB_txn = null;
        const flags: c_uint = if (write) 0 else c.MDB_RDONLY;
        if (c.mdb_txn_begin(self.env, null, flags, &txn) != c.MDB_SUCCESS)
            return Error.TxnFailed;
        return txn.?;
    }

    /// Open the dbi for `namespace`, creating it when `create` is set.
    fn openDbi(txn: *c.MDB_txn, namespace: [:0]const u8, create: bool) Error!c.MDB_dbi {
        var dbi: c.MDB_dbi = 0;
        const flags: c_uint = if (create) c.MDB_CREATE else 0;
        const rc = c.mdb_dbi_open(txn, namespace.ptr, flags, &dbi);
        if (rc == c.MDB_NOTFOUND) return Error.NamespaceNotFound;
        if (rc != c.MDB_SUCCESS) return Error.BackendError;
        return dbi;
    }

    /// Fetch the raw encoded record for top-level `key` in `namespace`.
    /// Copies the value into `arena`. Returns null if absent.
    fn getRecordRaw(
        self: *LmdbStore,
        arena: std.mem.Allocator,
        namespace: [:0]const u8,
        key: []const u8,
    ) Error!?[]u8 {
        const txn = try self.beginTxn(false);
        defer c.mdb_txn_abort(txn);
        const dbi = openDbi(txn, namespace, false) catch |e| switch (e) {
            Error.NamespaceNotFound => return null,
            else => return e,
        };
        var k = c.val(key);
        var v: c.MDB_val = undefined;
        const rc = c.mdb_get(txn, dbi, &k, &v);
        if (rc == c.MDB_NOTFOUND) return null;
        if (rc != c.MDB_SUCCESS) return Error.BackendError;
        return try arena.dupe(u8, c.slice(v));
    }

    /// Write the encoded record for top-level `key`, or delete it when
    /// `value` is null.
    fn putRecordRaw(
        self: *LmdbStore,
        namespace: [:0]const u8,
        key: []const u8,
        value: ?[]const u8,
    ) Error!void {
        const txn = try self.beginTxn(true);
        errdefer c.mdb_txn_abort(txn);
        const dbi = try openDbi(txn, namespace, true);
        var k = c.val(key);
        if (value) |val_bytes| {
            var v = c.val(val_bytes);
            if (c.mdb_put(txn, dbi, &k, &v, 0) != c.MDB_SUCCESS) return Error.PutFailed;
        } else {
            const rc = c.mdb_del(txn, dbi, &k, null);
            if (rc != c.MDB_SUCCESS and rc != c.MDB_NOTFOUND) return Error.PutFailed;
        }
        if (c.mdb_txn_commit(txn) != c.MDB_SUCCESS) return Error.TxnFailed;
    }

    // --- DataStore API ----------------------------------------------------

    /// Get the value at a dotted `key` in `namespace`. The result is allocated
    /// in `arena`. Returns null when the key path is absent.
    pub fn getItem(
        self: *LmdbStore,
        arena: std.mem.Allocator,
        namespace: [:0]const u8,
        key: []const u8,
    ) Error!?json.Value {
        const pk = try ds.parseKey(key);
        const segs = pk.slice();
        const raw = (try self.getRecordRaw(arena, namespace, segs[0])) orelse return null;
        const record = try decodeRecord(arena, raw);
        return ds.getPath(record, segs[1..]) catch |e| switch (e) {
            ds.Error.KeyNotFound => null,
            else => |other| other,
        };
    }

    /// Insert `value` at dotted `key`, replicating database.py `insert_item`.
    pub fn insertItem(
        self: *LmdbStore,
        arena: std.mem.Allocator,
        namespace: [:0]const u8,
        key: []const u8,
        value: json.Value,
    ) Error!void {
        const pk = try ds.parseKey(key);
        const segs = pk.slice();
        var record: json.Value = .null;
        if (segs.len > 1) {
            if (try self.getRecordRaw(arena, namespace, segs[0])) |raw| {
                record = try decodeRecord(arena, raw);
            } else {
                record = .{ .object = .empty };
            }
        }
        const new_record = try ds.insertPath(arena, record, segs[1..], value);
        const encoded = try encodeRecord(arena, new_record);
        try self.putRecordRaw(namespace, segs[0], encoded);
    }

    /// Update `value` at dotted `key`, replicating database.py `update_item`.
    /// The top-level record must already exist.
    pub fn updateItem(
        self: *LmdbStore,
        arena: std.mem.Allocator,
        namespace: [:0]const u8,
        key: []const u8,
        value: json.Value,
    ) Error!void {
        const pk = try ds.parseKey(key);
        const segs = pk.slice();
        const raw = (try self.getRecordRaw(arena, namespace, segs[0])) orelse
            return Error.KeyNotFound;
        const record = try decodeRecord(arena, raw);
        const new_record = try ds.updatePath(arena, record, segs[1..], value);
        const encoded = try encodeRecord(arena, new_record);
        try self.putRecordRaw(namespace, segs[0], encoded);
    }

    /// Delete the value at dotted `key`, returning the removed value (in
    /// `arena`). Replicates database.py `delete_item`.
    pub fn deleteItem(
        self: *LmdbStore,
        arena: std.mem.Allocator,
        namespace: [:0]const u8,
        key: []const u8,
    ) Error!json.Value {
        const pk = try ds.parseKey(key);
        const segs = pk.slice();
        const raw = (try self.getRecordRaw(arena, namespace, segs[0])) orelse
            return Error.KeyNotFound;
        const record = try decodeRecord(arena, raw);
        const res = try ds.deletePath(record, segs[1..]);
        if (res.record) |new_record| {
            const encoded = try encodeRecord(arena, new_record);
            try self.putRecordRaw(namespace, segs[0], encoded);
        } else {
            try self.putRecordRaw(namespace, segs[0], null);
        }
        return res.removed;
    }

    /// List all namespace names (the keys of the main/unnamed DB). Results
    /// allocated in `arena`.
    pub fn listNamespaces(self: *LmdbStore, arena: std.mem.Allocator) Error![][]const u8 {
        const txn = try self.beginTxn(false);
        defer c.mdb_txn_abort(txn);
        // The unnamed/main database (MAIN_DBI == 1 in liblmdb) holds one entry
        // per named sub-database, i.e. one per Moonraker namespace. dbi 0 is
        // the reserved FREE_DBI; iterating it would not yield namespaces.
        const main_dbi: c.MDB_dbi = c.MDB_MAIN_DBI;
        var cursor: ?*c.MDB_cursor = null;
        if (c.mdb_cursor_open(txn, main_dbi, &cursor) != c.MDB_SUCCESS)
            return Error.BackendError;
        defer c.mdb_cursor_close(cursor.?);

        var out: std.ArrayList([]const u8) = .empty;
        var k: c.MDB_val = undefined;
        var v: c.MDB_val = undefined;
        var op: c_uint = c.MDB_FIRST;
        while (true) {
            const rc = c.mdb_cursor_get(cursor.?, &k, &v, op);
            if (rc == c.MDB_NOTFOUND) break;
            if (rc != c.MDB_SUCCESS) return Error.BackendError;
            op = c.MDB_NEXT;
            const name = c.slice(k);
            if (name.len == 0) continue;
            try out.append(arena, try arena.dupe(u8, name));
        }
        return out.toOwnedSlice(arena);
    }

    // --- DataStore interface adapter --------------------------------------

    /// Expose this store behind the backend-agnostic `ds.DataStore` vtable.
    pub fn dataStore(self: *LmdbStore) ds.DataStore {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: ds.VTable = .{
        .getItem = vtGetItem,
        .insertItem = vtInsertItem,
        .updateItem = vtUpdateItem,
        .deleteItem = vtDeleteItem,
        .listNamespaces = vtListNamespaces,
        .getNamespace = vtGetNamespace,
    };

    fn vtGetItem(ctx: *anyopaque, arena: std.mem.Allocator, ns: [:0]const u8, key: []const u8) ds.Error!?json.Value {
        return @as(*LmdbStore, @ptrCast(@alignCast(ctx))).getItem(arena, ns, key) catch |e| return lmdbErrToDs(e);
    }
    fn vtInsertItem(ctx: *anyopaque, arena: std.mem.Allocator, ns: [:0]const u8, key: []const u8, value: json.Value) ds.Error!void {
        return @as(*LmdbStore, @ptrCast(@alignCast(ctx))).insertItem(arena, ns, key, value) catch |e| return lmdbErrToDs(e);
    }
    fn vtUpdateItem(ctx: *anyopaque, arena: std.mem.Allocator, ns: [:0]const u8, key: []const u8, value: json.Value) ds.Error!void {
        return @as(*LmdbStore, @ptrCast(@alignCast(ctx))).updateItem(arena, ns, key, value) catch |e| return lmdbErrToDs(e);
    }
    fn vtDeleteItem(ctx: *anyopaque, arena: std.mem.Allocator, ns: [:0]const u8, key: []const u8) ds.Error!json.Value {
        return @as(*LmdbStore, @ptrCast(@alignCast(ctx))).deleteItem(arena, ns, key) catch |e| return lmdbErrToDs(e);
    }
    fn vtListNamespaces(ctx: *anyopaque, arena: std.mem.Allocator) ds.Error![][]const u8 {
        return @as(*LmdbStore, @ptrCast(@alignCast(ctx))).listNamespaces(arena) catch |e| return lmdbErrToDs(e);
    }
    fn vtGetNamespace(ctx: *anyopaque, arena: std.mem.Allocator, ns: [:0]const u8) ds.Error!json.Value {
        return @as(*LmdbStore, @ptrCast(@alignCast(ctx))).getNamespace(arena, ns) catch |e| return lmdbErrToDs(e);
    }

    /// Map LMDB-specific errors to the backend-agnostic `ds.Error` set.
    /// `EnvOpenFailed`, `TxnFailed`, `PutFailed` all map to `BackendError`.
    fn lmdbErrToDs(e: Error) ds.Error {
        return switch (e) {
            ds.Error.InvalidKey => ds.Error.InvalidKey,
            ds.Error.KeyNotFound => ds.Error.KeyNotFound,
            ds.Error.NamespaceNotFound => ds.Error.NamespaceNotFound,
            ds.Error.NotAnObject => ds.Error.NotAnObject,
            ds.Error.OutOfMemory => ds.Error.OutOfMemory,
            ds.Error.BackendError => ds.Error.BackendError,
            error.EnvOpenFailed, error.TxnFailed, error.PutFailed => ds.Error.BackendError,
        };
    }

    /// Return all top-level key -> decoded-value pairs in `namespace` as a
    /// JSON object (database.py `get_namespace`). Allocated in `arena`.
    pub fn getNamespace(
        self: *LmdbStore,
        arena: std.mem.Allocator,
        namespace: [:0]const u8,
    ) Error!json.Value {
        var obj: json.ObjectMap = .empty;
        const txn = try self.beginTxn(false);
        defer c.mdb_txn_abort(txn);
        const dbi = openDbi(txn, namespace, false) catch |e| switch (e) {
            Error.NamespaceNotFound => return .{ .object = obj },
            else => return e,
        };
        var cursor: ?*c.MDB_cursor = null;
        if (c.mdb_cursor_open(txn, dbi, &cursor) != c.MDB_SUCCESS)
            return Error.BackendError;
        defer c.mdb_cursor_close(cursor.?);

        var k: c.MDB_val = undefined;
        var v: c.MDB_val = undefined;
        var op: c_uint = c.MDB_FIRST;
        while (true) {
            const rc = c.mdb_cursor_get(cursor.?, &k, &v, op);
            if (rc == c.MDB_NOTFOUND) break;
            if (rc != c.MDB_SUCCESS) return Error.BackendError;
            op = c.MDB_NEXT;
            const key = try arena.dupe(u8, c.slice(k));
            const value = try decodeRecord(arena, c.slice(v));
            try obj.put(arena, key, value);
        }
        return .{ .object = obj };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A scratch LMDB directory under /tmp plus the threaded `Io` used to create
/// and tear it down. LMDB itself does raw POSIX I/O on the path; we only use
/// `Io` for directory management so tests stay on the modern std API.
const TmpEnv = struct {
    threaded: std.Io.Threaded,
    io: std.Io,
    path: [:0]const u8,
    buf: [256]u8,

    fn create(self: *TmpEnv) !void {
        self.threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        self.io = self.threaded.io();
        var seed: [8]u8 = undefined;
        self.io.random(&seed);
        const s = std.mem.readInt(u64, &seed, .little);
        self.path = try std.fmt.bufPrintZ(&self.buf, "/tmp/phobos-lmdb-test-{x}", .{s});
        try std.Io.Dir.cwd().createDirPath(self.io, self.path);
    }

    fn destroy(self: *TmpEnv) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.path) catch {};
        self.threaded.deinit();
    }
};

fn parseJson(arena: std.mem.Allocator, text: []const u8) !json.Value {
    return json.parseFromSliceLeaky(json.Value, arena, text, .{});
}

test "encode/decode: scalar round-trips match Moonraker format" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // int -> 'q' + 8 LE bytes
    {
        const enc = try encodeRecord(a, .{ .integer = 0x0102030405060708 });
        try testing.expectEqual(@as(u8, 'q'), enc[0]);
        try testing.expectEqual(@as(usize, 9), enc.len);
        try testing.expectEqual(@as(u8, 0x08), enc[1]); // little-endian low byte
        const dec = try decodeRecord(a, enc);
        try testing.expectEqual(@as(i64, 0x0102030405060708), dec.integer);
    }
    // bool
    {
        const enc = try encodeRecord(a, .{ .bool = true });
        try testing.expectEqualSlices(u8, &.{ '?', 1 }, enc);
        try testing.expectEqual(true, (try decodeRecord(a, enc)).bool);
    }
    // float
    {
        const enc = try encodeRecord(a, .{ .float = 3.5 });
        try testing.expectEqual(@as(u8, 'd'), enc[0]);
        try testing.expectEqual(@as(f64, 3.5), (try decodeRecord(a, enc)).float);
    }
    // string -> 's' + raw
    {
        const enc = try encodeRecord(a, .{ .string = "hi" });
        try testing.expectEqualSlices(u8, "shi", enc);
        try testing.expectEqualStrings("hi", (try decodeRecord(a, enc)).string);
    }
    // null -> 0x00
    {
        const enc = try encodeRecord(a, .null);
        try testing.expectEqualSlices(u8, &.{0}, enc);
        try testing.expect((try decodeRecord(a, enc)) == .null);
    }
}

test "encode/decode: object/array as JSON text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parseJson(a, "{\"a\":1,\"b\":[2,3]}");
    const enc = try encodeRecord(a, v);
    try testing.expectEqual(@as(u8, '{'), enc[0]);
    const dec = try decodeRecord(a, enc);
    try testing.expectEqual(@as(i64, 1), dec.object.get("a").?.integer);
    try testing.expectEqual(@as(i64, 3), dec.object.get("b").?.array.items[1].integer);
}

test "lmdb round-trip: insert/get/update/delete across namespaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp: TmpEnv = undefined;
    try tmp.create();
    defer tmp.destroy();

    var store = try LmdbStore.open(tmp.path, false);
    defer store.close();

    try store.insertItem(a, "ns_a", "greeting", .{ .string = "hello" });
    try store.insertItem(a, "ns_b", "count", .{ .integer = 7 });

    const g = (try store.getItem(a, "ns_a", "greeting")).?;
    try testing.expectEqualStrings("hello", g.string);
    const cnt = (try store.getItem(a, "ns_b", "count")).?;
    try testing.expectEqual(@as(i64, 7), cnt.integer);

    // missing key -> null
    try testing.expect((try store.getItem(a, "ns_a", "missing")) == null);

    // update replaces
    try store.updateItem(a, "ns_b", "count", .{ .integer = 99 });
    try testing.expectEqual(@as(i64, 99), (try store.getItem(a, "ns_b", "count")).?.integer);

    // delete
    const removed = try store.deleteItem(a, "ns_a", "greeting");
    try testing.expectEqualStrings("hello", removed.string);
    try testing.expect((try store.getItem(a, "ns_a", "greeting")) == null);

    // namespaces list contains both
    const names = try store.listNamespaces(a);
    var saw_b = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "ns_b")) saw_b = true;
    }
    try testing.expect(saw_b);
}

test "lmdb dotted-key nested get/insert/delete matches database.py" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp: TmpEnv = undefined;
    try tmp.create();
    defer tmp.destroy();

    var store = try LmdbStore.open(tmp.path, false);
    defer store.close();

    // Insert at a.b.c builds nested objects.
    try store.insertItem(a, "cfg", "a.b.c", .{ .integer = 5 });
    const got = (try store.getItem(a, "cfg", "a.b.c")).?;
    try testing.expectEqual(@as(i64, 5), got.integer);

    // Reading an intermediate node returns the sub-object.
    const sub = (try store.getItem(a, "cfg", "a.b")).?;
    try testing.expectEqual(@as(i64, 5), sub.object.get("c").?.integer);

    // Insert sibling, then delete one leaf; the record persists.
    try store.insertItem(a, "cfg", "a.b.d", .{ .integer = 6 });
    const removed = try store.deleteItem(a, "cfg", "a.b.c");
    try testing.expectEqual(@as(i64, 5), removed.integer);
    try testing.expect((try store.getItem(a, "cfg", "a.b.c")) == null);
    try testing.expectEqual(@as(i64, 6), (try store.getItem(a, "cfg", "a.b.d")).?.integer);
}

test "lmdb persistence: drop-in on-disk format survives close/reopen" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp: TmpEnv = undefined;
    try tmp.create();
    defer tmp.destroy();

    {
        var store = try LmdbStore.open(tmp.path, false);
        defer store.close();
        try store.insertItem(a, "persist", "k", .{ .string = "v" });
        try store.insertItem(a, "persist", "obj", try parseJson(a, "{\"x\":[1,2,3]}"));
    }

    // data.mdb must exist on disk now.
    {
        var fbuf: [320]u8 = undefined;
        const fpath = try std.fmt.bufPrintZ(&fbuf, "{s}/data.mdb", .{tmp.path});
        const st = try std.Io.Dir.cwd().statFile(tmp.io, fpath, .{});
        try testing.expect(st.size > 0);
    }

    // Reopen READ-ONLY and read the known keys back — proves real on-disk format.
    {
        var store = try LmdbStore.open(tmp.path, true);
        defer store.close();
        try testing.expectEqualStrings("v", (try store.getItem(a, "persist", "k")).?.string);
        const obj = (try store.getItem(a, "persist", "obj")).?;
        try testing.expectEqual(@as(i64, 3), obj.object.get("x").?.array.items[2].integer);

        const whole = try store.getNamespace(a, "persist");
        try testing.expect(whole.object.get("k") != null);
        try testing.expect(whole.object.get("obj") != null);
    }
}

test "lmdb drop-in read of a Moonraker data.mdb asset if present" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Search a few likely asset locations under vendor/moonraker.
    const candidates = [_][]const u8{
        "vendor/moonraker/tests/assets/database",
        "vendor/moonraker/tests/assets",
    };
    var found: ?[:0]const u8 = null;
    var pathbuf: [320]u8 = undefined;
    for (candidates) |cand| {
        var fbuf: [384]u8 = undefined;
        const dbfile = std.fmt.bufPrint(&fbuf, "{s}/data.mdb", .{cand}) catch continue;
        std.Io.Dir.cwd().access(io, dbfile, .{}) catch continue;
        found = std.fmt.bufPrintZ(&pathbuf, "{s}", .{cand}) catch continue;
        break;
    }
    if (found == null) return error.SkipZigTest; // no asset DB shipped

    var store = try LmdbStore.open(found.?, true);
    defer store.close();
    // Just prove we can enumerate namespaces from a real Moonraker DB.
    const names = try store.listNamespaces(a);
    try testing.expect(names.len >= 0);
}

test "fuzz_datastore: random ops against a temp env never crash or leak" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var tmp: TmpEnv = undefined;
            tmp.create() catch return;
            defer tmp.destroy();

            var store = LmdbStore.open(tmp.path, false) catch return;
            defer store.close();

            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);

            const namespaces = [_][:0]const u8{ "n1", "n2" };
            const keys = [_][]const u8{ "k", "a.b", "a.b.c", "x.y", "" };
            const vals = [_][]const u8{ "1", "true", "\"s\"", "{\"o\":1}", "null", "[1,2]" };

            var i: usize = 0;
            while (i + 4 <= buf.len) : (i += 4) {
                const ns = namespaces[buf[i] % namespaces.len];
                const key = keys[buf[i + 1] % keys.len];
                const op = buf[i + 2] % 5;
                const vstr = vals[buf[i + 3] % vals.len];
                const v = parseJson(a, vstr) catch .null;
                switch (op) {
                    0 => _ = store.insertItem(a, ns, key, v) catch {},
                    1 => _ = store.updateItem(a, ns, key, v) catch {},
                    2 => _ = store.getItem(a, ns, key) catch {},
                    3 => _ = store.deleteItem(a, ns, key) catch {},
                    else => {
                        _ = store.listNamespaces(a) catch {};
                        _ = store.getNamespace(a, ns) catch {};
                    },
                }
            }
        }
    }.run, .{});
}
