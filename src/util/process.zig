//! Child-process deadlines include termination after the output pipes close.

const std = @import("std");

/// Caller owns stdout and stderr. Cancellation kills and reaps the child.
pub fn run(alloc: std.mem.Allocator, io: std.Io, options: std.process.RunOptions) !std.process.RunResult {
    if (options.timeout == .none) return std.process.run(alloc, io, options);
    const Result = union(enum) {
        child: anyerror!std.process.RunResult,
        deadline: std.Io.Cancelable!void,
    };
    var buffer: [2]Result = undefined;
    var tasks = std.Io.Select(Result).init(io, &buffer);
    defer while (tasks.cancel()) |result| {
        if (result == .child) {
            if (result.child) |output| {
                alloc.free(output.stdout);
                alloc.free(output.stderr);
            } else |_| {}
        }
    };
    try tasks.concurrent(.child, std.process.run, .{ alloc, io, options });
    try tasks.concurrent(.deadline, std.Io.Timeout.sleep, .{ options.timeout, io });
    return switch (try tasks.await()) {
        .child => |output| output,
        .deadline => |result| {
            try result;
            return error.Timeout;
        },
    };
}

test "process deadline includes children that close both output pipes" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "close-output", .data = "#!/bin/sh\nexec 1>&- 2>&-\nexec sleep 5\n", .flags = .{ .permissions = .executable_file } });
    const path = try tmp.dir.realPathFileAlloc(io, "close-output", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Timeout, run(std.testing.allocator, io, .{
        .argv = &.{path},
        .timeout = .{ .deadline = .fromNow(io, .{ .raw = .fromMilliseconds(100), .clock = .awake }) },
    }));
    try std.testing.expect(start.untilNow(io).raw.toMilliseconds() < 3000);
}

test "process deadline retains output and termination status" {
    const output = try run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "printf", "completed" },
        .timeout = .{ .deadline = .fromNow(std.testing.io, .{ .raw = .fromSeconds(3), .clock = .awake }) },
    });
    defer std.testing.allocator.free(output.stdout);
    defer std.testing.allocator.free(output.stderr);
    try std.testing.expectEqualStrings("completed", output.stdout);
    try std.testing.expectEqualStrings("", output.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, output.term);
}

test "fuzz process output limits preserve bounded arguments" {
    try std.testing.fuzz({}, struct {
        fn check(_: void, smith: *std.testing.Smith) !void {
            var value: [64]u8 = undefined;
            smith.bytes(&value);
            for (&value) |*byte| byte.* = 'a' + byte.* % 26;
            const size = smith.valueRangeAtMost(u8, 0, value.len);
            const limit = smith.valueRangeAtMost(u8, 0, value.len);
            const result = run(std.testing.allocator, std.testing.io, .{
                .argv = &.{ "printf", "%s", value[0..size] },
                .stdout_limit = .limited(limit),
                .timeout = .{ .deadline = .fromNow(std.testing.io, .{ .raw = .fromSeconds(3), .clock = .awake }) },
            }) catch |err| {
                try std.testing.expectEqual(error.StreamTooLong, err);
                try std.testing.expect(size > limit);
                return;
            };
            defer std.testing.allocator.free(result.stdout);
            defer std.testing.allocator.free(result.stderr);
            try std.testing.expect(size <= limit);
            try std.testing.expectEqualStrings(value[0..size], result.stdout);
        }
    }.check, .{});
}
