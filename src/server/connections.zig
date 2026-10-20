//! Registry of active WebSocket connections.
//!
//! Each live WS connection gets a monotonic `u64` id (Moonraker's `sc.uid`),
//! handed out under the serialized `Core` so ids are globally ordered and
//! distinct across all connection tasks. The registry tracks the set of active
//! connections so a later notification bus can fan out to every client; for now
//! it provides add / remove / count / iterate plus the id allocator.
//!
//! Thread-safety: all mutating and reading operations take the registry's own
//! `Io.Mutex`. Connection ids use `Core.nextSeq` under the Core lock so ids
//! share the one global monotonic sequence with the rest of the server.

const std = @import("std");
const Io = std.Io;
const Core = @import("core.zig").Core;
const jv = @import("../json/value.zig");

pub const max_subscription_objects = 256;
pub const max_subscription_name_len = 256;

pub const StatusMessage = struct { method: []const u8, params: std.json.Value };

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
    /// Authenticated user (Moonraker `user_info`), owned by `Connections.alloc`.
    /// The serve loop replaces this under the registry mutex; revocation reads
    /// it under that mutex and retains the string until the serve loop frees it.
    user: ?[]const u8 = null,
    /// The upgrade request failed authentication: `auth_required` methods are
    /// refused until identify supplies credentials. Broadcast reads atomically.
    need_auth: std.atomic.Value(bool) = .init(false),
    /// Client address, borrowed from the transport for the session.
    remote_ip: ?[]const u8 = null,
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
    /// Set once a write to this connection has failed; later writes are
    /// skipped. The transport writer shuts the socket down on failure, which
    /// ends the serve loop. Guarded by `write_mutex`.
    dead: bool = false,
    /// Status subscriptions: object names map to null (all fields) or a field
    /// array. Empty means unsubscribed. Keys and values use Connections.alloc
    /// and are guarded by the registry mutex.
    subs: std.json.ObjectMap = .empty,
    /// In-flight broadcast references. Guarded by the registry mutex. `broadcast`
    /// increments this while it writes to the connection with the registry lock
    /// released; `remove` defers the actual free until it returns to 0. Lets the
    /// fan-out drop the registry lock during (possibly blocking) socket writes
    /// without a use-after-free against a concurrent disconnect.
    refs: u32 = 0,
    /// Set by `remove` when a connection is unlinked while `refs > 0`; the last
    /// `broadcast` to release its ref performs the deferred free.
    pending_free: bool = false,
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
        if (c.user) |u| self.alloc.free(u);
        jv.free(self.alloc, .{ .object = c.subs });
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

    /// Write `frame` to every connection (optionally filtered by `topic`
    /// subscription) WITHOUT holding the registry mutex during the (possibly
    /// blocking) socket writes — so one slow client cannot stall connection
    /// add/remove server-wide.
    ///
    /// Safety: under the registry mutex we select the target connections, apply
    /// the subscription filter, and bump each target's `refs` (so a concurrent
    /// `remove` defers the free). We release the mutex, write to each target,
    /// then re-take the mutex to drop the refs and perform any deferred free.
    /// `targets` is built in `alloc` (the caller's per-broadcast arena).
    pub fn broadcast(self: *Connections, io: Io, alloc: std.mem.Allocator, frame: []const u8, topic: ?[]const u8, status: ?StatusMessage) void {
        self.broadcastExcept(io, alloc, frame, topic, status, null);
    }

    pub fn broadcastExcept(self: *Connections, io: Io, alloc: std.mem.Allocator, frame: []const u8, topic: ?[]const u8, status: ?StatusMessage, exclude: ?u64) void {
        const Target = struct { conn: *Connection, frame: []const u8 };
        var targets: std.ArrayList(Target) = .empty;
        defer targets.deinit(alloc);

        // Phase 1: select + pin (refs) under the registry mutex.
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            // Count is known under the lock — size the list once instead of
            // growing it by doubling on every broadcast.
            targets.ensureTotalCapacity(alloc, self.list.items.len) catch {};
            for (self.list.items) |conn| {
                if (exclude == conn.id) continue;
                if (conn.need_auth.load(.acquire)) continue;
                var message = frame;
                if (topic) |t| {
                    if (!conn.subs.contains(t)) continue;
                    if (conn.subs.get(t).? == .array) if (status) |s| {
                        if (s.params != .array or s.params.array.items.len != 2) continue;
                        const filtered = filterStatus(alloc, conn.subs, s.params.array.items[0], false) catch continue;
                        if (filtered.object.count() == 0) continue;
                        message = std.json.Stringify.valueAlloc(alloc, .{
                            .jsonrpc = "2.0",
                            .method = s.method,
                            .params = [_]std.json.Value{ filtered, s.params.array.items[1] },
                        }, .{}) catch continue;
                    };
                }
                conn.refs += 1;
                targets.append(alloc, .{ .conn = conn, .frame = message }) catch {
                    conn.refs -= 1; // OOM: drop this target, keep refs balanced.
                };
            }
        }

        // Phase 2: write outside the lock. A pinned (refs>0) connection cannot be
        // freed by `remove`, so this is safe even if the client disconnects mid-write.
        for (targets.items) |target| self.writeFrame(io, target.conn, target.frame) catch {};

        // Phase 3: release refs; perform any free deferred by `remove`.
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            for (targets.items) |target| {
                const conn = target.conn;
                conn.refs -= 1;
                if (conn.refs == 0 and conn.pending_free) self.freeConn(conn);
            }
        }
    }

    /// Replace one connection's complete subscription. Invalid input or an
    /// allocation failure leaves the previous subscription intact.
    pub fn replaceSubscriptions(self: *Connections, io: Io, conn: *Connection, objects: std.json.Value) !void {
        if (objects != .object or objects.object.count() > max_subscription_objects) return error.InvalidParams;
        var it = objects.object.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.len > max_subscription_name_len) return error.InvalidParams;
            switch (entry.value_ptr.*) {
                .null => {},
                .array => |fields| {
                    if (fields.items.len > max_subscription_objects) return error.InvalidParams;
                    for (fields.items) |field| {
                        if (field != .string or field.string.len > max_subscription_name_len) return error.InvalidParams;
                    }
                },
                else => return error.InvalidParams,
            }
        }
        const replacement = try jv.deepCopy(self.alloc, objects);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        jv.free(self.alloc, .{ .object = conn.subs });
        conn.subs = replacement.object;
    }

    /// Append owned object names from all live connections to an aggregate.
    pub fn appendSubscriptionObjects(self: *Connections, io: Io, alloc: std.mem.Allocator, objects: *std.json.ObjectMap) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.list.items) |conn| {
            for (conn.subs.keys()) |name| {
                if (!objects.contains(name)) {
                    const owned = try alloc.dupe(u8, name);
                    errdefer alloc.free(owned);
                    try objects.put(alloc, owned, .null);
                }
            }
        }
    }

    /// Create a connection while acquiring Core for its globally ordered id.
    pub fn add(self: *Connections, io: Io, need_auth: bool) !*Connection {
        self.core.lock(io);
        defer self.core.unlock(io);
        return self.addLocked(io, need_auth);
    }

    /// Create and register a fresh connection with a globally ordered id. Returns a
    /// pointer-stable `*Connection` the caller (and handlers) can retain until
    /// `remove`. Thread-safe.
    /// Caller holds Core, including authentication and identity setup.
    pub fn addLocked(self: *Connections, io: Io, need_auth: bool) !*Connection {
        const id = self.core.nextSeq();
        const c = try self.alloc.create(Connection);
        errdefer self.alloc.destroy(c);
        c.* = .{ .id = id, .need_auth = .init(need_auth) };

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
                // If a broadcast currently holds a ref, defer the free to it;
                // otherwise free now. Either way the connection is unlinked.
                if (c.refs == 0) self.freeConn(c) else c.pending_free = true;
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

    /// Keep a live connection allocated across a socket write outside Core.
    pub fn pin(self: *Connections, io: Io, id: u64) !*Connection {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.list.items) |conn| if (conn.id == id) {
            conn.refs += 1;
            return conn;
        };
        return error.AgentDisconnected;
    }

    pub fn unpin(self: *Connections, io: Io, conn: *Connection) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        conn.refs -= 1;
        if (conn.refs == 0 and conn.pending_free) self.freeConn(conn);
    }

    /// Record the authenticated user (copied) and clear `need_auth`. Called
    /// only from the connection's own serve loop.
    pub fn setUser(self: *Connections, io: Io, conn: *Connection, user: []const u8) !void {
        const owned = try self.alloc.dupe(u8, user);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (conn.user) |old| self.alloc.free(old);
        conn.user = owned;
        conn.need_auth.store(false, .release);
    }

    /// Revoke existing sessions after a durable logout or deletion. The serve
    /// loop retains ownership of its user string until reauthentication or close.
    pub fn invalidateUser(self: *Connections, io: Io, user: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.list.items) |conn| {
            if (conn.user) |name| if (std.mem.eql(u8, name, user)) conn.need_auth.store(true, .release);
        }
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

