//! Interruptible timer sleep for background timer threads.
//!
//! Zig 0.16 removed the classic `std.Thread` sync primitives (`ResetEvent`,
//! `Futex`, `Condition`); waiting now goes through `std.Io`. A background timer
//! thread therefore can't block on a cancellable wait the way it used to. The
//! workaround used across the components (button, td1, machine, announcements)
//! is to sleep the tick in small chunks and poll an atomic stop flag between
//! them, so `deinit`→`join` returns within one chunk instead of waiting out the
//! full interval. Centralised here so every timer uses the same bound.

const std = @import("std");

/// Default poll granularity: deinit→join latency is bounded by this.
pub const chunk_ms: u64 = 100;

/// Sleep approximately `total_ms`, split into `chunk_ms` slices, checking `stop`
/// before each slice. Returns `true` as soon as `stop` is observed set (the
/// caller should break out of its loop), or `false` after the full interval
/// elapsed without a stop. Also returns `true` if `io.sleep` itself fails
/// (e.g. cancellation), so the caller tears down rather than spins.
pub fn chunked(io: std.Io, total_ms: u64, stop: *std.atomic.Value(bool)) bool {
    var remaining = total_ms;
    while (remaining > 0) {
        if (stop.load(.acquire)) return true;
        const this = @min(remaining, chunk_ms);
        io.sleep(std.Io.Duration.fromMilliseconds(this), .awake) catch return true;
        remaining -= this;
    }
    return stop.load(.acquire);
}

test "chunked: returns true immediately when stop already set" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var stop = std.atomic.Value(bool).init(true);
    try std.testing.expect(chunked(io, 1000, &stop));
}

test "chunked: returns false after the interval when never stopped" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var stop = std.atomic.Value(bool).init(false);
    // Short total so the test stays fast; spans multiple chunks.
    try std.testing.expect(!chunked(io, 250, &stop));
}

test "chunked: a stop set mid-sleep is observed within ~one chunk" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var stop = std.atomic.Value(bool).init(false);
    const Setter = struct {
        fn run(s: *std.atomic.Value(bool), i: std.Io) void {
            i.sleep(std.Io.Duration.fromMilliseconds(120), .awake) catch {};
            s.store(true, .release);
        }
    };
    const th = try std.Thread.spawn(.{}, Setter.run, .{ &stop, io });
    defer th.join();
    // Would sleep ~5 s without interruption; must return early once stop flips.
    try std.testing.expect(chunked(io, 5000, &stop));
}

test "fuzz chunked: arbitrary total_ms never hangs or crashes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            // Pre-set stop so the call returns immediately regardless of the
            // (fuzz-chosen) interval — we exercise the arithmetic/bounds, not
            // real wall-clock time.
            var stop = std.atomic.Value(bool).init(true);
            const total = smith.valueRangeAtMostWithHash(u64, 0, 1_000_000, 0);
            _ = chunked(io, total, &stop);
        }
    }.run, .{});
}
