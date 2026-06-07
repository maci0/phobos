//! Thin Zig bindings over the vendored liblmdb C API.
//!
//! We hand-declare the subset of the LMDB C ABI that the datastore needs
//! rather than relying on `@cImport`, which keeps the surface small and
//! documents exactly which symbols we depend on. The declarations mirror
//! `lmdb.h` from the vendored LMDB 0.9.31 (see `vendor/lmdb/`).
//!
//! Always compiled — phobos has no no-lmdb build mode.

const std = @import("std");

pub const MDB_env = opaque {};
pub const MDB_txn = opaque {};
pub const MDB_cursor = opaque {};
pub const MDB_dbi = c_uint;

/// Mirrors `MDB_val` — a sized, unowned byte span into LMDB memory.
pub const MDB_val = extern struct {
    mv_size: usize,
    mv_data: ?*anyopaque,
};

// --- Environment flags (subset) -------------------------------------------
pub const MDB_RDONLY: c_uint = 0x20000;
pub const MDB_NOSUBDIR: c_uint = 0x4000;
pub const MDB_NOTLS: c_uint = 0x200000;

// --- Database flags (subset) ----------------------------------------------
pub const MDB_CREATE: c_uint = 0x40000;

// --- Cursor ops (subset of MDB_cursor_op) ---------------------------------
pub const MDB_FIRST: c_uint = 0;
pub const MDB_NEXT: c_uint = 8;

// --- Reserved dbi handles -------------------------------------------------
/// FREE_DBI — the reserved free-list database (never holds user data).
pub const MDB_FREE_DBI: MDB_dbi = 0;
/// MAIN_DBI — the unnamed/main database. Its entries are the names of the
/// named sub-databases (one per Moonraker namespace).
pub const MDB_MAIN_DBI: MDB_dbi = 1;

// --- Return codes (subset) ------------------------------------------------
pub const MDB_SUCCESS: c_int = 0;
pub const MDB_NOTFOUND: c_int = -30798;

pub extern "c" fn mdb_version(major: ?*c_int, minor: ?*c_int, patch: ?*c_int) [*:0]const u8;
pub extern "c" fn mdb_strerror(err: c_int) [*:0]const u8;

pub extern "c" fn mdb_env_create(env: *?*MDB_env) c_int;
pub extern "c" fn mdb_env_open(env: *MDB_env, path: [*:0]const u8, flags: c_uint, mode: c_uint) c_int;
pub extern "c" fn mdb_env_set_maxdbs(env: *MDB_env, dbs: MDB_dbi) c_int;
pub extern "c" fn mdb_env_set_mapsize(env: *MDB_env, size: usize) c_int;
pub extern "c" fn mdb_env_close(env: *MDB_env) void;

pub extern "c" fn mdb_txn_begin(env: *MDB_env, parent: ?*MDB_txn, flags: c_uint, txn: *?*MDB_txn) c_int;
pub extern "c" fn mdb_txn_commit(txn: *MDB_txn) c_int;
pub extern "c" fn mdb_txn_abort(txn: *MDB_txn) void;

pub extern "c" fn mdb_dbi_open(txn: *MDB_txn, name: ?[*:0]const u8, flags: c_uint, dbi: *MDB_dbi) c_int;

pub extern "c" fn mdb_get(txn: *MDB_txn, dbi: MDB_dbi, key: *MDB_val, data: *MDB_val) c_int;
pub extern "c" fn mdb_put(txn: *MDB_txn, dbi: MDB_dbi, key: *MDB_val, data: *MDB_val, flags: c_uint) c_int;
pub extern "c" fn mdb_del(txn: *MDB_txn, dbi: MDB_dbi, key: *MDB_val, data: ?*MDB_val) c_int;

pub extern "c" fn mdb_cursor_open(txn: *MDB_txn, dbi: MDB_dbi, cursor: *?*MDB_cursor) c_int;
pub extern "c" fn mdb_cursor_get(cursor: *MDB_cursor, key: *MDB_val, data: *MDB_val, op: c_uint) c_int;
pub extern "c" fn mdb_cursor_close(cursor: *MDB_cursor) void;

/// Translate an LMDB return code into a human-readable string.
pub fn strerror(err: c_int) []const u8 {
    return std.mem.span(mdb_strerror(err));
}

/// Build an `MDB_val` view over a Zig byte slice. The slice must outlive any
/// LMDB call that reads it (e.g. for the duration of a write transaction).
pub fn val(bytes: []const u8) MDB_val {
    return .{
        .mv_size = bytes.len,
        .mv_data = @constCast(@ptrCast(bytes.ptr)),
    };
}

/// View the bytes of an `MDB_val` as a Zig slice. Empty/null data yields an
/// empty slice.
pub fn slice(v: MDB_val) []const u8 {
    if (v.mv_size == 0 or v.mv_data == null) return &[_]u8{};
    const p: [*]const u8 = @ptrCast(v.mv_data.?);
    return p[0..v.mv_size];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "mdb_version reports the vendored 0.9.31" {
    var maj: c_int = 0;
    var min: c_int = 0;
    var patch: c_int = 0;
    _ = mdb_version(&maj, &min, &patch);
    try std.testing.expectEqual(@as(c_int, 0), maj);
    try std.testing.expectEqual(@as(c_int, 9), min);
    try std.testing.expectEqual(@as(c_int, 31), patch);
}

test "strerror: success code has a message" {
    const msg = strerror(MDB_SUCCESS);
    try std.testing.expect(msg.len > 0);
}

test "val/slice round-trip" {
    const data = "hello world";
    const v = val(data);
    try std.testing.expectEqual(@as(usize, data.len), v.mv_size);
    try std.testing.expectEqualStrings(data, slice(v));
}

test "slice: empty val yields empty slice" {
    try std.testing.expectEqual(@as(usize, 0), slice(.{ .mv_size = 0, .mv_data = null }).len);
}

test "fuzz val/slice: arbitrary bytes round-trip exactly" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const n = @as(usize, buf[0]) % buf.len;
            const in = buf[0..n];
            const v = val(in);
            const out = slice(v);
            try std.testing.expectEqualSlices(u8, in, out);
        }
    }.run, .{});
}
