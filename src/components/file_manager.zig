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
//! PATH SAFETY: `resolveRequestPath` normalizes the requested relative path.
//! `Resolved` opens relative to a registered root directory handle, resolves
//! links within that root, and rejects escaping links. Actual opens do not
//! follow replacement symlinks. `Resolved.abs` is for display and cache keys.
//!
//! On every successful mutation the component emits `notify_filelist_changed`
//! through `bus.emitLocked` with Moonraker's exact payload:
//!   params: [ { "action": "create_file"|"delete_file"|"create_dir"|
//!               "delete_dir"|"move_file"|"move_dir"|"modify_file",
//!              "item": { "path", "root", "size", "modified", "permissions" },
//!              "source_item"?: { "path", "root" } } ]
//!
//! Gcode metadata includes parsed slicer fields, thumbnails, and layer heights.
//! Extended gcodes directory listings reuse the same bounded metadata cache as
//! individual metadata requests. See `buildMetadata`.
//!
//! File I/O uses `std.Io.Dir`; disk capacity uses musl's `fstatvfs`. The live
//! `io` handle is stored in `FileCtx.io` and
//! supplied after the App event loop starts (via `setIo`); handlers return
//! `error.NotReady` if invoked before io is wired.

const std = @import("std");
const webreq = @import("../json/params.zig");
const registry = @import("../server/registry.zig");
const notify = @import("../server/notify.zig");
const jv = @import("../json/value.zig");
const confighelper = @import("../config/confighelper.zig");
const NotifyBus = @import("../server/notify.zig").NotifyBus;
const gcode_metadata = @import("gcode_metadata.zig");
const job_state_component = @import("job_state.zig");
const ServerInfo = @import("../core/methods.zig").ServerInfo;
const zip_writer = @import("../zip_writer.zig");

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
    /// Arena capacity, counted against `metadata_cache_max_bytes`.
    bytes: usize,
    arena: std.heap.ArenaAllocator,
    value: std.json.Value,
};

/// Metadata cache caps. `server.files.metadata` re-reads up to 256 KiB + re-parses
/// the gcode header on every call; Mainsail/Fluidd request it for every file in a
/// listing, so on slow eMMC this is a real, repeated stall. Entries carry base64
/// thumbnails (tens of KiB each), so the cache is bounded by entries and by
/// arena bytes and cleared wholesale on overflow. A record larger than the byte
/// cap is not cached.
const metadata_cache_cap = 256;
const metadata_cache_max_bytes = 512 * 1024;

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
    /// Sum of `MetaEntry.bytes` in `metadata_cache`.
    metadata_cache_bytes: usize = 0,
    /// Guards metadata_cache. metadata runs under Core today, but lock anyway so
    /// the cache stays correct if it ever moves off-Core. No-op when io unset.
    metadata_cache_mutex: std.Io.Mutex = .init,
    /// Archive compression runs outside Core, one archive at a time.
    archive_mutex: std.Io.Mutex = .init,
    /// `root/relative` paths omitted from listings. Forge-X `excludes`.
    excludes: [][]const u8 = &.{},
    excludes_owned: bool = false,
    /// print_stats source for `checkInUse`. Borrowed; set by the App.
    job_state: ?*job_state_component.JobStateCtx = null,
    /// Klippy readiness for the loaded-file lock. Borrowed; set by the App.
    server_info: ?*ServerInfo = null,

    pub fn setIo(self: *FileCtx, io: std.Io) void {
        self.io = io;
    }

    /// Replace the exclude list. Each entry is `root/relative`, one per line.
    pub fn setExcludes(self: *FileCtx, text: []const u8) !void {
        const owned = try confighelper.dupeLines(self.gpa, text);
        if (self.excludes_owned) confighelper.freeLines(self.gpa, self.excludes);
        self.excludes = owned;
        self.excludes_owned = true;
    }

    /// True when `root/rel` is an exclude or sits under one.
    pub fn pathExcluded(excludes: []const []const u8, root: []const u8, rel: []const u8) bool {
        for (excludes) |ex| {
            if (!std.mem.startsWith(u8, ex, root)) continue;
            if (ex.len == root.len) return true;
            if (ex[root.len] != '/') continue;
            const rest = ex[root.len + 1 ..];
            if (std.mem.eql(u8, rel, rest)) return true;
            if (rel.len > rest.len and std.mem.startsWith(u8, rel, rest) and rel[rest.len] == '/') return true;
        }
        return false;
    }

    pub fn deinit(self: *FileCtx) void {
        if (self.excludes_owned) {
            confighelper.freeLines(self.gpa, self.excludes);
            self.excludes = &.{};
            self.excludes_owned = false;
        }
        self.evictMetadata();
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
        const bytes = arena.queryCapacity();
        if (self.metadata_cache.fetchRemove(abs)) |old| {
            // Replace: free the old arena only now that the new copy is in hand.
            self.metadata_cache_bytes -= old.value.bytes;
            var old_arena = old.value.arena;
            old_arena.deinit();
            self.gpa.free(old.key);
        }
        if (bytes > metadata_cache_max_bytes) {
            arena.deinit();
            return;
        }
        if (self.metadata_cache.count() >= metadata_cache_cap or self.metadata_cache_bytes + bytes > metadata_cache_max_bytes) {
            self.evictMetadata();
        }
        const key = self.gpa.dupe(u8, abs) catch {
            arena.deinit();
            return;
        };
        self.metadata_cache.put(self.gpa, key, .{ .size = size, .mtime = mtime, .bytes = bytes, .arena = arena, .value = copy }) catch {
            self.gpa.free(key);
            arena.deinit();
            return;
        };
        self.metadata_cache_bytes += bytes;
    }

    fn evictMetadata(self: *FileCtx) void {
        var it = self.metadata_cache.iterator();
        while (it.next()) |e| {
            e.value_ptr.arena.deinit();
            self.gpa.free(e.key_ptr.*);
        }
        self.metadata_cache.clearRetainingCapacity();
        self.metadata_cache_bytes = 0;
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
        const file = resolved.openFile(io, a) catch return false;
        file.close(io);
        return true;
    }

    /// Type-erased adapter: does "gcodes/<filename>" exist as a file?
    pub fn gcodeExistsErased(ctx: *anyopaque, filename: []const u8) bool {
        const self: *const FileCtx = @ptrCast(@alignCast(ctx));
        return self.fileExists("gcodes", filename);
    }

    /// Moonraker `_handle_operation_check`: while a print is active (printing
    /// or paused) and Klippy is ready, refuse to change the loaded gcode file
    /// or, when `is_dir`, a directory holding it. Call under Core.
    pub fn checkInUse(self: *const FileCtx, path: Resolved, is_dir: bool) error{FileInUse}!void {
        if (!std.mem.eql(u8, path.root.name, "gcodes")) return;
        if (self.server_info) |info| {
            const aio = self.io orelse info.io;
            if (aio) |i| info.state_mutex.lockUncancelable(i);
            defer if (aio) |i| info.state_mutex.unlock(i);
            if (!std.mem.eql(u8, info.klippy_state, "ready")) return;
        }
        const js = self.job_state orelse return;
        if (!js.isActive()) return;
        const loaded = js.getLastStats().get("filename") orelse return;
        if (loaded != .string or loaded.string.len == 0) return;
        const name = std.mem.trimStart(u8, loaded.string, "/");
        const in_use = if (is_dir)
            path.rel.len == 0 or (std.mem.startsWith(u8, name, path.rel) and name.len > path.rel.len and name[path.rel.len] == '/')
        else
            std.mem.eql(u8, name, path.rel);
        if (in_use) return error.FileInUse;
    }
};

// ---------------------------------------------------------------------------
// Param helpers
// ---------------------------------------------------------------------------

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
    /// Lexical path for display and cache keys. Open through the methods below.
    abs: []const u8,

    pub const ParentOptions = struct {
        make_path: bool = false,
        follow_leaf: bool = false,
    };

    pub const Parent = struct {
        dir: Dir,
        name: []const u8,
        arena: std.heap.ArenaAllocator,

        pub fn close(self: *Parent, io: std.Io) void {
            self.dir.close(io);
            self.arena.deinit();
        }
    };

    /// Owns the returned directory and name. Resolve links within this root,
    /// then open each directory without following a replacement symlink.
    pub fn parent(self: Resolved, io: std.Io, alloc: std.mem.Allocator, options: ParentOptions) !Parent {
        var local = std.heap.ArenaAllocator.init(alloc);
        errdefer local.deinit();
        const a = local.allocator();
        const root_dir = try Dir.cwd().openDir(io, self.root.path, .{});
        defer root_dir.close(io);
        var root_buf: [Dir.max_path_bytes]u8 = undefined;
        const canonical_root = root_buf[0..try root_dir.realPath(io, &root_buf)];
        var dir = try root_dir.openDir(io, ".", .{});
        errdefer dir.close(io);
        if (self.rel.len > Dir.max_path_bytes) return error.InvalidParams;
        var pending: []const u8 = try normalizeRel(a, self.rel);
        var links: usize = 0;
        resolve: while (true) {
            if (pending.len == 0) return .{ .dir = dir, .name = ".", .arena = local };
            var parts = std.mem.splitScalar(u8, pending, '/');
            while (parts.next()) |part| {
                const tail = parts.rest();
                const last = tail.len == 0;
                if (!last or options.follow_leaf) {
                    const is_link = if (dir.statFile(io, part, .{ .follow_symlinks = false })) |info|
                        info.kind == .sym_link
                    else |err| switch (err) {
                        error.FileNotFound => false,
                        else => return err,
                    };
                    if (is_link) {
                        links += 1;
                        if (links > max_path_links) return error.Forbidden;
                        var target_buf: [Dir.max_path_bytes]u8 = undefined;
                        const target = target_buf[0..try dir.realPathFile(io, part, &target_buf)];
                        const relative = if (std.mem.eql(u8, canonical_root, "/"))
                            target[1..]
                        else if (std.mem.eql(u8, target, canonical_root))
                            ""
                        else if (std.mem.startsWith(u8, target, canonical_root) and target.len > canonical_root.len and target[canonical_root.len] == '/')
                            target[canonical_root.len + 1 ..]
                        else
                            return error.Forbidden;
                        pending = try std.fs.path.join(a, &.{ relative, tail });
                        if (pending.len > Dir.max_path_bytes) return error.Forbidden;
                        const restarted = try root_dir.openDir(io, ".", .{});
                        dir.close(io);
                        dir = restarted;
                        continue :resolve;
                    }
                }
                if (last) return .{ .dir = dir, .name = try a.dupe(u8, part), .arena = local };
                const next = dir.openDir(io, part, .{ .follow_symlinks = false }) catch |err| blk: {
                    if (err != error.FileNotFound or !options.make_path) return err;
                    try dir.createDirPath(io, part);
                    break :blk try dir.openDir(io, part, .{ .follow_symlinks = false });
                };
                dir.close(io);
                dir = next;
            }
            unreachable;
        }
    }

    pub fn openFile(self: Resolved, io: std.Io, alloc: std.mem.Allocator) !std.Io.File {
        var p = self.parent(io, alloc, .{ .follow_leaf = true }) catch |err| return accessError(err);
        defer p.close(io);
        const before = p.dir.statFile(io, p.name, .{ .follow_symlinks = false }) catch |err| return accessError(err);
        if (before.kind == .sym_link) return error.Forbidden;
        if (before.kind != .file) return error.NotFound;
        const file = p.dir.openFile(io, p.name, .{ .follow_symlinks = false }) catch |err| return accessError(err);
        errdefer file.close(io);
        if ((try file.stat(io)).kind != .file) return error.NotFound;
        return file;
    }

    pub fn openDirectory(self: Resolved, io: std.Io, alloc: std.mem.Allocator) !Dir {
        var p = self.parent(io, alloc, .{ .follow_leaf = true }) catch |err| return accessError(err);
        defer p.close(io);
        return p.dir.openDir(io, p.name, .{ .iterate = true, .follow_symlinks = false }) catch |err| return accessError(err);
    }

    pub fn stat(self: Resolved, io: std.Io, alloc: std.mem.Allocator) !std.Io.File.Stat {
        var p = self.parent(io, alloc, .{ .follow_leaf = true }) catch |err| return accessError(err);
        defer p.close(io);
        const result = try p.dir.statFile(io, p.name, .{ .follow_symlinks = false });
        if (result.kind == .sym_link) return error.Forbidden;
        return result;
    }

    /// Dir.copyFile reopens its source by name; keep the checked file open here.
    pub fn copyTo(self: Resolved, io: std.Io, alloc: std.mem.Allocator, destination: Resolved) !void {
        const source = try self.openFile(io, alloc);
        defer source.close(io);
        const info = try source.stat(io);
        var p = try destination.parent(io, alloc, .{ .make_path = true });
        defer p.close(io);
        var output = try p.dir.createFileAtomic(io, p.name, .{ .permissions = info.permissions, .replace = true });
        defer output.deinit(io);
        var reader: std.Io.File.Reader = .initSize(source, io, &.{}, info.size);
        var buf: [4096]u8 = undefined;
        var writer = output.file.writer(io, &buf);
        _ = writer.interface.sendFileAll(&reader, .unlimited) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            error.WriteFailed => return writer.err.?,
        };
        try writer.flush();
        // File.Atomic.replace renames without syncing; match the upload path.
        try output.file.sync(io);
        try output.replace(io);
    }
};

