//! server.files.* (file_manager) API component — Moonraker-compatible file
//! management endpoints.
//!
//! Mirrors the endpoints registered in
//! `vendor/moonraker/moonraker/components/file_manager/file_manager.py`:
//!
//!   GET    /server/files/roots      → server.files.roots
//!   GET    /server/files/list       → server.files.list
//!   GET    /server/files/metadata   → server.files.metadata
//!   POST   /server/files/metascan   → server.files.metascan
//!   GET    /server/files/thumbnails → server.files.thumbnails
//!   ALL    /server/files/directory  → server.files.get_directory/post_directory/delete_directory
//!   POST   /server/files/move       → server.files.move
//!   POST   /server/files/copy       → server.files.copy
//!   POST   /server/files/zip        → server.files.zip
//!   DELETE /server/files/delete_file→ server.files.delete_file (WS-only)
//!
//! Upload (POST /server/files/upload) and download
//! (GET /server/files/<root>/<path>) are wired in `http_transport.zig` because
//! they handle binary bodies / streamed responses outside the JSON handler path.
//!
//! Roots ("gcodes", "config", "logs", ...) come from the App datadir layout.
//! Each root has a name, an absolute filesystem path, and a read/write
//! permission ("rw" when full_access, otherwise "r").
//!
//! PATH SAFETY: `resolveRequestPath` is the single security-critical function.
//! It parses "<root>/<relative>", lexically normalizes the relative part
//! (collapsing "." and ".." without ever ascending above the root), and
//! produces an absolute path guaranteed to live inside the root directory. Any
//! attempt to escape (e.g. "gcodes/../../etc/passwd") is rejected with
//! `error.Forbidden`. The resolver is purely lexical — it never touches the
//! filesystem to decide containment — so it cannot be tricked by symlinks into
//! reporting a path as in-root.
//!
//! On every successful mutation the component emits `notify_filelist_changed`
//! through `bus.emit` with Moonraker's exact payload:
//!   params: [ { "action": "create_file"|"delete_file"|"create_dir"|
//!               "delete_dir"|"move_file"|"move_dir"|"modify_file",
//!              "item": { "path", "root", "size", "modified", "permissions" },
//!              "source_item"?: { "path", "root" } } ]
//!
//! Deep gcode-metadata parsing (slicer fields, thumbnails, layer heights) is
//! NOT performed here — phobos returns the stat-based record shape with the
//! Moonraker keys present (`size`, `modified`, `uuid`, `slicer`,
//! `print_start_time`, `job_id`, `filename`, `thumbnails`). See `buildMetadata`.
//!
//! All filesystem operations go through `std.Io.Dir` (Zig 0.16's Io-based fs
//! API), so the component needs a live `io`. It is stored in `FileCtx.io` and
//! supplied after the App event loop starts (via `setIo`); handlers return
//! `error.NotReady` if invoked before io is wired.

const std = @import("std");
const registry = @import("../server/registry.zig");
const notify = @import("../server/notify.zig");
const jv = @import("../json/value.zig");
const NotifyBus = @import("../server/notify.zig").NotifyBus;
const gcode_metadata = @import("gcode_metadata.zig");

const Registry = registry.Registry;
const Dir = std.Io.Dir;

// ---------------------------------------------------------------------------
// Roots
// ---------------------------------------------------------------------------

/// A configured file root: a named directory with read or read/write access.
pub const Root = struct {
    name: []const u8,
    /// Absolute, canonical path to the root directory.
    path: []const u8,
    /// True → "rw" permissions; false → "r" (read-only).
    full_access: bool,

    pub fn permissions(self: Root) []const u8 {
        return if (self.full_access) "rw" else "r";
    }
};

/// Valid gcode file extensions (mirrors VALID_GCODE_EXTS in file_manager.py).
pub const valid_gcode_exts = [_][]const u8{ ".gcode", ".g", ".gco", ".ufp", ".nc" };

fn isGcodeExt(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[dot..];
    var buf: [16]u8 = undefined;
    if (ext.len > buf.len) return false;
    const lower = std.ascii.lowerString(buf[0..ext.len], ext);
    for (valid_gcode_exts) |e| {
        if (std.mem.eql(u8, e, lower)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

/// Cached parsed gcode metadata, validated by (size, mtime). Each entry owns an
/// arena holding its deep-copied value, so eviction is a single arena.deinit().
const MetaEntry = struct {
    size: u64,
    mtime: f64,
    arena: std.heap.ArenaAllocator,
    value: std.json.Value,
};

/// Metadata cache cap. `server.files.metadata` re-reads up to 256 KiB + re-parses
/// the gcode header on every call; Mainsail/Fluidd request it for every file in a
/// listing, so on slow eMMC this is a real, repeated stall. Bounded; cleared
/// wholesale on overflow (simple, and the working set is small in practice).
const metadata_cache_cap = 256;

pub const FileCtx = struct {
    gpa: std.mem.Allocator,
    /// Configured roots. Borrowed; owned by the App.
    roots: []const Root,
    bus: ?*NotifyBus,
    /// Live io for filesystem operations + notification emission. Set after the
    /// event loop starts (via setIo). Handlers error with NotReady if absent.
    io: ?std.Io = null,
    /// Parsed-metadata cache keyed by absolute path (key owned by gpa).
    metadata_cache: std.StringHashMapUnmanaged(MetaEntry) = .empty,
    /// Guards metadata_cache. metadata runs under Core today, but lock anyway so
    /// the cache stays correct if it ever moves off-Core. No-op when io unset.
    metadata_cache_mutex: std.Io.Mutex = .init,

    pub fn setIo(self: *FileCtx, io: std.Io) void {
        self.io = io;
    }

    pub fn deinit(self: *FileCtx) void {
        var it = self.metadata_cache.iterator();
        while (it.next()) |e| {
            e.value_ptr.arena.deinit();
            self.gpa.free(e.key_ptr.*);
        }
        self.metadata_cache.deinit(self.gpa);
    }

    fn lockMeta(self: *FileCtx) void {
        if (self.io) |io| self.metadata_cache_mutex.lockUncancelable(io);
    }
    fn unlockMeta(self: *FileCtx) void {
        if (self.io) |io| self.metadata_cache_mutex.unlock(io);
    }

    /// Return a request-arena copy of the cached metadata for `abs` if present
    /// and still valid for (size, mtime); else null.
    fn cachedMetadata(self: *FileCtx, alloc: std.mem.Allocator, abs: []const u8, size: u64, mtime: f64) ?std.json.Value {
        self.lockMeta();
        defer self.unlockMeta();
        const e = self.metadata_cache.getPtr(abs) orelse return null;
        if (e.size != size or e.mtime != mtime) return null;
        return jv.deepCopy(alloc, e.value) catch null;
    }

    /// Store a cache copy of freshly-built metadata (deep-copied into a private
    /// arena). Replaces any prior entry for the path; clears the cache wholesale
    /// if it has grown past the cap.
    fn cacheMetadata(self: *FileCtx, abs: []const u8, size: u64, mtime: f64, value: std.json.Value) void {
        self.lockMeta();
        defer self.unlockMeta();
        // Build the new copy FIRST. Freeing the old entry's arena before the copy
        // succeeded would, on a deep-copy OOM, leave a stale map entry pointing at
        // freed memory → use-after-free on the next hit and a double-free at evict
        // /deinit. So everything below only frees the old arena once `copy` exists.
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        const copy = jv.deepCopy(arena.allocator(), value) catch {
            arena.deinit();
            return;
        };
        if (self.metadata_cache.getPtr(abs)) |slot| {
            // Replace: free the old arena only now that the new copy is in hand.
            slot.arena.deinit();
            slot.* = .{ .size = size, .mtime = mtime, .arena = arena, .value = copy };
            return;
        }
        if (self.metadata_cache.count() >= metadata_cache_cap) {
            var it = self.metadata_cache.iterator();
            while (it.next()) |e| {
                e.value_ptr.arena.deinit();
                self.gpa.free(e.key_ptr.*);
            }
            self.metadata_cache.clearRetainingCapacity();
        }
        const key = self.gpa.dupe(u8, abs) catch {
            arena.deinit();
            return;
        };
        self.metadata_cache.put(self.gpa, key, .{ .size = size, .mtime = mtime, .arena = arena, .value = copy }) catch {
            self.gpa.free(key);
            arena.deinit();
        };
    }

    pub fn findRoot(self: *const FileCtx, name: []const u8) ?Root {
        for (self.roots) |r| {
            if (std.mem.eql(u8, r.name, name)) return r;
        }
        return null;
    }

    fn requireIo(self: *const FileCtx) error{NotReady}!std.Io {
        return self.io orelse error.NotReady;
    }

    /// True if `rel` exists as a regular file under the named root. Used by
    /// job_queue to reject enqueuing/printing a missing file (Moonraker
    /// `check_file_exists`). False if io is absent or the path is invalid.
    pub fn fileExists(self: *const FileCtx, root_name: []const u8, rel: []const u8) bool {
        const io = self.io orelse return false;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const req = std.fmt.allocPrint(a, "{s}/{s}", .{ root_name, rel }) catch return false;
        const resolved = resolveRequestPath(self, a, req) catch return false;
        _ = Dir.cwd().statFile(io, resolved.abs, .{}) catch return false;
        return true;
    }

    /// Type-erased adapter: does "gcodes/<filename>" exist as a file?
    pub fn gcodeExistsErased(ctx: *anyopaque, filename: []const u8) bool {
        const self: *const FileCtx = @ptrCast(@alignCast(ctx));
        return self.fileExists("gcodes", filename);
    }
};

// ---------------------------------------------------------------------------
// Param helpers
// ---------------------------------------------------------------------------

fn getOptStr(params: std.json.Value, field: []const u8) ?[]const u8 {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return null;
            return switch (v) {
                .string => |s| s,
                else => null,
            };
        },
        else => return null,
    }
}

fn getStr(params: std.json.Value, field: []const u8) error{InvalidParams}![]const u8 {
    return getOptStr(params, field) orelse error.InvalidParams;
}

fn getStrDefault(params: std.json.Value, field: []const u8, default_val: []const u8) []const u8 {
    return getOptStr(params, field) orelse default_val;
}

fn getBool(params: std.json.Value, field: []const u8, default_val: bool) bool {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return default_val;
            return switch (v) {
                .bool => |b| b,
                .string => |s| std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1"),
                .integer => |i| i != 0,
                else => default_val,
            };
        },
        else => return default_val,
    }
}

