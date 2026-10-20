const std = @import("std");
const files = @import("file_manager.zig");
const linux = std.os.linux;
const Io = std.Io;
const Dir = Io.Dir;

pub const Kind = enum { none, inotify };

const max_watches = 512;
const max_pending = 128;
const max_owned_path_bytes = 128 * 1024;
const read_buffer_bytes = 16 * 1024;
const bundle_ms = 250;
const move_ms = 1000;
const watch_flags = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM |
    linux.IN.MOVED_TO | linux.IN.MODIFY | linux.IN.CLOSE_WRITE | linux.IN.ONLYDIR | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF;

// Zig 0.17 has no Io watch operation; only watch setup uses the Linux adapter.
const Native = struct {
    fn open() !Io.File {
        const rc = linux.inotify_init1(linux.IN.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.ObserverUnavailable;
        return .{ .handle = @intCast(rc), .flags = .{ .nonblocking = false } };
    }

    fn add(file: Io.File, dir: Dir) !i32 {
        var path_buffer: [64]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&path_buffer, "/proc/self/fd/{d}", .{dir.handle}, 0);
        const rc = linux.inotify_add_watch(file.handle, path, watch_flags);
        if (linux.errno(rc) != .SUCCESS) return error.WatchFailed;
        return @intCast(rc);
    }

    fn remove(file: Io.File, wd: i32) !void {
        switch (linux.errno(linux.inotify_rm_watch(file.handle, wd))) {
            .SUCCESS, .INVAL => {}, // The kernel removes deleted directories first.
            else => return error.WatchFailed,
        }
    }
};

const Action = enum {
    create_file,
    modify_file,
    delete_file,
    create_dir,
    delete_dir,
    move_file,
    move_dir,
    from_file,
    from_dir,
};
const Watch = struct { wd: i32, root: usize, path: []const u8 };
const Source = struct { root: usize, path: []const u8 };
const Pending = struct {
    action: Action,
    root: usize,
    path: []const u8,
    source: ?Source = null,
    deadline: ?i64,
    cookie: u32 = 0,
    created: bool = false,
    writing: bool = false,
};