const max_path_links = 40;

// Dir.Walker cannot accept checked child handles. Resolve linked directories
// within the root, then open without following a replacement link.
const RootWalker = struct {
    alloc: std.mem.Allocator,
    base: Resolved,
    mode: Mode,
    stack: std.ArrayList(Frame) = .empty,
    visited: std.StringHashMapUnmanaged(void) = .empty,
    directories: usize = 1,
    last_path: ?[]u8 = null,

    const max_directories = 4096;
    const Mode = union(enum) { list, copy: []const u8 };
    const Frame = struct { dir: Dir, iter: Dir.Iterator, prefix: []u8, canonical: []u8 };
    const Entry = struct { path: []const u8, kind: std.Io.File.Kind, dir: Dir, basename: []const u8 };

    fn init(io: std.Io, alloc: std.mem.Allocator, base: Resolved, mode: Mode) !RootWalker {
        const dir = try base.openDirectory(io, alloc);
        errdefer dir.close(io);
        const prefix = try alloc.dupe(u8, "");
        errdefer alloc.free(prefix);
        var canonical_buf: [Dir.max_path_bytes]u8 = undefined;
        const canonical = try alloc.dupe(u8, canonical_buf[0..try dir.realPath(io, &canonical_buf)]);
        errdefer alloc.free(canonical);
        var self: RootWalker = .{ .alloc = alloc, .base = base, .mode = mode };
        errdefer self.stack.deinit(alloc);
        errdefer self.visited.deinit(alloc);
        if (mode == .list) try self.visited.put(alloc, canonical, {});
        try self.stack.append(alloc, .{ .dir = dir, .iter = dir.iterate(), .prefix = prefix, .canonical = canonical });
        return self;
    }

    fn deinit(self: *RootWalker, io: std.Io) void {
        while (self.stack.pop()) |frame| {
            frame.dir.close(io);
            self.alloc.free(frame.prefix);
            if (self.mode == .copy) self.alloc.free(frame.canonical);
        }
        if (self.last_path) |path| self.alloc.free(path);
        self.stack.deinit(self.alloc);
        var keys = self.visited.keyIterator();
        while (keys.next()) |key| self.alloc.free(key.*);
        self.visited.deinit(self.alloc);
    }

    /// Entry storage remains valid until the next call or deinit.
    fn next(self: *RootWalker, io: std.Io) !?Entry {
        if (self.last_path) |path| self.alloc.free(path);
        self.last_path = null;
        while (self.stack.items.len > 0) {
            const top = &self.stack.items[self.stack.items.len - 1];
            const entry = try top.iter.next(io) orelse {
                const frame = self.stack.pop().?;
                frame.dir.close(io);
                self.alloc.free(frame.prefix);
                if (self.mode == .copy) self.alloc.free(frame.canonical);
                continue;
            };
            const path = try std.fs.path.join(self.alloc, &.{ top.prefix, entry.name });
            errdefer self.alloc.free(path);
            const parent_dir = top.dir;
            // DT_UNKNOWN: ask the filesystem without following a link.
            var kind = if (entry.kind != .unknown) entry.kind else if (parent_dir.statFile(io, entry.name, .{ .follow_symlinks = false })) |st| st.kind else |_| .unknown;
            const linked = kind == .sym_link;
            if (linked) {
                const child = try childResolved(self.alloc, self.base, path);
                defer self.alloc.free(child.rel);
                defer self.alloc.free(child.abs);
                const st = if (self.mode == .copy) try child.stat(io, self.alloc) else try entryStat(io, self.alloc, parent_dir, entry.name, kind, child) orelse {
                    self.alloc.free(path);
                    continue;
                };
                if (st.kind == .directory) kind = .directory;
            }
            if (kind == .directory) {
                const opened = if (linked) blk: {
                    const child = try childResolved(self.alloc, self.base, path);
                    defer self.alloc.free(child.rel);
                    defer self.alloc.free(child.abs);
                    break :blk child.openDirectory(io, self.alloc);
                } else parent_dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                if (opened) |dir| enter: {
                    errdefer dir.close(io);
                    var canonical_buf: [Dir.max_path_bytes]u8 = undefined;
                    const canonical = try self.alloc.dupe(u8, canonical_buf[0..try dir.realPath(io, &canonical_buf)]);
                    errdefer self.alloc.free(canonical);
                    if (self.mode == .list) {
                        if (self.visited.contains(canonical)) {
                            self.alloc.free(canonical);
                            dir.close(io);
                            break :enter;
                        }
                    } else for (self.stack.items) |frame| {
                        if (std.mem.eql(u8, frame.canonical, canonical)) return error.InvalidParams;
                    }
                    if (self.mode == .copy) {
                        const destination = self.mode.copy;
                        if (std.mem.eql(u8, destination, canonical) or
                            (std.mem.startsWith(u8, destination, canonical) and destination.len > canonical.len and destination[canonical.len] == '/') or
                            (std.mem.startsWith(u8, canonical, destination) and canonical.len > destination.len and canonical[destination.len] == '/')) return error.InvalidParams;
                    }
                    if (self.directories >= max_directories) return error.InvalidParams;
                    const prefix = try self.alloc.dupe(u8, path);
                    errdefer self.alloc.free(prefix);
                    if (self.mode == .list) try self.visited.put(self.alloc, canonical, {});
                    errdefer {
                        if (self.mode == .list) _ = self.visited.remove(canonical);
                    }
                    try self.stack.append(self.alloc, .{ .dir = dir, .iter = dir.iterate(), .prefix = prefix, .canonical = canonical });
                    self.directories += 1;
                } else |err| switch (err) {
                    error.AccessDenied, error.PermissionDenied, error.NotFound, error.FileNotFound, error.NotDir, error.Forbidden => if (self.mode == .copy) return err,
                    else => return err,
                }
            }
            self.last_path = path;
            return .{ .path = path, .kind = kind, .dir = parent_dir, .basename = std.fs.path.basename(path) };
        }
        return null;
    }
};

fn accessError(err: anyerror) anyerror {
    return switch (err) {
        error.FileNotFound, error.NotDir => error.NotFound,
        error.SymLinkLoop, error.AccessDenied, error.PermissionDenied => error.Forbidden,
        error.NameTooLong, error.BadPathName, error.DirNotEmpty, error.PathAlreadyExists => error.InvalidParams,
        else => err,
    };
}

/// Lexically normalize a relative path: collapse "." and "" segments, resolve
/// ".." against the accumulated stack, and REJECT any ".." that would ascend
/// above the (virtual) root. Returns the normalized slash-joined relative path.
///
/// This is lexical normalization. Filesystem containment is enforced by
/// `Resolved` when opening a path.
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
/// roots and lexical escapes; `Resolved` checks symlinks when opening the path.
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
fn buildPathInfo(alloc: std.mem.Allocator, st: ?std.Io.File.Stat, permissions: []const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    if (st) |s| {
        try obj.put(alloc, "modified", .{ .float = mtimeSecs(s) });
        try obj.put(alloc, "size", .{ .integer = @intCast(s.size) });
        try obj.put(alloc, "permissions", .{ .string = permissions });
    } else {
        try obj.put(alloc, "modified", .{ .integer = 0 });
        try obj.put(alloc, "size", .{ .integer = 0 });
        try obj.put(alloc, "permissions", .{ .string = "" });
    }
    return .{ .object = obj };
}

const StatKind = enum { file, dir, other, missing };

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
    const resolved: Resolved = .{ .root = root, .rel = rel, .abs = abs };
    var item = try buildPathInfo(alloc, resolved.stat(io, alloc) catch null, root.permissions());
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
    const root_name = ((try webreq.optional([]const u8, params, "root")) orelse "gcodes");
    const root = ctx.findRoot(root_name) orelse return error.InvalidParams;

    var arr: std.json.Array = .init(alloc);
    const base: Resolved = .{ .root = root, .rel = "", .abs = root.path };
    var walker = RootWalker.init(io, alloc, base, .list) catch |err| switch (err) {
        error.FileNotFound, error.NotFound, error.NotDir => return .{ .array = arr },
        else => return err,
    };
    defer walker.deinit(io);
    const gcodes_only = std.mem.eql(u8, root_name, "gcodes");
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        // get_file_list lists only gcode extensions in the gcodes root.
        if (gcodes_only and !isGcodeExt(entry.basename)) continue;
        if (FileCtx.pathExcluded(ctx.excludes, root_name, entry.path)) continue;
        const rel = try alloc.dupe(u8, entry.path);
        const stat = try entryStat(io, alloc, entry.dir, entry.basename, entry.kind, .{ .root = root, .rel = rel, .abs = "" }) orelse continue;
        if (stat.kind != .file) continue;
        var info = try buildPathInfo(alloc, stat, if (entry.kind == .sym_link) "r" else root.permissions());
        try info.object.put(alloc, "path", .{ .string = rel });
        try arr.append(info);
    }
    // Moonraker sorts by `str.lower`; std.mem.sort is stable like `sorted`.
    std.mem.sort(std.json.Value, arr.items, {}, struct {
        fn lessThan(_: void, a: std.json.Value, b: std.json.Value) bool {
            return std.ascii.orderIgnoreCase(a.object.get("path").?.string, b.object.get("path").?.string) == .lt;
        }
    }.lessThan);
    return .{ .array = arr };
}

/// Stat a listed entry. In-root links are followed; a link that escapes the
/// root, dangles or loops yields null, as os.path.exists does for a broken
/// link. `child` is the entry's path from the root.
fn entryStat(io: std.Io, alloc: std.mem.Allocator, dir: Dir, name: []const u8, kind: std.Io.File.Kind, child: Resolved) !?std.Io.File.Stat {
    if (kind != .sym_link and kind != .unknown) return dir.statFile(io, name, .{ .follow_symlinks = false }) catch null;
    return child.stat(io, alloc) catch |err| switch (accessError(err)) {
        error.NotFound, error.Forbidden, error.InvalidParams => null,
        else => |e| e,
    };
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
    const path = ((try webreq.optional([]const u8, params, "path")) orelse "gcodes");
    const extended = ((try webreq.optional(bool, params, "extended")) orelse false);
    const resolved = try resolveRequestPath(ctx, alloc, path);

    var dirs: std.json.Array = .init(alloc);
    var files: std.json.Array = .init(alloc);

    var dir = resolved.openDirectory(io, alloc) catch |err| return accessError(err);
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const kind = if (entry.kind == .unknown) (dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue).kind else entry.kind;
        const child_rel = if (resolved.rel.len == 0) entry.name else try std.fmt.allocPrint(alloc, "{s}/{s}", .{ resolved.rel, entry.name });
        if (FileCtx.pathExcluded(ctx.excludes, resolved.root.name, child_rel)) continue;
        const child: Resolved = .{ .root = resolved.root, .rel = child_rel, .abs = "" };
        const stat = try entryStat(io, alloc, dir, entry.name, kind, child) orelse continue;
        var info = try buildPathInfo(alloc, stat, if (kind == .sym_link and stat.kind == .file) "r" else resolved.root.permissions());
        switch (stat.kind) {
            .directory => {
                try info.object.put(alloc, "dirname", .{ .string = try alloc.dupe(u8, entry.name) });
                try dirs.append(info);
            },
            .file => {
                if (extended and std.mem.eql(u8, resolved.root.name, "gcodes") and isGcodeExt(entry.name)) {
                    var metadata_params: std.json.ObjectMap = .empty;
                    try metadata_params.put(alloc, "filename", .{ .string = child_rel });
                    // A file without metadata is still listed (`gcode_metadata.get(rel, {})`).
                    if (handleMetadata(ctx_ptr, .{ .object = metadata_params }, alloc)) |metadata| {
                        var fields = metadata.object.iterator();
                        while (fields.next()) |field| try info.object.put(alloc, field.key_ptr.*, field.value_ptr.*);
                    } else |err| switch (err) {
                        error.MetadataNotAvailable => {},
                        else => return err,
                    }
                }
                try info.object.put(alloc, "filename", .{ .string = try alloc.dupe(u8, entry.name) });
                try files.append(info);
            },
            else => {},
        }
    }

    var out: std.json.ObjectMap = .empty;
    try out.put(alloc, "dirs", .{ .array = dirs });
    try out.put(alloc, "files", .{ .array = files });
    try out.put(alloc, "disk_usage", try diskUsage(alloc, dir));

    var root_info: std.json.ObjectMap = .empty;
    try root_info.put(alloc, "name", .{ .string = resolved.root.name });
    try root_info.put(alloc, "permissions", .{ .string = resolved.root.permissions() });
    try out.put(alloc, "root_info", .{ .object = root_info });

    return .{ .object = out };
}