// ---------------------------------------------------------------------------
// Path resolution (SECURITY CRITICAL)
// ---------------------------------------------------------------------------

pub const ResolveError = error{
    InvalidParams,
    Forbidden,
    OutOfMemory,
};

/// A resolved request path.
pub const Resolved = struct {
    root: Root,
    /// Relative path inside the root, normalized, no leading slash. "" for the
    /// root itself.
    rel: []const u8,
    /// Absolute path on disk (root.path joined with rel). Guaranteed to be
    /// inside root.path.
    abs: []const u8,
};

/// Lexically normalize a relative path: collapse "." and "" segments, resolve
/// ".." against the accumulated stack, and REJECT any ".." that would ascend
/// above the (virtual) root. Returns the normalized slash-joined relative path.
///
/// This never touches the filesystem; containment is decided purely from the
/// textual segments, so symlinks cannot be used to fool it.
pub fn normalizeRel(alloc: std.mem.Allocator, rel: []const u8) ResolveError![]const u8 {
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(alloc);

    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            // Escape attempt: cannot pop above the root.
            if (stack.items.len == 0) return error.Forbidden;
            _ = stack.pop();
            continue;
        }
        // Reject embedded NUL and other path tricks.
        if (std.mem.indexOfScalar(u8, seg, 0) != null) return error.Forbidden;
        try stack.append(alloc, seg);
    }

    if (stack.items.len == 0) return "";
    return std.mem.join(alloc, "/", stack.items);
}

/// Parse a request path of the form "<root>" or "<root>/<relative...>" into the
/// root, normalized relative path, and absolute on-disk path. Rejects unknown
/// roots and any path that escapes the root.
pub fn resolveRequestPath(
    ctx: *const FileCtx,
    alloc: std.mem.Allocator,
    request_path: []const u8,
) ResolveError!Resolved {
    // Strip leading/trailing slashes around the whole request.
    const trimmed = std.mem.trim(u8, request_path, "/");
    if (trimmed.len == 0) return error.InvalidParams;

    // Split into root segment + remainder.
    const slash = std.mem.indexOfScalar(u8, trimmed, '/');
    const root_name = if (slash) |s| trimmed[0..s] else trimmed;
    const remainder = if (slash) |s| trimmed[s + 1 ..] else "";

    const root = ctx.findRoot(root_name) orelse return error.InvalidParams;

    const rel = try normalizeRel(alloc, remainder);

    const abs = if (rel.len == 0)
        try alloc.dupe(u8, root.path)
    else
        try std.fs.path.join(alloc, &.{ root.path, rel });

    return .{ .root = root, .rel = rel, .abs = abs };
}

// ---------------------------------------------------------------------------
// stat helpers
// ---------------------------------------------------------------------------

/// mtime in fractional seconds (Moonraker reports st_mtime as a float).
fn mtimeSecs(st: std.Io.File.Stat) f64 {
    const ns: i128 = @intCast(st.mtime.nanoseconds);
    return @as(f64, @floatFromInt(ns)) / 1_000_000_000.0;
}

/// Build a `{ "modified", "size", "permissions" }` object for a path, matching
/// Moonraker's `get_path_info`. On stat failure returns the zeroed shape.
fn buildPathInfo(io: std.Io, alloc: std.mem.Allocator, abs: []const u8, root: Root) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    const st: ?std.Io.File.Stat = Dir.cwd().statFile(io, abs, .{}) catch null;
    if (st) |s| {
        try obj.put(alloc, "modified", .{ .float = mtimeSecs(s) });
        try obj.put(alloc, "size", .{ .integer = @intCast(s.size) });
        try obj.put(alloc, "permissions", .{ .string = root.permissions() });
    } else {
        try obj.put(alloc, "modified", .{ .integer = 0 });
        try obj.put(alloc, "size", .{ .integer = 0 });
        try obj.put(alloc, "permissions", .{ .string = "" });
    }
    return .{ .object = obj };
}

const StatKind = enum { file, dir, other, missing };

fn statKind(io: std.Io, abs: []const u8) StatKind {
    const st = Dir.cwd().statFile(io, abs, .{}) catch return .missing;
    return switch (st.kind) {
        .file => .file,
        .directory => .dir,
        else => .other,
    };
}

// ---------------------------------------------------------------------------
// notify_filelist_changed emission
// ---------------------------------------------------------------------------

const SourceItem = struct { root: Root, rel: []const u8 };

/// Build the notify_info object: `{ action, item, source_item? }`. The `item`
/// is path_info augmented with `path` (relative) and `root`.
fn buildNotifyInfo(
    io: std.Io,
    alloc: std.mem.Allocator,
    action: []const u8,
    root: Root,
    rel: []const u8,
    abs: []const u8,
    source: ?SourceItem,
) !std.json.Value {
    var item = try buildPathInfo(io, alloc, abs, root);
    try item.object.put(alloc, "path", .{ .string = rel });
    try item.object.put(alloc, "root", .{ .string = root.name });

    var info: std.json.ObjectMap = .empty;
    try info.put(alloc, "action", .{ .string = action });
    try info.put(alloc, "item", item);
    if (source) |src| {
        var src_obj: std.json.ObjectMap = .empty;
        try src_obj.put(alloc, "path", .{ .string = src.rel });
        try src_obj.put(alloc, "root", .{ .string = src.root.name });
        try info.put(alloc, "source_item", .{ .object = src_obj });
    }
    return .{ .object = info };
}

/// Emit notify_filelist_changed with `[notify_info]` params (single-element
/// array, matching Moonraker's send_event tuple). No-op when bus is unavailable
/// (unit tests). The value is always returned for handler reuse.
///
/// Uses `emitLocked`: file_manager handlers always run inside `Core.run` (the
/// HTTP/JSON-RPC transports wrap every handler in it), which already holds the
/// non-reentrant Core lock. Calling the locking `emit` here would deadlock.
fn emitFilelistChanged(ctx: *FileCtx, io: std.Io, alloc: std.mem.Allocator, notify_info: std.json.Value) void {
    const bus = ctx.bus orelse return;
    var arr: std.json.Array = .init(alloc);
    arr.append(notify_info) catch return;
    bus.emitLocked(io, notify.names.filelist_changed, .{ .array = arr }) catch {};
}

// ---------------------------------------------------------------------------
// GET /server/files/roots → server.files.roots
// ---------------------------------------------------------------------------

pub fn handleRoots(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *FileCtx = @ptrCast(@alignCast(ctx_ptr));
    var arr: std.json.Array = .init(alloc);
    for (ctx.roots) |r| {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(alloc, "name", .{ .string = r.name });
        try obj.put(alloc, "path", .{ .string = r.path });
        try obj.put(alloc, "permissions", .{ .string = r.permissions() });
        try arr.append(.{ .object = obj });
    }
    return .{ .array = arr };
}

// ---------------------------------------------------------------------------
// GET /server/files/list → server.files.list
// ---------------------------------------------------------------------------
// Flat recursive file list for a root. Each entry:
//   { "path": <rel>, "modified": <mtime>, "size": <bytes>, "permissions": <p> }

pub fn handleList(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *FileCtx = @ptrCast(@alignCast(ctx_ptr));
    const io = try ctx.requireIo();
    const root_name = getStrDefault(params, "root", "gcodes");
    const root = ctx.findRoot(root_name) orelse return error.InvalidParams;

    var arr: std.json.Array = .init(alloc);
    var dir = Dir.cwd().openDir(io, root.path, .{ .iterate = true }) catch
        return .{ .array = arr };
    defer dir.close(io);

    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const rel = try alloc.dupe(u8, entry.path);
        const abs = try std.fs.path.join(alloc, &.{ root.path, rel });
        var info = try buildPathInfo(io, alloc, abs, root);
        try info.object.put(alloc, "path", .{ .string = rel });
        try arr.append(info);
    }
    return .{ .array = arr };
}

