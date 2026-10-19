//! Interruptible waits for owned background workers.
const std = @import("std");
const Io = std.Io;

/// Returns true on stop/cancellation, false when the interval expires.
pub fn untilStopped(io: Io, duration: Io.Duration, stop: *Io.Event) bool {
    if (stop.isSet()) return true;
    const start = Io.Clock.Timestamp.now(io, .awake);
    const end = start.raw.nanoseconds +| @max(0, duration.nanoseconds);
    while (!stop.isSet()) {
        const now = Io.Clock.Timestamp.now(io, .awake);
        if (now.raw.nanoseconds >= end) return false;
        // Keep native timespec seconds representable on 32-bit targets.
        const deadline: Io.Clock.Timestamp = .{
            .raw = .{ .nanoseconds = @min(end, now.raw.nanoseconds +| std.time.ns_per_day) },
            .clock = .awake,
        };
        stop.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Timeout => continue,
            error.Canceled => return true,
        };
        return true;
    }
    return true;
}

test "timer expires or returns immediately when stopped" {
    var stop: Io.Event = .unset;
    try std.testing.expect(!untilStopped(std.testing.io, .fromMilliseconds(1), &stop));
    stop.set(std.testing.io);
    try std.testing.expect(untilStopped(std.testing.io, .fromSeconds(3600), &stop));
}

test "stop wakes an hour-long timer promptly" {
    var threaded = Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var stop: Io.Event = .unset;
    const Setter = struct {
        fn run(event: *Io.Event, aio: Io) void {
            aio.sleep(.fromMilliseconds(10), .awake) catch return;
            event.set(aio);
        }
    };
    const thread = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, Setter.run, .{ &stop, io });
    defer thread.join();
    const start = Io.Clock.Timestamp.now(io, .awake);
    try std.testing.expect(untilStopped(io, .fromSeconds(3600), &stop));
    try std.testing.expect(start.untilNow(io).raw.toMilliseconds() < 1000);
}

test "fuzz timer: arbitrary durations return immediately after stop" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var stop: Io.Event = .is_set;
            const ms = smith.valueRangeAtMostWithHash(i64, 0, 1_000_000, 0);
            try std.testing.expect(untilStopped(std.testing.io, .fromMilliseconds(ms), &stop));
        }
    }.run, .{});
}

test "timer retries spurious wakes and bounds native deadlines" {
    const Fake = struct {
        now_ns: i96 = 1,
        wakes: usize = 0,
        fn now(raw: ?*anyopaque, _: Io.Clock) Io.Timestamp {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return .{ .nanoseconds = self.now_ns };
        }
        fn wait(raw: ?*anyopaque, _: *const u32, _: u32, timeout: Io.Timeout) Io.Cancelable!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.wakes += 1;
            const deadline = timeout.deadline.raw.nanoseconds;
            std.debug.assert(deadline - self.now_ns <= std.time.ns_per_day);
            if (self.wakes > 1) self.now_ns = deadline;
        }
    };
    var fake: Fake = .{};
    var vtable = std.testing.io.vtable.*;
    vtable.now = Fake.now;
    vtable.futexWait = Fake.wait;
    const aio: Io = .{ .userdata = &fake, .vtable = &vtable };
    var stop: Io.Event = .unset;
    try std.testing.expect(!untilStopped(aio, .fromMilliseconds(10), &stop));
    try std.testing.expectEqual(@as(usize, 2), fake.wakes);
    stop = .is_set;
    try std.testing.expect(untilStopped(aio, .{ .nanoseconds = std.math.maxInt(i96) }, &stop));
}
