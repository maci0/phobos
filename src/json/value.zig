//! Thin helpers over std.json for building JSON-RPC responses.
//! Provides insertion-ordered object construction and allocation-backed serialization.
const std = @import("std");

/// Checked truncation for numeric fields accepted as either JSON integers or floats.
pub fn floatToInt(value: f64) ?i64 {
    if (!std.math.isFinite(value) or value < -0x1p63 or value >= 0x1p63) return null;
    return @intFromFloat(value);
}

/// An owned JSON serialization result. Caller must free with allocator.free().
pub const OwnedJson = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: OwnedJson) void {
        self.allocator.free(self.bytes);
    }
};

/// Serialize any std.json.Value (or Zig value) to an owned []u8.
/// Caller owns the returned slice and must free it.
pub fn serializeAlloc(alloc: std.mem.Allocator, v: anytype) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(alloc, v, .{});
}

/// Recursively copy a JSON Value into `alloc`, owning all strings/keys, so the
/// copy is independent of the source's lifetime. Bounded inputs only (callers
/// that accept untrusted JSON must `exceedsDepth`-guard first — this recurses per
/// nesting level like the serializer).
pub fn deepCopy(alloc: std.mem.Allocator, val: std.json.Value) error{OutOfMemory}!std.json.Value {
    return switch (val) {
        .string => .{ .string = try alloc.dupe(u8, val.string) },
        .integer, .float, .bool, .null => val,
        .number_string => .{ .number_string = try alloc.dupe(u8, val.number_string) },
        .object => |obj| {
            var new_obj: std.json.ObjectMap = .empty;
            errdefer free(alloc, .{ .object = new_obj });
            // Final size is known: size the map once instead of rehashing as it grows.
            try new_obj.ensureTotalCapacity(alloc, obj.count());
            var it = obj.iterator();
            while (it.next()) |kv| {
                const key = try alloc.dupe(u8, kv.key_ptr.*);
                errdefer alloc.free(key);
                new_obj.putAssumeCapacity(key, try deepCopy(alloc, kv.value_ptr.*));
            }
            return .{ .object = new_obj };
        },
        .array => |arr| {
            var new_arr: std.json.Array = .init(alloc);
            errdefer free(alloc, .{ .array = new_arr });
            // Final length is known: reserve once instead of doubling-realloc per append.
            try new_arr.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| new_arr.appendAssumeCapacity(try deepCopy(alloc, item));
            return .{ .array = new_arr };
        },
    };
}

/// Release a bounded JSON tree owned by `deepCopy`, including keys and strings.
pub fn free(alloc: std.mem.Allocator, val: std.json.Value) void {
    switch (val) {
        .string => |s| alloc.free(s),
        .number_string => |s| alloc.free(s),
        .object => |obj| {
            var owned = obj;
            var it = owned.iterator();
            while (it.next()) |entry| {
                alloc.free(entry.key_ptr.*);
                free(alloc, entry.value_ptr.*);
            }
            owned.deinit(alloc);
        },
        .array => |arr| {
            var owned = arr;
            for (owned.items) |item| free(alloc, item);
            owned.deinit();
        },
        .integer, .float, .bool, .null => {},
    }
}

/// Maximum JSON nesting depth phobos accepts for stored/echoed values. Real
/// Moonraker data (config, gcode metadata, UI settings) is shallow (< 10). The
/// cap exists because `std.json.Stringify` serializes with a fixed 256-level
/// nesting stack: a value nested deeper than that panics (and corrupts memory in
/// release, where the bounds check is off). Reject over-deep values on ingest so
/// they can never reach the serializer.
pub const max_value_depth = 100;

/// True if `v` nests deeper than `max` levels. Recurses at most `max + 1` frames
/// (early-out on the first over-deep branch), so the check itself can't overflow
/// the stack on adversarial input — unlike serialization, which would.
pub fn exceedsDepth(v: std.json.Value, max: usize) bool {
    switch (v) {
        .array => |a| {
            if (max == 0) return true;
            for (a.items) |item| if (exceedsDepth(item, max - 1)) return true;
        },
        .object => |o| {
            if (max == 0) return true;
            var it = o.iterator();
            while (it.next()) |e| if (exceedsDepth(e.value_ptr.*, max - 1)) return true;
        },
        else => {},
    }
    return false;
}

test "exceedsDepth: flat values are never too deep" {
    try std.testing.expect(!exceedsDepth(.{ .integer = 1 }, 0));
    try std.testing.expect(!exceedsDepth(.{ .string = "x" }, 0));
}

test "exceedsDepth: nesting at and beyond the limit" {
    const a = std.testing.allocator;
    // Build n-deep arrays and check the boundary.
    for ([_]usize{ 5, 50, 150 }) |depth| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const al = arena.allocator();
        var v: std.json.Value = .{ .integer = 1 };
        for (0..depth) |_| {
            var arr: std.json.Array = .init(al);
            try arr.append(v);
            v = .{ .array = arr };
        }
        // depth `d` of arrays => exceedsDepth(v, d-1) is true, exceedsDepth(v, d) is false.
        try std.testing.expect(exceedsDepth(v, depth - 1));
        try std.testing.expect(!exceedsDepth(v, depth));
    }
}

test "fuzz exceedsDepth: never crashes on arbitrary nesting up to a large depth" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();
    // 5000-deep — far past max_value_depth; the early-out keeps recursion bounded.
    var v: std.json.Value = .{ .integer = 1 };
    for (0..5000) |_| {
        var arr: std.json.Array = .init(al);
        try arr.append(v);
        v = .{ .array = arr };
    }
    try std.testing.expect(exceedsDepth(v, max_value_depth));
}