/// `{ "total", "used", "free" }` matching shutil.disk_usage._asdict().
fn diskUsage(alloc: std.mem.Allocator, dir: Dir) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    var total: u64 = 0;
    var used: u64 = 0;
    var free: u64 = 0;
    // shutil.disk_usage raises on failure, so Moonraker answers 500 too.
    if (phobos_disk_usage(dir.handle, &total, &used, &free) != 0) return error.DiskUsageUnavailable;
    try obj.put(alloc, "total", .{ .integer = std.math.lossyCast(i64, total) });
    try obj.put(alloc, "used", .{ .integer = std.math.lossyCast(i64, used) });
    try obj.put(alloc, "free", .{ .integer = std.math.lossyCast(i64, free) });
    return .{ .object = obj };
}

/// Returns 0, or the fstatvfs errno with the outputs unchanged.
extern "c" fn phobos_disk_usage(fd: c_int, total: *u64, used: *u64, available: *u64) c_int;

// ---------------------------------------------------------------------------
// POST /server/files/directory (mkdir)
// ---------------------------------------------------------------------------

pub fn handlePostDirectory(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *FileCtx = @ptrCast(@alignCast(ctx_ptr));
    const io = try ctx.requireIo();
    const path = try webreq.required([]const u8, params, "path");
    const resolved = try resolveRequestPath(ctx, alloc, path);

    if (!resolved.root.full_access) return error.Forbidden;
    if (resolved.rel.len == 0) return error.Forbidden; // cannot recreate the root

    // os.mkdir: a missing parent or an existing entry is a 400 error.
    var parent = resolved.parent(io, alloc, .{}) catch |err| return switch (accessError(err)) {
        error.NotFound => error.InvalidParams,
        else => |e| e,
    };
    defer parent.close(io);
    parent.dir.createDir(io, parent.name, .default_dir) catch |err| return accessError(err);

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
    const path = try webreq.required([]const u8, params, "path");
    const force = ((try webreq.optional(bool, params, "force")) orelse false);
    const resolved = try resolveRequestPath(ctx, alloc, path);

    if (!resolved.root.full_access) return error.Forbidden;
    if (resolved.rel.len == 0) return error.Forbidden; // cannot delete root
    if (try resolvedKind(io, alloc, resolved) != .dir) return error.NotFound;
    if (force) try ctx.checkInUse(resolved, true);
    var parent = resolved.parent(io, alloc, .{}) catch |err| return accessError(err);
    defer parent.close(io);
    if (force) {
        parent.dir.deleteTree(io, parent.name) catch |err| return accessError(err);
    } else {
        parent.dir.deleteDir(io, parent.name) catch |err| return accessError(err);
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
    const source = try webreq.required([]const u8, params, "source");
    const dest = try webreq.required([]const u8, params, "dest");
    const src = try resolveRequestPath(ctx, alloc, source);
    const dst = try resolveRequestPath(ctx, alloc, dest);
    if (!dst.root.full_access) return error.Forbidden;
    const src_kind = try resolvedKind(io, alloc, src);
    if (src_kind == .missing) return error.NotFound;
    // file_manager.py checks the requested destination, then a moved source.
    const dst_kind = try resolvedKind(io, alloc, dst);
    if (dst_kind != .missing) try ctx.checkInUse(dst, dst_kind == .dir);
    if (is_move) {
        if (!src.root.full_access) return error.Forbidden;
        try ctx.checkInUse(src, src_kind == .dir);
    }
    var target = dst;
    if (dst_kind == .dir) {
        const base = std.fs.path.basename(src.abs);
        target.rel = try std.fs.path.join(alloc, &.{ dst.rel, base });
        target.abs = try std.fs.path.join(alloc, &.{ dst.abs, base });
    }
    if (std.mem.eql(u8, src.abs, target.abs)) return error.InvalidParams;
    if (src_kind == .dir and std.mem.startsWith(u8, target.abs, src.abs) and
        target.abs.len > src.abs.len and target.abs[src.abs.len] == '/') return error.InvalidParams;

    var action: []const u8 = undefined;
    if (is_move) {
        var sp = src.parent(io, alloc, .{}) catch |err| return accessError(err);
        defer sp.close(io);
        var dp = target.parent(io, alloc, .{}) catch |err| return accessError(err);
        defer dp.close(io);
        sp.dir.rename(sp.name, dp.dir, dp.name, io) catch |err| return accessError(err);
        action = if (src_kind == .dir) "move_dir" else "move_file";
    } else if (src_kind == .dir) {
        try copyTree(io, alloc, src, target);
        action = "create_dir";
    } else {
        action = if (try resolvedKind(io, alloc, target) == .file) "modify_file" else "create_file";
        src.copyTo(io, alloc, target) catch |err| return accessError(err);
    }
    const info = try buildNotifyInfo(io, alloc, action, target.root, target.rel, target.abs, if (is_move) .{ .root = src.root, .rel = src.rel } else null);
    emitFilelistChanged(ctx, io, alloc, info);
    return info;
}

fn resolvedKind(io: std.Io, alloc: std.mem.Allocator, path: Resolved) !StatKind {
    const info = path.stat(io, alloc) catch |err| switch (err) {
        error.FileNotFound, error.NotFound, error.NotDir => return .missing,
        else => return accessError(err),
    };
    return switch (info.kind) {
        .file => .file,
        .directory => .dir,
        else => .other,
    };
}

fn copyTree(io: std.Io, alloc: std.mem.Allocator, source: Resolved, destination: Resolved) !void {
    var target = try destination.parent(io, alloc, .{ .make_path = true, .follow_leaf = true });
    defer target.close(io);
    var source_dir = try source.openDirectory(io, alloc);
    defer source_dir.close(io);
    var source_buf: [Dir.max_path_bytes]u8 = undefined;
    var target_buf: [Dir.max_path_bytes]u8 = undefined;
    const source_real = source_buf[0..try source_dir.realPath(io, &source_buf)];
    const parent_real = target_buf[0..try target.dir.realPath(io, &target_buf)];
    const target_real = try std.fs.path.resolve(alloc, &.{ parent_real, target.name });
    defer alloc.free(target_real);
    if (std.mem.eql(u8, source_real, target_real) or
        (std.mem.startsWith(u8, target_real, source_real) and target_real.len > source_real.len and target_real[source_real.len] == '/')) return error.InvalidParams;
    try target.dir.createDirPath(io, target.name);
    var walker = try RootWalker.init(io, alloc, source, .{ .copy = target_real });
    defer walker.deinit(io);
    while (try walker.next(io)) |entry| {
        const from = try childResolved(alloc, source, entry.path);
        defer alloc.free(from.rel);
        defer alloc.free(from.abs);
        const to = try childResolved(alloc, destination, entry.path);
        defer alloc.free(to.rel);
        defer alloc.free(to.abs);
        switch (entry.kind) {
            .directory => {
                var parent = try to.parent(io, alloc, .{ .make_path = true, .follow_leaf = true });
                defer parent.close(io);
                try parent.dir.createDirPath(io, parent.name);
            },
            .file => try from.copyTo(io, alloc, to),
            // shutil.copytree copies the target of a linked file.
            .sym_link => if (try entryStat(io, alloc, entry.dir, entry.basename, entry.kind, from)) |st| {
                if (st.kind == .file) try from.copyTo(io, alloc, to);
            },
            else => {},
        }
    }
}

fn childResolved(alloc: std.mem.Allocator, base: Resolved, child: []const u8) !Resolved {
    const rel = try std.fs.path.join(alloc, &.{ base.rel, child });
    errdefer alloc.free(rel);
    return .{ .root = base.root, .rel = rel, .abs = try std.fs.path.join(alloc, &.{ base.abs, child }) };
}

// ---------------------------------------------------------------------------
// DELETE /server/files/delete_file → server.files.delete_file (WS-only)
// Also the implementation backing DELETE /server/files/<root>/<path>.
// ---------------------------------------------------------------------------

pub fn handleDeleteFile(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *FileCtx = @ptrCast(@alignCast(ctx_ptr));
    const path = try webreq.required([]const u8, params, "path");
    return deleteFileImpl(ctx, alloc, path);
}

pub fn deleteFileImpl(ctx: *FileCtx, alloc: std.mem.Allocator, path: []const u8) anyerror!std.json.Value {
    const io = try ctx.requireIo();
    const resolved = try resolveRequestPath(ctx, alloc, path);
    if (!resolved.root.full_access) return error.Forbidden;
    if (try resolvedKind(io, alloc, resolved) != .file) return error.NotFound;
    try ctx.checkInUse(resolved, false);
    var parent = resolved.parent(io, alloc, .{}) catch |err| return accessError(err);
    defer parent.close(io);
    parent.dir.deleteFile(io, parent.name) catch |err| return accessError(err);

    const info = try buildNotifyInfo(io, alloc, "delete_file", resolved.root, resolved.rel, resolved.abs, null);
    emitFilelistChanged(ctx, io, alloc, info);
    return info;
}

// ---------------------------------------------------------------------------
// GET /server/files/metadata → server.files.metadata
// ---------------------------------------------------------------------------
// Returns cached stat-derived and parsed gcode metadata.

pub fn handleMetadata(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *FileCtx = @ptrCast(@alignCast(ctx_ptr));
    const io = try ctx.requireIo();
    const filename = try webreq.required([]const u8, params, "filename");

    // Moonraker keeps metadata only for gcode files under the gcodes root;
    // anything else is 404 "Metadata not available for <filename>".
    if (!isGcodeExt(filename)) return error.MetadataNotAvailable;
    const req = try std.fmt.allocPrint(alloc, "gcodes/{s}", .{filename});
    const resolved = try resolveRequestPath(ctx, alloc, req);
    const file = resolved.openFile(io, alloc) catch |err| return switch (accessError(err)) {
        error.NotFound => error.MetadataNotAvailable,
        else => |e| e,
    };
    defer file.close(io);
    const st = try file.stat(io);
    const mtime = mtimeSecs(st);

    // Return the cached record if the file is unchanged (size + mtime). Avoids
    // re-reading 256 KiB + re-parsing the gcode header on every request.
    if (ctx.cachedMetadata(alloc, resolved.abs, st.size, mtime)) |cached| return cached;

    const value = try buildMetadata(io, ctx.gpa, alloc, file, st, resolved);
    ctx.cacheMetadata(resolved.abs, st.size, mtime, value);
    return value;
}

/// Build the metadata record with stat-derived fields plus deep gcode-parsed
/// fields (slicer, layer_height, estimated_time, filament_total, thumbnails,
/// temperatures). Reads the first 256 KiB of the file to extract comment-header
/// metadata via `gcode_metadata.parse`. `st` is the open file's stat.
/// Transient reads use gpa; only the returned JSON survives in response_alloc.
fn buildMetadata(io: std.Io, gpa: std.mem.Allocator, response_alloc: std.mem.Allocator, file: std.Io.File, st: std.Io.File.Stat, resolved: Resolved) !std.json.Value {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const alloc = scratch.allocator();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "size", .{ .integer = @intCast(st.size) });
    try obj.put(alloc, "modified", .{ .float = mtimeSecs(st) });
    try obj.put(alloc, "uuid", .{ .string = try stableUuid(alloc, resolved.rel) });
    try obj.put(alloc, "print_start_time", .null);
    try obj.put(alloc, "job_id", .null);
    try obj.put(alloc, "filename", .{ .string = resolved.rel });

    // Deep gcode header parsing: read up to 256 KiB of the file header
    // to extract slicer info, layer count, estimated time, filament usage,
    // temperatures, layer height, and embedded thumbnails. Real
    // PrusaSlicer/Orca/Bambu files carry their config block at the end, so
    // also scan the footer for est-time/filament/height/temps.
    const header_text = try readFileHeader(io, alloc, file, st.size);
    const footer_text = readFileFooter(io, alloc, file, st.size);
    const meta = gcode_metadata.parseFull(alloc, header_text, footer_text);

    try obj.put(alloc, "slicer", .{ .string = meta.slicer orelse "Unknown" });
    if (meta.slicer != null) {
        if (meta.slicer_version) |v| try obj.put(alloc, "slicer_version", .{ .string = v });
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
    try obj.put(alloc, "thumbnails", try thumbnailsJson(io, alloc, resolved, meta.thumbnails));

    return jv.deepCopy(response_alloc, .{ .object = obj });
}

/// Persist embedded PNGs atomically; the returned paths and JSON belong to alloc.
fn thumbnailsJson(io: std.Io, alloc: std.mem.Allocator, gcode: Resolved, thumbnails: []const gcode_metadata.Thumbnail) !std.json.Value {
    var thumbs: std.json.Array = try .initCapacity(alloc, thumbnails.len);
    if (!gcode.root.full_access) return .{ .array = thumbs };
    for (thumbnails) |t| {
        if (t.width <= 0 or t.height <= 0 or t.size != t.data.len) continue;
        const size = std.base64.standard.Decoder.calcSizeForSlice(t.data) catch continue;
        const image = try alloc.alloc(u8, size);
        std.base64.standard.Decoder.decode(image, t.data) catch continue;
        const relative_path = try std.fmt.allocPrint(alloc, ".thumbs/{s}-{d}x{d}.png", .{ std.fs.path.stem(gcode.rel), t.width, t.height });
        const image_rel = try std.fs.path.join(alloc, &.{ std.fs.path.dirname(gcode.rel) orelse "", relative_path });
        const target: Resolved = .{ .root = gcode.root, .rel = image_rel, .abs = "" };
        var parent = try target.parent(io, alloc, .{ .make_path = true });
        defer parent.close(io);
        var output = try parent.dir.createFileAtomic(io, parent.name, .{ .replace = true });
        defer output.deinit(io);
        try output.file.writePositionalAll(io, image, 0);
        try output.file.sync(io);
        try output.replace(io);
        var tobj: std.json.ObjectMap = .empty;
        try tobj.put(alloc, "width", .{ .integer = t.width });
        try tobj.put(alloc, "height", .{ .integer = t.height });
        try tobj.put(alloc, "size", .{ .integer = @intCast(size) });
        try tobj.put(alloc, "relative_path", .{ .string = relative_path });
        thumbs.appendAssumeCapacity(.{ .object = tobj });
    }
    return .{ .array = thumbs };
}

/// Read the first max_bytes of a file of `size` bytes into `alloc`-owned
/// memory. Returns an error if the file cannot be read (best-effort enrichment).
const header_max_bytes = 256 * 1024;
const footer_max_bytes = 32 * 1024;

fn readFileHeader(io: std.Io, alloc: std.mem.Allocator, file: std.Io.File, size: u64) ![]u8 {
    const buf = try alloc.alloc(u8, @intCast(@min(size, header_max_bytes)));
    errdefer alloc.free(buf);
    const got = try file.readPositionalAll(io, buf, 0);
    return alloc.realloc(buf, got);
}

/// Read the last `footer_max_bytes` of a file of `size` bytes (slicer config
/// block for PrusaSlicer/Orca/Bambu). Returns "" when the file is no larger
/// than the header window (the header already covers it).
fn readFileFooter(io: std.Io, alloc: std.mem.Allocator, file: std.Io.File, size: u64) []u8 {
    if (size <= header_max_bytes) return ""; // header already has the whole file
    const n: usize = @intCast(@min(size, @as(u64, footer_max_bytes)));
    const buf = alloc.alloc(u8, n) catch return "";
    const got = file.readPositionalAll(io, buf, size - n) catch {
        alloc.free(buf);
        return "";
    };
    return alloc.realloc(buf, got) catch {
        alloc.free(buf);
        return "";
    };
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
// Rebuild the metadata record from the file without consulting the cache
// (after validating the file exists and is a gcode file).

pub fn handleMetascan(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *FileCtx = @ptrCast(@alignCast(ctx_ptr));
    const io = try ctx.requireIo();
    const filename = try webreq.required([]const u8, params, "filename");
    const req = try std.fmt.allocPrint(alloc, "gcodes/{s}", .{filename});
    const resolved = try resolveRequestPath(ctx, alloc, req);
    const file = resolved.openFile(io, alloc) catch |err| return accessError(err);
    defer file.close(io);
    if (!isGcodeExt(filename)) return error.InvalidParams;
    const st = try file.stat(io);
    const value = try buildMetadata(io, ctx.gpa, alloc, file, st, resolved);
    ctx.cacheMetadata(resolved.abs, st.size, mtimeSecs(st), value);
    return value;
}

// ---------------------------------------------------------------------------
// GET /server/files/thumbnails → server.files.thumbnails
// ---------------------------------------------------------------------------
// Returns persisted thumbnail paths relative to the gcodes root.

pub fn handleThumbnails(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    // Moonraker get_str("filename") is 400 "No data for argument: filename"
    // when the argument is absent. A present empty string looks up metadata
    // and returns an empty list.
    const filename = (try webreq.optional([]const u8, params, "filename")) orelse return error.MissingFilename;
    if (filename.len == 0) return .{ .array = .init(alloc) };
    const metadata = handleMetadata(ctx_ptr, params, alloc) catch |err| switch (err) {
        error.MetadataNotAvailable => return .{ .array = .init(alloc) },
        else => return err,
    };
    const thumbs = metadata.object.get("thumbnails").?;
    for (thumbs.array.items) |*thumb| {
        if (thumb.object.fetchOrderedRemove("relative_path")) |entry| {
            const path = try std.fs.path.join(alloc, &.{ std.fs.path.dirname(filename) orelse "", entry.value.string });
            try thumb.object.put(alloc, "thumbnail_path", .{ .string = path });
        }
    }
    return thumbs;
}

// ---------------------------------------------------------------------------
// POST /server/files/zip → server.files.zip
// ---------------------------------------------------------------------------
// Archive creation uses a bounded source list and streaming native DEFLATE.
// Like the pinned file_manager, selected directories include immediate files.

pub fn handleZip(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *FileCtx = @ptrCast(@alignCast(ctx_ptr));
    const io = try ctx.requireIo();
    const requested = (try webreq.optionalList(alloc, params, "items")) orelse return error.InvalidParams;
    if (requested.len == 0 or requested.len > zip_writer.Archive.max_entries) return error.InvalidParams;
    const store_only = (try webreq.optional(bool, params, "store_only")) orelse false;
    var timestamp_buf: [32]u8 = undefined;
    const timestamp = @import("../util/clock.zig").iso8601(io, &timestamp_buf);
    const default_dest = try std.fmt.allocPrint(alloc, "config/collection-{s}{s}{s}-{s}{s}{s}.zip", .{ timestamp[0..4], timestamp[5..7], timestamp[8..10], timestamp[11..13], timestamp[14..16], timestamp[17..19] });
    const dest = (try webreq.optional([]const u8, params, "dest")) orelse default_dest;

    // The App can add roots while Core is released. Keep a stable snapshot;
    // all source-list and path-resolution allocations die with this operation.
    var scratch = std.heap.ArenaAllocator.init(ctx.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const roots = try a.alloc(Root, ctx.roots.len);
    for (ctx.roots, roots) |root, *copy| copy.* = .{ .name = try a.dupe(u8, root.name), .path = try a.dupe(u8, root.path), .full_access = root.full_access };
    const excludes = try a.alloc([]const u8, ctx.excludes.len);
    for (ctx.excludes, excludes) |exclude, *copy| copy.* = try a.dupe(u8, exclude);
    const snapshot: FileCtx = .{ .gpa = ctx.gpa, .roots = roots, .bus = null, .io = io, .excludes = excludes };
    const destination = try resolveRequestPath(&snapshot, a, dest);
    if (!destination.root.full_access or archiveReserved(snapshot.excludes, destination)) return error.Forbidden;
    if (destination.rel.len == 0) return error.InvalidParams;
    try ctx.checkInUse(destination, false);
    const core = if (ctx.bus) |bus| bus.core else null;
    if (core) |c| c.unlock(io);
    defer if (core) |c| c.lock(io);
    return createArchive(ctx, &snapshot, destination, requested, store_only, a, alloc) catch |err| switch (err) {
        error.ArchiveTooLarge => error.InvalidParams,
        else => accessError(err),
    };
}

fn archiveReserved(excludes: []const []const u8, path: Resolved) bool {
    if (FileCtx.pathExcluded(excludes, path.root.name, path.rel)) return true;
    var parts = std.mem.splitScalar(u8, path.rel, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, ".git")) return true;
    return false;
}

const ArchiveSources = struct {
    items: std.ArrayList(struct { resolved: Resolved, name: []const u8 }) = .empty,
    canonical: std.StringHashMapUnmanaged(void) = .empty,
    path_bytes: usize = 0,
    scanned: usize = 0,

    fn append(self: *ArchiveSources, io: std.Io, alloc: std.mem.Allocator, transient: std.mem.Allocator, resolved: Resolved) !void {
        var parent = try resolved.parent(io, transient, .{ .follow_leaf = true });
        defer parent.close(io);
        var canonical_buf: [Dir.max_path_bytes]u8 = undefined;
        const canonical = canonical_buf[0..try parent.dir.realPathFile(io, parent.name, &canonical_buf)];
        if (self.canonical.contains(canonical)) return;
        const name_len = resolved.root.name.len + 1 + resolved.rel.len;
        const bytes = canonical.len + name_len + resolved.abs.len + resolved.rel.len;
        if (self.items.items.len >= zip_writer.Archive.max_entries or bytes > zip_writer.Archive.max_names_bytes - self.path_bytes) return error.ArchiveTooLarge;
        const canonical_owned = try alloc.dupe(u8, canonical);
        try self.canonical.put(alloc, canonical_owned, {});
        const name = try std.fs.path.join(alloc, &.{ resolved.root.name, resolved.rel });
        const owned: Resolved = .{ .root = resolved.root, .rel = try alloc.dupe(u8, resolved.rel), .abs = try alloc.dupe(u8, resolved.abs) };
        try self.items.append(alloc, .{ .resolved = owned, .name = name });
        self.path_bytes += bytes;
    }
};

fn createArchive(ctx: *FileCtx, snapshot: *const FileCtx, destination: Resolved, requested: []const []const u8, store_only: bool, scratch: std.mem.Allocator, alloc: std.mem.Allocator) !std.json.Value {
    const io = try ctx.requireIo();
    try ctx.archive_mutex.lock(io);
    defer ctx.archive_mutex.unlock(io);
    var sources: ArchiveSources = .{};
    defer sources.items.deinit(scratch);
    defer sources.canonical.deinit(scratch);
    for (requested) |request| {
        var transient = std.heap.ArenaAllocator.init(ctx.gpa);
        defer transient.deinit();
        const a = transient.allocator();
        const source = try resolveRequestPath(snapshot, a, request);
        if (archiveReserved(snapshot.excludes, source)) return error.Forbidden;
        const info = source.stat(io, a) catch |err| return accessError(err);
        if (info.kind == .file) {
            try sources.append(io, scratch, a, source);
        } else if (info.kind == .directory) {
            const dir = try source.openDirectory(io, a);
            defer dir.close(io);
            var iter = dir.iterate();
            while (try iter.next(io)) |entry| {
                sources.scanned += 1;
                if (sources.scanned > 65536) return error.ArchiveTooLarge;
                // Resolve each file independently, including in-root links.
                // Missing, inaccessible and escaping children are omitted.
                if (entry.kind == .directory) continue;
                var child_arena = std.heap.ArenaAllocator.init(ctx.gpa);
                defer child_arena.deinit();
                const ca = child_arena.allocator();
                const child = try childResolved(ca, source, entry.name);
                if (archiveReserved(snapshot.excludes, child)) continue;
                const st = child.stat(io, ca) catch |err| switch (err) {
                    error.NotFound, error.FileNotFound, error.Forbidden, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => continue,
                    else => return err,
                };
                if (st.kind == .file) try sources.append(io, scratch, ca, child);
            }
        } else return error.InvalidParams;
    }
    // Stage the source list first, so the atomic temporary never archives itself.
    var parent = try destination.parent(io, scratch, .{});
    defer parent.close(io);
    if (parent.dir.statFile(io, parent.name, .{ .follow_symlinks = false })) |st| {
        if (st.kind == .directory) return error.InvalidParams;
        if (st.kind == .sym_link) return error.Forbidden;
    } else |err| if (err != error.FileNotFound) return err;
    var atomic = try parent.dir.createFileAtomic(io, parent.name, .{ .replace = true });
    defer atomic.deinit(io);
    var buf: [8192]u8 = undefined;
    var output = atomic.file.writer(io, &buf);
    var archive = zip_writer.Archive.init(ctx.gpa, &output, store_only);
    defer archive.deinit();
    for (sources.items.items) |source| {
        var source_arena = std.heap.ArenaAllocator.init(ctx.gpa);
        defer source_arena.deinit();
        const file = try source.resolved.openFile(io, source_arena.allocator());
        defer file.close(io);
        try archive.addFile(file, source.name);
    }
    try archive.finish();
    try atomic.file.sync(io);
    if (ctx.bus) |bus| return bus.core.run(io, commitArchive, .{ ctx, &atomic, destination, alloc });
    return commitArchive(ctx, &atomic, destination, alloc);
}

fn commitArchive(ctx: *FileCtx, atomic: *std.Io.File.Atomic, destination: Resolved, alloc: std.mem.Allocator) !std.json.Value {
    const io = try ctx.requireIo();
    // Printing may have started while compression ran outside Core.
    try ctx.checkInUse(destination, false);
    var item = try buildPathInfo(alloc, try atomic.file.stat(io), destination.root.permissions());
    try item.object.put(alloc, "path", .{ .string = try alloc.dupe(u8, destination.rel) });
    try item.object.put(alloc, "root", .{ .string = try alloc.dupe(u8, destination.root.name) });
    var notification: std.json.ObjectMap = .empty;
    try notification.put(alloc, "action", .{ .string = "create_file" });
    try notification.put(alloc, "item", item);
    var out: std.json.ObjectMap = .empty;
    try out.put(alloc, "destination", item);
    try out.put(alloc, "action", .{ .string = "zip_files" });
    try atomic.replace(io);
    emitFilelistChanged(ctx, io, alloc, .{ .object = notification });
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
    tmp: testing.TmpDir,
    io: std.Io,
    base_path: []u8,
    roots: [3]Root,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) !TestRoots {
        var tr: TestRoots = undefined;
        tr.alloc = alloc;
        tr.io = testing.io;
        tr.tmp = testing.tmpDir(.{});
        errdefer tr.tmp.cleanup();
        tr.base_path = try tr.tmp.dir.realPathFileAlloc(tr.io, ".", alloc);

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
        self.tmp.cleanup();
    }

    fn writeFile(self: *TestRoots, rel: []const u8, contents: []const u8) !void {
        const abs = try std.fs.path.join(self.alloc, &.{ self.base_path, rel });
        if (std.fs.path.dirname(abs)) |d| try Dir.cwd().createDirPath(self.io, d);
        try Dir.cwd().writeFile(self.io, .{ .sub_path = abs, .data = contents });
    }

    fn exists(self: *TestRoots, rel_to_base: []const u8) StatKind {
        const st = self.tmp.dir.statFile(self.io, rel_to_base, .{}) catch return .missing;
        return switch (st.kind) {
            .file => .file,
            .directory => .dir,
            else => .other,
        };
    }
};

fn objParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    return p.value;
}

