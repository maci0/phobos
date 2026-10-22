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

    fn getStoredRecord(self: *SqliteStore, arena: std.mem.Allocator, namespace: []const u8, record_key: []const u8) Error!?json.Value {
        const stmt = try self.prepare("SELECT value FROM namespace_store WHERE namespace=?1 AND key=?2");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, namespace);
        try bindText(stmt, 2, record_key);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return Error.BackendError;
        const n: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        if (n == 0) return Error.BackendError;
        const ptr = c.sqlite3_column_blob(stmt, 0) orelse return Error.BackendError;
        const src = @as([*]const u8, @ptrCast(ptr))[0..n];
        // Value parsing owns its strings before finalize invalidates the column.
        return try decodeRecord(arena, src);
    }

    /// Load the same logical record for reads and mutations. A KV record
    /// shadows its migrated table row.
    fn getRecord(self: *SqliteStore, arena: std.mem.Allocator, namespace: []const u8, record_key: []const u8) Error!?json.Value {
        if (try self.getStoredRecord(arena, namespace, record_key)) |stored| return stored;
        if (std.mem.eql(u8, namespace, "history")) return self.historyJobFromTable(arena, record_key);
        if (std.mem.eql(u8, namespace, "history_totals")) {
            const totals = try self.totalsFromTable(arena);
            return totals.object.get(record_key);
        }
        return null;
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

    pub fn getItem(self: *SqliteStore, arena: std.mem.Allocator, namespace: [:0]const u8, key: anytype) Error!?json.Value {
        self.lockRmw();
        defer self.unlockRmw();
        const pk = try ds.parseKey(key);
        const segs = pk.slice();
        const record = (try self.getRecord(arena, namespace, segs[0])) orelse return null;
        return ds.getPath(record, segs[1..]) catch |e| switch (e) {
            ds.Error.KeyNotFound => null,
            else => |o| o,
        };
    }

    pub fn insertItem(self: *SqliteStore, arena: std.mem.Allocator, namespace: [:0]const u8, key: anytype, value: json.Value) Error!void {
        const pk = try ds.parseKey(key);
        const segs = pk.slice();
        self.lockRmw();
        defer self.unlockRmw();
        var record: json.Value = .null;
        if (segs.len > 1) record = (try self.getRecord(arena, namespace, segs[0])) orelse .{ .object = .empty };
        const new_record = try ds.insertPath(arena, record, segs[1..], value);
        try self.putRecordRaw(namespace, segs[0], try encodeRecord(arena, new_record));
    }

    pub fn updateItem(self: *SqliteStore, arena: std.mem.Allocator, namespace: [:0]const u8, key: anytype, value: json.Value) Error!void {
        const pk = try ds.parseKey(key);
        const segs = pk.slice();
        self.lockRmw();
        defer self.unlockRmw();
        const record = (try self.getRecord(arena, namespace, segs[0])) orelse return Error.KeyNotFound;
        const new_record = try ds.updatePath(arena, record, segs[1..], value);
        try self.putRecordRaw(namespace, segs[0], try encodeRecord(arena, new_record));
    }

    pub fn deleteItem(self: *SqliteStore, arena: std.mem.Allocator, namespace: [:0]const u8, key: anytype) Error!json.Value {
        const pk = try ds.parseKey(key);
        const segs = pk.slice();
        self.lockRmw();
        defer self.unlockRmw();
        const migrated_history = std.mem.eql(u8, namespace, "history") or std.mem.eql(u8, namespace, "history_totals");
        if (migrated_history) try self.execSql("BEGIN IMMEDIATE");
        errdefer if (migrated_history) self.execSql("ROLLBACK") catch |err|
            std.debug.print("phobos: warning: history deletion rollback failed: {}\n", .{err});
        const removed = try self.deleteRecord(arena, namespace, segs);
        if (migrated_history) try self.execSql("COMMIT");
        return removed;
    }

    fn deleteRecord(self: *SqliteStore, arena: std.mem.Allocator, namespace: [:0]const u8, segs: []const []const u8) Error!json.Value {
        const record = (try self.getRecord(arena, namespace, segs[0])) orelse return Error.KeyNotFound;
        const res = try ds.deletePath(record, segs[1..]);
        if (res.record) |new_record| {
            try self.putRecordRaw(namespace, segs[0], try encodeRecord(arena, new_record));
        } else {
            // Removing the last shadow field must not resurrect its table row.
            if (std.mem.eql(u8, namespace, "history")) try self.deleteHistoryRow(segs[0]);
            if (std.mem.eql(u8, namespace, "history_totals") and std.mem.eql(u8, segs[0], "totals") and try self.hasTable("job_totals"))
                try self.execSql("DELETE FROM job_totals WHERE provider='history'");
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
        if (std.mem.eql(u8, namespace, "history_totals")) {
            const totals = try self.totalsFromTable(arena);
            var it = totals.object.iterator();
            while (it.next()) |entry| {
                const gop = try obj.getOrPut(arena, entry.key_ptr.*);
                if (!gop.found_existing) gop.value_ptr.* = entry.value_ptr.*;
            }
        }
        return .{ .object = obj };
    }

    /// Select scalar IDs before decoding metadata. Noncanonical KV records use
    /// the namespace path so its key/type/error semantics stay unchanged.
    pub fn getHistoryPage(self: *SqliteStore, arena: std.mem.Allocator, page: ds.HistoryPage) Error!?[]ds.HistoryJob {
        self.lockRmw();
        defer self.unlockRmw();
        const Key = struct { id: u64, from_kv: bool = false };
        var keys: std.ArrayList(Key) = .empty;
        const kv = try self.prepare("SELECT key, value FROM namespace_store WHERE namespace='history'");
        defer _ = c.sqlite3_finalize(kv);
        var rc = c.sqlite3_step(kv);
        while (rc == c.SQLITE_ROW) : (rc = c.sqlite3_step(kv)) {
            const key = colTextRaw(kv, 0) orelse return null;
            const id = std.fmt.parseInt(u64, key, 16) catch return null;
            var canonical: [16]u8 = undefined;
            const formatted = std.fmt.bufPrint(&canonical, "{X:0>6}", .{id}) catch unreachable;
            if (!std.mem.eql(u8, key, formatted)) return null;
            const size: usize = @intCast(c.sqlite3_column_bytes(kv, 1));
            const ptr = c.sqlite3_column_blob(kv, 1) orelse return null;
            const bytes = @as([*]const u8, @ptrCast(ptr))[0..size];
            if (size == 0 or bytes[0] != '{' or !try json.validate(arena, bytes)) return null;
            try keys.append(arena, .{ .id = id, .from_kv = true });
        }
        if (rc != c.SQLITE_DONE) return Error.BackendError;
        const has_history_table = try self.hasTable("job_history");
        if (has_history_table and keys.items.len == 0) {
            const rows = try self.prepare(if (page.ascending)
                job_history_select ++ " WHERE job_id >= 0 ORDER BY job_id ASC LIMIT ?1 OFFSET ?2"
            else
                job_history_select ++ " WHERE job_id >= 0 ORDER BY job_id DESC LIMIT ?1 OFFSET ?2");
            defer _ = c.sqlite3_finalize(rows);
            if (c.sqlite3_bind_int64(rows, 1, if (page.limit > 0) page.limit else -1) != c.SQLITE_OK or
                c.sqlite3_bind_int64(rows, 2, if (page.limit > 0) @max(0, page.start) else 0) != c.SQLITE_OK) return Error.BackendError;
            var result: std.ArrayList(ds.HistoryJob) = .empty;
            rc = c.sqlite3_step(rows);
            while (rc == c.SQLITE_ROW) : (rc = c.sqlite3_step(rows)) {
                const row = (try mapJobRow(arena, rows)) orelse return Error.BackendError;
                try result.append(arena, .{ .key = row.key, .val = row.value });
            }
            if (rc != c.SQLITE_DONE) return Error.BackendError;
            return try result.toOwnedSlice(arena);
        }
        if (has_history_table) {
            const ids = try self.prepare(if (keys.items.len == 0)
                "SELECT job_id FROM job_history WHERE job_id >= 0"
            else
                "SELECT job_id FROM job_history WHERE job_id >= 0 AND NOT EXISTS " ++
                    "(SELECT 1 FROM namespace_store WHERE namespace='history' AND key=printf('%06llX',job_history.job_id))");
            defer _ = c.sqlite3_finalize(ids);
            rc = c.sqlite3_step(ids);
            while (rc == c.SQLITE_ROW) : (rc = c.sqlite3_step(ids)) {
                const id: u64 = @intCast(c.sqlite3_column_int64(ids, 0));
                try keys.append(arena, .{ .id = id });
            }
            if (rc != c.SQLITE_DONE) return Error.BackendError;
        }
        std.sort.pdq(Key, keys.items, page.ascending, struct {
            fn lessThan(ascending: bool, left: Key, right: Key) bool {
                return if (ascending) left.id < right.id else left.id > right.id;
            }
        }.lessThan);
        var selected = keys.items;
        if (page.limit > 0) {
            selected = selected[@min(std.math.lossyCast(usize, page.start), selected.len)..];
            selected = selected[0..@min(std.math.lossyCast(usize, page.limit), selected.len)];
        }
        const result = try arena.alloc(ds.HistoryJob, selected.len);
        var table_row: ?*c.sqlite3_stmt = null;
        defer if (table_row) |stmt| {
            _ = c.sqlite3_finalize(stmt);
        };
        for (selected, result) |entry, *job| {
            if (entry.from_kv) {
                const key = try arena.print("{X:0>6}", .{entry.id});
                job.* = .{ .key = key, .val = (try self.getRecord(arena, "history", key)) orelse return Error.BackendError };
            } else {
                if (table_row == null) table_row = try self.prepare(job_history_select ++ " WHERE job_id=?1");
                const stmt = table_row.?;
                if (c.sqlite3_reset(stmt) != c.SQLITE_OK) return Error.BackendError;
                if (c.sqlite3_bind_int64(stmt, 1, @intCast(entry.id)) != c.SQLITE_OK) return Error.BackendError;
                if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return Error.BackendError;
                const row = (try mapJobRow(arena, stmt)) orelse return Error.BackendError;
                job.* = .{ .key = row.key, .val = row.value };
            }
        }
        return result;
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

    /// Delete a backing history row, if one exists.
    fn deleteHistoryRow(self: *SqliteStore, job_key: []const u8) Error!void {
        const id = jobRowId(job_key) orelse return;
        if (!try self.hasTable("job_history")) return;
        const stmt = try self.prepare("DELETE FROM job_history WHERE job_id=?1");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, id) != c.SQLITE_OK) return Error.BackendError;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.BackendError;
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
        .getHistoryPage = vtGetHistoryPage,
    };

    fn vtGetItem(ctx: *anyopaque, arena: std.mem.Allocator, namespace: [:0]const u8, key: ds.Key) Error!?json.Value {
        return getItem(@ptrCast(@alignCast(ctx)), arena, namespace, key);
    }
    fn vtInsertItem(ctx: *anyopaque, arena: std.mem.Allocator, namespace: [:0]const u8, key: ds.Key, value: json.Value) Error!void {
        return insertItem(@ptrCast(@alignCast(ctx)), arena, namespace, key, value);
    }
    fn vtUpdateItem(ctx: *anyopaque, arena: std.mem.Allocator, namespace: [:0]const u8, key: ds.Key, value: json.Value) Error!void {
        return updateItem(@ptrCast(@alignCast(ctx)), arena, namespace, key, value);
    }
    fn vtDeleteItem(ctx: *anyopaque, arena: std.mem.Allocator, namespace: [:0]const u8, key: ds.Key) Error!json.Value {
        return deleteItem(@ptrCast(@alignCast(ctx)), arena, namespace, key);
    }
    fn vtListNamespaces(ctx: *anyopaque, arena: std.mem.Allocator) Error![][]const u8 {
        return listNamespaces(@ptrCast(@alignCast(ctx)), arena);
    }
    fn vtGetNamespace(ctx: *anyopaque, arena: std.mem.Allocator, namespace: [:0]const u8) Error!json.Value {
        return getNamespace(@ptrCast(@alignCast(ctx)), arena, namespace);
    }
    fn vtGetHistoryPage(ctx: *anyopaque, arena: std.mem.Allocator, page: ds.HistoryPage) Error!?[]ds.HistoryJob {
        return getHistoryPage(@ptrCast(@alignCast(ctx)), arena, page);
    }
};

