//! Standard JSON parsing with bulk copies for long ASCII string values.
const std = @import("std");
const minimum_string_len = 1024;

pub fn parse(alloc: std.mem.Allocator, text: []const u8) std.json.ParseError(Source)!std.json.Parsed(std.json.Value) {
    if (text.len < minimum_string_len) return std.json.parseFromSlice(std.json.Value, alloc, text, .{});
    var source: Source = .{ .scanner = .initCompleteInput(alloc, text) };
    defer source.scanner.deinit();
    return std.json.parseFromTokenSource(std.json.Value, alloc, &source, .{ .max_value_len = text.len });
}

/// All returned storage belongs to the caller's arena, including on failure.
pub fn parseLeaky(alloc: std.mem.Allocator, text: []const u8) std.json.ParseError(Source)!std.json.Value {
    if (text.len < minimum_string_len) return std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{});
    var source: Source = .{ .scanner = .initCompleteInput(alloc, text) };
    defer source.scanner.deinit();
    return std.json.parseFromTokenSourceLeaky(std.json.Value, alloc, &source, .{ .max_value_len = text.len });
}

const Source = struct {
    scanner: std.json.Scanner,
    pub const NextError = std.json.Scanner.NextError;
    pub const AllocError = std.json.Scanner.AllocError;
    pub const PeekError = std.json.Scanner.PeekError;

    pub fn next(self: *@This()) NextError!std.json.Token {
        return self.scanner.next();
    }

    pub fn nextAllocMax(self: *@This(), alloc: std.mem.Allocator, when: std.json.AllocWhen, max_len: usize) AllocError!std.json.Token {
        const kind = self.scanner.peekNextTokenType() catch |err| switch (err) {
            error.BufferUnderrun => unreachable,
            else => |e| return e,
        };
        if (kind == .string and when == .alloc_always and self.scanner.state == .value) {
            if (try self.longString(alloc, max_len)) |value| return .{ .allocated_string = value };
        }
        return self.scanner.nextAllocMax(alloc, when, max_len);
    }

    fn longString(self: *@This(), alloc: std.mem.Allocator, max_len: usize) AllocError!?[]u8 {
        const start = self.scanner.cursor;
        if (self.scanner.input.len - start <= minimum_string_len or self.scanner.input[start] != '"') return null;
        var from = start + 1;
        const end = while (std.mem.findScalarPos(u8, self.scanner.input, from, '"')) |end| {
            var slash = end;
            while (slash > start + 1 and self.scanner.input[slash - 1] == '\\') slash -= 1;
            if ((end - slash) % 2 == 0) break end;
            from = end + 1;
        } else return null;
        const raw = self.scanner.input[start + 1 .. end];
        if (raw.len < minimum_string_len) return null;
        const escaped = std.mem.findScalar(u8, raw, '\\') != null;
        if (!asciiString(raw)) return null;
        if (escaped) {
            var from_unicode: usize = 0;
            while (std.mem.findScalarPos(u8, raw, from_unicode, 'u')) |index| {
                if (index > 0 and raw[index - 1] == '\\') return null;
                from_unicode = index + 1;
            }
        }
        if (!escaped) {
            if (raw.len > max_len) return error.ValueTooLong;
            const output = try alloc.dupe(u8, raw);
            self.scanner.cursor = end + 1;
            self.scanner.value_start = end;
            self.scanner.state = .post_value;
            return output;
        }
        const output = try alloc.alloc(u8, @min(raw.len, max_len));
        errdefer alloc.free(output);
        var read: usize = 0;
        var written: usize = 0;
        if (std.simd.suggestVectorLength(u8)) |width| {
            const Vector = @Vector(width, u8);
            while (raw.len - read >= width and output.len - written >= width) {
                const bytes: Vector = raw[read..][0..width].*;
                const mask: @Int(.unsigned, width) = @bitCast(bytes == @as(Vector, @splat('\\')));
                const plain: usize = @ctz(mask);
                @memcpy(output[written..][0..width], raw[read..][0..width]);
                written += plain;
                read += plain;
                if (plain < width) {
                    if (read + 1 == raw.len) return error.UnexpectedEndOfInput;
                    output[written] = try unescape(raw[read + 1]);
                    written += 1;
                    read += 2;
                }
            }
        }
        while (read < raw.len) {
            const byte = if (raw[read] == '\\') blk: {
                read += 1;
                if (read == raw.len) return error.UnexpectedEndOfInput;
                break :blk try unescape(raw[read]);
            } else raw[read];
            if (written == output.len) return error.ValueTooLong;
            output[written] = byte;
            written += 1;
            read += 1;
        }
        // Complete only value tokens; std.Scanner still handles keys and structure.
        self.scanner.cursor = end + 1;
        self.scanner.value_start = end;
        self.scanner.state = .post_value;
        return try alloc.realloc(output, written);
    }
};

