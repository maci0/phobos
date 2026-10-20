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
    io: std.Io,
    db: *c.sqlite3,
    /// Serializes operations: FULLMUTEX covers individual C calls, not a whole
    /// read-modify-write or the table/KV history transaction. Readers must not
    /// observe that transaction before it commits. Mirrors FileStore.
    rmw_lock: std.Io.Mutex = .init,

    fn lockRmw(self: *SqliteStore) void {
        self.rmw_lock.lockUncancelable(self.io);
    }
    fn unlockRmw(self: *SqliteStore) void {
        self.rmw_lock.unlock(self.io);
    }

    pub fn open(io: std.Io, path: [:0]const u8) Error!SqliteStore {
        if (std.mem.indexOfScalar(u8, path, 0) != null) return Error.BackendError;
        if (std.fs.path.dirname(path)) |parent| {
            var parent_dir = std.Io.Dir.cwd().createDirPathOpen(io, parent, .{}) catch return Error.BackendError;
            parent_dir.close(io);
        }
        // Built with SQLITE_OMIT_AUTOINIT: opening after a failed initialize
        // is undefined.
        if (c.sqlite3_initialize() != c.SQLITE_OK) return Error.BackendError;
        var db: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        if (c.sqlite3_open_v2(path.ptr, &db, flags, null) != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return Error.BackendError;
        }
        errdefer _ = c.sqlite3_close(db.?);
        var self = SqliteStore{ .io = io, .db = db.? };
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

    fn bindText(stmt: *c.sqlite3_stmt, idx: c_int, s: []const u8) Error!void {
        if (c.sqlite3_bind_text(stmt, idx, s.ptr, @intCast(s.len), c.SQLITE_TRANSIENT) != c.SQLITE_OK)
            return Error.BackendError;
    }

    // --- record encode/decode (Moonraker format) --------------------------

    fn encodeRecord(arena: std.mem.Allocator, value: json.Value) Error![]u8 {
        switch (value) {
            .null => return arena.dupe(u8, &[_]u8{0}),
            .bool => |b| return arena.dupe(u8, &[_]u8{ '?', @intFromBool(b) }),
            .integer => |i| {
                var buf = try arena.alloc(u8, 9);
                buf[0] = 'q';
                std.mem.writeInt(i64, buf[1..9], i, .little);
                return buf;
            },
            .float => |f| {
                var buf = try arena.alloc(u8, 9);
                buf[0] = 'd';
                std.mem.writeInt(u64, buf[1..9], @bitCast(f), .little);
                return buf;
            },
            .string => |s| {
                var buf = try arena.alloc(u8, s.len + 1);
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
                jw.write(value) catch return Error.OutOfMemory;
                return aw.written();
            },
        }
    }

    fn decodeRecord(arena: std.mem.Allocator, bytes: []const u8) Error!json.Value {
        if (bytes.len == 0) return Error.BackendError;
        switch (bytes[0]) {
            0 => return .null,
            '?' => {
                if (bytes.len != 2) return Error.BackendError;
                return .{ .bool = bytes[1] != 0 };
            },
            'q' => {
                if (bytes.len != 9) return Error.BackendError;
                return .{ .integer = std.mem.readInt(i64, bytes[1..9], .little) };
            },
            'd' => {
                if (bytes.len != 9) return Error.BackendError;
                return .{ .float = @bitCast(std.mem.readInt(u64, bytes[1..9], .little)) };
            },
            's' => {
                if (!std.unicode.utf8ValidateSlice(bytes[1..])) return Error.BackendError;
                return .{ .string = try arena.dupe(u8, bytes[1..]) };
            },
            '[', '{' => return json.parseFromSliceLeaky(json.Value, arena, bytes, .{}) catch |err| switch (err) {
                error.OutOfMemory => Error.OutOfMemory,
                else => Error.BackendError,
            },
            // Moonraker `decode_record` raises on an unknown format byte.
            else => return Error.BackendError,
        }
    }

    // --- raw record get/put over namespace_store --------------------------

    fn getRecordRaw(self: *SqliteStore, arena: std.mem.Allocator, namespace: []const u8, record_key: []const u8) Error!?[]u8 {
        const stmt = try self.prepare("SELECT value FROM namespace_store WHERE namespace=?1 AND key=?2");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, namespace);
        try bindText(stmt, 2, record_key);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return Error.BackendError;
        const n: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        if (n == 0) return try arena.alloc(u8, 0);
        const ptr = c.sqlite3_column_blob(stmt, 0) orelse return try arena.alloc(u8, 0);
        const src = @as([*]const u8, @ptrCast(ptr))[0..n];
        return try arena.dupe(u8, src);
    }

    fn putRecordRaw(self: *SqliteStore, namespace: []const u8, record_key: []const u8, value: ?[]const u8) Error!void {
        if (value) |v| {
            const stmt = try self.prepare("INSERT OR REPLACE INTO namespace_store (namespace,key,value) VALUES (?1,?2,?3)");
            defer _ = c.sqlite3_finalize(stmt);
            try bindText(stmt, 1, namespace);
            try bindText(stmt, 2, record_key);
            if (c.sqlite3_bind_blob(stmt, 3, v.ptr, @intCast(v.len), c.SQLITE_TRANSIENT) != c.SQLITE_OK)
                return Error.BackendError;
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.BackendError;
        } else {
            const stmt = try self.prepare("DELETE FROM namespace_store WHERE namespace=?1 AND key=?2");
            defer _ = c.sqlite3_finalize(stmt);
            try bindText(stmt, 1, namespace);
            try bindText(stmt, 2, record_key);
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.BackendError;
        }
    }

    // --- DataStore API (shared dotted-key path helpers) -------------------

    pub fn getItem(self: *SqliteStore, arena: std.mem.Allocator, namespace: [:0]const u8, key: []const u8) Error!?json.Value {
        self.lockRmw();
        defer self.unlockRmw();
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
        const migrated_history = segs.len == 1 and std.mem.eql(u8, namespace, "history");
        if (migrated_history) try self.execSql("BEGIN IMMEDIATE");
        errdefer if (migrated_history) self.execSql("ROLLBACK") catch |err|
            std.debug.print("phobos: warning: history deletion rollback failed: {}\n", .{err});
        const removed = try self.deleteRecord(arena, namespace, segs);
        if (migrated_history) try self.execSql("COMMIT");
        return removed;
    }

    fn deleteRecord(self: *SqliteStore, arena: std.mem.Allocator, namespace: [:0]const u8, segs: []const []const u8) Error!json.Value {
        // A migrated `job_history` row is a whole history record; delete it
        // with its key so it cannot reappear behind the removed KV record.
        const table_job: ?json.Value = if (segs.len == 1 and std.mem.eql(u8, namespace, "history"))
            try self.deleteHistoryRow(arena, segs[0])
        else
            null;
        const raw = (try self.getRecordRaw(arena, namespace, segs[0])) orelse
            return table_job orelse Error.KeyNotFound;
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
        self.lockRmw();
        defer self.unlockRmw();
        const stmt = try self.prepare("SELECT DISTINCT namespace FROM namespace_store");
        defer _ = c.sqlite3_finalize(stmt);
        var out: std.ArrayList([]const u8) = .empty;
        var rc = c.sqlite3_step(stmt);
        while (rc == c.SQLITE_ROW) : (rc = c.sqlite3_step(stmt)) {
            const n: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            const txt = c.sqlite3_column_text(stmt, 0) orelse continue;
            try out.append(arena, try arena.dupe(u8, txt[0..n]));
        }
        if (rc != c.SQLITE_DONE) return Error.BackendError;
        return out.toOwnedSlice(arena);
    }

    pub fn getNamespace(self: *SqliteStore, arena: std.mem.Allocator, namespace: [:0]const u8) Error!json.Value {
        self.lockRmw();
        defer self.unlockRmw();
        const stmt = try self.prepare("SELECT key, value FROM namespace_store WHERE namespace=?1");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, namespace);
        var obj: json.ObjectMap = .empty;
        var rc = c.sqlite3_step(stmt);
        while (rc == c.SQLITE_ROW) : (rc = c.sqlite3_step(stmt)) {
            const kn: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            const ktxt = c.sqlite3_column_text(stmt, 0) orelse continue;
            const key = try arena.dupe(u8, ktxt[0..kn]);
            const vn: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
            const vptr = c.sqlite3_column_blob(stmt, 1);
            const vbytes = if (vptr) |p| @as([*]const u8, @ptrCast(p))[0..vn] else &[_]u8{};
            try obj.put(arena, key, try decodeRecord(arena, vbytes));
        }
        if (rc != c.SQLITE_DONE) return Error.BackendError;
        // Drop-in compatibility: a Moonraker `moonraker-sql.db` keeps job history
        // in the dedicated `job_history`/`job_totals` tables. History adds every
        // table job whose id has no KV record (KV wins); totals come from the
        // table until phobos saves its own.
        if (std.mem.eql(u8, namespace, "history")) try self.mergeHistoryTable(arena, &obj);
        if (obj.count() == 0 and std.mem.eql(u8, namespace, "history_totals")) return self.totalsFromTable(arena);
        return .{ .object = obj };
    }

    /// True when the database has a table named `name`. Distinguishes a fresh
    /// phobos database from a failing read of a migrated Moonraker table.
    fn hasTable(self: *SqliteStore, name: []const u8) Error!bool {
        const stmt = try self.prepare("SELECT 1 FROM sqlite_schema WHERE type='table' AND name=?1");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, name);
        return switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => Error.BackendError,
        };
    }

    /// Add each Moonraker `job_history` row to `obj` in the `{job_id: job}`
    /// shape phobos's history component expects, unless `obj` already holds
    /// that id.
    fn mergeHistoryTable(self: *SqliteStore, arena: std.mem.Allocator, obj: *json.ObjectMap) Error!void {
        if (!try self.hasTable("job_history")) return;
        const stmt = try self.prepare(job_history_select);
        defer _ = c.sqlite3_finalize(stmt);
        var rc = c.sqlite3_step(stmt);
        while (rc == c.SQLITE_ROW) : (rc = c.sqlite3_step(stmt)) {
            const row = (try mapJobRow(arena, stmt)) orelse continue;
            const gop = try obj.getOrPut(arena, row.key);
            if (!gop.found_existing) gop.value_ptr.* = row.value;
        }
        if (rc != c.SQLITE_DONE) return Error.BackendError;
    }

    /// Read a single job from Moonraker's `job_history` table by its hex
    /// `job_key` (phobos's 6-hex job id), using the table's PRIMARY KEY for an
    /// indexed lookup. Returns null if the table is absent, the key is not a
    /// hex job id, or no such job exists.
    fn historyJobFromTable(self: *SqliteStore, arena: std.mem.Allocator, job_key: []const u8) Error!?json.Value {
        const jid = jobRowId(job_key) orelse return null;
        if (!try self.hasTable("job_history")) return null;
        const stmt = try self.prepare(job_history_select ++ " WHERE job_id=?1");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, jid) != c.SQLITE_OK) return Error.BackendError;
        return switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => if (try mapJobRow(arena, stmt)) |row| row.value else null,
            c.SQLITE_DONE => null,
            else => Error.BackendError,
        };
    }

    /// Delete one `job_history` row, returning the job it held; null when the
    /// table or row is absent.
    fn deleteHistoryRow(self: *SqliteStore, arena: std.mem.Allocator, job_key: []const u8) Error!?json.Value {
        const job = (try self.historyJobFromTable(arena, job_key)) orelse return null;
        const stmt = try self.prepare("DELETE FROM job_history WHERE job_id=?1");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, jobRowId(job_key).?) != c.SQLITE_OK) return Error.BackendError;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.BackendError;
        return job;
    }

    /// Read Moonraker's `job_totals` table (provider `history`) into the
    /// `{totals: {job_totals, auxiliary_totals}}` shape phobos expects.
    fn totalsFromTable(self: *SqliteStore, arena: std.mem.Allocator) Error!json.Value {
        if (!try self.hasTable("job_totals")) return .{ .object = .empty };
        var jt: json.ObjectMap = .empty;
        const stmt = try self.prepare("SELECT field, maximum, total FROM job_totals WHERE provider='history'");
        defer _ = c.sqlite3_finalize(stmt);
        var rc = c.sqlite3_step(stmt);
        while (rc == c.SQLITE_ROW) : (rc = c.sqlite3_step(stmt)) {
            const field = colTextRaw(stmt, 0) orelse continue;
            // longest_* track a maximum; the rest are running totals.
            const is_max = std.mem.startsWith(u8, field, "longest");
            const v = if (is_max) c.sqlite3_column_double(stmt, 1) else c.sqlite3_column_double(stmt, 2);
            try jt.put(arena, try arena.dupe(u8, field), .{ .float = v });
        }
        if (rc != c.SQLITE_DONE) return Error.BackendError;
        if (jt.count() == 0) return .{ .object = .empty };
        // phobos stores the `totals` key as the FLAT job_totals fields;
        // handleTotals wraps them under "job_totals" itself.
        var top: json.ObjectMap = .empty;
        try top.put(arena, "totals", .{ .object = jt });
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

// --- Moonraker job_history table mapping ------------------------------------

/// Column order is fixed: `mapJobRow` reads by index.
const job_history_select = "SELECT job_id, user, filename, status, start_time, end_time, print_duration, total_duration, filament_used, metadata, auxiliary_data FROM job_history";

/// `job_history.job_id` for a hex job key. A sign or a value above the
/// INTEGER range names no row.
fn jobRowId(job_key: []const u8) ?i64 {
    return std.fmt.parseUnsigned(u63, job_key, 16) catch null;
}

/// Column text duped into `arena` ("" if NULL).
fn colText(arena: std.mem.Allocator, stmt: *c.sqlite3_stmt, idx: c_int) Error![]const u8 {
    const n: usize = @intCast(c.sqlite3_column_bytes(stmt, idx));
    const t = c.sqlite3_column_text(stmt, idx) orelse return "";
    return arena.dupe(u8, t[0..n]);
}
/// Column text as a transient slice into SQLite memory (valid until next step).
fn colTextRaw(stmt: *c.sqlite3_stmt, idx: c_int) ?[]const u8 {
    const n: usize = @intCast(c.sqlite3_column_bytes(stmt, idx));
    const t = c.sqlite3_column_text(stmt, idx) orelse return null;
    return t[0..n];
}
/// Parse a JSON-text column into a Value, or `default` if NULL/empty/invalid.
fn colJson(arena: std.mem.Allocator, stmt: *c.sqlite3_stmt, idx: c_int, default: json.Value) Error!json.Value {
    const t = c.sqlite3_column_text(stmt, idx) orelse return default;
    const n: usize = @intCast(c.sqlite3_column_bytes(stmt, idx));
    if (n == 0) return default;
    return json.parseFromSliceLeaky(json.Value, arena, t[0..n], .{}) catch |err| switch (err) {
        error.OutOfMemory => Error.OutOfMemory,
        else => default,
    };
}

/// A `job_history` row mapped to phobos's `{job_id: job}` shape. `key` (the
/// 6-hex job id) is shared with the job object's `job_id` field — both borrow
/// the same arena-owned string.
const MappedJob = struct { key: []const u8, value: json.Value };

/// Map the current `job_history_select` row into a job object. A negative
/// job_id has no phobos key and maps to null.
fn mapJobRow(arena: std.mem.Allocator, stmt: *c.sqlite3_stmt) Error!?MappedJob {
    // Unsigned 6-hex like phobos's own keys; signed formatting would emit a sign.
    const jid = std.math.cast(u64, c.sqlite3_column_int64(stmt, 0)) orelse return null;
    var job: json.ObjectMap = .empty;
    try job.put(arena, "filename", .{ .string = try colText(arena, stmt, 2) });
    try job.put(arena, "status", .{ .string = try colText(arena, stmt, 3) });
    try job.put(arena, "user", .{ .string = try colText(arena, stmt, 1) });
    try job.put(arena, "start_time", .{ .float = c.sqlite3_column_double(stmt, 4) });
    try job.put(arena, "end_time", .{ .float = c.sqlite3_column_double(stmt, 5) });
    try job.put(arena, "print_duration", .{ .float = c.sqlite3_column_double(stmt, 6) });
    try job.put(arena, "total_duration", .{ .float = c.sqlite3_column_double(stmt, 7) });
    try job.put(arena, "filament_used", .{ .float = c.sqlite3_column_double(stmt, 8) });
    try job.put(arena, "metadata", try colJson(arena, stmt, 9, .{ .object = .empty }));
    try job.put(arena, "auxiliary_data", try colJson(arena, stmt, 10, .{ .array = .init(arena) }));
    const key = try std.fmt.allocPrint(arena, "{X:0>6}", .{jid});
    try job.put(arena, "job_id", .{ .string = key });
    return .{ .key = key, .value = .{ .object = job } };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "SqliteStore.open rejects embedded NUL before creating database parents" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&buf, "{s}/new-parent/db\x00ignored", .{root}, 0);
    if (SqliteStore.open(testing.io, path)) |opened| {
        var store = opened;
        store.deinit();
        return error.TestUnexpectedSuccess;
    } else |err| try testing.expectEqual(Error.BackendError, err);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "new-parent", .{}));
}