// ---- normalizeRel / resolveRequestPath (path safety) ----

test "excludes omit a directory from the file list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var tr = try TestRoots.init(arena.allocator());
    defer tr.deinit();
    try tr.writeFile("gcodes/keep.gcode", "G1\n");
    try tr.writeFile("gcodes/.mod/secret.gcode", "G1\n");
    var c = tr.ctx();
    defer c.deinit();
    try c.setExcludes("gcodes/.mod\n");
    const listed = try handleList(@ptrCast(&c), try objParams(arena.allocator(), "{\"root\":\"gcodes\"}"), arena.allocator());
    var saw_keep = false;
    var saw_secret = false;
    for (listed.array.items) |item| {
        const path = item.object.get("path").?.string;
        if (std.mem.eql(u8, path, "keep.gcode")) saw_keep = true;
        if (std.mem.indexOf(u8, path, "secret.gcode") != null) saw_secret = true;
    }
    try testing.expect(saw_keep);
    try testing.expect(!saw_secret);
    try testing.expect(FileCtx.pathExcluded(c.excludes, "gcodes", ".mod/secret.gcode"));
}

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

test "file operations reject symlink escapes from their registered root" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tr = try TestRoots.init(alloc);
    defer tr.deinit();
    var ctx = tr.ctx();
    defer ctx.deinit();
    try tr.writeFile("config/secret.gcode", "secret\n");
    const target = try std.fs.path.join(alloc, &.{ tr.roots[1].path, "secret.gcode" });
    const link = try std.fs.path.join(alloc, &.{ tr.roots[0].path, "escape.gcode" });
    try Dir.cwd().symLink(tr.io, target, link, .{});
    try testing.expectError(error.Forbidden, handleMetadata(@ptrCast(&ctx), try objParams(alloc, "{\"filename\":\"escape.gcode\"}"), alloc));
    try testing.expect(!ctx.fileExists("gcodes", "escape.gcode"));
    try testing.expectError(error.Forbidden, handleCopy(@ptrCast(&ctx), try objParams(alloc, "{\"source\":\"gcodes/escape.gcode\",\"dest\":\"gcodes/copied.gcode\"}"), alloc));
    try testing.expectEqual(StatKind.missing, tr.exists("gcodes/copied.gcode"));
    try tr.writeFile("gcodes/inside.gcode", "inside\n");
    try tr.tmp.dir.symLink(tr.io, tr.roots[1].path, "gcodes/outside", .{});
    const cases = .{
        .{ handleGetDirectory, "{\"path\":\"gcodes/outside\"}" },
        .{ handlePostDirectory, "{\"path\":\"gcodes/outside/new\"}" },
        .{ handleDeleteDirectory, "{\"path\":\"gcodes/outside/sub\",\"force\":true}" },
        .{ handleDeleteFile, "{\"path\":\"gcodes/outside/secret.gcode\"}" },
        .{ handleMove, "{\"source\":\"gcodes/inside.gcode\",\"dest\":\"gcodes/outside/moved.gcode\"}" },
        .{ handleCopy, "{\"source\":\"gcodes/inside.gcode\",\"dest\":\"gcodes/outside/copied.gcode\"}" },
    };
    inline for (cases) |case| try testing.expectError(error.Forbidden, case[0](@ptrCast(&ctx), try objParams(alloc, case[1]), alloc));
    try testing.expectEqual(StatKind.file, tr.exists("config/secret.gcode"));
    try testing.expectEqual(StatKind.file, tr.exists("gcodes/inside.gcode"));
    try testing.expectEqual(StatKind.missing, tr.exists("config/new"));
    try testing.expectEqual(StatKind.missing, tr.exists("config/moved.gcode"));
    try testing.expectEqual(StatKind.missing, tr.exists("config/copied.gcode"));
}

