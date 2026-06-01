const std = @import("std");

/// Deferred callback signature: opaque context plus a small integer argument.
pub const DeferredFn = *const fn (ctx: *anyopaque, arg: u8) void;

const Deferred = struct {
    cb: DeferredFn,
    ctx: *anyopaque,
    arg: u8,
};

/// Timer callback signature: just the opaque context.
pub const TimerFn = *const fn (ctx: *anyopaque) void;

const Timer = struct {
    deadline_ms: i64,
    seq: u64, // tiebreaker preserving insertion order at equal deadlines
    cb: TimerFn,
    ctx: *anyopaque,
};

/// Fd readiness callback: receives the fd and the ready epoll event mask.
pub const FdFn = *const fn (ctx: *anyopaque, fd: i32, events: u32) void;

const FdReg = struct {
    fd: i32,
    cb: FdFn,
    ctx: *anyopaque,
};

const max_events = 64;

/// Current monotonic time in milliseconds. This std build trims
/// std.time.milliTimestamp / Instant, so we read the clock directly.
fn nowMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ms_per_s +
        @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}

/// Single-threaded epoll reactor with a FIFO deferred queue and a timer heap.
pub const Reactor = struct {
    allocator: std.mem.Allocator,
    deferred: std.ArrayList(Deferred),
    timers: std.ArrayList(Timer),
    fds: std.ArrayList(FdReg),
    epfd: i32,
    seq: u64,
    stopped: bool,

    pub fn init(allocator: std.mem.Allocator) !Reactor {
        const rc = std.os.linux.epoll_create1(0);
        if (std.os.linux.errno(rc) != .SUCCESS) return error.EpollCreateFailed;
        return .{
            .allocator = allocator,
            .deferred = .empty,
            .timers = .empty,
            .fds = .empty,
            .epfd = @intCast(rc),
            .seq = 0,
            .stopped = false,
        };
    }

    pub fn deinit(self: *Reactor) void {
        self.deferred.deinit(self.allocator);
        self.timers.deinit(self.allocator);
        self.fds.deinit(self.allocator);
        _ = std.os.linux.close(self.epfd);
    }

    /// Enqueue a deferred callback. FIFO order is preserved (asyncio call_soon).
    pub fn callSoon(self: *Reactor, cb: DeferredFn, ctx: *anyopaque, arg: u8) !void {
        try self.deferred.append(self.allocator, .{ .cb = cb, .ctx = ctx, .arg = arg });
    }

    /// Drain the deferred queue exactly once, in insertion order.
    pub fn runPending(self: *Reactor) !void {
        // Snapshot the current length: callbacks enqueued during draining are
        // serviced on the next pass, matching call_soon semantics.
        var i: usize = 0;
        const n = self.deferred.items.len;
        while (i < n) : (i += 1) {
            const d = self.deferred.items[i];
            d.cb(d.ctx, d.arg);
        }
        // Remove the drained prefix.
        if (n > 0) {
            const remaining = self.deferred.items.len - n;
            std.mem.copyForwards(Deferred, self.deferred.items[0..remaining], self.deferred.items[n..]);
            self.deferred.shrinkRetainingCapacity(remaining);
        }
    }

    /// Schedule a one-shot timer to fire after `delay_ms` from now.
    pub fn callLater(self: *Reactor, delay_ms: i64, cb: TimerFn, ctx: *anyopaque) !void {
        const deadline = nowMs() + delay_ms;
        try self.timers.append(self.allocator, .{
            .deadline_ms = deadline,
            .seq = self.seq,
            .cb = cb,
            .ctx = ctx,
        });
        self.seq += 1;
    }

    fn timerBefore(_: void, a: Timer, b: Timer) bool {
        if (a.deadline_ms != b.deadline_ms) return a.deadline_ms < b.deadline_ms;
        return a.seq < b.seq;
    }

    /// Fire all timers whose deadline has passed, in (deadline, seq) order.
    fn fireDueTimers(self: *Reactor) void {
        if (self.timers.items.len == 0) return;
        std.mem.sort(Timer, self.timers.items, {}, timerBefore);
        const now = nowMs();
        var fired: usize = 0;
        while (fired < self.timers.items.len and self.timers.items[fired].deadline_ms <= now) {
            fired += 1;
        }
        if (fired == 0) return;
        // Copy the due timers out before invoking, since callbacks may schedule
        // new timers (mutating the list).
        var due: [max_events]Timer = undefined;
        var count: usize = 0;
        while (count < fired and count < max_events) : (count += 1) {
            due[count] = self.timers.items[count];
        }
        const remaining = self.timers.items.len - count;
        std.mem.copyForwards(Timer, self.timers.items[0..remaining], self.timers.items[count..]);
        self.timers.shrinkRetainingCapacity(remaining);
        for (due[0..count]) |t| t.cb(t.ctx);
    }

    /// Milliseconds until the next timer fires, or null if none are pending.
    fn nextTimeout(self: *Reactor) ?i32 {
        if (self.timers.items.len == 0) return null;
        var earliest: i64 = std.math.maxInt(i64);
        for (self.timers.items) |t| {
            if (t.deadline_ms < earliest) earliest = t.deadline_ms;
        }
        const now = nowMs();
        const delta = earliest - now;
        if (delta <= 0) return 0;
        if (delta > std.math.maxInt(i32)) return std.math.maxInt(i32);
        return @intCast(delta);
    }

    /// Register an fd for readiness notifications via epoll.
    pub fn addFd(self: *Reactor, fd: i32, events: u32, cb: FdFn, ctx: *anyopaque) !void {
        try self.fds.append(self.allocator, .{ .fd = fd, .cb = cb, .ctx = ctx });
        errdefer _ = self.fds.pop();
        var ev = std.os.linux.epoll_event{
            .events = events,
            .data = .{ .fd = fd },
        };
        const rc = std.os.linux.epoll_ctl(self.epfd, std.os.linux.EPOLL.CTL_ADD, fd, &ev);
        if (std.os.linux.errno(rc) != .SUCCESS) {
            _ = self.fds.pop();
            return error.EpollAddFailed;
        }
    }

    /// Change the event mask and/or callback for an already-registered fd.
    pub fn modFd(self: *Reactor, fd: i32, events: u32, cb: FdFn, ctx: *anyopaque) !void {
        for (self.fds.items) |*reg| {
            if (reg.fd == fd) {
                reg.cb = cb;
                reg.ctx = ctx;
                break;
            }
        } else return error.FdNotRegistered;
        var ev = std.os.linux.epoll_event{
            .events = events,
            .data = .{ .fd = fd },
        };
        const rc = std.os.linux.epoll_ctl(self.epfd, std.os.linux.EPOLL.CTL_MOD, fd, &ev);
        if (std.os.linux.errno(rc) != .SUCCESS) return error.EpollModFailed;
    }

    /// Unregister an fd from the reactor.
    pub fn delFd(self: *Reactor, fd: i32) void {
        var i: usize = 0;
        while (i < self.fds.items.len) {
            if (self.fds.items[i].fd == fd) {
                _ = self.fds.swapRemove(i);
            } else i += 1;
        }
        _ = std.os.linux.epoll_ctl(self.epfd, std.os.linux.EPOLL.CTL_DEL, fd, null);
    }

    fn lookupFd(self: *Reactor, fd: i32) ?FdReg {
        for (self.fds.items) |reg| {
            if (reg.fd == fd) return reg;
        }
        return null;
    }

    /// One iteration of the loop: drain deferred, wait up to `max_wait_ms` (capped
    /// by the next timer), dispatch ready fds, then fire due timers.
    pub fn runOnce(self: *Reactor, max_wait_ms: i32) !void {
        try self.runPending();

        var timeout: i32 = max_wait_ms;
        if (self.nextTimeout()) |t| {
            if (t < timeout) timeout = t;
        }
        // If deferred work was enqueued by the drained callbacks, don't block.
        if (self.deferred.items.len > 0) timeout = 0;

        var events: [max_events]std.os.linux.epoll_event = undefined;
        const rc = std.os.linux.epoll_wait(self.epfd, &events, max_events, timeout);
        const n: usize = switch (std.os.linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INTR => 0,
            else => return error.EpollWaitFailed,
        };

        for (events[0..n]) |ev| {
            const fd = ev.data.fd;
            if (self.lookupFd(fd)) |reg| {
                reg.cb(reg.ctx, fd, ev.events);
            }
        }

        self.fireDueTimers();
    }

    /// Request that `run` stop after the current iteration.
    pub fn stop(self: *Reactor) void {
        self.stopped = true;
    }

    /// Main loop: run until `stop` is called.
    pub fn run(self: *Reactor) !void {
        self.stopped = false;
        while (!self.stopped) {
            try self.runOnce(1000);
        }
    }
};