const Event = struct {
    wd: i32,
    mask: u32,
    cookie: u32,
    name: []const u8,

    fn take(input: *[]const u8) !?Event {
        if (input.len == 0) return null;
        if (input.len < @sizeOf(linux.inotify_event)) return error.InvalidEvent;
        const header = std.mem.bytesToValue(linux.inotify_event, input.*[0..@sizeOf(linux.inotify_event)]);
        const rest = input.*[@sizeOf(linux.inotify_event)..];
        if (header.len > rest.len) return error.InvalidEvent;
        const padded = rest[0..header.len];
        const name = if (padded.len == 0) "" else padded[0 .. std.mem.indexOfScalar(u8, padded, 0) orelse return error.InvalidEvent];
        if (name.len > 255 or std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidEvent;
        input.* = rest[header.len..];
        return .{ .wd = header.wd, .mask = header.mask, .cookie = header.cookie, .name = name };
    }
};

pub const Observer = struct {
    ctx: *files.FileCtx,
    io: Io,
    file: Io.File,
    future: ?Io.Future(void) = null,
    active: std.atomic.Value(bool) = .init(false),
    watches: [max_watches]Watch = undefined,
    watch_count: usize = 0,
    pending: [max_pending]Pending = undefined,
    pending_count: usize = 0,
    path_bytes: usize = 0,

    pub fn start(ctx: *files.FileCtx) !*Observer {
        const self = try ctx.gpa.create(Observer);
        errdefer ctx.gpa.destroy(self);
        try self.init(ctx);
        errdefer self.deinit();
        self.active.store(true, .release);
        self.future = try self.io.concurrent(run, .{self});
        return self;
    }

    pub fn stop(self: *Observer) void {
        self.active.store(false, .release);
        if (self.future) |*future| future.cancel(self.io);
        const alloc = self.ctx.gpa;
        self.deinit();
        alloc.destroy(self);
    }

    fn init(self: *Observer, ctx: *files.FileCtx) !void {
        const io = ctx.io orelse return error.NotReady;
        self.* = .{ .ctx = ctx, .io = io, .file = try Native.open() };
        errdefer self.deinit();
        for (ctx.roots, 0..) |_, index| try self.scan(index, "");
    }

    /// Registered roots change under Core, which also guards worker processing.
    pub fn updateRoot(self: *Observer, root: usize) !void {
        try self.removeTree(root, "");
        var index: usize = 0;
        while (index < self.pending_count) {
            if (self.pending[index].root == root) {
                self.freePending(self.takePending(index));
            } else index += 1;
        }
        try self.scan(root, "");
        try self.ctx.notifyObservedLocked("root_update", self.ctx.roots[root], "", null);
    }

    fn deinit(self: *Observer) void {
        self.file.close(self.io);
        for (self.watches[0..self.watch_count]) |watch| self.freePath(watch.path);
        for (self.pending[0..self.pending_count]) |pending| self.freePending(pending);
    }

    fn ownPath(self: *Observer, path: []const u8) ![]const u8 {
        if (path.len > Dir.max_path_bytes or path.len > max_owned_path_bytes - self.path_bytes) return error.ObserverPathLimit;
        const owned = try self.ctx.gpa.dupe(u8, path);
        self.path_bytes += path.len;
        return owned;
    }

    fn freePath(self: *Observer, path: []const u8) void {
        self.path_bytes -= path.len;
        self.ctx.gpa.free(path);
    }

    fn freePending(self: *Observer, pending: Pending) void {
        self.freePath(pending.path);
        if (pending.source) |source| self.freePath(source.path);
    }

    fn excluded(self: *Observer, root: usize, path: []const u8) bool {
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| if (std.mem.eql(u8, part, ".thumbs") or std.mem.eql(u8, part, ".git")) return true;
        return files.FileCtx.pathExcluded(self.ctx.excludes, self.ctx.roots[root].name, path);
    }

    fn resolved(self: *Observer, root: usize, path: []const u8) files.Resolved {
        return .{ .root = self.ctx.roots[root], .rel = path, .abs = "" };
    }

    fn add(self: *Observer, root: usize, path: []const u8) !bool {
        if (self.excluded(root, path)) return false;
        const dir = self.resolved(root, path).openDirectory(self.io, self.ctx.gpa) catch |err| switch (err) {
            error.NotFound, error.FileNotFound, error.NotDir, error.Forbidden => return false,
            else => return err,
        };
        defer dir.close(self.io);
        if (self.watch_count == max_watches) return error.ObserverWatchLimit;
        const owned = try self.ownPath(path);
        errdefer self.freePath(owned);
        const wd = try Native.add(self.file, dir);
        // shortcut: inode aliases share one watch; add alias fan-out if both names are needed.
        for (self.watches[0..self.watch_count]) |watch| if (watch.wd == wd) {
            self.freePath(owned);
            return false;
        };
        self.watches[self.watch_count] = .{ .wd = wd, .root = root, .path = owned };
        self.watch_count += 1;
        return true;
    }

    fn scan(self: *Observer, root: usize, path: []const u8) !void {
        const start_index = self.watch_count;
        if (!try self.add(root, path)) return;
        var index = start_index;
        while (index < self.watch_count) : (index += 1) {
            const watch = self.watches[index];
            const dir = self.resolved(watch.root, watch.path).openDirectory(self.io, self.ctx.gpa) catch |err| switch (err) {
                error.NotFound, error.FileNotFound, error.NotDir, error.Forbidden => continue,
                else => return err,
            };
            defer dir.close(self.io);
            var it = dir.iterate();
            while (try it.next(self.io)) |entry| {
                if (entry.kind != .directory and entry.kind != .sym_link and entry.kind != .unknown) continue;
                if (!std.unicode.utf8ValidateSlice(entry.name)) continue;
                var buffer: [Dir.max_path_bytes]u8 = undefined;
                const child = try joinPath(&buffer, watch.path, entry.name);
                _ = try self.add(watch.root, child);
            }
        }
    }

    fn removeTree(self: *Observer, root: usize, sub_path: []const u8) !void {
        var path_buffer: [Dir.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}", .{sub_path});
        var index: usize = 0;
        while (index < self.watch_count) {
            const watch = self.watches[index];
            if (watch.root != root or !inside(path, watch.path)) {
                index += 1;
                continue;
            }
            try Native.remove(self.file, watch.wd);
            self.freePath(watch.path);
            self.watch_count -= 1;
            self.watches[index] = self.watches[self.watch_count];
        }
    }

    fn takePending(self: *Observer, index: usize) Pending {
        const item = self.pending[index];
        self.pending_count -= 1;
        self.pending[index] = self.pending[self.pending_count];
        return item;
    }

    fn findPending(self: *Observer, root: usize, path: []const u8) ?usize {
        for (self.pending[0..self.pending_count], 0..) |pending, index| {
            if (pending.root == root and std.mem.eql(u8, pending.path, path)) return index;
        }
        return null;
    }

    fn dropChildren(self: *Observer, root: usize, path: []const u8) void {
        var index: usize = 0;
        while (index < self.pending_count) {
            const pending = self.pending[index];
            if (pending.root == root and !std.mem.eql(u8, pending.path, path) and inside(path, pending.path)) {
                self.freePending(self.takePending(index));
            } else index += 1;
        }
    }

    fn queue(self: *Observer, action: Action, root: usize, path: []const u8, ready: bool, source: ?Source) !void {
        const deadline = now(self.io) + bundle_ms;
        for (self.pending[0..self.pending_count]) |*pending| {
            if ((pending.action == .create_dir or pending.action == .delete_dir) and pending.root == root and
                !std.mem.eql(u8, path, pending.path) and inside(pending.path, path))
            {
                pending.deadline = if (ready) deadline else null;
                if (pending.action == .delete_dir) return;
            }
        }
        if (action == .delete_dir) self.dropChildren(root, path);
        if (self.findPending(root, path)) |index| {
            const existing = &self.pending[index];
            if ((action == .delete_file and existing.action == .create_file) or
                (action == .delete_dir and existing.action == .create_dir))
            {
                self.freePending(self.takePending(index));
                return;
            }
            if (action == .modify_file and (existing.action == .create_file or existing.action == .move_file)) {
                existing.deadline = if (ready) deadline else null;
                existing.writing = !ready;
                return;
            }
            self.freePending(self.takePending(index));
        }
        if (self.pending_count == max_pending) return error.ObserverPendingLimit;
        const owned = try self.ownPath(path);
        errdefer self.freePath(owned);
        const owned_source: ?Source = if (source) |src| .{ .root = src.root, .path = try self.ownPath(src.path) } else null;
        self.pending[self.pending_count] = .{
            .action = action,
            .root = root,
            .path = owned,
            .source = owned_source,
            .deadline = if (ready) deadline else null,
            .writing = !ready,
        };
        self.pending_count += 1;
    }

    fn movedFrom(self: *Observer, root: usize, path: []const u8, cookie: u32, is_dir: bool) !void {
        const previous: ?Pending = if (self.findPending(root, path)) |index| self.takePending(index) else null;
        defer if (previous) |item| self.freePending(item);
        if (is_dir) {
            try self.removeTree(root, path);
            self.dropChildren(root, path);
        }
        try self.queue(if (is_dir) .from_dir else .from_file, root, path, true, if (previous) |item| item.source else null);
        if (self.findPending(root, path)) |index| {
            const pending = &self.pending[index];
            pending.cookie = cookie;
            pending.created = if (previous) |item| item.action == .create_file or item.action == .create_dir else false;
            pending.writing = if (previous) |item| item.writing else false;
            pending.deadline = now(self.io) + move_ms;
        }
    }

    fn movedTo(self: *Observer, root: usize, path: []const u8, cookie: u32, is_dir: bool) !void {
        if (is_dir) try self.scan(root, path);
        for (self.pending[0..self.pending_count], 0..) |pending, index| {
            if (cookie == 0 or pending.cookie != cookie) continue;
            const source = self.takePending(index);
            defer self.freePending(source);
            try self.queue(if (source.created)
                (if (is_dir) .create_dir else .create_file)
            else
                (if (is_dir) .move_dir else .move_file), root, path, !source.writing, if (source.created) null else source.source orelse .{ .root = source.root, .path = source.path });
            return;
        }
        try self.queue(if (is_dir) .create_dir else .create_file, root, path, true, null);
    }

    fn process(self: *Observer, event: Event) !void {
        if (event.mask & linux.IN.Q_OVERFLOW != 0) return error.ObserverOverflow;
        const watch = for (self.watches[0..self.watch_count]) |watch| {
            if (watch.wd == event.wd) break watch;
        } else return;
        if (event.mask & linux.IN.IGNORED != 0) {
            try self.removeTree(watch.root, watch.path);
            return;
        }
        if (event.name.len == 0) {
            // shortcut: externally replaced roots stop observation; restart to watch their replacement.
            if (watch.path.len == 0 and event.mask & (linux.IN.DELETE_SELF | linux.IN.MOVE_SELF | linux.IN.UNMOUNT) != 0) return error.ObserverRootChanged;
            return;
        }
        if (!std.unicode.utf8ValidateSlice(event.name) or std.mem.eql(u8, event.name, ".") or std.mem.eql(u8, event.name, "..")) return;
        var buffer: [Dir.max_path_bytes]u8 = undefined;
        const path = try joinPath(&buffer, watch.path, event.name);
        if (self.excluded(watch.root, path)) return;
        const is_dir = event.mask & linux.IN.ISDIR != 0;
        if (event.mask & linux.IN.MOVED_FROM != 0) {
            try self.movedFrom(watch.root, path, event.cookie, is_dir);
        } else if (event.mask & linux.IN.MOVED_TO != 0) {
            try self.movedTo(watch.root, path, event.cookie, is_dir);
        } else if (event.mask & linux.IN.CREATE != 0) {
            if (is_dir) try self.scan(watch.root, path);
            const linked = if (self.resolved(watch.root, path).parent(self.io, self.ctx.gpa, .{})) |parent| blk: {
                var p = parent;
                defer p.close(self.io);
                const st = p.dir.statFile(self.io, p.name, .{ .follow_symlinks = false }) catch break :blk false;
                break :blk st.kind == .sym_link;
            } else |_| false;
            if (linked) try self.scan(watch.root, path);
            try self.queue(if (is_dir) .create_dir else .create_file, watch.root, path, is_dir or linked, null);
        } else if (event.mask & linux.IN.DELETE != 0) {
            if (is_dir) try self.removeTree(watch.root, path);
            try self.queue(if (is_dir) .delete_dir else .delete_file, watch.root, path, true, null);
        } else if (!is_dir and event.mask & linux.IN.MODIFY != 0) {
            try self.queue(.modify_file, watch.root, path, false, null);
        } else if (!is_dir and event.mask & linux.IN.CLOSE_WRITE != 0) {
            if (self.findPending(watch.root, path) != null)
                try self.queue(.modify_file, watch.root, path, true, null);
        }
    }

    fn flush(self: *Observer) !void {
        const current = now(self.io);
        var index: usize = 0;
        while (index < self.pending_count) {
            const deadline = self.pending[index].deadline orelse {
                index += 1;
                continue;
            };
            if (deadline > current) {
                index += 1;
                continue;
            }
            const candidate = &self.pending[index];
            if (candidate.action == .create_dir) {
                const writing = for (self.pending[0..self.pending_count]) |child| {
                    if (child.root == candidate.root and child.writing and child.cookie == 0 and inside(candidate.path, child.path)) break true;
                } else false;
                if (writing) {
                    candidate.deadline = null;
                    index += 1;
                    continue;
                }
            }
            const pending = self.takePending(index);
            defer self.freePending(pending);
            if (pending.action == .create_dir) self.dropChildren(pending.root, pending.path);
            const action: Action = switch (pending.action) {
                .from_file => .delete_file,
                .from_dir => .delete_dir,
                else => pending.action,
            };
            // Unmaterialized atomic files never become public entries.
            if (pending.created and pending.cookie != 0) continue;
            const from = pending.action == .from_file or pending.action == .from_dir;
            const target: Source = if (from) pending.source orelse .{ .root = pending.root, .path = pending.path } else .{ .root = pending.root, .path = pending.path };
            const source: ?files.SourceItem = if (!from and pending.source != null) .{ .root = self.ctx.roots[pending.source.?.root], .rel = pending.source.?.path } else null;
            try self.ctx.notifyObservedLocked(@tagName(action), self.ctx.roots[target.root], target.path, source);
        }
    }

    fn timeout(self: *Observer) Io.Timeout {
        var nearest: ?i64 = null;
        for (self.pending[0..self.pending_count]) |pending| if (pending.deadline) |deadline| {
            nearest = @min(nearest orelse deadline, deadline);
        };
        const deadline = nearest orelse return .none;
        return .{ .deadline = .{ .raw = .fromNanoseconds(@as(i96, deadline) * std.time.ns_per_ms), .clock = .awake } };
    }

    fn loop(self: *Observer) !void {
        var buffer: [read_buffer_bytes]u8 = undefined;
        while (self.active.load(.acquire)) {
            const deadline = if (self.ctx.bus) |bus| bus.core.run(self.io, Observer.timeout, .{self}) else self.timeout();
            const result = self.io.operateTimeout(.{ .file_read_streaming = .{ .file = self.file, .data = &.{&buffer} } }, deadline) catch |err| switch (err) {
                error.Timeout => {
                    try self.consume(&.{});
                    continue;
                },
                else => return err,
            };
            const count = try result.file_read_streaming;
            try self.consume(buffer[0..count]);
        }
    }

    fn consume(self: *Observer, bytes: []const u8) !void {
        if (self.ctx.bus) |bus| bus.core.lock(self.io);
        defer if (self.ctx.bus) |bus| bus.core.unlock(self.io);
        if (!self.active.load(.acquire)) return;
        var input = bytes;
        while (try Event.take(&input)) |event| try self.process(event);
        try self.flush();
    }

    fn run(self: *Observer) void {
        defer self.active.store(false, .release);
        self.loop() catch |err| {
            if (err != error.Canceled) std.debug.print("phobos: file observer stopped: {}\n", .{err});
        };
    }
};

fn now(io: Io) i64 {
    return Io.Clock.awake.now(io).toMilliseconds();
}

fn inside(parent: []const u8, path: []const u8) bool {
    return parent.len == 0 or std.mem.eql(u8, parent, path) or
        (path.len > parent.len and std.mem.startsWith(u8, path, parent) and path[parent.len] == '/');
}

fn joinPath(buffer: []u8, parent: []const u8, name: []const u8) ![]const u8 {
    return if (parent.len == 0) std.fmt.bufPrint(buffer, "{s}", .{name}) else std.fmt.bufPrint(buffer, "{s}/{s}", .{ parent, name });
}

test "file observer: external writes renames and deletes reach the websocket" {
    const testing = std.testing;
    const TestServer = @import("../testutil/server.zig").TestServer;
    const ws = @import("../testutil/ws_client.zig");
    const ts = try TestServer.init(testing.allocator);
    defer ts.stop();
    const client = try ws.connect(ts, testing.allocator);
    defer client.close();
    try ts.app.file_ctx.startObserver();
    const root = ts.app.file_ctx.findRoot("gcodes").?;
    const dir = try std.Io.Dir.cwd().openDir(ts.io, root.path, .{});
    defer dir.close(ts.io);
    const actions = [_][]const u8{ "create_file", "modify_file", "move_file", "delete_file" };
    for (actions, 0..) |action, index| {
        switch (index) {
            0 => try dir.writeFile(ts.io, .{ .sub_path = "external.gcode", .data = "G28\n" }),
            1 => try dir.writeFile(ts.io, .{ .sub_path = "external.gcode", .data = "G90\nG28\n" }),
            2 => try dir.rename("external.gcode", dir, "renamed.gcode", ts.io),
            3 => try dir.deleteFile(ts.io, "renamed.gcode"),
            else => unreachable,
        }
        client.read_deadline = .fromNow(ts.io, .{ .raw = .fromSeconds(3), .clock = .awake });
        const frame = try client.readFrame();
        defer testing.allocator.free(frame.data);
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame.data, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("notify_filelist_changed", parsed.value.object.get("method").?.string);
        const change = parsed.value.object.get("params").?.array.items[0].object;
        try testing.expectEqualStrings(action, change.get("action").?.string);
        const item = change.get("item").?.object;
        try testing.expectEqualStrings("gcodes", item.get("root").?.string);
        try testing.expectEqualStrings(if (index < 2) "external.gcode" else "renamed.gcode", item.get("path").?.string);
        try testing.expectEqual(@as(i64, if (index == 3) 0 else if (index == 0) 4 else 8), item.get("size").?.integer);
        try testing.expectEqualStrings(if (index == 3) "" else "rw", item.get("permissions").?.string);
        if (index == 2) try testing.expectEqualStrings("external.gcode", change.get("source_item").?.object.get("path").?.string);
    }
}

test "file observer: recursive directory creation move and deletion reach the websocket" {
    const testing = std.testing;
    const TestServer = @import("../testutil/server.zig").TestServer;
    const ws = @import("../testutil/ws_client.zig");
    const ts = try TestServer.init(testing.allocator);
    defer ts.stop();
    const client = try ws.connect(ts, testing.allocator);
    defer client.close();
    const dir = try Dir.cwd().openDir(ts.io, ts.app.file_ctx.findRoot("gcodes").?.path, .{});
    defer dir.close(ts.io);
    try dir.createDirPath(ts.io, "initial/nested");
    try ts.app.file_ctx.startObserver();
    const paths = [_][]const u8{ "initial/nested/a.gcode", "created", "created/b.gcode", "moved", "moved/b.gcode", "moved" };
    const actions = [_][]const u8{ "create_file", "create_dir", "create_file", "move_dir", "modify_file", "delete_dir" };
    for (paths, actions, 0..) |path, action, index| {
        switch (index) {
            0, 2, 4 => try dir.writeFile(ts.io, .{ .sub_path = path, .data = "G28\n" }),
            1 => try dir.createDirPath(ts.io, path),
            3 => try dir.rename("created", dir, path, ts.io),
            5 => try dir.deleteTree(ts.io, path),
            else => unreachable,
        }
        client.read_deadline = .fromNow(ts.io, .{ .raw = .fromSeconds(3), .clock = .awake });
        const frame = try client.readFrame();
        defer testing.allocator.free(frame.data);
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame.data, .{});
        defer parsed.deinit();
        const change = parsed.value.object.get("params").?.array.items[0].object;
        try testing.expectEqualStrings(action, change.get("action").?.string);
        try testing.expectEqualStrings(path, change.get("item").?.object.get("path").?.string);
        if (index == 3) try testing.expectEqualStrings("created", change.get("source_item").?.object.get("path").?.string);
    }
}