test "root handles retain in-root aliases and reject link loops and recursive copies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tr = try TestRoots.init(alloc);
    defer tr.deinit();
    var ctx = tr.ctx();
    defer ctx.deinit();
    try tr.writeFile("gcodes/real/file.gcode", "G1\n");
    try tr.tmp.dir.symLink(tr.io, "real", "gcodes/alias", .{});
    const real = try std.fs.path.join(alloc, &.{ tr.roots[0].path, "real" });
    try tr.tmp.dir.symLink(tr.io, real, "gcodes/absolute", .{});
    for ([_][]const u8{ "alias/file.gcode", "absolute/file.gcode" }) |name| {
        const params = try std.fmt.allocPrint(alloc, "{{\"filename\":\"{s}\"}}", .{name});
        const metadata = try handleMetadata(@ptrCast(&ctx), try objParams(alloc, params), alloc);
        try testing.expectEqual(@as(i64, 3), metadata.object.get("size").?.integer);
        try testing.expectEqualStrings(name, metadata.object.get("filename").?.string);
    }
    try tr.writeFile("gcodes/target.gcode", "wrong\n");
    try tr.writeFile("gcodes/real/target.gcode", "correct\n");
    try tr.writeFile("gcodes/real/sub/empty.gcode", "");
    try tr.tmp.dir.symLink(tr.io, "real/sub", "gcodes/inner", .{});
    try tr.tmp.dir.symLink(tr.io, "inner/../target.gcode", "gcodes/indirect", .{});
    const indirect = try resolveRequestPath(&ctx, alloc, "gcodes/indirect");
    const opened = try indirect.openFile(tr.io, alloc);
    defer opened.close(tr.io);
    try testing.expectEqualStrings("correct\n", try readFileHeader(tr.io, alloc, opened, (try opened.stat(tr.io)).size));
    try tr.tmp.dir.symLink(tr.io, "loop_b.gcode", "gcodes/loop_a.gcode", .{});
    try tr.tmp.dir.symLink(tr.io, "loop_a.gcode", "gcodes/loop_b.gcode", .{});
    try testing.expectError(error.Forbidden, handleMetadata(@ptrCast(&ctx), try objParams(alloc, "{\"filename\":\"loop_a.gcode\"}"), alloc));
    const prefix_escape = try std.fmt.allocPrint(alloc, "{s}-outside/file.gcode", .{tr.roots[0].path});
    try tr.writeFile("gcodes-outside/file.gcode", "outside\n");
    try tr.tmp.dir.symLink(tr.io, prefix_escape, "gcodes/prefix_escape.gcode", .{});
    try testing.expectError(error.Forbidden, handleMetadata(@ptrCast(&ctx), try objParams(alloc, "{\"filename\":\"prefix_escape.gcode\"}"), alloc));
    try testing.expectError(error.InvalidParams, handleCopy(@ptrCast(&ctx), try objParams(alloc, "{\"source\":\"gcodes/real\",\"dest\":\"gcodes/alias/copy\"}"), alloc));
    try testing.expectEqual(StatKind.missing, tr.exists("gcodes/real/copy"));
    const copied = try handleCopy(@ptrCast(&ctx), try objParams(alloc, "{\"source\":\"gcodes/real\",\"dest\":\"gcodes/copied\"}"), alloc);
    try testing.expectEqualStrings("create_dir", copied.object.get("action").?.string);
    const file = try Dir.cwd().readFileAlloc(tr.io, try std.fs.path.join(alloc, &.{ tr.roots[0].path, "copied/file.gcode" }), alloc, .limited(32));
    try testing.expectEqualStrings("G1\n", file);
}

test "root traversal and copies release partial allocations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tr = try TestRoots.init(alloc);
    defer tr.deinit();
    var ctx = tr.ctx();
    try tr.writeFile("gcodes/source/sub/file.gcode", "G28\n");
    const source = try resolveRequestPath(&ctx, alloc, "gcodes/source");
    const destination = try resolveRequestPath(&ctx, alloc, "gcodes/destination");
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator, aio: std.Io, from: Resolved, to: Resolved) !void {
            var walker = try RootWalker.init(aio, gpa, from, .list);
            defer walker.deinit(aio);
            var count: usize = 0;
            while (try walker.next(aio)) |_| count += 1;
            try testing.expectEqual(@as(usize, 2), count);
            try copyTree(aio, gpa, from, to);
        }
    }.run, .{ tr.io, source, destination });
}

test "listings follow in-root links and skip escaping or dangling ones" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tr = try TestRoots.init(alloc);
    defer tr.deinit();
    var ctx = tr.ctx();
    defer ctx.deinit();
    var vtable = testing.io.vtable.*;
    vtable.dirRead = struct {
        fn read(userdata: ?*anyopaque, reader: *Dir.Reader, entries: []Dir.Entry) Dir.Reader.Error!usize {
            const count = try testing.io.vtable.dirRead(userdata, reader, entries);
            for (entries[0..count]) |*entry| entry.kind = .unknown;
            return count;
        }
    }.read;
    ctx.io = .{ .userdata = testing.io.userdata, .vtable = &vtable };
    try tr.writeFile("gcodes/real/file.gcode", "G1\n");
    try tr.writeFile("gcodes/Zeta.gcode", "G1\n");
    try tr.writeFile("gcodes/notes.txt", "x\n");
    try tr.writeFile("config/secret.gcode", "secret\n");
    try tr.tmp.dir.symLink(tr.io, "real", "gcodes/alias", .{});
    try tr.tmp.dir.symLink(tr.io, "real/file.gcode", "gcodes/link.gcode", .{});
    try tr.tmp.dir.symLink(tr.io, "file.gcode", "gcodes/real/inner.gcode", .{});
    try tr.tmp.dir.symLink(tr.io, "missing.gcode", "gcodes/dangling.gcode", .{});
    var long_component: [Dir.max_name_bytes + 1]u8 = undefined;
    @memset(&long_component, 'x');
    try tr.tmp.dir.symLink(tr.io, &long_component, "gcodes/too-long.gcode", .{});
    try tr.tmp.dir.symLink(tr.io, tr.roots[1].path, "gcodes/outside", .{});
    const secret = try std.fs.path.join(alloc, &.{ tr.roots[1].path, "secret.gcode" });
    try tr.tmp.dir.symLink(tr.io, secret, "gcodes/escape.gcode", .{});

    const listing = try handleGetDirectory(@ptrCast(&ctx), try objParams(alloc, "{\"path\":\"gcodes\"}"), alloc);
    var names: std.ArrayList(u8) = .empty;
    for (listing.object.get("dirs").?.array.items) |d| try names.print(alloc, "d:{s} ", .{d.object.get("dirname").?.string});
    for (listing.object.get("files").?.array.items) |f| {
        try names.print(alloc, "f:{s} ", .{f.object.get("filename").?.string});
        if (std.mem.eql(u8, f.object.get("filename").?.string, "link.gcode")) try testing.expectEqualStrings("r", f.object.get("permissions").?.string);
    }
    for ([_][]const u8{ "d:real ", "d:alias ", "f:link.gcode ", "f:Zeta.gcode " }) |want| {
        try testing.expect(std.mem.indexOf(u8, names.items, want) != null);
    }
    for ([_][]const u8{ "dangling", "escape", "outside", "too-long" }) |hidden| {
        try testing.expect(std.mem.indexOf(u8, names.items, hidden) == null);
    }

    // Directory aliases are visited once; gcode paths are sorted case-insensitively.
    const list = try handleList(@ptrCast(&ctx), try objParams(alloc, "{\"root\":\"gcodes\"}"), alloc);
    const expected = [_][]const u8{ "link.gcode", "real/file.gcode", "real/inner.gcode", "Zeta.gcode" };
    try testing.expectEqual(expected.len, list.array.items.len);
    for (expected, list.array.items) |want, got| try testing.expectEqualStrings(want, got.object.get("path").?.string);
    try testing.expectEqual(@as(i64, 3), list.array.items[2].object.get("size").?.integer);
    try testing.expectEqualStrings("r", list.array.items[0].object.get("permissions").?.string);

    _ = try handleCopy(@ptrCast(&ctx), try objParams(alloc, "{\"source\":\"gcodes/real\",\"dest\":\"gcodes/copied\"}"), alloc);
    const inner = try std.fs.path.join(alloc, &.{ tr.roots[0].path, "copied/inner.gcode" });
    try testing.expectEqualStrings("G1\n", try Dir.cwd().readFileAlloc(tr.io, inner, alloc, .limited(16)));
}

