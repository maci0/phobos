//! Registry of active WebSocket connections.
//!
//! Each live WS connection gets a monotonic `u64` id (Moonraker's `sc.uid`),
//! handed out under the serialized `Core` so ids are globally ordered and
//! distinct across all connection tasks. The registry tracks the set of active
//! connections so a later notification bus can fan out to every client; for now
//! it provides add / remove / count / iterate plus the id allocator.
//!
//! Thread-safety: all mutating and reading operations take the registry's own
//! `Io.Mutex`. `nextId` delegates to `Core.nextSeq` under the Core lock so ids
//! share the one global monotonic sequence with the rest of the server.

const std = @import("std");
const Io = std.Io;
const Core = @import("core.zig").Core;

/// Identify metadata supplied by `server.connection.identify`. All fields are
/// owned by the connection record (duped into the registry allocator) so they
/// outlive the per-request arena the params were parsed in.
pub const ClientData = struct {
    name: []const u8 = "",
    version: []const u8 = "",
    type: []const u8 = "",
    url: []const u8 = "",
};

/// One active WebSocket connection.
pub const Connection = struct {
    /// Monotonic connection id (Moonraker `uid`). Stable for the connection's
    /// lifetime.
    id: u64,
    /// True once `server.connection.identify` has run for this connection.
    identified: bool = false,
    /// Identify metadata; the slices are owned by `Connections.alloc`.
    client: ClientData = .{},
};

pub const Connections = struct {
    alloc: std.mem.Allocator,
    core: *Core,
    mutex: Io.Mutex = .init,
    /// Pointer-stable storage: each Connection is heap-allocated so handlers can
    /// hold a `*Connection` while the list mutates underneath them.
    list: std.ArrayList(*Connection) = .empty,

    pub fn init(alloc: std.mem.Allocator, core: *Core) Connections {
        return .{ .alloc = alloc, .core = core };
    }

    pub fn deinit(self: *Connections, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.list.items) |c| self.freeConn(c);
        self.list.deinit(self.alloc);
    }

    fn freeConn(self: *Connections, c: *Connection) void {
        self.alloc.free(c.client.name);
        self.alloc.free(c.client.version);
        self.alloc.free(c.client.type);
        self.alloc.free(c.client.url);
        self.alloc.destroy(c);
    }

    /// Allocate the next monotonic connection id under the Core lock so it
    /// shares the one global sequence. Safe to call concurrently.
    pub fn nextId(self: *Connections, io: Io) u64 {
        self.core.lock(io);
        defer self.core.unlock(io);
        return self.core.nextSeq();
    }

    /// Create and register a fresh connection with id from `nextId`. Returns a
    /// pointer-stable `*Connection` the caller (and handlers) can retain until
    /// `remove`. Thread-safe.
    pub fn add(self: *Connections, io: Io) !*Connection {
        const id = self.nextId(io);
        const c = try self.alloc.create(Connection);
        errdefer self.alloc.destroy(c);
        c.* = .{ .id = id };

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.list.append(self.alloc, c);
        return c;
    }

    /// Remove a connection by identity and free it. No-op if not present.
    /// Thread-safe.
    pub fn remove(self: *Connections, io: Io, conn: *Connection) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.list.items, 0..) |c, i| {
            if (c == conn) {
                _ = self.list.swapRemove(i);
                self.freeConn(c);
                return;
            }
        }
    }

    /// Number of active connections. Thread-safe.
    pub fn count(self: *Connections, io: Io) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.list.items.len;
    }

    /// True if a connection with `id` is currently registered. Thread-safe.
    pub fn has(self: *Connections, io: Io, id: u64) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.list.items) |c| if (c.id == id) return true;
        return false;
    }

    /// Store identify metadata on a connection, replacing any prior values.
    /// Copies all strings into the registry allocator. Thread-safe.
    pub fn identify(self: *Connections, io: Io, conn: *Connection, data: ClientData) !void {
        const name = try self.alloc.dupe(u8, data.name);
        errdefer self.alloc.free(name);
        const version = try self.alloc.dupe(u8, data.version);
        errdefer self.alloc.free(version);
        const ctype = try self.alloc.dupe(u8, data.type);
        errdefer self.alloc.free(ctype);
        const url = try self.alloc.dupe(u8, data.url);
        errdefer self.alloc.free(url);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        // Free any previously-stored values.
        self.alloc.free(conn.client.name);
        self.alloc.free(conn.client.version);
        self.alloc.free(conn.client.type);
        self.alloc.free(conn.client.url);
        conn.client = .{ .name = name, .version = version, .type = ctype, .url = url };
        conn.identified = true;
    }
};

