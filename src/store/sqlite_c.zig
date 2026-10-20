//! Minimal hand-declared bindings for the vendored SQLite amalgamation
//! (vendor/sqlite/sqlite3.c, 3.47.0). Only the symbols the DataStore backend
//! needs — hand-declared rather than `@cImport`, matching the codebase's C-binding
//! style and keep cross-compilation simple. Built with SQLITE_OMIT_AUTOINIT, so
//! `sqlite3_initialize` must be called once before use.

pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};

// Result codes.
pub const SQLITE_OK: c_int = 0;
pub const SQLITE_ROW: c_int = 100;
pub const SQLITE_DONE: c_int = 101;

// open flags.
pub const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
pub const SQLITE_OPEN_CREATE: c_int = 0x00000004;
pub const SQLITE_OPEN_FULLMUTEX: c_int = 0x00010000;

// Special destructor sentinel for bind_* (value must be copied). It is the C
// `(sqlite3_destructor_type)-1` sentinel — never actually called — typed as an
// opaque pointer (alignment 1) so the -1 address is valid on every target (a
// fn-pointer type would require an aligned address and fail to compile on ARM).
pub const SQLITE_TRANSIENT: ?*const anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

pub extern "c" fn sqlite3_initialize() c_int;
pub extern "c" fn sqlite3_open_v2(filename: [*:0]const u8, ppDb: *?*sqlite3, flags: c_int, zVfs: ?[*:0]const u8) c_int;
pub extern "c" fn sqlite3_close(db: ?*sqlite3) c_int;
pub extern "c" fn sqlite3_exec(db: ?*sqlite3, sql: [*:0]const u8, cb: ?*const anyopaque, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;

pub extern "c" fn sqlite3_prepare_v2(db: ?*sqlite3, zSql: [*]const u8, nByte: c_int, ppStmt: *?*sqlite3_stmt, pzTail: ?*?[*:0]const u8) c_int;
pub extern "c" fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;

pub extern "c" fn sqlite3_bind_text(stmt: ?*sqlite3_stmt, idx: c_int, text: [*]const u8, n: c_int, destructor: ?*const anyopaque) c_int;
pub extern "c" fn sqlite3_bind_blob(stmt: ?*sqlite3_stmt, idx: c_int, blob: ?*const anyopaque, n: c_int, destructor: ?*const anyopaque) c_int;
pub extern "c" fn sqlite3_bind_int64(stmt: ?*sqlite3_stmt, idx: c_int, value: i64) c_int;

pub extern "c" fn sqlite3_column_bytes(stmt: ?*sqlite3_stmt, iCol: c_int) c_int;
pub extern "c" fn sqlite3_column_blob(stmt: ?*sqlite3_stmt, iCol: c_int) ?*const anyopaque;
pub extern "c" fn sqlite3_column_text(stmt: ?*sqlite3_stmt, iCol: c_int) ?[*:0]const u8;
pub extern "c" fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, iCol: c_int) i64;
pub extern "c" fn sqlite3_column_double(stmt: ?*sqlite3_stmt, iCol: c_int) f64;