test "server.files.list skips a directory it cannot open" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tr = try TestRoots.init(alloc);
    defer tr.deinit();
    var ctx = tr.ctx();
    try tr.writeFile("gcodes/open.gcode", "G1\n");
    try tr.writeFile("gcodes/locked/hidden.gcode", "G1\n");
    var vtable = testing.io.vtable.*;
    vtable.dirOpenDir = struct {
        fn open(userdata: ?*anyopaque, dir: Dir, name: []const u8, options: Dir.OpenOptions) Dir.OpenError!Dir {
            if (std.mem.eql(u8, name, "locked")) return error.AccessDenied;
            return testing.io.vtable.dirOpenDir(userdata, dir, name, options);
        }
    }.open;
    ctx.io = .{ .userdata = testing.io.userdata, .vtable = &vtable };
    const list = try handleList(@ptrCast(&ctx), try objParams(alloc, "{\"root\":\"gcodes\"}"), alloc);
    var saw_open = false;
    for (list.array.items) |item| {
        if (std.mem.eql(u8, item.object.get("path").?.string, "open.gcode")) saw_open = true;
        try testing.expect(!std.mem.endsWith(u8, item.object.get("path").?.string, "hidden.gcode"));
    }
    try testing.expect(saw_open);
}

test "linked directories are listed once and copied with their contents" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    var ctx = tr.ctx();
    defer ctx.deinit();
    try tr.writeFile("gcodes/target/file.gcode", "G28\n");
    try tr.tmp.dir.createDirPath(tr.io, "gcodes/source");
    try tr.tmp.dir.symLink(tr.io, "../target", "gcodes/source/alias", .{});
    try tr.tmp.dir.symLink(tr.io, "../target", "gcodes/source/second", .{});
    const list = try handleList(@ptrCast(&ctx), try objParams(a, "{\"root\":\"gcodes\"}"), a);
    try testing.expectEqual(@as(usize, 1), list.array.items.len);
    const listed = list.array.items[0].object.get("path").?.string;
    try testing.expect(std.mem.eql(u8, listed, "source/alias/file.gcode") or std.mem.eql(u8, listed, "source/second/file.gcode") or std.mem.eql(u8, listed, "target/file.gcode"));
    _ = try handleCopy(@ptrCast(&ctx), try objParams(a, "{\"source\":\"gcodes/source\",\"dest\":\"gcodes/copy\"}"), a);
    const copied = try std.fs.path.join(a, &.{ tr.roots[0].path, "copy/alias/file.gcode" });
    try testing.expectEqualStrings("G28\n", try Dir.cwd().readFileAlloc(tr.io, copied, a, .limited(32)));
    const second = try std.fs.path.join(a, &.{ tr.roots[0].path, "copy/second/file.gcode" });
    try testing.expectEqualStrings("G28\n", try Dir.cwd().readFileAlloc(tr.io, second, a, .limited(32)));
}

test "linked copy cycles and links into the output are rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    var ctx = tr.ctx();
    defer ctx.deinit();
    try tr.writeFile("gcodes/source/file.gcode", "G28\n");
    try tr.tmp.dir.symLink(tr.io, ".", "gcodes/source/loop", .{});
    const list = try handleList(@ptrCast(&ctx), try objParams(a, "{\"root\":\"gcodes\"}"), a);
    try testing.expectEqual(@as(usize, 1), list.array.items.len);
    try testing.expectError(error.InvalidParams, handleCopy(@ptrCast(&ctx), try objParams(a, "{\"source\":\"gcodes/source\",\"dest\":\"gcodes/copy\"}"), a));
    try tr.tmp.dir.deleteFile(tr.io, "gcodes/source/loop");
    try tr.tmp.dir.symLink(tr.io, "../copy", "gcodes/source/output", .{});
    try testing.expectError(error.InvalidParams, handleCopy(@ptrCast(&ctx), try objParams(a, "{\"source\":\"gcodes/source\",\"dest\":\"gcodes/copy\"}"), a));
}

test "root traversal refuses directories beyond its work limit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    var ctx = tr.ctx();
    try tr.writeFile("gcodes/sub/file.gcode", "G28\n");
    const base = try resolveRequestPath(&ctx, a, "gcodes");
    var walker = try RootWalker.init(tr.io, testing.allocator, base, .list);
    defer walker.deinit(tr.io);
    walker.directories = RootWalker.max_directories;
    try testing.expectError(error.InvalidParams, walker.next(tr.io));
}

test "fuzz root traversal: linked directories cannot escape or recurse forever" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var tr = try TestRoots.init(a);
            defer tr.deinit();
            var ctx = tr.ctx();
            defer ctx.deinit();
            try tr.writeFile("gcodes/source/local.gcode", "inside\n");
            try tr.writeFile("gcodes/target/linked.gcode", "linked\n");
            try tr.writeFile("config/secret.gcode", "outside\n");
            const targets = [_][]const u8{ "../target", ".", "..", "../../config", "missing", "../copy" };
            const target = targets[smith.value(u8) % targets.len];
            try tr.tmp.dir.symLink(tr.io, target, "gcodes/source/alias", .{});
            const list = try handleList(@ptrCast(&ctx), try objParams(a, "{\"root\":\"gcodes\"}"), a);
            try testing.expectEqual(@as(usize, 2), list.array.items.len);
            for (list.array.items) |item| try testing.expect(!std.mem.endsWith(u8, item.object.get("path").?.string, "secret.gcode"));
            const params = try objParams(a, "{\"source\":\"gcodes/source\",\"dest\":\"gcodes/copy\"}");
            if (handleCopy(@ptrCast(&ctx), params, a)) |_| {
                try testing.expectEqualStrings("../target", target);
                const path = try std.fs.path.join(a, &.{ tr.roots[0].path, "copy/alias/linked.gcode" });
                try testing.expectEqualStrings("linked\n", try Dir.cwd().readFileAlloc(tr.io, path, a, .limited(32)));
            } else |err| switch (err) {
                error.InvalidParams, error.NotFound, error.FileNotFound, error.Forbidden => {},
                else => return err,
            }
        }
    }.run, .{});
}

test "file changes unlock a paused gcode after Klippy shutdown" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    try tr.writeFile("gcodes/print.gcode", "G28\n");
    var js = job_state_component.JobStateCtx.init(testing.allocator);
    defer js.deinit();
    var info: ServerInfo = .{ .klippy_state = "ready", .io = tr.io };
    var ctx = tr.ctx();
    ctx.job_state = &js;
    ctx.server_info = &info;
    js.statusUpdate(try objParams(a, "{\"state\":\"paused\",\"filename\":\"print.gcode\"}"));
    const params = try objParams(a, "{\"path\":\"gcodes/print.gcode\"}");
    try testing.expectError(error.FileInUse, handleDeleteFile(@ptrCast(&ctx), params, a));
    info.klippy_state = "shutdown";
    _ = try handleDeleteFile(@ptrCast(&ctx), params, a);
    try testing.expectEqual(StatKind.missing, tr.exists("gcodes/print.gcode"));
}

test "fuzz root file access: links cannot expose another registered root" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            var tr = try TestRoots.init(alloc);
            defer tr.deinit();
            var ctx = tr.ctx();
            defer ctx.deinit();
            try tr.writeFile("gcodes/sub/file.gcode", "inside\n");
            try tr.writeFile("config/file.gcode", "outside\n");
            const segments = [_][]const u8{ "sub", "..", ".", "config", "file.gcode", "alias" };
            var target: std.ArrayList(u8) = .empty;
            for (0..1 + smith.value(u8) % 8) |_| {
                if (target.items.len != 0) try target.append(alloc, '/');
                try target.appendSlice(alloc, segments[smith.value(u8) % segments.len]);
            }
            try tr.tmp.dir.symLink(tr.io, target.items, "gcodes/alias", .{});
            const path = try resolveRequestPath(&ctx, alloc, "gcodes/alias");
            const file = path.openFile(tr.io, alloc) catch return;
            defer file.close(tr.io);
            try testing.expectEqualStrings("inside\n", try readFileHeader(tr.io, alloc, file, (try file.stat(tr.io)).size));
            var parent = try path.parent(tr.io, alloc, .{ .follow_leaf = true });
            defer parent.close(tr.io);
            const canonical = try parent.dir.realPathFileAlloc(tr.io, parent.name, alloc);
            try testing.expect(std.mem.startsWith(u8, canonical, tr.roots[0].path));
            try testing.expectEqual(@as(u64, 7), (try path.stat(tr.io, alloc)).size);
        }
    }.run, .{});
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
    const total = du.get("total").?.integer;
    const used = du.get("used").?.integer;
    const free = du.get("free").?.integer;
    try testing.expect(total > 0);
    try testing.expect(used >= 0 and free >= 0);
    try testing.expect(used + free <= total);
    const ri = o.get("root_info").?.object;
    try testing.expectEqualStrings("gcodes", ri.get("name").?.string);
    try testing.expectEqualStrings("rw", ri.get("permissions").?.string);
    try testing.expectEqual(@as(usize, 1), o.get("dirs").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), o.get("files").?.array.items.len);
}

test "diskUsage: an invalid directory is an error, not zero byte counts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.DiskUsageUnavailable, diskUsage(arena.allocator(), .{ .handle = -1 }));
}

test "handleGetDirectory: extended gcodes include metadata and preserve basenames" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    const gcode = "; generated by PrusaSlicer 2.7.4 on 2024-01-15 at 08:30:00 UTC\n; estimated printing time (normal mode) = 5025s\n";
    try tr.writeFile("gcodes/sub/print.gcode", gcode);
    try tr.writeFile("config/print.gcode", gcode);
    var c = tr.ctx();
    defer c.deinit();

    const plain = try handleGetDirectory(@ptrCast(&c), try objParams(a, "{\"path\":\"gcodes/sub\"}"), a);
    try testing.expect(plain.object.get("files").?.array.items[0].object.get("slicer") == null);
    const extended = try handleGetDirectory(@ptrCast(&c), try objParams(a, "{\"path\":\"gcodes/sub\",\"extended\":true}"), a);
    const file = extended.object.get("files").?.array.items[0].object;
    try testing.expectEqualStrings("print.gcode", file.get("filename").?.string);
    try testing.expectEqualStrings("rw", file.get("permissions").?.string);
    try testing.expect(file.get("slicer") != null);
    try testing.expectEqualStrings("PrusaSlicer", file.get("slicer").?.string);
    try testing.expectEqual(@as(f64, 5025), file.get("estimated_time").?.float);
    try testing.expectEqual(@as(usize, 1), c.metadata_cache.count());

    const config = try handleGetDirectory(@ptrCast(&c), try objParams(a, "{\"path\":\"config\",\"extended\":\"true\"}"), a);
    try testing.expect(config.object.get("files").?.array.items[0].object.get("slicer") == null);
}

test "fuzz diskUsage: directory handles return bounded byte counts" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const dir: Dir = if (smith.valueWithHash(bool, 0))
                try Dir.cwd().openDir(testing.io, ".", .{ .iterate = true })
            else
                .{ .handle = -1 };
            defer if (dir.handle != -1) dir.close(testing.io);
            const result = diskUsage(a, dir) catch |err| {
                try testing.expect(dir.handle == -1 and err == error.DiskUsageUnavailable);
                return;
            };
            const total = result.object.get("total").?.integer;
            const used = result.object.get("used").?.integer;
            const free = result.object.get("free").?.integer;
            try testing.expect(total >= 0 and used >= 0 and free >= 0);
            try testing.expect(used + free <= total);
        }
    }.run, .{});
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

    // os.mkdir semantics: no parents, no existing entry.
    try testing.expectError(error.InvalidParams, handlePostDirectory(@ptrCast(&c), try objParams(a, "{\"path\":\"gcodes/newdir\"}"), a));
    try testing.expectError(error.InvalidParams, handlePostDirectory(@ptrCast(&c), try objParams(a, "{\"path\":\"gcodes/missing/child\"}"), a));
    try testing.expectEqual(StatKind.missing, tr.exists("gcodes/missing"));
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
    const destination = try std.fs.path.join(a, &.{ tr.roots[0].path, "dst.gcode" });
    try testing.expectEqualStrings("G28\n", try Dir.cwd().readFileAlloc(tr.io, destination, a, .limited(32)));
    try tr.writeFile("gcodes/src.gcode", "G1 X1\n");
    const r2 = try handleCopy(@ptrCast(&c), try objParams(a, "{\"source\":\"gcodes/src.gcode\",\"dest\":\"gcodes/dst.gcode\"}"), a);
    try testing.expectEqualStrings("modify_file", r2.object.get("action").?.string);
    try testing.expectEqualStrings("G1 X1\n", try Dir.cwd().readFileAlloc(tr.io, destination, a, .limited(32)));
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
    const file = try Dir.cwd().openFile(tr.io, try std.fs.path.join(a, &.{ tr.roots[0].path, "a.gcode" }), .{});
    defer file.close(tr.io);
    const md = try buildMetadata(tr.io, testing.allocator, a, file, try file.stat(tr.io), .{ .root = tr.roots[0], .rel = "a.gcode", .abs = "" });
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

