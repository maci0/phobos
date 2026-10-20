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

test "fuzz_core: run returns the result of each call and seq counts them" {
    try std.testing.fuzz({}, struct {
        fn bump(c: *Core, by: u8) u64 {
            var last: u64 = 0;
            for (0..by) |_| last = c.nextSeq();
            return last;
        }
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            var core = Core.init();
            var total: u64 = 0;
            for (0..smith.valueRangeAtMostWithHash(u8, 0, 16, 0)) |i| {
                const by = smith.valueRangeAtMostWithHash(u8, 1, 32, @intCast(i + 1));
                total += by;
                try std.testing.expectEqual(total, core.run(threaded.io(), bump, .{ &core, by }));
            }
        }
    }.run, .{});
}