test "file observer: atomic replacement emits one final file and skips thumbnails and excludes" {
    const testing = std.testing;
    const TestServer = @import("../testutil/server.zig").TestServer;
    const ws = @import("../testutil/ws_client.zig");
    const ts = try TestServer.init(testing.allocator);
    defer ts.stop();
    try ts.app.file_ctx.setExcludes("gcodes/excluded");
    const client = try ws.connect(ts, testing.allocator);
    defer client.close();
    const dir = try Dir.cwd().openDir(ts.io, ts.app.file_ctx.findRoot("gcodes").?.path, .{});
    defer dir.close(ts.io);
    try dir.createDirPath(ts.io, ".thumbs");
    try dir.createDirPath(ts.io, ".git");
    try dir.createDirPath(ts.io, "excluded");
    try ts.app.file_ctx.startObserver();
    try dir.writeFile(ts.io, .{ .sub_path = ".thumbs/a.png", .data = "png" });
    try dir.writeFile(ts.io, .{ .sub_path = ".git/config", .data = "git" });
    try dir.writeFile(ts.io, .{ .sub_path = "excluded/a.gcode", .data = "G28\n" });
    var atomic = try dir.createFileAtomic(ts.io, "final.gcode", .{ .replace = true });
    defer atomic.deinit(ts.io);
    try atomic.file.writeStreamingAll(ts.io, "G28\n");
    try atomic.replace(ts.io);
    client.read_deadline = .fromNow(ts.io, .{ .raw = .fromSeconds(3), .clock = .awake });
    const frame = try client.readFrame();
    defer testing.allocator.free(frame.data);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame.data, .{});
    defer parsed.deinit();
    const change = parsed.value.object.get("params").?.array.items[0].object;
    try testing.expectEqualStrings("create_file", change.get("action").?.string);
    try testing.expectEqualStrings("final.gcode", change.get("item").?.object.get("path").?.string);
    ts.app.file_ctx.stopObserver();
    client.read_deadline = .fromNow(ts.io, .{ .raw = .fromMilliseconds(100), .clock = .awake });
    try testing.expectError(error.ReadFailed, client.readFrame());
}