test "file changes refuse the gcode loaded by an active print" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    try tr.writeFile("gcodes/sub/print.gcode", "G28\n");
    try tr.writeFile("gcodes/other.gcode", "G1\n");
    try tr.writeFile("config/print.gcode", "G1\n");
    var js = job_state_component.JobStateCtx.init(testing.allocator);
    defer js.deinit();
    var c = tr.ctx();
    c.job_state = &js;
    var ps: std.json.ObjectMap = .empty;
    try ps.put(a, "state", .{ .string = "printing" });
    try ps.put(a, "filename", .{ .string = "sub/print.gcode" });
    js.statusUpdate(.{ .object = ps });

    const refused = .{
        .{ handleDeleteFile, "{\"path\":\"gcodes/sub/print.gcode\"}" },
        .{ handleDeleteDirectory, "{\"path\":\"gcodes/sub\",\"force\":true}" },
        .{ handleMove, "{\"source\":\"gcodes/sub/print.gcode\",\"dest\":\"gcodes/moved.gcode\"}" },
        .{ handleMove, "{\"source\":\"gcodes/sub\",\"dest\":\"gcodes/moved\"}" },
        .{ handleCopy, "{\"source\":\"gcodes/other.gcode\",\"dest\":\"gcodes/sub/print.gcode\"}" },
        .{ handleCopy, "{\"source\":\"gcodes/other.gcode\",\"dest\":\"gcodes/sub\"}" },
    };
    inline for (refused) |case| try testing.expectError(error.FileInUse, case[0](@ptrCast(&c), try objParams(a, case[1]), a));
    try testing.expectEqual(StatKind.file, tr.exists("gcodes/sub/print.gcode"));
    try testing.expectEqual(StatKind.missing, tr.exists("gcodes/sub/other.gcode"));
    // Other roots and other files stay writable.
    _ = try handleDeleteFile(@ptrCast(&c), try objParams(a, "{\"path\":\"config/print.gcode\"}"), a);
    _ = try handleCopy(@ptrCast(&c), try objParams(a, "{\"source\":\"gcodes/other.gcode\",\"dest\":\"gcodes/copy.gcode\"}"), a);

    ps.getPtr("state").?.* = .{ .string = "complete" };
    js.statusUpdate(.{ .object = ps });
    _ = try handleDeleteFile(@ptrCast(&c), try objParams(a, "{\"path\":\"gcodes/sub/print.gcode\"}"), a);
}

test "fuzz checkInUse: only an active print blocks its file and parent directories" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var js = job_state_component.JobStateCtx.init(testing.allocator);
            defer js.deinit();
            const roots = [_]Root{.{ .name = "gcodes", .path = "/srv/gcodes", .full_access = true }};
            const ready = smith.value(bool);
            var info: ServerInfo = .{ .klippy_state = if (ready) "ready" else "shutdown" };
            const c: FileCtx = .{ .gpa = testing.allocator, .roots = &roots, .bus = null, .job_state = &js, .server_info = &info };
            const alphabet = "ab/";
            var lbuf: [6]u8 = undefined;
            var rbuf: [6]u8 = undefined;
            for (&lbuf) |*ch| ch.* = alphabet[smith.value(u8) % alphabet.len];
            for (&rbuf) |*ch| ch.* = alphabet[smith.value(u8) % alphabet.len];
            const loaded = lbuf[0 .. smith.value(u8) % (lbuf.len + 1)];
            const rel = rbuf[0 .. smith.value(u8) % (rbuf.len + 1)];
            const states = [_][]const u8{ "printing", "paused", "standby", "complete" };
            const state = states[smith.value(u8) % states.len];
            var ps: std.json.ObjectMap = .empty;
            try ps.put(a, "state", .{ .string = state });
            try ps.put(a, "filename", .{ .string = loaded });
            js.statusUpdate(.{ .object = ps });
            const is_dir = smith.value(bool);
            const blocked = if (c.checkInUse(.{ .root = roots[0], .rel = rel, .abs = "" }, is_dir)) |_| false else |_| true;
            const name = std.mem.trimStart(u8, loaded, "/");
            if (!ready or !js.isActive() or name.len == 0) return testing.expect(!blocked);
            if (!is_dir) return testing.expectEqual(std.mem.eql(u8, name, rel), blocked);
            if (blocked and rel.len > 0) try testing.expect(std.mem.startsWith(u8, name, rel));
            if (std.mem.eql(u8, name, rel)) try testing.expect(!blocked);
        }
    }.run, .{});
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

test "extended directory metadata releases per-file parsing buffers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    const header = "; generated by PrusaSlicer 2.7.4 on 2026-10-20 at 12:00:00 UTC\n; thumbnail begin 1x1 4\n; QUJD\n; thumbnail end\n";
    const footer = "; estimated printing time (normal mode) = 5s\n; layer_height = 0.2\n";
    const body = try a.alloc(u8, header_max_bytes + footer_max_bytes + 64);
    @memset(body, '\n');
    @memcpy(body[0..header.len], header);
    @memcpy(body[body.len - footer.len ..], footer);
    var memory = testing.FailingAllocator.init(testing.allocator, .{});
    var peak_retained: usize = 0;
    const retained_limit = 128 * 1024;
    {
        var ctx = tr.ctx();
        ctx.gpa = memory.allocator();
        defer ctx.deinit();
        var written: usize = 0;
        for ([_]usize{ 1, 8 }) |count| {
            while (written < count) : (written += 1) try tr.writeFile(try std.fmt.allocPrint(a, "gcodes/m{d}.gcode", .{written}), body);
            var response = std.heap.ArenaAllocator.init(memory.allocator());
            defer response.deinit();
            const output = try handleGetDirectory(@ptrCast(&ctx), try objParams(response.allocator(), "{\"path\":\"gcodes\",\"extended\":true}"), response.allocator());
            const files = output.object.get("files").?.array.items;
            try testing.expectEqual(count, files.len);
            for (files) |file| {
                try testing.expectEqualStrings("PrusaSlicer", file.object.get("slicer").?.string);
                try testing.expectEqualStrings("2.7.4", file.object.get("slicer_version").?.string);
                try testing.expectEqual(@as(f64, 5), file.object.get("estimated_time").?.float);
                const thumbnail = file.object.get("thumbnails").?.array.items[0].object;
                try testing.expect(std.mem.endsWith(u8, thumbnail.get("relative_path").?.string, "-1x1.png"));
                try testing.expectEqual(@as(i64, 3), thumbnail.get("size").?.integer);
            }
            const live = memory.allocated_bytes - memory.freed_bytes;
            peak_retained = @max(peak_retained, live);
            if (live > retained_limit) std.debug.print("metadata retains {d} bytes for {d} files\n", .{ live, count });
        }
    }
    try testing.expectEqual(memory.allocated_bytes, memory.freed_bytes);
    try testing.expect(peak_retained <= retained_limit);
}

test "metadata releases parsing buffers when copying its response fails" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    try tr.writeFile("gcodes/m.gcode", "; generated by PrusaSlicer 2.7.4 on 2026-10-20\nG28\n");
    const file = try tr.tmp.dir.openFile(tr.io, "gcodes/m.gcode", .{});
    defer file.close(tr.io);
    var scratch_memory = testing.FailingAllocator.init(testing.allocator, .{});
    var failed_response = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var response = std.heap.ArenaAllocator.init(failed_response.allocator());
    defer response.deinit();
    try testing.expectError(error.OutOfMemory, buildMetadata(tr.io, scratch_memory.allocator(), response.allocator(), file, try file.stat(tr.io), .{ .root = tr.roots[0], .rel = "m.gcode", .abs = "" }));
    try testing.expect(scratch_memory.allocated_bytes > 0);
    try testing.expectEqual(scratch_memory.allocated_bytes, scratch_memory.freed_bytes);
}

test "fuzz metadata snapshots: parsed strings survive scratch teardown" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var tr = try TestRoots.init(a);
            defer tr.deinit();
            var ctx = tr.ctx();
            ctx.gpa = testing.allocator;
            defer ctx.deinit();
            var version_buf: [32]u8 = undefined;
            const version = try std.fmt.bufPrint(&version_buf, "{d}.{d}.{d}", .{ smith.value(u8), smith.value(u8), smith.value(u8) });
            var tail: [256]u8 = undefined;
            smith.bytesWithHash(&tail, 0);
            const body = try std.fmt.allocPrint(a, "; generated by PrusaSlicer {s} on 2026-10-20\n; thumbnail begin 1x1 4\n; QUJD\n; thumbnail end\n{s}", .{ version, tail[0..smith.value(u8)] });
            try tr.writeFile("gcodes/m.gcode", body);
            const value = try handleMetascan(@ptrCast(&ctx), try objParams(a, "{\"filename\":\"m.gcode\"}"), a);
            try testing.expectEqualStrings(version, value.object.get("slicer_version").?.string);
            try testing.expectEqualStrings(".thumbs/m-1x1.png", value.object.get("thumbnails").?.array.items[0].object.get("relative_path").?.string);
        }
    }.run, .{});
}

test "handleMetadata: thumbnail-heavy records keep the cache under its byte cap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    var c = tr.ctx();
    defer c.deinit();
    const thumb_len = 200 * 1024;
    const body = try a.alloc(u8, thumb_len);
    @memset(body, 'A');
    const gcode = try std.fmt.allocPrint(a, "; thumbnail begin 1x1 {d}\n; {s}\n; thumbnail end\n", .{ thumb_len, body });
    const names = [_][]const u8{ "t0.gcode", "t1.gcode", "t2.gcode", "t3.gcode" };
    for (names) |name| try tr.writeFile(try std.fmt.allocPrint(a, "gcodes/{s}", .{name}), gcode);
    for (names) |name| {
        const params = try objParams(a, try std.fmt.allocPrint(a, "{{\"filename\":\"{s}\"}}", .{name}));
        for (0..2) |_| {
            const md = try handleMetadata(@ptrCast(&c), params, a);
            try testing.expectEqual(@as(i64, thumb_len / 4 * 3), md.object.get("thumbnails").?.array.items[0].object.get("size").?.integer);
        }
        try testing.expect(c.metadata_cache_bytes <= metadata_cache_max_bytes);
        var sum: usize = 0;
        var it = c.metadata_cache.valueIterator();
        while (it.next()) |e| sum += e.bytes;
        try testing.expectEqual(sum, c.metadata_cache_bytes);
    }
    try testing.expectEqual(names.len, c.metadata_cache.count());
}

test "handleMetadata: missing file → MetadataNotAvailable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    var c = tr.ctx();
    try testing.expectError(error.MetadataNotAvailable, handleMetadata(@ptrCast(&c), try objParams(a, "{\"filename\":\"none.gcode\"}"), a));

    // file_manager.py: 404 "Metadata not available for <name>", -32601 over JSON-RPC.
    const jsonrpc = @import("../jsonrpc.zig");
    var d = jsonrpc.Dispatcher.init(testing.allocator);
    defer d.deinit();
    var reg = Registry.init(testing.allocator, &d);
    defer reg.deinit();
    try registerFileManager(&reg, &c);
    const out = try d.handle("{\"jsonrpc\":\"2.0\",\"method\":\"server.files.metadata\",\"params\":{\"filename\":\"none.gcode\"},\"id\":1}", testing.allocator);
    defer testing.allocator.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqual(@as(i64, -32601), err.get("code").?.integer);
    try testing.expectEqualStrings("Metadata not available for <none.gcode>", err.get("message").?.string);
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
        \\iVBORw0KGgo=
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

test "handleMetadata: non-gcode files have no metadata; unknown slicers are Unknown" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    try tr.writeFile("gcodes/test.txt", "not a gcode file");
    var c = tr.ctx();
    try testing.expectError(error.MetadataNotAvailable, handleMetadata(@ptrCast(&c), try objParams(a, "{\"filename\":\"test.txt\"}"), a));
    try tr.writeFile("gcodes/plain.gcode", "G28\n");
    const result = try handleMetadata(@ptrCast(&c), try objParams(a, "{\"filename\":\"plain.gcode\"}"), a);
    try testing.expectEqualStrings("Unknown", result.object.get("slicer").?.string);
}

test "handleMetadata: large gcodes parse bounded header and footer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    const prefix = "; generated by PrusaSlicer 2.7.4 on 2024-01-15 at 08:30:00 UTC\n";
    const footer = "; estimated printing time (normal mode) = 5025s\n";
    const content = try a.alloc(u8, header_max_bytes + footer_max_bytes);
    @memset(content, '\n');
    @memcpy(content[0..prefix.len], prefix);
    @memcpy(content[content.len - footer.len ..], footer);
    try tr.writeFile("gcodes/large.gcode", content);
    var c = tr.ctx();
    defer c.deinit();

    const result = try handleMetadata(@ptrCast(&c), try objParams(a, "{\"filename\":\"large.gcode\"}"), a);
    try testing.expectEqualStrings("PrusaSlicer", result.object.get("slicer").?.string);
    try testing.expectEqual(@as(f64, 5025), result.object.get("estimated_time").?.float);
}

