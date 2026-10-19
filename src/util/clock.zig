//! Clock units and UTC formatting through the caller's I/O backend.
const std = @import("std");
const Io = std.Io;

fn seconds(io: Io, kind: Io.Clock) f64 {
    return @as(f64, @floatFromInt(kind.now(io).toNanoseconds())) / std.time.ns_per_s;
}

pub fn wallSeconds(io: Io) f64 {
    return seconds(io, .real);
}

pub fn wallSecondsInt(io: Io) i64 {
    return Io.Clock.real.now(io).toSeconds();
}

pub fn wallNanos(io: Io) u64 {
    return std.math.lossyCast(u64, Io.Clock.real.now(io).toNanoseconds());
}

pub fn monotonicSeconds(io: Io) f64 {
    return seconds(io, .awake);
}

pub fn monotonicNanos(io: Io) u64 {
    return std.math.lossyCast(u64, Io.Clock.awake.now(io).toNanoseconds());
}

pub fn bootSeconds(io: Io) f64 {
    return seconds(io, .boot);
}

pub fn processCpuSeconds(io: Io) f64 {
    return seconds(io, .cpu_process);
}

/// UTC "YYYY-MM-DDTHH:MM:SSZ". `buf` needs at least 20 bytes.
pub fn iso8601(io: Io, buf: []u8) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, wallSecondsInt(io))) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,              md.month.numeric(),      @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch "1970-01-01T00:00:00Z";
}

test "wall clocks are positive and consistent" {
    const s = wallSeconds(std.testing.io);
    try std.testing.expect(s > 1_700_000_000.0);
    try std.testing.expectApproxEqAbs(s, @as(f64, @floatFromInt(wallSecondsInt(std.testing.io))), 2.0);
    try std.testing.expect(wallNanos(std.testing.io) > 0);
}

test "monotonic clocks and process CPU clocks are nonnegative" {
    const a = monotonicSeconds(std.testing.io);
    try std.testing.expect(monotonicSeconds(std.testing.io) >= a);
    try std.testing.expect(monotonicNanos(std.testing.io) > 0);
    try std.testing.expect(bootSeconds(std.testing.io) >= 0);
    try std.testing.expect(processCpuSeconds(std.testing.io) >= 0);
}

test "iso8601 shape" {
    var buf: [32]u8 = undefined;
    const s = iso8601(std.testing.io, &buf);
    try std.testing.expectEqual(@as(usize, 20), s.len);
    try std.testing.expectEqual(@as(u8, 'T'), s[10]);
    try std.testing.expectEqual(@as(u8, 'Z'), s[19]);
}

test "fuzz iso8601: any buffer at least 20 bytes never crashes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var buf: [64]u8 = undefined;
            const n = smith.valueRangeAtMostWithHash(u32, 20, 64, 0);
            _ = iso8601(std.testing.io, buf[0..n]);
        }
    }.run, .{});
}
