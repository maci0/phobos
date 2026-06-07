//! Wall-clock and monotonic time helpers — the single place in the tree that
//! reads a system clock.
//!
//! These are deliberately io-free: they are called from io-less paths (--dump-api,
//! unit tests, and pure timestamp helpers) where no `std.Io` instance exists, so
//! the higher-level `std.Io.Timestamp.now(io, …)` cannot be used. This stripped
//! std has no io-free wall-clock reader (`std.time` only exposes constants), so a
//! direct `clock_gettime` is the only option — isolated here behind a small,
//! audited API rather than scattered across every component.

const std = @import("std");

fn read(clock_id: anytype) std.os.linux.timespec {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(clock_id, &ts);
    return ts;
}

fn toSeconds(ts: std.os.linux.timespec) f64 {
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1.0e9;
}

/// Wall-clock (CLOCK_REALTIME) seconds since the Unix epoch, as a float.
pub fn wallSeconds() f64 {
    return toSeconds(read(std.os.linux.CLOCK.REALTIME));
}

/// Wall-clock seconds since the Unix epoch, truncated to a whole second.
pub fn wallSecondsInt() i64 {
    return @intCast(read(std.os.linux.CLOCK.REALTIME).sec);
}

/// Raw wall-clock timespec (for callers that need the epoch breakdown).
pub fn wallTimespec() std.os.linux.timespec {
    return read(std.os.linux.CLOCK.REALTIME);
}

/// Wall-clock (CLOCK_REALTIME) nanoseconds since the Unix epoch.
pub fn wallNanos() u64 {
    const ts = read(std.os.linux.CLOCK.REALTIME);
    return @as(u64, @intCast(@max(0, ts.sec))) *% 1_000_000_000 +% @as(u64, @intCast(@max(0, ts.nsec)));
}

/// Monotonic (CLOCK_MONOTONIC) seconds — not affected by wall-clock jumps.
pub fn monotonicSeconds() f64 {
    return toSeconds(read(std.os.linux.CLOCK.MONOTONIC));
}

/// Monotonic (CLOCK_MONOTONIC) nanoseconds — for unique-id / interval math.
pub fn monotonicNanos() u64 {
    const ts = read(std.os.linux.CLOCK.MONOTONIC);
    return @as(u64, @intCast(@as(i64, ts.sec))) *% 1_000_000_000 +% @as(u64, @intCast(@as(i64, ts.nsec)));
}

/// System uptime (CLOCK_BOOTTIME) in seconds, including time spent suspended.
pub fn bootSeconds() f64 {
    return toSeconds(read(std.os.linux.CLOCK.BOOTTIME));
}

/// Per-process consumed CPU time (CLOCK_PROCESS_CPUTIME_ID) in seconds.
pub fn processCpuSeconds() f64 {
    return toSeconds(read(std.os.linux.CLOCK.PROCESS_CPUTIME_ID));
}

/// Current UTC time as an ISO-8601 string ("YYYY-MM-DDTHH:MM:SSZ") written into
/// `buf` (needs >= 20 bytes).
pub fn iso8601(buf: []u8) []const u8 {
    const ts = wallTimespec();
    const secs: u64 = @intCast(@max(0, ts.sec));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,
        md.month.numeric(),
        @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch "1970-01-01T00:00:00Z";
}

test "wallSeconds / wallSecondsInt are positive and consistent" {
    const s = wallSeconds();
    try std.testing.expect(s > 1_700_000_000.0); // after 2023
    const i = wallSecondsInt();
    try std.testing.expect(@as(f64, @floatFromInt(i)) <= s + 1.0);
    try std.testing.expect(@as(f64, @floatFromInt(i)) >= s - 2.0);
}

test "monotonicSeconds is non-decreasing" {
    const a = monotonicSeconds();
    const b = monotonicSeconds();
    try std.testing.expect(b >= a);
}

test "iso8601 shape" {
    var buf: [32]u8 = undefined;
    const s = iso8601(&buf);
    try std.testing.expectEqual(@as(usize, 20), s.len);
    try std.testing.expectEqual(@as(u8, 'T'), s[10]);
    try std.testing.expectEqual(@as(u8, 'Z'), s[19]);
}

test "fuzz iso8601: any buffer >= 20 never crashes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            const n = smith.valueRangeAtMostWithHash(u32, 20, 64, 0);
            _ = iso8601(buf[0..n]);
        }
    }.run, .{});
}