// --- tests ---------------------------------------------------------------

test "nextId is monotonic and distinct" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var conns = Connections.init(std.testing.allocator, &core);
    defer conns.deinit(io);

    const a = conns.nextId(io);
    const b = conns.nextId(io);
    const c = conns.nextId(io);
    try std.testing.expect(b > a);
    try std.testing.expect(c > b);
}

test "add assigns increasing ids and tracks count" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var conns = Connections.init(std.testing.allocator, &core);
    defer conns.deinit(io);

    try std.testing.expectEqual(@as(usize, 0), conns.count(io));
    const c1 = try conns.add(io);
    const c2 = try conns.add(io);
    try std.testing.expect(c2.id > c1.id);
    try std.testing.expectEqual(@as(usize, 2), conns.count(io));
    try std.testing.expect(conns.has(io, c1.id));
    try std.testing.expect(conns.has(io, c2.id));
}

test "remove drops the connection and frees it" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var conns = Connections.init(std.testing.allocator, &core);
    defer conns.deinit(io);

    const c1 = try conns.add(io);
    const c2 = try conns.add(io);
    const id1 = c1.id;
    conns.remove(io, c1);
    try std.testing.expectEqual(@as(usize, 1), conns.count(io));
    try std.testing.expect(!conns.has(io, id1));
    try std.testing.expect(conns.has(io, c2.id));

    // Double remove is a no-op.
    conns.remove(io, c1);
    try std.testing.expectEqual(@as(usize, 1), conns.count(io));
}

test "identify stores client data and sets identified" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var conns = Connections.init(std.testing.allocator, &core);
    defer conns.deinit(io);

    const c = try conns.add(io);
    try std.testing.expect(!c.identified);
    try conns.identify(io, c, .{ .name = "mainsail", .version = "0.1", .type = "web", .url = "http://x" });
    try std.testing.expect(c.identified);
    try std.testing.expectEqualStrings("mainsail", c.client.name);
    try std.testing.expectEqualStrings("web", c.client.type);

    // Re-identify replaces (and frees) the prior strings.
    try conns.identify(io, c, .{ .name = "fluidd", .version = "2", .type = "web", .url = "u" });
    try std.testing.expectEqualStrings("fluidd", c.client.name);
}

const Worker = struct {
    io: Io,
    conns: *Connections,
    ids: []u64,
    base: usize,
    count: usize,
};

fn addWorker(w: *Worker) void {
    var i: usize = 0;
    while (i < w.count) : (i += 1) {
        const c = w.conns.add(w.io) catch return;
        w.ids[w.base + i] = c.id;
    }
}

test "concurrent add: ids are globally distinct, count is exact" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var conns = Connections.init(std.testing.allocator, &core);
    defer conns.deinit(io);

    const workers = 4;
    const per = 100;
    const total = workers * per;
    var ids: [total]u64 = undefined;
    var ctxs: [workers]Worker = undefined;
    for (&ctxs, 0..) |*w, k| {
        w.* = .{ .io = io, .conns = &conns, .ids = &ids, .base = k * per, .count = per };
    }
    var futs: [workers]@TypeOf(io.async(addWorker, .{&ctxs[0]})) = undefined;
    for (&futs, 0..) |*f, k| f.* = io.async(addWorker, .{&ctxs[k]});
    for (&futs) |*f| f.await(io);

    try std.testing.expectEqual(@as(usize, total), conns.count(io));
    std.mem.sort(u64, &ids, {}, comptime std.sort.asc(u64));
    for (ids[1..], 1..) |id, i| {
        try std.testing.expect(id > ids[i - 1]); // strictly increasing => distinct
    }
}

test "fuzz_connections: random add/remove sequence keeps count consistent" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var ops: [128]u8 = undefined;
            smith.bytesWithHash(&ops, 0);

            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();

            var core = Core.init();
            var conns = Connections.init(std.heap.smp_allocator, &core);
            defer conns.deinit(io);

            var live: std.ArrayList(*Connection) = .empty;
            defer live.deinit(std.heap.smp_allocator);

            var expected: usize = 0;
            for (ops) |b| {
                if (b & 1 == 0 or live.items.len == 0) {
                    const c = try conns.add(io);
                    try live.append(std.heap.smp_allocator, c);
                    expected += 1;
                } else {
                    const idx = b % live.items.len;
                    const c = live.swapRemove(idx);
                    conns.remove(io, c);
                    expected -= 1;
                }
                try std.testing.expectEqual(expected, conns.count(io));
            }
        }
    }.run, .{});
}
