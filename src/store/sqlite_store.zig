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
    /// Serializes read-modify-write so concurrent inserts to one top-level
    /// record can't lose updates. SQLite's FULLMUTEX only serializes individual
    /// C-API calls — it does NOT make the load-decode-modify-encode-store
    /// sequence below atomic, so two writers racing on sub-keys of the same
    /// record would clobber each other without this. Mirrors FileStore.
    ///
    /// A spinlock (not std.Io.Mutex) because SqliteStore opens with no io
    /// handle (see app.zig); the RMW sections are short and writes are rare, so
    /// contention is negligible.
    rmw_lock: std.atomic.Value(bool) = .init(false),

    fn lockRmw(self: *SqliteStore) void {
        while (self.rmw_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }
    fn unlockRmw(self: *SqliteStore) void {
        self.rmw_lock.store(false, .release);
    }

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
        self.execSql("PRAGMA journal_mode=WAL;") catch |err|
            std.debug.print("phobos: warning: sqlite PRAGMA journal_mode=WAL failed: {} — reduced crash-safety\n", .{err});
        self.execSql("PRAGMA synchronous=NORMAL;") catch |err|
            std.debug.print("phobos: warning: sqlite PRAGMA synchronous=NORMAL failed: {}\n", .{err});
        // Block (up to 5s) on a contended lock instead of failing a write
        // immediately with SQLITE_BUSY → BackendError. Covers WAL checkpoints
        // and any concurrent reader holding the DB momentarily.
        self.execSql("PRAGMA busy_timeout=5000;") catch |err|
            std.debug.print("phobos: warning: sqlite PRAGMA busy_timeout failed: {} — writes may fail under contention\n", .{err});
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
        const raw = (try self.getRecordRaw(arena, namespace, segs[0])) orelse {
            // Drop-in fallback: history lives in the dedicated tables, not KV.
            // For a single job lookup, query that one row by its PRIMARY KEY
            // (job_id) instead of scanning the whole job_history table and
            // materialising every job just to pick one — the latter is O(rows)
            // per get and degrades linearly as print history grows.
            if (std.mem.eql(u8, namespace, "history")) {
                const job = (try self.historyJobFromTable(arena, segs[0])) orelse return null;
                return ds.getPath(job, segs[1..]) catch |e| switch (e) {
                    ds.Error.KeyNotFound => null,
                    else => |o| o,
                };
            }
            const ns_val: ?json.Value = if (std.mem.eql(u8, namespace, "history_totals"))
                try self.totalsFromTable(arena)
            else
                null;
            if (ns_val) |nv| {
                if (nv == .object) {
                    if (nv.object.get(segs[0])) |top| {
                        return ds.getPath(top, segs[1..]) catch |e| switch (e) {
                            ds.Error.KeyNotFound => null,
                            else => |o| o,
                        };
                    }
                }
            }
            return null;
        };
        const record = try decodeRecord(arena, raw);
        return ds.getPath(record, segs[1..]) catch |e| switch (e) {
            ds.Error.KeyNotFound => null,
            else => |o| o,
        };
    }

    pub fn insertItem(self: *SqliteStore, arena: std.mem.Allocator, namespace: [:0]const u8, key: []const u8, value: json.Value) Error!void {
        const pk = try ds.parseKey(key);
        const segs = pk.slice();
        self.lockRmw();
        defer self.unlockRmw();
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
        self.lockRmw();
        defer self.unlockRmw();
        const raw = (try self.getRecordRaw(arena, namespace, segs[0])) orelse return Error.KeyNotFound;
        const record = try decodeRecord(arena, raw);
        const new_record = try ds.updatePath(arena, record, segs[1..], value);
        try self.putRecordRaw(namespace, segs[0], try encodeRecord(arena, new_record));
    }

    pub fn deleteItem(self: *SqliteStore, arena: std.mem.Allocator, namespace: [:0]const u8, key: []const u8) Error!json.Value {
        const pk = try ds.parseKey(key);
        const segs = pk.slice();
        self.lockRmw();
        defer self.unlockRmw();
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
        // Drop-in compatibility: a Moonraker `moonraker-sql.db` keeps job history
        // in the dedicated `job_history`/`job_totals` tables, not in
        // `namespace_store`. If the KV namespace is empty, fall back to those
        // tables so phobos surfaces the user's existing history.
        if (obj.count() == 0) {
            if (std.mem.eql(u8, namespace, "history")) return self.historyFromTable(arena);
            if (std.mem.eql(u8, namespace, "history_totals")) return self.totalsFromTable(arena);
        }
        return .{ .object = obj };
    }

    /// Read Moonraker's `job_history` table into the `{job_id: job}` shape
    /// phobos's history component expects. Returns an empty object if the table
    /// is absent (a fresh phobos DB). Job ids are formatted as 6-hex like phobos.
    fn historyFromTable(self: *SqliteStore, arena: std.mem.Allocator) Error!json.Value {
        var obj: json.ObjectMap = .empty;
        const sql = "SELECT job_id, user, filename, status, start_time, end_time, print_duration, total_duration, filament_used, metadata, auxiliary_data FROM job_history";
        const stmt = self.prepare(sql) catch return .{ .object = obj }; // no table → empty
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const row = try mapJobRow(arena, stmt);
            obj.put(arena, row.key, row.value) catch return Error.BackendError;
        }
        return .{ .object = obj };
    }

    /// Read a single job from Moonraker's `job_history` table by its hex
    /// `job_key` (phobos's 6-hex job id), using the table's PRIMARY KEY for an
    /// indexed lookup. Returns null if the table is absent, the key is not
    /// valid hex, or no such job exists.
    fn historyJobFromTable(self: *SqliteStore, arena: std.mem.Allocator, job_key: []const u8) Error!?json.Value {
        const jid = std.fmt.parseInt(u64, job_key, 16) catch return null;
        const sql = "SELECT job_id, user, filename, status, start_time, end_time, print_duration, total_duration, filament_used, metadata, auxiliary_data FROM job_history WHERE job_id=?1";
        const stmt = self.prepare(sql) catch return null; // no table → not found
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, @intCast(jid));
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return (try mapJobRow(arena, stmt)).value;
    }

    /// Read Moonraker's `job_totals` table (provider `history`) into the
    /// `{totals: {job_totals, auxiliary_totals}}` shape phobos expects.
    fn totalsFromTable(self: *SqliteStore, arena: std.mem.Allocator) Error!json.Value {
        var jt: json.ObjectMap = .empty;
        const sql = "SELECT field, maximum, total FROM job_totals WHERE provider='history'";
        const stmt = self.prepare(sql) catch return .{ .object = .empty };
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const field = colTextRaw(stmt, 0) orelse continue;
            // longest_* track a maximum; the rest are running totals.
            const is_max = std.mem.startsWith(u8, field, "longest");
            const v = if (is_max) c.sqlite3_column_double(stmt, 1) else c.sqlite3_column_double(stmt, 2);
            putF(arena, &jt, field, v);
        }
        if (jt.count() == 0) return .{ .object = .empty }; // no table/rows
        // phobos stores the `totals` key as the FLAT job_totals fields;
        // handleTotals wraps them under "job_totals" itself.
        var top: json.ObjectMap = .empty;
        top.put(arena, "totals", .{ .object = jt }) catch return Error.BackendError;
        return .{ .object = top };
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

