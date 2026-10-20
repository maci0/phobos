//! Linux GPIO character-device edge input through std.Io device control.
const std = @import("std");
const Io = std.Io;

const get_line_event = std.os.linux.IOCTL.IOWR(0xb4, 0x04, EventRequest);
const get_line_values = std.os.linux.IOCTL.IOWR(0xb4, 0x08, [64]u8);
const input_flag: u32 = 1;
const active_low_flag: u32 = 4;
const pull_up_flag: u32 = 32;
const pull_down_flag: u32 = 64;
const both_edges: u32 = 3;

// ABI v1 also serves kernels predating GPIO v2 (5.10).
const EventRequest = extern struct {
    line: u32 = 0,
    flags: u32 = input_flag,
    edges: u32 = both_edges,
    consumer: [32]u8 = @splat(0),
    fd: c_int = -1,
};
const EventData = extern struct { timestamp_ns: u64, id: u32, padding: u32 };
comptime {
    std.debug.assert(@sizeOf(EventRequest) == 48);
    std.debug.assert(@sizeOf(EventData) == 16);
}

pub const Pin = struct {
    chip: u32 = 0,
    line: u32,
    inverted: bool = false,
    bias: enum { disabled, up, down } = .disabled,
};

pub fn parsePin(source: []const u8) !Pin {
    var text = std.mem.trim(u8, source, " \t\r\n");
    var pin: Pin = .{ .line = 0 };
    while (text.len > 0) {
        switch (text[0]) {
            '!' => pin.inverted = true,
            '^' => pin.bias = .up,
            '~' => pin.bias = .down,
            else => break,
        }
        text = text[1..];
    }
    if (std.mem.indexOfScalar(u8, text, '/')) |slash| {
        if (!std.mem.startsWith(u8, text, "gpiochip")) return error.InvalidPin;
        pin.chip = std.fmt.parseInt(u32, text["gpiochip".len..slash], 10) catch return error.InvalidPin;
        text = text[slash + 1 ..];
    }
    if (std.mem.startsWith(u8, text, "gpio")) text = text[4..];
    pin.line = std.fmt.parseInt(u32, text, 10) catch return error.InvalidPin;
    return pin;
}

pub const Input = struct {
    file: Io.File,

    pub fn open(io: Io, root: []const u8, pin: Pin) !Input {
        var path: [Io.Dir.max_path_bytes]u8 = undefined;
        const chip = try Io.Dir.cwd().openFile(io, try std.fmt.bufPrint(&path, "{s}/gpiochip{d}", .{ root, pin.chip }), .{});
        defer chip.close(io);
        return request(io, chip, pin);
    }

    fn request(io: Io, chip: Io.File, pin: Pin) !Input {
        var line_request: EventRequest = .{ .line = pin.line };
        @memcpy(line_request.consumer[0..6], "phobos");
        if (pin.inverted) line_request.flags |= active_low_flag;
        line_request.flags |= switch (pin.bias) {
            .disabled => 0,
            .up => pull_up_flag,
            .down => pull_down_flag,
        };
        const result = try io.operate(.{ .device_io_control = .{ .file = chip, .code = get_line_event, .arg = &line_request } });
        if (result.device_io_control < 0) return error.GpioRequestFailed;
        return .{ .file = .{ .handle = line_request.fd, .flags = .{ .nonblocking = false } } };
    }

    pub fn close(self: Input, io: Io) void {
        self.file.close(io);
    }

    pub fn value(self: Input, io: Io) !bool {
        var values: [64]u8 = @splat(0);
        const result = try io.operate(.{ .device_io_control = .{ .file = self.file, .code = get_line_values, .arg = &values } });
        if (result.device_io_control < 0) return error.GpioReadFailed;
        return values[0] != 0;
    }

    pub fn read(self: Input, io: Io) !bool {
        var data: EventData = undefined;
        const bytes = std.mem.asBytes(&data);
        var used: usize = 0;
        while (used < bytes.len) {
            const count = try self.file.readStreaming(io, &.{bytes[used..]});
            if (count == 0) return error.EndOfStream;
            used += count;
        }
        return decode(bytes);
    }
};