test "fuzz SqliteStore.open rejects every embedded NUL position" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
            defer testing.allocator.free(root);
            var name: [12]u8 = undefined;
            smith.bytesWithHash(&name, 0);
            for (&name) |*byte| byte.* = 'a' + byte.* % 26;
            name[smith.valueRangeAtMostWithHash(u8, 0, name.len - 1, 1)] = 0;
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const path = try std.fmt.bufPrintSentinel(&buf, "{s}/new-parent/{s}", .{ root, name }, 0);
            try testing.expectError(Error.BackendError, SqliteStore.open(testing.io, path));
            try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "new-parent", .{}));
        }
    }.run, .{});
}

test "SqliteStore.open creates missing database parents" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/missing/database/moonraker-sql.db", .{root}, 0);
    var db = try SqliteStore.open(testing.io, path);
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try db.insertItem(a, "test", "value", .{ .integer = 42 });
    const value = (try db.getItem(a, "test", "value")).?;
    try testing.expectEqual(@as(i64, 42), value.integer);
    var again = try SqliteStore.open(testing.io, path);
    defer again.deinit();
    try testing.expectEqual(@as(i64, 42), (try again.getItem(a, "test", "value")).?.integer);
}

test "fuzz SqliteStore.open creates bounded nested paths" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
            defer testing.allocator.free(root);
            var name: [12]u8 = undefined;
            smith.bytesWithHash(&name, 0);
            for (&name) |*ch| ch.* = 'a' + ch.* % 26;
            var path_buf: [512]u8 = undefined;
            const path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}/database/db.sqlite", .{ root, name }, 0);
            var db = try SqliteStore.open(testing.io, path);
            defer db.deinit();
            var file = try std.Io.Dir.cwd().openFile(io, path, .{});
            file.close(io);
        }
    }.run, .{});
}

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
    // Moonraker decode_record raises on an unknown format byte.
    try testing.expectError(Error.BackendError, SqliteStore.decodeRecord(a, "zzz"));
}