fn unescape(byte: u8) error{SyntaxError}!u8 {
    return switch (byte) {
        '"', '\\', '/' => byte,
        'b' => 8,
        'f' => 12,
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        else => error.SyntaxError,
    };
}

fn asciiString(text: []const u8) bool {
    var index: usize = 0;
    if (std.simd.suggestVectorLength(u8)) |width| {
        const Vector = @Vector(width, u8);
        while (text.len - index >= width) : (index += width) {
            const bytes: Vector = text[index..][0..width].*;
            if (@reduce(.Or, (bytes < @as(Vector, @splat(0x20))) | (bytes >= @as(Vector, @splat(0x80))))) return false;
        }
    }
    for (text[index..]) |byte| if (byte < 0x20 or byte >= 0x80) return false;
    return true;
}

test "long ASCII strings match standard JSON decoding" {
    const a = std.testing.allocator;
    var text: [4096]u8 = undefined;
    for (&text, 0..) |*byte, i| byte.* = switch (i % 21) {
        0 => '"',
        1 => '\\',
        2 => '\n',
        3 => '\r',
        4 => '\t',
        else => @intCast('A' + i % 26),
    };
    for ([_]usize{ 1023, 1024, 1025, text.len }) |len| {
        const wire = try std.json.Stringify.valueAlloc(a, .{ .message = text[0..len], .trailing = .{ 1, 2, true, "é水😀" } }, .{});
        defer a.free(wire);
        const expected = try std.json.parseFromSlice(std.json.Value, a, wire, .{});
        defer expected.deinit();
        const actual = try parse(a, wire);
        defer actual.deinit();
        const before = try std.json.Stringify.valueAlloc(a, expected.value, .{});
        defer a.free(before);
        const after = try std.json.Stringify.valueAlloc(a, actual.value, .{});
        defer a.free(after);
        try std.testing.expectEqualStrings(before, after);
    }
}

fn compare(alloc: std.mem.Allocator, wire: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const expected = std.json.parseFromSlice(std.json.Value, alloc, wire, .{}) catch |err| {
        if (parse(alloc, wire)) |unexpected| {
            unexpected.deinit();
            return error.TestExpectedError;
        } else |actual| try std.testing.expectEqual(@as(anyerror, err), @as(anyerror, actual));
        try std.testing.expectError(err, parseLeaky(arena.allocator(), wire));
        return;
    };
    defer expected.deinit();
    const actual = try parse(alloc, wire);
    defer actual.deinit();
    const before = try std.json.Stringify.valueAlloc(alloc, expected.value, .{});
    defer alloc.free(before);
    const after = try std.json.Stringify.valueAlloc(alloc, actual.value, .{});
    defer alloc.free(after);
    try std.testing.expectEqualStrings(before, after);
    const leaky = try parseLeaky(arena.allocator(), wire);
    try std.testing.expectEqualStrings(before, try std.json.Stringify.valueAlloc(arena.allocator(), leaky, .{}));
}

test "long strings preserve every byte, validation and trailing document checks" {
    const a = std.testing.allocator;
    var text: [2049]u8 = @splat('x');
    for (0..256) |byte| {
        for ([_]usize{ 0, 15, 16, 17, 1023, 1024, text.len - 1 }) |position| {
            text[position] = @intCast(byte);
            defer text[position] = 'x';
            const wire = try std.json.Stringify.valueAlloc(a, .{ .message = &text, .after = true }, .{});
            defer a.free(wire);
            try compare(a, wire);
        }
    }
    const prefix: [1024]u8 = @splat('x');
    for ([_][]const u8{ "\\a\"}", "\\uD800\"}", "\\uDC00\"}", "\\uD800\\uDC00\"}", "\\u0000\"}", "\\n\"}garbage", "\\\"}", "\"\"}", "\x01\"}", "é水😀\"}", "\xff\"}", "\"}", "", "\\" }) |suffix| {
        const wire = try std.fmt.allocPrint(a, "{{\"message\":\"{s}{s}", .{ prefix, suffix });
        defer a.free(wire);
        try compare(a, wire);
    }
    const key = try std.fmt.allocPrint(a, "{{\"{s}\\n\":1,\"tail\":false}}", .{prefix});
    defer a.free(key);
    try compare(a, key);
}