// --- Moonraker job_history table mapping ------------------------------------

/// Column order is fixed: `mapJobRow` reads by index.
const job_history_select = "SELECT job_id, user, filename, status, start_time, end_time, print_duration, total_duration, filament_used, metadata, auxiliary_data FROM job_history";
const job_history_field_count = 11;

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
    try job.ensureTotalCapacity(arena, job_history_field_count);
    job.putAssumeCapacity("filename", .{ .string = try colText(arena, stmt, 2) });
    job.putAssumeCapacity("status", .{ .string = try colText(arena, stmt, 3) });
    job.putAssumeCapacity("user", .{ .string = try colText(arena, stmt, 1) });
    job.putAssumeCapacity("start_time", .{ .float = c.sqlite3_column_double(stmt, 4) });
    job.putAssumeCapacity("end_time", if (c.sqlite3_column_type(stmt, 5) == c.SQLITE_NULL) .null else .{ .float = c.sqlite3_column_double(stmt, 5) });
    job.putAssumeCapacity("print_duration", .{ .float = c.sqlite3_column_double(stmt, 6) });
    job.putAssumeCapacity("total_duration", .{ .float = c.sqlite3_column_double(stmt, 7) });
    job.putAssumeCapacity("filament_used", .{ .float = c.sqlite3_column_double(stmt, 8) });
    job.putAssumeCapacity("metadata", try colJson(arena, stmt, 9, .{ .object = .empty }));
    job.putAssumeCapacity("auxiliary_data", try colJson(arena, stmt, 10, .{ .array = .init(arena) }));
    const key = try std.fmt.allocPrint(arena, "{X:0>6}", .{jid});
    job.putAssumeCapacity("job_id", .{ .string = key });
    return .{ .key = key, .value = .{ .object = job } };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "SqliteStore links the pinned SQLite version and source revision" {
    var store = try SqliteStore.open(testing.io, ":memory:");
    defer store.deinit();
    var stmt: ?*c.sqlite3_stmt = null;
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(store.db, "SELECT sqlite_version(), sqlite_source_id()", -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt.?);
    try testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt.?));
    try testing.expectEqualStrings("3.54.1", std.mem.span(c.sqlite3_column_text(stmt.?, 0).?));
    try testing.expectEqualStrings("2026-10-16 14:45:20 555e07ef33f69a0957d24d8e555b702464a131d6f1607f4c3c1e4551e8e6ca76", std.mem.span(c.sqlite3_column_text(stmt.?, 1).?));
}

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