test "file observer: bounded state checked links and disabled startup" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/child");
    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.symLink(io, "../outside", "root/escape", .{});
    try tmp.dir.symLink(io, "child", "root/alias", .{});
    try tmp.dir.symLink(io, ".", "root/cycle", .{});
    const root_path = try tmp.dir.realPathFileAlloc(io, "root", testing.allocator);
    defer testing.allocator.free(root_path);
    const roots = [_]files.Root{.{ .name = "gcodes", .path = root_path, .full_access = true }};
    var ctx: files.FileCtx = .{ .gpa = testing.allocator, .roots = &roots, .bus = null, .io = io };
    defer ctx.deinit();
    ctx.observer_kind = .none;
    try ctx.startObserver();
    try testing.expect(ctx.observer == null);
    const observer = try testing.allocator.create(Observer);
    defer testing.allocator.destroy(observer);
    try observer.init(&ctx);
    defer observer.deinit();
    try testing.expectEqual(@as(usize, 2), observer.watch_count);
    try testing.expectError(error.ObserverOverflow, observer.process(.{ .wd = -1, .mask = linux.IN.Q_OVERFLOW, .cookie = 0, .name = "" }));
    try testing.expectError(error.ObserverRootChanged, observer.process(.{ .wd = observer.watches[0].wd, .mask = linux.IN.MOVE_SELF, .cookie = 0, .name = "" }));
    try testing.expect(!try observer.add(0, "escape"));
    const owned = try observer.ownPath("abc");
    defer observer.freePath(owned);
    const before = observer.path_bytes;
    observer.path_bytes = max_owned_path_bytes;
    try testing.expectError(error.ObserverPathLimit, observer.ownPath("x"));
    observer.path_bytes = before;
    for (0..max_pending) |index| {
        var buffer: [32]u8 = undefined;
        try observer.queue(.create_file, 0, try std.fmt.bufPrint(&buffer, "file-{d}", .{index}), false, null);
    }
    try testing.expectError(error.ObserverPendingLimit, observer.queue(.create_file, 0, "overflow", false, null));
    try testing.expect(observer.timeout() == .none);
}