fn decode(bytes: []const u8) !bool {
    if (bytes.len != @sizeOf(EventData)) return error.InvalidGpioEvent;
    return switch (std.mem.readInt(u32, bytes[8..12], @import("builtin").cpu.arch.endian())) {
        1 => true,
        2 => false,
        else => error.InvalidGpioEvent,
    };
}

test "GPIO pin parsing preserves chip, inversion and bias" {
    const pin = try parsePin("^!gpiochip2/gpio23");
    try std.testing.expectEqual(@as(u32, 2), pin.chip);
    try std.testing.expectEqual(@as(u32, 23), pin.line);
    try std.testing.expect(pin.inverted);
    try std.testing.expectEqual(.up, pin.bias);
    try std.testing.expectError(error.InvalidPin, parsePin("bad23"));
    try std.testing.expectError(error.InvalidPin, parsePin("gpiochip/3"));
}

const ControlDouble = struct {
    expected: Pin,
    rejected: bool = false,
    fn operate(raw: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        const control = operation.device_io_control;
        if (control.code == get_line_event) {
            const line: *EventRequest = @ptrCast(@alignCast(control.arg.?));
            std.debug.assert(line.line == self.expected.line);
            std.debug.assert(line.edges == both_edges);
            std.debug.assert((line.flags & active_low_flag != 0) == self.expected.inverted);
            std.debug.assert((line.flags & pull_up_flag != 0) == (self.expected.bias == .up));
            std.debug.assert((line.flags & pull_down_flag != 0) == (self.expected.bias == .down));
            line.fd = -1;
        } else {
            std.debug.assert(control.code == get_line_values);
            const values: *[64]u8 = @ptrCast(@alignCast(control.arg.?));
            values[0] = 1;
        }
        return .{ .device_io_control = if (self.rejected) -1 else 0 };
    }
    fn io(self: *@This()) Io {
        const vtable = comptime blk: {
            var table = Io.failing.vtable.*;
            table.operate = operate;
            break :blk table;
        };
        return .{ .userdata = self, .vtable = &vtable };
    }
};

test "GPIO device control requests both edges and applies input modifiers" {
    const pin = try parsePin("^!gpiochip2/gpio23");
    var control: ControlDouble = .{ .expected = pin };
    const file: Io.File = .{ .handle = -1, .flags = .{ .nonblocking = false } };
    const input = try Input.request(control.io(), file, pin);
    try std.testing.expect(try input.value(control.io()));
    control.rejected = true;
    try std.testing.expectError(error.GpioRequestFailed, Input.request(control.io(), file, pin));
    try std.testing.expectError(error.GpioReadFailed, input.value(control.io()));
}

test "GPIO input reads an edge record from a fake file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var event: EventData = .{ .timestamp_ns = 4, .id = 1, .padding = 0 };
    try tmp.dir.writeFile(io, .{ .sub_path = "events", .data = std.mem.asBytes(&event) });
    const input = Input{ .file = try tmp.dir.openFile(io, "events", .{}) };
    defer input.close(io);
    try std.testing.expect(try input.read(io));
    try std.testing.expectError(error.EndOfStream, input.read(io));
    try std.testing.expectError(error.GpioReadFailed, input.value(io));
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try std.testing.expectError(error.FileNotFound, Input.open(io, root, .{ .line = 2 }));
    try tmp.dir.writeFile(io, .{ .sub_path = "gpiochip0", .data = "" });
    try std.testing.expectError(error.GpioRequestFailed, Input.open(io, root, .{ .line = 2 }));
}

test "fuzz GPIO pin and event decoders reject malformed records" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var bytes: [32]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            _ = parsePin(&bytes) catch {};
            const n = smith.valueRangeAtMostWithHash(u8, 0, bytes.len, 1);
            const value = decode(bytes[0..n]);
            if (n != @sizeOf(EventData)) try std.testing.expectError(error.InvalidGpioEvent, value) else _ = value catch {};
            const pin: Pin = .{ .line = std.mem.readInt(u32, bytes[0..4], .little), .inverted = bytes[4] % 2 == 0, .bias = @fromBackingInt(@intCast(bytes[5] % 3)) };
            var control: ControlDouble = .{ .expected = pin };
            const file: Io.File = .{ .handle = -1, .flags = .{ .nonblocking = false } };
            const input = try Input.request(control.io(), file, pin);
            try std.testing.expect(try input.value(control.io()));
        }
    }.run, .{});
}