// ---------------------------------------------------------------------------
// GET /server/files/directory → server.files.get_directory
// POST/DELETE handled by handlePostDirectory / handleDeleteDirectory.
// ---------------------------------------------------------------------------
// GET response:
//   { "dirs": [...], "files": [...], "disk_usage": {...}, "root_info": {...} }

pub fn handleGetDirectory(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *FileCtx = @ptrCast(@alignCast(ctx_ptr));
    const io = try ctx.requireIo();
    const path = getStrDefault(params, "path", "gcodes");
    const resolved = resolveRequestPath(ctx, alloc, path) catch |e| return mapResolveErr(e);

    if (statKind(io, resolved.abs) != .dir) return error.NotFound;

    var dirs: std.json.Array = .init(alloc);
    var files: std.json.Array = .init(alloc);

    var dir = Dir.cwd().openDir(io, resolved.abs, .{ .iterate = true }) catch
        return error.NotFound;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child_abs = try std.fs.path.join(alloc, &.{ resolved.abs, entry.name });
        var info = try buildPathInfo(io, alloc, child_abs, resolved.root);
        switch (entry.kind) {
            .directory => {
                try info.object.put(alloc, "dirname", .{ .string = try alloc.dupe(u8, entry.name) });
                try dirs.append(info);
            },
            .file => {
                try info.object.put(alloc, "filename", .{ .string = try alloc.dupe(u8, entry.name) });
                try files.append(info);
            },
            else => {},
        }
    }

    var out: std.json.ObjectMap = .empty;
    try out.put(alloc, "dirs", .{ .array = dirs });
    try out.put(alloc, "files", .{ .array = files });
    try out.put(alloc, "disk_usage", try diskUsage(alloc, resolved.abs));

    var root_info: std.json.ObjectMap = .empty;
    try root_info.put(alloc, "name", .{ .string = resolved.root.name });
    try root_info.put(alloc, "permissions", .{ .string = resolved.root.permissions() });
    try out.put(alloc, "root_info", .{ .object = root_info });

    return .{ .object = out };
}

/// Linux `struct statfs` (x86_64 / generic 64-bit). We only read bsize, blocks
/// and bavail; the trailing fields are padding we never touch.
const LinuxStatfs = extern struct {
    f_type: i64,
    f_bsize: i64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_namelen: i64,
    f_frsize: i64,
    f_flags: i64,
    f_spare: [4]i64,
};

/// `{ "total", "used", "free" }` matching shutil.disk_usage._asdict().
fn diskUsage(alloc: std.mem.Allocator, abs: []const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    var total: u64 = 0;
    var free: u64 = 0;
    statfsInto(alloc, abs, &total, &free);
    const used = if (total >= free) total - free else 0;
    try obj.put(alloc, "total", .{ .integer = @intCast(total) });
    try obj.put(alloc, "used", .{ .integer = @intCast(used) });
    try obj.put(alloc, "free", .{ .integer = @intCast(free) });
    return .{ .object = obj };
}

/// Fill total/free bytes via the statfs syscall; leaves them 0 on failure.
fn statfsInto(alloc: std.mem.Allocator, abs: []const u8, total: *u64, free: *u64) void {
    const path_z = alloc.dupeZ(u8, abs) catch return;
    defer alloc.free(path_z);
    var sfs: LinuxStatfs = undefined;
    const rc = std.os.linux.syscall2(.statfs, @intFromPtr(path_z.ptr), @intFromPtr(&sfs));
    if (std.os.linux.errno(rc) != .SUCCESS) return;
    const bsize: u64 = @intCast(sfs.f_bsize);
    total.* = sfs.f_blocks * bsize;
    free.* = sfs.f_bavail * bsize;
}

// ---------------------------------------------------------------------------
// POST /server/files/directory (mkdir)
// ---------------------------------------------------------------------------

pub fn handlePostDirectory(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *FileCtx = @ptrCast(@alignCast(ctx_ptr));
    const io = try ctx.requireIo();
    const path = try getStr(params, "path");
    const resolved = resolveRequestPath(ctx, alloc, path) catch |e| return mapResolveErr(e);

    if (!resolved.root.full_access) return error.Forbidden;
    if (resolved.rel.len == 0) return error.Forbidden; // cannot recreate the root

    Dir.cwd().createDirPath(io, resolved.abs) catch return error.InvalidParams;

    const info = try buildNotifyInfo(io, alloc, "create_dir", resolved.root, resolved.rel, resolved.abs, null);
    emitFilelistChanged(ctx, io, alloc, info);
    return info;
}

// ---------------------------------------------------------------------------
// DELETE /server/files/directory (rmdir, optional recursive force)
// ---------------------------------------------------------------------------

pub fn handleDeleteDirectory(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *FileCtx = @ptrCast(@alignCast(ctx_ptr));
    const io = try ctx.requireIo();
    const path = try getStr(params, "path");
    const force = getBool(params, "force", false);
    const resolved = resolveRequestPath(ctx, alloc, path) catch |e| return mapResolveErr(e);

    if (!resolved.root.full_access) return error.Forbidden;
    if (resolved.rel.len == 0) return error.Forbidden; // cannot delete root
    if (statKind(io, resolved.abs) != .dir) return error.NotFound;

    if (force) {
        Dir.cwd().deleteTree(io, resolved.abs) catch return error.InvalidParams;
    } else {
        Dir.cwd().deleteDir(io, resolved.abs) catch return error.InvalidParams;
    }

    const info = try buildNotifyInfo(io, alloc, "delete_dir", resolved.root, resolved.rel, resolved.abs, null);
    emitFilelistChanged(ctx, io, alloc, info);
    return info;
}

// ---------------------------------------------------------------------------
// POST /server/files/move  and  POST /server/files/copy
// ---------------------------------------------------------------------------

pub fn handleMove(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    return moveOrCopy(ctx_ptr, params, alloc, true);
}

pub fn handleCopy(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    return moveOrCopy(ctx_ptr, params, alloc, false);
}

fn moveOrCopy(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator, is_move: bool) anyerror!std.json.Value {
    const ctx: *FileCtx = @ptrCast(@alignCast(ctx_ptr));
    const io = try ctx.requireIo();
    const source = try getStr(params, "source");
    const dest = try getStr(params, "dest");

    const src = resolveRequestPath(ctx, alloc, source) catch |e| return mapResolveErr(e);
    const dst = resolveRequestPath(ctx, alloc, dest) catch |e| return mapResolveErr(e);

    if (!dst.root.full_access) return error.Forbidden;

    const src_kind = statKind(io, src.abs);
    if (src_kind == .missing) return error.NotFound;

    // If the destination is an existing directory, place the source INSIDE it
    // (dst/basename(src)) — matching shutil.move/shutil.copy. Without this, a
    // move/copy onto an existing folder (a common UI drag-into-folder) failed or
    // landed at the wrong path.
    var dst_abs = dst.abs;
    var dst_rel = dst.rel;
    if (statKind(io, dst.abs) == .dir) {
        const base = std.fs.path.basename(src.abs);
        dst_abs = try std.fs.path.join(alloc, &.{ dst.abs, base });
        dst_rel = try std.fs.path.join(alloc, &.{ dst.rel, base });
    }

    // Reject source == destination. A move is a no-op, but a COPY would open the
    // source then `createFile` (truncating) the same path → a 0-byte file (data
    // loss). Reachable as `copy a.gcode -> gcodes/` (dir-dest resolves to a.gcode)
    // or directly with dest == source. Moonraker raises on same-path move/copy.
    if (std.mem.eql(u8, src.abs, dst_abs)) return error.InvalidParams;

    var action: []const u8 = undefined;
    if (is_move) {
        if (!src.root.full_access) return error.Forbidden;
        Dir.cwd().rename(src.abs, Dir.cwd(), dst_abs, io) catch return error.InvalidParams;
        action = if (src_kind == .dir) "move_dir" else "move_file";
        const src_info: SourceItem = .{ .root = src.root, .rel = src.rel };
        const info = try buildNotifyInfo(io, alloc, action, dst.root, dst_rel, dst_abs, src_info);
        emitFilelistChanged(ctx, io, alloc, info);
        return info;
    }

    // copy
    if (src_kind == .dir) {
        action = "create_dir";
        try copyTree(io, alloc, src.abs, dst_abs);
    } else {
        // If the destination already exists as a file, this is a modify.
        action = if (statKind(io, dst_abs) == .file) "modify_file" else "create_file";
        copyFileSimple(io, alloc, src.abs, dst_abs) catch return error.InvalidParams;
    }
    const info = try buildNotifyInfo(io, alloc, action, dst.root, dst_rel, dst_abs, null);
    emitFilelistChanged(ctx, io, alloc, info);
    return info;
}