test "SqliteStore history pages preserve namespace ordering overrides and filters" {
    const HistoryCtx = @import("../components/history.zig").HistoryCtx;
    const history = @import("../components/history.zig");
    var s = try SqliteStore.open(testing.io, ":memory:");
    defer s.deinit();
    try createJobHistory(&s);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try json.parseFromSliceLeaky(json.Value, a, "{\"filename\":\"override.gcode\",\"metadata\":{},\"start_time\":250,\"end_time\":300}", .{});
    var bus: @import("../server/notify.zig").NotifyBus = undefined;
    var ctx: HistoryCtx = .{ .clock_io = testing.io, .store = s.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };
    var fallback_vtable = SqliteStore.vtable;
    fallback_vtable.getHistoryPage = null;
    var fallback = ctx;
    fallback.store.vtable = &fallback_vtable;
    for (0..2) |phase| {
        if (phase == 1) {
            try s.insertItem(a, "history", "000001", value);
            try s.insertItem(a, "history", "000003", value);
        }
        for ([_][]const u8{
            "{}",                                          "{\"limit\":1,\"order\":\"asc\"}", "{\"limit\":1,\"start\":1}",
            "{\"limit\":1,\"start\":-20}",                 "{\"limit\":0,\"start\":1}",       "{\"limit\":-1,\"start\":1}",
            "{\"since\":100}",                             "{\"before\":350}",                "{\"since\":0,\"before\":400,\"order\":\"asc\"}",
            "{\"limit\":1,\"start\":9223372036854775807}",
        }) |input| {
            const params = try json.parseFromSliceLeaky(json.Value, a, input, .{});
            const expected = try history.handleList(&fallback, params, a);
            const actual = try history.handleList(&ctx, params, a);
            try testing.expectEqualStrings(try json.Stringify.valueAlloc(a, expected, .{}), try json.Stringify.valueAlloc(a, actual, .{}));
        }
    }
    try s.insertItem(a, "history", "3", value);
    try testing.expect((try s.getHistoryPage(a, .{ .limit = 20, .start = 0, .ascending = false })) == null);
    try testing.expectEqualStrings(try json.Stringify.valueAlloc(a, try history.handleList(&fallback, .null, a), .{}), try json.Stringify.valueAlloc(a, try history.handleList(&ctx, .null, a), .{}));
    _ = try s.deleteItem(a, "history", "3");
    try s.insertItem(a, "history", "000004", .null);
    try testing.expect((try s.getHistoryPage(a, .{ .limit = 20, .start = 0, .ascending = false })) == null);
    try testing.expectEqualStrings(try json.Stringify.valueAlloc(a, try history.handleList(&fallback, .null, a), .{}), try json.Stringify.valueAlloc(a, try history.handleList(&ctx, .null, a), .{}));
    try s.execSql("INSERT INTO namespace_store VALUES ('history','000005',x'7b00');");
    try testing.expectError(Error.BackendError, history.handleList(&ctx, .null, a));
}

