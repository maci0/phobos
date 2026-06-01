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

/// Type-erased frame writer bound to a live transport (a
/// `std.http.Server.WebSocket`). `ctx` is the transport handle; `bytes` is one
/// complete text frame to emit. Returning an error signals the connection is
/// dead (write failed / socket closed). Defined here so `Connections` need not
/// import the transport layer (avoids an import cycle).
pub const WriteFn = *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void;

/// One active WebSocket connection.
pub const Connection = struct {
    /// Monotonic connection id (Moonraker `uid`). Stable for the connection's
    /// lifetime.
    id: u64,
    /// True once `server.connection.identify` has run for this connection.
    identified: bool = false,
    /// Identify metadata; the slices are owned by `Connections.alloc`.
    client: ClientData = .{},
    /// Per-connection write mutex. EVERY write to this connection's WebSocket —
    /// JSON-RPC responses from the read loop AND notifications from the emitter —
    /// must be held while writing, so frames never interleave. Reads are
    /// unaffected (std.http WS uses separate input/output buffers).
    write_mutex: Io.Mutex = .init,
    /// Live transport handle + writer, installed by the serve loop while the
    /// session is active and cleared on exit. `null` => not yet attached (or
    /// already torn down); writes are dropped.
    write_ctx: ?*anyopaque = null,
    write_fn: ?WriteFn = null,
    /// Set once a write to this connection has failed; the serve loop checks it
    /// to tear the session down. Guarded by `write_mutex`.
    dead: bool = false,
    /// Subscription topic set for status updates (`printer.objects.subscribe`).
    /// Empty => not subscribed. Owned by `Connections.alloc`; guarded by the
    /// registry mutex. Status notifications are gated on membership here; all
    /// other notifications broadcast regardless.
    subs: std.StringHashMapUnmanaged(void) = .empty,
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
        var it = c.subs.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        c.subs.deinit(self.alloc);
        self.alloc.destroy(c);
    }

    /// Attach the live transport writer to a connection for the duration of its
    /// session. Held under the connection's own write mutex so an in-flight
    /// notification observes a consistent (ctx, fn) pair.
    pub fn attachWriter(self: *Connections, io: Io, conn: *Connection, ctx: *anyopaque, write_fn: WriteFn) void {
        _ = self;
        conn.write_mutex.lockUncancelable(io);
        defer conn.write_mutex.unlock(io);
        conn.write_ctx = ctx;
        conn.write_fn = write_fn;
    }

    /// Detach the transport writer (session ending). Subsequent `writeFrame`
    /// calls become no-ops.
    pub fn detachWriter(self: *Connections, io: Io, conn: *Connection) void {
        _ = self;
        conn.write_mutex.lockUncancelable(io);
        defer conn.write_mutex.unlock(io);
        conn.write_ctx = null;
        conn.write_fn = null;
    }

    /// Write one complete frame to a connection, holding its per-connection write
    /// mutex so responses and notifications never interleave. On write failure
    /// the connection is flagged `dead` and the error is returned. A no-op (no
    /// error) when no writer is attached. Thread-safe; never blocks reads.
    pub fn writeFrame(self: *Connections, io: Io, conn: *Connection, bytes: []const u8) !void {
        _ = self;
        conn.write_mutex.lockUncancelable(io);
        defer conn.write_mutex.unlock(io);
        if (conn.dead) return error.ConnectionDead;
        const wfn = conn.write_fn orelse return;
        const ctx = conn.write_ctx orelse return;
        wfn(ctx, bytes) catch |err| {
            conn.dead = true;
            return err;
        };
    }

    /// True if the connection has been flagged dead by a failed write.
    pub fn isDead(self: *Connections, io: Io, conn: *Connection) bool {
        _ = self;
        conn.write_mutex.lockUncancelable(io);
        defer conn.write_mutex.unlock(io);
        return conn.dead;
    }

    /// Snapshot the current set of connection pointers into `out_alloc` so the
    /// notification bus can fan out without holding the registry mutex while it
    /// writes (writes take per-connection mutexes, which must not nest under the
    /// registry lock). Caller frees the returned slice. Thread-safe.
    pub fn snapshot(self: *Connections, io: Io, out_alloc: std.mem.Allocator) ![]*Connection {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return out_alloc.dupe(*Connection, self.list.items);
    }

    /// Add status-update topics to a connection's subscription set. Duplicate
    /// topics are ignored. Strings are copied into the registry allocator.
    /// Thread-safe.
    pub fn subscribe(self: *Connections, io: Io, conn: *Connection, topics: []const []const u8) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (topics) |t| {
            if (conn.subs.contains(t)) continue;
            const key = try self.alloc.dupe(u8, t);
            errdefer self.alloc.free(key);
            try conn.subs.put(self.alloc, key, {});
        }
    }

    /// Remove topics from a connection's subscription set. No-op for absent
    /// topics. Thread-safe.
    pub fn unsubscribe(self: *Connections, io: Io, conn: *Connection, topics: []const []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (topics) |t| {
            if (conn.subs.fetchRemove(t)) |kv| self.alloc.free(kv.key);
        }
    }

    /// True if `conn` is subscribed to `topic`. Thread-safe.
    pub fn isSubscribed(self: *Connections, io: Io, conn: *Connection, topic: []const u8) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return conn.subs.contains(topic);
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

