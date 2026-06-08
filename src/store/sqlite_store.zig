//! SqliteStore — a SQLite-backed DataStore, drop-in compatible with Moonraker's
//! `moonraker-sql.db` (the database backend current Moonraker uses).
//!
//! Stores the namespaced key/value data in the `namespace_store` table
//! (`namespace TEXT, key TEXT, value record, PRIMARY KEY(namespace,key)`), with
//! Moonraker's exact `record` value encoding so an existing Moonraker database
//! reads/writes interchangeably:
//!   int   → 'q' + 8-byte little-endian i64
//!   float → 'd' + 8-byte little-endian f64
//!   bool  → '?' + 1 byte
//!   str   → 's' + UTF-8 bytes
//!   list  → raw JSON (begins '[')
//!   dict  → raw JSON (begins '{')
//!   None  → 0x00
//!
//! Dotted-key path semantics are shared with the other backends via
//! `datastore.zig`. SQLite is opened SERIALIZED (FULLMUTEX) so it is safe across
//! phobos's threads.

const std = @import("std");
const json = std.json;
const c = @import("sqlite_c.zig");
const ds = @import("datastore.zig");
const Error = ds.Error;

pub const SqliteStore = struct {
    gpa: std.mem.Allocator,
    db: *c.sqlite3,

    pub fn open(gpa: std.mem.Allocator, path: [:0]const u8) Error!SqliteStore {
        _ = c.sqlite3_initialize();
        var db: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        if (c.sqlite3_open_v2(path.ptr, &db, flags, null) != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return Error.BackendError;
        }
        var self = SqliteStore{ .gpa = gpa, .db = db.? };
        // WAL for crash-safety + concurrency; create the namespace table to match
        // Moonraker's schema (the `record` declared type drives no behaviour here
        // — we encode/decode the blobs ourselves — but keeps the schema identical).
        self.execSql("PRAGMA journal_mode=WAL;") catch {};
        self.execSql("PRAGMA synchronous=NORMAL;") catch {};
        try self.execSql(
            \\CREATE TABLE IF NOT EXISTS namespace_store (
            \\    namespace TEXT NOT NULL,
            \\    key TEXT NOT NULL,
            \\    value record NOT NULL,
            \\    PRIMARY KEY (namespace, key)
            \\);
        );
        return self;
    }

    pub fn deinit(self: *SqliteStore) void {
        _ = c.sqlite3_close(self.db);
    }

    fn execSql(self: *SqliteStore, sql: [:0]const u8) Error!void {
        if (c.sqlite3_exec(self.db, sql.ptr, null, null, null) != c.SQLITE_OK) return Error.BackendError;
    }

    fn prepare(self: *SqliteStore, sql: []const u8) Error!*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) return Error.BackendError;
        return stmt orelse Error.BackendError;
    }

    fn bindText(stmt: *c.sqlite3_stmt, idx: c_int, s: []const u8) void {
        _ = c.sqlite3_bind_text(stmt, idx, s.ptr, @intCast(s.len), c.SQLITE_TRANSIENT);
    }

    // --- record encode/decode (Moonraker format) --------------------------

    fn encodeRecord(arena: std.mem.Allocator, value: json.Value) Error![]u8 {
        switch (value) {
            .null => return arena.dupe(u8, &[_]u8{0}) catch Error.BackendError,
            .bool => |b| return arena.dupe(u8, &[_]u8{ '?', @intFromBool(b) }) catch Error.BackendError,
            .integer => |i| {
                var buf = arena.alloc(u8, 9) catch return Error.BackendError;
                buf[0] = 'q';
                std.mem.writeInt(i64, buf[1..9], i, .little);
                return buf;
            },
            .float => |f| {
                var buf = arena.alloc(u8, 9) catch return Error.BackendError;
                buf[0] = 'd';
                std.mem.writeInt(u64, buf[1..9], @bitCast(f), .little);
                return buf;
            },
            .string => |s| {
                var buf = arena.alloc(u8, s.len + 1) catch return Error.BackendError;
                buf[0] = 's';
                @memcpy(buf[1..], s);
                return buf;
            },
            .number_string => |s| {
                // A JSON number that didn't fit i64/f64 — store as int if it parses,
                // else float, mirroring Moonraker's typed encoding.
                if (std.fmt.parseInt(i64, s, 10)) |i| {
                    return encodeRecord(arena, .{ .integer = i });
                } else |_| {
                    const f = std.fmt.parseFloat(f64, s) catch return Error.BackendError;
                    return encodeRecord(arena, .{ .float = f });
                }
            },
            .array, .object => {
                // Raw JSON (begins '[' or '{') — matches Moonraker's list/dict.
                var aw: std.Io.Writer.Allocating = .init(arena);
                var jw: json.Stringify = .{ .writer = &aw.writer };
                jw.write(value) catch return Error.BackendError;
                return aw.written();
            },
        }
    }

    fn decodeRecord(arena: std.mem.Allocator, bytes: []const u8) Error!json.Value {
        if (bytes.len == 0) return .null;
        switch (bytes[0]) {
            0 => return .null,
            '?' => return .{ .bool = if (bytes.len >= 2) bytes[1] != 0 else false },
            'q' => {
                if (bytes.len < 9) return Error.BackendError;
                return .{ .integer = std.mem.readInt(i64, bytes[1..9], .little) };
            },
            'd' => {
                if (bytes.len < 9) return Error.BackendError;
                return .{ .float = @bitCast(std.mem.readInt(u64, bytes[1..9], .little)) };
            },
            's' => return .{ .string = arena.dupe(u8, bytes[1..]) catch return Error.BackendError },
            '[', '{' => return json.parseFromSliceLeaky(json.Value, arena, bytes, .{}) catch Error.BackendError,
            // Unknown tag: fall back to the whole blob as a string (Moonraker does
            // the same on a decode exception).
            else => return .{ .string = arena.dupe(u8, bytes) catch return Error.BackendError },
        }
    }

    // --- raw record get/put over namespace_store --------------------------

    fn getRecordRaw(self: *SqliteStore, arena: std.mem.Allocator, namespace: []const u8, record_key: []const u8) Error!?[]u8 {
        const stmt = try self.prepare("SELECT value FROM namespace_store WHERE namespace=?1 AND key=?2");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, namespace);
        bindText(stmt, 2, record_key);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return Error.BackendError;
        const n: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        if (n == 0) return try arena.alloc(u8, 0);
        const ptr = c.sqlite3_column_blob(stmt, 0) orelse return try arena.alloc(u8, 0);
        const src = @as([*]const u8, @ptrCast(ptr))[0..n];
        return arena.dupe(u8, src) catch Error.BackendError;
    }

    fn putRecordRaw(self: *SqliteStore, namespace: []const u8, record_key: []const u8, value: ?[]const u8) Error!void {
        if (value) |v| {
            const stmt = try self.prepare("INSERT OR REPLACE INTO namespace_store (namespace,key,value) VALUES (?1,?2,?3)");
            defer _ = c.sqlite3_finalize(stmt);
            bindText(stmt, 1, namespace);
            bindText(stmt, 2, record_key);
            _ = c.sqlite3_bind_blob(stmt, 3, v.ptr, @intCast(v.len), c.SQLITE_TRANSIENT);
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.BackendError;
        } else {
            const stmt = try self.prepare("DELETE FROM namespace_store WHERE namespace=?1 AND key=?2");
            defer _ = c.sqlite3_finalize(stmt);
            bindText(stmt, 1, namespace);
            bindText(stmt, 2, record_key);
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.BackendError;
        }
    }

    // --- DataStore API (shared dotted-key path helpers) -------------------

    pub fn getItem(self: *SqliteStore, arena: std.mem.Allocator, namespace: [:0]const u8, key: []const u8) Error!?json.Value {
        const pk = try ds.parseKey(key);
        const segs = pk.slice();
        const raw = (try self.getRecordRaw(arena, namespace, segs[0])) orelse return null;
        const record = try decodeRecord(arena, raw);
        return ds.getPath(record, segs[1..]) catch |e| switch (e) {
            ds.Error.KeyNotFound => null,
            else => |o| o,
        };
    }

    pub fn insertItem(self: *SqliteStore, arena: std.mem.Allocator, namespace: [:0]const u8, key: []const u8, value: json.Value) Error!void {
        const pk = try ds.parseKey(key);
        const segs = pk.slice();
        var record: json.Value = .null;
        if (segs.len > 1) {
            if (try self.getRecordRaw(arena, namespace, segs[0])) |raw| {
                record = try decodeRecord(arena, raw);
            } else record = .{ .object = .empty };
        }
        const new_record = try ds.insertPath(arena, record, segs[1..], value);
        try self.putRecordRaw(namespace, segs[0], try encodeRecord(arena, new_record));
    }

    pub fn updateItem(self: *SqliteStore, arena: std.mem.Allocator, namespace: [:0]const u8, key: []const u8, value: json.Value) Error!void {
        const pk = try ds.parseKey(key);
        const segs = pk.slice();
        const raw = (try self.getRecordRaw(arena, namespace, segs[0])) orelse return Error.KeyNotFound;
        const record = try decodeRecord(arena, raw);
        const new_record = try ds.updatePath(arena, record, segs[1..], value);
        try self.putRecordRaw(namespace, segs[0], try encodeRecord(arena, new_record));
    }

    pub fn deleteItem(self: *SqliteStore, arena: std.mem.Allocator, namespace: [:0]const u8, key: []const u8) Error!json.Value {
        const pk = try ds.parseKey(key);
        const segs = pk.slice();
        const raw = (try self.getRecordRaw(arena, namespace, segs[0])) orelse return Error.KeyNotFound;
        const record = try decodeRecord(arena, raw);
        const res = try ds.deletePath(record, segs[1..]);
        if (res.record) |new_record| {
            try self.putRecordRaw(namespace, segs[0], try encodeRecord(arena, new_record));
        } else {
            try self.putRecordRaw(namespace, segs[0], null);
        }
        return res.removed;
    }

    pub fn listNamespaces(self: *SqliteStore, arena: std.mem.Allocator) Error![][]const u8 {
        const stmt = try self.prepare("SELECT DISTINCT namespace FROM namespace_store");
        defer _ = c.sqlite3_finalize(stmt);
        var out: std.ArrayList([]const u8) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const n: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            const txt = c.sqlite3_column_text(stmt, 0) orelse continue;
            out.append(arena, arena.dupe(u8, txt[0..n]) catch return Error.BackendError) catch return Error.BackendError;
        }
        return out.toOwnedSlice(arena) catch Error.BackendError;
    }

    pub fn getNamespace(self: *SqliteStore, arena: std.mem.Allocator, namespace: [:0]const u8) Error!json.Value {
        const stmt = try self.prepare("SELECT key, value FROM namespace_store WHERE namespace=?1");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, namespace);
        var obj: json.ObjectMap = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const kn: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            const ktxt = c.sqlite3_column_text(stmt, 0) orelse continue;
            const key = arena.dupe(u8, ktxt[0..kn]) catch return Error.BackendError;
            const vn: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
            const vptr = c.sqlite3_column_blob(stmt, 1);
            const vbytes = if (vptr) |p| @as([*]const u8, @ptrCast(p))[0..vn] else &[_]u8{};
            const val = try decodeRecord(arena, vbytes);
            obj.put(arena, key, val) catch return Error.BackendError;
        }
        return .{ .object = obj };
    }

    // --- DataStore vtable adapter -----------------------------------------

    pub fn dataStore(self: *SqliteStore) ds.DataStore {
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

    fn vtGetItem(ctx: *anyopaque, arena: std.mem.Allocator, namespace: [:0]const u8, key: []const u8) Error!?json.Value {
        return getItem(@ptrCast(@alignCast(ctx)), arena, namespace, key);
    }
    fn vtInsertItem(ctx: *anyopaque, arena: std.mem.Allocator, namespace: [:0]const u8, key: []const u8, value: json.Value) Error!void {
        return insertItem(@ptrCast(@alignCast(ctx)), arena, namespace, key, value);
    }
    fn vtUpdateItem(ctx: *anyopaque, arena: std.mem.Allocator, namespace: [:0]const u8, key: []const u8, value: json.Value) Error!void {
        return updateItem(@ptrCast(@alignCast(ctx)), arena, namespace, key, value);
    }
    fn vtDeleteItem(ctx: *anyopaque, arena: std.mem.Allocator, namespace: [:0]const u8, key: []const u8) Error!json.Value {
        return deleteItem(@ptrCast(@alignCast(ctx)), arena, namespace, key);
    }
    fn vtListNamespaces(ctx: *anyopaque, arena: std.mem.Allocator) Error![][]const u8 {
        return listNamespaces(@ptrCast(@alignCast(ctx)), arena);
    }
    fn vtGetNamespace(ctx: *anyopaque, arena: std.mem.Allocator, namespace: [:0]const u8) Error!json.Value {
        return getNamespace(@ptrCast(@alignCast(ctx)), arena, namespace);
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "SqliteStore: record encode/decode round-trips every type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]json.Value{
        .null,
        .{ .bool = true },
        .{ .bool = false },
        .{ .integer = -9223372036854775808 },
        .{ .integer = 42 },
        .{ .float = 3.14159 },
        .{ .string = "hello world" },
    };
    for (cases) |v| {
        const enc = try SqliteStore.encodeRecord(a, v);
        const dec = try SqliteStore.decodeRecord(a, enc);
        try testing.expect(@as(std.meta.Tag(json.Value), dec) == @as(std.meta.Tag(json.Value), v));
    }
    // Known Moonraker encodings.
    try testing.expectEqualSlices(u8, &[_]u8{0}, try SqliteStore.encodeRecord(a, .null));
    try testing.expectEqual(@as(u8, 'q'), (try SqliteStore.encodeRecord(a, .{ .integer = 1 }))[0]);
    try testing.expectEqual(@as(u8, 's'), (try SqliteStore.encodeRecord(a, .{ .string = "x" }))[0]);
}