test "SqliteStore migrated history pages allocate only selected jobs" {
    var s = try SqliteStore.open(testing.io, ":memory:");
    defer s.deinit();
    try createJobHistory(&s);
    try s.execSql(
        \\DELETE FROM job_history;
        \\WITH RECURSIVE ids(id) AS (SELECT 1 UNION ALL SELECT id+1 FROM ids WHERE id<10000)
        \\INSERT INTO job_history SELECT id,'me','fixture.gcode','completed',100.0,NULL,
        \\ 90.0,100.0,42.5,'{"layers":3}','[]','default' FROM ids;
    );
    var params_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer params_arena.deinit();
    const params = try json.parseFromSliceLeaky(json.Value, params_arena.allocator(), "{\"limit\":1}", .{});
    var tracked = testing.FailingAllocator.init(testing.allocator, .{});
    var request = std.heap.ArenaAllocator.init(tracked.allocator());
    defer request.deinit();
    const history = @import("../components/history.zig");
    var bus: @import("../server/notify.zig").NotifyBus = undefined;
    var ctx: history.HistoryCtx = .{ .clock_io = testing.io, .store = s.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };
    const result = try history.handleList(&ctx, params, request.allocator());
    try testing.expectEqual(@as(i64, 1), result.object.get("count").?.integer);
    const job = result.object.get("jobs").?.array.items[0];
    try testing.expectEqualStrings("002710", job.object.get("job_id").?.string);
    try testing.expectEqualStrings("fixture.gcode", job.object.get("filename").?.string);
    try testing.expect(job.object.get("end_time").? == .null);
    try testing.expect(tracked.allocated_bytes < 64 * 1024);
}