// A capturing test writer that records every frame it is handed, so we can
// assert ordering and content without real sockets.
const RecordWriter = struct {
    alloc: std.mem.Allocator,
    frames: std.ArrayList([]u8) = .empty,
    fail: bool = false,

    fn deinit(self: *RecordWriter) void {
        for (self.frames.items) |f| self.alloc.free(f);
        self.frames.deinit(self.alloc);
    }

    fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *RecordWriter = @ptrCast(@alignCast(ctx));
        if (self.fail) return error.WriteFailed;
        const dup = try self.alloc.dupe(u8, bytes);
        errdefer self.alloc.free(dup);
        try self.frames.append(self.alloc, dup);
    }
};

test "writeFrame routes bytes through the attached writer in order" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var conns = Connections.init(std.testing.allocator, &core);
    defer conns.deinit(io);

    const c = try conns.add(io);
    var rec = RecordWriter{ .alloc = std.testing.allocator };
    defer rec.deinit();
    conns.attachWriter(io, c, &rec, RecordWriter.write);

    try conns.writeFrame(io, c, "one");
    try conns.writeFrame(io, c, "two");

    try std.testing.expectEqual(@as(usize, 2), rec.frames.items.len);
    try std.testing.expectEqualStrings("one", rec.frames.items[0]);
    try std.testing.expectEqualStrings("two", rec.frames.items[1]);
}

test "writeFrame is a no-op with no writer attached" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var conns = Connections.init(std.testing.allocator, &core);
    defer conns.deinit(io);

    const c = try conns.add(io);
    // No attachWriter: must not error, must not crash.
    try conns.writeFrame(io, c, "ignored");
    try std.testing.expect(!conns.isDead(io, c));
}

test "writeFrame flags the connection dead on write failure" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var conns = Connections.init(std.testing.allocator, &core);
    defer conns.deinit(io);

    const c = try conns.add(io);
    var rec = RecordWriter{ .alloc = std.testing.allocator, .fail = true };
    defer rec.deinit();
    conns.attachWriter(io, c, &rec, RecordWriter.write);

    try std.testing.expectError(error.WriteFailed, conns.writeFrame(io, c, "x"));
    try std.testing.expect(conns.isDead(io, c));
    // Once dead, further writes short-circuit with ConnectionDead.
    try std.testing.expectError(error.ConnectionDead, conns.writeFrame(io, c, "y"));
}

