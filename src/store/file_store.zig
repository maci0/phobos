//! FileStore — an atomic-rename JSON DataStore backend.
//!
//! One file per namespace: `<dir>/<namespace>.json` holds a JSON object mapping
//! each top-level record key to its record value. `std.Io.File.Atomic` publishes
//! each complete namespace. Data is synced before replacement; failed writes
//! leave the previous namespace in place and clean up the temporary file.
//!
//! Pure Zig, no C dependency — the lean alternative to the SQLite backend for
//! deployments that don't need Moonraker `moonraker-sql.db` compatibility. The
//! dotted-key path semantics are shared with the other backends via
//! `datastore.zig` (`parseKey`/`getPath`/`insertPath`/`updatePath`/`deletePath`).

const std = @import("std");
const json = std.json;
const ds = @import("datastore.zig");
const Error = ds.Error;

pub const FileStore = struct {
    io: std.Io,
    dir: std.Io.Dir,
    /// Serializes read-modify-write so concurrent inserts to one namespace can't
    /// lose updates. Required: `GET /server/database/item` and background
    /// workers reach the store outside the Core lock.
    mutex: std.Io.Mutex = .init,

    /// Per-namespace file size cap — bounds memory on a hostile/corrupt file.
    const max_file: usize = 64 * 1024 * 1024;

    /// Open (creating if absent) the database directory.
    pub fn open(io: std.Io, dir_path: []const u8) !FileStore {
        const cwd = std.Io.Dir.cwd();
        const dir = try cwd.createDirPathOpen(io, dir_path, .{ .open_options = .{ .iterate = true } });
        return .{ .io = io, .dir = dir };
    }

    pub fn deinit(self: *FileStore) void {
        self.dir.close(self.io);
    }

    // --- namespace file load/save -----------------------------------------

    /// `<namespace>.json`, relative to the store directory. A namespace is
    /// request input, so a path separator or NUL is `InvalidKey`.
    fn fileName(arena: std.mem.Allocator, namespace: []const u8) Error![]const u8 {
        if (std.mem.indexOfAny(u8, namespace, "/\x00") != null) return Error.InvalidKey;
        return std.fmt.allocPrint(arena, "{s}.json", .{namespace});
    }

    /// Read + parse a namespace's JSON object into `arena`. Empty when absent.
    fn load(self: *FileStore, arena: std.mem.Allocator, namespace: []const u8) Error!json.ObjectMap {
        const fname = try fileName(arena, namespace);
        const bytes = self.dir.readFileAlloc(self.io, fname, arena, .limited(max_file)) catch |e| switch (e) {
            error.FileNotFound => return .empty,
            else => return Error.BackendError,
        };
        const v = json.parseFromSliceLeaky(json.Value, arena, bytes, .{}) catch return Error.BackendError;
        return switch (v) {
            .object => |o| o,
            else => Error.BackendError,
        };
    }

    /// Serialize `obj` and write it to `<namespace>.json` atomically (temp+rename).
    fn save(self: *FileStore, arena: std.mem.Allocator, namespace: []const u8, obj: json.ObjectMap) Error!void {
        const fname = try fileName(arena, namespace);
        var aw: std.Io.Writer.Allocating = .init(arena);
        var jw: json.Stringify = .{ .writer = &aw.writer };
        jw.write(json.Value{ .object = obj }) catch return Error.BackendError;
        const bytes = aw.written();

        var pending = self.dir.createFileAtomic(self.io, fname, .{ .replace = true }) catch return Error.BackendError;
        defer pending.deinit(self.io);
        pending.file.writeStreamingAll(self.io, bytes) catch return Error.BackendError;
        pending.file.sync(self.io) catch return Error.BackendError;
        pending.replace(self.io) catch return Error.BackendError;
    }

    // --- DataStore API (shared dotted-key path helpers) -------------------

    pub fn getItem(self: *FileStore, arena: std.mem.Allocator, namespace: [:0]const u8, key: anytype) Error!?json.Value {
        const pk = try ds.parseKey(key);
        const segs = pk.slice();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var obj = try self.load(arena, namespace);
        const record = obj.get(segs[0]) orelse return null;
        return ds.getPath(record, segs[1..]) catch |e| switch (e) {
            ds.Error.KeyNotFound => null,
            else => |other| other,
        };
    }

    pub fn insertItem(self: *FileStore, arena: std.mem.Allocator, namespace: [:0]const u8, key: anytype, value: json.Value) Error!void {
        const pk = try ds.parseKey(key);
        const segs = pk.slice();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var obj = try self.load(arena, namespace);
        var record: json.Value = .null;
        if (segs.len > 1) record = obj.get(segs[0]) orelse .{ .object = .empty };
        const new_record = try ds.insertPath(arena, record, segs[1..], value);
        obj.put(arena, try arena.dupe(u8, segs[0]), new_record) catch return Error.BackendError;
        try self.save(arena, namespace, obj);
    }

    pub fn updateItem(self: *FileStore, arena: std.mem.Allocator, namespace: [:0]const u8, key: anytype, value: json.Value) Error!void {
        const pk = try ds.parseKey(key);
        const segs = pk.slice();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var obj = try self.load(arena, namespace);
        const record = obj.get(segs[0]) orelse return Error.KeyNotFound;
        const new_record = try ds.updatePath(arena, record, segs[1..], value);
        obj.put(arena, try arena.dupe(u8, segs[0]), new_record) catch return Error.BackendError;
        try self.save(arena, namespace, obj);
    }

    pub fn deleteItem(self: *FileStore, arena: std.mem.Allocator, namespace: [:0]const u8, key: anytype) Error!json.Value {
        const pk = try ds.parseKey(key);
        const segs = pk.slice();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var obj = try self.load(arena, namespace);
        const record = obj.get(segs[0]) orelse return Error.KeyNotFound;
        const res = try ds.deletePath(record, segs[1..]);
        if (res.record) |new_record| {
            obj.put(arena, try arena.dupe(u8, segs[0]), new_record) catch return Error.BackendError;
        } else {
            _ = obj.swapRemove(segs[0]);
        }
        try self.save(arena, namespace, obj);
        return res.removed;
    }

    pub fn getNamespace(self: *FileStore, arena: std.mem.Allocator, namespace: [:0]const u8) Error!json.Value {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const obj = try self.load(arena, namespace);
        return .{ .object = obj };
    }

    pub fn listNamespaces(self: *FileStore, arena: std.mem.Allocator) Error![][]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var out: std.ArrayList([]const u8) = .empty;
        var it = self.dir.iterate();
        while (it.next(self.io) catch return Error.BackendError) |entry| {
            const name = entry.name;
            // A namespace file is "<name>.json"; atomic-write temporaries have
            // no extension.
            if (!std.mem.endsWith(u8, name, ".json")) continue;
            const ns = name[0 .. name.len - ".json".len];
            try out.append(arena, try arena.dupe(u8, ns));
        }
        return out.toOwnedSlice(arena);
    }

    // --- DataStore vtable adapter -----------------------------------------

    pub fn dataStore(self: *FileStore) ds.DataStore {
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
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "FileStore: insert / get / update / delete round-trip + persistence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);

    {
        var fs = try FileStore.open(io, dir);
        defer fs.deinit();
        try fs.insertItem(a, "moonraker", "file_manager.metadata_version", .{ .integer = 3 });
        const got = (try fs.getItem(a, "moonraker", "file_manager.metadata_version")).?;
        try testing.expectEqual(@as(i64, 3), got.integer);
        // update
        try fs.updateItem(a, "moonraker", "file_manager.metadata_version", .{ .integer = 4 });
        try testing.expectEqual(@as(i64, 4), (try fs.getItem(a, "moonraker", "file_manager.metadata_version")).?.integer);
        // a string record + a whole-namespace read
        try fs.insertItem(a, "moonraker", "instance_id", .{ .string = "abc123" });
        const ns = try fs.getNamespace(a, "moonraker");
        try testing.expect(ns.object.get("instance_id") != null);
    }
    // Reopen: data persisted to disk (atomic rename committed it).
    {
        var fs = try FileStore.open(io, dir);
        defer fs.deinit();
        try testing.expectEqual(@as(i64, 4), (try fs.getItem(a, "moonraker", "file_manager.metadata_version")).?.integer);
        const removed = try fs.deleteItem(a, "moonraker", "instance_id");
        try testing.expectEqualStrings("abc123", removed.string);
        try testing.expect((try fs.getItem(a, "moonraker", "instance_id")) == null);
        // listNamespaces sees the namespace file (not the .tmp).
        const names = try fs.listNamespaces(a);
        var found = false;
        for (names) |n| if (std.mem.eql(u8, n, "moonraker")) {
            found = true;
        };
        try testing.expect(found);
    }
}