test "SqliteStore legacy history rows reserve their known fields" {
    var s = try SqliteStore.open(testing.io, ":memory:");
    defer s.deinit();
    try createJobHistory(&s);
    try s.execSql(
        \\DELETE FROM job_history;
        \\WITH RECURSIVE ids(id) AS (SELECT 1 UNION ALL SELECT id+1 FROM ids WHERE id<200)
        \\INSERT INTO job_history SELECT id,'me','fixture.gcode','completed',100.0,NULL,
        \\ 90.0,100.0,42.5,'{"payload":"kept"}','[]','default' FROM ids;
    );
    var tracked = testing.FailingAllocator.init(testing.allocator, .{});
    var response = std.heap.ArenaAllocator.init(tracked.allocator());
    defer response.deinit();
    const page = (try s.getHistoryPage(response.allocator(), .{ .limit = 0, .start = 0, .ascending = false })).?;
    try testing.expectEqual(@as(usize, 200), page.len);
    for (page, 0..) |job, index| {
        var key: [16]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&key, "{X:0>6}", .{200 - index}), job.key);
        try testing.expectEqual(@as(usize, 11), job.val.object.count());
        try testing.expectEqualStrings("fixture.gcode", job.val.object.get("filename").?.string);
        try testing.expectEqualStrings("kept", job.val.object.get("metadata").?.object.get("payload").?.string);
        try testing.expect(job.val.object.get("end_time").? == .null);
    }
    const retained = tracked.allocated_bytes - tracked.freed_bytes;
    std.debug.print("legacy history rows retained request storage: {d} bytes\n", .{retained});
    try testing.expect(retained < 768 * 1024);
}

test "SqliteStore history page key indexes retain scalar IDs" {
    var s = try SqliteStore.open(testing.io, ":memory:");
    defer s.deinit();
    var seed = std.heap.ArenaAllocator.init(testing.allocator);
    defer seed.deinit();
    const a = seed.allocator();
    for (1..1025) |id| {
        var buf: [16]u8 = undefined;
        try s.insertItem(a, "history", try std.fmt.bufPrint(&buf, "{X:0>6}", .{id}), .{ .object = .empty });
    }
    for ([_][]const u8{ "000000", "7FFFFFFFFFFFFFFF", "8000000000000000", "FFFFFFFFFFFFFFFF" }) |key|
        try s.insertItem(a, "history", key, .{ .object = .empty });
    var tracked = testing.FailingAllocator.init(testing.allocator, .{});
    var response = std.heap.ArenaAllocator.init(tracked.allocator());
    defer response.deinit();
    const page = (try s.getHistoryPage(response.allocator(), .{ .limit = 20, .start = 0, .ascending = false })).?;
    try testing.expectEqual(@as(usize, 20), page.len);
    try testing.expectEqualStrings("FFFFFFFFFFFFFFFF", page[0].key);
    try testing.expectEqualStrings("8000000000000000", page[1].key);
    try testing.expectEqualStrings("7FFFFFFFFFFFFFFF", page[2].key);
    try testing.expectEqualStrings("0003F0", page[19].key);
    const retained = tracked.allocated_bytes - tracked.freed_bytes;
    std.debug.print("history key index retained request storage: {d} bytes\n", .{retained});
    try testing.expect(retained < 64 * 1024);
    const first = (try s.getHistoryPage(a, .{ .limit = 1, .start = 0, .ascending = true })).?;
    try testing.expectEqualStrings("000000", first[0].key);
}