test "detachWriter stops further delivery" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var conns = Connections.init(std.testing.allocator, &core);
    defer conns.deinit(io);

    const c = try conns.add(io);
    var rec = RecordWriter{ .alloc = std.testing.allocator };
    defer rec.deinit();
    conns.attachWriter(io, c, &rec, RecordWriter.write);
    try conns.writeFrame(io, c, "before");
    conns.detachWriter(io, c);
    try conns.writeFrame(io, c, "after"); // dropped
    try std.testing.expectEqual(@as(usize, 1), rec.frames.items.len);
}

test "subscribe/unsubscribe/isSubscribed track topics" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var conns = Connections.init(std.testing.allocator, &core);
    defer conns.deinit(io);

    const c = try conns.add(io);
    try std.testing.expect(!conns.isSubscribed(io, c, "toolhead"));

    try conns.subscribe(io, c, &.{ "toolhead", "extruder" });
    try std.testing.expect(conns.isSubscribed(io, c, "toolhead"));
    try std.testing.expect(conns.isSubscribed(io, c, "extruder"));

    // Duplicate subscribe is idempotent.
    try conns.subscribe(io, c, &.{"toolhead"});
    try std.testing.expect(conns.isSubscribed(io, c, "toolhead"));

    conns.unsubscribe(io, c, &.{"toolhead"});
    try std.testing.expect(!conns.isSubscribed(io, c, "toolhead"));
    try std.testing.expect(conns.isSubscribed(io, c, "extruder"));

    // Unsubscribe of an absent topic is a no-op.
    conns.unsubscribe(io, c, &.{"missing"});
    try std.testing.expect(conns.isSubscribed(io, c, "extruder"));
}

test "snapshot returns the live connection set" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var conns = Connections.init(std.testing.allocator, &core);
    defer conns.deinit(io);

    const a = try conns.add(io);
    const b = try conns.add(io);
    const snap = try conns.snapshot(io, std.testing.allocator);
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqual(@as(usize, 2), snap.len);
    var seen_a = false;
    var seen_b = false;
    for (snap) |c| {
        if (c == a) seen_a = true;
        if (c == b) seen_b = true;
    }
    try std.testing.expect(seen_a and seen_b);
}

test "fuzz_subscribe: random subscribe/unsubscribe never crashes or leaks" {
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

            const c = try conns.add(io);
            const topics = [_][]const u8{ "toolhead", "extruder", "gcode_move", "heater_bed" };
            for (ops) |b| {
                const t = topics[(b >> 1) % topics.len];
                if (b & 1 == 0) {
                    try conns.subscribe(io, c, &.{t});
                    try std.testing.expect(conns.isSubscribed(io, c, t));
                } else {
                    conns.unsubscribe(io, c, &.{t});
                    try std.testing.expect(!conns.isSubscribed(io, c, t));
                }
            }
        }
    }.run, .{});
}

test "fuzz_writeframe: random frames delivered in order, never crash" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var ctl: [64]u8 = undefined;
            smith.bytesWithHash(&ctl, 0);

            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();

            var core = Core.init();
            var conns = Connections.init(std.heap.smp_allocator, &core);
            defer conns.deinit(io);

            const c = try conns.add(io);
            var rec = RecordWriter{ .alloc = std.heap.smp_allocator };
            defer rec.deinit();
            conns.attachWriter(io, c, &rec, RecordWriter.write);

            var expected: usize = 0;
            for (ctl, 0..) |b, i| {
                var buf: [8]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "f{d}", .{i}) catch continue;
                if (b & 0x80 != 0) {
                    conns.detachWriter(io, c);
                    conns.attachWriter(io, c, &rec, RecordWriter.write);
                }
                try conns.writeFrame(io, c, msg);
                expected += 1;
            }
            try std.testing.expectEqual(expected, rec.frames.items.len);
            // Order preserved: each frame index strictly increases.
            for (rec.frames.items, 0..) |f, i| {
                var buf: [8]u8 = undefined;
                const want = std.fmt.bufPrint(&buf, "f{d}", .{i}) catch unreachable;
                try std.testing.expectEqualStrings(want, f);
            }
        }
    }.run, .{});
}