test "FileStore: missing key/namespace error/empty as expected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    var fs = try FileStore.open(io, dir);
    defer fs.deinit();

    try testing.expect((try fs.getItem(a, "nope", "x")) == null);
    try testing.expectError(Error.KeyNotFound, fs.updateItem(a, "nope", "x", .{ .integer = 1 }));
    try testing.expectError(Error.KeyNotFound, fs.deleteItem(a, "nope", "x"));
    const empty = try fs.getNamespace(a, "nope");
    try testing.expectEqual(@as(usize, 0), empty.object.count());
}

test "FileStore: a namespace cannot leave the database directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const dir = try std.fs.path.join(a, &.{ root, "db" });
    var fs = try FileStore.open(io, dir);
    defer fs.deinit();

    try testing.expectError(Error.InvalidKey, fs.insertItem(a, "../escape", "k", .{ .integer = 1 }));
    try testing.expectError(Error.InvalidKey, fs.getItem(a, "../escape", "k"));
    try testing.expectError(Error.InvalidKey, fs.getNamespace(a, "a/b"));
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "escape.json", .{}));
}

test "fuzz FileStore: arbitrary namespace/key stays inside the directory" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const io = testing.io;
            var tmp = testing.tmpDir(.{ .iterate = true });
            defer tmp.cleanup();
            const root = try tmp.dir.realPathFileAlloc(io, ".", a);
            var fs = try FileStore.open(io, try std.fs.path.join(a, &.{ root, "db" }));
            defer fs.deinit();
            var nbuf: [16:0]u8 = @splat(0);
            const nn = smith.valueRangeAtMostWithHash(u32, 0, 16, 2);
            smith.bytesWithHash(nbuf[0..nn], 3);
            nbuf[nn] = 0;
            const ns = nbuf[0..nn :0];
            var kbuf: [48]u8 = undefined;
            const kn = smith.valueRangeAtMostWithHash(u32, 0, 48, 0);
            smith.bytesWithHash(kbuf[0..kn], 1);
            fs.insertItem(a, ns, kbuf[0..kn], .{ .integer = 7 }) catch {};
            _ = fs.getItem(a, ns, kbuf[0..kn]) catch {};
            _ = fs.getNamespace(a, ns) catch {};
            var it = tmp.dir.iterate();
            while (try it.next(io)) |entry| try testing.expectEqualStrings("db", entry.name);
        }
    }.run, .{});
}