test "file observer: daemon worker cancels an idle native read" {
    const testing = std.testing;
    const TestServer = @import("../testutil/server.zig").TestServer;
    const ts = try TestServer.init(testing.allocator);
    defer ts.stop();
    try ts.app.file_ctx.startObserver();
    try ts.app.file_ctx.startObserver();
    const start = now(ts.io);
    ts.app.file_ctx.stopObserver();
    ts.app.file_ctx.stopObserver();
    try testing.expect(now(ts.io) - start < 1000);
}

test "file observer: a renamed open file notifies after its completed write" {
    const testing = std.testing;
    const TestServer = @import("../testutil/server.zig").TestServer;
    const ws = @import("../testutil/ws_client.zig");
    const ts = try TestServer.init(testing.allocator);
    defer ts.stop();
    const client = try ws.connect(ts, testing.allocator);
    defer client.close();
    try ts.app.file_ctx.startObserver();
    const dir = try Dir.cwd().openDir(ts.io, ts.app.file_ctx.findRoot("gcodes").?.path, .{});
    defer dir.close(ts.io);
    {
        const file = try dir.createFile(ts.io, "open.gcode", .{});
        defer file.close(ts.io);
        try file.writeStreamingAll(ts.io, "G28\n");
        try dir.rename("open.gcode", dir, "finished.gcode", ts.io);
        client.read_deadline = .fromNow(ts.io, .{ .raw = .fromMilliseconds(bundle_ms + 100), .clock = .awake });
        try testing.expectError(error.ReadFailed, client.readFrame());
        try file.writeStreamingAll(ts.io, "G90\n");
    }
    client.read_deadline = .fromNow(ts.io, .{ .raw = .fromSeconds(3), .clock = .awake });
    const frame = try client.readFrame();
    defer testing.allocator.free(frame.data);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame.data, .{});
    defer parsed.deinit();
    const change = parsed.value.object.get("params").?.array.items[0].object;
    try testing.expectEqualStrings("create_file", change.get("action").?.string);
    try testing.expectEqualStrings("finished.gcode", change.get("item").?.object.get("path").?.string);
    try testing.expectEqual(@as(i64, 8), change.get("item").?.object.get("size").?.integer);
}