/// Prune status to the requested objects and fields. Returned maps borrow the
/// source values; alloc must be a request arena. Serialize before either source changes.
pub fn filterStatus(alloc: std.mem.Allocator, subscriptions: std.json.ObjectMap, status: std.json.Value, include_empty: bool) !std.json.Value {
    var out: std.json.ObjectMap = .empty;
    if (status != .object) return .{ .object = out };
    var it = status.object.iterator();
    while (it.next()) |entry| {
        const fields = subscriptions.get(entry.key_ptr.*) orelse continue;
        if (fields == .null) {
            try out.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
        } else if (fields == .array and entry.value_ptr.* == .object) {
            var selected: std.json.ObjectMap = .empty;
            for (fields.array.items) |field| {
                if (entry.value_ptr.object.get(field.string)) |value| try selected.put(alloc, field.string, value);
            }
            if (include_empty or selected.count() != 0) try out.put(alloc, entry.key_ptr.*, .{ .object = selected });
        }
    }
    return .{ .object = out };
}

// --- tests ---------------------------------------------------------------

test "connection ids are monotonic and distinct" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var conns = Connections.init(std.testing.allocator, &core);
    defer conns.deinit(io);

    const a = (try conns.add(io, false)).id;
    const b = (try conns.add(io, false)).id;
    const c = (try conns.add(io, false)).id;
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
    const c1 = try conns.add(io, false);
    const c2 = try conns.add(io, false);
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

    const c1 = try conns.add(io, false);
    const c2 = try conns.add(io, false);
    const id1 = c1.id;
    conns.remove(io, c1);
    try std.testing.expectEqual(@as(usize, 1), conns.count(io));
    try std.testing.expect(!conns.has(io, id1));
    try std.testing.expect(conns.has(io, c2.id));

    // Double remove is a no-op.
    conns.remove(io, c1);
    try std.testing.expectEqual(@as(usize, 1), conns.count(io));
}