/// Copy a single file by reading it whole and writing it out. Used instead of
/// `Dir.copyFile` (whose atomic sendfile path can stall on the threaded io in
/// tests). Sufficient for gcode/config files in the spine.
fn copyFileSimple(io: std.Io, alloc: std.mem.Allocator, src_abs: []const u8, dst_abs: []const u8) !void {
    _ = alloc; // streamed, not buffered whole-file
    const f = try Dir.cwd().openFile(io, src_abs, .{});
    defer f.close(io);
    const out = try Dir.cwd().createFile(io, dst_abs, .{});
    defer out.close(io);

    // Stream chunks src -> dst so a multi-MB gcode file is never held whole in
    // RAM (allocRemaining(.unlimited) previously buffered the entire file, a peak
    // far over the RSS budget). 32 KiB buffers, transient to this call.
    var rbuf: [32 * 1024]u8 = undefined;
    var fr = f.reader(io, &rbuf);
    var wbuf: [32 * 1024]u8 = undefined;
    var fw = out.writer(io, &wbuf);
    while (true) {
        _ = fr.interface.stream(&fw.interface, .unlimited) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
    }
    try fw.interface.flush();
}

fn copyTree(io: std.Io, alloc: std.mem.Allocator, src_abs: []const u8, dst_abs: []const u8) !void {
    Dir.cwd().createDirPath(io, dst_abs) catch return error.InvalidParams;
    var src_dir = Dir.cwd().openDir(io, src_abs, .{ .iterate = true }) catch return error.InvalidParams;
    defer src_dir.close(io);
    var walker = src_dir.walk(alloc) catch return error.OutOfMemory;
    defer walker.deinit();
    while (walker.next(io) catch return error.InvalidParams) |entry| {
        const child_dst = std.fs.path.join(alloc, &.{ dst_abs, entry.path }) catch return error.OutOfMemory;
        switch (entry.kind) {
            .directory => Dir.cwd().createDirPath(io, child_dst) catch return error.InvalidParams,
            .file => {
                const child_src = std.fs.path.join(alloc, &.{ src_abs, entry.path }) catch return error.OutOfMemory;
                if (std.fs.path.dirname(child_dst)) |d| Dir.cwd().createDirPath(io, d) catch {};
                copyFileSimple(io, alloc, child_src, child_dst) catch return error.InvalidParams;
            },
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// DELETE /server/files/delete_file → server.files.delete_file (WS-only)
// Also the implementation backing DELETE /server/files/<root>/<path>.
// ---------------------------------------------------------------------------

pub fn handleDeleteFile(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *FileCtx = @ptrCast(@alignCast(ctx_ptr));
    const path = try getStr(params, "path");
    return deleteFileImpl(ctx, alloc, path);
}

pub fn deleteFileImpl(ctx: *FileCtx, alloc: std.mem.Allocator, path: []const u8) anyerror!std.json.Value {
    const io = try ctx.requireIo();
    const resolved = resolveRequestPath(ctx, alloc, path) catch |e| return mapResolveErr(e);
    if (!resolved.root.full_access) return error.Forbidden;
    if (statKind(io, resolved.abs) != .file) return error.NotFound;

    Dir.cwd().deleteFile(io, resolved.abs) catch return error.InvalidParams;

    const info = try buildNotifyInfo(io, alloc, "delete_file", resolved.root, resolved.rel, resolved.abs, null);
    emitFilelistChanged(ctx, io, alloc, info);
    return info;
}

// ---------------------------------------------------------------------------
// GET /server/files/metadata → server.files.metadata
// ---------------------------------------------------------------------------
// Returns the gcode metadata record shape. Deep gcode parsing is NOT performed
// (see module header); the stat-based record carries the Moonraker keys.

pub fn handleMetadata(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *FileCtx = @ptrCast(@alignCast(ctx_ptr));
    const io = try ctx.requireIo();
    const filename = try getStr(params, "filename");

    const req = try std.fmt.allocPrint(alloc, "gcodes/{s}", .{filename});
    const resolved = resolveRequestPath(ctx, alloc, req) catch |e| return mapResolveErr(e);
    const st = Dir.cwd().statFile(io, resolved.abs, .{}) catch return error.NotFound;
    if (st.kind != .file) return error.NotFound;
    const size: u64 = @intCast(st.size);
    const mtime = mtimeSecs(st);

    // Return the cached record if the file is unchanged (size + mtime). Avoids
    // re-reading 256 KiB + re-parsing the gcode header on every request.
    if (ctx.cachedMetadata(alloc, resolved.abs, size, mtime)) |cached| return cached;

    const value = try buildMetadata(io, alloc, resolved.abs, filename);
    ctx.cacheMetadata(resolved.abs, size, mtime, value);
    return value;
}

/// Build the metadata record with stat-derived fields plus deep gcode-parsed
/// fields (slicer, layer_height, estimated_time, filament_total, thumbnails,
/// temperatures). Reads the first 256 KiB of the file to extract comment-header
/// metadata via `gcode_metadata.parse`.
fn buildMetadata(io: std.Io, alloc: std.mem.Allocator, abs: []const u8, filename: []const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    const st = Dir.cwd().statFile(io, abs, .{}) catch return error.NotFound;
    try obj.put(alloc, "size", .{ .integer = @intCast(st.size) });
    try obj.put(alloc, "modified", .{ .float = mtimeSecs(st) });
    try obj.put(alloc, "uuid", .{ .string = try stableUuid(alloc, filename) });
    try obj.put(alloc, "print_start_time", .null);
    try obj.put(alloc, "job_id", .null);
    try obj.put(alloc, "filename", .{ .string = filename });

    // Deep gcode header parsing: read up to 256 KiB of the file header
    // to extract slicer info, layer count, estimated time, filament usage,
    // temperatures, layer height, and embedded thumbnails.
    if (isGcodeExt(filename)) {
        if (readFileHeader(io, alloc, abs)) |header_text| {
            // Real PrusaSlicer/Orca/Bambu files carry their config block at the
            // end, so also scan the footer for est-time/filament/height/temps.
            const footer_text = readFileFooter(io, alloc, abs);
            const meta = gcode_metadata.parseFull(alloc, header_text, footer_text);

            if (meta.slicer) |s| {
                try obj.put(alloc, "slicer", .{ .string = s });
                if (meta.slicer_version) |v| {
                    try obj.put(alloc, "slicer_version", .{ .string = v });
                }
            } else {
                try obj.put(alloc, "slicer", .{ .string = "Unknown" });
            }
            if (meta.layer_count) |lc| try obj.put(alloc, "layer_count", .{ .integer = lc });
            if (meta.estimated_time) |et| try obj.put(alloc, "estimated_time", .{ .float = et });
            if (meta.filament_total) |ft| try obj.put(alloc, "filament_total", .{ .float = ft });
            if (meta.filament_weight_total) |fw| try obj.put(alloc, "filament_weight_total", .{ .float = fw });
            if (meta.first_layer_extr_temp) |t| try obj.put(alloc, "first_layer_extr_temp", .{ .float = t });
            if (meta.first_layer_bed_temp) |t| try obj.put(alloc, "first_layer_bed_temp", .{ .float = t });
            if (meta.layer_height) |lh| try obj.put(alloc, "layer_height", .{ .float = lh });
            if (meta.object_height) |oh| try obj.put(alloc, "object_height", .{ .float = oh });
            if (meta.nozzle_diameter) |nd| try obj.put(alloc, "nozzle_diameter", .{ .float = nd });

            // Thumbnails: convert gcode_metadata.Thumbnail slices to JSON.
            if (meta.thumbnails.len > 0) {
                var thumbs: std.json.Array = .init(alloc);
                for (meta.thumbnails) |t| {
                    var tobj: std.json.ObjectMap = .empty;
                    try tobj.put(alloc, "width", .{ .integer = t.width });
                    try tobj.put(alloc, "height", .{ .integer = t.height });
                    try tobj.put(alloc, "size", .{ .integer = t.size });
                    try tobj.put(alloc, "data", .{ .string = t.data });
                    try thumbs.append(.{ .object = tobj });
                }
                try obj.put(alloc, "thumbnails", .{ .array = thumbs });
            } else {
                try obj.put(alloc, "thumbnails", .{ .array = .init(alloc) });
            }
        } else |_| {
            try obj.put(alloc, "slicer", .{ .string = "Unknown" });
            try obj.put(alloc, "thumbnails", .{ .array = .init(alloc) });
        }
    } else {
        try obj.put(alloc, "slicer", .{ .string = "Unknown" });
        try obj.put(alloc, "thumbnails", .{ .array = .init(alloc) });
    }

    return .{ .object = obj };
}

/// Read the first max_bytes of a file into `alloc`-owned memory. Returns
/// an error if the file cannot be opened or read (best-effort enrichment).
const header_max_bytes = 256 * 1024;
const footer_max_bytes = 32 * 1024;

fn readFileHeader(io: std.Io, alloc: std.mem.Allocator, abs: []const u8) ![]u8 {
    const f = Dir.cwd().openFile(io, abs, .{}) catch return error.FileNotFound;
    defer f.close(io);
    var rbuf: [8 * 1024]u8 = undefined;
    var fr = f.reader(io, &rbuf);
    return fr.interface.allocRemaining(alloc, .limited(header_max_bytes));
}

/// Read the last `footer_max_bytes` of the file (slicer config block for
/// PrusaSlicer/Orca/Bambu). Returns "" when the file is no larger than the
/// header window (the header already covers it).
fn readFileFooter(io: std.Io, alloc: std.mem.Allocator, abs: []const u8) []u8 {
    const f = Dir.cwd().openFile(io, abs, .{}) catch return "";
    defer f.close(io);
    const st = f.stat(io) catch return "";
    const size: u64 = st.size;
    if (size <= header_max_bytes) return ""; // header already has the whole file
    const n: usize = @intCast(@min(size, @as(u64, footer_max_bytes)));
    const buf = alloc.alloc(u8, n) catch return "";
    const got = f.readPositionalAll(io, buf, size - n) catch return "";
    return buf[0..got];
}

/// A deterministic uuid-shaped string derived from the filename (NOT a parsed
/// gcode uuid). Stable across calls so clients can key on it.
fn stableUuid(alloc: std.mem.Allocator, seed: []const u8) ![]const u8 {
    var h = std.hash.Wyhash.init(0x9e3779b9);
    h.update(seed);
    const a = h.final();
    var h2 = std.hash.Wyhash.init(0x12345678);
    h2.update(seed);
    const b = h2.final();
    return std.fmt.allocPrint(alloc, "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}", .{
        @as(u32, @truncate(a >> 32)),
        @as(u16, @truncate(a >> 16)),
        @as(u16, @truncate(a)),
        @as(u16, @truncate(b >> 48)),
        @as(u48, @truncate(b)),
    });
}

// ---------------------------------------------------------------------------
// POST /server/files/metascan → server.files.metascan
// ---------------------------------------------------------------------------
// Force a metadata rescan. With no deep parser this returns the same shape as
// metadata (after validating the file exists and is a gcode file).

pub fn handleMetascan(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *FileCtx = @ptrCast(@alignCast(ctx_ptr));
    const io = try ctx.requireIo();
    const filename = try getStr(params, "filename");
    const req = try std.fmt.allocPrint(alloc, "gcodes/{s}", .{filename});
    const resolved = resolveRequestPath(ctx, alloc, req) catch |e| return mapResolveErr(e);
    if (statKind(io, resolved.abs) != .file) return error.NotFound;
    if (!isGcodeExt(filename)) return error.InvalidParams;
    return buildMetadata(io, alloc, resolved.abs, filename);
}

// ---------------------------------------------------------------------------
// GET /server/files/thumbnails → server.files.thumbnails
// ---------------------------------------------------------------------------
// Returns embedded thumbnail data parsed from gcode header comments.
// Reads the file header and extracts `; thumbnail begin … end` blocks.

pub fn handleThumbnails(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *FileCtx = @ptrCast(@alignCast(ctx_ptr));
    const io = try ctx.requireIo();
    // Match Moonraker: empty/missing filename → empty list (not an error).
    const filename = getOptStr(params, "filename") orelse return .{ .array = .init(alloc) };
    if (filename.len == 0) return .{ .array = .init(alloc) };
    const req = try std.fmt.allocPrint(alloc, "gcodes/{s}", .{filename});
    const resolved = resolveRequestPath(ctx, alloc, req) catch |e| return mapResolveErr(e);
    if (statKind(io, resolved.abs) != .file) return error.NotFound;
    if (!isGcodeExt(filename)) return .{ .array = .init(alloc) };

    const header_text = readFileHeader(io, alloc, resolved.abs) catch return .{ .array = .init(alloc) };
    const meta = gcode_metadata.parse(alloc, header_text);

    var thumbs: std.json.Array = .init(alloc);
    for (meta.thumbnails) |t| {
        var tobj: std.json.ObjectMap = .empty;
        try tobj.put(alloc, "width", .{ .integer = t.width });
        try tobj.put(alloc, "height", .{ .integer = t.height });
        try tobj.put(alloc, "size", .{ .integer = t.size });
        try tobj.put(alloc, "data", .{ .string = t.data });
        try thumbs.append(.{ .object = tobj });
    }
    return .{ .array = thumbs };
}

// ---------------------------------------------------------------------------
// POST /server/files/zip → server.files.zip
// ---------------------------------------------------------------------------
// Archive creation. phobos does not bundle a zip writer; we validate inputs and
// return the Moonraker response shape `{ "destination": <item>, "action":
// "zip_files" }`. The archive is not actually produced (noted limitation).

pub fn handleZip(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *FileCtx = @ptrCast(@alignCast(ctx_ptr));
    const io = try ctx.requireIo();
    const dest = getStrDefault(params, "dest", "config/collection.zip");
    const resolved = resolveRequestPath(ctx, alloc, dest) catch |e| return mapResolveErr(e);
    if (!resolved.root.full_access) return error.Forbidden;

    var item = try buildPathInfo(io, alloc, resolved.abs, resolved.root);
    try item.object.put(alloc, "path", .{ .string = resolved.rel });
    try item.object.put(alloc, "root", .{ .string = resolved.root.name });

    var out: std.json.ObjectMap = .empty;
    try out.put(alloc, "destination", item);
    try out.put(alloc, "action", .{ .string = "zip_files" });
    return .{ .object = out };
}

// ---------------------------------------------------------------------------
// Upload result (used by http_transport upload wiring)
// ---------------------------------------------------------------------------

/// Build the upload response and emit notify_filelist_changed (create_file).
/// Response shape mirrors Moonraker's `_finish_*_upload`:
///   { "item": {path, root, size, modified, permissions},
///     "action": "create_file", "print_started": false, "print_queued": false }
pub fn buildUploadResult(ctx: *FileCtx, alloc: std.mem.Allocator, resolved: Resolved) !std.json.Value {
    const io = try ctx.requireIo();
    const info = try buildNotifyInfo(io, alloc, "create_file", resolved.root, resolved.rel, resolved.abs, null);
    emitFilelistChanged(ctx, io, alloc, info);

    var out: std.json.ObjectMap = .empty;
    try out.put(alloc, "item", info.object.get("item").?);
    try out.put(alloc, "action", .{ .string = "create_file" });
    try out.put(alloc, "print_started", .{ .bool = false });
    try out.put(alloc, "print_queued", .{ .bool = false });
    return .{ .object = out };
}

// ---------------------------------------------------------------------------
// Error mapping
// ---------------------------------------------------------------------------

fn mapResolveErr(e: ResolveError) anyerror {
    return switch (e) {
        error.InvalidParams => error.InvalidParams,
        error.Forbidden => error.Forbidden,
        error.OutOfMemory => error.OutOfMemory,
    };
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------
//
// JSON-RPC naming: /server/files/directory is registered RequestType.all() in
// Moonraker which the baseline classifies as multi_verb=false → single method
// name "server.files.directory". We replicate the database.item trick: register
// GET with default transports (derives the single name) and POST/DELETE as
// HTTP-only (no extra rpc methods). delete_file is WEBSOCKET-only (no HTTP
// route) so it derives "server.files.delete_file" without an HTTP route.

pub fn registerFileManager(reg: *Registry, ctx: *FileCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    try reg.registerEndpoint(.{ .path = "/server/files/roots", .methods = &.{.GET} }, c, handleRoots);
    try reg.registerEndpoint(.{ .path = "/server/files/list", .methods = &.{.GET} }, c, handleList);
    try reg.registerEndpoint(.{ .path = "/server/files/metadata", .methods = &.{.GET} }, c, handleMetadata);
    try reg.registerEndpoint(.{ .path = "/server/files/metascan", .methods = &.{.POST} }, c, handleMetascan);
    try reg.registerEndpoint(.{ .path = "/server/files/thumbnails", .methods = &.{.GET} }, c, handleThumbnails);

    // directory: one HTTP path split across three handlers, but Moonraker
    // verb-prefixes ALL of them → server.files.get_directory / post_directory /
    // delete_directory (each also a JSON-RPC method, used by Mainsail/Fluidd).
    try reg.registerEndpoint(.{ .path = "/server/files/directory", .methods = &.{.GET}, .multi_verb = true }, c, handleGetDirectory);
    try reg.registerEndpoint(.{ .path = "/server/files/directory", .methods = &.{.POST}, .multi_verb = true }, c, handlePostDirectory);
    try reg.registerEndpoint(.{ .path = "/server/files/directory", .methods = &.{.DELETE}, .multi_verb = true }, c, handleDeleteDirectory);

    try reg.registerEndpoint(.{ .path = "/server/files/move", .methods = &.{.POST} }, c, handleMove);
    try reg.registerEndpoint(.{ .path = "/server/files/copy", .methods = &.{.POST} }, c, handleCopy);
    try reg.registerEndpoint(.{ .path = "/server/files/zip", .methods = &.{.POST} }, c, handleZip);

    // delete_file: WS-only (matches Moonraker transports=WEBSOCKET). Derives
    // the JSON-RPC method "server.files.delete_file" with no HTTP route.
    try reg.registerEndpoint(.{ .path = "/server/files/delete_file", .methods = &.{.DELETE}, .transports = &.{.WEBSOCKET} }, c, handleDeleteFile);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// A temp directory tree with gcodes/config/logs roots and a live threaded io.
const TestRoots = struct {
    threaded: std.Io.Threaded,
    io: std.Io,
    base_path: []u8,
    roots: [3]Root,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) !TestRoots {
        var tr: TestRoots = undefined;
        tr.alloc = alloc;
        tr.threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        tr.io = tr.threaded.io();

        // Unique per-instance temp base in /tmp (process-global atomic counter
        // mixed with the instance address so concurrent threads never collide).
        const Counter = struct {
            var v: std.atomic.Value(u64) = .init(0);
        };
        const uniq = (Counter.v.fetchAdd(1, .monotonic) *% 0x9e3779b97f4a7c15) ^
            @as(u64, @intCast(@intFromPtr(&tr)));
        tr.base_path = try std.fmt.allocPrint(alloc, "/tmp/phobos-fm-test-{x}", .{uniq});

        const dir = Dir.cwd();
        const g = try std.fs.path.join(alloc, &.{ tr.base_path, "gcodes" });
        const cfg = try std.fs.path.join(alloc, &.{ tr.base_path, "config" });
        const lg = try std.fs.path.join(alloc, &.{ tr.base_path, "logs" });
        try dir.createDirPath(tr.io, g);
        try dir.createDirPath(tr.io, cfg);
        try dir.createDirPath(tr.io, lg);

        tr.roots = .{
            .{ .name = "gcodes", .path = g, .full_access = true },
            .{ .name = "config", .path = cfg, .full_access = true },
            .{ .name = "logs", .path = lg, .full_access = false },
        };
        return tr;
    }

    fn ctx(self: *TestRoots) FileCtx {
        return .{ .gpa = self.alloc, .roots = &self.roots, .bus = null, .io = self.io };
    }

    fn deinit(self: *TestRoots) void {
        Dir.cwd().deleteTree(self.io, self.base_path) catch {};
        self.threaded.deinit();
    }

    fn writeFile(self: *TestRoots, rel: []const u8, contents: []const u8) !void {
        const abs = try std.fs.path.join(self.alloc, &.{ self.base_path, rel });
        if (std.fs.path.dirname(abs)) |d| try Dir.cwd().createDirPath(self.io, d);
        try Dir.cwd().writeFile(self.io, .{ .sub_path = abs, .data = contents });
    }

    fn exists(self: *TestRoots, rel_to_base: []const u8) StatKind {
        const abs = std.fs.path.join(self.alloc, &.{ self.base_path, rel_to_base }) catch return .missing;
        return statKind(self.io, abs);
    }
};

fn objParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    return p.value;
}

// ---- normalizeRel / resolveRequestPath (path safety) ----

test "normalizeRel: collapses . and empty segments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("a/b", try normalizeRel(a, "a/./b"));
    try testing.expectEqualStrings("a/b", try normalizeRel(a, "a//b/"));
    try testing.expectEqualStrings("a/b/c", try normalizeRel(a, "a/b/d/../c"));
    try testing.expectEqualStrings("", try normalizeRel(a, ""));
    try testing.expectEqualStrings("", try normalizeRel(a, "./."));
}

test "normalizeRel: rejects escape above root" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.Forbidden, normalizeRel(a, ".."));
    try testing.expectError(error.Forbidden, normalizeRel(a, "a/../.."));
    try testing.expectError(error.Forbidden, normalizeRel(a, "../etc/passwd"));
    try testing.expectError(error.Forbidden, normalizeRel(a, "a\x00b"));
}