test "SqliteStore history overrides preserve full-width legacy IDs" {
    var s = try SqliteStore.open(testing.io, ":memory:");
    defer s.deinit();
    try createJobHistory(&s);
    try s.execSql(
        \\INSERT INTO job_history VALUES
        \\ (2147483648,'me','wide.gcode','completed',100.0,NULL,0.0,0.0,0.0,'{}','[]','default'),
        \\ (4294967296,'me','shadow.gcode','completed',100.0,NULL,0.0,0.0,0.0,'{}','[]','default'),
        \\ (9223372036854775807,'me','shadow.gcode','completed',100.0,NULL,0.0,0.0,0.0,'{}','[]','default');
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const job = try json.parseFromSliceLeaky(json.Value, a, "{\"filename\":\"override.gcode\"}", .{});
    for ([_][]const u8{ "100000000", "7FFFFFFFFFFFFFFF" }) |key|
        try s.insertItem(a, "history", key, job);
    const page = (try s.getHistoryPage(a, .{ .limit = 0, .start = 0, .ascending = false })).?;
    try testing.expectEqual(@as(usize, 5), page.len);
    for (page, [_][]const u8{ "7FFFFFFFFFFFFFFF", "100000000", "80000000", "000002", "000001" }) |row, key|
        try testing.expectEqualStrings(key, row.key);
    for (page[0..2]) |row|
        try testing.expectEqualStrings("override.gcode", row.val.object.get("filename").?.string);
    try testing.expectEqualStrings("wide.gcode", page[2].val.object.get("filename").?.string);
}

test "SqliteStore history pages own interleaved table and KV rows" {
    var s = try SqliteStore.open(testing.io, ":memory:");
    defer s.deinit();
    try createJobHistory(&s);
    try s.execSql(
        \\UPDATE job_history SET metadata='{"payload":"second"}' WHERE job_id=2;
        \\INSERT INTO job_history VALUES
        \\ (3,'me','shadow.gcode','completed',400.0,NULL,0.0,0.0,0.0,'{}','[]','default'),
        \\ (4,'me','fourth.gcode','completed',500.0,NULL,0.0,0.0,0.0,'{"payload":"fourth"}','[]','default');
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stored = try json.parseFromSliceLeaky(json.Value, a, "{\"filename\":\"kv.gcode\",\"metadata\":{\"payload\":\"kv\"}}", .{});
    try s.insertItem(a, "history", "000001", stored);
    try s.insertItem(a, "history", "000003", stored);
    const page = (try s.getHistoryPage(a, .{ .limit = 4, .start = 0, .ascending = true })).?;
    try testing.expectEqual(@as(usize, 4), page.len);
    try s.execSql("UPDATE job_history SET filename='replaced',metadata='{}'; DELETE FROM namespace_store WHERE namespace='history';");
    for (page, [_][]const u8{ "000001", "000002", "000003", "000004" }, [_][]const u8{ "kv", "second", "kv", "fourth" }) |job, key, payload| {
        try testing.expectEqualStrings(key, job.key);
        try testing.expectEqualStrings(payload, job.val.object.get("metadata").?.object.get("payload").?.string);
    }
    try testing.expectEqualStrings("fourth.gcode", page[3].val.object.get("filename").?.string);
    try testing.expect(page[3].val.object.get("end_time").? == .null);
}

test "SqliteStore history preserves nullable end times" {
    var s = try SqliteStore.open(testing.io, ":memory:");
    defer s.deinit();
    try createJobHistory(&s);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bus: @import("../server/notify.zig").NotifyBus = undefined;
    var ctx: @import("../components/history.zig").HistoryCtx = .{ .clock_io = testing.io, .store = s.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };
    const before = try json.parseFromSliceLeaky(json.Value, a, "{\"before\":350,\"limit\":0}", .{});
    for ([_]struct { sql: []const u8, expected: json.Value }{
        .{ .sql = "NULL", .expected = .null },
        .{ .sql = "0.0", .expected = .{ .float = 0 } },
        .{ .sql = "350.25", .expected = .{ .float = 350.25 } },
    }) |case| {
        try s.execSql(try std.fmt.allocPrintSentinel(a, "UPDATE job_history SET end_time={s} WHERE job_id=2", .{case.sql}, 0));
        const direct = (try s.getItem(a, "history", "000002")).?.object.get("end_time").?;
        const namespace = (try s.getNamespace(a, "history")).object.get("000002").?.object.get("end_time").?;
        const page = (try s.getHistoryPage(a, .{ .limit = 1, .start = 0, .ascending = false })).?[0].val.object.get("end_time").?;
        for ([_]json.Value{ direct, namespace, page }) |actual| {
            try testing.expectEqualStrings(try json.Stringify.valueAlloc(a, case.expected, .{}), try json.Stringify.valueAlloc(a, actual, .{}));
        }
        const filtered = try @import("../components/history.zig").handleList(&ctx, before, a);
        try testing.expectEqual(@as(i64, if (std.mem.eql(u8, case.sql, "0.0")) 2 else 1), filtered.object.get("count").?.integer);
    }
}

test "SqliteStore history pages release every partial request allocation" {
    var s = try SqliteStore.open(testing.io, ":memory:");
    defer s.deinit();
    try createJobHistory(&s);
    for (0..2) |phase| {
        if (phase == 1) try s.execSql("INSERT INTO namespace_store VALUES ('history','000003',x'7b226d65746164617461223a7b226c6179657273223a32307d7d');");
        var no_resize = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
        try testing.checkAllAllocationFailures(no_resize.allocator(), struct {
            fn run(alloc: std.mem.Allocator, store: *SqliteStore) !void {
                var arena = std.heap.ArenaAllocator.init(alloc);
                defer arena.deinit();
                const page = (try store.dataStore().getHistoryPage(arena.allocator(), .{ .limit = 2, .start = 0, .ascending = true })).?;
                try testing.expectEqual(@as(usize, 2), page.len);
                try testing.expectEqualStrings("000001", page[0].key);
                try testing.expectEqualStrings("000002", page[1].key);
            }
        }.run, .{&s});
    }
}

test "fuzz SqliteStore history pages match namespace pagination" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var bits: [8]u8 = undefined;
            smith.bytesWithHash(&bits, 0);
            var s = try SqliteStore.open(testing.io, ":memory:");
            defer s.deinit();
            try createJobHistory(&s);
            try s.execSql(
                \\INSERT INTO job_history VALUES
                \\ (4,'me','four.gcode','completed',400.0,500.0,0.0,0.0,0.0,'{"name":"four"}','[]','default'),
                \\ (5,'me','five.gcode','completed',500.0,NULL,0.0,0.0,0.0,'{"name":"five"}','[]','default');
            );
            try s.execSql("INSERT INTO job_history SELECT 9223372036854775807,user,filename,status,start_time,end_time,print_duration,total_duration,filament_used,metadata,auxiliary_data,instance_id FROM job_history WHERE job_id=1;");
            if (bits[5] & 1 != 0) try s.execSql("UPDATE job_history SET end_time=NULL WHERE job_id=2");
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            if (bits[5] & 1 != 0) try testing.expect((try s.getItem(a, "history", "000002")).?.object.get("end_time").? == .null);
            const job = try json.parseFromSliceLeaky(json.Value, a, "{\"filename\":\"new.gcode\",\"metadata\":{\"layers\":20}}", .{});
            if (bits[7] & 1 != 0) try s.insertItem(a, "history", "FFFFFFFFFFFFFFFF", job);
            if (bits[7] & 2 != 0) try s.insertItem(a, "history", "7FFFFFFFFFFFFFFF", job);
            if (bits[0] & 1 != 0) try s.insertItem(a, "history", "000001", job);
            if (bits[7] & 4 != 0) try s.insertItem(a, "history", if (bits[0] & 2 != 0) "000003" else "3", if (bits[0] & 4 != 0) job else .null);
            var params: json.ObjectMap = .empty;
            try params.put(a, "limit", .{ .integer = @as(i64, bits[1] % 7) - 2 });
            try params.put(a, "start", .{ .integer = @as(i64, bits[2] % 7) - 2 });
            try params.put(a, "order", .{ .string = if (bits[3] & 1 == 0) "asc" else "desc" });
            if (bits[4] & 1 != 0) try params.put(a, "since", .{ .integer = bits[5] });
            if (bits[6] & 1 != 0) try params.put(a, "before", .{ .integer = 400 });
            const history = @import("../components/history.zig");
            var bus: @import("../server/notify.zig").NotifyBus = undefined;
            var ctx: history.HistoryCtx = .{ .clock_io = testing.io, .store = s.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };
            var fallback_vtable = SqliteStore.vtable;
            fallback_vtable.getHistoryPage = null;
            var fallback = ctx;
            fallback.store.vtable = &fallback_vtable;
            const expected = try history.handleList(&fallback, .{ .object = params }, a);
            const actual = try history.handleList(&ctx, .{ .object = params }, a);
            try testing.expectEqualStrings(try json.Stringify.valueAlloc(a, expected, .{}), try json.Stringify.valueAlloc(a, actual, .{}));
        }
    }.run, .{});
}