// ---- test helpers ----

const AppendCtx = struct {
    list: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
};

fn appendCb(ctx_ptr: *anyopaque, n: u8) void {
    const ctx: *AppendCtx = @ptrCast(@alignCast(ctx_ptr));
    ctx.list.append(ctx.alloc, n) catch {};
}

test "deferred callbacks run in FIFO order" {
    var r = try Reactor.init(std.testing.allocator);
    defer r.deinit();

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    var ctx = AppendCtx{ .list = &list, .alloc = std.testing.allocator };

    try r.callSoon(appendCb, &ctx, 1);
    try r.callSoon(appendCb, &ctx, 2);
    try r.callSoon(appendCb, &ctx, 3);
    try r.runPending();

    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, list.items);
}

const TimerCtx = struct {
    list: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    label: u8,
};

fn timerCb(ctx_ptr: *anyopaque) void {
    const ctx: *TimerCtx = @ptrCast(@alignCast(ctx_ptr));
    ctx.list.append(ctx.alloc, ctx.label) catch {};
}

test "timers fire in deadline order" {
    var r = try Reactor.init(std.testing.allocator);
    defer r.deinit();

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    var late = TimerCtx{ .list = &list, .alloc = std.testing.allocator, .label = 'b' };
    var early = TimerCtx{ .list = &list, .alloc = std.testing.allocator, .label = 'a' };

    try r.callLater(5, timerCb, &late);
    try r.callLater(1, timerCb, &early);

    // Drive the loop until both timers have fired (bounded wall-clock budget).
    const deadline = nowMs() + 500;
    while (list.items.len < 2 and nowMs() < deadline) {
        try r.runOnce(50);
    }

    try std.testing.expectEqualSlices(u8, &[_]u8{ 'a', 'b' }, list.items);
}