test "resolveRequestPath: valid path stays inside root" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    var c = tr.ctx();

    const r = try resolveRequestPath(&c, a, "gcodes/sub/file.gcode");
    try testing.expectEqualStrings("gcodes", r.root.name);
    try testing.expectEqualStrings("sub/file.gcode", r.rel);
    try testing.expect(std.mem.startsWith(u8, r.abs, tr.roots[0].path));
}

test "resolveRequestPath: unknown root → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    var c = tr.ctx();
    try testing.expectError(error.InvalidParams, resolveRequestPath(&c, a, "nope/x"));
    try testing.expectError(error.InvalidParams, resolveRequestPath(&c, a, ""));
}

test "resolveRequestPath: escape attempt → Forbidden" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    var c = tr.ctx();
    try testing.expectError(error.Forbidden, resolveRequestPath(&c, a, "gcodes/../../etc/passwd"));
    try testing.expectError(error.Forbidden, resolveRequestPath(&c, a, "gcodes/../config/secret"));
}

// ---- handlers ----

test "handleRoots: lists configured roots with permissions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    var c = tr.ctx();

    const result = try handleRoots(@ptrCast(&c), .null, a);
    try testing.expectEqual(@as(usize, 3), result.array.items.len);
    const first = result.array.items[0].object;
    try testing.expectEqualStrings("gcodes", first.get("name").?.string);
    try testing.expectEqualStrings("rw", first.get("permissions").?.string);
    const logs = result.array.items[2].object;
    try testing.expectEqualStrings("logs", logs.get("name").?.string);
    try testing.expectEqualStrings("r", logs.get("permissions").?.string);
}