test "SqliteStore JSON reads own their bytes without a retained encoded copy" {
    var s = try SqliteStore.open(testing.io, ":memory:");
    defer s.deinit();
    var seed = std.heap.ArenaAllocator.init(testing.allocator);
    defer seed.deinit();
    const a = seed.allocator();
    var payload: [64 * 1024]u8 = undefined;
    @memset(&payload, 'x');
    var record: json.ObjectMap = .empty;
    try record.put(a, "payload", .{ .string = &payload });
    try s.insertItem(a, "test", "large", .{ .object = record });
    var tracked = testing.FailingAllocator.init(testing.allocator, .{});
    var request = std.heap.ArenaAllocator.init(tracked.allocator());
    defer request.deinit();
    const result = (try s.getItem(request.allocator(), "test", "large")).?;
    try s.insertItem(a, "test", "large", .{ .string = "replacement" });
    try testing.expectEqualStrings(&payload, result.object.get("payload").?.string);
    const retained = tracked.allocated_bytes - tracked.freed_bytes;
    std.debug.print("large database read retained request storage: {d} bytes\n", .{retained});
    try testing.expect(retained < 3 * payload.len);
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

test "SqliteStore: dotted mutations preserve migrated job records" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..3) |operation| {
        var s = try SqliteStore.open(testing.io, ":memory:");
        defer s.deinit();
        try createJobHistory(&s);
        switch (operation) {
            0 => try s.insertItem(a, "history", "000001.metadata.layers", .{ .integer = 8 }),
            1 => try s.updateItem(a, "history", "000001.metadata.layers", .{ .integer = 8 }),
            2 => try testing.expectEqual(@as(i64, 3), (try s.deleteItem(a, "history", "000001.metadata.layers")).integer),
            else => unreachable,
        }
        try testing.expectEqualStrings("a.gcode", (try s.getItem(a, "history", "000001.filename")).?.string);
        const layers = try s.getItem(a, "history", "000001.metadata.layers");
        if (operation == 2) try testing.expect(layers == null) else try testing.expectEqual(@as(i64, 8), layers.?.integer);
        try testing.expectEqual(@as(usize, 2), (try s.getNamespace(a, "history")).object.count());
    }
}