test "SqliteStore: binding errors propagate before executing a query" {
    var s = try SqliteStore.open(testing.io, ":memory:");
    defer s.deinit();
    const stmt = try s.prepare("SELECT ?1");
    defer _ = c.sqlite3_finalize(stmt);
    try testing.expectError(Error.BackendError, SqliteStore.bindText(stmt, 2, "outside parameter range"));
    try SqliteStore.bindText(stmt, 1, "value");
    try testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    try testing.expectEqualStrings("value", colTextRaw(stmt, 0).?);
}

test "SqliteStore: malformed scalar records are backend errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = [_][]const u8{
        "", "?", "?\x00\x01", "q", "d", "q\x00\x00\x00\x00\x00\x00\x00\x00\x00", "d\x00\x00\x00\x00\x00\x00\x00\x00\x00", "s\xff",
    };
    for (bad) |bytes| try testing.expectError(Error.BackendError, SqliteStore.decodeRecord(a, bytes));
    try testing.expectEqualStrings("", (try SqliteStore.decodeRecord(a, "s")).string);
    try testing.expectEqualStrings("é", (try SqliteStore.decodeRecord(a, "sé")).string);
}

test "fuzz SqliteStore: scalar encoding round-trips values" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var bytes: [32]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const integer = std.mem.readInt(i64, bytes[0..8], .little);
            const floating: f64 = @floatFromInt(integer);
            var text: [32]u8 = undefined;
            for (&text, bytes) |*out, byte| out.* = 'a' + byte % 26;
            const cases = [_]json.Value{ .null, .{ .bool = bytes[0] & 1 != 0 }, .{ .integer = integer }, .{ .float = floating }, .{ .string = &text } };
            for (cases) |value| {
                const decoded = try SqliteStore.decodeRecord(a, try SqliteStore.encodeRecord(a, value));
                try testing.expectEqualDeep(value, decoded);
            }
        }
    }.run, .{});
}