test "file observer: event decoder rejects truncated names and headers" {
    const testing = std.testing;
    var input: []const u8 = &.{};
    try testing.expect(try Event.take(&input) == null);
    input = "a";
    try testing.expectError(error.InvalidEvent, Event.take(&input));
    var header: linux.inotify_event = .{ .wd = 2, .mask = linux.IN.CREATE, .cookie = 7, .len = 4 };
    var bytes: [20]u8 = undefined;
    @memcpy(bytes[0..16], std.mem.asBytes(&header));
    @memcpy(bytes[16..], "abc\x00");
    input = &bytes;
    const event = (try Event.take(&input)).?;
    try testing.expectEqualStrings("abc", event.name);
    try testing.expectEqual(@as(u32, 7), event.cookie);
    try testing.expectEqual(@as(usize, 0), input.len);
    bytes[19] = 'd';
    input = &bytes;
    try testing.expectError(error.InvalidEvent, Event.take(&input));
    header.len = 5;
    @memcpy(bytes[0..16], std.mem.asBytes(&header));
    input = &bytes;
    try testing.expectError(error.InvalidEvent, Event.take(&input));
    try testing.expect(inside("dir", "dir/a"));
    try testing.expect(!inside("dir", "directory/a"));
}

test "file observer: live registered roots update watches and notify clients" {
    const testing = std.testing;
    const TestServer = @import("../testutil/server.zig").TestServer;
    const ws = @import("../testutil/ws_client.zig");
    const ts = try TestServer.init(testing.allocator);
    defer ts.stop();
    const client = try ws.connect(ts, testing.allocator);
    defer client.close();
    try testing.expect(ts.app.file_ctx.observer == null);
    try ts.app.file_ctx.startObserver();
    for ([_][]const u8{ "first", "replacement" }) |base| {
        var path_buffer: [Dir.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/klipper", .{base});
        const dir = try ts.tmp.dir.createDirPathOpen(ts.io, path, .{});
        defer dir.close(ts.io);
        try dir.createDirPath(ts.io, "config");
        try dir.createDirPath(ts.io, "docs");
        const absolute = try dir.realPathFileAlloc(ts.io, ".", testing.allocator);
        defer testing.allocator.free(absolute);
        ts.app.core.lock(ts.io);
        ts.app.registerKlipperRoots(absolute);
        ts.app.core.unlock(ts.io);
        for (0..2) |_| {
            client.read_deadline = .fromNow(ts.io, .{ .raw = .fromSeconds(3), .clock = .awake });
            const frame = try client.readFrame();
            defer testing.allocator.free(frame.data);
            const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame.data, .{});
            defer parsed.deinit();
            const change = parsed.value.object.get("params").?.array.items[0].object;
            try testing.expectEqualStrings("root_update", change.get("action").?.string);
            try testing.expectEqualStrings("", change.get("item").?.object.get("path").?.string);
        }
        try dir.writeFile(ts.io, .{ .sub_path = "docs/readme.txt", .data = "docs" });
        client.read_deadline = .fromNow(ts.io, .{ .raw = .fromSeconds(3), .clock = .awake });
        const frame = try client.readFrame();
        defer testing.allocator.free(frame.data);
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame.data, .{});
        defer parsed.deinit();
        const item = parsed.value.object.get("params").?.array.items[0].object.get("item").?.object;
        try testing.expectEqualStrings("docs", item.get("root").?.string);
        try testing.expectEqualStrings("readme.txt", item.get("path").?.string);
        try testing.expectEqualStrings("r", item.get("permissions").?.string);
    }
}