test "setUser copies the user, replaces the old one and clears need_auth" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var core = Core.init();
    var conns = Connections.init(std.testing.allocator, &core);
    defer conns.deinit(io);

    const c = try conns.add(io, false);
    c.need_auth.store(true, .release);
    var name = "alice".*;
    try conns.setUser(io, c, &name);
    name[0] = 'X';
    try std.testing.expectEqualStrings("alice", c.user.?);
    try std.testing.expect(!c.need_auth.load(.acquire));
    try conns.setUser(io, c, "bob");
    try std.testing.expectEqualStrings("bob", c.user.?);
}

test "broadcast skips unauthenticated connections until identify authenticates" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var core = Core.init();
    var conns = Connections.init(alloc, &core);
    defer conns.deinit(io);
    const conn = try conns.add(io, true);
    var writer = RecordWriter{ .alloc = alloc };
    defer writer.deinit();
    conns.attachWriter(io, conn, &writer, RecordWriter.write);
    defer conns.detachWriter(io, conn);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    conns.broadcast(io, arena.allocator(), "private output", null, null);
    try std.testing.expectEqual(@as(usize, 0), writer.frames.items.len);
    try conns.setUser(io, conn, "authenticated");
    conns.broadcast(io, arena.allocator(), "private output", null, null);
    try std.testing.expectEqual(@as(usize, 1), writer.frames.items.len);
    try std.testing.expectEqualStrings("private output", writer.frames.items[0]);
}

test "revocation retains user ownership and blocks only matching sessions" {
    const io = std.testing.io;
    var core = Core.init();
    var conns = Connections.init(std.testing.allocator, &core);
    defer conns.deinit(io);
    const alice = try conns.add(io, false);
    const bob = try conns.add(io, false);
    try conns.setUser(io, alice, "alice");
    try conns.setUser(io, bob, "bob");
    const original = alice.user.?.ptr;
    conns.invalidateUser(io, "alice");
    try std.testing.expect(alice.need_auth.load(.acquire));
    try std.testing.expect(!bob.need_auth.load(.acquire));
    try std.testing.expect(alice.user.?.ptr == original);
    try std.testing.expectEqualStrings("alice", alice.user.?);
    try conns.setUser(io, alice, "new identity");
    conns.invalidateUser(io, "alice");
    try std.testing.expect(!alice.need_auth.load(.acquire));
    try std.testing.expectEqualStrings("new identity", alice.user.?);
}