/// Moonraker's `job_history` schema with rows 1, 2 and a foreign negative id.
fn createJobHistory(s: *SqliteStore) !void {
    try s.execSql(
        \\CREATE TABLE job_history (job_id INTEGER PRIMARY KEY ASC, user TEXT NOT NULL,
        \\ filename TEXT, status TEXT NOT NULL, start_time REAL NOT NULL, end_time REAL,
        \\ print_duration REAL NOT NULL, total_duration REAL NOT NULL, filament_used REAL NOT NULL,
        \\ metadata pyjson, auxiliary_data pyjson NOT NULL, instance_id TEXT NOT NULL);
        \\INSERT INTO job_history VALUES
        \\ (1,'me','a.gcode','completed',100.0,200.0,90.0,100.0,42.5,'{"layers":3}','[]','default'),
        \\ (2,'me','b.gcode','cancelled',300.0,350.0,40.0,50.0,10.0,NULL,'[]','default'),
        \\ (-5,'me','c.gcode','completed',1.0,2.0,1.0,1.0,0.0,NULL,'[]','default');
    );
}

test "SqliteStore: migrated job_history stays visible beside new KV jobs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try SqliteStore.open(testing.io, ":memory:");
    defer s.deinit();
    try createJobHistory(&s);

    // A job id above the INTEGER range or a negative row id names no job.
    try testing.expect((try s.getItem(a, "history", "FFFFFFFFFFFFFFFF")) == null);
    try testing.expectEqual(@as(usize, 2), (try s.getNamespace(a, "history")).object.count());

    // The first new phobos job must not hide the migrated rows; KV wins on a
    // shared id.
    try s.insertItem(a, "history", "000003", .{ .string = "new" });
    try s.insertItem(a, "history", "000001", .{ .string = "kv" });
    const merged = (try s.getNamespace(a, "history")).object;
    try testing.expectEqual(@as(usize, 3), merged.count());
    try testing.expectEqualStrings("kv", merged.get("000001").?.string);
    try testing.expectEqualStrings("b.gcode", merged.get("000002").?.object.get("filename").?.string);

    // Deleting a table-only job removes the row; deleting a shadowed job
    // removes both copies.
    const removed = try s.deleteItem(a, "history", "000002");
    try testing.expectEqualStrings("b.gcode", removed.object.get("filename").?.string);
    try testing.expectEqualStrings("kv", (try s.deleteItem(a, "history", "000001")).string);
    try testing.expect((try s.getItem(a, "history", "000001")) == null);
    try testing.expectError(Error.KeyNotFound, s.deleteItem(a, "history", "000002"));
    try testing.expectEqual(@as(usize, 1), (try s.getNamespace(a, "history")).object.count());
}