test "handleList: returns files in root with path/size/modified" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    try tr.writeFile("gcodes/a.gcode", "G28\n");
    try tr.writeFile("gcodes/sub/b.gcode", "G1\n");
    var c = tr.ctx();

    const result = try handleList(@ptrCast(&c), try objParams(a, "{\"root\":\"gcodes\"}"), a);
    try testing.expectEqual(@as(usize, 2), result.array.items.len);
    for (result.array.items) |it| {
        try testing.expect(it.object.get("path") != null);
        try testing.expect(it.object.get("size") != null);
        try testing.expect(it.object.get("modified") != null);
    }
}

test "handleGetDirectory: dirs/files/disk_usage/root_info shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    try tr.writeFile("gcodes/top.gcode", "G28\n");
    try Dir.cwd().createDirPath(tr.io, try std.fs.path.join(a, &.{ tr.roots[0].path, "subdir" }));
    var c = tr.ctx();

    const result = try handleGetDirectory(@ptrCast(&c), try objParams(a, "{\"path\":\"gcodes\"}"), a);
    const o = result.object;
    try testing.expect(o.get("dirs").? == .array);
    try testing.expect(o.get("files").? == .array);
    const du = o.get("disk_usage").?.object;
    try testing.expect(du.get("total") != null);
    try testing.expect(du.get("used") != null);
    try testing.expect(du.get("free") != null);
    const ri = o.get("root_info").?.object;
    try testing.expectEqualStrings("gcodes", ri.get("name").?.string);
    try testing.expectEqualStrings("rw", ri.get("permissions").?.string);
    try testing.expectEqual(@as(usize, 1), o.get("dirs").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), o.get("files").?.array.items.len);
}

test "handlePostDirectory: mkdir then notify info shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    var c = tr.ctx();

    const result = try handlePostDirectory(@ptrCast(&c), try objParams(a, "{\"path\":\"gcodes/newdir\"}"), a);
    try testing.expectEqualStrings("create_dir", result.object.get("action").?.string);
    const item = result.object.get("item").?.object;
    try testing.expectEqualStrings("newdir", item.get("path").?.string);
    try testing.expectEqualStrings("gcodes", item.get("root").?.string);
    try testing.expectEqual(StatKind.dir, tr.exists("gcodes/newdir"));
}

test "handlePostDirectory: read-only root → Forbidden" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    var c = tr.ctx();
    try testing.expectError(error.Forbidden, handlePostDirectory(@ptrCast(&c), try objParams(a, "{\"path\":\"logs/x\"}"), a));
}

test "handleDeleteDirectory: rmdir empty and force recursive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    try Dir.cwd().createDirPath(tr.io, try std.fs.path.join(a, &.{ tr.roots[0].path, "empty" }));
    try tr.writeFile("gcodes/full/inner.gcode", "G1\n");
    var c = tr.ctx();

    const r1 = try handleDeleteDirectory(@ptrCast(&c), try objParams(a, "{\"path\":\"gcodes/empty\"}"), a);
    try testing.expectEqualStrings("delete_dir", r1.object.get("action").?.string);

    try testing.expectError(error.InvalidParams, handleDeleteDirectory(@ptrCast(&c), try objParams(a, "{\"path\":\"gcodes/full\"}"), a));
    const r2 = try handleDeleteDirectory(@ptrCast(&c), try objParams(a, "{\"path\":\"gcodes/full\",\"force\":true}"), a);
    try testing.expectEqualStrings("delete_dir", r2.object.get("action").?.string);
}

test "handleDeleteDirectory: cannot delete root" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    var c = tr.ctx();
    try testing.expectError(error.Forbidden, handleDeleteDirectory(@ptrCast(&c), try objParams(a, "{\"path\":\"gcodes\"}"), a));
}

