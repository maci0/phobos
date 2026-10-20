//! Linux V4L2 format and discrete-resolution enumeration through std.Io.
const std = @import("std");
const Io = std.Io;

const max_entries = 128;
const capture_type = 1;
const discrete_type = 1;

// linux/videodev2.h; std.Io supplies device control but not the V4L2 ABI.
const Format = extern struct {
    index: u32,
    type: u32,
    flags: u32,
    description: [32]u8,
    pixel_format: u32,
    reserved: [4]u32,
};
const FrameSize = extern struct {
    index: u32,
    pixel_format: u32,
    type: u32,
    size: extern union {
        discrete: extern struct { width: u32, height: u32 },
        stepwise: [6]u32,
    },
    reserved: [2]u32,
};
const enum_format = std.os.linux.IOCTL.IOWR('V', 2, Format);
const enum_sizes = std.os.linux.IOCTL.IOWR('V', 74, FrameSize);

/// JSON arrays and strings belong to alloc, normally the request arena.
pub fn enumerate(io: Io, file: Io.File, alloc: std.mem.Allocator) !std.json.Array {
    var modes: std.json.Array = .init(alloc);
    for (0..max_entries) |index| {
        var format: Format = std.mem.zeroes(Format);
        format.index = @intCast(index);
        format.type = capture_type;
        const result = try io.operate(.{ .device_io_control = .{ .file = file, .code = enum_format, .arg = &format } });
        if (result.device_io_control < 0) break;
        const description = std.mem.sliceTo(&format.description, 0);
        if (!std.unicode.utf8ValidateSlice(description)) return error.InvalidUtf8;
        var resolutions: std.json.Array = .init(alloc);
        for (0..max_entries) |size_index| {
            var size: FrameSize = std.mem.zeroes(FrameSize);
            size.index = @intCast(size_index);
            size.pixel_format = format.pixel_format;
            const size_result = try io.operate(.{ .device_io_control = .{ .file = file, .code = enum_sizes, .arg = &size } });
            if (size_result.device_io_control < 0 or size.type != discrete_type) break;
            try resolutions.append(.{ .string = try std.fmt.allocPrint(alloc, "{d}x{d}", .{ size.size.discrete.width, size.size.discrete.height }) });
        }
        if (resolutions.items.len == 0) continue;
        var fourcc: [4]u8 = undefined;
        var n: usize = 0;
        for (0..fourcc.len) |byte_index| {
            const byte: u8 = @truncate(format.pixel_format >> @as(u5, @intCast(byte_index * 8)));
            if (byte < 0x80) {
                fourcc[n] = byte;
                n += 1;
            }
        }
        var flags: std.json.Array = .init(alloc);
        if (format.flags & 1 != 0) try flags.append(.{ .string = "COMPRESSED" });
        if (format.flags & 2 != 0) try flags.append(.{ .string = "EMULATED" });
        var mode: std.json.ObjectMap = .empty;
        try mode.put(alloc, "format", .{ .string = try alloc.dupe(u8, fourcc[0..n]) });
        try mode.put(alloc, "description", .{ .string = try alloc.dupe(u8, description) });
        try mode.put(alloc, "flags", .{ .array = flags });
        try mode.put(alloc, "resolutions", .{ .array = resolutions });
        try modes.append(.{ .object = mode });
    }
    return modes;
}

const Fixture = struct {
    description: [32]u8 = @splat(0),
    pixel_format: u32 = 0x47504a4d,
    flags: u32 = 3,
    width: u32 = 640,
    height: u32 = 480,
    size_type: u32 = discrete_type,
    format_count: u32 = 1,
    size_count: u32 = 2,
    calls: usize = 0,
    cancel: bool = false,

    fn operate(raw: ?*anyopaque, op: Io.Operation) Io.Cancelable!Io.Operation.Result {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.cancel) return error.Canceled;
        const request = op.device_io_control;
        if (request.code == enum_format) {
            const out: *Format = @ptrCast(@alignCast(request.arg.?));
            if (out.index >= self.format_count) return .{ .device_io_control = -1 };
            std.debug.assert(out.type == capture_type);
            out.description = self.description;
            out.pixel_format = self.pixel_format;
            out.flags = self.flags;
        } else {
            std.debug.assert(request.code == enum_sizes);
            const out: *FrameSize = @ptrCast(@alignCast(request.arg.?));
            std.debug.assert(out.pixel_format == self.pixel_format);
            if (out.index >= self.size_count) return .{ .device_io_control = -1 };
            out.type = self.size_type;
            out.size.discrete = .{ .width = self.width, .height = self.height };
        }
        return .{ .device_io_control = 0 };
    }

    fn io(self: *@This()) Io {
        const table = comptime table: {
            var v = Io.failing.vtable.*;
            v.operate = operate;
            break :table v;
        };
        return .{ .userdata = self, .vtable = &table };
    }
};

test "V4L2 modes use typed Linux layouts and return flags and discrete resolutions" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Format));
    try std.testing.expectEqual(@as(usize, 44), @sizeOf(FrameSize));
    try std.testing.expectEqual(@as(usize, 44), @offsetOf(Format, "pixel_format"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(FrameSize, "size"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = .{};
    @memcpy(fixture.description[0..5], "MJPEG");
    const file: Io.File = .{ .handle = 0, .flags = .{ .nonblocking = true } };
    const modes = try enumerate(fixture.io(), file, arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), modes.items.len);
    const mode = modes.items[0].object;
    try std.testing.expectEqualStrings("MJPG", mode.get("format").?.string);
    try std.testing.expectEqualStrings("MJPEG", mode.get("description").?.string);
    try std.testing.expectEqualStrings("COMPRESSED", mode.get("flags").?.array.items[0].string);
    try std.testing.expectEqualStrings("EMULATED", mode.get("flags").?.array.items[1].string);
    try std.testing.expectEqual(@as(usize, 2), mode.get("resolutions").?.array.items.len);
    try std.testing.expectEqualStrings("640x480", mode.get("resolutions").?.array.items[0].string);
    fixture.size_type = 3;
    try std.testing.expectEqual(@as(usize, 0), (try enumerate(fixture.io(), file, arena.allocator())).items.len);
    fixture.cancel = true;
    try std.testing.expectError(error.Canceled, enumerate(fixture.io(), file, arena.allocator()));
}

test "fuzz V4L2 modes bound driver replies and reject invalid UTF-8" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var fixture: Fixture = .{};
            smith.bytesWithHash(&fixture.description, 0);
            fixture.pixel_format = smith.valueWithHash(u32, 1);
            fixture.flags = smith.valueWithHash(u32, 2);
            fixture.width = smith.valueWithHash(u32, 3);
            fixture.height = smith.valueWithHash(u32, 4);
            fixture.size_type = smith.valueRangeAtMostWithHash(u32, 0, 3, 5);
            fixture.format_count = smith.valueRangeAtMostWithHash(u32, 0, 3, 6);
            fixture.size_count = smith.valueRangeAtMostWithHash(u32, 0, 3, 7);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const result = enumerate(fixture.io(), .{ .handle = 0, .flags = .{ .nonblocking = true } }, arena.allocator()) catch |err| switch (err) {
                error.InvalidUtf8 => return,
                else => return err,
            };
            try std.testing.expect(result.items.len <= fixture.format_count);
            try std.testing.expect(fixture.calls <= 16);
        }
    }.run, .{});
}