test "SqliteStore: insert/get/update/delete + persistence (in-file)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const pid = std.os.linux.getpid();
    const path = try std.fmt.allocPrintSentinel(a, "/tmp/phobos-sqlite-test-{d}.db", .{pid}, 0);
    const wal = try std.fmt.allocPrint(a, "{s}-wal", .{path});
    const shm = try std.fmt.allocPrint(a, "{s}-shm", .{path});
    const cwd = std.Io.Dir.cwd();
    for ([_][]const u8{ path, wal, shm }) |p| cwd.deleteFile(io, p) catch {};
    defer for ([_][]const u8{ path, wal, shm }) |p| cwd.deleteFile(io, p) catch {};
    {
        var s = try SqliteStore.open(testing.allocator, path);
        defer s.deinit();
        try s.insertItem(a, "moonraker", "file_manager.metadata_version", .{ .integer = 3 });
        try testing.expectEqual(@as(i64, 3), (try s.getItem(a, "moonraker", "file_manager.metadata_version")).?.integer);
        try s.updateItem(a, "moonraker", "file_manager.metadata_version", .{ .integer = 4 });
        try s.insertItem(a, "moonraker", "instance_id", .{ .string = "abc" });
    }
    {
        var s = try SqliteStore.open(testing.allocator, path);
        defer s.deinit();
        try testing.expectEqual(@as(i64, 4), (try s.getItem(a, "moonraker", "file_manager.metadata_version")).?.integer);
        const names = try s.listNamespaces(a);
        try testing.expect(names.len >= 1);
        const removed = try s.deleteItem(a, "moonraker", "instance_id");
        try testing.expectEqualStrings("abc", removed.string);
        try testing.expect((try s.getItem(a, "moonraker", "instance_id")) == null);
    }
}

test "fuzz SqliteStore record decode: arbitrary bytes never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var buf: [64]u8 = undefined;
            const n = smith.valueRangeAtMostWithHash(u32, 0, 64, 0);
            smith.bytesWithHash(buf[0..n], 1);
            _ = SqliteStore.decodeRecord(a, buf[0..n]) catch {};
        }
    }.run, .{});
}