test "long strings obey decoded token limits" {
    const a = std.testing.allocator;
    var text: [2048]u8 = @splat('\n');
    for ([_]usize{ 1023, 1024, 1025, text.len }) |len| {
        const wire = try std.json.Stringify.valueAlloc(a, text[0..len], .{});
        defer a.free(wire);
        for ([_]usize{ 0, 1, len - 1, len, len + 1 }) |limit| {
            var source: Source = .{ .scanner = .initCompleteInput(a, wire) };
            defer source.scanner.deinit();
            if (limit < len) {
                try std.testing.expectError(error.ValueTooLong, std.json.parseFromTokenSource(std.json.Value, a, &source, .{ .max_value_len = limit }));
            } else {
                const parsed = try std.json.parseFromTokenSource(std.json.Value, a, &source, .{ .max_value_len = limit });
                defer parsed.deinit();
                try std.testing.expectEqualStrings(text[0..len], parsed.value.string);
            }
        }
    }
}

test "long string parsing owns input and bounds arena growth" {
    const a = std.testing.allocator;
    const text: [256 * 1024]u8 = @splat('x');
    const wire = try std.json.Stringify.valueAlloc(a, .{ .result = &text }, .{});
    defer a.free(wire);
    var tracked = std.testing.FailingAllocator.init(a, .{});
    const parsed = try parse(tracked.allocator(), wire);
    defer parsed.deinit();
    @memset(wire, 'z');
    try std.testing.expectEqualStrings(&text, parsed.value.object.get("result").?.string);
    try std.testing.expect(tracked.allocated_bytes < text.len * 2 + 4096);
}

test "long string parsing releases every partial allocation" {
    const a = std.testing.allocator;
    const text: [2048]u8 = @splat('\n');
    const wire = try std.json.Stringify.valueAlloc(a, .{ .message = &text, .after = true }, .{});
    defer a.free(wire);
    var no_resize = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
    for ([_]bool{ false, true }) |leaky| {
        try std.testing.checkAllAllocationFailures(no_resize.allocator(), struct {
            fn run(alloc: std.mem.Allocator, input: []const u8, in_arena: bool) !void {
                if (in_arena) {
                    var arena = std.heap.ArenaAllocator.init(alloc);
                    defer arena.deinit();
                    const value = try parseLeaky(arena.allocator(), input);
                    try std.testing.expectEqual(@as(usize, 2048), value.object.get("message").?.string.len);
                } else {
                    const parsed = try parse(alloc, input);
                    defer parsed.deinit();
                    try std.testing.expectEqual(@as(usize, 2048), parsed.value.object.get("message").?.string.len);
                }
            }
        }.run, .{ wire, leaky });
    }
}

test "fuzz long string tokens match standard JSON values and errors" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var text: [4096]u8 = undefined;
            smith.bytesWithHash(&text, 0);
            const alphabet = "abcdefABCDEF01234567 \\\"/\n\r\t\x08\x0c";
            for (&text) |*byte| byte.* = alphabet[byte.* % alphabet.len];
            if (smith.value(bool)) @memcpy(text[1024..][0.."é水😀".len], "é水😀");
            const len = smith.valueRangeAtMostWithHash(u16, 0, text.len, 1);
            const a = std.testing.allocator;
            const wire = try std.json.Stringify.valueAlloc(a, .{ .message = text[0..len], .after = .{ 1, false, "end" } }, .{});
            defer a.free(wire);
            try compare(a, wire);
            const index = smith.valueRangeAtMostWithHash(u32, 0, @intCast(wire.len - 1), 2);
            wire[index] = smith.value(u8);
            try compare(a, wire);
        }
    }.run, .{});
}
