//! Klippy's ETX-delimited JSON protocol, bounded to Moonraker's 20 MiB limit.
const std = @import("std");

pub const delimiter = 0x03;
pub const max_size = 20 * 1024 * 1024;

/// Returns an owned payload. A truncated or oversized frame closes the session.
pub fn read(alloc: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    _ = reader.streamDelimiterLimit(&output.writer, delimiter, .limited(max_size)) catch |err| switch (err) {
        error.StreamTooLong => return error.FrameTooLarge,
        error.WriteFailed => return error.OutOfMemory,
        error.ReadFailed => return error.ReadFailed,
    };
    if (try reader.takeByte() != delimiter) return error.InvalidFrame;
    return output.toOwnedSlice();
}

pub fn write(writer: *std.Io.Writer, payload: []const u8) !void {
    if (payload.len >= max_size) return error.FrameTooLarge;
    try writer.writeAll(payload);
    try writer.writeByte(delimiter);
}

test "Klippy framing preserves pipelined and empty payloads" {
    var reader = std.Io.Reader.fixed("hello\x03\x03world\x03");
    for ([_][]const u8{ "hello", "", "world" }) |expected| {
        const payload = try read(std.testing.allocator, &reader);
        defer std.testing.allocator.free(payload);
        try std.testing.expectEqualStrings(expected, payload);
    }
    try std.testing.expectError(error.EndOfStream, read(std.testing.allocator, &reader));
}

test "Klippy framing rejects truncated and oversized payloads" {
    var truncated = std.Io.Reader.fixed("partial");
    try std.testing.expectError(error.EndOfStream, read(std.testing.allocator, &truncated));
    const full = try std.testing.allocator.alloc(u8, max_size + 1);
    defer std.testing.allocator.free(full);
    @memset(full, 'x');
    full[max_size - 1] = delimiter;
    var largest = std.Io.Reader.fixed(full[0..max_size]);
    const payload = try read(std.testing.allocator, &largest);
    defer std.testing.allocator.free(payload);
    try std.testing.expectEqual(max_size - 1, payload.len);
    full[max_size - 1] = 'x';
    full[max_size] = delimiter;
    var oversized = std.Io.Reader.fixed(full);
    try std.testing.expectError(error.FrameTooLarge, read(std.testing.allocator, &oversized));
    var rejecting = std.Io.Writer.Discarding.init(&.{});
    try std.testing.expectError(error.FrameTooLarge, write(&rejecting.writer, full[0..max_size]));
}

test "Klippy framing frees partial output on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            var reader = std.Io.Reader.fixed("{\"id\":1}\x03");
            const payload = try read(alloc, &reader);
            defer alloc.free(payload);
            try std.testing.expectEqualStrings("{\"id\":1}", payload);
        }
    }.run, .{});
}

test "fuzz Klippy framing streams payloads without losing the next frame" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var payload: [4096]u8 = undefined;
            smith.bytesWithHash(&payload, 0);
            std.mem.replaceScalar(u8, &payload, delimiter, ' ');
            var storage: [payload.len + 2]u8 = undefined;
            var writer = std.Io.Writer.fixed(&storage);
            try write(&writer, &payload);
            try write(&writer, "");
            var reader = std.Io.Reader.fixed(writer.buffered());
            const decoded = try read(std.testing.allocator, &reader);
            defer std.testing.allocator.free(decoded);
            try std.testing.expectEqualSlices(u8, &payload, decoded);
            const next = try read(std.testing.allocator, &reader);
            defer std.testing.allocator.free(next);
            try std.testing.expectEqual(0, next.len);
        }
    }.run, .{});
}