test "file observer: allocation failures release watched paths and pending sources" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "child");
    const path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(path);
    const roots = [_]files.Root{.{ .name = "gcodes", .path = path, .full_access = true }};
    const Harness = struct {
        fn run(alloc: std.mem.Allocator, root_slice: []const files.Root) !void {
            var ctx: files.FileCtx = .{ .gpa = alloc, .roots = root_slice, .bus = null, .io = testing.io };
            defer ctx.deinit();
            const observer = try alloc.create(Observer);
            defer alloc.destroy(observer);
            try observer.init(&ctx);
            defer observer.deinit();
            try observer.queue(.create_file, 0, "file.gcode", false, null);
            try observer.queue(.move_file, 0, "moved.gcode", true, .{ .root = 0, .path = "source.gcode" });
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Harness.run, .{&roots});
}

test "fuzz file observer: bounded native event decoding and coalescing" {
    const testing = std.testing;
    const Ctx = struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            const root_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
            defer testing.allocator.free(root_path);
            const roots = [_]files.Root{.{ .name = "gcodes", .path = root_path, .full_access = true }};
            var ctx: files.FileCtx = .{ .gpa = testing.allocator, .roots = &roots, .bus = null, .io = testing.io };
            defer ctx.deinit();
            const observer = try testing.allocator.create(Observer);
            defer testing.allocator.destroy(observer);
            try observer.init(&ctx);
            defer observer.deinit();
            try observer.updateRoot(0);
            observer.active.store(true, .release);
            try observer.consume(&.{});
            var bytes: [512]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const data = &bytes;
            var input: []const u8 = data;
            while (Event.take(&input) catch null) |event| {
                observer.process(event) catch |err| switch (err) {
                    error.ObserverOverflow, error.ObserverRootChanged => {},
                    else => return err,
                };
            }
            const path = if (data.len > 0 and data[0] & 1 == 0) "a.gcode" else "dir/b.gcode";
            try observer.queue(.create_file, 0, path, false, null);
            try observer.queue(.modify_file, 0, path, true, null);
            try observer.movedFrom(0, path, 1, false);
            try observer.movedTo(0, "renamed.gcode", 1, false);
            try testing.expectEqual(@as(usize, 1), observer.pending_count);
            try testing.expectEqual(Action.create_file, observer.pending[0].action);
            try observer.queue(.delete_file, 0, "renamed.gcode", true, null);
            try testing.expectEqual(@as(usize, 0), observer.pending_count);
            try observer.movedFrom(0, "original.gcode", 2, false);
            try observer.movedTo(0, "intermediate.gcode", 2, false);
            try observer.movedFrom(0, "intermediate.gcode", 3, false);
            try observer.movedTo(0, "last.gcode", 3, false);
            try testing.expectEqualStrings("original.gcode", observer.pending[0].source.?.path);
            observer.freePending(observer.takePending(0));
            try observer.queue(.modify_file, 0, path, true, null);
            observer.pending[0].deadline = 0;
            try observer.flush();
            try testing.expectEqual(@as(usize, 0), observer.pending_count);
            try observer.queue(.create_dir, 0, "dir", true, null);
            try observer.queue(.create_file, 0, "dir/open.gcode", false, null);
            observer.pending[0].deadline = 0;
            try observer.flush();
            try testing.expect(observer.pending[0].deadline == null);
            try observer.queue(.modify_file, 0, "dir/open.gcode", true, null);
            observer.pending[0].deadline = 0;
            try observer.flush();
            try testing.expectEqual(@as(usize, 0), observer.pending_count);
            try testing.expect(observer.path_bytes <= max_owned_path_bytes);
            try observer.removeTree(0, "");
            var worker_ctx: files.FileCtx = .{ .gpa = std.heap.smp_allocator, .roots = &roots, .bus = null, .io = testing.io };
            defer worker_ctx.deinit();
            try worker_ctx.startObserver();
            try worker_ctx.startObserver();
            worker_ctx.stopObserver();
            worker_ctx.stopObserver();
        }
    };
    try testing.fuzz({}, Ctx.run, .{});
}

test "file observer: startup watch limit fails without retaining partial state" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for (0..max_watches) |index| {
        var buffer: [32]u8 = undefined;
        try tmp.dir.createDirPath(testing.io, try std.fmt.bufPrint(&buffer, "dir-{d}", .{index}));
    }
    const path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(path);
    const roots = [_]files.Root{.{ .name = "gcodes", .path = path, .full_access = true }};
    var ctx: files.FileCtx = .{ .gpa = testing.allocator, .roots = &roots, .bus = null, .io = testing.io };
    defer ctx.deinit();
    try testing.expectError(error.ObserverWatchLimit, ctx.startObserver());
    try testing.expect(ctx.observer == null);
}