test "fuzz session revocation matches complete owned user names" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            const io = std.testing.io;
            var core = Core.init();
            var conns = Connections.init(std.testing.allocator, &core);
            defer conns.deinit(io);
            const conn = try conns.add(io, false);
            var name: [32]u8 = undefined;
            const len = smith.valueRangeAtMostWithHash(u8, 0, name.len, 0);
            smith.bytesWithHash(name[0..len], 1);
            try conns.setUser(io, conn, name[0..len]);
            conns.invalidateUser(io, name[0..len]);
            try std.testing.expect(conn.need_auth.load(.acquire));
            try conns.setUser(io, conn, "another");
            conns.invalidateUser(io, name[0..len]);
            try std.testing.expectEqual(std.mem.eql(u8, name[0..len], "another"), conn.need_auth.load(.acquire));
        }
    }.run, .{});
}

test "fuzz setUser owns every user it stores" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var core = Core.init();
            var conns = Connections.init(std.testing.allocator, &core);
            defer conns.deinit(io);
            const c = try conns.add(io, false);
            var buf: [32]u8 = undefined;
            for (0..smith.valueRangeAtMostWithHash(u8, 0, 4, 0)) |i| {
                const n = smith.valueRangeAtMostWithHash(u8, 0, buf.len, @intCast(i + 1));
                smith.bytesWithHash(buf[0..n], @intCast(i + 10));
                try conns.setUser(io, c, buf[0..n]);
                try std.testing.expectEqualSlices(u8, buf[0..n], c.user.?);
            }
        }
    }.run, .{});
}

test "identify stores client data and sets identified" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var conns = Connections.init(std.testing.allocator, &core);
    defer conns.deinit(io);

    const c = try conns.add(io, false);
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
        const c = w.conns.add(w.io, false) catch return;
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
                    const c = try conns.add(io, false);
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

    const c = try conns.add(io, false);
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

    const c = try conns.add(io, false);
    // No attachWriter: must not error, must not crash.
    try conns.writeFrame(io, c, "ignored");
    try std.testing.expect(!c.dead);
}

test "writeFrame flags the connection dead on write failure" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var conns = Connections.init(std.testing.allocator, &core);
    defer conns.deinit(io);

    const c = try conns.add(io, false);
    var rec = RecordWriter{ .alloc = std.testing.allocator, .fail = true };
    defer rec.deinit();
    conns.attachWriter(io, c, &rec, RecordWriter.write);

    try std.testing.expectError(error.WriteFailed, conns.writeFrame(io, c, "x"));
    try std.testing.expect(c.dead);
    // Once dead, further writes short-circuit with ConnectionDead.
    try std.testing.expectError(error.ConnectionDead, conns.writeFrame(io, c, "y"));
}

test "broadcast: connection removed during its own write is freed via deferred ref" {
    // Regression for the refcounted fan-out: broadcast drops the registry lock
    // during writes; a write callback that disconnects its own connection must
    // not UAF and must be freed exactly once (testing.allocator enforces both).
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var conns = Connections.init(std.testing.allocator, &core);
    defer conns.deinit(io);

    const c = try conns.add(io, false);
    const Remover = struct {
        conns: *Connections,
        conn: *Connection,
        io: Io,
        called: bool = false,
        fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
            _ = bytes;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.called = true;
            self.conns.remove(self.io, self.conn); // disconnect mid-broadcast
        }
    };
    var rem = Remover{ .conns = &conns, .conn = c, .io = io };
    conns.attachWriter(io, c, &rem, Remover.write);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    conns.broadcast(io, arena.allocator(), "frame", null, null);

    try std.testing.expect(rem.called);
    try std.testing.expectEqual(@as(usize, 0), conns.count(io));
}

test "detachWriter stops further delivery" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var conns = Connections.init(std.testing.allocator, &core);
    defer conns.deinit(io);

    const c = try conns.add(io, false);
    var rec = RecordWriter{ .alloc = std.testing.allocator };
    defer rec.deinit();
    conns.attachWriter(io, c, &rec, RecordWriter.write);
    try conns.writeFrame(io, c, "before");
    conns.detachWriter(io, c);
    try conns.writeFrame(io, c, "after"); // dropped
    try std.testing.expectEqual(@as(usize, 1), rec.frames.items.len);
}