test "handleMove: moves file and emits move_file action with source_item" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    try tr.writeFile("gcodes/orig.gcode", "G28\n");
    var c = tr.ctx();

    const result = try handleMove(@ptrCast(&c), try objParams(a, "{\"source\":\"gcodes/orig.gcode\",\"dest\":\"gcodes/moved.gcode\"}"), a);
    try testing.expectEqualStrings("move_file", result.object.get("action").?.string);
    const src = result.object.get("source_item").?.object;
    try testing.expectEqualStrings("orig.gcode", src.get("path").?.string);
    try testing.expectEqualStrings("gcodes", src.get("root").?.string);
    try testing.expectEqual(StatKind.file, tr.exists("gcodes/moved.gcode"));
    try testing.expectEqual(StatKind.missing, tr.exists("gcodes/orig.gcode"));
}

test "handleCopy: copies file with create_file then modify_file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    try tr.writeFile("gcodes/src.gcode", "G28\n");
    var c = tr.ctx();

    const r1 = try handleCopy(@ptrCast(&c), try objParams(a, "{\"source\":\"gcodes/src.gcode\",\"dest\":\"gcodes/dst.gcode\"}"), a);
    try testing.expectEqualStrings("create_file", r1.object.get("action").?.string);
    const r2 = try handleCopy(@ptrCast(&c), try objParams(a, "{\"source\":\"gcodes/src.gcode\",\"dest\":\"gcodes/dst.gcode\"}"), a);
    try testing.expectEqualStrings("modify_file", r2.object.get("action").?.string);
}

test "handleCopy/Move: destination directory receives the source inside it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    try tr.writeFile("gcodes/orig.gcode", "G28\n");
    // Create gcodes/sub as a directory by placing a file under it.
    try tr.writeFile("gcodes/sub/keep.txt", "x");
    var c = tr.ctx();

    // Copy onto the directory → lands at gcodes/sub/orig.gcode.
    const rc = try handleCopy(@ptrCast(&c), try objParams(a, "{\"source\":\"gcodes/orig.gcode\",\"dest\":\"gcodes/sub\"}"), a);
    try testing.expectEqualStrings("create_file", rc.object.get("action").?.string);
    try testing.expectEqual(StatKind.file, tr.exists("gcodes/sub/orig.gcode"));
    try testing.expectEqual(StatKind.file, tr.exists("gcodes/orig.gcode")); // copy left source

    // Move onto the directory → lands at gcodes/sub/orig.gcode, source gone.
    const rm = try handleMove(@ptrCast(&c), try objParams(a, "{\"source\":\"gcodes/orig.gcode\",\"dest\":\"gcodes/sub\"}"), a);
    try testing.expectEqualStrings("move_file", rm.object.get("action").?.string);
    try testing.expectEqual(StatKind.missing, tr.exists("gcodes/orig.gcode"));
}

test "handleCopy: source == destination is rejected (no self-truncation)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    const contents = "G28\nG1 X10\n";
    try tr.writeFile("gcodes/a.gcode", contents);
    var c = tr.ctx();

    // Both forms resolve dst == src; a copy must NOT open-then-truncate the file.
    try testing.expectError(error.InvalidParams, handleCopy(@ptrCast(&c), try objParams(a, "{\"source\":\"gcodes/a.gcode\",\"dest\":\"gcodes/a.gcode\"}"), a));
    try testing.expectError(error.InvalidParams, handleCopy(@ptrCast(&c), try objParams(a, "{\"source\":\"gcodes/a.gcode\",\"dest\":\"gcodes\"}"), a));
    // The source file is untouched (still its original size, not truncated to 0).
    const md = try buildMetadata(tr.io, a, try std.fs.path.join(a, &.{ tr.roots[0].path, "a.gcode" }), "a.gcode");
    try testing.expectEqual(@as(i64, @intCast(contents.len)), md.object.get("size").?.integer);
}

test "handleCopy: read-only destination root → Forbidden" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    try tr.writeFile("gcodes/src.gcode", "G28\n");
    var c = tr.ctx();
    try testing.expectError(error.Forbidden, handleCopy(@ptrCast(&c), try objParams(a, "{\"source\":\"gcodes/src.gcode\",\"dest\":\"logs/x.gcode\"}"), a));
}

test "handleDeleteFile: deletes and emits delete_file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    try tr.writeFile("gcodes/del.gcode", "G28\n");
    var c = tr.ctx();

    const result = try handleDeleteFile(@ptrCast(&c), try objParams(a, "{\"path\":\"gcodes/del.gcode\"}"), a);
    try testing.expectEqualStrings("delete_file", result.object.get("action").?.string);
    try testing.expectEqual(StatKind.missing, tr.exists("gcodes/del.gcode"));
}

test "handleDeleteFile: missing file → NotFound" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    var c = tr.ctx();
    try testing.expectError(error.NotFound, handleDeleteFile(@ptrCast(&c), try objParams(a, "{\"path\":\"gcodes/nope.gcode\"}"), a));
}

test "handleMetadata: stat-based record shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    try tr.writeFile("gcodes/m.gcode", "G28\nG1 X0\n");
    var c = tr.ctx();

    const result = try handleMetadata(@ptrCast(&c), try objParams(a, "{\"filename\":\"m.gcode\"}"), a);
    const o = result.object;
    try testing.expectEqualStrings("m.gcode", o.get("filename").?.string);
    try testing.expect(o.get("size") != null);
    try testing.expect(o.get("modified") != null);
    try testing.expect(o.get("uuid") != null);
    try testing.expect(o.get("thumbnails").? == .array);
    try testing.expect(o.get("print_start_time").? == .null);
    try testing.expect(o.get("job_id").? == .null);
}

test "handleMetadata: cache hit returns same record; file change invalidates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    try tr.writeFile("gcodes/c.gcode", "G28\n");
    var c = tr.ctx();
    defer c.deinit();

    const p = try objParams(a, "{\"filename\":\"c.gcode\"}");
    const r1 = try handleMetadata(@ptrCast(&c), p, a);
    const size1 = r1.object.get("size").?.integer;
    try testing.expectEqual(@as(usize, 1), c.metadata_cache.count()); // populated

    // Second call hits the cache and yields the same size.
    const r2 = try handleMetadata(@ptrCast(&c), p, a);
    try testing.expectEqual(size1, r2.object.get("size").?.integer);

    // Rewriting the file changes its size → the (size,mtime) stamp no longer
    // matches, so the cache must rebuild and report the new size.
    try tr.writeFile("gcodes/c.gcode", "G28\nG1 X10\nG1 Y10\nG1 Z5\n");
    const r3 = try handleMetadata(@ptrCast(&c), p, a);
    try testing.expect(r3.object.get("size").?.integer != size1);
}

test "handleMetadata: missing file → NotFound" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    var c = tr.ctx();
    try testing.expectError(error.NotFound, handleMetadata(@ptrCast(&c), try objParams(a, "{\"filename\":\"none.gcode\"}"), a));
}

test "handleMetadata: gcode header parsing extracts slicer and stats" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();

    const gcode =
        \\; generated by PrusaSlicer 2.7.4 on 2024-01-15 at 08:30:00 UTC
        \\;LAYER_COUNT: 42
        \\; estimated printing time (normal mode) = 5025s
        \\; filament used [mm] = 1234.5
        \\; total filament used [g] = 150.0
        \\; nozzle_diameter = 0.4
        \\; first_layer_temperature = 210
        \\; first_layer_bed_temperature = 60
        \\; layer_height = 0.2
        \\; max_z_height: 155.0
        \\; thumbnail begin 16x16 12
        \\iVBORw0==
        \\; thumbnail end
        \\G28 X0 Y0
        \\
        \\G1 X100 Y100
        \\
    ;
    try tr.writeFile("gcodes/parsed.gcode", gcode);
    var c = tr.ctx();

    const result = try handleMetadata(@ptrCast(&c), try objParams(a, "{\"filename\":\"parsed.gcode\"}"), a);
    const o = result.object;
    try testing.expectEqualStrings("parsed.gcode", o.get("filename").?.string);
    try testing.expectEqualStrings("PrusaSlicer", o.get("slicer").?.string);
    try testing.expectEqualStrings("2.7.4", o.get("slicer_version").?.string);
    try testing.expectEqual(@as(i64, 42), o.get("layer_count").?.integer);
    try testing.expectEqual(@as(f64, 5025.0), o.get("estimated_time").?.float);
    try testing.expectEqual(@as(f64, 1234.5), o.get("filament_total").?.float);
    try testing.expectEqual(@as(f64, 150.0), o.get("filament_weight_total").?.float);
    try testing.expectEqual(@as(f64, 0.4), o.get("nozzle_diameter").?.float);
    try testing.expectEqual(@as(f64, 210.0), o.get("first_layer_extr_temp").?.float);
    try testing.expectEqual(@as(f64, 60.0), o.get("first_layer_bed_temp").?.float);
    try testing.expectEqual(@as(f64, 0.2), o.get("layer_height").?.float);
    try testing.expectEqual(@as(f64, 155.0), o.get("object_height").?.float);

    const thumbs = o.get("thumbnails").?.array;
    try testing.expectEqual(@as(usize, 1), thumbs.items.len);
    try testing.expectEqual(@as(i64, 16), thumbs.items[0].object.get("width").?.integer);
}