test "SqliteStore: an unreadable job_history table is an error, not an empty history" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try SqliteStore.open(testing.io, ":memory:");
    defer s.deinit();
    try testing.expectEqual(@as(usize, 0), (try s.getNamespace(a, "history")).object.count());
    try s.execSql("CREATE TABLE job_history (unrelated TEXT);");
    try testing.expectError(Error.BackendError, s.getNamespace(a, "history"));
    try testing.expectError(Error.BackendError, s.getItem(a, "history", "000001"));
}

test "SqliteStore: failed history deletion rolls back both persisted copies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try SqliteStore.open(testing.io, ":memory:");
    defer s.deinit();
    try createJobHistory(&s);
    try s.insertItem(a, "history", "000001", .{ .string = "shadow" });
    try s.execSql("CREATE TRIGGER prevent_delete BEFORE DELETE ON namespace_store BEGIN SELECT RAISE(ABORT,'record unavailable'); END;");
    try testing.expectError(Error.BackendError, s.deleteItem(a, "history", "000001"));
    try testing.expectEqualStrings("shadow", (try s.getItem(a, "history", "000001")).?.string);
    try testing.expectEqualStrings("a.gcode", (try s.historyJobFromTable(a, "000001")).?.object.get("filename").?.string);
    try s.execSql("DROP TRIGGER prevent_delete");
    _ = try s.deleteItem(a, "history", "000001");
    try testing.expect((try s.historyJobFromTable(a, "000001")) == null);
}