test "subscription replacement filters fields and removes stale aggregate names" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var core = Core.init();
    var conns = Connections.init(alloc, &core);
    defer conns.deinit(io);
    const conn = try conns.add(io, false);
    var rec: RecordWriter = .{ .alloc = alloc };
    defer rec.deinit();
    conns.attachWriter(io, conn, &rec, RecordWriter.write);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const objects = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"toolhead\":[\"position\"]}", .{});
    try conns.replaceSubscriptions(io, conn, objects);
    const params = try std.json.parseFromSliceLeaky(std.json.Value, a, "[{\"toolhead\":{\"position\":[1,2,3],\"velocity\":4},\"extruder\":{\"temperature\":21}},10]", .{});
    conns.broadcast(io, a, "unfiltered", "toolhead", .{ .method = "notify_status_update", .params = params });
    try std.testing.expectEqual(@as(usize, 1), rec.frames.items.len);
    const message = try std.json.parseFromSliceLeaky(std.json.Value, a, rec.frames.items[0], .{});
    const status = message.object.get("params").?.array.items[0].object;
    try std.testing.expectEqual(@as(usize, 1), status.count());
    const toolhead = status.get("toolhead").?.object;
    try std.testing.expectEqual(@as(usize, 1), toolhead.count());
    try std.testing.expect(toolhead.contains("position"));
    try conns.replaceSubscriptions(io, conn, try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"extruder\":null}", .{}));
    conns.broadcast(io, a, "unfiltered", "toolhead", .{ .method = "notify_status_update", .params = params });
    try std.testing.expectEqual(@as(usize, 1), rec.frames.items.len);
    var aggregate: std.json.ObjectMap = .empty;
    try conns.appendSubscriptionObjects(io, a, &aggregate);
    try std.testing.expectEqual(@as(usize, 1), aggregate.count());
    try std.testing.expect(aggregate.contains("extruder"));
    try std.testing.expectError(error.InvalidParams, conns.replaceSubscriptions(io, conn, try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"toolhead\":[1]}", .{})));
    try std.testing.expect(conn.subs.contains("extruder"));
    conns.detachWriter(io, conn);
    conns.remove(io, conn);
    aggregate = .empty;
    try conns.appendSubscriptionObjects(io, a, &aggregate);
    try std.testing.expectEqual(@as(usize, 0), aggregate.count());
}

test "subscription replacement preserves old state on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            const io = std.testing.io;
            var core = Core.init();
            var conns = Connections.init(alloc, &core);
            defer conns.deinit(io);
            const conn = try conns.add(io, false);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const old = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"toolhead\":[\"position\"]}", .{});
            const next = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"extruder\":[\"temperature\",\"target\"]}", .{});
            try conns.replaceSubscriptions(io, conn, old);
            conns.replaceSubscriptions(io, conn, next) catch |err| {
                try std.testing.expect(conn.subs.contains("toolhead"));
                try std.testing.expect(!conn.subs.contains("extruder"));
                return err;
            };
            try std.testing.expect(!conn.subs.contains("toolhead"));
            try std.testing.expect(conn.subs.contains("extruder"));
        }
    }.run, .{});
}

test "fuzz subscription replacement and status filtering keep only requested fields" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            const io = std.testing.io;
            var core = Core.init();
            var conns = Connections.init(std.testing.allocator, &core);
            defer conns.deinit(io);
            const conn = try conns.add(io, false);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const names = [_][]const u8{ "toolhead", "extruder" };
            const fields = [_][]const u8{ "temperature", "position", "unknown" };
            var request: std.json.ObjectMap = .empty;
            for (names, 0..) |name, i| {
                if (smith.valueRangeAtMostWithHash(u8, 0, 1, @intCast(i)) == 0) continue;
                var selected: std.json.Array = .init(a);
                const field = fields[smith.valueRangeAtMostWithHash(u8, 0, fields.len - 1, @intCast(i + 10))];
                try selected.append(.{ .string = field });
                try request.put(a, name, if (smith.valueRangeAtMostWithHash(u8, 0, 1, @intCast(i + 20)) == 0) .null else .{ .array = selected });
            }
            try conns.replaceSubscriptions(io, conn, .{ .object = request });
            const status = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"toolhead\":{\"position\":[0,0,0],\"temperature\":1},\"extruder\":{\"temperature\":21}}", .{});
            const filtered = try filterStatus(a, conn.subs, status, true);
            var it = filtered.object.iterator();
            while (it.next()) |entry| {
                const selected = request.get(entry.key_ptr.*).?;
                if (selected == .array) {
                    var values = entry.value_ptr.object.iterator();
                    while (values.next()) |value| try std.testing.expectEqualStrings(selected.array.items[0].string, value.key_ptr.*);
                }
            }
            try std.testing.expect(filtered.object.count() <= request.count());
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

            const c = try conns.add(io, false);
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