test "SqliteStore: deleting the last shadow field cannot restore its migrated row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try SqliteStore.open(testing.io, ":memory:");
    defer s.deinit();
    try createJobHistory(&s);
    var shadow: json.ObjectMap = .empty;
    try shadow.put(a, "only", .{ .integer = 7 });
    try s.insertItem(a, "history", "000001", .{ .object = shadow });
    try s.execSql("CREATE TRIGGER prevent_delete BEFORE DELETE ON namespace_store BEGIN SELECT RAISE(ABORT,'record unavailable'); END;");
    try testing.expectError(Error.BackendError, s.deleteItem(a, "history", "000001.only"));
    try testing.expectEqual(@as(i64, 7), (try s.getItem(a, "history", "000001.only")).?.integer);
    try testing.expect((try s.historyJobFromTable(a, "000001")) != null);
    try s.execSql("DROP TRIGGER prevent_delete");
    _ = try s.deleteItem(a, "history", "000001.only");
    try testing.expect((try s.getItem(a, "history", "000001")) == null);
    try testing.expect((try s.historyJobFromTable(a, "000001")) == null);
}

test "SqliteStore: migrated totals stay visible and mutations preserve other fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try SqliteStore.open(testing.io, ":memory:");
    defer s.deinit();
    try s.execSql(
        \\CREATE TABLE job_totals (provider TEXT, field TEXT, maximum REAL, total REAL);
        \\INSERT INTO job_totals VALUES ('history','total_jobs',NULL,9), ('history','total_time',NULL,10), ('other','reading',NULL,99);
    );
    try s.insertItem(a, "history_totals", "note", .{ .string = "keep" });
    const all = (try s.getNamespace(a, "history_totals")).object;
    try testing.expectEqual(@as(usize, 2), all.count());
    try testing.expectEqual(@as(f64, 10), all.get("totals").?.object.get("total_time").?.float);
    try s.insertItem(a, "history_totals", "totals.total_jobs", .{ .integer = 11 });
    try s.updateItem(a, "history_totals", "totals.total_time", .{ .integer = 20 });
    _ = try s.deleteItem(a, "history_totals", "totals.total_jobs");
    try testing.expect((try s.getItem(a, "history_totals", "totals.total_jobs")) == null);
    try testing.expectEqual(@as(i64, 20), (try s.getItem(a, "history_totals", "totals.total_time")).?.integer);
    try s.execSql("CREATE TRIGGER prevent_delete BEFORE DELETE ON namespace_store BEGIN SELECT RAISE(ABORT,'record unavailable'); END;");
    try testing.expectError(Error.BackendError, s.deleteItem(a, "history_totals", "totals.total_time"));
    try testing.expectEqual(@as(f64, 10), (try s.totalsFromTable(a)).object.get("totals").?.object.get("total_time").?.float);
    try s.execSql("DROP TRIGGER prevent_delete");
    _ = try s.deleteItem(a, "history_totals", "totals.total_time");
    try testing.expect((try s.getItem(a, "history_totals", "totals")) == null);
    const remaining = (try s.getNamespace(a, "history_totals")).object;
    try testing.expectEqual(@as(usize, 1), remaining.count());
    try testing.expectEqualStrings("keep", remaining.get("note").?.string);
    const stmt = try s.prepare("SELECT total FROM job_totals WHERE provider='other'");
    defer _ = c.sqlite3_finalize(stmt);
    try testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    try testing.expectEqual(@as(f64, 99), c.sqlite3_column_double(stmt, 0));
}

test "fuzz SqliteStore: migrated dotted mutations retain unrelated job fields" {
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
            const number = std.mem.readInt(i64, &bytes, .little);
            const operation = bytes[0] % 3;
            switch (operation) {
                0 => try s.insertItem(a, "history", "000001.metadata.layers", .{ .integer = number }),
                1 => try s.updateItem(a, "history", "000001.metadata.layers", .{ .integer = number }),
                2 => _ = try s.deleteItem(a, "history", "000001.metadata.layers"),
                else => unreachable,
            }
            try testing.expectEqualStrings("a.gcode", (try s.getItem(a, "history", "000001.filename")).?.string);
            const layers = try s.getItem(a, "history", "000001.metadata.layers");
            if (operation == 2) try testing.expect(layers == null) else try testing.expectEqual(number, layers.?.integer);
        }
    }.run, .{});
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
