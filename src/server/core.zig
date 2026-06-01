//! Serialized server core.
//!
//! Under the `std.Io.Threaded` thread pool many connection tasks run in
//! parallel, but Moonraker's observable behaviour is that of a single event
//! loop: notifications and id assignment have one global order. `Core`
//! restores that by funnelling logical work through a single mutex, and by
//! handing out monotonic sequence numbers under that same lock.

const std = @import("std");
const Io = std.Io;

pub const Core = struct {
    mutex: Io.Mutex = .init,
    seq: u64 = 0,

    pub fn init() Core {
        return .{};
    }

    /// Enter the serialized critical section. Pair with `unlock`.
    /// Uses the Io-aware mutex so a contended task yields to the backend
    /// scheduler instead of blocking a pool thread.
    pub fn lock(self: *Core, io: Io) void {
        self.mutex.lockUncancelable(io);
    }

    /// Leave the serialized critical section.
    pub fn unlock(self: *Core, io: Io) void {
        self.mutex.unlock(io);
    }

    /// Run `f(args)` inside the critical section, returning its result.
    /// Only one thread executes `f` at a time.
    pub fn run(self: *Core, io: Io, comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
        self.lock(io);
        defer self.unlock(io);
        return @call(.auto, f, args);
    }

    /// Next monotonic sequence number. MUST be called while holding the lock
    /// (e.g. from inside `run`), otherwise distinctness is not guaranteed.
    pub fn nextSeq(self: *Core) u64 {
        self.seq += 1;
        return self.seq;
    }
};

/// A minimal FIFO notification queue, serialized through a `Core`.
/// Task 8 grows this into the full notification bus; for now it provides
/// just enough: enqueue under the lock, drain in FIFO order.
pub fn Fifo(comptime T: type) type {
    return struct {
        const Self = @This();

        core: *Core,
        items: std.ArrayList(T) = .empty,
        alloc: std.mem.Allocator,

        pub fn init(core: *Core, alloc: std.mem.Allocator) Self {
            return .{ .core = core, .alloc = alloc };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.alloc);
        }

        /// Append one item under the core lock.
        pub fn enqueue(self: *Self, io: Io, item: T) !void {
            self.core.lock(io);
            defer self.core.unlock(io);
            try self.items.append(self.alloc, item);
        }

        /// Drain all items in FIFO order into `out`, clearing the queue.
        /// Caller owns the returned slice (allocated with `out_alloc`).
        pub fn drain(self: *Self, io: Io, out_alloc: std.mem.Allocator) ![]T {
            self.core.lock(io);
            defer self.core.unlock(io);
            const out = try out_alloc.alloc(T, self.items.items.len);
            @memcpy(out, self.items.items);
            self.items.clearRetainingCapacity();
            return out;
        }
    };
}

// --- tests ---------------------------------------------------------------

const SeqCtx = struct {
    io: Io,
    core: *Core,
    counter: *u64,
    seqs: []u64,
    base: usize,
    count: usize,
};

fn seqWorker(ctx: *SeqCtx) void {
    var i: usize = 0;
    while (i < ctx.count) : (i += 1) {
        ctx.core.lock(ctx.io);
        ctx.counter.* += 1;
        ctx.seqs[ctx.base + i] = ctx.core.nextSeq();
        ctx.core.unlock(ctx.io);
    }
}

test "core serializes and seq is monotonic" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var counter: u64 = 0;

    const workers = 4;
    const per_worker = 250;
    const total = workers * per_worker;

    var seqs: [total]u64 = undefined;
    var ctxs: [workers]SeqCtx = undefined;
    for (&ctxs, 0..) |*c, w| {
        c.* = .{ .io = io, .core = &core, .counter = &counter, .seqs = &seqs, .base = w * per_worker, .count = per_worker };
    }

    var futs: [workers]@TypeOf(io.async(seqWorker, .{&ctxs[0]})) = undefined;
    for (&futs, 0..) |*f, w| f.* = io.async(seqWorker, .{&ctxs[w]});
    for (&futs) |*f| f.await(io);

    // No lost updates -> mutual exclusion held.
    try std.testing.expectEqual(@as(u64, total), counter);

    // Seqs are distinct and cover the contiguous range [1, total].
    std.mem.sort(u64, &seqs, {}, comptime std.sort.asc(u64));
    for (seqs, 0..) |s, i| {
        try std.testing.expectEqual(@as(u64, i + 1), s);
    }
}

test "notifications drain in FIFO order" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var core = Core.init();
    var q = Fifo([]const u8).init(&core, std.testing.allocator);
    defer q.deinit();

    try q.enqueue(io, "notify_a");
    try q.enqueue(io, "notify_b");

    const drained = try q.drain(io, std.testing.allocator);
    defer std.testing.allocator.free(drained);

    try std.testing.expectEqual(@as(usize, 2), drained.len);
    try std.testing.expectEqualStrings("notify_a", drained[0]);
    try std.testing.expectEqualStrings("notify_b", drained[1]);
}

const ProdCtx = struct {
    io: Io,
    q: *Fifo(u32),
    producer: u32,
    count: u32,
};

fn producerWorker(ctx: *ProdCtx) void {
    var i: u32 = 0;
    while (i < ctx.count) : (i += 1) {
        // Encode producer in high bits, sequence in low bits so we can verify
        // per-producer relative ordering after draining.
        const item: u32 = (ctx.producer << 24) | i;
        ctx.q.enqueue(ctx.io, item) catch {};
    }
}

test "fuzz_core: concurrent producers keep relative order with no loss" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var seed: [2]u8 = undefined;
            smith.bytesWithHash(&seed, 0);

            const producers: u32 = 2 + (@as(u32, seed[0]) % 5); // 2..6
            const per: u32 = 1 + (@as(u32, seed[1]) % 64); // 1..64

            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();

            var core = Core.init();
            var q = Fifo(u32).init(&core, std.heap.smp_allocator);
            defer q.deinit();

            const ctxs = try std.heap.smp_allocator.alloc(ProdCtx, producers);
            defer std.heap.smp_allocator.free(ctxs);
            for (ctxs, 0..) |*c, p| c.* = .{ .io = io, .q = &q, .producer = @intCast(p), .count = per };

            const FutT = @TypeOf(io.async(producerWorker, .{&ctxs[0]}));
            const futs = try std.heap.smp_allocator.alloc(FutT, producers);
            defer std.heap.smp_allocator.free(futs);
            for (futs, 0..) |*f, p| f.* = io.async(producerWorker, .{&ctxs[p]});
            for (futs) |*f| f.await(io);

            const drained = try q.drain(io, std.heap.smp_allocator);
            defer std.heap.smp_allocator.free(drained);

            // No loss: total count matches.
            try std.testing.expectEqual(@as(usize, producers * per), drained.len);

            // Per-producer relative order preserved: each producer's items must
            // appear in increasing sequence in the drained output.
            const last = try std.heap.smp_allocator.alloc(?u32, producers);
            defer std.heap.smp_allocator.free(last);
            @memset(last, null);
            for (drained) |item| {
                const p = item >> 24;
                const seq = item & 0x00FF_FFFF;
                if (last[p]) |prev| {
                    try std.testing.expect(seq > prev);
                }
                last[p] = seq;
            }
        }
    }.run, .{});
}