test "fuzz SqliteStore: history deletion commits or preserves both copies" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var s = try SqliteStore.open(testing.io, ":memory:");
            defer s.deinit();
            try createJobHistory(&s);
            var bytes: [8]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            try s.insertItem(a, "history", "000001", .{ .integer = std.mem.readInt(i64, &bytes, .little) });
            const fail = bytes[0] & 1 != 0;
            if (fail) try s.execSql("CREATE TRIGGER prevent_delete BEFORE DELETE ON namespace_store BEGIN SELECT RAISE(ABORT,'record unavailable'); END;");
            if (fail) {
                try testing.expectError(Error.BackendError, s.deleteItem(a, "history", "000001"));
            } else {
                _ = try s.deleteItem(a, "history", "000001");
            }
            try testing.expectEqual(fail, (try s.getItem(a, "history", "000001")) != null);
            try testing.expectEqual(fail, (try s.historyJobFromTable(a, "000001")) != null);
        }
    }.run, .{});
}

test "fuzz SqliteStore history keys: arbitrary job keys never panic" {
    var s = try SqliteStore.open(testing.io, ":memory:");
    defer s.deinit();
    try createJobHistory(&s);
    try testing.fuzz(&s, struct {
        fn run(store: *SqliteStore, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var kbuf: [20]u8 = undefined;
            const kn = smith.valueRangeAtMostWithHash(u32, 0, 20, 0);
            smith.bytesWithHash(kbuf[0..kn], 1);
            const key = kbuf[0..kn];
            if (jobRowId(key)) |id| try testing.expect(id >= 0);
            _ = store.getItem(a, "history", key) catch |err| switch (err) {
                Error.InvalidKey => {},
                else => return err,
            };
        }
    }.run, .{});
}

test "SqliteStore: insert/get/update/delete + persistence (in-file)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/moonraker-sql.db", .{root}, 0);
    {
        var s = try SqliteStore.open(testing.io, path);
        defer s.deinit();
        try s.insertItem(a, "moonraker", "file_manager.metadata_version", .{ .integer = 3 });
        try testing.expectEqual(@as(i64, 3), (try s.getItem(a, "moonraker", "file_manager.metadata_version")).?.integer);
        try s.updateItem(a, "moonraker", "file_manager.metadata_version", .{ .integer = 4 });
        try s.insertItem(a, "moonraker", "instance_id", .{ .string = "abc" });
    }
    {
        var s = try SqliteStore.open(testing.io, path);
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
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/moonraker-sql.db", .{root}, 0);
    var s = try SqliteStore.open(testing.io, path);
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