test "handleMetadata: non-gcode file returns Unknown slicer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    try tr.writeFile("gcodes/test.txt", "not a gcode file");
    var c = tr.ctx();
    const result = try handleMetadata(@ptrCast(&c), try objParams(a, "{\"filename\":\"test.txt\"}"), a);
    try testing.expectEqualStrings("Unknown", result.object.get("slicer").?.string);
}

test "handleMetascan: validates gcode ext" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    try tr.writeFile("gcodes/scan.gcode", "G28\n");
    try tr.writeFile("gcodes/notgcode.txt", "hi\n");
    var c = tr.ctx();

    const ok = try handleMetascan(@ptrCast(&c), try objParams(a, "{\"filename\":\"scan.gcode\"}"), a);
    try testing.expectEqualStrings("scan.gcode", ok.object.get("filename").?.string);
    try testing.expectError(error.InvalidParams, handleMetascan(@ptrCast(&c), try objParams(a, "{\"filename\":\"notgcode.txt\"}"), a));
}

test "handleThumbnails: parses embedded thumbnails from gcode header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();

    // Write a gcode file with a thumbnail block.
    const gcode =
        \\; thumbnail begin 32x32 44
        \\iVBORw0KGgoAAAANSUhEUg==
        \\; thumbnail end
        \\G28 X0 Y0
        \\
    ;
    try tr.writeFile("gcodes/test.gcode", gcode);

    var c = tr.ctx();
    const result = try handleThumbnails(@ptrCast(&c), try objParams(a, "{\"filename\":\"test.gcode\"}"), a);
    try testing.expect(result == .array);
    try testing.expectEqual(@as(usize, 1), result.array.items.len);
    const t = result.array.items[0].object;
    try testing.expectEqual(@as(i64, 32), t.get("width").?.integer);
    try testing.expectEqual(@as(i64, 32), t.get("height").?.integer);
    try testing.expectEqualStrings("iVBORw0KGgoAAAANSUhEUg==", t.get("data").?.string);

    // Missing/empty filename → empty list (matches Moonraker behavior).
    {
        const r = try handleThumbnails(@ptrCast(&c), .null, a);
        try testing.expect(r == .array);
        try testing.expectEqual(@as(usize, 0), r.array.items.len);
    }
}

test "handleThumbnails: non-gcode file returns empty list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    try tr.writeFile("gcodes/test.txt", "hello");
    var c = tr.ctx();
    const result = try handleThumbnails(@ptrCast(&c), try objParams(a, "{\"filename\":\"test.txt\"}"), a);
    try testing.expect(result == .array);
    try testing.expectEqual(@as(usize, 0), result.array.items.len);
}

test "handleThumbnails: missing file returns NotFound" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    var c = tr.ctx();
    try testing.expectError(error.NotFound, handleThumbnails(@ptrCast(&c), try objParams(a, "{\"filename\":\"nonexistent.gcode\"}"), a));
}

test "handleZip: response shape destination + action" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    var c = tr.ctx();
    const result = try handleZip(@ptrCast(&c), try objParams(a, "{\"dest\":\"config/out.zip\",\"items\":[]}"), a);
    try testing.expectEqualStrings("zip_files", result.object.get("action").?.string);
    const dst = result.object.get("destination").?.object;
    try testing.expectEqualStrings("out.zip", dst.get("path").?.string);
    try testing.expectEqualStrings("config", dst.get("root").?.string);
}

test "isGcodeExt: recognizes valid extensions" {
    try testing.expect(isGcodeExt("a.gcode"));
    try testing.expect(isGcodeExt("a.G"));
    try testing.expect(isGcodeExt("a.gco"));
    try testing.expect(isGcodeExt("a.ufp"));
    try testing.expect(!isGcodeExt("a.txt"));
    try testing.expect(!isGcodeExt("noext"));
}

test "registerFileManager: wires routes and JSON-RPC methods" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");
    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    const roots = [_]Root{.{ .name = "gcodes", .path = "/tmp", .full_access = true }};
    var ctx = FileCtx{ .gpa = alloc, .roots = &roots, .bus = null };
    try registerFileManager(&reg, &ctx);

    try testing.expect(reg.lookup(.GET, "/server/files/roots") != null);
    try testing.expect(reg.lookup(.GET, "/server/files/list") != null);
    try testing.expect(reg.lookup(.GET, "/server/files/directory") != null);
    try testing.expect(reg.lookup(.POST, "/server/files/directory") != null);
    try testing.expect(reg.lookup(.DELETE, "/server/files/directory") != null);
    try testing.expect(reg.lookup(.POST, "/server/files/move") != null);
    try testing.expect(reg.lookup(.POST, "/server/files/copy") != null);
    try testing.expect(reg.lookup(.POST, "/server/files/zip") != null);

    const expected_methods = [_][]const u8{
        "server.files.roots",            "server.files.list",
        "server.files.metadata",         "server.files.metascan",
        "server.files.thumbnails",       "server.files.get_directory",
        "server.files.post_directory",   "server.files.delete_directory",
        "server.files.move",             "server.files.copy",
        "server.files.zip",              "server.files.delete_file",
    };
    for (expected_methods) |m| {
        try testing.expect(d.methods.get(m) != null);
    }
    // The old single-name "server.files.directory" must NOT exist (renamed to
    // the verb-prefixed get_/post_/delete_ trio above).
    try testing.expect(d.methods.get("server.files.directory") == null);
}

// ---- Fuzz tests ----

test "fuzz normalizeRel: never escapes the root, never crashes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const n = 1 + (@as(usize, buf[0]) % 60);

            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const alphabet = "ab/.";
            var path_buf: [128]u8 = undefined;
            var len: usize = 0;
            for (buf[0..n]) |b| {
                path_buf[len] = alphabet[b % alphabet.len];
                len += 1;
            }
            const rel = path_buf[0..len];

            const out = normalizeRel(a, rel) catch return;
            var it = std.mem.splitScalar(u8, out, '/');
            while (it.next()) |seg| {
                try testing.expect(!std.mem.eql(u8, seg, ".."));
            }
        }
    }.run, .{});
}

test "fuzz resolveRequestPath: abs always inside root or rejected" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const n = 1 + (@as(usize, buf[0]) % 60);

            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const roots = [_]Root{.{ .name = "gcodes", .path = "/srv/gcodes", .full_access = true }};
            var ctx = FileCtx{ .gpa = a, .roots = &roots, .bus = null };

            const alphabet = "ab/.g";
            var path_buf: [128]u8 = undefined;
            const prefix = "gcodes/";
            @memcpy(path_buf[0..prefix.len], prefix);
            var len: usize = prefix.len;
            for (buf[0..n]) |b| {
                path_buf[len] = alphabet[b % alphabet.len];
                len += 1;
            }
            const req = path_buf[0..len];

            const r = resolveRequestPath(&ctx, a, req) catch return;
            try testing.expect(std.mem.startsWith(u8, r.abs, "/srv/gcodes"));
        }
    }.run, .{});
}

test "fuzz handlers: arbitrary params never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);

            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var tr = TestRoots.init(a) catch return;
            defer tr.deinit();
            var c = tr.ctx();

            const cases = [_][]const u8{
                "{}",
                "{\"root\":\"gcodes\"}",
                "{\"path\":\"gcodes/../etc\"}",
                "{\"path\":\"gcodes/x\"}",
                "{\"filename\":\"a.gcode\"}",
                "{\"source\":\"gcodes/a\",\"dest\":\"gcodes/b\"}",
                "null",
            };
            const p = std.json.parseFromSlice(std.json.Value, a, cases[buf[0] % cases.len], .{}) catch return;
            _ = handleRoots(@ptrCast(&c), p.value, a) catch {};
            _ = handleList(@ptrCast(&c), p.value, a) catch {};
            _ = handleGetDirectory(@ptrCast(&c), p.value, a) catch {};
            _ = handlePostDirectory(@ptrCast(&c), p.value, a) catch {};
            _ = handleDeleteDirectory(@ptrCast(&c), p.value, a) catch {};
            _ = handleMove(@ptrCast(&c), p.value, a) catch {};
            _ = handleCopy(@ptrCast(&c), p.value, a) catch {};
            _ = handleDeleteFile(@ptrCast(&c), p.value, a) catch {};
            _ = handleMetadata(@ptrCast(&c), p.value, a) catch {};
            _ = handleMetascan(@ptrCast(&c), p.value, a) catch {};
            _ = handleThumbnails(@ptrCast(&c), p.value, a) catch {};
            _ = handleZip(@ptrCast(&c), p.value, a) catch {};
        }
    }.run, .{});
}