/// Build a JSON-RPC 2.0 success response object as an owned []u8.
/// `id` should be a std.json.Value (.integer, .string, or .null).
/// `result` is any serializable value.
/// Caller must free.
pub fn successResponse(
    alloc: std.mem.Allocator,
    id: std.json.Value,
    result: std.json.Value,
) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    jw.beginObject() catch return error.OutOfMemory;
    jw.objectField("jsonrpc") catch return error.OutOfMemory;
    jw.write("2.0") catch return error.OutOfMemory;
    jw.objectField("result") catch return error.OutOfMemory;
    jw.write(result) catch return error.OutOfMemory;
    jw.objectField("id") catch return error.OutOfMemory;
    jw.write(id) catch return error.OutOfMemory;
    jw.endObject() catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// Build a JSON-RPC 2.0 error response as an owned []u8.
/// Caller must free.
pub fn errorResponse(
    alloc: std.mem.Allocator,
    id: std.json.Value,
    code: i64,
    message: []const u8,
) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    jw.beginObject() catch return error.OutOfMemory;
    jw.objectField("jsonrpc") catch return error.OutOfMemory;
    jw.write("2.0") catch return error.OutOfMemory;
    jw.objectField("error") catch return error.OutOfMemory;
    jw.beginObject() catch return error.OutOfMemory;
    jw.objectField("code") catch return error.OutOfMemory;
    jw.write(code) catch return error.OutOfMemory;
    jw.objectField("message") catch return error.OutOfMemory;
    jw.write(message) catch return error.OutOfMemory;
    jw.endObject() catch return error.OutOfMemory;
    jw.objectField("id") catch return error.OutOfMemory;
    jw.write(id) catch return error.OutOfMemory;
    jw.endObject() catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

// --- Tests ---

test "serializeAlloc: string value" {
    const alloc = std.testing.allocator;
    const v: std.json.Value = .{ .string = "hello" };
    const out = try serializeAlloc(alloc, v);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("\"hello\"", out);
}

test "serializeAlloc: integer value" {
    const alloc = std.testing.allocator;
    const v: std.json.Value = .{ .integer = 42 };
    const out = try serializeAlloc(alloc, v);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("42", out);
}

test "successResponse: builds correct envelope" {
    const alloc = std.testing.allocator;
    const id: std.json.Value = .{ .integer = 1 };
    const result: std.json.Value = .{ .string = "ok" };
    const out = try successResponse(alloc, id, result);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","result":"ok","id":1}
    , out);
}

test "successResponse: null id" {
    const alloc = std.testing.allocator;
    const id: std.json.Value = .null;
    const result: std.json.Value = .{ .integer = 0 };
    const out = try successResponse(alloc, id, result);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","result":0,"id":null}
    , out);
}

test "errorResponse: builds correct envelope" {
    const alloc = std.testing.allocator;
    const id: std.json.Value = .{ .integer = 7 };
    const out = try errorResponse(alloc, id, -32601, "Method not found");
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found"},"id":7}
    , out);
}

test "fuzz_value_helpers: never crash on arbitrary values" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const alloc = std.testing.allocator;
            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            // Build a string value from fuzz bytes (valid UTF-8 subset: just use len)
            const len = @as(usize, buf[0]) % 32;
            const v: std.json.Value = .{ .string = buf[0..len] };
            const id: std.json.Value = .{ .integer = @as(i64, @intCast(buf[1])) };

            const s = try serializeAlloc(alloc, v);
            defer alloc.free(s);

            const r = try successResponse(alloc, id, v);
            defer alloc.free(r);

            const e = try errorResponse(alloc, id, -32600, buf[0..len]);
            defer alloc.free(e);
        }
    }.run, .{});
}

test "floatToInt rejects non-finite and overflowing values" {
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), 0x1p63, -0x1p64 }) |value|
        try std.testing.expectEqual(null, floatToInt(value));
    try std.testing.expectEqual(@as(?i64, std.math.minInt(i64)), floatToInt(-0x1p63));
    try std.testing.expectEqual(@as(?i64, 42), floatToInt(42.9));
    try std.testing.expectEqual(@as(?i64, -42), floatToInt(-42.9));
}

test "fuzz floatToInt handles arbitrary IEEE values" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            const value: f64 = @bitCast(smith.value(u64));
            if (floatToInt(value)) |integer| {
                try std.testing.expect(std.math.isFinite(value));
                try std.testing.expectEqual(@trunc(value), @as(f64, @floatFromInt(integer)));
            }
        }
    }.run, .{});
}

test "JSON copy cleans up every partial allocation" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"text\":\"hello\",\"array\":[true,null,{\"n\":1}],\"object\":{}}", .{});
    defer parsed.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn copy(alloc: std.mem.Allocator, val: std.json.Value) !void {
            const owned = try deepCopy(alloc, val);
            defer free(alloc, owned);
        }
    }.copy, .{parsed.value});
}

test "fuzz JSON copy owns and releases bounded trees" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var raw: [32]u8 = undefined;
            smith.bytesWithHash(&raw, 0);
            var source: std.json.Array = .init(std.testing.allocator);
            defer source.deinit();
            for (&raw) |*b| try source.append(.{ .string = b[0..1] });
            const copy = try deepCopy(std.testing.allocator, .{ .array = source });
            defer free(std.testing.allocator, copy);
            for (copy.array.items, &raw) |item, b| try std.testing.expectEqual(b, item.string[0]);
        }
    }.run, .{});
}