test "fuzz readFileHeader: reads a bounded prefix of any file size" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var tr = try TestRoots.init(a);
            defer tr.deinit();
            const size: usize = smith.valueRangeAtMostWithHash(u32, 0, header_max_bytes + 32, 0);
            const content = try a.alloc(u8, size);
            @memset(content, 'G');
            try tr.writeFile("gcodes/prefix.gcode", content);
            const abs = try std.fs.path.join(a, &.{ tr.roots[0].path, "prefix.gcode" });
            const file = try Dir.cwd().openFile(tr.io, abs, .{});
            defer file.close(tr.io);
            const header = try readFileHeader(tr.io, a, file, size);
            try testing.expectEqualSlices(u8, content[0..@min(size, header_max_bytes)], header);
        }
    }.run, .{});
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
        \\; thumbnail begin 32x32 24
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
    try testing.expectEqualStrings(".thumbs/test-32x32.png", t.get("thumbnail_path").?.string);
    try testing.expectEqual(@as(i64, 16), t.get("size").?.integer);

    // Missing filename is 400. An empty string is a lookup that finds nothing.
    try testing.expectError(error.MissingFilename, handleThumbnails(@ptrCast(&c), .null, a));
    const empty = try handleThumbnails(@ptrCast(&c), try objParams(a, "{\"filename\":\"\"}"), a);
    try testing.expect(empty == .array);
    try testing.expectEqual(@as(usize, 0), empty.array.items.len);
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

test "thumbnail writes cannot follow a .thumbs link outside the gcode root" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    var ctx = tr.ctx();
    defer ctx.deinit();
    try tr.writeFile("gcodes/model.gcode", "; thumbnail begin 1x1 4\n; QUJD\n; thumbnail end\n");
    try tr.writeFile("config/model-1x1.png", "keep");
    try tr.tmp.dir.symLink(tr.io, tr.roots[1].path, "gcodes/.thumbs", .{});
    try testing.expectError(error.Forbidden, handleMetadata(@ptrCast(&ctx), try objParams(a, "{\"filename\":\"model.gcode\"}"), a));
    const contents = try tr.tmp.dir.readFileAlloc(tr.io, "config/model-1x1.png", a, .limited(16));
    try testing.expectEqualStrings("keep", contents);
}

test "fuzz thumbnail persistence validates dimensions and base64 before writing" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var tr = try TestRoots.init(a);
            defer tr.deinit();
            var data: [64]u8 = undefined;
            smith.bytesWithHash(&data, 0);
            const encoded: []const u8 = if (smith.value(bool)) "QUJD" else data[0 .. smith.value(u8) % data.len];
            const thumbnails = [_]gcode_metadata.Thumbnail{.{
                .width = smith.value(i8),
                .height = smith.value(i8),
                .size = if (smith.value(bool)) @intCast(encoded.len) else smith.value(i8),
                .data = encoded,
            }};
            const value = try thumbnailsJson(tr.io, a, .{ .root = tr.roots[0], .rel = "model.gcode", .abs = "" }, &thumbnails);
            for (value.array.items) |thumbnail| {
                const rel = thumbnail.object.get("relative_path").?.string;
                try testing.expect(std.mem.startsWith(u8, rel, ".thumbs/model-"));
                const image = try tr.tmp.dir.readFileAlloc(tr.io, try std.fs.path.join(a, &.{ "gcodes", rel }), a, .limited(data.len));
                try testing.expectEqual(@as(i64, @intCast(image.len)), thumbnail.object.get("size").?.integer);
                const expected = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
                try std.base64.standard.Decoder.decode(expected, encoded);
                try testing.expectEqualSlices(u8, expected, image);
            }
        }
    }.run, .{});
}

test "handleThumbnails: missing file returns an empty list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    var c = tr.ctx();
    const result = try handleThumbnails(@ptrCast(&c), try objParams(a, "{\"filename\":\"nonexistent.gcode\"}"), a);
    try testing.expectEqual(@as(usize, 0), result.array.items.len);
}

test "handleZip creates a readable archive with selected root paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    var c = tr.ctx();
    try tr.writeFile("gcodes/cube.gcode", "G1 X0\n");
    const result = try handleZip(@ptrCast(&c), try objParams(a, "{\"dest\":\"config/out.zip\",\"items\":[\"gcodes/cube.gcode\"]}"), a);
    try testing.expectEqualStrings("zip_files", result.object.get("action").?.string);
    const dst = result.object.get("destination").?.object;
    try testing.expectEqualStrings("out.zip", dst.get("path").?.string);
    try testing.expectEqualStrings("config", dst.get("root").?.string);
    const archive = try tr.tmp.dir.openFile(tr.io, "config/out.zip", .{});
    defer archive.close(tr.io);
    var buf: [1024]u8 = undefined;
    var reader = archive.reader(tr.io, &buf);
    var iter = try std.zip.Iterator.init(&reader);
    const entry = (try iter.next()).?;
    var name_buf: [128]u8 = undefined;
    try testing.expectEqualStrings("gcodes/cube.gcode", try entry.getFilename(&reader, &name_buf, .{}));
    var contents: [128]u8 = undefined;
    var output: std.Io.Writer = .fixed(&contents);
    try entry.extractTo(&reader, &output);
    try testing.expectEqualStrings("G1 X0\n", output.buffered());
    try testing.expectEqual(null, try iter.next());
}

test "handleZip directories are shallow, excluded paths are omitted and aliases deduplicate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    try tr.writeFile("gcodes/cube.gcode", "cube");
    try tr.writeFile("gcodes/sub/deeper.gcode", "omit subdirectories");
    try tr.writeFile("gcodes/private.gcode", "excluded");
    try tr.writeFile("config/secret.cfg", "outside source root");
    try tr.tmp.dir.symLink(tr.io, "cube.gcode", "gcodes/alias.gcode", .{});
    try tr.tmp.dir.symLink(tr.io, "../config/secret.cfg", "gcodes/escape.gcode", .{});
    var c = tr.ctx();
    var excludes = [_][]const u8{"gcodes/private.gcode"};
    c.excludes = &excludes;
    _ = try handleZip(@ptrCast(&c), try objParams(a, "{\"dest\":\"config/out.zip\",\"items\":[\"gcodes/cube.gcode\",\"gcodes\"],\"store_only\":true}"), a);
    const file = try tr.tmp.dir.openFile(tr.io, "config/out.zip", .{});
    defer file.close(tr.io);
    var buf: [1024]u8 = undefined;
    var reader = file.reader(tr.io, &buf);
    var iter = try std.zip.Iterator.init(&reader);
    const entry = (try iter.next()).?;
    var name_buf: [128]u8 = undefined;
    try testing.expectEqualStrings("gcodes/cube.gcode", try entry.getFilename(&reader, &name_buf, .{}));
    try testing.expectEqual(std.zip.CompressionMethod.store, entry.compression_method);
    try testing.expectEqual(null, try iter.next());
}

test "handleZip validation and late failures preserve the existing destination" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    try tr.writeFile("config/out.zip", "previous archive");
    try tr.writeFile("gcodes/cube.gcode", "cube");
    try tr.writeFile("config/.git/config", "reserved");
    var c = tr.ctx();
    const cases = [_]struct { params: []const u8, err: anyerror }{
        .{ .params = "{\"dest\":\"config/out.zip\"}", .err = error.InvalidParams },
        .{ .params = "{\"dest\":\"config/out.zip\",\"items\":[]}", .err = error.InvalidParams },
        .{ .params = "{\"dest\":\"config/out.zip\",\"items\":[5]}", .err = error.InvalidParams },
        .{ .params = "{\"dest\":\"config/out.zip\",\"items\":[\"gcodes/missing\"]}", .err = error.NotFound },
        .{ .params = "{\"dest\":\"config/out.zip\",\"items\":[\"config/.git/config\"]}", .err = error.Forbidden },
        .{ .params = "{\"dest\":\"logs/out.zip\",\"items\":[\"gcodes/cube.gcode\"]}", .err = error.Forbidden },
        .{ .params = "{\"dest\":\"config/sub/out.zip\",\"items\":[\"gcodes/cube.gcode\"]}", .err = error.NotFound },
    };
    for (cases) |case| {
        try testing.expectError(case.err, handleZip(@ptrCast(&c), try objParams(a, case.params), a));
        try testing.expectEqualStrings("previous archive", try tr.tmp.dir.readFileAlloc(tr.io, "config/out.zip", a, .limited(100)));
    }
    const huge = try tr.tmp.dir.createFile(tr.io, "gcodes/huge.gcode", .{});
    defer huge.close(tr.io);
    try huge.setLength(tr.io, std.math.maxInt(u32));
    try testing.expectError(error.InvalidParams, handleZip(@ptrCast(&c), try objParams(a, "{\"dest\":\"config/out.zip\",\"items\":[\"gcodes/huge.gcode\"]}"), a));
    try testing.expectEqualStrings("previous archive", try tr.tmp.dir.readFileAlloc(tr.io, "config/out.zip", a, .limited(100)));
    var dir = try tr.tmp.dir.openDir(tr.io, "config", .{ .iterate = true });
    defer dir.close(tr.io);
    var iter = dir.iterate();
    var count: usize = 0;
    while (try iter.next(tr.io)) |_| count += 1;
    try testing.expectEqual(@as(usize, 2), count); // out.zip and .git; no temporary remains.
}

test "handleZip rejects escaping destinations and bounded source tables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try TestRoots.init(a);
    defer tr.deinit();
    try tr.writeFile("gcodes/cube.gcode", "cube");
    try tr.tmp.dir.symLink(tr.io, "../logs", "config/outside", .{ .is_directory = true });
    var c = tr.ctx();
    try testing.expectError(error.Forbidden, handleZip(@ptrCast(&c), try objParams(a, "{\"dest\":\"config/outside/out.zip\",\"items\":[\"gcodes/cube.gcode\"]}"), a));
    try testing.expectEqual(StatKind.missing, tr.exists("logs/out.zip"));
    const source = try resolveRequestPath(&c, a, "gcodes/cube.gcode");
    var sources: ArchiveSources = .{};
    defer sources.items.deinit(a);
    defer sources.canonical.deinit(a);
    sources.path_bytes = zip_writer.Archive.max_names_bytes;
    try testing.expectError(error.ArchiveTooLarge, sources.append(tr.io, a, a, source));
    sources.path_bytes = 0;
    try sources.items.resize(a, zip_writer.Archive.max_entries);
    try testing.expectError(error.ArchiveTooLarge, sources.append(tr.io, a, a, source));
}

test "fuzz handleZip archives only the selected file and preserves its contents" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var tr = try TestRoots.init(a);
            defer tr.deinit();
            var buf: [2048]u8 = undefined;
            const bytes = buf[0..smith.slice(&buf)];
            try tr.writeFile("gcodes/print.gcode", bytes);
            var c = tr.ctx();
            const params = try objParams(a, if (smith.value(bool)) "{\"dest\":\"config/out.zip\",\"items\":[\"gcodes/print.gcode\",\"gcodes/print.gcode\"],\"store_only\":true}" else "{\"dest\":\"config/out.zip\",\"items\":[\"gcodes/print.gcode\"]}");
            _ = try handleZip(@ptrCast(&c), params, a);
            const file = try tr.tmp.dir.openFile(tr.io, "config/out.zip", .{});
            defer file.close(tr.io);
            var read_buf: [1024]u8 = undefined;
            var reader = file.reader(tr.io, &read_buf);
            var iter = try std.zip.Iterator.init(&reader);
            const entry = (try iter.next()).?;
            var data: std.Io.Writer.Allocating = .init(a);
            defer data.deinit();
            try entry.extractTo(&reader, &data.writer);
            try testing.expectEqualSlices(u8, bytes, data.written());
            try testing.expectEqual(std.hash.Crc32.hash(bytes), entry.crc32);
            try testing.expectEqual(null, try iter.next());
        }
    }.run, .{});
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

    var ctx = FileCtx{ .gpa = alloc, .roots = &.{}, .bus = null };
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
        "server.files.roots",          "server.files.list",
        "server.files.metadata",       "server.files.metascan",
        "server.files.thumbnails",     "server.files.get_directory",
        "server.files.post_directory", "server.files.delete_directory",
        "server.files.move",           "server.files.copy",
        "server.files.zip",            "server.files.delete_file",
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
            try tr.writeFile("gcodes/print.gcode", "; generated by PrusaSlicer 2.7.4\n");
            var c = tr.ctx();
            defer c.deinit();

            const cases = [_][]const u8{
                "{}",
                "{\"root\":\"gcodes\"}",
                "{\"path\":\"gcodes\",\"extended\":true}",
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

test "file excludes preserve ownership on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(alloc: std.mem.Allocator) !void {
            var ctx: FileCtx = .{ .gpa = alloc, .roots = &.{}, .bus = null };
            defer ctx.deinit();
            try ctx.setExcludes("gcodes/old");
            try ctx.setExcludes("gcodes/new\nconfig/private");
            try std.testing.expectEqual(@as(usize, 2), ctx.excludes.len);
        }
    }.check, .{});
}