// --- small column/JSON helpers for the history table mapping ----------------

fn putKV(arena: std.mem.Allocator, obj: *json.ObjectMap, key: []const u8, val: json.Value) void {
    const k = arena.dupe(u8, key) catch return;
    obj.put(arena, k, val) catch {};
}
fn put(arena: std.mem.Allocator, obj: *json.ObjectMap, key: []const u8, s: []const u8) void {
    putKV(arena, obj, key, .{ .string = s });
}
fn putF(arena: std.mem.Allocator, obj: *json.ObjectMap, key: []const u8, f: f64) void {
    putKV(arena, obj, key, .{ .float = f });
}
/// Column text duped into `arena` ("" if NULL).
fn colText(arena: std.mem.Allocator, stmt: *c.sqlite3_stmt, idx: c_int) []const u8 {
    const n: usize = @intCast(c.sqlite3_column_bytes(stmt, idx));
    const t = c.sqlite3_column_text(stmt, idx) orelse return "";
    return arena.dupe(u8, t[0..n]) catch "";
}
/// Column text as a transient slice into SQLite memory (valid until next step).
fn colTextRaw(stmt: *c.sqlite3_stmt, idx: c_int) ?[]const u8 {
    const n: usize = @intCast(c.sqlite3_column_bytes(stmt, idx));
    const t = c.sqlite3_column_text(stmt, idx) orelse return null;
    return t[0..n];
}
/// Parse a JSON-text column into a Value, or `default` if NULL/empty/invalid.
fn colJson(arena: std.mem.Allocator, stmt: *c.sqlite3_stmt, idx: c_int, default: json.Value) json.Value {
    const t = c.sqlite3_column_text(stmt, idx) orelse return default;
    const n: usize = @intCast(c.sqlite3_column_bytes(stmt, idx));
    if (n == 0) return default;
    return json.parseFromSliceLeaky(json.Value, arena, t[0..n], .{}) catch default;
}

/// A `job_history` row mapped to phobos's `{job_id: job}` shape. `key` (the
/// 6-hex job id) is shared with the job object's `job_id` field — both borrow
/// the same arena-owned string.
const MappedJob = struct { key: []const u8, value: json.Value };

/// Map the current `job_history` result row (column order per the SELECT in
/// `historyFromTable`/`historyJobFromTable`) into a job object.
fn mapJobRow(arena: std.mem.Allocator, stmt: *c.sqlite3_stmt) Error!MappedJob {
    var job: json.ObjectMap = .empty;
    // job_id is a positive INTEGER; format as unsigned 6-hex (matching phobos's
    // own key format). Signed formatting would emit a `+` sign.
    const jid: u64 = @intCast(c.sqlite3_column_int64(stmt, 0));
    put(arena, &job, "filename", colText(arena, stmt, 2));
    put(arena, &job, "status", colText(arena, stmt, 3));
    put(arena, &job, "user", colText(arena, stmt, 1));
    putF(arena, &job, "start_time", c.sqlite3_column_double(stmt, 4));
    putF(arena, &job, "end_time", c.sqlite3_column_double(stmt, 5));
    putF(arena, &job, "print_duration", c.sqlite3_column_double(stmt, 6));
    putF(arena, &job, "total_duration", c.sqlite3_column_double(stmt, 7));
    putF(arena, &job, "filament_used", c.sqlite3_column_double(stmt, 8));
    job.put(arena, "metadata", colJson(arena, stmt, 9, .{ .object = .empty })) catch return Error.BackendError;
    job.put(arena, "auxiliary_data", colJson(arena, stmt, 10, .{ .array = .init(arena) })) catch return Error.BackendError;
    const key = std.fmt.allocPrint(arena, "{X:0>6}", .{jid}) catch return Error.BackendError;
    job.put(arena, "job_id", .{ .string = key }) catch return Error.BackendError;
    return .{ .key = key, .value = .{ .object = job } };
}

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

test "SqliteStore: reads Moonraker job_history/job_totals tables (drop-in compat)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const pid = std.os.linux.getpid();
    const path = try std.fmt.allocPrintSentinel(a, "/tmp/phobos-hist-test-{d}.db", .{pid}, 0);
    const wal = try std.fmt.allocPrint(a, "{s}-wal", .{path});
    const shm = try std.fmt.allocPrint(a, "{s}-shm", .{path});
    const cwd = std.Io.Dir.cwd();
    for ([_][]const u8{ path, wal, shm }) |p| cwd.deleteFile(io, p) catch {};
    defer for ([_][]const u8{ path, wal, shm }) |p| cwd.deleteFile(io, p) catch {};

    var s = try SqliteStore.open(testing.allocator, path);
    defer s.deinit();
    // Recreate Moonraker's dedicated history tables + a couple of rows.
    try s.execSql(
        \\CREATE TABLE job_history (job_id INTEGER PRIMARY KEY ASC, user TEXT NOT NULL,
        \\ filename TEXT, status TEXT NOT NULL, start_time REAL NOT NULL, end_time REAL,
        \\ print_duration REAL NOT NULL, total_duration REAL NOT NULL, filament_used REAL NOT NULL,
        \\ metadata pyjson, auxiliary_data pyjson NOT NULL, instance_id TEXT NOT NULL);
    );
    try s.execSql(
        \\INSERT INTO job_history VALUES
        \\ (1,'me','a.gcode','completed',100.0,200.0,90.0,100.0,42.5,'{"layers":3}','[]','default'),
        \\ (2,'me','b.gcode','cancelled',300.0,350.0,40.0,50.0,10.0,NULL,'[]','default');
    );
    try s.execSql(
        \\CREATE TABLE job_totals (provider TEXT NOT NULL, field TEXT NOT NULL, maximum REAL,
        \\ total REAL, instance_id TEXT NOT NULL, PRIMARY KEY (provider, field, instance_id));
    );
    try s.execSql(
        \\INSERT INTO job_totals VALUES
        \\ ('history','total_jobs',NULL,2.0,'default'),
        \\ ('history','total_filament_used',NULL,52.5,'default'),
        \\ ('history','longest_job',150.0,NULL,'default');
    );

    // getNamespace("history") maps rows → {hex_job_id: job}.
    const hist = try s.getNamespace(a, "history");
    try testing.expect(hist == .object);
    try testing.expectEqual(@as(usize, 2), hist.object.count());
    const j1 = hist.object.get("000001").?.object;
    try testing.expectEqualStrings("a.gcode", j1.get("filename").?.string);
    try testing.expectEqualStrings("completed", j1.get("status").?.string);
    try testing.expectEqual(@as(f64, 42.5), j1.get("filament_used").?.float);
    try testing.expectEqual(@as(i64, 3), j1.get("metadata").?.object.get("layers").?.integer);
    try testing.expectEqualStrings("000001", j1.get("job_id").?.string);

    // getItem reaches a single mapped job, and the totals key.
    const j2 = (try s.getItem(a, "history", "000002")).?.object;
    try testing.expectEqualStrings("b.gcode", j2.get("filename").?.string);
    const totals = (try s.getItem(a, "history_totals", "totals")).?.object;
    try testing.expectEqual(@as(f64, 2.0), totals.get("total_jobs").?.float);
    try testing.expectEqual(@as(f64, 52.5), totals.get("total_filament_used").?.float);
    try testing.expectEqual(@as(f64, 150.0), totals.get("longest_job").?.float); // uses maximum col
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
